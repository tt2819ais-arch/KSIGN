import Foundation

/// Исполняет план переподписи: правит Info.plist, иконки, подписывает все бинарники,
/// строит CodeResources и пересобирает IPA (нетронутые записи копируются вербатим).
final class ResignRunner: @unchecked Sendable {

    struct Input {
        let originalIPA: URL
        let outputIPA: URL
        let plan: SignPlan
        let overrides: SignOverrides
        let identity: SigningIdentity
        let teamID: String
        let profileRaw: Data
    }

    private let input: Input
    private let log: @Sendable (LogLevel, String) -> Void
    private let progress: @Sendable (Double, String) -> Void

    init(input: Input,
         log: @escaping @Sendable (LogLevel, String) -> Void,
         progress: @escaping @Sendable (Double, String) -> Void) {
        self.input = input
        self.log = log
        self.progress = progress
    }

    func run() async throws {
        let fm = FileManager.default
        let plan = input.plan
        let workRoot = StorageManager.shared.tmp
            .appendingPathComponent("job-\(UUID().uuidString)", isDirectory: true)

        // 1. Распаковка
        progress(0.02, "Распаковка IPA")
        log(.info, "Распаковка \(input.originalIPA.lastPathComponent)")
        let reader = try ZipReader(url: input.originalIPA)
        try fm.createDirectory(at: workRoot, withIntermediateDirectories: true)
        try reader.extractAll(to: workRoot) { done, total in
            progress(0.02 + 0.12 * Double(done) / Double(max(total, 1)), "Распаковка IPA")
            return !Task.isCancelled
        }

        // 2. Правки главного Info.plist: имя, bundle id, иконки
        progress(0.16, "Подготовка изменений")
        let appDir = plan.appDir
        let infoURL = appDir.appendingPathComponent("Info.plist")
        var info = try Plist.dict(at: infoURL)
        if let newName = input.overrides.appName, !newName.isEmpty {
            info["CFBundleDisplayName"] = newName
            info["CFBundleName"] = String(newName.prefix(15))
            log(.info, "Display Name → \(newName)")
        }
        info["CFBundleIdentifier"] = plan.mainNewID
        if let icons = input.overrides.iconPNGs {
            for icon in icons {
                try icon.data.write(to: appDir.appendingPathComponent(icon.name))
            }
            info["CFBundleIcons"] = ["CFBundlePrimaryIcon": [
                "CFBundleIconFiles": ["AppIcon60x60"],
                "CFBundleIconName": "AppIcon"]]
            info["CFBundleIcons~ipad"] = ["CFBundlePrimaryIcon": [
                "CFBundleIconFiles": ["AppIcon76x76"],
                "CFBundleIconName": "AppIcon"]]
            log(.info, "Иконки добавлены: \(icons.map(\.name).joined(separator: ", "))")
        }
        try Plist.data(info).write(to: infoURL)

        // 3. Подпись бандлов (глубже — раньше)
        let signWeight = 0.62
        let units = plan.tasks.count + plan.looseDylibs.count
        var doneUnits = 0

        for task in plan.tasks {
            try Task.checkCancellation()
            progress(0.2 + signWeight * Double(doneUnits) / Double(max(units, 1)),
                     "Подпись \(task.dir.lastPathComponent)")
            let execURL = task.dir.appendingPathComponent(task.executableRelative)
            try await signSingleBinary(fileURL: execURL,
                                       identifier: task.newBundleID,
                                       entitlementsXML: task.entitlementsXML,
                                       infoPlistData: (try? Data(contentsOf: task.dir.appendingPathComponent("Info.plist"))) ?? Data(),
                                       bundleDir: task.dir,
                                       isMain: task.isMain,
                                       workRoot: workRoot)
            doneUnits += 1
        }

        for dylib in plan.looseDylibs {
            try Task.checkCancellation()
            progress(0.2 + signWeight * Double(doneUnits) / Double(max(units, 1)),
                     "Подпись \(dylib.lastPathComponent)")
            try await signSingleBinary(fileURL: dylib,
                                       identifier: dylib.lastPathComponent,
                                       entitlementsXML: try Plist.data([:], binary: false),
                                       infoPlistData: Data(),
                                       bundleDir: nil,
                                       isMain: false,
                                       workRoot: workRoot)
            doneUnits += 1
        }

        // 4. Перепаковка IPA
        progress(0.86, "Сборка подписанного IPA")
        log(.info, "Пересборка контейнера IPA")
        let writer = try ZipWriter(url: input.outputIPA)
        let total = reader.entries.count
        for (i, e) in reader.entries.enumerated() {
            try Task.checkCancellation()
            if i % 25 == 0 {
                progress(0.86 + 0.13 * Double(i) / Double(max(total, 1)), "Сборка подписанного IPA")
            }
            let fsPath = workRoot.appendingPathComponent(e.name).path
            if !e.isDirectory && fm.fileExists(atPath: fsPath) {
                let data = try Data(contentsOf: URL(fileURLWithPath: fsPath))
                let execBit = (e.unixMode & 0o111) != 0
                try writer.add(name: e.name, data: data,
                               mode: execBit ? 0o755 : 0o644)
            } else {
                try writer.addVerbatim(from: reader, entry: e)
            }
        }
        try writer.finish()

        progress(0.995, "Очистка временных файлов")
        try? fm.removeItem(at: workRoot)
        progress(1.0, "Готово")
        log(.success, "Подписанный IPA: \(input.outputIPA.lastPathComponent)")
    }

    // MARK: - Подпись одного исполняемого файла (+ CodeResources его бандла)

    private func signSingleBinary(fileURL: URL, identifier: String,
                                  entitlementsXML: Data, infoPlistData: Data,
                                  bundleDir: URL?, isMain: Bool,
                                  workRoot: URL) async throws {
        let fm = FileManager.default
        var rawData = try Data(contentsOf: fileURL)
        log(.info, "Обработка \(fileURL.lastPathComponent) (\(BytesFmt.string(Int64(rawData.count))))")

        let cmsFactory: (Data) throws -> Data = { cd in
            try CMSSigner.signedData(contentDER: cd, id: self.input.identity)
        }

        func signThin(_ thin: inout MachOBinary) throws {
            try CodeSigner.resign(bin: &thin,
                                  identifier: identifier,
                                  teamID: self.input.teamID,
                                  entitlementsXML: entitlementsXML,
                                  infoPlistData: infoPlistData,
                                  codeResourcesData: bundleDir == nil ? nil : try? CodeResourcesBuilder.build(
                                        bundleDir: bundleDir!.deletingLastPathComponent() == bundleDir! ? bundleDir! : bundleDir!,
                                        mainExecutableRelativePath: fileURL.lastPathComponent),
                                  isMainExecutable: isMain,
                                  cms: cmsFactory) { msg in
                Task { await self.emit(.info, msg) }
            }
        }

        if Fat.isFat(rawData) {
            log(.warn, "FAT-бинарник: подписывается только arm64-слайс, контейнер пересобирается")
            var slices = Fat.slices(of: rawData)
            guard let armIdx = slices.firstIndex(where: { $0.cputype == 0x0100000C }) else {
                throw AppError.incompatible("в FAT-бинарнике нет arm64-слайса")
            }
            let armData = rawData.subdata(in: slices[armIdx].offset..<(slices[armIdx].offset + slices[armIdx].size))
            var bin = MachOBinary(armData)
            try signThin(&bin)
            var parts: [(Fat.Slice, Data)] = []
            for (i, s) in slices.enumerated() {
                let d = i == armIdx ? bin.data : rawData.subdata(in: s.offset..<(s.offset + s.size))
                parts.append((s, d))
            }
            rawData = Fat.rebuild(parts)
        } else {
            var bin = MachOBinary(rawData)
            try signThin(&bin)
            rawData = bin.data
        }

        try rawData.write(to: fileURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)

        // CodeResources бандла
        if let dir = bundleDir {
            let cr = try CodeResourcesBuilder.build(bundleDir: dir,
                                                    mainExecutableRelativePath: fileURL.lastPathComponent)
            let csDir = dir.appendingPathComponent("_CodeSignature", isDirectory: true)
            try fm.createDirectory(at: csDir, withIntermediateDirectories: true)
            try cr.write(to: csDir.appendingPathComponent("CodeResources"))
        }
    }

    private func emit(_ level: LogLevel, _ msg: String) {
        log(level, msg)
    }
}
