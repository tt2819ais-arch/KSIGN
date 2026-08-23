import Foundation
import CryptoKit

/// Строит манифест ресурсов _CodeSignature/CodeResources (файлы + files2).
enum CodeResourcesBuilder {

    static func build(bundleDir: URL, mainExecutableRelativePath: String) throws -> Data {
        let fm = FileManager.default
        var filesSHA1: [String: Any] = [:]
        var files2SHA256: [String: Any] = [:]

        let enumerator = fm.enumerator(at: bundleDir,
                                       includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        var relPaths: [(rel: String, url: URL, isSymlink: Bool, target: String?)] = []
        while let item = enumerator?.nextObject() as? URL {
            let rel = item.path.replacingOccurrences(of: bundleDir.path + "/", with: "")
            if rel.contains("_CodeSignature/") || rel.hasSuffix(".DS_Store") || rel == mainExecutableRelativePath {
                continue
            }
            let vals = try? item.resourceValues(forKeys: [.isSymbolicLinkKey])
            if vals?.isSymbolicLink == true {
                let target = try? fm.destinationOfSymbolicLink(atPath: item.path)
                relPaths.append((rel, item, true, target))
            } else if (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                relPaths.append((rel, item, false, nil))
            }
        }
        relPaths.sort { $0.rel < $1.rel }

        for item in relPaths {
            if item.isSymlink {
                filesSHA1[item.rel] = ["symlink": item.target ?? ""]
            } else {
                let data = try Data(contentsOf: item.url)
                filesSHA1[item.rel] = Data(Insecure.SHA1.hash(data: data)).base64EncodedString()
                files2SHA256[item.rel] = ["hash": Data(SHA256.hash(data: data)).base64EncodedString()]
            }
        }

        let root: [String: Any] = ["files": filesSHA1, "files2": files2SHA256]
        return try Plist.data(root, binary: false)
    }
}
