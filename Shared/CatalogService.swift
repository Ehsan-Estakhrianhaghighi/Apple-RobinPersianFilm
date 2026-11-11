import Foundation
import SwiftSoup

struct CatalogService {
    private let http = ProviderHTTP.shared

    func loadCatalog(kind: MediaKind) async throws -> [MediaTitle] {
        async let plex = loadProvider(kind: kind, provider: .farsiPlex)
        async let land = loadProvider(kind: kind, provider: .farsiLand)
        let plexTitles = (try? await plex) ?? []
        let landTitles = (try? await land) ?? []
        if plexTitles.isEmpty && landTitles.isEmpty { throw AppProblem.invalidResponse }
        var keys = Set<String>()
        // FarsiPlex wins whenever the normalized title is present on both sites.
        let merged = (plexTitles + landTitles).enumerated().compactMap { index, item -> MediaTitle? in
            let key = "\(kind.rawValue):\(normalizedTitle(item.title))"
            guard keys.insert(key).inserted else { return nil }
            return MediaTitle(title: item.title, pageURL: item.pageURL, posterURL: item.posterURL,
                              kind: item.kind, provider: item.provider, publishedAt: item.publishedAt,
                              rank: index)
        }
        return merged.sorted { a, b in
            let dateA = a.publishedAt ?? .distantPast
            let dateB = b.publishedAt ?? .distantPast
            return dateA == dateB ? a.rank < b.rank : dateA > dateB
        }
    }

    private func loadProvider(kind: MediaKind, provider: Provider) async throws -> [MediaTitle] {
        let prefix = provider == .farsiPlex ? "https://farsiplex.com" : "https://farsiland.com"
        let listing = provider == .farsiPlex ? (kind == .movie ? "/movie/" : "/tvshow/")
            : (kind == .movie ? "/iran-movie-2025/" : "/series-26/")
        var pages = [URL(string: prefix + listing)!]
        if provider == .farsiLand { pages.insert(URL(string: prefix + "/home")!, at: 0) }
        var visited = Set<URL>()
        var titles: [MediaTitle] = []
        while !pages.isEmpty && visited.count < (provider == .farsiPlex ? 8 : 5) {
            let url = pages.removeFirst()
            guard visited.insert(url).inserted else { continue }
            guard let response = try? await http.page(url) else { continue }
            let doc = response.document
            let links = (try? doc.select("a[href]").array()) ?? []
            let expected = provider == .farsiPlex ? (kind == .movie ? "/movie/" : "/tvshow/")
                : (kind == .movie ? "/movies/" : "/tvshows/")
            for link in links {
                guard let href = try? link.attr("href"),
                      let page = absoluteURL(href, base: response.url),
                      page.scheme == "https", page.host == response.url.host,
                      page.path.hasPrefix(expected), page.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != expected.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { continue }
                let heading = try? link.select("h2,h3,h4").first()?.text()
                let img = try? link.select("img").first()
                let title = (heading ?? "").isEmpty
                    ? ((try? link.attr("title")) ?? "").nonEmpty
                        ?? ((try? img?.attr("alt")) ?? "").nonEmpty
                        ?? ((try? link.text()) ?? "")
                    : heading!
                let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, clean.count <= 110 else { continue }
                let posterText = (try? img?.attr("data-src"))?.nonEmpty
                    ?? (try? img?.attr("data-original"))?.nonEmpty
                    ?? (try? img?.attr("src"))?.nonEmpty
                let poster = posterText.flatMap { absoluteURL($0, base: response.url) }
                guard poster != nil || heading != nil else { continue }
                let date = try? link.select("time[datetime], [itemprop=datePublished][content]").first()
                let rawDate = ((try? date?.attr("datetime")) ?? "").nonEmpty
                    ?? ((try? date?.attr("content")) ?? "")
                let published: Date? = rawDate.flatMap {
                    ISO8601DateFormatter().date(from: $0) ?? ISO8601DateFormatter().date(from: String($0.prefix(10)) + "T00:00:00Z")
                }
                let item = MediaTitle(title: clean, pageURL: page, posterURL: poster,
                                      kind: kind, provider: provider, publishedAt: published,
                                      rank: titles.count)
                if let index = titles.firstIndex(where: { $0.pageURL.path == page.path }) {
                    if titles[index].posterURL == nil && poster != nil { titles[index] = item }
                } else { titles.append(item) }
            }
            if url.path != "/home" {
                let nav = (try? doc.select(".pagination a[href], a.page-numbers[href], nav.pagination a[href]").array()) ?? []
                for anchor in nav {
                    if let link = try? anchor.attr("href"), let next = absoluteURL(link, base: response.url),
                       next.host == response.url.host, next.path.hasPrefix(listing),
                       !visited.contains(next), !pages.contains(next) { pages.append(next) }
                }
            }
        }
        return titles
    }

    func episodes(for series: MediaTitle) async throws -> [Episode] {
        let response = try await http.page(series.pageURL)
        let pattern = series.provider == .farsiLand ? "a[href*=/episodes/]" : "a[href*=/episode/]"
        var seen = Set<URL>()
        var entries: [Episode] = []
        for link in (try? response.document.select(pattern).array()) ?? [] {
            guard let href = try? link.attr("href"), let page = absoluteURL(href, base: response.url),
                  page.host == response.url.host, seen.insert(page).inserted else { continue }
            let content = ((try? link.text()) ?? "") + " " + page.path
            let number = firstRegexCapture(#"(?:episode|ep|e)[\s_-]*0*([0-9]+)"#, in: content).flatMap(Int.init)
            let season = firstRegexCapture(#"(?:season|se|s)[\s_-]*0*([0-9]+)"#, in: content).flatMap(Int.init) ?? 1
            guard let number, number > 0 else { continue }
            entries.append(Episode(title: "Episode \(number)", pageURL: page, season: season, number: number))
        }
        return entries.sorted { $0.season == $1.season ? $0.number < $1.number : $0.season < $1.season }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
