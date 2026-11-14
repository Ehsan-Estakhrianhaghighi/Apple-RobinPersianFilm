import Foundation
import SwiftUI

enum Provider: String, Codable, Sendable {
    case farsiPlex = "FarsiPlex"
    case farsiLand = "FarsiLand"
}
enum MediaKind: String, Codable, Sendable {
    case movie, series
}
struct MediaTitle: Identifiable, Hashable, Codable, Sendable {
    let title: String
    let pageURL: URL
    let posterURL: URL?
    let kind: MediaKind
    let provider: Provider
    let publishedAt: Date?
    let rank: Int
    var id: String { pageURL.absoluteString }
}
struct Episode: Identifiable, Hashable, Sendable {
    let title: String
    let pageURL: URL
    let season: Int
    let number: Int
    var id: String { pageURL.absoluteString }
}
struct MediaStream: Identifiable, Hashable, Sendable {
    let url: URL
    let quality: Int
    let source: String
    var id: String { url.absoluteString }
}
enum CatalogSort: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case alphabetical = "A–Z"
    var id: String { rawValue }
}
enum LibraryTab: String, CaseIterable, Identifiable {
    case home = "Home", movies = "Movies", series = "Series", favorites = "Favorites", history = "History"
    var id: String { rawValue }
}
enum AppProblem: LocalizedError {
    case invalidPage, noStream, invalidResponse, browserPlaybackRequired
    var errorDescription: String? {
        switch self {
        case .invalidPage: "The provider page could not be read."
        case .noStream: "No authorized playable stream was found for this title."
        case .invalidResponse: "The provider returned an unexpected response."
        case .browserPlaybackRequired: "FarsiPlex did not publish a verified stream or a title-specific native player route. This title may require an interactive browser session, which tvOS does not support."
        }
    }
}

@MainActor final class LibraryStore: ObservableObject {
    @Published var movies: [MediaTitle] = []
    @Published var series: [MediaTitle] = []
    @Published var loading = false
    @Published var error: String?
    @Published var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
    @Published var watched: [String] = UserDefaults.standard.stringArray(forKey: "watched") ?? []

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let service = CatalogService()
            async let m = service.loadCatalog(kind: .movie)
            async let s = service.loadCatalog(kind: .series)
            movies = try await m
            series = try await s
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func entries(for tab: LibraryTab, sort: CatalogSort, query: String) -> [MediaTitle] {
        let all = movies + series
        let candidates: [MediaTitle]
        switch tab {
        case .home: candidates = all
        case .movies: candidates = movies
        case .series: candidates = series
        case .favorites: candidates = all.filter { favorites.contains($0.id) }
        case .history: candidates = watched.compactMap { id in all.first { $0.id == id } }
        }
        let filtered = candidates.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        if tab == .history { return filtered }
        switch sort {
        case .alphabetical:
            return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .newest:
            return filtered.sorted {
                let first = $0.publishedAt ?? .distantPast, second = $1.publishedAt ?? .distantPast
                return first == second ? $0.rank < $1.rank : first > second
            }
        }
    }
    func toggleFavorite(_ item: MediaTitle) {
        if !favorites.insert(item.id).inserted { favorites.remove(item.id) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
    }
    func markWatched(_ item: MediaTitle) {
        watched.removeAll { $0 == item.id }
        watched.insert(item.id, at: 0)
        watched = Array(watched.prefix(80))
        UserDefaults.standard.set(watched, forKey: "watched")
    }
}
