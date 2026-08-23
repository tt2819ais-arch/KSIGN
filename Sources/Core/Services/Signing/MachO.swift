import Foundation

enum LE {
    static func u16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[o]) | (UInt16(d[o + 1]) << 8)
    }
    static func u32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | (UInt32(d[o + 1]) << 8)
            | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24)
    }
    static func u64(_ d: Data, _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(d[o + i]) << (8 * i) }
        return v
    }
}

enum BE {
    static func bytes<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
        var big = v.bigEndian
        return withUnsafeBytes(of: &big) { Array($0) }
    }
}

/// Контейнер FAT (universal binary).
enum Fat {
    static func isFat(_ d: Data) -> Bool {
        d.count > 8 && d[0] == 0xca && d[1] == 0xfe && d[2] == 0xba && d[3] == 0xbe
    }
    struct Slice { var cputype: UInt32; var cpusub: UInt32; var offset: Int; var size: Int; var align: UInt32 }

    static func slices(of d: Data) -> [Slice] {
        func bu32(_ o: Int) -> UInt32 {
            (UInt32(d[o]) << 24) | (UInt32(d[o + 1]) << 16)
                | (UInt32(d[o + 2]) << 8) | UInt32(d[o + 3])
        }
        let n = Int(bu32(4))
        var out: [Slice] = []
        for i in 0..<n {
            let b = 8 + i * 20
            out.append(Slice(cputype: bu32(b), cpusub: bu32(b + 4), offset: Int(bu32(b + 8)),
                             size: Int(bu32(b + 12)), align: bu32(b + 16)))
        }
        return out
    }

    /// Пересобирает FAT-контейнер из тонких слайсов.
    static func rebuild(_ parts: [(Slice, Data)]) -> Data {
        var headerSize = 8 + parts.count * 20
        var entries: [(Slice, Int)] = []
        for (slice, _) in parts {
            let alignment = 1 << Int(slice.align)
            let off = Align.up(headerSize, alignment)
            entries.append((slice, off))
            headerSize = off + slice.size
        }
        var out = Data()
        out.append(contentsOf: BE.bytes(UInt32(0xcafebabe)))
        out.append(contentsOf: BE.bytes(UInt32(parts.count)))
        for (i, (slice, _)) in parts.enumerated() {
            out.append(contentsOf: BE.bytes(slice.cputype))
            out.append(contentsOf: BE.bytes(slice.cpusub))
            out.append(contentsOf: BE.bytes(UInt32(entries[i].1)))
            out.append(contentsOf: BE.bytes(UInt32(slice.size)))
            out.append(contentsOf: BE.bytes(slice.align))
        }
        for (i, (_, data)) in parts.enumerated() {
            let pad = entries[i].1 - out.count
            if pad > 0 { out.append(Data(repeating: 0, count: pad)) }
            out.append(data)
        }
        return out
    }
}

struct SegmentInfo64 {
    let name: String
    let vmaddr: UInt64, vmsize: UInt64, fileoff: UInt64, filesize: UInt64
    let cmdOffset: Int
}

struct LoadCommand { let cmd: UInt32; let cmdsize: UInt32; let offset: Int }

/// Изменяемое представление одного тонкого (thin) Mach-O слайса.
struct MachOBinary {
    private(set) var data: Data

    init(_ data: Data) { self.data = data }

    var isMachO: Bool { data.count > 32 && LE.u32(data, 0) == 0xfeedfacf }
    var cputype: UInt32 { LE.u32(data, 4) }
    var ncmds: Int { Int(LE.u32(data, 16)) }
    var sizeofcmds: Int { Int(LE.u32(data, 20)) }

    func loadCommands() -> [LoadCommand] {
        var out: [LoadCommand] = []
        var off = 32
        let end = 32 + sizeofcmds
        while off + 8 <= end {
            let cmd = LE.u32(data, off), size = LE.u32(data, off + 4)
            guard size >= 8 else { break }
            out.append(LoadCommand(cmd: cmd, cmdsize: size, offset: off))
            off += Int(size)
        }
        return out
    }

    func segment(named name: String) -> SegmentInfo64? {
        for lc in loadCommands() where lc.cmd == 0x19 { // LC_SEGMENT_64
            let raw = data.subdata(in: (lc.offset + 8)..<(lc.offset + 24))
            let nameBytes = Array(raw).prefix { $0 != 0 }
            let segName = String(bytes: nameBytes, encoding: .utf8) ?? ""
            if segName != name { continue }
            return SegmentInfo64(name: name,
                                 vmaddr: LE.u64(data, lc.offset + 24),
                                 vmsize: LE.u64(data, lc.offset + 32),
                                 fileoff: LE.u64(data, lc.offset + 40),
                                 filesize: LE.u64(data, lc.offset + 48),
                                 cmdOffset: lc.offset)
        }
        return nil
    }

    /// LC_CODE_SIGNATURE (0x1d): cmdsize=16, dataoff=+8, datasize=+12
    func codeSignatureCmd() -> (cmdOffset: Int, dataoff: UInt32, datasize: UInt32)? {
        for lc in loadCommands() where lc.cmd == 0x1d {
            return (lc.offset, LE.u32(data, lc.offset + 8), LE.u32(data, lc.offset + 12))
        }
        return nil
    }

    mutating func patchCodeSignatureCmd(cmdOffset: Int?, dataoff: UInt32, datasize: UInt32) throws {
        if let off = cmdOffset {
            writeLE(dataoff, off + 8)
            writeLE(datasize, off + 12)
        } else {
            // Команды нет — добавляем новую в конец загрузочных команд.
            let insertAt = 32 + sizeofcmds
            guard data.count >= insertAt + 16 else {
                throw AppError.invalidFormat("в Mach-O нет свободного места под LC_CODE_SIGNATURE")
            }
            var cmd: [UInt8] = []
            cmd.append(contentsOf: BE.bytes(UInt32(0x1d)))
            cmd.append(contentsOf: BE.bytes(UInt32(16)))
            cmd.append(contentsOf: BE.bytes(dataoff))
            cmd.append(contentsOf: BE.bytes(datasize))
            data.replaceSubrange(insertAt..<(insertAt + 16), with: Data(cmd))
            writeLE(UInt32(ncmds + 1), 16)
            writeLE(UInt32(sizeofcmds + 16), 20)
        }
    }

    mutating func writeLE<T: FixedWidthInteger>(_ v: T, _ o: Int) {
        var val = v.littleEndian
        let bytes = withUnsafeBytes(of: &val) { Data($0) }
        data.replaceSubrange(o..<(o + MemoryLayout<T>.size), with: bytes)
    }
}
