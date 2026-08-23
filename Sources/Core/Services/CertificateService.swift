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

    /// Пароль используется ОДИН раз и нигде не сохраняется.
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

    // MARK: - Информация о сертификате через собственный X.509-парсер

    static func describe(chain: [SecCertificate], hasKey: Bool) -> CertificateDetails {
        let leaf = chain[0]
        let der = SecCertificateCopyData(leaf) as Data
        let info: X509Info
        if let parsed = try? X509Parser.parse(der: der) {
            info = parsed
        } else {
            info = X509Info(serialBytes: [], notBefore: .distantPast, notAfter: .distantFuture,
                            issuerDER: [], subjectCN: "Без имени", subjectO: "", subjectOU: "",
                            issuerCN: "")
        }

        let cn = info.subjectCN.isEmpty ? "Без имени" : info.subjectCN
        var type = "Unknown"
        if cn.contains("Apple Development") || cn.contains("iPhone Developer") { type = "Development" }
        else if cn.contains("Apple Distribution") || cn.contains("iPhone Distribution") { type = "Distribution" }
        else if cn.contains("Apple Push") { type = "Push" }

        let org = info.subjectO
        let ou = info.subjectOU
        let looksLikeTeamID = ou.count == 10 && ou.allSatisfy { $0.isUpperOrDigit }

        var serialHex = ""
        if !info.serialBytes.isEmpty {
            serialHex = SHA.hex(Data(info.serialBytes))
        }

        return CertificateDetails(
            label: cn,
            certType: type,
            teamID: looksLikeTeamID ? ou : "",
            teamName: org,
            subject: "CN=\(cn)" + (org.isEmpty ? "" : ", O=\(org)") + (ou.isEmpty ? "" : ", OU=\(ou)"),
            issuer: info.issuerCN,
            notBefore: info.notBefore,
            notAfter: info.notAfter,
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
    var isUpperOrDigit: Bool { isUppercase || isNumber }
}
