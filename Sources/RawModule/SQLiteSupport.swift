import Foundation
import DossierCore

/// A table or view of the selected database.
struct TableEntry: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let type: String
    let isVirtual: Bool
    var rowCount: Int?
    var counted = false
}

/// Everything needed to build paged queries for one table.
struct TableShape: Sendable, Hashable {
    let dbPath: String
    let table: String
    let columns: [SQLColumnInfo]
    let hasRowid: Bool
}

/// A dynamically typed row for the generic table browser.
struct RawRow: Identifiable, Sendable {
    let id: Int64
    /// The fetched cells. Aligned with ``TableShape/columns`` when `slots` is nil.
    let values: [SQLValue]
    /// Full byte sizes of the cells when values were truncated for display.
    let sizes: [Int]?
    /// When only some columns were fetched: position in `values` per shape column index
    /// (-1 = not fetched). The array is shared by all rows of a page.
    var slots: [Int]? = nil

    private func slot(_ column: Int) -> Int? {
        guard let slots else { return column < values.count ? column : nil }
        guard column < slots.count, slots[column] >= 0, slots[column] < values.count else { return nil }
        return slots[column]
    }

    /// The cell of a shape column, nil when that column was not fetched for this row.
    func value(_ column: Int) -> SQLValue? { slot(column).map { values[$0] } }
    func size(_ column: Int) -> Int? { slot(column).flatMap { sizes?[$0] } }
}

enum RawSQL {
    /// Max bytes fetched per cell for table display (full values are fetched on selection).
    static let cellByteLimit = 512
    static let rowidAlias = "__dossier_rowid"

    /// Probes columns and rowid availability of a table / view.
    static func shape(dbPath: String, table: String) async throws -> TableShape {
        let db = try await SQLiteDB.shared(dbPath)
        let columns = await db.columns(of: table).filter { !$0.hidden }
        let hasRowid = (try? await db.query("SELECT rowid FROM \(SQLiteDB.quote(table)) LIMIT 0")) != nil
        return TableShape(dbPath: dbPath, table: table, columns: columns, hasRowid: hasRowid)
    }

    private static func filterClause(_ shape: TableShape, search: String, params: inout [SQLValue]) -> String? {
        guard !search.isEmpty else { return nil }
        let candidates = shape.columns
            .filter { !$0.declaredType.uppercased().contains("BLOB") }
            .prefix(40)
        guard !candidates.isEmpty else { return nil }
        let escaped = search
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        params.append(.text("%" + escaped + "%"))
        let index = params.count
        let parts = candidates.map { "CAST(\(SQLiteDB.quote($0.name)) AS TEXT) LIKE ?\(index) ESCAPE '\\'" }
        return "(" + parts.joined(separator: " OR ") + ")"
    }

    /// Columns the browser shows (and fetches) by default.
    static let defaultColumnCap = 24

    /// Indices (ascending) of the columns shown by default. SwiftUI `Table` builds every
    /// column of every visible row, so wide tables are capped: primary key first, then
    /// text and date columns, then other scalars, blobs last.
    static func defaultVisible(_ shape: TableShape) -> [Int] {
        let all = Array(shape.columns.indices)
        guard all.count > defaultColumnCap else { return all }
        func rank(_ c: SQLColumnInfo) -> Int {
            if c.primaryKeyIndex > 0 { return 0 }
            let t = c.declaredType.uppercased()
            let n = c.name.lowercased()
            if t.contains("BLOB") { return 4 }
            if t.contains("CHAR") || t.contains("TEXT") || t.contains("CLOB") || t.contains("STRING") { return 1 }
            if t.contains("TIMESTAMP") || t.contains("DATE") || n.contains("date") || n.contains("time") { return 1 }
            return t.isEmpty ? 3 : 2
        }
        let chosen = all.sorted { (rank(shape.columns[$0]), $0) < (rank(shape.columns[$1]), $1) }.prefix(defaultColumnCap)
        return chosen.sorted()
    }

    /// One page of a table: keyset paging on rowid in natural order, OFFSET otherwise.
    /// - Parameter visible: shape column indices to fetch (nil = all). Only honoured for
    ///   rowid tables, where the inspector can fetch the complete row on selection.
    static func page(_ shape: TableShape, _ request: PageRequest, visible: [Int]? = nil) async throws -> [RawRow] {
        let db = try await SQLiteDB.shared(shape.dbPath)
        var params: [SQLValue] = []
        var conditions: [String] = []
        if let filter = filterClause(shape, search: request.search, params: &params) { conditions.append(filter) }

        var order = ""
        var useOffset = true
        if let sort = request.sort, shape.columns.contains(where: { $0.name == sort.columnID }) {
            order = " ORDER BY \(SQLiteDB.quote(sort.columnID)) \(sort.sqlDirection)"
            if shape.hasRowid { order += ", rowid" }
        } else if shape.hasRowid {
            order = " ORDER BY rowid"
            if let cursor = request.cursor?.base as? Int64 {
                params.append(.integer(cursor))
                conditions.append("rowid > ?\(params.count)")
                useOffset = false
            }
        }
        var slots: [Int]?
        var list = "*"
        if shape.hasRowid, let visible {
            let wanted = visible.filter { shape.columns.indices.contains($0) }
            if !wanted.isEmpty, wanted.count < shape.columns.count {
                var map = [Int](repeating: -1, count: shape.columns.count)
                for (position, column) in wanted.enumerated() { map[column] = position }
                slots = map
                list = wanted.map { SQLiteDB.quote(shape.columns[$0].name) }.joined(separator: ", ")
            }
        }
        let select = shape.hasRowid ? "rowid AS \(rowidAlias), \(list)" : list
        var sql = "SELECT \(select) FROM \(SQLiteDB.quote(shape.table))"
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        sql += order
        params.append(.integer(Int64(request.limit)))
        sql += " LIMIT ?\(params.count)"
        if useOffset && request.offset > 0 {
            params.append(.integer(Int64(request.offset)))
            sql += " OFFSET ?\(params.count)"
        }
        let result = try await db.query(sql, params, maxRows: request.limit, cellByteLimit: cellByteLimit)
        let skip = shape.hasRowid ? 1 : 0
        return result.rows.enumerated().map { index, row in
            let id = shape.hasRowid ? (row[0].int ?? Int64(request.offset + index)) : Int64(request.offset + index)
            return RawRow(id: id, values: Array(row.values.dropFirst(skip)), sizes: row.fullSizes.map { Array($0.dropFirst(skip)) }, slots: slots)
        }
    }

    static func count(_ shape: TableShape, _ request: PageRequest) async throws -> Int? {
        let db = try await SQLiteDB.shared(shape.dbPath)
        var params: [SQLValue] = []
        var sql = "SELECT count(*) FROM \(SQLiteDB.quote(shape.table))"
        if let filter = filterClause(shape, search: request.search, params: &params) { sql += " WHERE " + filter }
        return try await db.scalar(sql, params).int.map(Int.init)
    }

    /// The complete (untruncated) row for the inspector.
    static func fullRow(_ shape: TableShape, rowid: Int64) async throws -> [SQLValue]? {
        guard shape.hasRowid else { return nil }
        let db = try await SQLiteDB.shared(shape.dbPath)
        let cols = shape.columns.map { SQLiteDB.quote($0.name) }.joined(separator: ", ")
        let row = try await db.first("SELECT \(cols) FROM \(SQLiteDB.quote(shape.table)) WHERE rowid = ?", [.integer(rowid)])
        return row?.values
    }

    // MARK: Cell rendering

    /// Single-line cell text.
    static func cellText(_ value: SQLValue, fullSize: Int?) -> String {
        switch value {
        case .null: return "NULL"
        case .integer(let v): return String(v)
        case .real(let v): return Format.number(v, maxDigits: 6)
        case .text(let s): return Format.oneLine(s, max: 240)
        case .blob(let d):
            let size = fullSize ?? d.count
            let kind = magicLabel(d)
            return "BLOB · \(Format.bytes(size))" + (kind.map { " · " + $0 } ?? "")
        }
    }

    /// Cheap magic-number classification that works on a truncated prefix.
    static func magicLabel(_ prefix: Data) -> String? {
        if prefix.isEmpty { return nil }
        switch BlobSniffer.sniff(prefix) {
        case .binaryPlist, .keyedArchive: return "bplist"
        case .xmlPlist: return "XML plist"
        case .image(let t): return t
        case .gzip: return "gzip"
        case .sqlite: return "SQLite"
        case .json: return "JSON"
        case .text: return "text"
        case .protobuf: return "protobuf"
        default: return nil
        }
    }

    /// Is this declared column type numeric (right-aligned)?
    static func isNumeric(_ declaredType: String) -> Bool {
        let t = declaredType.uppercased()
        return t.contains("INT") || t.contains("REAL") || t.contains("FLOA") || t.contains("DOUB") || t.contains("NUM") || t == "TIMESTAMP"
    }

    /// Date interpretation for the inspector when the column name suggests a timestamp.
    static func dateHint(column: String, value: SQLValue) -> String? {
        guard let v = value.double, v > 0 else { return nil }
        let name = column.lowercased()
        guard name.contains("date") || name.contains("time") || name.contains("stamp") || name.hasSuffix("_at") || name.contains("created") || name.contains("modified") else { return nil }
        guard let guess = DossierDate.guess(v) else { return nil }
        return DossierDate.sortable(guess.date) + " (" + guess.encoding + ")"
    }
}
