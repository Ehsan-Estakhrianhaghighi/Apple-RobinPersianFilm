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
        return try await resolveFarsiPlex(pageURL: target)
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
        if streams.isEmpty {
            // Only follow player links actually published by the selected title.
            let nodes = (try? first.document.select("a[href], iframe[src]").array()) ?? []
            for node in nodes.prefix(120) {
                let raw = (try? node.attr(node.tagName() == "iframe" ? "src" : "href")) ?? ""
                guard let url = absoluteURL(raw, base: first.url), hostMatches(url, "farsiplex.com"),
                      url.path.contains("play-") else { continue }
                guard let page = try? await http.page(url, referer: first.url) else { continue }
                streams = publishedStreams(in: page.html, source: "FarsiPlex")
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
