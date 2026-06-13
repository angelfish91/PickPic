import SwiftUI

struct PickPicBrandMark: View {
    var size: CGFloat
    var cornerRadius: CGFloat
    var showsShadow = false

    var body: some View {
        Image("PickPicBrandIcon")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 0.6)
            }
            .shadow(
                color: showsShadow ? .black.opacity(0.2) : .clear,
                radius: showsShadow ? 24 : 0,
                y: showsShadow ? 12 : 0
            )
            .accessibilityHidden(true)
    }
}
