import AVKit
import SwiftUI

@MainActor
final class PlaybackSession: ObservableObject {
    let player = AVPlayer()
    @Published var streams: [MediaStream] = []
    @Published var selected: MediaStream?
    @Published var loading = false
    @Published var error: String?

    func load(title: MediaTitle, episode: Episode?) async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let values = try await StreamResolver().resolve(title: title, episode: episode)
            streams = values
            if let first = values.first(where: { $0.quality == 720 }) ?? values.first {
                choose(first)
            }
        } catch { self.error = error.localizedDescription }
    }

    func choose(_ stream: MediaStream) {
        guard stream.url != selected?.url else { return }
        let previousTime = player.currentTime()
        let resume = selected != nil && previousTime.isNumeric && previousTime.seconds > 0
        selected = stream
        player.replaceCurrentItem(with: AVPlayerItem(url: stream.url))
        if resume {
            player.seek(to: previousTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
                player?.play()
            }
        } else { player.play() }
    }

    func stop() { player.pause() }
}

struct PlaybackView: View {
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var session = PlaybackSession()
    @State private var fullScreen = false
    let title: MediaTitle
    let episode: Episode?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(episode.map { "\(title.title) · \($0.title)" } ?? title.title)
                    .font(.title.bold())
                if session.loading { ProgressView("Finding verified video streams…") }
                if let error = session.error {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(error).foregroundStyle(.secondary)
                        Text("Some titles require a provider browser session. No unsupported or expired stream is substituted.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Try Again") {
                            Task { await session.load(title: title, episode: episode) }
                        }
                    }
                }
                if !session.streams.isEmpty {
                    Text("Quality").font(.headline)
                    HStack(spacing: 16) {
                        ForEach(session.streams) { stream in
                            Button {
                                session.choose(stream)
                            } label: {
                                HStack {
                                    if session.selected?.url == stream.url { Image(systemName: "checkmark") }
                                    Text("\(stream.quality)p")
                                }
                                .padding(8)
                                .frame(minWidth: 100)
                            }
                            .buttonStyle(.bordered)
                            .tint(session.selected?.url == stream.url ? .yellow : .white)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    Button {
                        fullScreen = true
                    } label: {
                        Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    #if os(tvOS)
                    .buttonStyle(.borderedProminent)
                    #endif
                    NativePlayerView(player: session.player)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16/9, contentMode: .fit)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(maxWidth: 1250, alignment: .leading)
            .padding(28)
        }
        .navigationTitle("RobinPersianFilm Player")
        .task(id: episode?.pageURL ?? title.pageURL) {
            await session.load(title: title, episode: episode)
            if session.selected != nil { library.markWatched(title) }
        }
        .fullScreenCover(isPresented: $fullScreen) {
            FullScreenPlayback(player: session.player)
        }
        .onDisappear { if !fullScreen { session.stop() } }
    }
}

/// AVPlayerViewController supplies the native playback overlay, seek bar,
/// scrubbing and Siri Remote play/pause behavior.
private struct NativePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}

private struct FullScreenPlayback: View {
    @Environment(\.dismiss) private var dismiss
    let player: AVPlayer

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            NativePlayerView(player: player).ignoresSafeArea()
            #if os(iOS)
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.largeTitle)
            }
            .padding(22)
            .accessibilityLabel("Exit Full Screen")
            #endif
        }
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
    }
}
