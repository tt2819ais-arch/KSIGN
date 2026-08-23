import Foundation

/// Мини-энкодер DER — ровно то, что нужно для построения CMS SignedData.
enum DER {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [tag]
        let len = content.count
        if len < 0x80 {
            out.append(UInt8(len))
        } else {
            var bytes: [UInt8] = []
            var v = len
            while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
            out.append(UInt8(0x80 | bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(contentsOf: content)
        return out
    }

    static func seq(_ parts: [[UInt8]]) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
    static func set(_ parts: [[UInt8]]) -> [UInt8] {
        tlv(0x31, parts.sorted { lexicographic($0, $1) }.flatMap { $0 })
    }
    static func ctxImplicitPrimitive(_ n: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0x80 | n, content) }
    static func ctxExplicit(_ n: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xA0 | n, content) }

    static func lexicographic(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x < y }
        return a.count <= b.count
    }

    static func integer(_ v: Int) -> [UInt8] {
        var v = v
        precondition(v >= 0)
        var bytes: [UInt8] = []
        repeat { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 } while v > 0
        if bytes.first.map({ $0 & 0x80 }) == .some(0x80) { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }

    /// INTEGER из big-endian байт (серийный номер сертификата).
    static func integer(bytes raw: [UInt8]) -> [UInt8] {
        var b = raw
        while b.count > 1 && b.first == 0 { b.removeFirst() }
        if b.first.map({ $0 & 0x80 }) == .some(0x80) { b.insert(0, at: 0) }
        if b.isEmpty { b = [0] }
        return tlv(0x02, b)
    }

    static func null() -> [UInt8] { [0x05, 0x00] }
    static func octetString(_ d: Data) -> [UInt8] { tlv(0x04, Array(d)) }
    static func utf8(_ s: String) -> [UInt8] { tlv(0x0C, Array(s.utf8)) }

    static func oid(_ dotted: String) -> [UInt8] {
        let parts = dotted.split(separator: ".").compactMap { UInt32($0) }
        var bytes: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for p in parts.dropFirst(2) {
            var v = p, tmp: [UInt8] = []
            tmp.append(UInt8(v & 0x7f)); v >>= 7
            while v > 0 { tmp.insert(UInt8(v & 0x7f) | 0x80, at: 0); v >>= 7 }
            bytes.append(contentsOf: tmp)
        }
        return tlv(0x06, bytes)
    }

    static func utcTime(_ date: Date) -> [UInt8] {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Array(f.string(from: date).utf8))
    }
}
