import SwiftUI

struct ProfilesView: View {
    @EnvironmentObject var library: LibraryViewModel
    @State private var showPicker = false
    @State private var detail: StoredProfile?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if library.profiles.isEmpty {
                    EmptyState(systemImage: "doc.badge.gearshape",
                               title: "Нет профилей",
                               subtitle: "Импортируйте .mobileprovision для подписи приложений")
                } else {
                    List {
                        ForEach(library.profiles) { p in
                            Button { detail = p } label: { row(p) }.buttonStyle(.plain)
                        }
                        .onDelete { idx in for i in idx { library.delete(library.profiles[i]) } }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Профили")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPicker = true } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.profileType]) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task {
                        if case .failure(let e) = await library.importProfile(from: url) {
                            errorMessage = e.localizedDescription
                        }
                    }
                }
            }
            .sheet(item: $detail) { p in ProfileDetail(profile: p) }
            .alert("Ошибка", isPresented: .init(get: { errorMessage != nil },
                                                set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func row(_ p: StoredProfile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name).font(.body.weight(.semibold))
                Text("\(p.profileType) · \(p.bundlePattern)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if p.isExpired { StatusBadge(kind: .expired) }
        }
    }
}

struct ProfileDetail: View {
    let profile: StoredProfile
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if profile.isExpired {
                        Label("Профиль просрочен — подписание им приведёт к ошибке установки",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.footnote)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(.orange.opacity(0.12)))
                    }
                    VStack(spacing: 10) {
                        KeyValueRow(key: "Name", value: profile.name)
                        KeyValueRow(key: "UUID", value: profile.uuid, mono: true)
                        KeyValueRow(key: "Team ID", value: profile.teamID, mono: true)
                        KeyValueRow(key: "Team Name", value: profile.teamName)
                        KeyValueRow(key: "App ID", value: profile.appID, mono: true)
                        KeyValueRow(key: "Тип", value: profile.profileType)
                        KeyValueRow(key: "Создан", value: profile.createdAt.formatted(date: .abbreviated, time: .omitted))
                        KeyValueRow(key: "Истекает", value: profile.expirationDate.formatted(date: .abbreviated, time: .shortened))
                    }.card()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Entitlements").font(.headline)
                        Text(profile.entitlementsJSON)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }.card()

                    if let devices = try? JSONDecoder().decode([String].self,
                                                               from: Data(profile.devicesJSON.utf8)),
                       !devices.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Устройства (\(devices.count))").font(.headline)
                            ForEach(devices.prefix(20), id: \.self) { d in
                                Text(d).font(.system(.caption2, design: .monospaced))
                            }
                        }.card()
                    }
                }
                .padding(20)
            }
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Готово") { dismiss() } } }
        }
    }
}

struct SignedAppsView: View {
    @EnvironmentObject var library: LibraryViewModel
    var body: some View {
        NavigationStack {
            Group {
                if library.signed.isEmpty {
                    EmptyState(systemImage: "signature",
                               title: "Нет подписанных приложений",
                               subtitle: "Подпишите IPA — результат появится здесь и в разделе «Файлы»")
                } else {
                    List {
                        ForEach(library.signed) { rec in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(rec.name).font(.body.weight(.semibold))
                                KeyValueRow(key: "Bundle", value: rec.bundleID, mono: true)
                                KeyValueRow(key: "Сертификат", value: rec.certLabel)
                                    .font(.caption)
                                KeyValueRow(key: "Профиль", value: rec.profileName).font(.caption)
                                KeyValueRow(key: "Дата", value: rec.signedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                ShareLink(item: URL(fileURLWithPath: rec.fileURL)) {
                                    Label("Экспорт / Поделиться", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(.bordered)
                            }
                            .swipeActions {
                                Button(role: .destructive) { library.delete(rec) } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Подписанные")
        }
    }
}
