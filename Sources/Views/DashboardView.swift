import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var ipaType: UTType { UTType(filenameExtension: "ipa", conformingTo: .data) ?? .data }
    static var p12Type: UTType { UTType(filenameExtension: "p12", conformingTo: .data) ?? .data }
    static var profileType: UTType { UTType(filenameExtension: "mobileprovision", conformingTo: .data) ?? .data }
}

struct DashboardView: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var library: LibraryViewModel
    @Binding var showSettings: Bool
    @State private var showIPAPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    quickActions
                    recentSection
                }
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                }
            }
        }
        .fileImporter(isPresented: $showIPAPicker, allowedContentTypes: [.ipaType]) { result in
            if case .success(let url) = result {
                Task { await library.importIPA(from: url) }
            }
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .init())
        switch h {
        case 5..<12: return "Доброе утро"
        case 12..<18: return "Добрый день"
        default: return "Добрый вечер"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(greeting).font(.title3).foregroundStyle(.secondary)
            Text("IPA Signer").font(.largeTitle.bold())
            Button {
                showIPAPicker = true
            } label: {
                Label("Import IPA", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
        }
    }

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            quick("shippingbox.fill", "Import IPA") { showIPAPicker = true }
            quick("seal.fill", "Certificates") { NotificationCenter.default.post(name: .switchTab, object: 2) }
            quick("doc.badge.gearshape", "Profiles") { NotificationCenter.default.post(name: .switchTab, object: 3) }
            quick("signature", "Signed Apps") { NotificationCenter.default.post(name: .switchTab, object: 4) }
            quick("gearshape.fill", "Settings") { showSettings = true }
        }
    }

    private func quick(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(theme.palette.accent)
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
            }
        }
        .card()
        .buttonStyle(.plain)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Apps").font(.title3.bold())
            if library.ipas.isEmpty {
                EmptyState(systemImage: "shippingbox",
                           title: "Пока пусто",
                           subtitle: "Импортируйте первый .ipa — он появится здесь")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(library.ipas.prefix(6)) { ipa in
                            AppCard(ipa: ipa)
                        }
                    }
                }
            }
        }
    }
}

extension Notification.Name { static let switchTab = Notification.Name("switchTab") }

struct AppCard: View {
    let ipa: ImportedIPA
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            appIcon
            Text(ipa.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("v\(ipa.version) (\(ipa.build))")
                .font(.caption).foregroundStyle(.secondary)
            StatusBadge(kind: .neutral(ipa.isSigned ? "Signed" : "Unsigned"))
        }
        .padding(14)
        .frame(width: 150, alignment: .leading)
        .card()
    }

    @ViewBuilder private var appIcon: some View {
        if let data = ipa.iconData, let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.blue.gradient)
                Text(String(ipa.name.prefix(1)).uppercased())
                    .font(.title2.bold()).foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
        }
    }
}
