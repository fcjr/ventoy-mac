import SwiftUI

enum Theme {
    static let bezel = Color(hex: 0x0F1317)
    static let panel = Color(hex: 0x161B21)
    static let well = Color(hex: 0x0B0E11)
    static let hairline = Color(hex: 0x262E37)
    static let ink = Color(hex: 0xE6EDF3)
    static let dim = Color(hex: 0x7C8894)
    static let phosphor = Color(hex: 0xFFB454)
    static let steel = Color(hex: 0x4E7E9E)
    static let danger = Color(hex: 0xE5484D)
    static let ok = Color(hex: 0x58B382)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.mono(10, .semibold))
            .tracking(1.6)
            .foregroundStyle(Theme.dim)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }
    private struct Styled: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.88))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.phosphor.opacity(configuration.isPressed ? 0.7 : 1))
                )
                .opacity(isEnabled ? 1 : 0.35)
        }
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }
    private struct Styled: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(configuration.isPressed ? 0.6 : 1))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
                .opacity(isEnabled ? 1 : 0.35)
        }
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.mono(12))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hairline, lineWidth: 1))
    }
}
