import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal read-only sqlite3 wrapper. T3 Code owns the database; we only ever read.
final class SQLiteConnection {
    enum Failure: Error, LocalizedError {
        case open(String)
        case prepare(String)

        var errorDescription: String? {
            switch self {
            case let .open(message): return "Could not open T3 Code's database: \(message)"
            case let .prepare(message): return "Query failed: \(message)"
            }
        }
    }

    private var handle: OpaquePointer?

    init(path: String) throws {
        // `mode=ro` keeps us out of the way of the writer. A WAL database still
        // needs its -shm file, which T3 Code creates while it is running.
        let uri = "file:\(path)?mode=ro"
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let db { sqlite3_close_v2(db) }
            throw Failure.open(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 2_000)
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    /// Runs `sql` and hands each row to `body` as a column accessor.
    func query(_ sql: String, bind: [Binding] = [], _ body: (Row) -> Void) throws {
        guard let handle else { throw Failure.prepare("connection closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(statement)
            throw Failure.prepare(message)
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bind.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let .text(text): sqlite3_bind_text(statement, position, text, -1, SQLITE_TRANSIENT)
            }
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            body(Row(statement: statement))
        }
    }

    enum Binding {
        case text(String)
    }

    struct Row {
        let statement: OpaquePointer

        func string(_ index: Int32) -> String? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL,
                  let raw = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: raw)
        }

        func text(_ index: Int32) -> String { string(index) ?? "" }

        func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }

        func date(_ index: Int32) -> Date? { string(index).flatMap(ISO8601.date(from:)) }

        /// Parses a JSON column into a dictionary, tolerating malformed values.
        func json(_ index: Int32) -> [String: Any] {
            guard let raw = string(index), let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return object
        }
    }
}

/// T3 Code writes timestamps as ISO-8601 with fractional seconds.
enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from string: String) -> Date? {
        withFraction.date(from: string) ?? plain.date(from: string)
    }
}
