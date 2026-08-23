import SwiftUI

struct ExplorerView: View {
    @StateObject private var vm: ExplorerViewModel
    @Environment(\.dismiss) private var dismiss

    init(appDir: URL) {
        _vm = StateObject(wrappedValue: ExplorerViewModel(appDir: appDir))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text(vm.appDir.lastPathComponent).font(.footnote.monospaced())
                        Spacer()
                        Button { vm.goUp() } label: { Image(systemName: "chevron.up") }
                            .disabled(!vm.canGoUp)
                    }
                }
                Section {
                    ForEach(vm.children, id: \.absoluteString) { url in
                        Row(url: url, vm: vm)
                    }
                }
            }
            .searchable(text: $vm.searchText, prompt: "Поиск файлов")
            .onChange(of: vm.searchText) { _, _ in vm.reload() }
            .navigationTitle("IPA Explorer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Готово") { dismiss() } } }
        }
    }

    struct Row: View {
        let url: URL
        @ObservedObject var vm: ExplorerViewModel
        @State private var openFile: URL?

        var body: some View {
            let isDir = ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
            Button {
                if isDir { vm.open(url) } else { openFile = url }
            } label: {
                HStack {
                    Image(systemName: isDir ? "folder.fill" : iconName)
                        .foregroundStyle(isDir ? .blue : .secondary)
                    Text(url.lastPathComponent).font(.footnote.monospaced()).lineLimit(1)
                    Spacer()
                    if !isDir {
                        Text(BytesFmt.string(vm.size(of: url)))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .sheet(item: $openFile) { item in
                FileViewer(url: item)
            }
        }

        private var iconName: String {
            switch url.pathExtension.lowercased() {
            case "plist": return "list.bullet.rectangle"
            case "png", "jpg": return "photo"
            case "mobileprovision": return "doc.badge.gearshape"
            default: return "doc"
            }
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct FileViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            content
                .navigationTitle(url.lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }

    @ViewBuilder private var content: some View {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "plist", "mobileprovision":
            PlistViewer(url: url)
        case "txt", "strings", "json", "entitlements", "xml":
            TextViewer(url: url)
        case "png":
            if let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img).resizable().scaledToFit().padding()
            } else {
                BinaryInfo(url: url)
            }
        default:
            BinaryInfo(url: url)
        }
    }
}

struct PlistViewer: View {
    let url: URL
    var body: some View {
        List {
            if let obj = try? Plist.object(at: url) {
                PlistNode(key: "", value: obj, depth: 0)
            } else {
                Text("Не удалось разобрать файл").foregroundStyle(.secondary)
            }
        }
    }
}

struct PlistNode: View {
    let key: String
    let value: Any
    let depth: Int
    var body: some View {
        if let dict = value as? [String: Any] {
            DisclosureGroup("\(key.isEmpty ? "Dictionary" : key) (\(dict.count))") {
                ForEach(dict.keys.sorted(), id: \.self) { k in
                    PlistNode(key: k, value: dict[k]!, depth: depth + 1)
                }
            }
        } else if let arr = value as? [Any] {
            DisclosureGroup("\(key.isEmpty ? "Array" : key) (\(arr.count))") {
                ForEach(Array(arr.enumerated()), id: \.offset) { i, v in
                    PlistNode(key: "[\(i)]", value: v, depth: depth + 1)
                }
            }
        } else {
            KeyValueRow(key: key, value: Self.describe(value), mono: true)
        }
    }

    private static func describe(_ v: Any) -> String {
        switch v {
        case let d as Data: return "Data (\(d.count) B): \(SHA.hex(d.prefix(16)))…"
        case let s as String: return "\"\(s)\""
        default: return "\(v)"
        }
    }
}

struct TextViewer: View {
    let url: URL
    var body: some View {
        ScrollView {
            if let data = try? Data(contentsOf: url), isText(data) {
                Text(String(data: data.prefix(200_000), encoding: .utf8) ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .textSelection(.enabled)
            } else {
                BinaryInfo(url: url)
            }
        }
    }

    private func isText(_ d: Data) -> Bool {
        let sample = d.prefix(4096)
        return !sample.contains(0) && (String(data: sample, encoding: .utf8) != nil)
    }
}

struct BinaryInfo: View {
    let url: URL
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "binary").font(.largeTitle).foregroundStyle(.secondary)
            Text("Бинарный файл").font(.headline)
            Text("Размер: \(BytesFmt.string(StorageManager.shared.size(of: url)))")
                .foregroundStyle(.secondary)
            Text("Содержимое не отображается как текст.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity).padding(40)
    }
}
