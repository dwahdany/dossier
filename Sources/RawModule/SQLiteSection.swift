import SwiftUI
import DossierCore

@MainActor
final class SQLiteExplorerModel: ObservableObject {
    @Published var databases: [DatabaseEntry] = []
    @Published var loadingDatabases = true
    @Published var selectedDB: String?
    @Published var tables: [TableEntry] = []
    @Published var tablesState: LoadState<Bool> = .idle
    @Published var selectedTable: String?
    @Published var shape: TableShape?
    @Published var schema: [SQLSchemaObject] = []
    @Published var immutableFallback = false
    /// Mode requested by the last deep link (consumed by the view).
    @Published var requestedMode: String?

    private var dbGeneration = 0
    private var countTask: Task<Void, Never>?
    private var pendingTable: String?
    private var autoSelectedTable = false

    func loadDatabases(token: Int, deepLink: DeepLink?) async {
        loadingDatabases = databases.isEmpty
        let found = await SnapshotReadiness.track {
            await RawCatalog.shared.sync(token: token)
            return await RawCatalog.shared.databases()
        }
        databases = found
        loadingDatabases = false
        if let deepLink { open(payload: deepLink.payload) }
        if selectedDB == nil || !found.contains(where: { $0.id == selectedDB }) {
            select(database: found.first?.id)
        } else if token != 0 {
            select(database: selectedDB, force: true)
        }
    }

    /// Payload format: `<database path>[\t<table>[\t<mode>]]` with mode `browse`, `schema`,
    /// `sql` or `sql!` (open the console and run the default query).
    func open(payload: String) {
        let parts = payload.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard let path = parts.first, !path.isEmpty else { return }
        pendingTable = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        requestedMode = parts.count > 2 ? parts[2] : nil
        select(database: path, force: true)
    }

    func select(database path: String?, force: Bool = false) {
        guard force || path != selectedDB else { return }
        selectedDB = path
        dbGeneration += 1
        let gen = dbGeneration
        countTask?.cancel()
        tables = []
        schema = []
        shape = nil
        selectedTable = nil
        guard let path else { tablesState = .empty(nil); return }
        tablesState = .loading
        let wanted = pendingTable
        pendingTable = nil
        Task {
            SnapshotReadiness.begin()
            defer { SnapshotReadiness.end() }
            do {
                let db = try await SQLiteDB.shared(path)
                let objects = try await db.schema()
                guard gen == dbGeneration else { return }
                schema = objects
                immutableFallback = db.isImmutableFallback
                tables = objects
                    .filter { ($0.type == "table" || $0.type == "view") && !$0.name.hasPrefix("sqlite_") }
                    .map { TableEntry(name: $0.name, type: $0.type, isVirtual: $0.isVirtual) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                tablesState = tables.isEmpty ? .empty("This database has no tables.") : .loaded(true)
                let initial = wanted.flatMap { w in tables.first { $0.name.caseInsensitiveCompare(w) == .orderedSame }?.name } ?? tables.first?.name
                select(table: initial, automatic: wanted == nil)
                startCounting(db: db, generation: gen)
            } catch {
                guard gen == dbGeneration else { return }
                tablesState = .from(error: error)
            }
        }
    }

    private func startCounting(db: SQLiteDB, generation gen: Int) {
        let names = tables.map(\.name)
        countTask = Task { [weak self] in
            for name in names {
                if Task.isCancelled { return }
                let n = await db.rowCount(of: name)
                guard let self, gen == self.dbGeneration, !Task.isCancelled else { return }
                if let i = self.tables.firstIndex(where: { $0.name == name }) {
                    self.tables[i].rowCount = n
                    self.tables[i].counted = true
                }
                // If the automatically chosen table turns out to be empty, move on to the
                // first table that has rows (only while the user has not picked one).
                if self.autoSelectedTable, let n, n > 0,
                   let current = self.tables.first(where: { $0.name == self.selectedTable }), current.counted, (current.rowCount ?? 0) == 0 {
                    self.select(table: name, automatic: true)
                }
            }
            if let self, gen == self.dbGeneration { self.autoSelectedTable = false }
        }
    }

    func select(table name: String?, automatic: Bool = false) {
        autoSelectedTable = automatic
        selectedTable = name
        shape = nil
        guard let name, let path = selectedDB else { return }
        let gen = dbGeneration
        Task {
            SnapshotReadiness.begin()
            defer { SnapshotReadiness.end() }
            guard let shape = try? await RawSQL.shape(dbPath: path, table: name) else { return }
            if gen == dbGeneration, selectedTable == name { self.shape = shape }
        }
    }
}

/// (b) Generic SQLite explorer: databases → tables → browse / schema / ad-hoc SQL.
struct SQLiteSection: View {
    enum Mode: String, CaseIterable, Identifiable {
        case browse = "Browse", schema = "Schema", sql = "SQL"
        var id: String { rawValue }
    }

    @StateObject private var model = SQLiteExplorerModel()
    @State private var mode: Mode = .browse
    @State private var dbFilter = ""
    @State private var tableFilter = ""
    @State private var autoRunSQL = false
    @Environment(\.deepLink) private var deepLink
    @Environment(\.refreshToken) private var refreshToken

    private struct LoadKey: Hashable { let token: Int; let nonce: UUID? }

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (mode, dbFilter, tableFilter, autoRunSQL)
        // Three panes side by side while the content keeps a usable width; in a narrow
        // window the two lists share one column (databases above tables).
        ExplorerPanesLayout(ideal: [250, 230], minimum: [200, 180], comfortableContent: 520, stackedColumn: 220...250) {
            databaseList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PaneSeparator()
            tableList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PaneSeparator()
            Group { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.requestedMode, initial: true) { _, requested in
            guard let requested else { return }
            switch requested {
            case "schema": mode = .schema
            case "sql": mode = .sql
            case "sql!": mode = .sql; autoRunSQL = true
            default: mode = .browse
            }
            model.requestedMode = nil
        }
        .task(id: LoadKey(token: refreshToken, nonce: deepLink?.sectionID == "raw.sqlite" ? deepLink?.nonce : nil)) {
            await model.loadDatabases(token: refreshToken, deepLink: deepLink?.sectionID == "raw.sqlite" ? deepLink : nil)
        }
    }

    // MARK: Database list

    private var filteredDatabases: [(store: String, entries: [DatabaseEntry])] {
        let needle = dbFilter.trimmingCharacters(in: .whitespaces)
        let matching = needle.isEmpty ? model.databases : model.databases.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || $0.folder.localizedCaseInsensitiveContains(needle) || $0.storeTitle.localizedCaseInsensitiveContains(needle)
        }
        var order: [String] = []
        var groups: [String: [DatabaseEntry]] = [:]
        for entry in matching {
            if groups[entry.storeTitle] == nil { order.append(entry.storeTitle) }
            groups[entry.storeTitle, default: []].append(entry)
        }
        return order.map { ($0, groups[$0]!) }
    }

    private var databaseList: some View {
        VStack(spacing: 0) {
            PaneFilterField(prompt: "Filter databases", text: $dbFilter)
            Divider()
            if model.loadingDatabases {
                LoadingPlaceholder("Discovering databases…")
            } else if model.databases.isEmpty {
                StatePlaceholder(title: "No Databases", symbol: "cylinder", message: "No readable SQLite databases were found. Check Full Disk Access.")
            } else {
                List(selection: Binding(get: { model.selectedDB }, set: { model.select(database: $0) })) {
                    ForEach(filteredDatabases, id: \.store) { group in
                        Section(group.store) {
                            ForEach(group.entries) { entry in
                                DatabaseRowView(entry: entry).tag(entry.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            Divider()
            PaneFooter("\(Format.count(model.databases.count)) databases · \(Format.bytes(model.databases.reduce(Int64(0)) { $0 + $1.size }))")
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    // MARK: Table list

    private var tableList: some View {
        VStack(spacing: 0) {
            PaneFilterField(prompt: "Filter tables", text: $tableFilter)
            Divider()
            switch model.tablesState {
            case .idle, .loading:
                LoadingPlaceholder()
            case .inaccessible(let m):
                StatePlaceholder.inaccessible(m)
            case .missing(let m):
                StatePlaceholder.missing(m)
            case .failed(let m):
                StatePlaceholder(title: "Can’t Open", symbol: "exclamationmark.triangle", message: m)
            case .empty(let m):
                StatePlaceholder(title: "No Tables", symbol: "tablecells", message: m)
            case .loaded:
                let needle = tableFilter.trimmingCharacters(in: .whitespaces)
                let tables = needle.isEmpty ? model.tables : model.tables.filter { $0.name.localizedCaseInsensitiveContains(needle) }
                List(selection: Binding(get: { model.selectedTable }, set: { model.select(table: $0) })) {
                    ForEach(tables) { table in
                        HStack(spacing: 6) {
                            Image(systemName: table.type == "view" ? "eye" : (table.isVirtual ? "sparkle.magnifyingglass" : "tablecells"))
                                .foregroundStyle(.secondary)
                                .imageScale(.small)
                                .frame(width: 14)
                            Text(table.name).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if table.counted {
                                Text(table.rowCount.map { Format.compact($0) } ?? "?")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .tag(table.name)
                        .help(table.rowCount.map { "\(Format.count($0)) rows" } ?? table.name)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            Divider()
            PaneFooter(tableFooter)
        }
    }

    private var tableFooter: String {
        guard !model.tables.isEmpty else { return " " }
        let counted = model.tables.compactMap(\.rowCount).reduce(0, +)
        return "\(model.tables.count) table\(model.tables.count == 1 ? "" : "s") · \(Format.count(counted)) row\(counted == 1 ? "" : "s")"
    }

    // MARK: Content

    private var selectedEntry: DatabaseEntry? { model.databases.first { $0.id == model.selectedDB } }

    @ViewBuilder private var content: some View {
        if let entry = selectedEntry {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(model.selectedTable ?? entry.name).font(.headline).lineLimit(1).truncationMode(.middle)
                            if model.immutableFallback {
                                TagLabel("snapshot, possibly stale", tint: .orange)
                                    .help("Opened as an immutable snapshot: the write-ahead log could not be read without modifying files, so recent changes that are not yet checkpointed are missing.")
                            }
                        }
                        Text(entry.name + (entry.folder.isEmpty ? "" : " — " + entry.folder))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .frame(height: 46)
                Divider()
                Group {
                    switch mode {
                    case .browse:
                        if let shape = model.shape {
                            TableBrowser(shape: shape).id(shape)
                        } else if model.selectedTable == nil {
                            StatePlaceholder(title: "Select a Table", symbol: "tablecells")
                        } else {
                            LoadingPlaceholder()
                        }
                    case .schema:
                        SchemaView(objects: model.schema, table: model.selectedTable, columns: model.shape?.columns ?? [])
                    case .sql:
                        SQLConsole(dbPath: entry.url.path, table: model.selectedTable, autoRun: autoRunSQL).id(entry.url.path)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                StoreFooter(entry.url, note: "read-only")
            }
        } else if model.loadingDatabases {
            LoadingPlaceholder()
        } else {
            StatePlaceholder(title: "Select a Database", symbol: "cylinder.split.1x2", message: "Every SQLite database found under the known store locations is listed on the left.")
        }
    }
}

// MARK: - Small pane pieces

struct PaneFilterField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary).imageScale(.small)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.callout)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.barHeight + 4)
    }
}


private struct DatabaseRowView: View {
    let entry: DatabaseEntry

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cylinder").foregroundStyle(.secondary).imageScale(.small)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.name).font(.callout).lineLimit(1).truncationMode(.middle)
                if !entry.folder.isEmpty {
                    Text(entry.folder).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        .sensitive(.personal)
                }
            }
            Spacer(minLength: 4)
            Text(Format.bytes(entry.size)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
        .help(Format.tildePath(entry.url))
    }
}

// MARK: - Browse

/// Remembers the column choice per table while the app runs.
@MainActor
private enum ColumnChoices {
    static var byTable: [TableShape: [Int]] = [:]
}

private struct TableBrowser: View {
    let shape: TableShape
    @State private var selected: RawRow?
    /// Shape column indices shown as table columns (ascending).
    @State private var visible: [Int]
    /// Columns the current rows were fetched with; a superset of `visible`. Only showing
    /// a column that was not fetched re-queries.
    @State private var fetched: [Int]
    @State private var choosing = false

    init(shape: TableShape) {
        self.shape = shape
        let initial = ColumnChoices.byTable[shape] ?? RawSQL.defaultVisible(shape)
        _visible = State(initialValue: initial)
        _fetched = State(initialValue: initial)
    }

    private struct ReloadKey: Hashable {
        let shape: TableShape
        let fetched: [Int]
    }

    private var columns: [PagedColumn<RawRow>] {
        visible.filter { shape.columns.indices.contains($0) }.map { index in
            let column = shape.columns[index]
            let numeric = RawSQL.isNumeric(column.declaredType)
            let wide = !numeric && !column.declaredType.uppercased().contains("BLOB")
            return PagedColumn<RawRow>(
                column.name, id: column.name,
                width: numeric ? 96 : (wide ? 190 : 150),
                min: numeric ? 64 : 90,
                alignment: numeric ? .trailing : .leading,
                sensitivity: .sensitive,
                monospaced: false
            ) { row in
                row.value(index).map { RawSQL.cellText($0, fullSize: row.size(index)) } ?? ""
            }
            .cell { row in
                if let value = row.value(index) {
                    RawCell(value: value, fullSize: row.size(index), numeric: numeric)
                }
            }
        }
    }

    private func setVisible(_ indices: [Int]) {
        let sorted = Array(Set(indices)).sorted()
        guard !sorted.isEmpty else { return }
        visible = sorted
        ColumnChoices.byTable[shape] = sorted
        // Views and WITHOUT ROWID tables always fetch every column.
        if shape.hasRowid, !Set(sorted).isSubset(of: fetched) { fetched = sorted }
    }

    var body: some View {
        let shape = self.shape
        let fetched = self.fetched
        PagedTable(
            columns: columns,
            pageSize: 200,
            searchPrompt: "Filter rows (substring in any text column)",
            reloadKey: ReloadKey(shape: shape, fetched: fetched),
            exportName: shape.table,
            emptyTitle: "Empty Table",
            fetch: { request in try await RawSQL.page(shape, request, visible: fetched) },
            count: { request in try await RawSQL.count(shape, request) },
            onSelect: { selected = $0.count == 1 ? $0.first : nil }
        ) {
            if shape.columns.count > RawSQL.defaultColumnCap {
                Button { choosing = true } label: {
                    Label("\(visible.count) of \(shape.columns.count) columns", systemImage: "rectangle.split.3x1")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Wide table: only some columns are shown and fetched. Select a row to see all of its columns.")
                .popover(isPresented: $choosing, arrowEdge: .bottom) {
                    ColumnChooser(shape: shape, visible: visible, apply: setVisible)
                }
            }
        }
        .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected {
                RowInspector(shape: shape, row: selected, onClose: { self.selected = nil }).id(selected.id)
            }
        }
    }
}

/// Popover listing every column of a wide table with a checkbox.
private struct ColumnChooser: View {
    let shape: TableShape
    let visible: [Int]
    let apply: ([Int]) -> Void
    @State private var filter = ""

    var body: some View {
        let shown = Set(visible)
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let indices = shape.columns.indices.filter { needle.isEmpty || shape.columns[$0].name.localizedCaseInsensitiveContains(needle) }
        VStack(spacing: 0) {
            PaneFilterField(prompt: "Filter columns", text: $filter)
            Divider()
            List(indices, id: \.self) { index in
                let column = shape.columns[index]
                Toggle(isOn: Binding(
                    get: { shown.contains(index) },
                    set: { on in apply(on ? visible + [index] : visible.filter { $0 != index }) }
                )) {
                    HStack(spacing: 5) {
                        Text(column.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        if column.primaryKeyIndex > 0 { Image(systemName: "key.fill").font(.system(size: 8)).foregroundStyle(.yellow) }
                        Spacer(minLength: 6)
                        Text(column.declaredType.lowercased()).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(shown.contains(index) && shown.count == 1)
            }
            .listStyle(.plain)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("Default") { apply(RawSQL.defaultVisible(shape)) }
                    Button("Show All") { apply(Array(shape.columns.indices)) }
                    Spacer()
                    Text("\(visible.count) of \(shape.columns.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .controlSize(.small)
                Text("Each visible column is built for every row on screen, so showing many columns makes scrolling slower. The row inspector always lists all columns.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
        }
        .frame(width: 300, height: 420)
    }
}

/// Typed cell: NULL dimmed, numbers monospaced, blobs as a tag.
private struct RawCell: View {
    let value: SQLValue
    let fullSize: Int?
    let numeric: Bool

    var body: some View {
        switch value {
        case .null:
            Text("NULL").font(.caption).foregroundStyle(.quaternary)
        case .blob(let d):
            HStack(spacing: 4) {
                Image(systemName: "shippingbox").imageScale(.small).foregroundStyle(.brown)
                Text(Format.bytes(fullSize ?? d.count)).font(.callout).monospacedDigit()
                if let kind = RawSQL.magicLabel(d) { TagLabel(kind, tint: .brown) }
            }
        case .integer, .real:
            Text(RawSQL.cellText(value, fullSize: fullSize)).font(.callout).monospacedDigit().lineLimit(1)
        case .text:
            Text(RawSQL.cellText(value, fullSize: fullSize)).font(.callout).lineLimit(1).truncationMode(.tail)
        }
    }
}

/// Inspector for one row: every column with type and value; blobs and long texts open in
/// the ``BlobInspector``.
private struct RowInspector: View {
    let shape: TableShape
    let row: RawRow
    let onClose: () -> Void

    @State private var full: [SQLValue]?
    @State private var loadFailed = false
    @State private var openColumn: Int?
    @AppStorage("raw.sqlite.showNullColumns") private var showNulls = false

    /// The complete row once loaded, else whatever the table fetched for this column.
    private func value(_ index: Int) -> SQLValue? {
        if let full { return index < full.count ? full[index] : nil }
        return row.value(index)
    }

    var body: some View {
        Group {
            if let openColumn, let data = value(openColumn)?.data {
                InspectorPage(title: shape.columns[openColumn].name, subtitle: "\(shape.table) · row \(row.id)", scrolls: false, onClose: onClose) {
                    VStack(spacing: 0) {
                        HStack {
                            Button { self.openColumn = nil } label: { Label("All Columns", systemImage: "chevron.left") }
                                .buttonStyle(.link)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        Divider()
                        BlobInspector(data: data, title: shape.columns[openColumn].name)
                    }
                }
            } else {
                InspectorPage(title: shape.hasRowid ? "Row \(row.id)" : "Row", subtitle: shape.table, onClose: onClose) {
                    let nullCount = shape.columns.indices.filter { value($0)?.isNull == true }.count
                    let pending = full == nil ? shape.columns.indices.filter { value($0) == nil }.count : 0
                    ForEach(Array(shape.columns.enumerated()), id: \.offset) { index, column in
                        if let value = value(index), showNulls || !value.isNull {
                            ColumnValueView(
                                column: column, value: value,
                                truncated: full == nil && (row.size(index) ?? 0) > RawSQL.cellByteLimit,
                                open: { openColumn = index }
                            )
                        }
                    }
                    if pending > 0 {
                        Text(loadFailed ? "\(pending) hidden column\(pending == 1 ? "" : "s") could not be loaded for this row." : "Loading \(pending) more column\(pending == 1 ? "" : "s")…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if nullCount > 0 {
                        Button(showNulls ? "Hide \(nullCount) NULL Column\(nullCount == 1 ? "" : "s")" : "Show \(nullCount) NULL Column\(nullCount == 1 ? "" : "s")") { showNulls.toggle() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
        .task(id: row.id) {
            full = try? await RawSQL.fullRow(shape, rowid: row.id)
            loadFailed = full == nil
        }
    }
}

private struct ColumnValueView: View {
    let column: SQLColumnInfo
    let value: SQLValue
    let truncated: Bool
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(column.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if column.primaryKeyIndex > 0 { Image(systemName: "key.fill").font(.system(size: 8)).foregroundStyle(.yellow) }
                Spacer(minLength: 4)
                Text(value.typeName.lowercased()).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
            }
            switch value {
            case .null:
                Text("NULL").font(.callout).foregroundStyle(.quaternary)
            case .blob(let d):
                HStack(spacing: 6) {
                    Text(Format.bytes(d.count) + (truncated ? "+" : "")).font(.callout).monospacedDigit()
                    TagLabel(BlobSniffer.sniff(d).label, tint: .brown)
                    Spacer()
                    Button("Inspect", action: open).controlSize(.small)
                }
            case .text(let s):
                Text(s.count > 1_200 ? String(s.prefix(1_200)) + "…" : s)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .sensitive(.sensitive)
                if s.utf8.count > 600 || s.hasPrefix("{") || s.hasPrefix("[") || s.hasPrefix("<") {
                    Button("Inspect", action: open).controlSize(.small)
                }
            case .integer, .real:
                Text(value.description).font(.callout.monospacedDigit()).textSelection(.enabled).sensitive(.personal)
                if let hint = RawSQL.dateHint(column: column.name, value: value) {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider().padding(.top, 3)
        }
    }
}

// MARK: - Schema

private struct SchemaView: View {
    let objects: [SQLSchemaObject]
    let table: String?
    let columns: [SQLColumnInfo]

    var body: some View {
        let rank: (SQLSchemaObject) -> Int = { $0.type == "table" || $0.type == "view" ? 0 : ($0.type == "index" ? 1 : 2) }
        let related = objects.filter { table == nil || $0.tableName == table }.sorted { (rank($0), $0.name) < (rank($1), $1.name) }
        ScrollPage {
            if !columns.isEmpty {
                SectionHeader("Columns", subtitle: "\(columns.count) columns", symbol: "list.bullet.rectangle")
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                    GridRow {
                        Text("Name"); Text("Declared Type"); Text("Constraints")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider()
                    ForEach(columns) { column in
                        GridRow {
                            Text(column.name).font(.callout.monospaced()).textSelection(.enabled)
                            Text(column.declaredType.isEmpty ? "—" : column.declaredType).font(.callout).foregroundStyle(.secondary)
                            Text([column.primaryKeyIndex > 0 ? "PRIMARY KEY" : nil, column.notNull ? "NOT NULL" : nil].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .card()
            }
            SectionHeader("SQL Definition", subtitle: "\(related.count) schema object\(related.count == 1 ? "" : "s")", symbol: "curlybraces")
            ForEach(related) { object in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        TagLabel(object.type, tint: object.type == "index" ? .purple : (object.type == "trigger" ? .orange : .blue))
                        Text(object.name).font(.callout.weight(.medium)).textSelection(.enabled)
                    }
                    Text(object.sql ?? "(automatic — no SQL)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(object.sql == nil ? .tertiary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .card(padding: 10)
            }
        }
    }
}

// MARK: - SQL console

private struct ConsoleRow: Identifiable, Sendable {
    let id: Int
    let values: [SQLValue]
    let sizes: [Int]?
}

private struct ConsoleResult: Sendable {
    let columns: [String]
    let rows: [ConsoleRow]
    let truncated: Bool
    let seconds: Double
    let serial: Int
}

/// Ad-hoc SQL against the selected database. The connection is read-only at three levels
/// (`mode=ro`, `PRAGMA query_only`, authorizer), so any statement is safe to run.
private struct SQLConsole: View {
    let dbPath: String
    let table: String?
    var autoRun = false

    static let rowCap = 5_000

    @State private var sql = ""
    @State private var result: ConsoleResult?
    @State private var error: String?
    @State private var running = false
    @State private var task: Task<Void, Never>?
    @State private var serial = 0
    @State private var selected: ConsoleRow?

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                TextEditor(text: $sql)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                Divider()
                HStack(spacing: 10) {
                    Button {
                        run()
                    } label: {
                        Label(running ? "Running…" : "Run", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(running || sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if running {
                        Button("Cancel") { task?.cancel() }
                        ProgressView().controlSize(.small)
                    }
                    Group {
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
                        } else if let result {
                            Text("\(Format.count(result.rows.count)) row\(result.rows.count == 1 ? "" : "s")\(result.truncated ? " (capped — add LIMIT/OFFSET to page)" : "") in \(String(format: "%.3f", result.seconds))s")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("⌘↩ to run. Read-only: writes, ATTACH and schema changes are rejected.").foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption)
                    .textSelection(.enabled)
                    Spacer()
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).imageScale(.small).help("Read-only connection")
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(.bar)
            }
            .frame(minHeight: 96, idealHeight: 150, maxHeight: 260)

            Group {
                if let result {
                    PagedTable(
                        rows: result.rows,
                        columns: columns(result),
                        searchPrompt: "Filter result",
                        reloadKey: result.serial,
                        exportName: "query",
                        emptyTitle: "No Rows Returned",
                        onSelect: { selected = $0.count == 1 ? $0.first : nil }
                    ) {
                        if result.columns.count > RawSQL.defaultColumnCap {
                            Label("First \(RawSQL.defaultColumnCap) of \(result.columns.count) columns shown", systemImage: "rectangle.split.3x1")
                                .font(.caption).foregroundStyle(.secondary)
                                .help("Wide result: enable more columns in the Columns menu below, or select a row to see all of its columns.")
                        }
                    }
                    .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                        if let selected { ConsoleRowInspector(columns: result.columns, row: selected, onClose: { self.selected = nil }).id(selected.id) }
                    }
                    // A new run can return different columns. Changing the column set of a live
                    // SwiftUI Table aborts in AttributeGraph, so every result gets its own table.
                    .id(result.serial)
                } else {
                    StatePlaceholder(title: "Run a Query", symbol: "terminal", message: "Results appear here. At most \(Format.count(SQLConsole.rowCap)) rows are materialized per run.")
                }
            }
            .frame(minHeight: 160, maxHeight: .infinity)
        }
        .onAppear {
            if sql.isEmpty { sql = defaultSQL }
            if autoRun, table != nil, result == nil { run() }
        }
        .onChange(of: table) { old, _ in
            // The untouched template follows the table; with auto-run so does its result
            // (the automatic table choice can move on after the first run).
            let wasTemplate = sql == SQLConsole.template(for: old)
            if wasTemplate { sql = defaultSQL }
            if autoRun, wasTemplate || (result == nil && !running) { run() }
        }
        .onDisappear { task?.cancel() }
    }

    private var defaultSQL: String { SQLConsole.template(for: table) }

    private static func template(for table: String?) -> String {
        guard let table else { return "SELECT type, name, tbl_name FROM sqlite_master ORDER BY 1, 2;" }
        return "SELECT *\nFROM \(SQLiteDB.quote(table))\nLIMIT 100;"
    }

    private func columns(_ result: ConsoleResult) -> [PagedColumn<ConsoleRow>] {
        result.columns.enumerated().map { index, name in
            PagedColumn<ConsoleRow>(name, id: "\(index):\(name)", width: 160, min: 90, sensitivity: .sensitive, hiddenByDefault: index >= RawSQL.defaultColumnCap) { row in
                index < row.values.count ? RawSQL.cellText(row.values[index], fullSize: row.sizes?[index]) : ""
            }
            .cell { row in
                RawCell(value: index < row.values.count ? row.values[index] : .null, fullSize: row.sizes?[index], numeric: false)
            }
        }
    }

    private func run() {
        let statement = sql
        let path = dbPath
        task?.cancel()
        running = true
        error = nil
        selected = nil
        serial += 1
        let runSerial = serial
        task = Task {
            let started = Date()
            SnapshotReadiness.begin()
            defer { SnapshotReadiness.end() }
            do {
                let db = try await SQLiteDB.shared(path)
                let r = try await db.query(statement, maxRows: SQLConsole.rowCap, cellByteLimit: 64 * 1024)
                let rows = r.rows.enumerated().map { ConsoleRow(id: $0.offset, values: $0.element.values, sizes: $0.element.fullSizes) }
                if runSerial == serial {
                    result = ConsoleResult(columns: r.columns, rows: rows, truncated: r.truncated, seconds: Date().timeIntervalSince(started), serial: runSerial)
                }
            } catch is CancellationError {
                if runSerial == serial { error = "Cancelled" }
            } catch {
                if runSerial == serial { self.error = error.localizedDescription; result = nil }
            }
            if runSerial == serial { running = false }
        }
    }
}

private struct ConsoleRowInspector: View {
    let columns: [String]
    let row: ConsoleRow
    let onClose: () -> Void
    @State private var openColumn: Int?

    var body: some View {
        if let openColumn, openColumn < row.values.count, let data = row.values[openColumn].data {
            InspectorPage(title: columns[openColumn], subtitle: "result row \(row.id + 1)", scrolls: false, onClose: onClose) {
                VStack(spacing: 0) {
                    HStack {
                        Button { self.openColumn = nil } label: { Label("All Columns", systemImage: "chevron.left") }.buttonStyle(.link)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    Divider()
                    BlobInspector(data: data, title: columns[openColumn])
                }
            }
        } else {
            InspectorPage(title: "Result Row \(row.id + 1)", onClose: onClose) {
                ForEach(Array(columns.enumerated()), id: \.offset) { index, name in
                    if index < row.values.count {
                        ColumnValueView(
                            column: SQLColumnInfo(name: name, declaredType: "", notNull: false, primaryKeyIndex: 0, hidden: false),
                            value: row.values[index],
                            truncated: (row.sizes?[index] ?? 0) > 64 * 1024,
                            open: { openColumn = index }
                        )
                    }
                }
            }
        }
    }
}
