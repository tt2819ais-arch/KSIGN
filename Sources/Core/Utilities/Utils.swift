import Foundation
import CryptoKit

enum SHA {
    static func sha256(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }
    static func sha1(_ d: Data) -> Data { Data(CryptoKit.SHA1.hash(data: d)) }
    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func sha1Hex(_ d: Data) -> String { hex(sha1(d)) }
}

enum Align {
    static func up(_ v: Int, _ a: Int) -> Int { (v + a - 1) / a * a }
}

enum Plist {
    static func object(at url: URL) throws -> Any {
        let data = try Data(contentsOf: url)
        return try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }
    static func dict(at url: URL) throws -> [String: Any] {
        guard let d = try object(at: url) as? [String: Any] else {
            throw AppError.invalidFormat("Info.plist имеет неожиданный формат")
        }
        return d
    }
    static func data(_ obj: Any, binary: Bool = true) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: obj,
                                           format: binary ? .binary : .xml, options: 0)
    }
}

enum BytesFmt {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum AppError: LocalizedError {
    case invalidFormat(String)
    case notFound(String)
    case incompatible(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let m): return "Неверный формат файла: \(m)"
        case .notFound(let m):      return "Не найдено: \(m)"
        case .incompatible(let m):  return "Несовместимость: \(m)"
        }
    }
}

enum LogLevel: String, Codable { case info, warn, error, success }

struct LogLine: Identifiable, Codable {
    let id: UUID
    let date: Date
    let level: LogLevel
    let message: String
    init(_ level: LogLevel, _ message: String) {
        self.id = UUID(); self.date = .init(); self.level = level; self.message = message
    }
}

/// Безопасный логгер процесса подписи.
/// ВАЖНО: секреты (пароли p12, ключи) в лог принципиально не попадают —
/// они никогда не передаются в этот класс.
actor SignLog {
    private(set) var lines: [LogLine] = []
    func add(_ level: LogLevel, _ msg: String) {
        lines.append(LogLine(level, msg))
    }
    func snapshot() -> [LogLine] { lines }
}
