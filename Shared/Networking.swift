import Foundation
import SwiftSoup

struct PageResponse {
    let document: Document
    let url: URL
    let html: String
}

/// Shared session retains cookies between the publisher's POST steps.
actor ProviderHTTP {
    static let shared = ProviderHTTP()
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 22
        config.timeoutIntervalForResource = 35
        session = URLSession(configuration: config)
    }

    private func allowedPage(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return ["farsiplex.com", "www.farsiplex.com", "farsiland.com", "www.farsiland.com",
                "farsiland.buzz", "www.farsiland.buzz"].contains(host)
    }

    func page(_ url: URL, fields: [(String, String)]? = nil, referer: URL? = nil) async throws -> PageResponse {
        guard allowedPage(url) else { throw AppProblem.invalidPage }
        var request = URLRequest(url: url)
        request.timeoutInterval = 22
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        if let fields {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            request.httpBody = fields.map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }.joined(separator: "&").data(using: .utf8)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let finalURL = http.url, allowedPage(finalURL) else { throw AppProblem.invalidResponse }
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
        return PageResponse(document: try SwiftSoup.parse(html, finalURL.absoluteString), url: finalURL, html: html)
    }

    func verifyMP4(_ url: URL) async -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              ["pl.farsiplex.buzz", "pl.farsiland.buzz"].contains(host),
              url.path.lowercased().hasSuffix(".mp4") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.timeoutInterval = 12
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            return (http.statusCode == 200 || http.statusCode == 206) &&
                (type.contains("video") || type.contains("octet-stream"))
        } catch { return false }
    }
}

func absoluteURL(_ text: String, base: URL) -> URL? {
    guard !text.isEmpty else { return nil }
    return URL(string: text, relativeTo: base)?.absoluteURL
}

func hostMatches(_ url: URL, _ domain: String) -> Bool {
    guard let h = url.host?.lowercased() else { return false }
    return h == domain || h == "www.\(domain)"
}

func normalizedTitle(_ value: String) -> String {
    let folded = value.precomposedStringWithCompatibilityMapping.lowercased()
        .replacingOccurrences(of: "ي", with: "ی")
        .replacingOccurrences(of: "ك", with: "ک")
    return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
}

func firstRegexCapture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}
