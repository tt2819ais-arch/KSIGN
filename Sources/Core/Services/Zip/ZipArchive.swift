import Foundation
import Compression

/// Минимальный, но полноценный ZIP (методы store/deflate, без ZIP64).
final class ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let crc32: UInt32
        let compSize: Int
        let uncompSize: Int
        let localOffset: Int
        let unixMode: UInt16
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    private let map: Data
    private(set) var entries: [Entry] = []

    init(url: URL) throws {
        map = try Data(contentsOf: url, options: .mappedIfSafe)
        try parseCentralDirectory()
    }

    private func u16(_ o: Int) -> UInt16 { map[o] | (UInt16(map[o+1]) << 8) }
    private func u32(_ o: Int) -> UInt32 {
        UInt32(map[o]) | (UInt32(map[o+1]) << 8) | (UInt32(map[o+2]) << 16) | (UInt32(map[o+3]) << 24)
    }

    private func parseCentralDirectory() throws {
        let count = map.count
        guard count > 22 else { throw AppError.invalidFormat("файл слишком мал для ZIP") }
        var eocd = -1
        let lower = max(0, count - 22 - 65535)
        var i = count - 22
        while i >= lower {
            if u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw AppError.invalidFormat("EOCD ZIP не найден") }
        let total = Int(u16(eocd + 10))
        var ptr = Int(u32(eocd + 16))
        let end = ptr + Int(u32(eocd + 12))
        for _ in 0..<total {
            guard ptr + 46 <= end, u32(ptr) == 0x02014b50 else { break }
            let method = u16(ptr + 10)
            let crc = u32(ptr + 16)
            let compSize = Int(u32(ptr + 20)), uncompSize = Int(u32(ptr + 24))
            let nameLen = Int(u16(ptr + 28)), extraLen = Int(u16(ptr + 29)), commLen = Int(u16(ptr + 30))
            let extAttrs = u32(ptr + 38)
            let creatorSys = u16(ptr + 4) >> 8
            let mode: UInt16 = creatorSys == 3 ? UInt16((extAttrs >> 16) & 0xFFFF) : 0
            let localOffset = Int(u32(ptr + 42))
            let nameData = map.subdata(in: (ptr+46)..<(ptr+46+nameLen))
            guard let name = String(data: nameData, encoding: .utf8) else { break }
            guard compSize != 0xFFFFFFFF else { throw AppError.invalidFormat("ZIP64 не поддерживается") }
            entries.append(Entry(name: name, method: method, crc32: crc, compSize: compSize,
                                 uncompSize: uncompSize, localOffset: localOffset, unixMode: mode))
            ptr += 46 + nameLen + extraLen + commLen
        }
    }

    func entry(named name: String) -> Entry? { entries.first { $0.name == name } }

    /// Диапазон сырого блока в контейнере (локальный заголовок + данные [+ дескриптор]).
    func rawBlockRange(_ e: Entry) throws -> Range<Int> {
        let lo = e.localOffset
        guard u32(lo) == 0x04034b50 else { throw AppError.invalidFormat("битый локальный заголовок: \(e.name)") }
        let flags = u16(lo + 6)
        let nameLen = Int(u16(lo + 26)), extraLen = Int(u16(lo + 28))
        let start = lo + 30 + nameLen + extraLen
        let end = start + e.compSize + ((flags & 0x8) != 0 ? 16 : 0)
        return start..<end
    }

    func readCompressed(_ e: Entry) throws -> Data {
        let r = try rawBlockRange(e)
        let dataStart = r.lowerBound
        return map.subdata(in: dataStart..<(dataStart + e.compSize))
    }

    func read(_ e: Entry) throws -> Data {
        let raw = try readCompressed(e)
        switch e.method {
        case 0: return raw
        case 8:
            guard let out = Deflate.decode(raw, expected: e.uncompSize) else {
                throw AppError.invalidFormat("не удалось распаковать \(e.name)")
            }
            return out
        default: throw AppError.invalidFormat("метод сжатия \(e.method) не поддерживается (\(e.name))")
        }
    }

    func extractAll(to dir: URL,
                    progress: (_ done: Int, _ total: Int) -> Bool = { _, _ in true }) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fm = FileManager.default
        for (idx, e) in entries.enumerated() {
            guard progress(idx, entries.count) else { throw CancellationError() }
            let dst = dir.appendingPathComponent(e.name)
            if e.isDirectory {
                try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try read(e)
            try data.write(to: dst)
            if e.unixMode & 0o111 != 0 { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path) }
        }
    }
}

enum Deflate {
    static func encode(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        var dst = Data(count: data.count + 64)
        let written = dst.withUnsafeMutableBytes { dbuf -> Int in
            data.withUnsafeBytes { sbuf in
                compression_encode_buffer(dbuf.bindMemory(to: UInt8.self).capacity,
                                          dbuf.bindMemory(to: UInt8.self).capacity,
                                          sbuf.bindMemory(to: UInt8.self).baseAddress!,
                                          data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return dst.prefix(written)
    }

    static func decode(_ data: Data, expected: Int) -> Data? {
        var cap = max(expected, 4096)
        while cap <= (1 << 30) {
            var dst = Data(count: cap)
            let written = dst.withUnsafeMutableBytes { dbuf -> Int in
                data.withUnsafeBytes { sbuf in
                    compression_decode_buffer(dbuf.bindMemory(to: UInt8.self).capacity,
                                              dbuf.bindMemory(to: UInt8.self).capacity,
                                              sbuf.bindMemory(to: UInt8.self).baseAddress!,
                                              data.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 { return dst.prefix(written) }
            cap *= 4
        }
        return nil
    }
}

/// Потоковый писатель ZIP. Поддерживает «вербатим»-копирование записей
/// исходного IPA (без распаковки) — критично для больших файлов.
final class ZipWriter {
    private let fh: FileHandle
    private var offset: Int = 0
    private var central = Data()

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fh = try FileHandle(forWritingTo: url)
    }
    deinit { try? fh.close() }

    private func write(_ d: Data) { fh.write(d); offset += d.count }

    private static func dosTime(_ date: Date = .init()) -> (time: UInt16, date: UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let y = max(1980, c.year ?? 1980) - 1980
        let time = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        let dat = UInt16((y << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        return (time, dat)
    }

    private func put16(_ v: UInt16, into arr: inout [UInt8]) {
        arr.append(UInt8(v & 0xff)); arr.append(UInt8(v >> 8))
    }
    private func put32(_ v: UInt32, into arr: inout [UInt8]) {
        arr.append(UInt8(v & 0xff)); arr.append(UInt8((v >> 8) & 0xff))
        arr.append(UInt8((v >> 16) & 0xff)); arr.append(UInt8(v >> 24))
    }

    func add(name: String, data: Data, mode: UInt16 = 0o644, compress: Bool = true) throws {
        let crc = CRC32.checksum(data)
        var payload = data
        var method: UInt16 = 0
        if compress, data.count > 128, let enc = Deflate.encode(data), enc.count < data.count {
            payload = enc; method = 8
        }
        let nameBytes = Array(name.utf8)
        let t = Self.dosTime()

        var local: [UInt8] = []
        put32(0x04034b50, into: &local); put16(20, into: &local); put16(0, into: &local)
        put16(method, into: &local); put16(t.time, into: &local); put16(t.date, into: &local)
        put32(crc, into: &local); put32(UInt32(payload.count), into: &local)
        put32(UInt32(data.count), into: &local)
        put16(UInt16(nameBytes.count), into: &local); put16(0, into: &local)
        write(Data(local)); write(Data(nameBytes)); write(payload)

        var cd: [UInt8] = []
        put32(0x02014b50, into: &cd); put16((3 << 8) | 20, into: &cd); put16(20, into: &cd)
        put16(0, into: &cd); put16(method, into: &cd); put16(t.time, into: &cd); put16(t.date, into: &cd)
        put32(crc, into: &cd); put32(UInt32(payload.count), into: &cd); put32(UInt32(data.count), into: &cd)
        put16(UInt16(nameBytes.count), into: &cd); put16(0, into: &cd); put16(0, into: &cd)
        put16(0, into: &cd); put16(0, into: &cd); put32(UInt32(mode) << 16, into: &cd)
        put32(UInt32(offset), into: &cd)
        central.append(Data(cd)); central.append(Data(nameBytes))
        offset += nameBytes.count
    }

    /// Копирует запись исходного архива байт-в-байт (опционально переименовывая),
    /// сохраняя метод сжатия, CRC и права — без распаковки.
    func addVerbatim(from reader: ZipReader, entry e: ZipReader.Entry, newName: String? = nil) throws {
        let block = try reader.rawBlockRange(e)
        let lo = e.localOffset
        let flags = reader.u16lo == nil ? 0 : 0 // placeholder, заменяется ниже
        _ = flags
        let localFlags = readerLocalFlags(reader, lo)
        let nameLen = Int(reader.u16(lo + 26)), extraLen = Int(reader.u16(lo + 28))
        let headerRange = lo..<(lo + 30 + nameLen + extraLen)
        var header = reader.map.subdata(in: headerRange)
        let payload = reader.map.subdata(in: block.lowerBound..<(block.lowerBound + e.compSize))

        let nameBytes = Array((newName ?? e.name).utf8)
        // перезаписываем длины имени/extra в копии локального заголовка
        header.replaceSubrange(26..<28, with: with16(UInt16(nameBytes.count)))
        header.replaceSubrange(28..<30, with: with16(0))

        write(header.subdata(in: 0..<30)); write(Data(nameBytes))
        write(payload)
        if localFlags & 0x8 != 0 {
            write(reader.map.subdata(in: (block.lowerBound + e.compSize)..<block.upperBound))
        }

        var cd: [UInt8] = []
        put32(0x02014b50, into: &cd); put16((3 << 8) | 20, into: &cd); put16(20, into: &cd)
        put16(localFlags, into: &cd); put16(e.method, into: &cd); put16(0, into: &cd); put16(0, into: &cd)
        put32(e.crc32, into: &cd); put32(UInt32(e.compSize), into: &cd); put32(UInt32(e.uncompSize), into: &cd)
        put16(UInt16(nameBytes.count), into: &cd); put16(0, into: &cd); put16(0, into: &cd)
        put16(0, into: &cd); put16(0, into: &cd); put32(UInt32(e.unixMode) << 16, into: &cd)
        put32(UInt32(offset), into: &cd)
        central.append(Data(cd)); central.append(Data(nameBytes))
        offset += nameBytes.count
    }

    fileprivate func u16(_ o: Int) -> UInt16 { map16(o) }
    private func with16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8)]) }

    func finish() throws {
        write(central)
        var eocd: [UInt8] = []
        put32(0x06054b50, into: &eocd); put16(0, into: &eocd); put16(0, into: &eocd)
        put16(0, into: &eocd); put16(0, into: &eocd)
        put32(UInt32(central.count), into: &eocd); put32(UInt32(offset), into: &eocd)
        put16(0, into: &eocd)
        write(Data(eocd))
        try fh.close()
    }
}

// Небольшие хелперы чтения для addVerbatim (map закрыт в ZipReader — дублируем через сабдатас)
private func readerLocalFlags(_ r: ZipReader, _ lo: Int) -> UInt16 { r.u16(lo + 6) }
