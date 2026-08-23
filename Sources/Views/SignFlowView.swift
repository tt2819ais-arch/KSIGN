import SwiftUI
import PhotosUI

struct SignFlowView: View {
    @EnvironmentObject var library: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: SignViewModel
    @State private var photoItem: PhotosPickerItem?

    init(ipa: ImportedIPA) {
        // library внедряется в onAppear через environment — создаём VM лениво нельзя,
        // поэтому используем общий singleton-паттерн через EnvironmentObject в body.
        guard let lib = Shared.library else {
            fatalError("LibraryViewModel не инициализирован")
        }
        _vm = StateObject(wrappedValue: SignViewModel(library: lib, ipa: ipa))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch vm.phase {
                    case .idle, .checking, .ready: configuration
                    case .signing: signingScreen
                    case .done(let url): result(url)
                    case .failed(let msg): failure(msg)
                    case .cancelled:
                        VStack(spacing: 12) {
                            Image(systemName: "xmark.circle").font(.system(size: 60)).foregroundStyle(.orange)
                            Text("Отменено").font(.headline)
                        }.frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Sign IPA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(vm.phase == .signing ? "Отменить" : "Закрыть") {
                        if vm.phase == .signing { /* отмена через отмену Task — упрощённо */ }
                        dismiss()
                    }
                }
            }
            .task { await vm.runPreflight() }
            .photosPicker(isPresented: .constant(photoItem == nil && showPhotoPickerFlag),
                          selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let img = try? await item.loadTransferable(type: UIImage.self) {
                        vm.iconImage = img
                    }
                }
            }
        }
        .onAppear { Shared.library = library }
    }

    // вспомогательный флаг для photosPicker
    @State private var showPhotoPickerFlag = false

    // MARK: Экран конфигурации

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 20) {
            Menu {
                ForEach(library.certificates) { c in
                    Button(c.label) { vm.selectedCert = c; Task { await vm.runPreflight() } }
                }
            } label: {
                selectorRow(icon: "seal.fill",
                            title: vm.selectedCert?.label ?? "Выбрать сертификат",
                            subtitle: vm.selectedCert.map { "\($0.certType) · до \($0.notAfter.formatted(date: .abbreviated, time: .omitted))" } ?? ".p12")
            }

            Menu {
                ForEach(library.profiles) { p in
                    Button(p.name) { vm.selectedProfile = p; Task { await vm.runPreflight() } }
                }
            } label: {
                selectorRow(icon: "doc.badge.gearshape",
                            title: vm.selectedProfile?.name ?? "Выбрать профиль",
                            subtitle: vm.selectedProfile.map { "\($0.profileType) · \($0.bundlePattern)" } ?? ".mobileprovision")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Проверки перед подписью").font(.headline)
                ForEach(vm.checks) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.passed == true ? "checkmark.circle.fill" :
                                item.passed == false ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(item.passed == true ? .green :
                                                item.passed == false ? .red : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.subheadline.weight(.medium))
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.card()

            VStack(alignment: .leading, spacing: 14) {
                Text("Настройки приложения").font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    Text("App Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Имя приложения", text: $vm.appName)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bundle Identifier").font(.caption).foregroundStyle(.secondary)
                    TextField("Bundle ID", text: $vm.bundleID)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("Меняйте, только если профиль покрывает новый идентификатор.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                HStack(spacing: 14) {
                    iconPreview
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Изменить иконку", systemImage: "photo")
                    }
                    .buttonStyle(.bordered)
                }
            }.card()

            Button {
                vm.startSigning()
            } label: {
                Label("Начать подписание", systemImage: "signature")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!vm.canSign)
            .clipShape(Capsule())
        }
    }

    @ViewBuilder private var iconPreview: some View {
        if let img = vm.iconImage {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 11))
        } else {
            RoundedRectangle(cornerRadius: 11).fill(.gray.opacity(0.2))
                .frame(width: 48, height: 48)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    private func selectorRow(icon: String, title: String, subtitle: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.tertiary)
        }
        .card()
    }

    // MARK: Экран подписи

    private var signingScreen: some View {
        VStack(spacing: 20) {
            ProgressRing(progress: vm.progress)
            Text(vm.phaseTitle).font(.headline)
            ConsoleView(lines: vm.logLines).frame(height: 260)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Результат

    private func result(_ url: URL) -> some View {
        VStack(spacing: 20) {
            SuccessCheck()
            Text("Подписание завершено").font(.title2.bold())
            Text(BytesFmt.string(StorageManager.shared.size(of: url)))
                .foregroundStyle(.secondary)
            ShareLink(item: url) {
                Label("Экспортировать IPA", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            Button("Готово") { dismiss() }
            Text("Установка подписанного IPA выполняется вне этого приложения: используйте Finder (Mac), Apple Configurator или AltStore.")
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func failure(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 56)).foregroundStyle(.red)
            Text("Ошибка подписи").font(.title2.bold())
            ErrorCard(message: msg, logTail: vm.logLines)
            Button("Повторить проверку") { Task { await vm.runPreflight() } }
                .buttonStyle(.bordered)
        }
    }
}

/// Простейший DI-контейнер для передачи LibraryViewModel в sheets.
enum Shared {
    nonisolated(unsafe) static weak var library: LibraryViewModel?
}
