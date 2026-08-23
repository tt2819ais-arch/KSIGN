import Foundation

final class StorageManager {
    static let shared = StorageManager()
    let fm = FileManager.default

    lazy var documents: URL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    lazy var ipas: URL = documents.appendingPathComponent("IPAs", isDirectory: true)
    lazy var extracted: URL = documents.appendingPathComponent("Extracted", isDirectory: true)
    lazy var certs: URL = documents.appendingPathComponent("Certs", isDirectory: true)
    lazy var profiles: URL = documents.appendingPathComponent("Profiles", isDirectory: true)
    lazy var signed: URL = documents.appendingPathComponent("Signed", isDirectory: true)
    lazy var tmp: URL = documents.appendingPathComponent("tmp", isDirectory: true)

    init() {
        for d in [documents, ipas, extracted, certs, profiles, signed, tmp] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    func uniqueURL(in dir: URL, name: String) -> URL {
        var url = dir.appendingPathComponent(name)
        var n = 1
        while fm.fileExists(atPath: url.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            url = dir.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return url
    }

    func copyIntoLibrary(from source: URL, kind: String, ext: String) throws -> URL {
        var started = false
        if source.startAccessingSecurityScopedResource() { started = true }
        defer { if started { source.stopAccessingSecurityScopedResource() } }
        let dst = uniqueURL(in: dir(for: kind), name: "\(UUID().uuidString).\(ext)")
        try fm.copyItem(at: source, to: dst)
        return dst
    }

    private func dir(for kind: String) -> URL {
        switch kind {
        case "ipa": return ipas
        case "p12": return certs
        case "profile": return profiles
        default: return documents
        }
    }

    func size(of url: URL) -> Int64 {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    func totalUsage() -> Int64 {
        var total: Int64 = 0
        for dir in [ipas, certs, profiles, signed] {
            if let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let f as URL in en { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            }
        }
        return total
    }

    func purgeTemp() {
        try? fm.removeItem(at: tmp)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    func removeItem(at url: URL) { try? fm.removeItem(at: url) }
}
