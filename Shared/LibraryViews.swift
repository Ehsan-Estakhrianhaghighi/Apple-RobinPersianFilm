import SwiftUI

struct LibraryRootView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var tab: LibraryTab = .home
    @State private var order: CatalogSort = .newest
    @State private var search = ""

    private var items: [MediaTitle] { store.entries(for: tab, sort: order, query: search) }
    private var columns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: 28), count: 5)
        #else
        [GridItem(.adaptive(minimum: 150, maximum: 225), spacing: 16)]
        #endif
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                #if os(tvOS)
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        ForEach(LibraryTab.allCases) { section in
                            Button {
                                tab = section
                            } label: {
                                Text(section.rawValue)
                                    .font(.headline)
                                    .foregroundStyle(tab == section ? Color.black : Color.white)
                                    .frame(minWidth: 158, minHeight: 46)
                                    .padding(.horizontal, 10)
                                    .background(
                                        tab == section ? Color.yellow : Color.white.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 14)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(section.rawValue)
                            .accessibilityAddTraits(tab == section ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 15)
                }
                #endif
                HStack(spacing: 20) {
                    TextField("Search titles", text: $search)
                        #if os(iOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                        .accessibilityLabel("Search movies and series")
                    Picker("Sort", selection: $order) {
                        ForEach(CatalogSort.allCases) { sort in
                            Text(sort.rawValue).tag(sort)
                        }
                    }
                    #if os(tvOS)
                    .frame(width: 280)
                    #else
                    .frame(maxWidth: 130)
                    #endif
                    Button { Task { await store.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh catalog")
                    .disabled(store.loading)
                }
                .padding(.horizontal)
                if store.loading && store.movies.isEmpty && store.series.isEmpty {
                    ProgressView("Loading catalogs…")
                    Spacer()
                } else if let error = store.error, items.isEmpty {
                    ContentUnavailableView("Catalog unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(items) { item in
                                NavigationLink(value: item) { PosterCard(item: item) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(24)
                    }
                }
            }
            .navigationTitle("RobinPersianFilm")
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Picker("Library", selection: $tab) {
                        ForEach(LibraryTab.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                }
            }
            #endif
            .navigationDestination(for: MediaTitle.self) { item in
                TitleDetailView(item: item)
            }
        }
    }
}

private struct PosterCard: View {
    let item: MediaTitle
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: item.posterURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.gray.opacity(0.3)
                    Image(systemName: "film").font(.largeTitle)
                }
            }
            .aspectRatio(2/3, contentMode: .fit)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(item.title).font(.headline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Text(item.provider.rawValue).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(8)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct TitleDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    let item: MediaTitle
    @State private var episodes: [Episode] = []
    @State private var busy = false
    @State private var episodeError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 26) {
                    AsyncImage(url: item.posterURL) { image in
                        image.resizable().scaledToFit()
                    } placeholder: { Image(systemName: "film").font(.largeTitle) }
                    .frame(maxWidth: 230, maxHeight: 340)
                    VStack(alignment: .leading, spacing: 15) {
                        Text(item.title).font(.largeTitle.bold())
                        Text("\(item.kind == .movie ? "Movie" : "Series") • \(item.provider.rawValue)")
                            .foregroundStyle(.secondary)
                        Button {
                            library.toggleFavorite(item)
                        } label: {
                            Label(library.favorites.contains(item.id) ? "Remove Favorite" : "Add Favorite",
                                  systemImage: library.favorites.contains(item.id) ? "heart.fill" : "heart")
                        }
                        if item.kind == .movie {
                            NavigationLink(destination: PlaybackView(title: item, episode: nil)) {
                                Label("Play Movie", systemImage: "play.fill")
                            }
                        }
                    }
                }
                if item.kind == .series {
                    Text("Episodes").font(.title2.bold())
                    if busy { ProgressView("Loading episodes…") }
                    if let episodeError { Text(episodeError).foregroundStyle(.secondary) }
                    ForEach(episodes) { episode in
                        NavigationLink(destination: PlaybackView(title: item, episode: episode)) {
                            HStack {
                                Label("Season \(episode.season) · \(episode.title)", systemImage: "play.circle")
                                Spacer()
                                Image(systemName: "chevron.right")
                            }.padding(8)
                        }
                    }
                }
            }
            .frame(maxWidth: 1300, alignment: .leading)
            .padding(26)
        }
        .navigationTitle(item.title)
        .task(id: item.pageURL) {
            guard item.kind == .series else { return }
            busy = true
            defer { busy = false }
            do { episodes = try await CatalogService().episodes(for: item) }
            catch { episodeError = error.localizedDescription }
        }
    }
}
