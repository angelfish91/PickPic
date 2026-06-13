import SwiftUI

@main
struct PickPicApp: App {
    @StateObject private var photoLibrary = PhotoLibraryStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(photoLibrary)
                .task {
                    await photoLibrary.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    Task {
                        await photoLibrary.handleScenePhase(phase)
                    }
                }
        }
    }
}
