import Foundation
import Security

enum KeychainService {

    static func allIdentities() -> [SecIdentity] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let refs = out as? [Any] else { return [] }
        return refs.compactMap { $0 as? SecIdentity }
    }

    static func certificateData(of identity: SecIdentity) -> (SecCertificate, Data)? {
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let c = cert else { return nil }
        let data = SecCertificateCopyData(c) as Data
        return (c, data)
    }

    /// Находит identity в Keychain по SHA-1 листового сертификата (сохранённому при импорте p12).
    static func identity(certSHA1Hex: String) -> SecIdentity? {
        for id in allIdentities() {
            if let (_, data) = certificateData(of: id),
               SHA.sha1Hex(data) == certSHA1Hex { return id }
        }
        return nil
    }

    static func privateKey(of identity: SecIdentity) -> SecKey? {
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess else { return nil }
        return key
    }

    static func deleteIdentity(certSHA1Hex: String) {
        guard let id = identity(certSHA1Hex: certSHA1Hex) else { return }
        SecItemDelete([kSecClass as String: kSecClassIdentity,
                       kSecValueRef as String: id] as CFDictionary)
    }
}
