import Foundation

struct TLV {
    let tag: UInt8
    let start: Int
    let contentStart: Int
    let contentEnd: Int
    let end: Int

    static func parse(_ b: [UInt8], at start: Int) throws -> TLV {
        guard start >= 0, start + 2 <= b.count else {
            throw AppError.invalidFormat("DER: неожиданный конец данных")
        }
        let tag = b[start]
        var idx = start + 1
        let firstLenByte = b[idx]
        idx += 1
        var length = 0
        if firstLenByte & 0x80 == 0 {
            length = Int(firstLenByte)
        } else {
            let numBytes = Int(firstLenByte & 0x7F)
            guard numBytes > 0, idx + numBytes <= b.count else {
                throw AppError.invalidFormat("DER: некорректная длина")
            }
            for _ in 0..<numBytes {
                length = (length << 8) | Int(b[idx])
                idx += 1
            }
        }
        let cs = idx
        let ce = idx + length
        guard ce <= b.count else {
            throw AppError.invalidFormat("DER: длина выходит за границы данных")
        }
        return TLV(tag: tag, start: start, contentStart: cs, contentEnd: ce, end: ce)
    }

    func content(_ b: [UInt8]) -> [UInt8] { Array(b[contentStart..<contentEnd]) }
}

struct X509Info {
    var serialBytes: [UInt8]
    var notBefore: Date
    var notAfter: Date
    var issuerDER: [UInt8]
    var subjectCN: String
    var subjectO: String
    var subjectOU: String
    var issuerCN: String
}

/// Минимальный парсер X.509 (DER). Не зависит от SecCertificateCopyValues /
/// kSecOID*, которые удалены из новых SDK.
enum X509Parser {

    static func parse(der data: Data) throws -> X509Info {
        let b = Array(data)

        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
        let cert = try TLV.parse(b, at: 0)
        guard cert.tag == 0x30 else { throw AppError.invalidFormat("X.509: ожидался SEQUENCE") }

        let tbs = try TLV.parse(b, at: cert.contentStart)
        guard tbs.tag == 0x30 else { throw AppError.invalidFormat("X.509: ожидался TBSCertificate") }

        var pos = tbs.contentStart

        // [0] EXPLICIT version (опционально)
        if pos < tbs.contentEnd, b[pos] == 0xA0 {
            let ver = try TLV.parse(b, at: pos)
            pos = ver.end
        }

        // serialNumber INTEGER
        let serial = try TLV.parse(b, at: pos)
        guard serial.tag == 0x02 else { throw AppError.invalidFormat("X.509: ожидался serialNumber") }
        let serialBytes = serial.content(b)
        pos = serial.end

        // signature AlgorithmIdentifier
        let sigAlg = try TLV.parse(b, at: pos)
        guard sigAlg.tag == 0x30 else { throw AppError.invalidFormat("X.509: ожидался AlgorithmIdentifier") }
        pos = sigAlg.end

        // issuer Name
        let issuer = try TLV.parse(b, at: pos)
        guard issuer.tag == 0x30 else { throw AppError.invalidFormat("X.509: ожидался issuer") }
        let issuerDER = Array(b[issuer.start..<issuer.end])
        pos = issuer.end

        // validity ::= SEQUENCE { notBefore, notAfter }
        let validity = try TLV.parse(b, at: pos)
        guard validity.tag == 0x30 else { throw AppError.invalidFormat("X.509: ожидался validity") }
        let nb = try TLV.parse(b, at: validity.contentStart)
        let na = try TLV.parse(b, at: nb.end)
        let notBefore = parseTime(tag: nb.tag, bytes: nb.content(b))
        let notAfter = parseTime(tag: na.tag, bytes: na.content(b))

        // subject Name
        guard let subject = try? TLV.parse(b, at: na.end), subject.tag == 0x30 else {
            throw AppError.invalidFormat("X.509: ожидался subject")
        }

        let s = rdnFields(b, name: subject)
        let i = rdnFields(b, name: issuer)

        return X509Info(serialBytes: serialBytes,
                        notBefore: notBefore,
                        notAfter: notAfter,
                        issuerDER: issuerDER,
                        subjectCN: s.cn,
                        subjectO: s.o,
                        subjectOU: s.ou,
                        issuerCN: i.cn)
    }

    // MARK: - Разбор RelativeDistinguishedName

    private static func rdnFields(_ b: [UInt8], name: TLV) -> (cn: String, o: String, ou: String) {
        var cn = "", o = "", ou = ""
        var p = name.contentStart
        while p < name.contentEnd {
            guard let set = try? TLV.parse(b, at: p), set.tag == 0x31 else { break }
            var q = set.contentStart
            while q < set.contentEnd {
                guard let attr = try? TLV.parse(b, at: q), attr.tag == 0x30 else { break }
                if let oid = try? TLV.parse(b, at: attr.contentStart), oid.tag == 0x06,
                   let val = try? TLV.parse(b, at: oid.end) {
                    let oidBytes = oid.content(b)
                    let str = decodeString(tag: val.tag, bytes: val.content(b))
                    if oidBytes == [0x55, 0x04, 0x03] { cn = str }        // 2.5.4.3 CN
                    else if oidBytes == [0x55, 0x04, 0x0A] { o = str }    // 2.5.4.10 O
                    else if oidBytes == [0x55, 0x04, 0x0B] { ou = str }   // 2.5.4.11 OU
                }
                q = attr.end
            }
            p = set.end
        }
        return (cn, o, ou)
    }

    private static func decodeString(tag: UInt8, bytes: [UInt8]) -> String {
        let d = Data(bytes)
        switch tag {
        case 0x0C: return String(data: d, encoding: .utf8) ?? ""
        case 0x13, 0x16: return String(data: d, encoding: .ascii) ?? String(data: d, encoding: .utf8) ?? ""
        case 0x14: return String(data: d, encoding: .isoLatin1) ?? ""
        case 0x1E: return String(data: d, encoding: .utf16BigEndian) ?? ""
        default: return String(data: d, encoding: .utf8) ?? ""
        }
    }

    private static func parseTime(tag: UInt8, bytes: [UInt8]) -> Date {
        let s = String(decoding: bytes, as: UTF8.self)
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = (tag == 0x18) ? "yyyyMMddHHmmss'Z'" : "yyMMddHHmmss'Z'"
        return f.date(from: s) ?? .distantPast
    }
}
