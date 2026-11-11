import Foundation
import SQLite3

/// A dynamically typed SQLite value.
public enum SQLValue: Sendable, Hashable, CustomStringConvertible {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var isNull: Bool { if case .null = self { return true } else { return false } }

    /// Integer value; reals are truncated, numeric text is parsed.
    public var int: Int64? {
        switch self {
        case .integer(let v): return v
        case .real(let v): return v.isFinite ? Int64(v) : nil
        case .text(let s): return Int64(s)
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .integer(let v): return Double(v)
        case .real(let v): return v
        case .text(let s): return Double(s)
        default: return nil
        }
    }

    /// Text value; numbers are stringified, blobs that are valid UTF-8 are decoded.
    public var string: String? {
        switch self {
        case .text(let s): return s
        case .integer(let v): return String(v)
        case .real(let v): return Format.number(v, maxDigits: 6)
        case .blob(let d): return String(data: d, encoding: .utf8)
        case .null: return nil
        }
    }

    public var data: Data? {
        switch self {
        case .blob(let d): return d
        case .text(let s): return Data(s.utf8)
        default: return nil
        }
    }

    public var bool: Bool? { int.map { $0 != 0 } }

    /// Interprets the number as seconds since 2001 (CoreData / Biome convention).
    public var cocoaDate: Date? { double.flatMap { $0 == 0 ? nil : DossierDate.cocoa($0) } }
    /// Interprets the number as seconds since 1970.
    public var unixDate: Date? { double.flatMap { $0 == 0 ? nil : DossierDate.unix($0) } }

    /// SQLite storage class name.
    public var typeName: String {
        switch self {
        case .null: return "NULL"
        case .integer: return "INTEGER"
        case .real: return "REAL"
        case .text: return "TEXT"
        case .blob: return "BLOB"
        }
    }

    /// Short single-line rendering for table cells.
    public var description: String {
        switch self {
        case .null: return "NULL"
        case .integer(let v): return String(v)
        case .real(let v): return Format.number(v, maxDigits: 6)
        case .text(let s): return s
        case .blob(let d): return "BLOB (\(Format.bytes(d.count)))"
        }
    }
}

/// One result row. Column names are shared between all rows of a result.
public struct SQLRow: Sendable {
    public let columns: SQLColumns
    public let values: [SQLValue]
    /// When a query was run with `cellByteLimit`, the full byte length of each text/blob
    /// cell (values themselves are truncated to the limit). Nil otherwise.
    public let fullSizes: [Int]?

    public subscript(index: Int) -> SQLValue { index < values.count ? values[index] : .null }

    /// Lookup by column name (case-insensitive); `.null` if the column does not exist.
    public subscript(name: String) -> SQLValue {
        guard let i = columns.index(of: name) else { return .null }
        return values[i]
    }

    public func has(_ name: String) -> Bool { columns.index(of: name) != nil }
}

/// Shared, immutable column-name table of a result set.
public final class SQLColumns: Sendable {
    public let names: [String]
    private let lookup: [String: Int]

    public init(_ names: [String]) {
        self.names = names
        var map: [String: Int] = [:]
        for (i, n) in names.enumerated() where map[n.lowercased()] == nil { map[n.lowercased()] = i }
        lookup = map
    }

    public func index(of name: String) -> Int? { lookup[name.lowercased()] }
    public var count: Int { names.count }
}

/// A fully materialized (bounded) result.
public struct SQLResult: Sendable {
    public let columns: [String]
    public let rows: [SQLRow]
    /// True if stepping stopped because `maxRows` was reached while more rows were available.
    public let truncated: Bool
    public static let empty = SQLResult(columns: [], rows: [], truncated: false)
}

/// Schema information for one column (`PRAGMA table_xinfo`).
public struct SQLColumnInfo: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let declaredType: String
    public let notNull: Bool
    public let primaryKeyIndex: Int
    public let hidden: Bool

    public init(name: String, declaredType: String, notNull: Bool, primaryKeyIndex: Int, hidden: Bool) {
        self.name = name; self.declaredType = declaredType; self.notNull = notNull
        self.primaryKeyIndex = primaryKeyIndex; self.hidden = hidden
    }
}

/// Entry of `sqlite_master`.
public struct SQLSchemaObject: Sendable, Hashable, Identifiable {
    public var id: String { type + ":" + name }
    public let type: String        // table | view | index | trigger
    public let name: String
    public let tableName: String
    public let sql: String?
    public var isVirtual: Bool { (sql ?? "").uppercased().hasPrefix("CREATE VIRTUAL") }
}

public enum SQLiteError: Error, LocalizedError, Sendable {
    case openFailed(path: String, code: Int32, message: String)
    case inaccessible(path: String, message: String)
    case missing(path: String)
    case prepareFailed(sql: String, message: String)
    case stepFailed(message: String)
    case interrupted
    case writeAttempt(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let code, let message): return "Cannot open \((path as NSString).lastPathComponent) (\(code)): \(message)"
        case .inaccessible(_, let message): return "No access: \(message)"
        case .missing(let path): return "\((path as NSString).lastPathComponent) does not exist on this Mac"
        case .prepareFailed(_, let message): return message
        case .stepFailed(let message): return message
        case .interrupted: return "Query cancelled"
        case .writeAttempt(let what): return "Blocked: this connection is read-only (\(what))"
        }
    }

    /// True for errors that mean "the store is protected / not readable".
    public var isAccessProblem: Bool {
        if case .inaccessible = self { return true }
        return false
    }
}

private let SQLITE_TRANSIENT_FN = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A thin, fast, strictly read-only SQLite connection.
///
/// * Opened with `SQLITE_OPEN_READONLY` via `file:<path>?mode=ro&readonly_shm=1`.
///   `mode=ro` alone is not enough for WAL databases: SQLite would still open the
///   `-shm` wal-index read-write and rebuild (or create) it when no other process holds
///   the database. `readonly_shm=1` makes it map an existing `-shm` read-only and never
///   create one, so not a single byte next to the database changes. When nobody else
///   has the database open SQLite then builds a private in-heap wal-index per read
///   transaction (slower on large WALs, but write-free).
/// * Falls back to `immutable=1` only if that open fails (a WAL database whose `-shm`
///   file does not exist cannot be read without creating one). The fallback reads the
///   main database file only: changes that are still in the `-wal` are not visible, so
///   the data may be stale — see ``isImmutableFallback`` / ``openModeNote``.
/// * `PRAGMA query_only=ON` plus an authorizer that denies everything except reads, so
///   even ad-hoc user SQL cannot modify, attach or create anything.
/// * All work is confined to a private serial queue: `await` any method from the main
///   actor without blocking it.
/// * Task cancellation interrupts the running statement (`sqlite3_interrupt`).
/// * Prepared statements are cached per connection.
///
/// Use ``SQLiteDB/shared(_:)`` to get a pooled connection for a path.
public final class SQLiteDB: @unchecked Sendable {
    public let path: String
    /// True if the connection had to fall back to `immutable=1`. Such a connection reads
    /// the main database file only and ignores frames that are still in the `-wal`, so
    /// recent changes may be missing.
    public private(set) var isImmutableFallback = false

    /// User-facing caveat about how this database was opened, nil for a normal read-only
    /// connection.
    public var openModeNote: String? {
        isImmutableFallback
            ? "Immutable snapshot, possibly stale: the write-ahead log could not be read without modifying files, so recent changes that are not yet checkpointed are missing."
            : nil
    }

    private var handle: OpaquePointer?
    private let queue: DispatchQueue
    private var statementCache: [String: OpaquePointer] = [:]
    private var statementOrder: [String] = []
    private let statementCacheLimit = 48

    private let stateLock = NSLock()
    private var runningJob: UInt64 = 0
    private var nextJob: UInt64 = 1
    private var cancelledJobs: Set<UInt64> = []

    // MARK: Opening

    /// Opens a read-only connection. Throws ``SQLiteError`` describing missing /
    /// inaccessible / corrupt databases. Opening is cheap but does touch the disk; prefer
    /// calling from a background context (or use ``shared(_:)`` inside an async function).
    public init(path: String, busyTimeoutMs: Int32 = 2_000) throws {
        self.path = path
        self.queue = DispatchQueue(label: "dossier.sqlite." + (path as NSString).lastPathComponent, qos: .userInitiated)

        switch Paths.probe(URL(fileURLWithPath: path)) {
        case .missing: throw SQLiteError.missing(path: path)
        case .inaccessible(let message): throw SQLiteError.inaccessible(path: path, message: message)
        case .available: break
        }

        var lastError: SQLiteError?
        for immutable in [false, true] {
            var db: OpaquePointer?
            let uri = SQLiteDB.uri(for: path, immutable: immutable)
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
            let rc = sqlite3_open_v2(uri, &db, flags, nil)
            if rc == SQLITE_OK, let db {
                sqlite3_busy_timeout(db, busyTimeoutMs)
                // Verify the schema is actually readable (surfaces CANTOPEN on -shm, NOTADB, ...).
                var probeStmt: OpaquePointer?
                let probeRC = sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &probeStmt, nil)
                var stepRC = probeRC
                if probeRC == SQLITE_OK { stepRC = sqlite3_step(probeStmt) }
                sqlite3_finalize(probeStmt)
                if stepRC == SQLITE_ROW || stepRC == SQLITE_DONE {
                    sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil)
                    SQLiteDB.installAuthorizer(db)
                    handle = db
                    isImmutableFallback = immutable
                    return
                }
                let message = String(cString: sqlite3_errmsg(db))
                lastError = (stepRC == SQLITE_AUTH || stepRC == SQLITE_PERM)
                    ? .inaccessible(path: path, message: message)
                    : .openFailed(path: path, code: stepRC, message: message)
                sqlite3_close_v2(db)
            } else {
                let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
                lastError = .openFailed(path: path, code: rc, message: message)
                if let db { sqlite3_close_v2(db) }
            }
        }
        throw lastError ?? SQLiteError.openFailed(path: path, code: -1, message: "unknown")
    }

    deinit {
        for (_, stmt) in statementCache { sqlite3_finalize(stmt) }
        if let handle { sqlite3_close_v2(handle) }
    }

    private static func uri(for path: String, immutable: Bool) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        let escaped = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        // readonly_shm=1: never open, rebuild or create the -shm wal-index read-write.
        return "file:" + escaped + (immutable ? "?mode=ro&immutable=1" : "?mode=ro&readonly_shm=1")
    }

    /// Denies every operation that is not a pure read.
    private static func installAuthorizer(_ db: OpaquePointer) {
        sqlite3_set_authorizer(db, { _, action, arg1, arg2, _, _ in
            switch action {
            case SQLITE_SELECT, SQLITE_READ, SQLITE_FUNCTION, SQLITE_RECURSIVE:
                return SQLITE_OK
            case SQLITE_PRAGMA:
                // Read-only pragmas only; pragmas with an argument are limited to a whitelist.
                guard let arg1 else { return SQLITE_DENY }
                let name = String(cString: arg1).lowercased()
                let readOnly: Set<String> = [
                    "table_info", "table_xinfo", "table_list", "index_list", "index_info", "index_xinfo",
                    "foreign_key_list", "database_list", "collation_list", "function_list", "module_list",
                    "pragma_list", "compile_options",
                ]
                if readOnly.contains(name) { return SQLITE_OK }
                let valueOnly: Set<String> = [
                    "page_count", "page_size", "freelist_count", "user_version", "schema_version",
                    "application_id", "encoding", "journal_mode", "auto_vacuum", "data_version",
                    "query_only", "busy_timeout",
                ]
                if valueOnly.contains(name) { return arg2 == nil ? SQLITE_OK : SQLITE_DENY }
                return SQLITE_DENY
            default:
                return SQLITE_DENY
            }
        }, nil)
    }

    // MARK: Pool

    private static let poolLock = NSLock()
    private static var pool: [String: SQLiteDB] = [:]

    /// Returns the pooled connection for `path`, opening it on first use (off the caller's
    /// thread). Failed opens are not cached.
    public static func shared(_ path: String) async throws -> SQLiteDB {
        if let existing = poolLock.withLock({ pool[path] }) { return existing }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let db = try SQLiteDB(path: path)
                    let winner = poolLock.withLock { () -> SQLiteDB in
                        if let existing = pool[path] { return existing }
                        pool[path] = db
                        return db
                    }
                    continuation.resume(returning: winner)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public static func shared(_ url: URL) async throws -> SQLiteDB { try await shared(url.path) }

    /// Like ``shared(_:)`` but returns nil instead of throwing (missing / protected store).
    public static func sharedIfAvailable(_ url: URL?) async -> SQLiteDB? {
        guard let url else { return nil }
        return try? await shared(url.path)
    }

    /// Drops pooled connections (all, or one path). Used by "Refresh".
    public static func resetPool(path: String? = nil) {
        poolLock.withLock {
            if let path { pool[path] = nil } else { pool.removeAll() }
        }
    }

    // MARK: Job scheduling (serial queue + cancellation)

    private func run<T: Sendable>(_ body: @escaping (SQLiteDB) throws -> T) async throws -> T {
        let job = stateLock.withLock { () -> UInt64 in
            let j = nextJob; nextJob += 1; return j
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                queue.async { [self] in
                    let cancelled = stateLock.withLock { () -> Bool in
                        if cancelledJobs.remove(job) != nil { return true }
                        runningJob = job
                        return false
                    }
                    if cancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    defer { stateLock.withLock { runningJob = 0; cancelledJobs.remove(job) } }
                    do {
                        continuation.resume(returning: try body(self))
                    } catch SQLiteError.interrupted {
                        continuation.resume(throwing: CancellationError())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { [self] in
            stateLock.withLock {
                if runningJob == job {
                    if let handle { sqlite3_interrupt(handle) }
                } else {
                    cancelledJobs.insert(job)
                    if cancelledJobs.count > 4_096 { cancelledJobs.removeAll() }
                }
            }
        }
    }

    /// Interrupts whatever statement is currently running on this connection.
    public func interrupt() {
        stateLock.withLock { if let handle { sqlite3_interrupt(handle) } }
    }

    // MARK: Statements (queue-confined)

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let cached = statementCache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            let message = String(cString: sqlite3_errmsg(handle))
            if rc == SQLITE_AUTH { throw SQLiteError.writeAttempt(message) }
            if rc == SQLITE_INTERRUPT { throw SQLiteError.interrupted }
            throw SQLiteError.prepareFailed(sql: sql, message: message)
        }
        if sqlite3_stmt_readonly(stmt) == 0 {
            sqlite3_finalize(stmt)
            throw SQLiteError.writeAttempt("statement would modify the database")
        }
        statementCache[sql] = stmt
        statementOrder.append(sql)
        if statementOrder.count > statementCacheLimit {
            let evicted = statementOrder.removeFirst()
            if let old = statementCache.removeValue(forKey: evicted) { sqlite3_finalize(old) }
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ params: [SQLValue]) {
        for (i, value) in params.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .null: sqlite3_bind_null(stmt, index)
            case .integer(let v): sqlite3_bind_int64(stmt, index, v)
            case .real(let v): sqlite3_bind_double(stmt, index, v)
            case .text(let s): sqlite3_bind_text(stmt, index, s, -1, SQLITE_TRANSIENT_FN)
            case .blob(let d):
                d.withUnsafeBytes { raw in
                    _ = sqlite3_bind_blob64(stmt, index, raw.baseAddress, sqlite3_uint64(raw.count), SQLITE_TRANSIENT_FN)
                }
            }
        }
    }

    @inline(__always)
    private static func columnValue(_ stmt: OpaquePointer, _ i: Int32, limit: Int?, fullSize: inout Int) -> SQLValue {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER:
            fullSize = 8
            return .integer(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT:
            fullSize = 8
            return .real(sqlite3_column_double(stmt, i))
        case SQLITE_TEXT:
            guard let ptr = sqlite3_column_text(stmt, i) else { fullSize = 0; return .text("") }
            let n = Int(sqlite3_column_bytes(stmt, i))
            fullSize = n
            if let limit, n > limit {
                // Truncate on a UTF-8 boundary.
                var end = limit
                while end > 0, (ptr[end] & 0xC0) == 0x80 { end -= 1 }
                return .text(String(decoding: UnsafeBufferPointer(start: ptr, count: end), as: UTF8.self))
            }
            return .text(String(decoding: UnsafeBufferPointer(start: ptr, count: n), as: UTF8.self))
        case SQLITE_BLOB:
            let n = Int(sqlite3_column_bytes(stmt, i))
            fullSize = n
            guard n > 0, let ptr = sqlite3_column_blob(stmt, i) else { return .blob(Data()) }
            return .blob(Data(bytes: ptr, count: limit.map { min($0, n) } ?? n))
        default:
            fullSize = 0
            return .null
        }
    }

    private func stepAll(
        _ sql: String, _ params: [SQLValue], maxRows: Int?, cellByteLimit: Int?,
        body: (SQLRow) -> Bool
    ) throws -> (columns: [String], truncated: Bool) {
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt) }
        bind(stmt, params)
        let n = sqlite3_column_count(stmt)
        let names = (0..<n).map { i in sqlite3_column_name(stmt, i).map { String(cString: $0) } ?? "column\(i)" }
        let columns = SQLColumns(names)
        var produced = 0
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                if let maxRows, produced >= maxRows { return (names, true) }
                var values: [SQLValue] = []
                values.reserveCapacity(Int(n))
                var sizes: [Int]? = cellByteLimit == nil ? nil : []
                for i in 0..<n {
                    var full = 0
                    values.append(SQLiteDB.columnValue(stmt, i, limit: cellByteLimit, fullSize: &full))
                    sizes?.append(full)
                }
                produced += 1
                if !body(SQLRow(columns: columns, values: values, fullSizes: sizes)) { return (names, false) }
            } else if rc == SQLITE_DONE {
                return (names, false)
            } else if rc == SQLITE_INTERRUPT {
                throw SQLiteError.interrupted
            } else {
                throw SQLiteError.stepFailed(message: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    // MARK: Public query API

    /// Runs a query and materializes up to `maxRows` rows.
    ///
    /// - Parameters:
    ///   - maxRows: hard cap on returned rows (protects memory). `result.truncated` tells
    ///     whether more rows existed. Always page large tables with `LIMIT`.
    ///   - cellByteLimit: if set, text/blob cells are truncated to this many bytes and
    ///     `SQLRow.fullSizes` carries the real lengths (for table display of huge cells).
    public func query(
        _ sql: String, _ params: [SQLValue] = [], maxRows: Int? = 100_000, cellByteLimit: Int? = nil
    ) async throws -> SQLResult {
        try await run { db in
            var rows: [SQLRow] = []
            let (columns, truncated) = try db.stepAll(sql, params, maxRows: maxRows, cellByteLimit: cellByteLimit) { row in
                rows.append(row); return true
            }
            return SQLResult(columns: columns, rows: rows, truncated: truncated)
        }
    }

    /// Convenience: rows only.
    public func rows(_ sql: String, _ params: [SQLValue] = [], maxRows: Int? = 100_000) async throws -> [SQLRow] {
        try await query(sql, params, maxRows: maxRows).rows
    }

    /// Streams rows to `body` on the connection queue without materializing them. Return
    /// `false` from `body` to stop early. `body` must not call back into this connection.
    public func forEach(
        _ sql: String, _ params: [SQLValue] = [], cellByteLimit: Int? = nil,
        _ body: @escaping @Sendable (SQLRow) -> Bool
    ) async throws {
        try await run { db in
            _ = try db.stepAll(sql, params, maxRows: nil, cellByteLimit: cellByteLimit, body: body)
        }
    }

    /// Streams rows and reduces them into a value (aggregation without row arrays).
    public func reduce<T: Sendable>(
        _ sql: String, _ params: [SQLValue] = [], into initial: T,
        _ update: @escaping @Sendable (inout T, SQLRow) -> Void
    ) async throws -> T {
        try await run { db in
            var acc = initial
            _ = try db.stepAll(sql, params, maxRows: nil, cellByteLimit: nil) { row in
                update(&acc, row); return true
            }
            return acc
        }
    }

    /// First column of the first row (`.null` if there is no row).
    public func scalar(_ sql: String, _ params: [SQLValue] = []) async throws -> SQLValue {
        try await run { db in
            var value = SQLValue.null
            _ = try db.stepAll(sql, params, maxRows: 1, cellByteLimit: nil) { row in
                value = row[0]; return false
            }
            return value
        }
    }

    /// `SELECT count(*)`-style helper returning an Int (nil on error, e.g. missing table).
    public func count(_ sql: String, _ params: [SQLValue] = []) async -> Int? {
        (try? await scalar(sql, params))?.int.map(Int.init)
    }

    /// First row, if any.
    public func first(_ sql: String, _ params: [SQLValue] = []) async throws -> SQLRow? {
        try await query(sql, params, maxRows: 1).rows.first
    }

    // MARK: Schema probing

    /// Quotes an identifier for safe interpolation into SQL: `"na""me"`.
    public static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// All schema objects (tables, views, indexes, triggers).
    public func schema() async throws -> [SQLSchemaObject] {
        let result = try await query("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name")
        return result.rows.map {
            SQLSchemaObject(type: $0[0].string ?? "", name: $0[1].string ?? "", tableName: $0[2].string ?? "", sql: $0[3].string)
        }
    }

    /// Names of tables (and optionally views), excluding SQLite internals.
    public func tables(includeViews: Bool = false) async throws -> [String] {
        try await schema()
            .filter { ($0.type == "table" || (includeViews && $0.type == "view")) && !$0.name.hasPrefix("sqlite_") }
            .map(\.name)
    }

    public func tableExists(_ name: String) async -> Bool {
        let n = await count("SELECT count(*) FROM sqlite_master WHERE type IN ('table','view') AND name = ? COLLATE NOCASE", [.text(name)])
        return (n ?? 0) > 0
    }

    /// Column metadata for a table or view (empty if it does not exist).
    public func columns(of table: String) async -> [SQLColumnInfo] {
        let rows = (try? await query("PRAGMA table_xinfo(\(SQLiteDB.quote(table)))").rows) ?? []
        return rows.map {
            SQLColumnInfo(
                name: $0["name"].string ?? "",
                declaredType: $0["type"].string ?? "",
                notNull: $0["notnull"].bool ?? false,
                primaryKeyIndex: Int($0["pk"].int ?? 0),
                hidden: ($0["hidden"].int ?? 0) != 0
            )
        }
    }

    /// **Lower-cased** set of column names. `names.contains("ZVALUESTRING")` is therefore
    /// always false — compare against lower-case literals, or use ``columnSet(of:)`` whose
    /// `contains` is case-insensitive.
    public func columnNames(of table: String) async -> Set<String> {
        Set(await columns(of: table).map { $0.name.lowercased() })
    }

    /// Case-insensitive column lookup for a table (empty if the table does not exist).
    public func columnSet(of table: String) async -> ColumnSet {
        ColumnSet(names: await columnNames(of: table))
    }

    /// True if all of `columns` exist in `table`.
    public func hasColumns(_ table: String, _ columns: [String]) async -> Bool {
        let names = await columnNames(of: table)
        return !names.isEmpty && columns.allSatisfy { names.contains($0.lowercased()) }
    }

    /// Exact row count (`SELECT count(*)`); nil if the table cannot be read. Can take a
    /// while on very large tables — it is cancellable.
    public func rowCount(of table: String) async -> Int? {
        await count("SELECT count(*) FROM \(SQLiteDB.quote(table))")
    }
}

/// Case-insensitive set of column names (see ``SQLiteDB/columnSet(of:)``).
public struct ColumnSet: Sendable, Hashable {
    /// Lower-cased names.
    public let names: Set<String>
    public init(names: Set<String>) { self.names = Set(names.map { $0.lowercased() }) }
    public var isEmpty: Bool { names.isEmpty }
    public func contains(_ name: String) -> Bool { names.contains(name.lowercased()) }
    public func containsAll(_ wanted: [String]) -> Bool { wanted.allSatisfy(contains) }
}
