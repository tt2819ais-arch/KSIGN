import Foundation

enum ProfileType: String { case development = "Development", adHoc = "Ad Hoc", enterprise = "Enterprise", appStore = "App Store", unknown = "Unknown" }

struct ParsedProfile {
    var name: String
    var uuid: String
    var teamID: String
    var teamName: String
    var appID: String                 // напр. "TEAMID.com.company.*"
    var bundlePattern: String         // без Team ID
    var type: ProfileType
    var createdAt: Date
    var expirationDate: Date
    var entitlements: [String: Any]
    var devices: [String]
    var rawData: Data
}

enum ProfileService {

    /// .mobileprovision — это CMS(PKCS#7)-контейнер с plist внутри.
    /// CMS-конверт декодировать не обязательно: встроенный XML-plist
    /// надёжно извлекается по границам "<?xml" … "</plist>".
    static func parse(raw data: Data) throws -> ParsedProfile {
        guard let xml = embeddedPlist(data: data),
              let obj = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil),
              let dict = obj as? [String: Any] else {
            throw AppError.invalidFormat("не удалось извлечь plist из .mobileprovision")
        }
        let ent = dict["Entitlements"] as? [String: Any] ?? [:]
        let appID = ent["application-identifier"] as? String ?? ""
        let teamID = dict["TeamIdentifier"] as? [String] ?? (appID.isEmpty ? [] : [String(appID.prefix(10))])
        let pattern = appID.contains(".")
            ? String(appID.split(separator: ".", maxSplits: 1).last ?? "")
            : "*"

        var type: ProfileType = .unknown
        let taskAllow = ent["get-task-allow"] as? Bool ?? false
        if dict["ProvisionsAllDevices"] != nil {
            type = .enterprise
        } else if taskAllow {
            type = .development
        } else if !(dict["ProvisionedDevices"] as? [String] ?? []).isEmpty {
            type = .adHoc
        } else {
            type = .appStore
        }

        func date(_ key: String) -> Date {
            (dict[key] as? Date) ?? (dict[key] as? NSString)?.toDate() ?? .distantPast
        }

        return ParsedProfile(
            name: dict["Name"] as? String ?? "Профиль",
            uuid: dict["UUID"] as? String ?? "",
            teamID: teamID.first ?? "",
            teamName: (dict["TeamName"] as? String) ?? "",
            appID: appID,
            bundlePattern: pattern,
            type: type,
            createdAt: date("CreationDate"),
            expirationDate: date("ExpirationDate"),
            entitlements: ent,
            devices: dict["ProvisionedDevices"] as? [String] ?? [],
            rawData: data)
    }

    /// Совпадает ли bundle id с шаблоном профиля ("com.x.*" / точное совпадение).
    static func matches(pattern: String, bundleID: String) -> Bool {
        if pattern == "*" { return true }
        if pattern.hasSuffix(".*") {
            let prefix = String(pattern.dropLast(2))
            return bundleID == prefix || bundleID.hasPrefix(prefix + ".")
        }
        return pattern == bundleID
    }

    private static func embeddedPlist(data: Data) -> Data? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              end.lowerBound > start.upperBound else { return nil }
        return data.subdata(in: start.lowerBound..<end.upperBound)
    }
}

private extension NSString {
    func toDate() -> Date? {
        let f = ISO8601DateFormatter()
        return f.date(from: self as String)
    }
}
