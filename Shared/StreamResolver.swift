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
            // A matching FarsiLand listing can be used solely as the backup player.
            // The catalog still shows the preferred FarsiPlex entry once.
            guard let fallback = await CatalogService().farsiLandFallback(for: title) else { throw error }
            if let episode {
                let options = (try? await CatalogService().episodes(for: fallback)) ?? []
                guard let alternative = options.first(where: {
                    $0.season == episode.season && $0.number == episode.number
                }) else { throw error }
                return try await resolveFarsiLand(pageURL: alternative.pageURL)
            }
            return try await resolveFarsiLand(pageURL: fallback.pageURL)
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

    private func resolveFarsiPlex(pageURL: URL) async throws -> [MediaStream] {
        let first = try await http.page(pageURL)
        var streams = publishedStreams(in: first.html, source: "FarsiPlex")
        streams += linkedMP4Streams(in: first, source: "FarsiPlex")
        if streams.isEmpty {
            // Visit player pages published by this title. A generic player page
            // without title-specific context cannot identify which movie to load.
            let nodes = (try? first.document.select("a[href], iframe[src], [data-href], [data-url]").array()) ?? []
            var visited = Set<URL>()
            for node in nodes.prefix(180) {
                let attribute = node.tagName() == "iframe" ? "src"
                    : (node.hasAttr("href") ? "href" : (node.hasAttr("data-href") ? "data-href" : "data-url"))
                let raw = (try? node.attr(attribute)) ?? ""
                guard let url = absoluteURL(raw, base: first.url),
                      hostMatches(url, "farsiplex.com"),
                      url.path.contains("play-") || url.path.contains("/watch/"),
                      visited.insert(url).inserted else { continue }
                // Without a query or dedicated player slug, this route can be a
                // shared landing page requiring an interactive browser session.
                let hasContext = url.query != nil ||
                    url.path.split(separator: "/").count > 1 ||
                    node.tagName() == "iframe"
                guard hasContext else { continue }
                guard let page = try? await http.page(url, referer: first.url) else { continue }
                streams += publishedStreams(in: page.html, source: "FarsiPlex")
                streams += linkedMP4Streams(in: page, source: "FarsiPlex")
                if !streams.isEmpty { break }
            }
        }
        // MP4 quality variants can use suffixes like "-720.new.mp4".
        let current = streams
        for stream in current {
            let raw = stream.url.absoluteString
            let pattern = #"[.-](360|480|720|1080)(?=(?:\.[^./?]+)*\.mp4)"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let range = Range(match.range(at: 1), in: raw) else { continue }
            for quality in [480, 720, 1080] where quality != stream.quality {
                var changed = raw
                changed.replaceSubrange(range, with: String(quality))
                if let url = URL(string: changed),
                   !streams.contains(where: { $0.url == url }),
                   await http.verifyMP4(url) {
                    streams.append(MediaStream(url: url, quality: quality, source: stream.source))
                }
            }
        }
        var valid: [MediaStream] = []
        for stream in streams where !valid.contains(where: { $0.url == stream.url }) {
            if await http.verifyMP4(stream.url) { valid.append(stream) }
        }
        guard !valid.isEmpty else { throw AppProblem.noStream }
        return valid.sorted { $0.quality < $1.quality }
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
                      ["pl.farsiplex.buzz", "pl.farsiland.buzz"].contains(url.host?.lowercased() ?? ""),
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
                  urls.insert(url).inserted else { return nil }
            let quality = firstRegexCapture(#"[.-](480|720|1080)(?=(?:\.[^./?]+)*\.mp4)"#, in: url.path).flatMap(Int.init)
                ?? qualityHint ?? 720
            return MediaStream(url: url, quality: quality, source: source)
        }
    }
}
