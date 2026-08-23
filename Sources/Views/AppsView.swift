import SwiftUI

struct AppsView: View {
    @EnvironmentObject var library: LibraryViewModel
    @State private var showPicker = false
    @State private var detail: ImportedIPA?

    var body: some View {
        NavigationStack {
            Group {
                if library.ipas.isEmpty {
                    EmptyState(systemImage: "shippingbox", title: "Нет импортированных IPA",
                               subtitle: "Нажмите «Импорт», чтобы добавить первый файл")
                } else {
                    List {
                        ForEach(library.ipas) { ipa in
                            Button { detail = ipa } label: { row(ipa) }
                                .buttonStyle(.plain)
                        }
                        .onDelete { idx in
                            for i in idx { library.delete(library.ipas[i]) }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("IPA")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPicker = true } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .sheet(item: $detail) { ipa in AppDetailView(ipa: ipa) }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.ipaType]) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task { await library.importIPA(from: url) }
                }
            }
        }
    }

    private func row(_ ipa: ImportedIPA) -> some View {
        HStack(spacing: 14) {
            AppCardIconOnly(ipa: ipa)
            VStack(alignment: .leading, spacing: 3) {
                Text(ipa.name).font(.body.weight(.semibold))
                Text("\(ipa.bundleID)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(kind: .neutral(ipa.isSigned ? "Signed" : "Unsigned"))
        }
        .padding(.vertical, 4)
    }
}

struct AppCardIconOnly: View {
    let ipa: ImportedIPA
    var body: some View {
        if let data = ipa.iconData, let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, continuous: true))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.indigo.gradient)
                Text(String(ipa.name.prefix(1)).uppercased()).font(.headline).foregroundStyle(.white)
            }.frame(width: 44, height: 44)
        }
    }
}

struct AppDetailView: View {
    @EnvironmentObject var library: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    let ipa: ImportedIPA
    @State private var showSign = false
    @State private var showExplorer = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        AppCardIconOnly(ipa: ipa).scaleEffect(1.3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ipa.name).font(.title2.bold())
                            Text("v\(ipa.version) (\(ipa.build))").foregroundStyle(.secondary)
                            StatusBadge(kind: .neutral(ipa.isSigned ? "Signed" : "Unsigned"))
                        }
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))

                    VStack(spacing: 10) {
                        KeyValueRow(key: "Bundle ID", value: ipa.bundleID, mono: true)
                        Divider()
                        KeyValueRow(key: "Minimum OS", value: ipa.minOS)
                        KeyValueRow(key: "Архитектуры", value: ipa.architectures)
                        KeyValueRow(key: "Frameworks", value: ipa.hasFrameworks ? "есть" : "нет")
                        KeyValueRow(key: "PlugIns/Extensions", value: ipa.hasPlugIns ? "есть" : "нет")
                        KeyValueRow(key: "embedded.mobileprovision", value: ipa.hasProfile ? "есть" : "нет")
                        KeyValueRow(key: "Размер", value: BytesFmt.string(ipa.sizeBytes))
                    }
                    .card()

                    VStack(spacing: 12) {
                        Button {
                            showSign = true
                        } label: {
                            Label("Подписать IPA", systemImage: "signature")
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            showExplorer = true
                        } label: {
                            Label("IPA Explorer", systemImage: "folder")
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        Button(role: .destructive) {
                            library.delete(ipa)
                            dismiss()
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Информация")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } } }
            .sheet(isPresented: $showExplorer) { ExplorerView(appDir: URL(fileURLWithPath: ipa.extractDirURL)) }
            .sheet(isPresented: $showSign) { SignFlowView(ipa: ipa) }
        }
    }
}
