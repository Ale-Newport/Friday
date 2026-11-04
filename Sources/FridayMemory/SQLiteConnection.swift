import Foundation
import SQLite3

/// A value bound to, or read from, a SQLite statement.
enum SQLiteValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    init(_ text: String?) { self = text.map(SQLiteValue.text) ?? .null }
    init(_ date: Date?) { self = date.map { .real($0.timeIntervalSince1970) } ?? .null }
    init(_ number: Int) { self = .integer(Int64(number)) }
    init(_ flag: Bool) { self = .integer(flag ? 1 : 0) }
}

/// One result row, addressed by column name.
struct SQLiteRow {
    private let values: [String: SQLiteValue]

    init(_ values: [String: SQLiteValue]) { self.values = values }

    subscript(column: String) -> SQLiteValue? { values[column] }

    func string(_ column: String) -> String? {
        switch values[column] {
        case .text(let text)?: return text
        case .integer(let number)?: return String(number)
        case .real(let number)?: return String(number)
        default: return nil
        }
    }

    func int(_ column: String) -> Int? {
        switch values[column] {
        case .integer(let number)?: return Int(number)
        case .real(let number)?: return Int(number)
        case .text(let text)?: return Int(text)
        default: return nil
        }
    }

    func double(_ column: String) -> Double? {
        switch values[column] {
        case .real(let number)?: return number
        case .integer(let number)?: return Double(number)
        case .text(let text)?: return Double(text)
        default: return nil
        }
    }

    func date(_ column: String) -> Date? { double(column).map { Date(timeIntervalSince1970: $0) } }

    func bool(_ column: String) -> Bool { (int(column) ?? 0) != 0 }
}

/// A thin, synchronous wrapper around one `sqlite3*` handle.
///
/// The connection is deliberately **not** `Sendable`: exactly one ``MemoryStore`` actor owns it and every call
/// happens on that actor, so the handle never crosses an isolation boundary.
final class SQLiteConnection {
    private var handle: OpaquePointer?

    /// SQLite's `SQLITE_TRANSIENT` destructor is a macro the Swift importer does not expose; this is its value.
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    init(path: String) throws {
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &pointer, flags, nil)
        guard status == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite could not open the database (code \(status))."
            sqlite3_close_v2(pointer)
            throw MemoryError.sqlite(message: message)
        }
        handle = pointer
        sqlite3_busy_timeout(pointer, 3_000)
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    private var lastError: MemoryError {
        guard let handle else { return .sqlite(message: "The database connection is closed.") }
        return .sqlite(message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Runs one or more statements that take no bindings.
    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard status == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "SQLite error \(status)."
            sqlite3_free(errorPointer)
            throw MemoryError.sqlite(message: message)
        }
    }

    /// Runs a single statement with bindings and returns the number of rows changed.
    @discardableResult
    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw lastError }
        return Int(sqlite3_changes(handle))
    }

    /// Runs a query and returns every row.
    func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let columnCount = Int(sqlite3_column_count(statement))
        let names = (0..<columnCount).map { String(cString: sqlite3_column_name(statement, Int32($0))) }
        var rows: [SQLiteRow] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw lastError }
            var values: [String: SQLiteValue] = [:]
            for index in 0..<columnCount {
                let column = Int32(index)
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: values[names[index]] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: values[names[index]] = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, column) {
                        values[names[index]] = .text(String(cString: text))
                    } else {
                        values[names[index]] = .null
                    }
                default: values[names[index]] = .null
                }
            }
            rows.append(SQLiteRow(values))
        }
        return rows
    }

    /// Returns the first column of the first row as an integer (`0` when there is no row).
    func scalarInt(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return 0 }
        guard status == SQLITE_ROW else { throw lastError }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Runs `body` inside `BEGIN IMMEDIATE … COMMIT`, rolling back when it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Runs `body` inside a savepoint. Returns `nil` (after rolling the savepoint back) when it throws, so a
    /// failing optional feature probe does not abort an enclosing transaction.
    func attempt<T>(_ body: () throws -> T) -> T? {
        guard (try? execute("SAVEPOINT friday_attempt")) != nil else { return nil }
        do {
            let value = try body()
            try execute("RELEASE friday_attempt")
            return value
        } catch {
            try? execute("ROLLBACK TO friday_attempt")
            try? execute("RELEASE friday_attempt")
            return nil
        }
    }

    // MARK: Statements

    private func prepare(_ sql: String, _ bindings: [SQLiteValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw lastError }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .null: status = sqlite3_bind_null(statement, index)
            case .integer(let number): status = sqlite3_bind_int64(statement, index, number)
            case .real(let number): status = sqlite3_bind_double(statement, index, number)
            case .text(let text): status = sqlite3_bind_text(statement, index, text, -1, Self.transient)
            }
            guard status == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw lastError
            }
        }
        return statement
    }
}
