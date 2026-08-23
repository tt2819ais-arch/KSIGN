import Foundation

enum CRC32 {
    static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            return c
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buf -> UInt32 in
            var c: UInt32 = 0xFFFFFFFF
            for b in buf { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
            return c ^ 0xFFFFFFFF
        }
    }

    static func checksum(fileAt url: URL) throws -> UInt32 {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var c: UInt32 = 0xFFFFFFFF
        while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty {
            chunk.withUnsafeBytes { buf in
                for b in buf { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
            }
        }
        return c ^ 0xFFFFFFFF
    }
}
