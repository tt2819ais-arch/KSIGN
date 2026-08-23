import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case black, white, starry
    var id: String { rawValue }
    var title: String { switch self { case .black: "Black"; case .white: "White"; case .starry: "Starry" } }
}

struct Palette {
    let background: Color
    let card: Color
    let stroke: Color
    let text: Color
    let secondary: Color
    let accent: Color
    let accent2: Color
    let translucentCards: Bool
}

final class ThemeManager: ObservableObject {
    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "app.theme") }
    }
    init() {
        self.theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "app.theme") ?? "") ?? .black
    }

    var palette: Palette {
        switch theme {
        case .black:
            Palette(background: Color(red: 0.04, green: 0.04, blue: 0.05),
                    card: Color(red: 0.09, green: 0.09, blue: 0.11),
                    stroke: .white.opacity(0.07),
                    text: .primary, secondary: .secondary,
                    accent: Color(red: 0.45, green: 0.5, blue: 1.0),
                    accent2: Color(red: 0.6, green: 0.45, blue: 1.0),
                    translucentCards: false)
        case .white:
            Palette(background: Color(red: 0.95, green: 0.96, blue: 0.97),
                    card: .white,
                    stroke: .black.opacity(0.08),
                    text: .primary, secondary: .secondary,
                    accent: .blue, accent2: .indigo,
                    translucentCards: false)
        case .starry:
            Palette(background: .black,
                    card: .black.opacity(0.55),
                    stroke: .white.opacity(0.12),
                    text: .primary, secondary: .secondary,
                    accent: Color(red: 0.55, green: 0.65, blue: 1.0),
                    accent2: Color(red: 0.75, green: 0.6, blue: 1.0),
                    translucentCards: true)
        }
    }
}

struct CardStyle: ViewModifier {
    @EnvironmentObject var theme: ThemeManager
    func body(content: Content) -> some View {
        let p = theme.palette
        content
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(p.card)
                    .shadow(color: .black.opacity(theme.theme == .white ? 0.06 : 0.35), radius: 12, y: 4)
            )
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(p.stroke, lineWidth: 1))
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}
