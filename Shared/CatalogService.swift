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
            let invalidTitles: Set<String> = ["genres", "genre", "all genres", "movies", "movie",
                "series", "tv shows", "tv show", "play", "view", "more", "watch", "home", "browse"]
            for link in links {
                guard let href = try? link.attr("href"),
                      let page = absoluteURL(href, base: response.url),
                      page.scheme == "https", hostMatches(page, provider == .farsiPlex ? "farsiplex.com" : "farsiland.com"),
                      page.path.hasPrefix(expected),
                      page.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) !=
                      expected.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { continue }

                // Provider card titles and images can be on the link or on a nearby ancestor.
                let parent = link.parent()
                let grandparent = parent?.parent()
                let greatGrandparent = grandparent?.parent()
                let ownHeading: String? = try? link.select("h2,h3,h4").first()?.text()
                let parentHeading: String? = try? parent?.select("h2,h3,h4").first()?.text()
                let grandHeading: String? = try? grandparent?.select("h2,h3,h4").first()?.text()
                let ownImage: Element? = try? link.select("img").first()
                let parentImage: Element? = try? parent?.select("img").first()
                let grandImage: Element? = try? grandparent?.select("img").first()
                let greatImage: Element? = try? greatGrandparent?.select("img").first()
                let image = ownImage ?? parentImage ?? grandImage ?? greatImage
                let titleHeading = ownHeading?.nonEmpty ?? parentHeading?.nonEmpty ?? grandHeading?.nonEmpty
                let attrTitle: String = (try? link.attr("title")) ?? ""
                let textTitle: String = (try? link.text()) ?? ""
                let altTitle: String = (try? image?.attr("alt")) ?? ""
                let rawTitle: String = titleHeading ?? attrTitle.nonEmpty
                    ?? textTitle.nonEmpty ?? altTitle.nonEmpty ?? ""
                let clean = rawTitle.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                let slug: String = page.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    .split(separator: "/").last.map(String.init) ?? ""
                guard !clean.isEmpty, clean.count <= 110,
                      !invalidTitles.contains(clean.lowercased()),
                      !invalidTitles.contains(slug.lowercased()) else { continue }
                guard titleHeading != nil || image != nil else { continue }

                var poster: URL?
                if let image {
                    for attribute in ["data-src", "data-lazy-src", "data-original", "data-srcset", "srcset", "src"] {
                        let raw: String = (try? image.attr(attribute)) ?? ""
                        guard !raw.isEmpty, !raw.hasPrefix("data:") else { continue }
                        let firstSrcset: String = raw.components(separatedBy: ",").first ?? ""
                        let candidate: String = firstSrcset.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                            .components(separatedBy: " ").first ?? ""
                        if let resolved = absoluteURL(candidate, base: response.url), resolved.scheme == "https" {
                            poster = resolved
                            break
                        }
                    }
                }
                let dateNode: Element? = try? parent?.select("time[datetime], [itemprop=datePublished][content]").first()
                let dateValue: String = (try? dateNode?.attr("datetime")) ?? ""
                let dateContent: String = (try? dateNode?.attr("content")) ?? ""
                let rawDate: String? = dateValue.nonEmpty ?? dateContent.nonEmpty
                let published: Date? = rawDate.flatMap { dateString in
                    ISO8601DateFormatter().date(from: dateString)
                        ?? ISO8601DateFormatter().date(from: String(dateString.prefix(10)) + "T00:00:00Z")
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
