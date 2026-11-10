import Foundation
import SQLite3

public enum DatabaseError: Error, CustomStringConvertible, Sendable {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)
    case bind(String)

    public var description: String {
        switch self {
        case .open(let message): "データベースを開けません: \(message)"
        case .prepare(let message, let sql): "SQLの準備に失敗しました: \(message) [\(sql)]"
        case .step(let message, let sql): "SQLの実行に失敗しました: \(message) [\(sql)]"
        case .bind(let message): "パラメータの設定に失敗しました: \(message)"
        }
    }
}

public enum SQLValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public init(_ string: String?) { self = string.map(SQLValue.text) ?? .null }
    public init(_ int: Int64?) { self = int.map(SQLValue.integer) ?? .null }
    public init(_ int: Int) { self = .integer(Int64(int)) }
    public init(_ double: Double?) { self = double.map(SQLValue.real) ?? .null }
    public init(_ bool: Bool) { self = .integer(bool ? 1 : 0) }
    public init(_ date: Date?) { self = date.map { .real($0.timeIntervalSince1970) } ?? .null }
    public init(_ uuid: UUID?) { self = uuid.map { .text($0.uuidString) } ?? .null }
}

public struct Row: Sendable {
    let values: [String: SQLValue]

    public func string(_ column: String) -> String? {
        if case .text(let value) = values[column] { return value }
        return nil
    }

    public func int(_ column: String) -> Int64? {
        switch values[column] {
        case .integer(let value): value
        case .real(let value): Int64(value)
        default: nil
        }
    }

    public func double(_ column: String) -> Double? {
        switch values[column] {
        case .real(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }

    public func bool(_ column: String) -> Bool { (int(column) ?? 0) != 0 }

    public func date(_ column: String) -> Date? {
        double(column).map(Date.init(timeIntervalSince1970:))
    }

    public func uuid(_ column: String) -> UUID? {
        string(column).flatMap(UUID.init(uuidString:))
    }
}

/// SQLite3 C API の薄いラッパー。アクセスはアクター内で直列化される。
public actor SQLiteDatabase {
    nonisolated(unsafe) private let handle: OpaquePointer

    /// `url` が nil の場合はインメモリデータベースを開く（テスト用）。
    public init(url: URL?) throws {
        var db: OpaquePointer?
        let path = url?.path(percentEncoded: false) ?? ":memory:"
        if let url {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(db)
            throw DatabaseError.open(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;", nil, nil, nil)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    public func executeScript(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw DatabaseError.step(message, sql: sql)
        }
    }

    public func execute(_ sql: String, _ parameters: [SQLValue] = []) throws {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw DatabaseError.step(lastError, sql: sql)
        }
    }

    public func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [Row] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw DatabaseError.step(lastError, sql: sql) }
            var values: [String: SQLValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                values[name] = column(statement, index)
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    /// 複数の書き込みを1トランザクションにまとめる。
    public func transaction<T: Sendable>(_ body: @Sendable (isolated SQLiteDatabase) throws -> T) throws -> T {
        try executeScript("BEGIN IMMEDIATE TRANSACTION")
        do {
            let value = try body(self)
            try executeScript("COMMIT")
            return value
        } catch {
            try? executeScript("ROLLBACK")
            throw error
        }
    }

    public func userVersion() throws -> Int {
        Int(try query("PRAGMA user_version").first?.int("user_version") ?? 0)
    }

    public func setUserVersion(_ version: Int) throws {
        try executeScript("PRAGMA user_version = \(version)")
    }

    // MARK: - Private

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    private func prepare(_ sql: String, _ parameters: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.prepare(lastError, sql: sql)
        }
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32 = switch value {
            case .null:
                sqlite3_bind_null(statement, index)
            case .integer(let int):
                sqlite3_bind_int64(statement, index, int)
            case .real(let double):
                sqlite3_bind_double(statement, index, double)
            case .text(let string):
                sqlite3_bind_text(statement, index, string, -1, Self.transient)
            case .blob(let data):
                data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
                }
            }
            guard result == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw DatabaseError.bind(lastError)
            }
        }
        return statement
    }

    private func column(_ statement: OpaquePointer, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            return .text(String(cString: sqlite3_column_text(statement, index)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
        }
    }
}
