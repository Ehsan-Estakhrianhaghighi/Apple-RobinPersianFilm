import Foundation
import SwiftSoup

/// Follows provider-published forms instead of fabricating per-episode tokens.
struct StreamResolver {
    private let http = ProviderHTTP.shared

    func resolve(title: MediaTitle, episode: Episode? = nil) async throws -> [MediaStream] {
        let target = episode?.pageURL ?? title.pageURL
        if title.provider == .farsiLand {
            return try await resolveFarsiLand(pageURL: target)
        }
        do {
            return try await resolveFarsiPlex(pageURL: target)
        } catch {
            let primaryError = error
            // Keep the FarsiPlex diagnostic when a matching FarsiLand fallback
            // exists but also fails. Do not hide an unreachable published source.
            guard let fallback = await CatalogService().farsiLandFallback(for: title) else { throw primaryError }
            do {
                if let episode {
                    let options = try await CatalogService().episodes(for: fallback)
                    guard let alternative = options.first(where: {
                        $0.season == episode.season && $0.number == episode.number
                    }) else { throw primaryError }
                    return try await resolveFarsiLand(pageURL: alternative.pageURL)
                }
                return try await resolveFarsiLand(pageURL: fallback.pageURL)
            } catch { throw primaryError }
        }
    }

    /// An Android browser session may publish a signed FarsiPlex MP4 URL that
    /// tvOS cannot discover without a browser engine. Accept that exact URL
    /// when the user provides it, verify it, and test only signed filename
    /// quality variants. Never fabricate or persist expiring tokens.
    func resolveFarsiPlexPublishedURL(_ text: String) async throws -> [MediaStream] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https",
              url.host?.lowercased() == "pl.farsiplex.buzz",
              url.path.lowercased().hasSuffix(".mp4"),
              await http.verifyMP4(url) else { throw AppProblem.noStream }

        let quality = firstRegexCapture(
            #"[.-](360|480|720|1080)(?=(?:\.[^./]+)*\.mp4$)"#,
            in: url.path
        ).flatMap(Int.init) ?? 720
        var available = [MediaStream(url: url, quality: quality, source: "FarsiPlex")]
        let pattern = #"[.-](360|480|720|1080)(?=(?:\.[^./]+)*\.mp4$)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: url.path, range: NSRange(url.path.startIndex..., in: url.path)),
           let range = Range(match.range(at: 1), in: url.path) {
            for candidateQuality in [480, 720, 1080] where candidateQuality != quality {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                var path = url.path
                path.replaceSubrange(range, with: String(candidateQuality))
                components?.path = path
                if let candidate = components?.url, await http.verifyMP4(candidate) {
                    available.append(MediaStream(url: candidate, quality: candidateQuality, source: "FarsiPlex"))
                }
            }
        }
        return available.sorted { $0.quality < $1.quality }
    }

    private func resolveFarsiLand(pageURL: URL) async throws -> [MediaStream] {
        let first = try await http.page(pageURL)
        guard let watch = try first.document.select("form[action]").array().first(where: {
            let action = ((try? $0.attr("action")) ?? "").lowercased()
            return action.contains("farsiland.buzz/redirect.php")
        }), let watchURL = formAction(watch, base: first.url) else { throw AppProblem.noStream }

        let redirected = try await http.page(watchURL, fields: formFields(watch), referer: first.url)
        guard let jump = try redirected.document.select("form[action]").array().first(where: {
            guard let url = formAction($0, base: redirected.url) else { return false }
            return hostMatches(url, "farsiland.buzz")
        }), let jumpURL = formAction(jump, base: redirected.url) else { throw AppProblem.noStream }

        let selection = try await http.page(jumpURL, fields: formFields(jump), referer: redirected.url)
        let forms = (try? selection.document.select("form").array()) ?? []
        var verified: [MediaStream] = []
        for form in forms {
            let fields = formFields(form)
            guard let qualityText = fields.first(where: { $0.0 == "q" })?.1,
                  let quality = Int(qualityText), [480, 720, 1080].contains(quality),
                  fields.contains(where: { $0.0 == "postid" && !$0.1.isEmpty }),
                  let url = formAction(form, base: selection.url) else { continue }
            guard let page = try? await http.page(url, fields: fields, referer: selection.url) else { continue }
            let streams = publishedStreams(in: page.html, source: "FarsiLand", qualityHint: quality)
            for stream in streams where !verified.contains(where: { $0.url == stream.url }) {
                if await http.verifyMP4(stream.url) { verified.append(stream) }
            }
        }
        guard !verified.isEmpty else { throw AppProblem.noStream }
        return verified.sorted { $0.quality < $1.quality }
    }

    // tvOS does not offer Android WebView. Follow only FarsiPlex player links
    // actually published by this selected title, retaining server cookies,
    // POST fields, and Referer. This supports native HTTP-based player flows,
    // but it never claims to execute JavaScript or complete access prompts.
    private struct PlaybackRoute {
        let url: URL
        let fields: [(String, String)]?
        let referer: URL

        var key: String {
            let payload = fields?.map { "\($0.0)=\($0.1)" }.joined(separator: "&") ?? ""
            return url.absoluteString + "|" + payload
        }
    }

    private func publishedPlaybackRoutes(in page: PageResponse) -> [PlaybackRoute] {
        var result: [PlaybackRoute] = []
        var seen = Set<String>()
        let nodes = (try? page.document.select(
            "a[href], iframe[src], [data-href], [data-url], [data-src]"
        ).array()) ?? []
        for node in nodes.prefix(240) {
            for attr in ["href", "src", "data-href", "data-url", "data-src"] {
                guard node.hasAttr(attr),
                      let raw = try? node.attr(attr),
                      let url = absoluteURL(raw, base: page.url),
                      url.scheme == "https",
                      hostMatches(url, "farsiplex.com"),
                      isFarsiPlexPlayerPath(url.path) else { continue }
                let route = PlaybackRoute(url: url, fields: nil, referer: page.url)
                if seen.insert(route.key).inserted { result.append(route) }
            }
        }
        // Some title-specific player buttons submit a provider form, not a link.
        // Only submit a form whose action explicitly targets a player route.
        // Login, advertisement and payment forms are never submitted.
        for form in (try? page.document.select("form[action]").array()) ?? [] {
            guard let target = formAction(form, base: page.url),
                  target.scheme == "https",
                  hostMatches(target, "farsiplex.com") else { continue }
            let method = ((try? form.attr("method")) ?? "get").lowercased()
            guard method == "post" || method == "get" else { continue }
            let fields = formFields(form)
            // Verified on Balit and Taxi: their public Watch button submits a
            // single hidden post ID to POST /play/, which redirects to a
            // title-specific JWPlayer page. Earlier versions ignored /play/.
            let publicWatchForm = target.path.lowercased() == "/play/" &&
                method == "post" && fields.count == 1 &&
                fields[0].0 == "id" && !fields[0].1.isEmpty &&
                fields[0].1.allSatisfy({ $0.isNumber })
            guard publicWatchForm || isFarsiPlexPlayerPath(target.path) else { continue }
            let route: PlaybackRoute
            if method == "post" {
                route = PlaybackRoute(url: target, fields: fields, referer: page.url)
            } else if fields.isEmpty {
                route = PlaybackRoute(url: target, fields: nil, referer: page.url)
            } else {
                var components = URLComponents(url: target, resolvingAgainstBaseURL: false)
                var queries = components?.queryItems ?? []
                queries += fields.map { URLQueryItem(name: $0.0, value: $0.1) }
                components?.queryItems = queries
                guard let nextURL = components?.url else { continue }
                route = PlaybackRoute(url: nextURL, fields: nil, referer: page.url)
            }
            if seen.insert(route.key).inserted { result.append(route) }
        }
        return result
    }

    private func isFarsiPlexPlayerPath(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.hasPrefix("/play-") ||
            p.hasPrefix("/play-quick-view/") ||
            p.hasPrefix("/play-hq-player/") ||
            p.hasPrefix("/watch/") || p.hasPrefix("/stream/")
    }

    private func hasSelectedTitleEvidence(in page: PageResponse, titleURL: URL,
                                          streams: [MediaStream]) -> Bool {
        let titleSlug = titleURL.path.split(separator: "/").last.map(String.init) ?? ""
        let token = normalizedTitle(titleSlug)
        guard token.count >= 4 else { return false }
        // The generic HQ player may show unrelated editorial articles if it
        // has no current-title state. Don't play a random video from that page.
        if page.html.localizedCaseInsensitiveContains(titleSlug) { return true }
        return streams.contains { stream in
            let mediaName = normalizedTitle(stream.url.deletingPathExtension().lastPathComponent)
            return mediaName.contains(token) || token.contains(mediaName)
        }
    }

    private func resolveFarsiPlex(pageURL: URL) async throws -> [MediaStream] {
        let first = try await http.page(pageURL)
        var streams = publishedStreams(in: first.html, source: "FarsiPlex")
        streams += linkedMP4Streams(in: first, source: "FarsiPlex")
        streams += jwPlayerStreams(in: first)

        // Try the first-party title -> quick view -> HQ player route. A single
        // page fetch was insufficient for the current FarsiPlex page structure.
        var routes = publishedPlaybackRoutes(in: first)
        let initialRoutes = routes.count
        var visited = Set<String>()
        var checked = 0
        while !routes.isEmpty && checked < 8 && streams.isEmpty {
            let next = routes.removeFirst()
            guard visited.insert(next.key).inserted else { continue }
            checked += 1
            guard let page = try? await http.page(next.url, fields: next.fields,
                                                  referer: next.referer) else { continue }
            var found = publishedStreams(in: page.html, source: "FarsiPlex")
            found += linkedMP4Streams(in: page, source: "FarsiPlex")
            found += jwPlayerStreams(in: page)
            let path = page.url.path.lowercased()
            let generic = path == "/play-hq-player/" ||
                path == "/play-quick-view/" ||
                path == "/play-hq-player" || path == "/play-quick-view"
            let titleBoundWatch = next.url.path.lowercased() == "/play/" &&
                next.fields?.contains(where: { $0.0 == "id" }) == true
            if titleBoundWatch || !generic ||
                hasSelectedTitleEvidence(in: page, titleURL: pageURL, streams: found) {
                streams += found
            }
            // Only follow controls actually published by pages reached from
            // this title. Never discover arbitrary movie URLs across the site.
            routes += publishedPlaybackRoutes(in: page)
        }

        guard !streams.isEmpty else {
            print("FarsiPlex native playback: no title-bound published MP4; checked \(checked) first-party player pages.")
            throw AppProblem.browserPlaybackRequired(publishedRoutes: initialRoutes, visitedRoutes: checked)
        }
        // Discover only variants of a signed filename actually published and
        // verified. Reuse its existing query unchanged; no token fabrication.
        let current = streams
        for stream in current {
            let path = stream.url.path
            let pattern = #"[.-](360|480|720|1080)(?=(?:\.[^./?]+)*\.mp4$)"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
                  let range = Range(match.range(at: 1), in: path) else { continue }
            for quality in [480, 720, 1080] where quality != stream.quality {
                var alternativePath = path
                alternativePath.replaceSubrange(range, with: String(quality))
                var components = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)
                components?.path = alternativePath
                if let variant = components?.url,
                   !streams.contains(where: { $0.url == variant }),
                   await http.verifyMP4(variant) {
                    streams.append(MediaStream(url: variant, quality: quality, source: stream.source))
                }
            }
        }
        var valid: [MediaStream] = []
        for stream in streams where !valid.contains(where: { $0.url == stream.url }) {
            if await http.verifyMP4(stream.url) { valid.append(stream) }
        }
        guard !valid.isEmpty else { throw AppProblem.publishedStreamsUnreachable(found: streams.count) }
        return valid.sorted { $0.quality < $1.quality }
    }

    // FarsiPlex's actual public Watch form redirects to a player page with
    // iframe URLs like /jwplayer/?source=https://cdn2.farsiland.com/series/taxi/01.720.mp4.
    // The source parameter is the provider-published media URL, not the
    // outer /jwplayer/ URL. Never invent filenames, hosts, or signed tokens.
    private func jwPlayerStreams(in page: PageResponse) -> [MediaStream] {
        var results: [MediaStream] = []
        var seen = Set<URL>()
        func add(_ raw: String) {
            guard let wrapper = absoluteURL(raw, base: page.url),
                  wrapper.scheme == "https",
                  hostMatches(wrapper, "farsiplex.com"),
                  wrapper.path.lowercased().hasPrefix("/jwplayer/"),
                  let components = URLComponents(url: wrapper, resolvingAgainstBaseURL: false),
                  let candidateText = components.queryItems?.first(where: { $0.name == "source" })?.value,
                  let url = URL(string: candidateText),
                  url.scheme == "https",
                  ["pl.farsiplex.buzz", "pl.farsiland.buzz", "cdn2.farsiland.com"]
                    .contains(url.host?.lowercased() ?? ""),
                  url.path.lowercased().hasSuffix(".mp4"),
                  seen.insert(url).inserted else { return }
            let quality = firstRegexCapture(
                #"[.-](360|480|720|1080)(?=(?:\.[^./]+)*\.mp4$)"#, in: url.path
            ).flatMap(Int.init) ?? 720
            results.append(MediaStream(url: url, quality: quality, source: "FarsiPlex"))
        }
        let elements = (try? page.document.select(
            "iframe[src], iframe[data-src], a[href], [data-url], [data-src]"
        ).array()) ?? []
        for node in elements.prefix(180) {
            for key in ["src", "data-src", "href", "data-url"] {
                if node.hasAttr(key), let raw = try? node.attr(key) {
                    add(raw)
                }
            }
        }
        // Also detect player URLs in inline markup when no iframe element is
        // present, e.g. provider JSON-in-script output.
        let html = page.html.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\/", with: "/")
        let pattern = #"https://(?:www\.)?farsiplex\.com/jwplayer/\?[^\s'\"<>\\]+"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(40) {
                if let range = Range(match.range, in: html) {
                    add(String(html[range]))
                }
            }
        }
        return results
    }

    // Some provider pages publish a relative file URL in a source, link,
    // or data attribute rather than an absolute URL inside player JavaScript.
    private func linkedMP4Streams(in page: PageResponse, source: String) -> [MediaStream] {
        let nodes = (try? page.document.select(
            "a[href], video[src], source[src], iframe[src], [data-src], [data-url]"
        ).array()) ?? []
        var seen = Set<URL>()
        var results: [MediaStream] = []
        for node in nodes {
            for attribute in ["href", "src", "data-src", "data-url"] {
                guard node.hasAttr(attribute),
                      let value = try? node.attr(attribute),
                      let url = absoluteURL(value, base: page.url),
                      url.scheme == "https",
                      url.host?.lowercased() == (source == "FarsiPlex" ? "pl.farsiplex.buzz" : "pl.farsiland.buzz"),
                      url.path.lowercased().hasSuffix(".mp4"),
                      seen.insert(url).inserted else { continue }
                let quality = firstRegexCapture(
                    #"[.-](480|720|1080)(?=(?:\.[^./?]+)*\.mp4)"#, in: url.path
                ).flatMap(Int.init) ?? 720
                results.append(MediaStream(url: url, quality: quality, source: source))
            }
        }
        return results
    }

    private func formFields(_ form: Element) -> [(String, String)] {
        ((try? form.select("input[name]").array()) ?? []).compactMap { input in
            guard let name = try? input.attr("name"), !name.isEmpty else { return nil }
            return (name, (try? input.attr("value")) ?? "")
        }
    }

    private func formAction(_ form: Element, base: URL) -> URL? {
        let action = (try? form.attr("action")) ?? ""
        return absoluteURL(action.isEmpty ? base.absoluteString : action, base: base)
    }

    private func publishedStreams(in html: String, source: String, qualityHint: Int? = nil) -> [MediaStream] {
        let unescaped = html.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
        let pattern = #"https://pl\.(?:farsiland|farsiplex)\.buzz/[^\s'"<>\\]+?\.mp4(?:\?[^\s'"<>\\]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        var urls = Set<URL>()
        return regex.matches(in: unescaped, range: NSRange(unescaped.startIndex..., in: unescaped)).compactMap { match -> MediaStream? in
            guard let range = Range(match.range, in: unescaped),
                  let url = URL(string: String(unescaped[range]).replacingOccurrences(of: "&quot;", with: "")),
                  url.host?.lowercased() == (source == "FarsiPlex" ? "pl.farsiplex.buzz" : "pl.farsiland.buzz"),
                  urls.insert(url).inserted else { return nil }
            let quality = firstRegexCapture(#"[.-](480|720|1080)(?=(?:\.[^./?]+)*\.mp4)"#, in: url.path).flatMap(Int.init)
                ?? qualityHint ?? 720
            return MediaStream(url: url, quality: quality, source: source)
        }
    }
}
