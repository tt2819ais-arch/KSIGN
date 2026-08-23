import Foundation
import CryptoKit

/// Полная переподпись одного тонкого Mach-O:
/// усечение старого блока подписи, патчинг __LINKEDIT, сборка CodeDirectory v0x20400,
/// SuperBlob (CodeDirectory + Requirements + Entitlements + CMS).
enum CodeSigner {

    static func resign(bin: inout MachOBinary,
                       identifier: String,
                       teamID: String,
                       entitlementsXML: Data,
                       infoPlistData: Data,
                       codeResourcesData: Data?,
                       isMainExecutable: Bool,
                       cms: (_ codeDirectory: Data) throws -> Data,
                       log: (String) -> Void) throws {
        guard bin.isMachO else { throw AppError.invalidFormat("файл не является Mach-O") }
        let pageSize = 4096

        let old = bin.codeSignatureCmd()
        // 1. Убираем старый блок подписи (load command остаётся — обновим его поля).
        if let old, old.dataoff > 0, Int(old.dataoff) <= bin.data.count {
            bin.data = bin.data.subdata(in: 0..<Int(old.dataoff))
        }
        let contentLen = bin.data.count

        guard let linkedit = bin.segment(named: "__LINKEDIT"),
              let text = bin.segment(named: "__TEXT") else {
            throw AppError.invalidFormat("в Mach-O отсутствуют сегменты __TEXT/__LINKEDIT")
        }

        // 2. Статические блобы
        let reqBlob = Data([0xfa, 0xde, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x00])
        let entBlob = entitlementsXML

        // 3. Измеряем размер CMS «пустышкой» (реальный CMS может отличаться на пару байт
        //    для EC-ключей — компенсируется нулевым паддингом в конце).
        let dummyCMS = try cms(Data(repeating: 0, count: 32))

        // 4. Раскладка: блоб выравниваем на 16 байт после контента.
        let dataoff = Align.up(contentLen, 16)
        let codeLimit = dataoff
        let pageCount = (codeLimit + pageSize - 1) / pageSize

        let identBytes = Array(identifier.utf8) + [0]
        let teamBytes = Array(teamID.utf8) + [0]
        let specialCount = 5
        let cdLen = 96 + identBytes.count + teamBytes.count + 32 * specialCount + 32 * pageCount
        let sbLen = 8 + 8 * 4 + pad4(cdLen) + pad4(reqBlob.count) + pad4(entBlob.count) + dummyCMS.count

        // 5. Патчим сегмент __LINKEDIT под новый размер файла.
        let newFileSize = dataoff + sbLen
        bin.writeLE(UInt64(newFileSize - Int(linkedit.fileoff)), linkedit.cmdOffset + 48)
        bin.writeLE(UInt64(max(pageSize, Align.up(newFileSize - Int(linkedit.fileoff), pageSize))),
                    linkedit.cmdOffset + 32)

        // 6. Заголовок LC_CODE_SIGNATURE
        try bin.patchCodeSignatureCmd(cmdOffset: old?.cmdOffset,
                                      dataoff: UInt32(dataoff), datasize: UInt32(sbLen))

        // 7. Выравнивающие нули до начала блоба
        if bin.data.count < dataoff {
            bin.data.append(Data(repeating: 0, count: dataoff - bin.data.count))
        }

        // 8. Хеши страниц по итоговому содержимому (заголовки уже пропатчены)
        var pageHashes: [Data] = []
        pageHashes.reserveCapacity(pageCount)
        for p in 0..<pageCount {
            let start = p * pageSize
            let end = min(start + pageSize, codeLimit)
            pageHashes.append(SHA.sha256(bin.data.subdata(in: start..<end)))
        }
        // Спец-слоты: индекс 4 = слот -1 (Info.plist), 3 = -2 (Requirements),
        // 2 = -3 (CodeResources), 1 = -4 (Entitlements), 0 — резервный.
        var special: [Data?] = Array(repeating: nil, count: specialCount)
        special[4] = SHA.sha256(infoPlistData)
        special[3] = SHA.sha256(reqBlob)
        if let cr = codeResourcesData { special[2] = SHA.sha256(cr) }
        special[1] = SHA.sha256(entBlob)

        let cd = buildCodeDirectory(ident: identBytes, team: teamBytes,
                                    codeLimit: codeLimit, pageCount: pageCount,
                                    specialCount: specialCount,
                                    special: special, pages: pageHashes,
                                    execBase: text.fileoff,
                                    execLimit: text.fileoff + text.filesize,
                                    execFlags: isMainExecutable ? 0x1 : 0)
        let realCMS = try cms(cd)

        // 9. SuperBlob; при расхождении размеров (ECDSA) дополняем нулями до sbLen —
        //    верификатор читает фактическую длину из заголовка SuperBlob.
        var sb = buildSuperBlob(entries: [
            (0, cd), (2, reqBlob), (5, entBlob), (0x10000, realCMS)
        ])
        if sb.count < sbLen {
            sb.append(Data(repeating: 0, count: sbLen - sb.count))
        }
        guard sb.count == sbLen else {
            throw AppError.invalidFormat("расхождение расчёта SuperBlob (\(sb.count) ≠ \(sbLen))")
        }
        bin.data.append(sb)
        log("Подписано: \(identifier) (cdhash \(SHA.hex(SHA.sha1(cd)).prefix(16))…)")
    }

    // MARK: - CodeDirectory (версия 0x20400, все поля BIG-ENDIAN)

    private static func buildCodeDirectory(ident: [UInt8], team: [UInt8],
                                           codeLimit: Int, pageCount: Int, specialCount: Int,
                                           special: [Data?], pages: [Data],
                                           execBase: UInt64, execLimit: UInt64, execFlags: UInt64) -> Data {
        let headerSize = 96
        let identOff = headerSize
        let teamOff = identOff + ident.count
        let specialOff = teamOff + team.count
        let hashOff = specialOff + 32 * specialCount

        var b: [UInt8] = []
        func put32(_ v: UInt32) { b.append(contentsOf: BE.bytes(v)) }
        func put64(_ v: UInt64) { b.append(contentsOf: BE.bytes(v)) }

        put32(0xfade0cc0)          // magic CSMAGIC_CODEDIRECTORY
        put32(0)                   // length — заполнится фактическим размером ниже
        put32(0x20400)             // version
        put32(0)                   // flags
        put32(UInt32(hashOff))     // hashOffset
        put32(UInt32(identOff))    // identOffset
        put32(UInt32(specialCount))
        put32(UInt32(pageCount))
        put32(UInt32(codeLimit))
        b.append(32)               // hashSize (SHA-256)
        b.append(2)                // hashType (SHA256)
        b.append(0)                // spare
        b.append(12)               // pageSize (log2)
        put32(0)                   // spare2
        put32(0)                   // scatterOffset
        put32(UInt32(teamOff))     // teamOffset
        put32(0)                   // spare3
        put64(0)                   // codeLimit64
        put64(execBase)
        put64(execLimit)
        put64(execFlags)
        put32(0)                   // runtime
        put32(0)                   // preEncryptOffset

        b.append(contentsOf: ident)
        b.append(contentsOf: team)
        // Спец-слоты пишутся от старшего к младшему: слот -1 оказывается последним,
        // непосредственно перед хешами страниц.
        for i in 0..<specialCount {
            b.append(contentsOf: Array(special[i] ?? Data(repeating: 0, count: 32)))
        }
        for h in pages { b.append(contentsOf: Array(h)) }

        var out = Data(b)
        out.replaceSubrange(4..<8, with: Data(BE.bytes(UInt32(out.count))))
        return out
    }

    private static func pad4(_ n: Int) -> Int { Align.up(n, 4) }

    private static func buildSuperBlob(entries: [(UInt32, Data)]) -> Data {
        var out = Data()
        out.append(contentsOf: BE.bytes(UInt32(0xfade0b01)))
        out.append(contentsOf: BE.bytes(UInt32(entries.count)))
        var offset = 8 + 8 * entries.count
        for (type, data) in entries {
            out.append(contentsOf: BE.bytes(type))
            out.append(contentsOf: BE.bytes(UInt32(offset)))
            offset += pad4(data.count)
        }
        var body = Data()
        for (_, data) in entries {
            body.append(data)
            let pad = pad4(data.count) - data.count
            if pad > 0 { body.append(Data(repeating: 0, count: pad)) }
        }
        out.append(body)
        return out
    }
}
