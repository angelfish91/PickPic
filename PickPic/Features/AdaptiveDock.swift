import SwiftUI

struct AdaptiveDock: View {
    @Binding var selectedTab: AppTab
    let onSearch: () -> Void
    @Namespace private var selectionGlass

    var body: some View {
        if #available(iOS 26, *) {
            liquidGlassDock
        } else {
            fallbackDock
        }
    }

    @available(iOS 26, *)
    private var liquidGlassDock: some View {
        GlassEffectContainer(spacing: 12) {
            dockContent(usesNativeGlass: true)
                .frame(height: PickPicTheme.dockHeight)
                .padding(.horizontal, PickPicTheme.Spacing.s)
                .glassEffect(
                    .regular
                        .tint(PickPicTheme.surface.opacity(0.18))
                        .interactive(),
                    in: .rect(cornerRadius: 29)
                )
                .shadow(color: .black.opacity(0.15), radius: 24, y: 12)
        }
    }

    private var fallbackDock: some View {
        dockContent(usesNativeGlass: false)
            .frame(height: PickPicTheme.dockHeight)
            .padding(.horizontal, PickPicTheme.Spacing.s)
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

    private func dockContent(usesNativeGlass: Bool) -> some View {
        HStack(spacing: 4) {
            tabButton(.memories, usesNativeGlass: usesNativeGlass)
            tabButton(.library, usesNativeGlass: usesNativeGlass)
            searchButton(usesNativeGlass: usesNativeGlass)
            tabButton(.profile, usesNativeGlass: usesNativeGlass)
        }
    }

    private func tabButton(_ tab: AppTab, usesNativeGlass: Bool) -> some View {
        Button {
            withAnimation(.spring(duration: 0.38, bounce: 0.12)) {
                selectedTab = tab
            }
        } label: {
            ZStack {
                if selectedTab == tab {
                    Capsule()
                        .fill(usesNativeGlass ? PickPicTheme.surface.opacity(0.08) : .clear)
                        .overlay {
                            Capsule()
                                .fill(.white.opacity(usesNativeGlass ? 0.07 : 0.16))
                        }
                        .overlay {
                            Capsule()
                                .stroke(.white.opacity(usesNativeGlass ? 0.24 : 0.52), lineWidth: 0.65)
                        }
                        .matchedGeometryEffect(id: "selection-glass", in: selectionGlass)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 7)
                        .ifAvailableGlassTab(isEnabled: usesNativeGlass)
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

    private func searchButton(usesNativeGlass: Bool) -> some View {
        Button(action: onSearch) {
            ZStack {
                Circle()
                    .fill(usesNativeGlass ? PickPicTheme.ink.opacity(0.66) : .clear)
                if !usesNativeGlass {
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
                }
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 49, height: 49)
            .ifAvailableGlassSearch(isEnabled: usesNativeGlass)
            .shadow(color: .black.opacity(0.18), radius: 12, y: 7)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(LiquidGlassPressStyle())
        .accessibilityLabel("搜索照片")
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

private extension View {
    @ViewBuilder
    func ifAvailableGlassTab(isEnabled: Bool) -> some View {
        if #available(iOS 26, *), isEnabled {
            self.glassEffect(
                .regular
                    .tint(PickPicTheme.surface.opacity(0.20))
                    .interactive(),
                in: .capsule
            )
        } else {
            self.background(.thinMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func ifAvailableGlassSearch(isEnabled: Bool) -> some View {
        if #available(iOS 26, *), isEnabled {
            self.glassEffect(
                .regular
                    .tint(PickPicTheme.ink.opacity(0.48))
                    .interactive(),
                in: .circle
            )
        } else {
            self
        }
    }
}
