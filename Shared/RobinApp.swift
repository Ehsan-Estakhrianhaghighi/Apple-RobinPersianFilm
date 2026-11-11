import SwiftUI

@main
struct RobinPersianFilmAppleApp: App {
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        WindowGroup {
            LibraryRootView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Color.yellow)
                .task { await library.refresh() }
        }
    }
}
