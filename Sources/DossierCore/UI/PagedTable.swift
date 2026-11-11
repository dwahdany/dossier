import SwiftUI
import AppKit

/// Sort request for a paged query.
public struct PageSort: Sendable, Hashable {
    /// ``PagedColumn/id`` of the sorted column.
    public let columnID: String
    public let ascending: Bool
    public init(columnID: String, ascending: Bool) { self.columnID = columnID; self.ascending = ascending }
    /// "ASC" / "DESC" for SQL.
    public var sqlDirection: String { ascending ? "ASC" : "DESC" }
}

/// Parameters of one page fetch.
public struct PageRequest: @unchecked Sendable {
    /// Number of rows already loaded (use for `OFFSET`).
    public let offset: Int
    /// Page size (use for `LIMIT`).
    public let limit: Int
    /// Current sort, nil = the source's natural order.
    public let sort: PageSort?
    /// Trimmed filter text ("" = none).
    public let search: String
    /// `id` of the last row already loaded (nil for the first page). Sources whose natural
    /// order is keyed by the row id can use it for keyset paging (`WHERE id > ?`) instead
    /// of `OFFSET`.
    public let cursor: AnyHashable?

    public init(offset: Int, limit: Int, sort: PageSort? = nil, search: String = "", cursor: AnyHashable? = nil) {
        self.offset = offset; self.limit = limit; self.sort = sort; self.search = search; self.cursor = cursor
    }
}

/// Column definition for ``PagedTable``.
public struct PagedColumn<Row>: Identifiable {
    public let id: String
    public var title: String
    /// Narrowest width of the column. A table that is narrower than the sum of its
    /// columns' minimums scrolls sideways. Default (no `min:`): the ideal width for
    /// columns up to 110 pt, otherwise 60 % of the ideal width but between 110 and 160 pt —
    /// so a narrow table (minimum window, inspector open) scrolls instead of squeezing
    /// every column to an unreadable stub.
    public var minWidth: CGFloat
    public var idealWidth: CGFloat
    public var maxWidth: CGFloat
    public var alignment: Alignment
    /// Whether clicking the header re-queries with a ``PageSort`` for this column.
    public var sortable: Bool
    public var sensitivity: Sensitivity
    public var monospaced: Bool
    /// Render in secondary colour (ids, technical columns).
    public var secondary: Bool
    /// Hidden until enabled in the column chooser.
    public var hiddenByDefault: Bool
    /// Cell text; also used for copy / CSV export.
    public var text: (Row) -> String
    /// Optional custom cell view (the text is still used for copy/export).
    public var view: ((Row) -> AnyView)?
    /// Optional numeric sort key for the in-memory ``PagedTable/init(rows:columns:…)``
    /// variant (durations, sizes, dates — anything whose text does not sort naturally).
    public var sortKey: ((Row) -> Double)?

    public init(
        _ title: String, id: String? = nil,
        width: CGFloat = 140, min: CGFloat? = nil, max: CGFloat? = nil,
        alignment: Alignment = .leading, sortable: Bool = true,
        sensitivity: Sensitivity = .low, monospaced: Bool = false, secondary: Bool = false,
        hiddenByDefault: Bool = false,
        text: @escaping (Row) -> String
    ) {
        self.id = id ?? title
        self.title = title
        self.idealWidth = width
        let upper = max ?? 2_000
        self.minWidth = Swift.min(min ?? PagedColumn.defaultMinimum(ideal: width), upper)
        self.maxWidth = upper
        self.alignment = alignment
        self.sortable = sortable
        self.sensitivity = sensitivity
        self.monospaced = monospaced
        self.secondary = secondary
        self.hiddenByDefault = hiddenByDefault
        self.text = text
    }

    /// The minimum width a column gets when none is given: see ``minWidth``.
    public static func defaultMinimum(ideal width: CGFloat) -> CGFloat {
        Swift.max(Swift.min(width, 110), Swift.min((width * 0.6).rounded(), 160))
    }

    /// Returns a copy that sorts by a number instead of the cell text (in-memory tables).
    public func sortKey(_ key: @escaping (Row) -> Double) -> PagedColumn<Row> {
        var copy = self
        copy.sortKey = key
        return copy
    }

    /// Returns a copy that renders a custom view in the cell.
    public func cell<V: View>(@ViewBuilder _ view: @escaping (Row) -> V) -> PagedColumn<Row> {
        var copy = self
        copy.view = { AnyView(view($0)) }
        return copy
    }
}

public extension PagedColumn {
    /// A date column: the cell shows the compact localized ``DossierDate/table(_:)`` form
    /// ("11 Nov, 16:29"), the tooltip the full localized timestamp, and copy / CSV export
    /// the sortable ``DossierDate/sortable(_:)`` form with seconds. In-memory tables sort
    /// it chronologically. Unless `max:` is given the column grows to at most 1.5 x its
    /// ideal width: a timestamp has a fixed length and should not soak up the spare width
    /// of a wide window.
    static func date(
        _ title: String, id: String? = nil,
        width: CGFloat = 130, min: CGFloat? = 96, max: CGFloat? = nil,
        sortable: Bool = true, sensitivity: Sensitivity = .low, secondary: Bool = false,
        hiddenByDefault: Bool = false,
        date: @escaping (Row) -> Date?
    ) -> PagedColumn<Row> {
        var column = PagedColumn<Row>(
            title, id: id, width: width, min: min, max: max ?? (width * 1.5).rounded(), sortable: sortable,
            sensitivity: sensitivity, secondary: secondary, hiddenByDefault: hiddenByDefault,
            text: { DossierDate.sortable(date($0)) }
        )
        column.sortKey = { date($0)?.timeIntervalSinceReferenceDate ?? -.infinity }
        column.view = { row in
            let value = date(row)
            return AnyView(
                Text(DossierDate.table(value))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(secondary ? .secondary : .primary)
                    .lineLimit(1)
                    .help(value.map { DossierDate.medium($0) } ?? "")
            )
        }
        return column
    }
}

/// `SortComparator` that only carries the column id / direction; sorting happens in the
/// data source, not in memory.
public struct PagedSortComparator<Row>: SortComparator, Hashable {
    public let columnID: String
    public var order: SortOrder = .forward
    public init(columnID: String) { self.columnID = columnID }
    public func compare(_ lhs: Row, _ rhs: Row) -> ComparisonResult { .orderedSame }
}

@MainActor
final class PagedTableModel<Row: Identifiable & Sendable>: ObservableObject where Row.ID: Sendable {
    enum Phase { case loading, ready, failed(LoadState<Void>) }

    @Published var rows: [Row] = []
    @Published var total: Int?
    @Published var phase: Phase = .loading
    @Published var isLoadingMore = false
    @Published var reachedEnd = false
    /// Set when fetching a further page failed; the rows loaded so far stay visible.
    @Published var loadMoreError: String?

    var pageSize = 200
    private var generation = 0
    private var fetch: (@Sendable (PageRequest) async throws -> [Row])?
    private var sort: PageSort?
    private var search = ""
    private var triggerID: Row.ID?
    private var loadMoreTask: Task<Void, Never>?

    deinit { loadMoreTask?.cancel() }

    /// Cancels a page fetch that is still running (reload, view disappeared).
    /// - Parameter rearm: re-arm the scroll trigger so the page is requested again when
    ///   its rows come back into view (false when a new query is about to replace the rows).
    func cancelLoadMore(rearm: Bool = true) {
        loadMoreTask?.cancel()
        loadMoreTask = nil
        if isLoadingMore {
            isLoadingMore = false
            if rearm { updateTrigger() }
        }
    }

    func reload(
        sort: PageSort?, search: String,
        fetch: @escaping @Sendable (PageRequest) async throws -> [Row],
        count: (@Sendable (PageRequest) async throws -> Int?)?
    ) async {
        generation += 1
        let gen = generation
        loadMoreTask?.cancel()
        loadMoreTask = nil
        self.fetch = fetch
        self.sort = sort
        self.search = search
        reachedEnd = false
        isLoadingMore = false
        loadMoreError = nil
        if rows.isEmpty { phase = .loading }
        let request = PageRequest(offset: 0, limit: pageSize, sort: sort, search: search, cursor: nil)

        SnapshotReadiness.begin()
        defer { SnapshotReadiness.end() }
        do {
            let page = try await cancellableDetached(priority: .userInitiated) { try await fetch(request) }
            guard gen == generation, !Task.isCancelled else { return }
            rows = page
            reachedEnd = page.count < pageSize
            updateTrigger()
            phase = .ready
            total = reachedEnd ? page.count : nil
        } catch is CancellationError {
            return
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            rows = []
            total = nil
            phase = .failed(.from(error: error))
            return
        }
        if !reachedEnd, let count {
            let n = try? await cancellableDetached(priority: .utility) { try await count(request) }
            guard gen == generation, !Task.isCancelled else { return }
            if let n { total = n }
        }
    }

    private func updateTrigger() {
        guard !reachedEnd, !rows.isEmpty else { triggerID = nil; return }
        triggerID = rows[max(0, rows.count - 30)].id
    }

    func rowAppeared(_ id: Row.ID) {
        guard id == triggerID else { return }
        triggerID = nil
        // Deferred: never mutate the row collection from inside a table layout pass.
        DispatchQueue.main.async { [weak self] in self?.loadMore() }
    }

    func loadMore() {
        guard !isLoadingMore, !reachedEnd, let fetch else { return }
        isLoadingMore = true
        loadMoreError = nil
        triggerID = nil
        let gen = generation
        let request = PageRequest(offset: rows.count, limit: pageSize, sort: sort, search: search, cursor: rows.last.map { AnyHashable($0.id) })
        loadMoreTask = Task { [weak self] in
            let result: Result<[Row], Error>
            do {
                result = .success(try await cancellableDetached(priority: .userInitiated) { try await fetch(request) })
            } catch {
                result = .failure(error)
            }
            // A cancelled or superseded fetch leaves the state to whoever cancelled it.
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.loadMoreTask = nil
            self.isLoadingMore = false
            switch result {
            case .success(let page):
                self.rows.append(contentsOf: page)
                self.reachedEnd = page.count < self.pageSize
                if self.reachedEnd, self.total == nil || self.total! < self.rows.count { self.total = self.rows.count }
                self.updateTrigger()
            case .failure(let error):
                if error is CancellationError { self.updateTrigger(); return }
                // Keep what is loaded, say what went wrong and offer a retry; the scroll
                // trigger stays disarmed so a broken page is not re-requested in a loop.
                self.loadMoreError = (LoadState<Void>.from(error: error).message) ?? error.localizedDescription
            }
        }
    }
}

/// A native `Table` over an asynchronous, paged data source.
///
/// Features: infinite scrolling (pages are fetched off the main actor as the user nears
/// the end), server-side sorting via column headers, a debounced filter field, a column
/// chooser, row-count footer, multi-selection with ⌘C copy (TSV) and CSV export,
/// loading / empty / error / no-access placeholders, Privacy Mode redaction per column.
///
/// ```swift
/// PagedTable(
///     columns: [
///         PagedColumn("Time", width: 150) { DossierDate.sortable($0.date) },
///         PagedColumn("App", id: "bundle", sensitivity: .personal) { $0.bundleID },
///     ],
///     reloadKey: selectedStream,
///     fetch: { req in try await store.events(offset: req.offset, limit: req.limit, sort: req.sort, search: req.search) },
///     count: { req in try await store.eventCount(search: req.search) },
///     onSelect: { rows in selected = rows.first }
/// )
/// ```
public struct PagedTable<Row: Identifiable & Sendable, Accessory: View>: View where Row.ID: Sendable {
    private let columns: [PagedColumn<Row>]
    private let pageSize: Int
    private let searchPrompt: String?
    private let reloadKey: AnyHashable
    private let exportName: String
    private let emptyTitle: String
    private let filter: Binding<String>?
    private let selectedID: Binding<Row.ID?>?
    private let fetch: @Sendable (PageRequest) async throws -> [Row]
    private let count: (@Sendable (PageRequest) async throws -> Int?)?
    private let onSelect: (([Row]) -> Void)?
    private let onActivate: ((Row) -> Void)?
    private let accessory: Accessory

    @StateObject private var model = PagedTableModel<Row>()
    @State private var selection: Set<Row.ID> = []
    @State private var sortOrder: [PagedSortComparator<Row>] = []
    @State private var searchText = ""
    @State private var hidden: Set<String>?
    @State private var footerWidth: CGFloat = 0
    @Environment(\.refreshToken) private var refreshToken

    /// - Parameters:
    ///   - columns: column definitions (order = display order).
    ///   - pageSize: rows per fetch.
    ///   - searchPrompt: placeholder of the filter field; nil hides the field (then
    ///     `PageRequest.search` is always "").
    ///   - reloadKey: change it to restart from the first page (e.g. selected table).
    ///   - exportName: suggested CSV file name.
    ///   - filter: optional two-way binding to the filter text, for sections that set the
    ///     filter themselves (deep links: `filterText = link.payload`). Requires a
    ///     non-nil `searchPrompt`.
    ///   - initialSort: sort shown in the header (and passed to `fetch`) before the user
    ///     clicks a column. The column id must be a sortable column.
    ///   - selectedID: optional two-way binding to the single selected row id, so a
    ///     section can highlight a row from outside (deep links). The row is selected
    ///     once it has been loaded; rows that are not loaded cannot be highlighted.
    ///   - fetch: returns the rows for a request; runs off the main actor. Return fewer
    ///     than `limit` rows to signal the end.
    ///   - count: optional total row count for the footer (runs after the first page).
    ///   - onSelect: called with the selected rows whenever the selection changes.
    ///   - onActivate: double-click / Return on a row.
    ///   - accessory: extra controls shown at the trailing edge of the filter bar.
    public init(
        columns: [PagedColumn<Row>],
        pageSize: Int = 200,
        searchPrompt: String? = "Filter",
        reloadKey: AnyHashable = 0,
        exportName: String = "export",
        emptyTitle: String = "No Rows",
        filter: Binding<String>? = nil,
        initialSort: PageSort? = nil,
        selectedID: Binding<Row.ID?>? = nil,
        fetch: @escaping @Sendable (PageRequest) async throws -> [Row],
        count: (@Sendable (PageRequest) async throws -> Int?)? = nil,
        onSelect: (([Row]) -> Void)? = nil,
        onActivate: ((Row) -> Void)? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.selectedID = selectedID
        if let initialSort {
            var comparator = PagedSortComparator<Row>(columnID: initialSort.columnID)
            comparator.order = initialSort.ascending ? .forward : .reverse
            _sortOrder = State(initialValue: [comparator])
        }
        self.columns = columns
        self.pageSize = pageSize
        self.searchPrompt = searchPrompt
        self.reloadKey = reloadKey
        self.exportName = exportName
        self.emptyTitle = emptyTitle
        self.filter = filter
        self.fetch = fetch
        self.count = count
        self.onSelect = onSelect
        self.onActivate = onActivate
        self.accessory = accessory()
    }

    private struct ExternalSelectionKey: Equatable {
        let id: Row.ID?
        let loaded: Int
    }

    private struct QueryKey: Hashable {
        let reloadKey: AnyHashable
        let token: Int
        let search: String
        let sort: PageSort?
    }

    private var currentSort: PageSort? {
        guard let first = sortOrder.first, columns.first(where: { $0.id == first.columnID })?.sortable == true else { return nil }
        return PageSort(columnID: first.columnID, ascending: first.order == .forward)
    }

    private var hiddenIDs: Set<String> { hidden ?? Set(columns.filter(\.hiddenByDefault).map(\.id)) }
    private var visibleColumns: [PagedColumn<Row>] {
        let h = hiddenIDs
        let visible = columns.filter { !h.contains($0.id) }
        return visible.isEmpty ? Array(columns.prefix(1)) : visible
    }

    public var body: some View {
        VStack(spacing: 0) {
            if searchPrompt != nil || Accessory.self != EmptyView.self {
                filterBar
                Divider()
            }
            ZStack {
                table
                overlay
            }
            Divider()
            footer
        }
        .task(id: QueryKey(reloadKey: reloadKey, token: refreshToken, search: searchText.trimmingCharacters(in: .whitespaces), sort: currentSort)) {
            let search = searchText.trimmingCharacters(in: .whitespaces)
            // The query changed: a page fetch for the previous query is of no use any more.
            model.cancelLoadMore(rearm: false)
            if !search.isEmpty {
                // Debounce typing.
                try? await Task.sleep(nanoseconds: 220_000_000)
                if Task.isCancelled { return }
            }
            model.pageSize = pageSize
            selection = []
            await model.reload(sort: currentSort, search: search, fetch: fetch, count: count)
            // Snapshot aid: DOSSIER_SNAPSHOT_SELECT_ROW=<n> selects row n after the first
            // load so inspectors can be captured offscreen.
            if let n = ProcessInfo.processInfo.environment["DOSSIER_SNAPSHOT_SELECT_ROW"].flatMap(Int.init),
               selection.isEmpty, model.rows.indices.contains(n) {
                selection = [model.rows[n].id]
            }
        }
        .onDisappear { model.cancelLoadMore() }
        .onChange(of: filter?.wrappedValue, initial: true) { _, external in
            if let external, external != searchText { searchText = external }
        }
        .onChange(of: searchText) { _, text in
            if let filter, filter.wrappedValue != text { filter.wrappedValue = text }
        }
        .onChange(of: selection) { _, newValue in
            if let selectedID {
                let single = newValue.count == 1 ? newValue.first : nil
                if selectedID.wrappedValue != single { selectedID.wrappedValue = single }
            }
            guard let onSelect else { return }
            onSelect(model.rows.filter { newValue.contains($0.id) })
        }
        .onChange(of: ExternalSelectionKey(id: selectedID?.wrappedValue, loaded: model.rows.count), initial: true) { _, key in
            guard selectedID != nil else { return }
            if let id = key.id {
                if selection != [id], model.rows.contains(where: { $0.id == id }) { selection = [id] }
            } else if selection.count == 1 {
                selection = []
            }
        }
    }

    // MARK: Pieces

    private var filterBar: some View {
        FilterBarLayout(spacing: 8, fieldMinimum: 140, fieldIdeal: 220, fieldMaximum: 280) {
            if let searchPrompt {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary).imageScale(.small)
                    TextField(searchPrompt, text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .help(searchPrompt)
                .layoutValue(key: FilterBarLayout.IsField.self, value: true)
            }
            accessory
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: Metrics.barHeight + 4)
        .background(.bar)
    }

    private var table: some View {
        Table(of: Row.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumnForEach(visibleColumns) { column in
                TableColumn(column.title, sortUsing: PagedSortComparator<Row>(columnID: column.id)) { (row: Row) in
                    PagedCell(column: column, row: row)
                        .onAppear { model.rowAppeared(row.id) }
                }
                .width(min: column.minWidth, ideal: column.idealWidth, max: column.maxWidth)
            }
        } rows: {
            ForEach(model.rows) { row in
                TableRow(row)
            }
        }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            if !ids.isEmpty {
                Button("Copy \(ids.count == 1 ? "Row" : "\(ids.count) Rows")") { copy(ids) }
                if ids.count == 1, let id = ids.first, let row = model.rows.first(where: { $0.id == id }) {
                    Menu("Copy Value") {
                        ForEach(visibleColumns) { column in
                            Button(column.title) { Pasteboard.copy(column.text(row)) }
                        }
                    }
                }
                Divider()
                Button("Export Selection as CSV…") { export(ids) }
            }
        } primaryAction: { ids in
            if let onActivate, let id = ids.first, let row = model.rows.first(where: { $0.id == id }) { onActivate(row) }
        }
        .onCopyCommand {
            let text = tsv(selection)
            return text.isEmpty ? [] : [NSItemProvider(object: text as NSString)]
        }
        // A caller that swaps rows and the column set in one update (a SQL console) made
        // the live Table abort inside AttributeGraph: a new column set is a new table.
        .id(columns.map(\.id))
    }

    @ViewBuilder private var overlay: some View {
        switch model.phase {
        case .loading:
            LoadingPlaceholder().background(Color(nsColor: .controlBackgroundColor))
        case .failed(let state):
            Group {
                switch state {
                case .inaccessible(let m): StatePlaceholder.inaccessible(m)
                case .missing(let m): StatePlaceholder.missing(m)
                case .failed(let m): StatePlaceholder(title: "Couldn’t Load", symbol: "exclamationmark.triangle", message: m)
                default: EmptyView()
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
        case .ready:
            if model.rows.isEmpty {
                let searching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
                StatePlaceholder(
                    title: searching ? "No Matches" : emptyTitle,
                    symbol: searching ? "magnifyingglass" : "tray",
                    message: searching ? "Nothing matches “\(searchText)”." : nil
                )
                .padding(.top, 28)
                .allowsHitTesting(false)
            }
        }
    }

    /// The footer never wraps. From wide to narrow: everything; without "N selected"; the
    /// short count ("200 / 6,465"); icon-only Columns / Export menus, with the count
    /// truncating last.
    ///
    /// Only the texts go through `ViewThatFits`. The menus are AppKit pop-up buttons, and
    /// `ViewThatFits` builds the controls of every alternative again on each layout pass —
    /// with menus inside, a window full of tables became several times slower to lay out.
    /// Their form follows the measured footer width instead.
    private var footer: some View {
        let iconOnly = footerWidth > 0 && footerWidth < compactFooterWidth
        return HStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    footerCount(countLabel).fixedSize()
                    if !selection.isEmpty {
                        Text("\(Format.count(selection.count)) selected").font(.caption).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                    }
                }
                footerCount(countLabel).fixedSize()
                footerCount(shortCountLabel).fixedSize()
                footerCount(shortCountLabel).truncationMode(.middle)
            }
            if model.isLoadingMore {
                ProgressView().controlSize(.mini)
            }
            if let message = model.loadMoreError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Couldn’t load more rows: \(message)")
                ViewThatFits(in: .horizontal) {
                    Text("Couldn’t load more rows").font(.caption).foregroundStyle(.orange).lineLimit(1).fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
                Button("Retry") { model.loadMore() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            if iconOnly {
                footerMenus.labelStyle(.iconOnly)
            } else {
                footerMenus.labelStyle(.titleAndIcon)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(height: Metrics.barHeight - 4)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .onGeometryChange(for: CGFloat.self) { ($0.size.width / 4).rounded() * 4 } action: { footerWidth = $0 }
    }

    private func footerCount(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .help(countLabel)
    }

    /// Below this footer width the menus show only their icons: the short count plus the
    /// titled menus (about 180 pt) no longer fit.
    private var compactFooterWidth: CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        let text = (shortCountLabel as NSString).size(withAttributes: [.font: font]).width
        var extras: CGFloat = 0
        if model.isLoadingMore { extras += 26 }
        if model.loadMoreError != nil { extras += 80 }
        return 20 + text + 10 + extras + 190
    }

    private var footerMenus: some View {
            Group {
                Menu {
                    ForEach(columns) { column in
                        Toggle(column.title, isOn: Binding(
                            get: { !hiddenIDs.contains(column.id) },
                            set: { show in
                                var h = hiddenIDs
                                if show { h.remove(column.id) } else { h.insert(column.id) }
                                hidden = h
                            }
                        ))
                    }
                    Divider()
                    Button("Reset Columns") { hidden = nil }
                } label: {
                    Label("Columns", systemImage: "tablecells")
                }
                .help("Choose visible columns")

                Menu {
                    Button("Copy Loaded Rows") { Pasteboard.copy(tsv(Set(model.rows.map(\.id)))) }
                    Button("Export Loaded Rows as CSV…") { export(Set(model.rows.map(\.id))) }
                    if !selection.isEmpty {
                        Button("Export Selection as CSV…") { export(selection) }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Copy or export rows")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
    }

    /// "200 / 6,465" instead of "200 of 6,465 rows loaded".
    private var shortCountLabel: String {
        if case .ready = model.phase, let total = model.total, model.rows.count < total {
            return "\(Format.count(model.rows.count)) / \(Format.count(total))"
        }
        return countLabel
    }

    private var countLabel: String {
        let loaded = model.rows.count
        switch model.phase {
        case .loading: return "Loading…"
        case .failed: return "—"
        case .ready:
            if let total = model.total {
                if loaded >= total { return "\(Format.count(total)) row\(total == 1 ? "" : "s")" }
                return "\(Format.count(loaded)) of \(Format.count(total)) rows loaded"
            }
            return model.reachedEnd ? "\(Format.count(loaded)) rows" : "\(Format.count(loaded))+ rows"
        }
    }

    // MARK: Copy / export

    private func selectedRows(_ ids: Set<Row.ID>) -> [Row] { model.rows.filter { ids.contains($0.id) } }

    private func tsv(_ ids: Set<Row.ID>) -> String {
        let cols = visibleColumns
        let rows = selectedRows(ids)
        guard !rows.isEmpty else { return "" }
        let clean: (String) -> String = { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        var lines = rows.count > 1 ? [cols.map(\.title).joined(separator: "\t")] : []
        lines += rows.map { row in cols.map { clean($0.text(row)) }.joined(separator: "\t") }
        return lines.joined(separator: "\n")
    }

    private func copy(_ ids: Set<Row.ID>) { Pasteboard.copy(tsv(ids)) }

    private func export(_ ids: Set<Row.ID>) {
        let cols = visibleColumns
        let rows = selectedRows(ids).map { row in cols.map { $0.text(row) } }
        CSV.export(header: cols.map(\.title), rows: rows, suggestedName: exportName)
    }
}

public extension PagedTable where Accessory == EmptyView {
    init(
        columns: [PagedColumn<Row>],
        pageSize: Int = 200,
        searchPrompt: String? = "Filter",
        reloadKey: AnyHashable = 0,
        exportName: String = "export",
        emptyTitle: String = "No Rows",
        filter: Binding<String>? = nil,
        initialSort: PageSort? = nil,
        selectedID: Binding<Row.ID?>? = nil,
        fetch: @escaping @Sendable (PageRequest) async throws -> [Row],
        count: (@Sendable (PageRequest) async throws -> Int?)? = nil,
        onSelect: (([Row]) -> Void)? = nil,
        onActivate: ((Row) -> Void)? = nil
    ) {
        self.init(columns: columns, pageSize: pageSize, searchPrompt: searchPrompt, reloadKey: reloadKey, exportName: exportName, emptyTitle: emptyTitle, filter: filter, initialSort: initialSort, selectedID: selectedID, fetch: fetch, count: count, onSelect: onSelect, onActivate: onActivate) { EmptyView() }
    }

    /// In-memory convenience: pages, filters (substring match over all column texts) and
    /// sorts a fixed array. Sorting uses a column's ``PagedColumn/sortKey`` when it has
    /// one; otherwise texts that are plain numbers (with or without grouping separators)
    /// compare numerically and everything else in natural string order. Use for results
    /// that are already small (≲ 50k rows); `reloadKey` must change when `rows` changes.
    init(
        rows: [Row],
        columns: [PagedColumn<Row>],
        searchPrompt: String? = "Filter",
        reloadKey: AnyHashable,
        exportName: String = "export",
        emptyTitle: String = "No Rows",
        filter: Binding<String>? = nil,
        initialSort: PageSort? = nil,
        selectedID: Binding<Row.ID?>? = nil,
        onSelect: (([Row]) -> Void)? = nil,
        onActivate: ((Row) -> Void)? = nil
    ) {
        let source = InMemoryPageSource(rows: rows, columns: columns)
        self.init(
            columns: columns, pageSize: 200, searchPrompt: searchPrompt, reloadKey: reloadKey,
            exportName: exportName, emptyTitle: emptyTitle, filter: filter,
            initialSort: initialSort, selectedID: selectedID,
            fetch: { request in await source.page(request) },
            count: { request in await source.count(request) },
            onSelect: onSelect, onActivate: onActivate
        ) { EmptyView() }
    }
}

public extension PagedTable {
    /// In-memory variant with extra controls at the trailing edge of the filter bar.
    init(
        rows: [Row],
        columns: [PagedColumn<Row>],
        searchPrompt: String? = "Filter",
        reloadKey: AnyHashable,
        exportName: String = "export",
        emptyTitle: String = "No Rows",
        filter: Binding<String>? = nil,
        initialSort: PageSort? = nil,
        selectedID: Binding<Row.ID?>? = nil,
        onSelect: (([Row]) -> Void)? = nil,
        onActivate: ((Row) -> Void)? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        let source = InMemoryPageSource(rows: rows, columns: columns)
        self.init(
            columns: columns, pageSize: 200, searchPrompt: searchPrompt, reloadKey: reloadKey,
            exportName: exportName, emptyTitle: emptyTitle, filter: filter,
            initialSort: initialSort, selectedID: selectedID,
            fetch: { request in await source.page(request) },
            count: { request in await source.count(request) },
            onSelect: onSelect, onActivate: onActivate,
            accessory: accessory
        )
    }
}

/// The bar above a ``PagedTable``: filter field at the leading edge, the caller's
/// accessory at the trailing edge.
///
/// * The accessory is sized first, with the width that is left beside the field's minimum,
///   so an adaptive accessory (`ViewThatFits`, ``AdaptiveSegmentedPicker``) picks the form
///   that fits and a rigid one is never offered just "half of the bar".
/// * The field then gets the rest, between `fieldMinimum` and `fieldMaximum` — it is never
///   squeezed down to its icon.
/// * When field and accessory do not fit on one line the accessory moves to a **second
///   row** below the field.
///
/// Zero-width proposal (minimum-size query): the wider of the field's minimum and the
/// accessory's own minimum (two rows) — never their sum. Ideal: one row with the field at
/// `fieldIdeal`.
struct FilterBarLayout: Layout {
    /// Marks the filter field among the subviews (everything else is accessory).
    struct IsField: LayoutValueKey { static let defaultValue = false }

    var spacing: CGFloat
    var fieldMinimum: CGFloat
    var fieldIdeal: CGFloat
    var fieldMaximum: CGFloat
    var rowSpacing: CGFloat = 6

    private struct Arrangement {
        var size: CGSize = .zero
        var field: CGRect?
        /// Accessory subviews in order, laid out as a trailing-aligned row.
        var accessories: [(index: Int, frame: CGRect)] = []
    }

    private func arrange(_ subviews: Subviews, width proposed: CGFloat?) -> Arrangement {
        let fieldIndex = subviews.firstIndex { $0[IsField.self] }
        let others = subviews.indices.filter { $0 != fieldIndex }
        let fieldHeight = fieldIndex.map { subviews[$0].sizeThatFits(ProposedViewSize(width: fieldIdeal, height: nil)).height } ?? 0
        let fieldFloor: CGFloat = fieldIndex == nil ? 0 : fieldMinimum
        let gap: CGFloat = fieldIndex == nil || others.isEmpty ? 0 : spacing

        /// Sizes the accessory views for a row `limit` wide (nil: ideal sizes). A view is
        /// never offered more than its ideal width, so a greedy one (a `Spacer`, an
        /// `HStack` with one) does not take the field's share.
        func accessorySizes(_ limit: CGFloat?) -> [CGSize] {
            var remaining = limit
            return others.map { index in
                let ideal = subviews[index].sizeThatFits(.unspecified)
                guard let r = remaining else { return ideal }
                let size = ideal.width <= r ? ideal : subviews[index].sizeThatFits(ProposedViewSize(width: max(0, r), height: nil))
                remaining = r - size.width - spacing
                return size
            }
        }
        func rowWidth(_ sizes: [CGSize]) -> CGFloat {
            sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, sizes.count - 1))
        }
        func rowHeight(_ sizes: [CGSize]) -> CGFloat { sizes.map(\.height).max() ?? 0 }

        var result = Arrangement()
        guard let width = proposed, width.isFinite else {
            // Ideal: everything on one line.
            let sizes = accessorySizes(nil)
            let field = fieldIndex == nil ? 0 : fieldIdeal
            result.size = CGSize(width: field + gap + rowWidth(sizes), height: max(fieldHeight, rowHeight(sizes)))
            return result
        }

        // One line: accessory beside a field of at least its minimum width.
        let beside = accessorySizes(width - fieldFloor - gap)
        let besideWidth = rowWidth(beside)
        if others.isEmpty || fieldIndex == nil || besideWidth + gap + fieldFloor <= width + 0.5 {
            let height = max(fieldHeight, rowHeight(beside))
            let fieldWidth = fieldIndex == nil ? 0 : min(fieldMaximum, max(fieldFloor, width - besideWidth - gap))
            if fieldIndex != nil {
                result.field = CGRect(x: 0, y: (height - fieldHeight) / 2, width: fieldWidth, height: fieldHeight)
            }
            let total = max(width, fieldWidth + gap + besideWidth)
            var x = total - besideWidth
            for (offset, index) in others.enumerated() {
                let size = beside[offset]
                result.accessories.append((index, CGRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)))
                x += size.width + spacing
            }
            result.size = CGSize(width: total, height: height)
            return result
        }

        // Two lines: the field on the first, the accessory (offered the full width) below.
        let below = accessorySizes(width)
        let belowWidth = rowWidth(below)
        let belowHeight = rowHeight(below)
        let total = max(width, fieldFloor, belowWidth)
        result.field = CGRect(x: 0, y: 0, width: min(fieldMaximum, total), height: fieldHeight)
        var x = max(0, total - belowWidth)
        let top = fieldHeight + rowSpacing
        for (offset, index) in others.enumerated() {
            let size = below[offset]
            result.accessories.append((index, CGRect(x: x, y: top + (belowHeight - size.height) / 2, width: size.width, height: size.height)))
            x += size.width + spacing
        }
        result.size = CGSize(width: total, height: top + belowHeight)
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let a = arrange(subviews, width: bounds.width)
        if let field = a.field, let index = subviews.firstIndex(where: { $0[IsField.self] }) {
            subviews[index].place(at: CGPoint(x: bounds.minX + field.minX, y: bounds.minY + field.minY), anchor: .topLeading,
                                  proposal: ProposedViewSize(field.size))
        }
        for item in a.accessories {
            subviews[item.index].place(at: CGPoint(x: bounds.minX + item.frame.minX, y: bounds.minY + item.frame.minY), anchor: .topLeading,
                                       proposal: ProposedViewSize(item.frame.size))
        }
    }
}

/// Parses cell texts that are plain numbers — "1.234", "1,234", "12 %", "−3,5" — using the
/// current locale's separators, so formatted counts sort by value.
enum NumericText {
    private static let grouping: Character? = Locale.current.groupingSeparator?.first
    private static let decimal: Character = Locale.current.decimalSeparator?.first ?? "."

    static func value(_ text: String) -> Double? {
        guard let first = text.unicodeScalars.first, text.utf8.count <= 32 else { return nil }
        guard CharacterSet.decimalDigits.contains(first) || first == "-" || first == "−" || first == "+" else { return nil }
        var cleaned = ""
        cleaned.reserveCapacity(text.count)
        for ch in text {
            if ch.isNumber { cleaned.append(ch) }
            else if ch == decimal { cleaned.append(".") }
            else if ch == grouping || ch == "\u{a0}" || ch == "\u{202f}" || ch == " " || ch == "%" || ch == "’" { continue }
            else if ch == "-" || ch == "−" { cleaned.append("-") }
            else if ch == "+" { continue }
            else { return nil }
        }
        return Double(cleaned)
    }
}

/// Filters / sorts a fixed array off the main actor, caching the last filtered+sorted view.
private actor InMemoryPageSource<Row: Identifiable & Sendable> {
    private let rows: [Row]
    private let texts: [String: (Row) -> String]
    private let keys: [String: (Row) -> Double]
    private let order: [String]
    private var cacheKey: String?
    private var cache: [Row] = []

    init(rows: [Row], columns: [PagedColumn<Row>]) {
        self.rows = rows
        self.order = columns.map(\.id)
        self.texts = Dictionary(columns.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
        self.keys = Dictionary(columns.compactMap { c in c.sortKey.map { (c.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    private func view(_ request: PageRequest) -> [Row] {
        let key = request.search + "\u{1}" + (request.sort.map { "\($0.columnID)|\($0.ascending)" } ?? "")
        if key == cacheKey { return cache }
        var result = rows
        if !request.search.isEmpty {
            let needle = request.search
            let extractors = order.compactMap { texts[$0] }
            result = result.filter { row in
                extractors.contains { $0(row).range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
        if let sort = request.sort, let key = keys[sort.columnID] {
            let keyed = result.enumerated().map { (key($0.element), $0.offset, $0.element) }
            result = keyed.sorted { a, b in
                if a.0 == b.0 { return a.1 < b.1 }
                return sort.ascending ? a.0 < b.0 : a.0 > b.0
            }.map(\.2)
        } else if let sort = request.sort, let text = texts[sort.columnID] {
            let keyed = result.map { row -> (String, Double?, Row) in
                let t = text(row)
                return (t, NumericText.value(t), row)
            }
            // Numeric comparison only when every non-empty cell is a number.
            let allNumeric = keyed.allSatisfy { $0.1 != nil || $0.0.isEmpty || $0.0 == "—" }
            let sorted = keyed.sorted { a, b in
                if allNumeric {
                    let x = a.1 ?? -.infinity, y = b.1 ?? -.infinity
                    if x != y { return sort.ascending ? x < y : x > y }
                    return false
                }
                let r = a.0.compare(b.0, options: [.numeric, .caseInsensitive])
                return sort.ascending ? r == .orderedAscending : r == .orderedDescending
            }
            result = sorted.map(\.2)
        }
        cacheKey = key
        cache = result
        return result
    }

    func page(_ request: PageRequest) -> [Row] {
        let all = view(request)
        guard request.offset < all.count else { return [] }
        return Array(all[request.offset..<min(all.count, request.offset + request.limit)])
    }

    func count(_ request: PageRequest) -> Int? { view(request).count }
}

private struct PagedCell<Row>: View {
    let column: PagedColumn<Row>
    let row: Row

    var body: some View {
        Group {
            if let view = column.view {
                view(row)
            } else {
                Text(column.text(row))
                    .font(column.monospaced ? .callout.monospaced() : .callout)
                    .monospacedDigit()
                    .foregroundStyle(column.secondary ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: column.alignment)
        .sensitive(column.sensitivity)
    }
}
