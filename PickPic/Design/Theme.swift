import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum PickPicTheme {
    static let canvas = adaptive(light: RGB(0.965, 0.957, 0.933), dark: RGB(0.118, 0.114, 0.104))
    static let surface = adaptive(light: RGB(1, 0.992, 0.965), dark: RGB(0.165, 0.157, 0.145))
    static let surfaceRaised = adaptive(light: RGB(1, 1, 0.985), dark: RGB(0.205, 0.197, 0.180))
    static let ink = adaptive(light: RGB(0.075, 0.075, 0.07), dark: RGB(0.945, 0.925, 0.875))
    static let secondaryInk = adaptive(light: RGB(0.38, 0.37, 0.34), dark: RGB(0.705, 0.680, 0.620))
    static let accent = adaptive(light: RGB(0.62, 0.31, 0.18), dark: RGB(0.86, 0.58, 0.38))
    static let accentWash = adaptive(light: RGB(0.945, 0.825, 0.695), dark: RGB(0.315, 0.205, 0.155))
    static let hairline = adaptive(light: RGB(1, 1, 1), dark: RGB(0.35, 0.33, 0.30)).opacity(0.46)
    static let dockHeight: CGFloat = 74

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 28
    }

    enum AppFont {
        static let display = Font.system(size: 36, weight: .semibold, design: .serif)
        static let heading = Font.system(size: 21, weight: .semibold, design: .rounded)
        static let subheading = Font.system(size: 15, weight: .semibold)
        static let caption = Font.system(size: 12, weight: .semibold)
        static let micro = Font.system(size: 11, weight: .medium)
    }

    private struct RGB {
        let red: Double
        let green: Double
        let blue: Double

        init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    private static func adaptive(light: RGB, dark: RGB) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: value.red, green: value.green, blue: value.blue, alpha: 1)
        })
        #else
        Color(red: light.red, green: light.green, blue: light.blue)
        #endif
    }
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
