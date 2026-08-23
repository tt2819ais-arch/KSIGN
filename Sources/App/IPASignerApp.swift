import SwiftUI
import SwiftData

@main
struct IPASignerApp: App {
    let container: ModelContainer
    @StateObject private var theme = ThemeManager()
    @StateObject private var library = LibraryViewModel()

    init() {
        do {
            container = try ModelContainer(for: ImportedIPA.self, StoredCertificate.self,
                                           StoredProfile.self, SignedAppRecord.self)
        } catch {
            fatalError("ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(theme)
                .environmentObject(library)
                .environment(\.modelContext, container.mainContext)
                .onAppear { library.attach(context: container.mainContext) }
                .preferredColorScheme(theme.theme == .white ? .light : .dark)
        }
    }
}
