import SwiftUI

struct AdaptiveDock: View {
    @Binding var selectedTab: AppTab
    let onSearch: () -> Void
    @Namespace private var selectionGlass

    var body: some View {
        HStack(spacing: 4) {
            tabButton(.memories)
            tabButton(.library)

            Button(action: onSearch) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                    Circle()
                        .fill(PickPicTheme.ink.opacity(0.58))
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.82), .white.opacity(0.16)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 49, height: 49)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 7)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LiquidGlassPressStyle())
            .accessibilityLabel("搜索照片")

            tabButton(.profile)
        }
        .frame(height: PickPicTheme.dockHeight)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 29, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 29, style: .continuous)
                        .fill(.white.opacity(0.055))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 29, style: .continuous)
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.86), location: 0),
                            .init(color: .white.opacity(0.22), location: 0.42),
                            .init(color: .white.opacity(0.08), location: 1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(.white.opacity(0.34))
                .frame(width: 124, height: 1)
                .blur(radius: 0.4)
                .offset(y: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 24, y: 12)
    }

    private func tabButton(_ tab: AppTab) -> some View {
        Button {
            withAnimation(.spring(duration: 0.38, bounce: 0.12)) {
                selectedTab = tab
            }
        } label: {
            ZStack {
                if selectedTab == tab {
                    Capsule()
                        .fill(.thinMaterial)
                        .overlay {
                            Capsule()
                                .fill(.white.opacity(0.16))
                        }
                        .overlay {
                            Capsule()
                                .stroke(.white.opacity(0.52), lineWidth: 0.65)
                        }
                        .matchedGeometryEffect(id: "selection-glass", in: selectionGlass)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 7)
                }

                VStack(spacing: 5) {
                    Image(systemName: selectedTab == tab ? tab.selectedIcon : tab.icon)
                        .font(.system(size: 19, weight: selectedTab == tab ? .semibold : .regular))
                        .symbolEffect(.bounce, value: selectedTab == tab)
                    Text(tab.rawValue)
                        .font(.system(size: 10.5, weight: selectedTab == tab ? .semibold : .medium))
                }
                .foregroundStyle(PickPicTheme.ink.opacity(selectedTab == tab ? 0.92 : 0.54))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(LiquidGlassPressStyle())
    }
}

private struct LiquidGlassPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
