import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var library: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var usage: Int64 = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Оформление").font(.headline)
                        Picker("Тема", selection: $theme.theme) {
                            ForEach(AppTheme.allCases) { t in Text(t.title).tag(t) }
                        }
                        .pickerStyle(.segmented)
                        if theme.theme == .starry {
                            Text("Анимация звёзд автоматически отключается при включённом Reduce Motion.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .card()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Хранилище").font(.headline)
                        KeyValueRow(key: "Занято", value: BytesFmt.string(usage))
                        Button("Очистить временные файлы") {
                            StorageManager.shared.purgeTemp()
                            usage = StorageManager.shared.totalUsage()
                        }
                        .font(.footnote)
                    }
                    .card()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ограничения iOS").font(.headline)
                        Text("""
                        • Установка подписанных приложений на устройство из sandbox-приложения \
                        технически невозможна (нет публичного API). Экспортируйте IPA и установите \
                        через Finder, Apple Configurator или AltStore.
                        • Все криптографические операции выполняются локально; ключи живут \
                        в Keychain, пароль .p12 нигде не сохраняется.
                        • Никакие данные не отправляются на внешние серверы.
                        """)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .card()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("IPA Signer").font(.headline)
                        Text("Версия 1.0")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .card()
                }
                .padding(20)
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
            .onAppear { usage = StorageManager.shared.totalUsage() }
        }
    }
}
