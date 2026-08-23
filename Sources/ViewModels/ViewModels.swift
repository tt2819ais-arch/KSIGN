import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PhotosUI

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var ipas: [ImportedIPA] = []
    @Published var certificates: [StoredCertificate] = []
    @Published var profiles: [StoredProfile] = []
    @Published var signed: [SignedAppRecord] = []
    @Published var busy = false

    private let storage = StorageManager.shared
    var modelContext: ModelContext?

    func attach(context: ModelContext) {
        modelContext = context
        reload()
    }

    func reload() {
        guard let ctx = modelContext else { return }
        let d = FetchDescriptor<ImportedIPA>(sortBy: [SortDescriptor(\.importedAt, order: .reverse)])
        let c = FetchDescriptor<StoredCertificate>(sortBy: [SortDescriptor(\.importedAt, order: .reverse)])
        let p = FetchDescriptor<StoredProfile>(sortBy: [SortDescriptor(\.importedAt, order: .reverse)])
        let s = FetchDescriptor<SignedAppRecord>(sortBy: [SortDescriptor(\.signedAt, order: .reverse)])
        ipas = (try? ctx.fetch(d)) ?? []
        certificates = (try? ctx.fetch(c)) ?? []
        profiles = (try? ctx.fetch(p)) ?? []
        signed = (try? ctx.fetch(s)) ?? []
    }

    // MARK: Импорт IPA

    func importIPA(from url: URL) async {
        busy = true
        defer { busy = false }
        do {
            let stored = try storage.copyIntoLibrary(from: url, kind: "ipa", ext: "ipa")
            let extractDir = storage.extracted.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let (summary, appDir, _) = try await Task.detached {
                try IPAParser.importAndAnalyze(ipa: stored, extractRoot: extractDir) { _, _ in true }
            }.value

            let info = try Plist.dict(at: appDir.appendingPathComponent("Info.plist"))
            let icon = IPAParser.extractIcon(appDir: appDir, info: info)
            let model = ImportedIPA(
                fileName: url.lastPathComponent,
                storedFileURL: stored.path,
                extractDirURL: extractDir.path,
                name: summary.name, bundleID: summary.bundleID,
                version: summary.version, build: summary.build, minOS: summary.minOS,
                architectures: summary.architectures.joined(separator: ", "),
                sizeBytes: storage.size(of: stored),
                hasFrameworks: !summary.frameworks.isEmpty,
                hasPlugIns: !summary.plugIns.isEmpty,
                hasExtensions: !summary.plugIns.isEmpty,
                hasProfile: summary.hasEmbeddedProfile,
                isSigned: summary.hasCodeSignature,
                iconData: icon, importedAt: .init())
            modelContext?.insert(model)
            try modelContext?.save()
            reload()
        } catch {
            logError(error)
        }
    }

    func delete(_ ipa: ImportedIPA) {
        storage.removeItem(at: URL(fileURLWithPath: ipa.storedFileURL))
        storage.removeItem(at: URL(fileURLWithPath: ipa.extractDirURL))
        try? modelContext?.delete(ipa)
        try? modelContext?.save()
        reload()
    }

    // MARK: Сертификаты

    func importCertificate(p12URL: URL, password: String) -> Result<Void, Error> {
        do {
            var scoped = false
            if p12URL.startAccessingSecurityScopedResource() { scoped = true }
            defer { if scoped { p12URL.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: p12URL)
            let service = CertificateService()
            let (details, sha1, chain) = try service.importP12(data: data, password: password)
            let chainFile = storage.uniqueURL(in: storage.certs, name: "\(sha1).chain")
            let packed = try NSKeyedArchiver.archivedData(withRootObject: chain, requiringSecureCoding: true)
            try packed.write(to: chainFile)
            let model = StoredCertificate(label: details.label, certType: details.certType,
                teamID: details.teamID, teamName: details.teamName,
                subjectSummary: details.subject, issuerSummary: details.issuer,
                notBefore: details.notBefore, notAfter: details.notAfter,
                serialHex: details.serialHex, certSHA1: sha1,
                chainFileName: chainFile.lastPathComponent,
                hasPrivateKey: details.hasPrivateKey, importedAt: .init())
            modelContext?.insert(model)
            try modelContext?.save()
            reload()
            return .success(())
        } catch { return .failure(error) }
    }

    func delete(_ cert: StoredCertificate) {
        KeychainService.deleteIdentity(certSHA1Hex: cert.certSHA1)
        storage.removeItem(at: storage.certs.appendingPathComponent(cert.chainFileName))
        try? modelContext?.delete(cert)
        try? modelContext?.save()
        reload()
    }

    // MARK: Профили

    func importProfile(from url: URL) async -> Result<Void, Error> {
        do {
            var scoped = false
            if url.startAccessingSecurityScopedResource() { scoped = true }
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let raw = try Data(contentsOf: url)
            let parsed = try ProfileService.parse(raw: raw)
            let file = storage.uniqueURL(in: storage.profiles, name: "\(parsed.uuid).mobileprovision")
            try raw.write(to: file)
            let entJSON = String(data: try JSONSerialization.data(withJSONObject: parsed.entitlements,
                                                                  options: [.prettyPrinted, .sortedKeys]), encoding: .utf8) ?? "{}"
            let devJSON = String(data: try JSONSerialization.data(withJSONObject: parsed.devices), encoding: .utf8) ?? "[]"
            let model = StoredProfile(name: parsed.name, uuid: parsed.uuid, teamID: parsed.teamID,
                teamName: parsed.teamName, appID: parsed.appID, bundlePattern: parsed.bundlePattern,
                profileType: parsed.type.rawValue, createdAt: parsed.createdAt,
                expirationDate: parsed.expirationDate, entitlementsJSON: entJSON,
                devicesJSON: devJSON, fileName: file.lastPathComponent)
            modelContext?.insert(model)
            try modelContext?.save()
            reload()
            return .success(())
        } catch { return .failure(error) }
    }

    func delete(_ profile: StoredProfile) {
        storage.removeItem(at: storage.profiles.appendingPathComponent(profile.fileName))
        try? modelContext?.delete(profile)
        try? modelContext?.save()
        reload()
    }

    func delete(_ rec: SignedAppRecord) {
        storage.removeItem(at: URL(fileURLWithPath: rec.fileURL))
        try? modelContext?.delete(rec)
        try? modelContext?.save()
        reload()
    }

    func loadParsedProfile(_ stored: StoredProfile) -> ParsedProfile? {
        try? ProfileService.parse(raw: (try? Data(contentsOf: storage.profiles.appendingPathComponent(stored.fileName))) ?? Data())
    }

    func loadChain(of cert: StoredCertificate) -> [Data] {
        let url = storage.certs.appendingPathComponent(cert.chainFileName)
        guard let packed = try? Data(contentsOf: url),
              let arr = try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: NSData.self, from: packed) else { return [] }
        return arr.map { Data($0) }
    }

    nonisolated func logError(_ e: Error) {}
}

@MainActor
final class SignViewModel: ObservableObject {

    enum Phase: Equatable { case idle, checking, ready, signing, done(URL), failed(String), cancelled }

    struct CheckItem: Identifiable {
        let id = UUID()
        let title: String
        let passed: Bool?      // nil = предупреждение
        let detail: String
    }

    @Published var phase: Phase = .idle
    @Published var checks: [CheckItem] = []
    @Published var logLines: [LogLine] = []
    @Published var progress: Double = 0
    @Published var phaseTitle: String = ""

    @Published var selectedCert: StoredCertificate?
    @Published var selectedProfile: StoredProfile?
    @Published var appName: String = ""
    @Published var bundleID: String = ""
    @Published var iconImage: UIImage?

    let library: LibraryViewModel
    let ipa: ImportedIPA

    init(library: LibraryViewModel, ipa: ImportedIPA) {
        self.library = library
        self.ipa = ipa
        self.appName = ipa.name
        self.bundleID = ipa.bundleID
        // авто-выбор: единственные доступные сертификат/профиль
        if library.certificates.count == 1 { selectedCert = library.certificates[0] }
        if library.profiles.count == 1 { selectedProfile = library.profiles[0] }
    }

    func runPreflight() async {
        phase = .checking
        var items: [CheckItem] = []
        let cert = selectedCert
        let profile = selectedProfile

        items.append(CheckItem(title: "IPA содержит корректный .app",
                               passed: FileManager.default.fileExists(atPath: URL(fileURLWithPath: ipa.extractDirURL)
                                   .appendingPathComponent("Payload/\(ipa.name).app").path) ||
                                   FileManager.default.fileExists(atPath: URL(fileURLWithPath: ipa.extractDirURL).path),
                               detail: ipa.bundleID))

        items.append(CheckItem(title: "Сертификат выбран",
                               passed: cert != nil,
                               detail: cert?.label ?? "импортируйте .p12"))

        if let cert {
            let expired = cert.notAfter < Date()
            items.append(CheckItem(title: "Сертификат действителен",
                                   passed: !expired,
                                   detail: expired ? "истёк \(cert.notAfter.formatted(date: .long, time: .omitted))"
                                                   : "осталось \(cert.daysLeft) дн."))
            let keyOK = KeychainService.identity(certSHA1Hex: cert.certSHA1) != nil
            items.append(CheckItem(title: "Приватный ключ доступен",
                                   passed: keyOK && cert.hasPrivateKey,
                                   detail: keyOK ? "найден в Keychain" : "нет в Keychain"))
        }

        if let stored = profile {
            let parsed = library.loadParsedProfile(stored)
            items.append(CheckItem(title: "Provisioning profile выбран",
                                   passed: true, detail: stored.name))
            let exp = stored.expirationDate > Date()
            items.append(CheckItem(title: "Профиль не истёк",
                                   passed: exp,
                                   detail: stored.expirationDate.formatted(date: .abbreviated, time: .shortened)))
            if let parsed {
                let ok = ProfileService.matches(pattern: parsed.bundlePattern, bundleID: bundleID)
                items.append(CheckItem(title: "Bundle ID совместим с профилем",
                                       passed: ok,
                                       detail: ok ? "\(bundleID) ✓ \(parsed.bundlePattern)"
                                                  : "«\(bundleID)» не покрыт шаблоном «\(parsed.bundlePattern)»"))
            }
        } else {
            items.append(CheckItem(title: "Provisioning profile выбран",
                                   passed: false, detail: "импортируйте .mobileprovision"))
        }

        let armOK = ipa.architectures.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .contains("arm64")
        items.append(CheckItem(title: "Архитектура arm64",
                               passed: armOK, detail: ipa.architectures))

        checks = items
        phase = .ready
    }

    var canSign: Bool {
        checks.contains { $0.passed == false } == false &&
        selectedCert != nil && selectedProfile != nil
    }

    func startSigning() {
        guard let cert = selectedCert,
              let storedProfile = selectedProfile,
              let parsed = library.loadParsedProfile(storedProfile) else { return }
        Task {
            phase = .signing
            logLines = []
            progress = 0
            do {
                let chain = library.loadChain(of: cert)
                let service = CertificateService()
                let (secIdentity, secChain) = try service.resolveIdentity(certSHA1: cert.certSHA1, chainDER: chain)
                let identity = SigningIdentity(identity: secIdentity, chain: secChain)

                var iconPNGs: [(String, Data)]?
                if let img = iconImage {
                    iconPNGs = try IconProcessor.prepareSet(from: img).map { ($0.name, $0.data) }
                }
                let overrides = SignOverrides(appName: appName.isEmpty ? nil : appName,
                                              bundleID: bundleID == ipa.bundleID ? nil : bundleID,
                                              iconPNGs: iconPNGs)

                let extractURL = URL(fileURLWithPath: ipa.extractDirURL)
                let plan = try await Task.detached {
                    try PlanBuilder.build(workRoot: extractURL, appDir: try IPAParser.locateAppDir(in: extractURL),
                                          profile: parsed, overrides: overrides)
                }.value

                for w in plan.warnings {
                    logLines.append(LogLine(.warn, w))
                }

                let outURL = StorageManager.shared.uniqueURL(
                    in: StorageManager.shared.signed,
                    name: "\((appName.isEmpty ? ipa.name : appName))-signed.ipa")

                let logger = SignLog()
                let runner = ResignRunner(input: .init(originalIPA: URL(fileURLWithPath: ipa.storedFileURL),
                                                       outputIPA: outURL,
                                                       plan: plan,
                                                       overrides: overrides,
                                                       identity: identity,
                                                       teamID: parsed.teamID,
                                                       profileRaw: parsed.rawData),
                    log: { [weak self] level, msg in
                        Task { @MainActor in
                            self?.logLines.append(LogLine(level, msg))
                            if let snap = try? await logger.snapshot() { _ = snap }
                        }
                    },
                    progress: { [weak self] frac, title in
                        Task { @MainActor in
                            self?.progress = frac
                            self?.phaseTitle = title
                        }
                    })

                try await runner.run()

                let rec = SignedAppRecord(name: appName.isEmpty ? ipa.name : appName,
                                          bundleID: plan.mainNewID,
                                          version: ipa.version, signedAt: .init(),
                                          certLabel: cert.label, profileName: storedProfile.name,
                                          fileURL: outURL.path,
                                          sizeBytes: StorageManager.shared.size(of: outURL))
                library.modelContext?.insert(rec)
                try library.modelContext?.save()
                library.reload()
                phase = .done(outURL)
            } catch is CancellationError {
                phase = .cancelled
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

@MainActor
final class ExplorerViewModel: ObservableObject {
    @Published var currentURL: URL
    @Published var children: [URL] = []
    @Published var searchText: String = ""

    let appDir: URL

    init(appDir: URL) {
        self.appDir = appDir
        self.currentURL = appDir
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: currentURL,
                        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])) ?? []
        let filtered = searchText.isEmpty ? items : items.filter {
            $0.lastPathComponent.localizedCaseInsensitiveContains(searchText)
        }
        children = filtered.sorted {
            let ld = (((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false)
            let rd = (((try? $1.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false)
            if ld != rd { return ld }
            return $0.lastPathComponent < $1.lastPathComponent
        }
    }

    func open(_ url: URL) {
        currentURL = url
        reload()
    }

    func goUp() {
        guard currentURL != appDir, currentURL.path != "/" else { return }
        currentURL = currentURL.deletingLastPathComponent()
        reload()
    }

    var canGoUp: Bool { currentURL.path != appDir.path }

    func size(of url: URL) -> Int64 {
        let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if vals?.isDirectory == true { return 0 }
        return Int64(vals?.fileSize ?? 0)
    }
}
