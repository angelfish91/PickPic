import SwiftUI

enum PickPicTheme {
    static let canvas = Color(red: 0.965, green: 0.957, blue: 0.933)
    static let ink = Color(red: 0.075, green: 0.075, blue: 0.07)
    static let secondaryInk = Color(red: 0.38, green: 0.37, blue: 0.34)
    static let hairline = Color.white.opacity(0.46)
    static let dockHeight: CGFloat = 74
}

struct MaterialSurface: ViewModifier {
    var radius: CGFloat
    var shadow: Double = 0.1

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.72), .white.opacity(0.12)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.7
                    )
            }
            .shadow(color: .black.opacity(shadow), radius: 22, y: 10)
    }
}

extension View {
    func materialSurface(radius: CGFloat, shadow: Double = 0.1) -> some View {
        modifier(MaterialSurface(radius: radius, shadow: shadow))
    }
}
