import SwiftUI

struct CertificatesView: View {
    @EnvironmentObject var library: LibraryViewModel
    @State private var showPicker = false
    @State private var pendingP12: URL?
    @State private var password = ""
    @State private var showPasswordSheet = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if library.certificates.isEmpty {
                    EmptyState(systemImage: "checkmark.seal",
                               title: "Нет сертификатов",
                               subtitle: "Импортируйте .p12 — ключ будет сохранён в Keychain устройства")
                } else {
                    List {
                        ForEach(library.certificates) { cert in
                            CertificateCard(cert: cert)
                                .swipeActions {
                                    Button(role: .destructive) { library.delete(cert) } label: {
                                        Label("Удалить", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Сертификаты")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPicker = true } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.p12Type]) { result in
                if case .success(let url) = result {
                    pendingP12 = url
                    showPasswordSheet = true
                }
            }
            .sheet(isPresented: $showPasswordSheet) {
                PasswordSheet(password: $password) {
                    if let url = pendingP12 {
                        switch library.importCertificate(p12URL: url, password: password) {
                        case .success: break
                        case .failure(let e): errorMessage = e.localizedDescription
                        }
                    }
                    password = ""
                }
            }
            .alert("Ошибка импорта", isPresented: .init(get: { errorMessage != nil },
                                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }
}

struct PasswordSheet: View {
    @Binding var password: String
    let onSubmit: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                SecureField("Пароль .p12", text: $password)
                Section {
                    Text("Пароль используется однократно для расшифровки контейнера и не сохраняется.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Пароль сертификата")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Импортировать") { dismiss(); onSubmit() }.disabled(password.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct CertificateCard: View {
    let cert: StoredCertificate
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(cert.label).font(.headline).lineLimit(1)
                Spacer()
                StatusBadge(kind: cert.status == .valid ? .valid :
                            cert.status == .expiringSoon ? .expiring : .expired)
            }
            VStack(spacing: 6) {
                KeyValueRow(key: "Тип", value: cert.certType)
                KeyValueRow(key: "Team ID", value: cert.teamID, mono: true)
                KeyValueRow(key: "Действует до",
                            value: cert.notAfter.formatted(date: .abbreviated, time: .omitted))
                KeyValueRow(key: "Осталось дней", value: "\(max(cert.daysLeft, 0))")
                KeyValueRow(key: "Приватный ключ", value: cert.hasPrivateKey ? "есть (Keychain)" : "нет")
                KeyValueRow(key: "Serial", value: cert.serialHex, mono: true)
            }
            .font(.caption)
        }
        .padding(.vertical, 6)
    }
}
