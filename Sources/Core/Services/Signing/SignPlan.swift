import Foundation

struct SignOverrides {
    var appName: String?
    var bundleID: String?
    var iconPNGs: [(name: String, data: Data)]?
}

struct BundleSignTask {
    var dir: URL
    var isMain: Bool
    var oldBundleID: String
    var newBundleID: String
    var executableRelative: String
    var entitlementsXML: Data
    var needsProfileEmbed: Bool
    var rootPath: String = ""

    var infoRelative: String { relative(dir) + "/Info.plist" }
    var relativeDir: String { relative(dir) }
    func relative(_ url: URL) -> String {
        url.path.replacingOccurrences(of: rootPath + "/", with: "")
    }
}

struct SignPlan {
    var appDir: URL
    var mainInfoOriginalID: String
    var mainNewID: String
    var tasks: [BundleSignTask]      // отсортированы: самые глубокие первыми
    var looseDylibs: [URL]
    var warnings: [String]
    var rootPath: String
}

enum PlanBuilder {

    static func build(workRoot: URL, appDir: URL, profile: ParsedProfile,
                      overrides: SignOverrides) throws -> SignPlan {
        let fm = FileManager.default
        let rootPath = workRoot.path
        let infoURL = appDir.appendingPathComponent("Info.plist")
        let info = try Plist.dict(at: infoURL)
        let oldID = info["CFBundleIdentifier"] as? String ?? ""
        let newMainID = overrides.bundleID?.isEmpty == false ? overrides.bundleID! : oldID

        var warnings: [String] = []

        // Рекурсивный сбор вложенных бандлов (Frameworks, PlugIns, вложенные .appex)
        var bundleDirs: [URL] = [appDir]
        func walk(_ dir: URL) {
            guard let children = try? fm.contentsOfDirectory(at: dir,
                                                             includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            for child in children {
                let isDir = ((try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
                guard isDir else { continue }
                if fm.fileExists(atPath: child.appendingPathComponent("Info.plist").path) {
                    bundleDirs.append(child)
                }
                walk(child)
            }
        }
        walk(appDir)

        // Новые bundle id для вложенных бандлов: <главный>.<суффикс>
        func newID(for dir: URL) -> String {
            if dir == appDir { return newMainID }
            let parent = dir.deletingLastPathComponent()
            let parentID = bundleDirs.contains(parent) ? newID(for: parent) : newMainID
            var leaf = dir.lastPathComponent
            for suffix in [".framework", ".appex", ".app", ".bundle", ".xpc"] {
                if leaf.hasSuffix(suffix) { leaf.removeLast(suffix.count) }
            }
            let sanitized = leaf.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
            return parentID + "." + String(sanitized)
        }

        var tasks: [BundleSignTask] = []
        var looseDylibs: [URL] = []

        for dir in bundleDirs {
            let isMain = dir == appDir
            let infoPath = dir.appendingPathComponent("Info.plist")
            var dinfo = try Plist.dict(at: infoPath)
            let nid = newID(for: dir)
            let oldBundleID = (dinfo["CFBundleIdentifier"] as? String) ?? oldID

            if !isMain {
                dinfo["CFBundleIdentifier"] = nid
                try Plist.data(dinfo).write(to: infoPath)
            }

            let execName = (dinfo["CFBundleExecutable"] as? String)
                ?? dir.lastPathComponent.replacingOccurrences(of: ".framework", with: "")
            let exec = execName.isEmpty ? dir.lastPathComponent : execName

            let profRel = dir.appendingPathComponent("embedded.mobileprovision").path
            let needsProfile = !fm.fileExists(atPath: profRel)
            if needsProfile {
                try profile.rawData.write(to: dir.appendingPathComponent("embedded.mobileprovision"))
            }

            var ents = profile.entitlements
            if !isMain {
                ents = transform(entitlements: profile.entitlements,
                                 oldMain: oldID, newMain: newMainID, childID: nid, teamID: profile.teamID)
                if !ProfileService.matches(pattern: profile.bundlePattern, bundleID: nid) {
                    warnings.append("Профиль не покрывает расширение \(nid) — оно может не запуститься после установки.")
                }
            }
            let entXML = try Plist.data(ents, binary: false)

            let task = BundleSignTask(dir: dir, isMain: isMain,
                                      oldBundleID: oldBundleID,
                                      newBundleID: isMain ? newMainID : nid,
                                      executableRelative: exec,
                                      entitlementsXML: entXML,
                                      needsProfileEmbed: needsProfile,
                                      rootPath: rootPath)
            tasks.append(task)
        }

        // Свободные .dylib прямо в Frameworks/
        if let fwDir = try? fm.contentsOfDirectory(at: appDir.appendingPathComponent("Frameworks"),
                                                   includingPropertiesForKeys: nil) {
            for f in fwDir where f.pathExtension == "dylib" { looseDylibs.append(f) }
        }

        // Глубина: сначала подписываем самые вложенные
        tasks.sort {
            $0.dir.path.components(separatedBy: "/").count > $1.dir.path.components(separatedBy: "/").count
        }

        if overrides.bundleID?.isEmpty == false,
           !ProfileService.matches(pattern: profile.bundlePattern, bundleID: newMainID) {
            throw AppError.incompatible(
                "Выбранный provisioning profile не покрывает Bundle Identifier «\(newMainID)». " +
                "Профиль допускает: «\(profile.bundlePattern)».")
        }
        if overrides.appName?.isEmpty == false {
            warnings.append("Display Name будет изменён на «\(overrides.appName!)».")
        }
        if overrides.iconPNGs != nil {
            warnings.append("Иконка будет заменена через CFBundleIcons (приоритетнее Assets.car).")
        }

        return SignPlan(appDir: appDir, mainInfoOriginalID: oldID, mainNewID: newMainID,
                        tasks: tasks, looseDylibs: looseDylibs, warnings: warnings, rootPath: rootPath)
    }

    private static func transform(entitlements: [String: Any], oldMain: String,
                                  newMain: String, childID: String, teamID: String) -> [String: Any] {
        var e = entitlements
        if !teamID.isEmpty {
            e["application-identifier"] = "\(teamID).\(childID)"
        }
        if let groups = e["keychain-access-groups"] as? [String] {
            e["keychain-access-groups"] = groups.map {
                $0.replacingOccurrences(of: oldMain, with: childID)
            }
        }
        if let groups = e["com.apple.security.application-groups"] as? [String] {
            e["com.apple.security.application-groups"] = groups.map {
                $0.replacingOccurrences(of: oldMain, with: childID)
            }
        }
        return e
    }
}
