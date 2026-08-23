import Foundation

struct IPASummary {
    var name: String
    var bundleID: String
    var version: String
    var build: String
    var minOS: String
    var executable: String
    var architectures: [String]
    var frameworks: [String]
    var plugIns: [String]
    var hasEmbeddedProfile: Bool
    var hasCodeSignature: Bool
    var appRelativePath: String
}

enum IPAParser {

    static func locateAppDir(in root: URL) throws -> URL {
        let payload = root.appendingPathComponent("Payload")
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isDirectoryKey])
        for item in items where item.lastPathComponent.hasSuffix(".app") {
            if fm.fileExists(atPath: item.appendingPathComponent("Info.plist").path) { return item }
        }
        throw AppError.invalidFormat("в IPA не найден каталог Payload/*.app с Info.plist")
    }

    static func summarize(appDir: URL) throws -> IPASummary {
        let fm = FileManager.default
        let info = try Plist.dict(at: appDir.appendingPathComponent("Info.plist"))
        let exec = info["CFBundleExecutable"] as? String
            ?? ((info["CFBundleName"] as? String) ?? appDir.lastPathComponent.replacingOccurrences(of: ".app", with: ""))
        let binURL = appDir.appendingPathComponent(exec)
        var archs: [String] = []
        if let data = try? Data(contentsOf: binURL) {
            archs = MachOUtil.architectureNames(data)
        }
        let fw = (try? fm.contentsOfDirectory(at: appDir.appendingPathComponent("Frameworks"),
                                              includingPropertiesForKeys: nil))?.map(\.lastPathComponent) ?? []
        let pl = (try? fm.contentsOfDirectory(at: appDir.appendingPathComponent("PlugIns"),
                                              includingPropertiesForKeys: nil))?.map(\.lastPathComponent) ?? []
        let hasProfile = fm.fileExists(atPath: appDir.appendingPathComponent("embedded.mobileprovision").path)
        let hasSig = fm.fileExists(atPath: appDir.appendingPathComponent("_CodeSignature/CodeResources").path)

        return IPASummary(
            name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? appDir.lastPathComponent,
            bundleID: info["CFBundleIdentifier"] as? String ?? "—",
            version: info["CFBundleShortVersionString"] as? String ?? "—",
            build: info["CFBundleVersion"] as? String ?? "—",
            minOS: info["MinimumOSVersion"] as? String ?? "—",
            executable: exec,
            architectures: archs,
            frameworks: fw.filter { $0.hasSuffix(".framework") },
            plugIns: pl.filter { $0.hasSuffix(".appex") },
            hasEmbeddedProfile: hasProfile,
            hasCodeSignature: hasSig,
            appRelativePath: "Payload/\(appDir.lastPathComponent)")
    }

    /// Попытка достать PNG-иконку (классические CFBundleIconFiles;
    /// для Assets.car вернёт nil — рисуем плейсхолдер).
    static func extractIcon(appDir: URL, info: [String: Any]) -> Data? {
        let candidates = (info["CFBundleIconFiles"] as? [String]) ?? []
        let primary = candidates.last
        for scale in ["@3x", "@2x", ""] {
            if let p = primary {
                let url = appDir.appendingPathComponent(p + scale + ".png")
                if let d = try? Data(contentsOf: url) { return d }
            }
        }
        return nil
    }

    static func importAndAnalyze(ipa: URL, extractRoot: URL,
                                 progress: @escaping (Int, Int) -> Bool) throws -> (IPASummary, URL, URL) {
        let fm = FileManager.default
        try fm.createDirectory(at: extractRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        let reader = try ZipReader(url: ipa)
        try reader.extractAll(to: extractRoot, progress: progress)
        let appDir = try locateAppDir(in: extractRoot)
        let summary = try summarize(appDir: appDir)
        return (summary, appDir, extractRoot)
    }
}

enum MachOUtil {
    static func architectureNames(_ data: Data) -> [String] {
        if Fat.isFat(data) { return Fat.slices(of: data).map { name($0.cputype) } }
        guard data.count >= 8, data[0] == 0xcf, data[1] == 0xfa, data[2] == 0xed, data[3] == 0xfe else { return [] }
        let cpu = LE.u32(data, 4)
        return [name(cpu)]
    }
    static func name(_ cputype: UInt32) -> String {
        switch cputype {
        case 0x0100000C: return "arm64"
        case 0x0100000E: return "arm64e"
        case 0x01000007: return "x86_64"
        case 0x0000000C: return "arm"
        default: return "cpu\(cputype)"
        }
    }
}
