import Foundation
import SwiftData

@Model
final class ImportedIPA {
    @Attribute(.unique) var id: UUID
    var fileName: String
    var storedFileURL: String
    var extractDirURL: String
    var name: String
    var bundleID: String
    var version: String
    var build: String
    var minOS: String
    var architectures: String
    var sizeBytes: Int64
    var hasFrameworks: Bool
    var hasPlugIns: Bool
    var hasExtensions: Bool
    var hasProfile: Bool
    var isSigned: Bool
    var iconData: Data?
    var importedAt: Date

    init(id: UUID = UUID(), fileName: String, storedFileURL: String, extractDirURL: String,
         name: String, bundleID: String, version: String, build: String, minOS: String,
         architectures: String, sizeBytes: Int64, hasFrameworks: Bool, hasPlugIns: Bool,
         hasExtensions: Bool, hasProfile: Bool, isSigned: Bool, iconData: Data?, importedAt: Date) {
        self.id = id; self.fileName = fileName; self.storedFileURL = storedFileURL
        self.extractDirURL = extractDirURL; self.name = name; self.bundleID = bundleID
        self.version = version; self.build = build; self.minOS = minOS
        self.architectures = architectures; self.sizeBytes = sizeBytes
        self.hasFrameworks = hasFrameworks; self.hasPlugIns = hasPlugIns
        self.hasExtensions = hasExtensions; self.hasProfile = hasProfile
        self.isSigned = isSigned; self.iconData = iconData; self.importedAt = importedAt
    }
}

@Model
final class StoredCertificate {
    @Attribute(.unique) var id: UUID
    var label: String
    var certType: String          // Development / Distribution / Enterprise / Unknown
    var teamID: String
    var teamName: String
    var subjectSummary: String
    var issuerSummary: String
    var notBefore: Date
    var notAfter: Date
    var serialHex: String
    var certSHA1: String          // отпечаток листового сертификата для поиска identity в Keychain
    var chainFileName: String     // файл Documents/Certs/<sha1>.chain (DER-цепочка)
    var hasPrivateKey: Bool
    var importedAt: Date

    var daysLeft: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: notAfter).day ?? 0
    }

    var status: CertStatus {
        if notAfter < Date() { return .expired }
        if daysLeft <= 30 { return .expiringSoon }
        return .valid
    }

    init(id: UUID = UUID(), label: String, certType: String, teamID: String, teamName: String,
         subjectSummary: String, issuerSummary: String, notBefore: Date, notAfter: Date,
         serialHex: String, certSHA1: String, chainFileName: String, hasPrivateKey: Bool,
         importedAt: Date) {
        self.id = id
        self.label = label
        self.certType = certType
        self.teamID = teamID
        self.teamName = teamName
        self.subjectSummary = subjectSummary
        self.issuerSummary = issuerSummary
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.serialHex = serialHex
        self.certSHA1 = certSHA1
        self.chainFileName = chainFileName
        self.hasPrivateKey = hasPrivateKey
        self.importedAt = importedAt
    }
}

enum CertStatus: String { case valid = "Valid", expiringSoon = "Expiring Soon", expired = "Expired" }

@Model
final class StoredProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var uuid: String
    var teamID: String
    var teamName: String
    var appID: String             // TEAMID.bundle.pattern
    var bundlePattern: String     // без префикса Team ID
    var profileType: String       // Development / Ad Hoc / Enterprise / App Store
    var createdAt: Date
    var expirationDate: Date
    var entitlementsJSON: String
    var devicesJSON: String
    var fileName: String          // Documents/Profiles/<uuid>.mobileprovision
    var importedAt: Date

    var isExpired: Bool { expirationDate < Date() }

    init(id: UUID = UUID(), name: String, uuid: String, teamID: String, teamName: String,
         appID: String, bundlePattern: String, profileType: String, createdAt: Date,
         expirationDate: Date, entitlementsJSON: String, devicesJSON: String,
         fileName: String, importedAt: Date = .init()) {
        self.id = id; self.name = name; self.uuid = uuid; self.teamID = teamID
        self.teamName = teamName; self.appID = appID; self.bundlePattern = bundlePattern
        self.profileType = profileType; self.createdAt = createdAt
        self.expirationDate = expirationDate; self.entitlementsJSON = entitlementsJSON
        self.devicesJSON = devicesJSON; self.fileName = fileName; self.importedAt = importedAt
    }
}

@Model
final class SignedAppRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var bundleID: String
    var version: String
    var signedAt: Date
    var certLabel: String
    var profileName: String
    var fileURL: String
    var sizeBytes: Int64

    init(id: UUID = UUID(), name: String, bundleID: String, version: String,
         signedAt: Date, certLabel: String, profileName: String, fileURL: String, sizeBytes: Int64) {
        self.id = id; self.name = name; self.bundleID = bundleID; self.version = version
        self.signedAt = signedAt; self.certLabel = certLabel; self.profileName = profileName
        self.fileURL = fileURL; self.sizeBytes = sizeBytes
    }
}
