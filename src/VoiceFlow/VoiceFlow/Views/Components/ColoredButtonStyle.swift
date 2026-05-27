import SwiftUI

struct ColoredButtonStyle: ButtonStyle {
    var backgroundColor: Color
    var fixedHeight: CGFloat? = nil
    var fixedWidth: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, fixedHeight == nil ? 8 : 0)
            .padding(.horizontal, fixedWidth == nil ? 16 : 0)
            .frame(width: fixedWidth, height: fixedHeight)
            .background(backgroundColor)
            .foregroundStyle(.white)
            .cornerRadius(10)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}
