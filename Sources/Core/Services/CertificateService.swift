import Foundation
import Security

struct CertificateDetails {
    var label: String
    var certType: String
    var teamID: String
    var teamName: String
    var subject: String
    var issuer: String
    var notBefore: Date
    var notAfter: Date
    var serialHex: String
    var hasPrivateKey: Bool
}

final class CertificateService {

    // MARK: - Импорт .p12

    /// Импортирует p12. Пароль используется ОДИН раз и нигде не сохраняется.
    /// Identity попадает в Keychain средствами SecPKCS12Import.
    func importP12(data: Data, password: String) throws -> (details: CertificateDetails, certSHA1: String, chainDER: [Data]) {
        let options = [kSecImportExportPassphrase as String: password]
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess else {
            if status == errSecAuthFailed {
                throw AppError.invalidFormat("неверный пароль .p12")
            }
            throw AppError.invalidFormat("не удалось импортировать .p12 (код \(status))")
        }
        guard let items = rawItems as? [[String: Any]], let first = items.first,
              let identity = first[kSecImportItemIdentity as String] as? SecIdentity else {
            throw AppError.invalidFormat("в .p12 не найдена связка сертификат+ключ")
        }
        let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        guard let leaf = chain.first else {
            throw AppError.invalidFormat("в .p12 не найден сертификат")
        }
        let leafDER = SecCertificateCopyData(leaf) as Data
        let sha1 = SHA.sha1Hex(leafDER)
        guard KeychainService.identity(certSHA1Hex: sha1) != nil else {
            throw AppError.notFound("identity не удалось сохранить в Keychain")
        }
        let details = Self.describe(chain: chain, hasKey: KeychainService.privateKey(of: identity) != nil)
        return (details, sha1, chain.map { SecCertificateCopyData($0) as Data })
    }

    // MARK: - Разбор информации о сертификате (только публичные API)

    static func describe(chain: [SecCertificate], hasKey: Bool) -> CertificateDetails {
        func stringVal(_ oid: CFString) -> String? {
            guard let dict = SecCertificateCopyValues(oid, nil, nil) as? [CFString: Any],
                  let entry = dict[oid] as? [CFString: Any] else { return nil }
            return entry[kSecPropertyKeyValue as CFString] as? String
        }
        func dateVal(_ oid: CFString) -> Date? {
            guard let dict = SecCertificateCopyValues(oid, nil, nil) as? [CFString: Any],
                  let entry = dict[oid] as? [CFString: Any],
                  let n = entry[kSecPropertyKeyValue as CFString] as? NSNumber else { return nil }
            return Date(timeIntervalSinceReferenceDate: n.doubleValue)
        }

        let leaf = chain[0]
        let cn = stringVal(kSecOIDCommonName) ?? "Без имени"
        let org = stringVal(kSecOIDOrganizationName) ?? ""
        let ou = stringVal(kSecOIDOrganizationalUnitName) ?? ""
        let issuerCN = stringVal(kSecOIDX509V1IssuerName) ?? ""
        let notBefore = dateVal(kSecOIDX509V1ValidityNotBefore) ?? Date.distantPast
        let notAfter = dateVal(kSecOIDX509V1ValidityNotAfter) ?? Date.distantFuture

        var serialHex = ""
        if let d = SecCertificateCopyValues(kSecOIDX509V1SerialNumber, nil, nil) as? [CFString: Any],
           let entry = d[kSecOIDX509V1SerialNumber] as? [CFString: Any],
           let data = entry[kSecPropertyKeyValue as CFString] as? Data {
            serialHex = SHA.hex(data)
        }

        var type = "Unknown"
        if cn.contains("Apple Development") || cn.contains("iPhone Developer") { type = "Development" }
        else if cn.contains("Apple Distribution") || cn.contains("iPhone Distribution") { type = "Distribution" }
        else if cn.contains("Apple Push") { type = "Push" }

        let looksLikeTeamID = ou.count == 10 && !ou.isEmpty && ou.allSatisfy { $0.isUpperOrDigit }

        return CertificateDetails(
            label: cn,
            certType: type,
            teamID: looksLikeTeamID ? ou : "",
            teamName: org,
            subject: "CN=\(cn)" + (org.isEmpty ? "" : ", O=\(org)") + (ou.isEmpty ? "" : ", OU=\(ou)"),
            issuer: issuerCN,
            notBefore: notBefore,
            notAfter: notAfter,
            serialHex: serialHex,
            hasPrivateKey: hasKey)
    }

    // MARK: - Получение identity для подписи

    func resolveIdentity(certSHA1: String, chainDER: [Data]) throws -> (identity: SecIdentity, chain: [SecCertificate]) {
        guard let id = KeychainService.identity(certSHA1Hex: certSHA1) else {
            throw AppError.notFound("приватный ключ сертификата недоступен в Keychain")
        }
        let chain = chainDER.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !chain.isEmpty else { throw AppError.invalidFormat("цепочка сертификатов повреждена") }
        return (id, chain)
    }
}

private extension Character {
    var isUpperOrDigit: Bool { (isUppercase || isNumber) }
}
