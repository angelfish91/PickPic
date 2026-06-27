import SwiftUI

enum AppTab: String, CaseIterable {
    case memories = "回忆"
    case library = "图库"
    case profile = "我的"

    var icon: String {
        switch self {
        case .memories: "sparkles.rectangle.stack"
        case .library: "square.grid.2x2"
        case .profile: "person"
        }
    }

    var selectedIcon: String {
        switch self {
        case .memories: "sparkles.rectangle.stack.fill"
        case .library: "square.grid.2x2.fill"
        case .profile: "person.fill"
        }
    }
}

struct RootView: View {
    let photoLibrary: PhotoLibraryStore
    @State private var selectedTab: AppTab = .memories
    @State private var searchPresented = false

    var body: some View {
        ZStack(alignment: .bottom) {
            PickPicTheme.canvas.ignoresSafeArea()

            Group {
                switch selectedTab {
                case .memories:
                    MemoriesView(photoLibrary: photoLibrary, onSearch: { searchPresented = true })
                case .library:
                    LibraryView(photoLibrary: photoLibrary)
                case .profile:
                    ProfileView(photoLibrary: photoLibrary)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 29, style: .continuous)
                    .fill(.clear)
                    .contentShape(RoundedRectangle(cornerRadius: 29, style: .continuous))
                    .onTapGesture {}

                AdaptiveDock(selectedTab: $selectedTab, onSearch: { searchPresented = true })
            }
                .frame(height: PickPicTheme.dockHeight)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .zIndex(100)

            LaunchPreparationOverlay(photoLibrary: photoLibrary)
                .zIndex(200)
        }
        .animation(.easeOut(duration: 0.35), value: photoLibrary.isPreparingInitialMemories)
        .tint(PickPicTheme.ink)
        .sheet(isPresented: $searchPresented) {
            SearchView(photoLibrary: photoLibrary)
                .presentationBackground(.clear)
                .presentationDetents([.large])
        }
    }
}

private struct LaunchPreparationOverlay: View {
    @ObservedObject var photoLibrary: PhotoLibraryStore

    var body: some View {
        if photoLibrary.isPreparingInitialMemories {
            LaunchPreparationView(status: photoLibrary.launchPreparationStatus)
                .transition(.opacity)
                .zIndex(10)
        }
    }
}

private struct LaunchPreparationView: View {
    let status: String

    var body: some View {
        ZStack {
            PickPicTheme.canvas.ignoresSafeArea()

            Circle()
                .fill(.white.opacity(0.55))
                .frame(width: 340, height: 340)
                .blur(radius: 3)

            VStack(spacing: 18) {
                PickPicBrandMark(size: 92, cornerRadius: 30, showsShadow: true)

                Text("PickPic")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .foregroundStyle(PickPicTheme.ink)

                ProgressView()
                    .controlSize(.small)
                    .tint(PickPicTheme.ink)
                    .padding(.top, 10)

                Text(status)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(PickPicTheme.secondaryInk)
            }
        }
    }
}
