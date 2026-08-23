import SwiftUI

struct RootView: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var library: LibraryViewModel
    @State private var tab = 0
    @State private var showSettings = false

    var body: some View {
        ZStack {
            switch theme.theme {
            case .starry:
                StarryBackground()
            default:
                theme.palette.background.ignoresSafeArea()
            }
            TabView(selection: $tab) {
                DashboardView(showSettings: $showSettings)
                    .tabItem { Label("Главная", systemImage: "house.fill") }.tag(0)
                AppsView()
                    .tabItem { Label("IPA", systemImage: "shippingbox.fill") }.tag(1)
                CertificatesView()
                    .tabItem { Label("Сертификаты", systemImage: "checkmark.seal.fill") }.tag(2)
                ProfilesView()
                    .tabItem { Label("Профили", systemImage: "doc.badge.gearshape.fill") }.tag(3)
                SignedAppsView()
                    .tabItem { Label("Подписанные", systemImage: "signature") }.tag(4)
            }
            .scrollContentBackground(.hidden)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onReceive(NotificationCenter.default.publisher(for: .switchTab)) { n in
            if let t = n.object as? Int { tab = t }
        }
        .onAppear { Shared.library = library }
        .tint(theme.palette.accent)
    }
}
