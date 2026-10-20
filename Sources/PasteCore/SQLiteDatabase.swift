import Foundation
import CSQLite

/// A short-lived, serialized SQLite connection. Values always use bound parameters.
final class SQLiteDatabase {
    enum Value { case text(String), blob(Data), integer(Int64), real(Double), null }
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure(); sqlite3_close(handle); throw error
        }
        sqlite3_busy_timeout(handle, 10_000)
        try execute("PRAGMA foreign_keys=ON")
    }
    deinit { sqlite3_close(handle) }
    private func failure() -> Error {
        SnapshotRepositoryError.invalidData("本地数据库：\(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开")")
    }
    func execute(_ sql: String, _ values: [Value] = []) throws { try rows(sql, values) { _ in } }
    func rows(_ sql: String, _ values: [Value] = [], body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1), status: Int32
            switch value {
            case .text(let string): status = string.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .blob(let data): status = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            case .integer(let integer): status = sqlite3_bind_int64(statement, index, integer)
            case .real(let number): status = sqlite3_bind_double(statement, index, number)
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw failure() }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try body(statement)
            case SQLITE_DONE: return
            default: throw failure()
            }
        }
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    static func data(_ statement: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
    static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }; return String(cString: value)
    }
}
