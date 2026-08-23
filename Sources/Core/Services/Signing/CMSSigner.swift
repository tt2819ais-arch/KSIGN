import Foundation
import Security
import CryptoKit

struct SigningIdentity {
    let identity: SecIdentity
    let chain: [SecCertificate]   // chain[0] — листовой
}

/// Строит CMS (PKCS#7) SignedData — блок Signature в SuperBlob кодовой подписи.
enum CMSSigner {

    static let oidData          = "1.2.840.113549.1.7.1"
    static let oidSignedData    = "1.2.840.113549.1.7.2"
    static let oidSHA256        = "2.16.840.1.101.3.4.2.1"
    static let oidRSA           = "1.2.840.113549.1.1.1"
    static let oidECDSA256      = "1.2.840.10045.4.3.2"
    static let oidContentType   = "1.2.840.113549.1.9.3"
    static let oidSigningTime   = "1.2.840.113549.1.9.5"
    static let oidMessageDigest = "1.2.840.113549.1.9.4"

    static func signedData(contentDER: Data, id: SigningIdentity, signingTime: Date = Date()) throws -> Data {
        let leaf = id.chain[0]
        let key = try privateKey(id.identity)

        let keyAttrs = SecKeyCopyAttributes(key) as? [CFString: Any]
        let isRSA = (keyAttrs?[kSecAttrKeyType] as? String) == (kSecAttrKeyTypeRSA as String)

        // IssuerAndSerialNumber — берём из собственного X.509-парсера
        let leafDER = SecCertificateCopyData(leaf) as Data
        let certInfo = try X509Parser.parse(der: leafDER)
        let sid = DER.seq([
            certInfo.issuerDER,
            DER.integer(bytes: certInfo.serialBytes)
        ])

        let digestAlg = DER.seq([DER.oid(oidSHA256), DER.null()])
        let encap = DER.seq([DER.oid(oidData)])

        // Атрибуты (signedAttrs)
        let contentTypeAttr = DER.seq([DER.oid(oidContentType),
                                       DER.set([DER.seq([DER.oid(oidData)])])])
        let signingTimeAttr = DER.seq([DER.oid(oidSigningTime),
                                       DER.set([DER.utcTime(signingTime)])])
        let msgDigest = SHA.sha256(contentDER)
        let msgDigestAttr = DER.seq([DER.oid(oidMessageDigest),
                                     DER.set([DER.octetString(msgDigest)])])
        let attrsTLVs = [contentTypeAttr, signingTimeAttr, msgDigestAttr].sorted { DER.lexicographic($0, $1) }
        let signedAttrsTagged = DER.ctxImplicitPrimitive(0, attrsTLVs.flatMap { $0 })

        // Подпись атрибутов приватным ключом из Keychain
        let alg: SecKeyAlgorithm = isRSA ? .rsaSignatureMessagePKCS1v15SHA256
                                         : .ecdsaSignatureMessageX962SHA256
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, alg, Data(signedAttrsTagged) as CFData, &err) as Data?,
              err == nil else {
            let msg = err?.takeRetainedValue().localizedDescription ?? "неизвестная ошибка ключа"
            throw AppError.incompatible("подпись не создана: \(msg)")
        }
        let sigBytes = isRSA ? Array(sig) : Array(ecdsaDER(from: sig))
        let digestEncAlg = isRSA ? DER.seq([DER.oid(oidRSA), DER.null()])
                                 : DER.seq([DER.oid(oidECDSA256)])

        let signerInfo = DER.seq([
            DER.integer(1),
            sid,
            digestAlg,
            signedAttrsTagged,
            digestEncAlg,
            DER.octetString(Data(sigBytes))
        ])

        var certsPayload: [UInt8] = []
        for cert in id.chain {
            certsPayload.append(contentsOf: Array(SecCertificateCopyData(cert) as Data))
        }
        let certsTagged = DER.ctxImplicitPrimitive(0, certsPayload)

        let sd = DER.seq([
            DER.integer(1),
            DER.set([digestAlg]),
            encap,
            certsTagged,
            DER.set([signerInfo])
        ])
        return Data(DER.seq([DER.oid(oidSignedData), DER.ctxExplicit(0, sd)]))
    }

    private static func privateKey(_ id: SecIdentity) throws -> SecKey {
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(id, &key) == errSecSuccess, let k = key else {
            throw AppError.notFound("приватный ключ недоступен в Keychain")
        }
        return k
    }

    /// SecKey возвращает ECDSA-подпись как raw r||s — конвертируем в DER.
    private static func ecdsaDER(from raw: Data) -> Data {
        let half = raw.count / 2
        func intPart(_ slice: Data) -> [UInt8] {
            var b = Array(slice)
            while b.count > 1 && b.first == 0 { b.removeFirst() }
            if b.first.map({ $0 & 0x80 }) == .some(0x80) { b.insert(0, at: 0) }
            return b
        }
        let r = intPart(raw.subdata(in: 0..<half))
        let s = intPart(raw.subdata(in: half..<raw.count))
        return Data(DER.seq([DER.tlv(0x02, r), DER.tlv(0x02, s)]))
    }
}
