import SwiftUI
import Charts
import DossierCore

// MARK: - Model

/// One module's `summary()` as shown on the Overview.
struct ModuleResult: Identifiable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let firstSectionID: String?
    let summary: ModuleSummary
    let seconds: Double
}

/// A store beyond Full Disk Access, probed at load time.
struct ProtectedLine: Identifiable, Sendable {
    let store: KnownStore
    let availability: Availability
    var id: String { store.id }
}

/// Loads every module's summary concurrently and publishes each one as it arrives, so the
/// page fills in progressively instead of waiting for the slowest module.
@MainActor
final class OverviewModel: ObservableObject {
    @Published private(set) var results: [String: ModuleResult] = [:]
    @Published private(set) var protected: [ProtectedLine] = []
    @Published private(set) var isLoading = false
    @Published private(set) var totalSeconds: Double?
    private var generation = 0

    func load(_ modules: [any DossierModule]) async {
        generation += 1
        let gen = generation
        isLoading = true
        totalSeconds = nil
        SnapshotReadiness.begin()
        defer { SnapshotReadiness.end() }
        let started = Date()

        await withTaskGroup(of: ModuleResult?.self) { group in
            for module in modules {
                group.addTask {
                    let t0 = Date()
                    let summary = await module.summary()
                    if Task.isCancelled { return nil }
                    return ModuleResult(
                        id: module.id, title: module.title, symbol: module.symbol,
                        firstSectionID: module.sections.first?.id, summary: summary,
                        seconds: Date().timeIntervalSince(t0))
                }
            }
            group.addTask {
                let lines = Paths.protectedStores().map { ProtectedLine(store: $0, availability: Paths.probe($0.url)) }
                await MainActor.run { [weak self] in
                    if let self, gen == self.generation { self.protected = lines }
                }
                return nil
            }
            for await result in group {
                guard gen == generation, !Task.isCancelled else { return }
                if let result { results[result.id] = result }
            }
        }
        guard gen == generation, !Task.isCancelled else { return }
        totalSeconds = Date().timeIntervalSince(started)
        isLoading = false
    }

    /// Per-module timings for `--overview-timing` and the self-test.
    static func timings(_ modules: [any DossierModule]) async -> (total: Double, perModule: [(String, Double)]) {
        let started = Date()
        let per = await withTaskGroup(of: (Int, String, Double).self) { group -> [(String, Double)] in
            for (index, module) in modules.enumerated() {
                group.addTask {
                    let t0 = Date()
                    _ = await module.summary()
                    return (index, module.id, Date().timeIntervalSince(t0))
                }
            }
            var out: [(Int, String, Double)] = []
            for await item in group { out.append(item) }
            return out.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }
        return (Date().timeIntervalSince(started), per)
    }
}

// MARK: - Aggregation

/// Pure aggregation over the module summaries (unit-testable, no I/O).
enum OverviewMath {
    struct StoreLine: Identifiable {
        let id: String
        let module: ModuleResult
        let store: StoreInfo
    }

    struct Totals {
        var readable = 0
        var missing = 0
        var blocked = 0
        var distinctPaths = 0
        var bytes: Int64 = 0
        var rows = 0
        var earliest: Date?
        var latest: Date?
    }

    static func lines(_ results: [ModuleResult]) -> [StoreLine] {
        results.flatMap { r in r.summary.stores.map { StoreLine(id: r.id + "|" + $0.id, module: r, store: $0) } }
    }

    /// Several modules read the same store (knowledgeC, the iCloud key-value cache, …) and
    /// the Raw Explorer reports whole directory roots, so sizes are counted once per path
    /// and a store that lies inside another reported directory is not added again.
    static func totals(_ lines: [StoreLine], now: Date = Date()) -> Totals {
        var totals = Totals()
        var byPath: [String: (bytes: Int64, rows: Int)] = [:]
        for line in lines {
            switch line.store.availability {
            case .available: totals.readable += 1
            case .missing: totals.missing += 1
            case .inaccessible: totals.blocked += 1
            }
            guard line.store.availability.isAvailable else { continue }
            let path = line.store.path.standardizedFileURL.path
            let old = byPath[path] ?? (0, 0)
            byPath[path] = (max(old.bytes, line.store.sizeBytes ?? 0), max(old.rows, line.store.rowCount ?? 0))
            if let range = line.store.timeRange, DossierDate.isPlausible(range.lowerBound) {
                totals.earliest = min(totals.earliest ?? range.lowerBound, range.lowerBound)
                let upper = min(range.upperBound, now)
                totals.latest = max(totals.latest ?? upper, upper)
            }
        }
        totals.distinctPaths = byPath.count
        let paths = byPath.keys.sorted()
        for path in paths {
            let nested = paths.contains { other in other != path && other != "/" && path.hasPrefix(other.hasSuffix("/") ? other : other + "/") }
            if !nested { totals.bytes += byPath[path]!.bytes }
            totals.rows += byPath[path]!.rows
        }
        return totals
    }

    /// Facts ordered most private first; within a level in module order.
    static func rankedFacts(_ results: [ModuleResult]) -> [(fact: Fact, module: ModuleResult)] {
        let all = results.flatMap { r in r.summary.facts.map { (fact: $0, module: r) } }
        return all.enumerated().sorted { a, b in
            if a.element.fact.sensitivity != b.element.fact.sensitivity { return a.element.fact.sensitivity > b.element.fact.sensitivity }
            return a.offset < b.offset
        }.map(\.element)
    }
}

// MARK: - View

/// Dashboard aggregating every module's `summary()`.
struct OverviewView: View {
    let modules: [any DossierModule]

    @Environment(\.navigate) private var navigate
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.privacyMode) private var privacyMode
    @StateObject private var model = OverviewModel()
    @State private var factFilter: Sensitivity?
    @State private var showAllFacts = false
    @State private var coverage: CoverageWindow = .year

    /// Snapshot-able section wrapper (`--snapshot overview out.png`).
    static func section(modules: [any DossierModule]) -> ModuleSection {
        ModuleSection(id: "overview", title: "Overview", symbol: "rectangle.3.group") { OverviewView(modules: modules) }
    }

    enum CoverageWindow: String, CaseIterable, Identifiable {
        case days90 = "90 Days", year = "12 Months", all = "All Time"
        var id: String { rawValue }
        func start(earliest: Date, now: Date) -> Date {
            switch self {
            case .days90: return now.addingTimeInterval(-90 * 86_400)
            case .year: return now.addingTimeInterval(-365 * 86_400)
            case .all: return earliest
            }
        }
    }

    private var ordered: [ModuleResult] { modules.compactMap { model.results[$0.id] } }

    var body: some View {
        let results = ordered
        let lines = OverviewMath.lines(results)
        let totals = OverviewMath.totals(lines)
        ScrollPage {
            header
            StatTileRow(stats(results, lines: lines, totals: totals), minTileWidth: 170)
            moduleGrid
            facts(results)
            coverageChart(lines)
            protectedStores(lines)
            stores(lines, results: results)
        }
        .task(id: refreshToken) { await model.load(modules) }
    }

    // MARK: Header + tiles

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Paths.isDemo ? "What a Mac knows about its owner" : "What this Mac knows about you")
                    .font(.largeTitle.weight(.bold))
                Text(Paths.isDemo
                     ? "Demo data: every name, place, message and figure on these pages belongs to an invented person and was generated for screenshots. Nothing here comes from this Mac's stores."
                     : "A read-only look into the on-device knowledge and personalization stores macOS maintains. Nothing is modified and no store content is sent anywhere; maps download Apple map tiles for the area they show.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if model.isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading \(modules.count - model.results.count) of \(modules.count) modules…")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else if let seconds = model.totalSeconds {
                Text("Read in \(String(format: "%.1f", seconds)) s")
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    .help("Every module's summary runs concurrently; the page fills in as each one finishes.")
            }
        }
    }

    private func stats(_ results: [ModuleResult], lines: [OverviewMath.StoreLine], totals: OverviewMath.Totals) -> [Stat] {
        let facts = results.flatMap(\.summary.facts)
        let sensitive = facts.filter { $0.sensitivity == .sensitive }.count
        let outOfReach = model.protected.filter { !$0.availability.isAvailable && $0.availability != .missing }.count
        let blocked = totals.blocked + outOfReach
        let pending = model.isLoading && results.count < modules.count
        return [
            Stat("Stores Read", pending && lines.isEmpty ? "…" : "\(totals.distinctPaths)",
                 caption: totals.blocked > 0 ? "\(blocked) without access" : (outOfReach > 0 ? "all readable · \(outOfReach) system-protected" : "all readable"),
                 symbol: "externaldrive", tint: totals.blocked == 0 ? .accentColor : .orange),
            Stat("On Disk", totals.bytes > 0 ? Format.bytes(totals.bytes) : "…", caption: "each store counted once", symbol: "internaldrive", tint: .indigo),
            Stat("Rows & Records", totals.rows > 0 ? Format.compact(totals.rows) : "…", caption: totals.rows > 0 ? Format.count(totals.rows) : nil, symbol: "list.bullet.rectangle", tint: .teal),
            Stat("Reaches Back To", totals.earliest.map { DossierDate.day($0) } ?? "—",
                 caption: totals.latest.map { "newest record " + DossierDate.relative($0) }, symbol: "calendar", tint: .purple),
            Stat("Headline Facts", "\(facts.count)", caption: sensitive > 0 ? "\(sensitive) sensitive" : "none marked sensitive", symbol: "lock.shield", tint: .orange),
        ]
    }

    // MARK: Modules

    private var moduleGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Where to Look", subtitle: "One card per area — click to open it", symbol: "square.grid.2x2")
            BalancedGrid(minItemWidth: 250, spacing: 12) {
                ForEach(modules, id: \.id) { module in
                    ModuleCard(module: module, result: model.results[module.id]) {
                        if let target = module.sections.first?.id { navigate?(DeepLink(sectionID: target, payload: "")) }
                    }
                }
            }
        }
    }

    // MARK: Facts

    @ViewBuilder private func facts(_ results: [ModuleResult]) -> some View {
        let ranked = OverviewMath.rankedFacts(results)
        let filtered = factFilter.map { level in ranked.filter { $0.fact.sensitivity == level } } ?? ranked
        let collapsedCount = 18
        let shown = showAllFacts ? filtered : Array(filtered.prefix(collapsedCount))
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Headline Facts", subtitle: ranked.isEmpty ? (model.isLoading ? "Reading the stores…" : "No module reported any facts.") : (Paths.isDemo ? "What the system would hold about the invented owner, most private first" : "What the system holds about you, most private first"), symbol: "sparkles") {
                Picker("", selection: $factFilter) {
                    Text("All \(ranked.count)").tag(Sensitivity?.none)
                    ForEach([Sensitivity.sensitive, .personal, .low], id: \.self) { level in
                        Text("\(level.label) \(ranked.filter { $0.fact.sensitivity == level }.count)").tag(Sensitivity?.some(level))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if !shown.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: .infinity), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                        FactCard(fact: item.fact, module: item.module) {
                            if let target = item.fact.sectionID ?? item.module.firstSectionID { navigate?(DeepLink(sectionID: target, payload: "")) }
                        }
                    }
                }
                if filtered.count > collapsedCount {
                    Button(showAllFacts ? "Show Fewer" : "Show All \(filtered.count) Facts") { showAllFacts.toggle() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        }
    }

    // MARK: Coverage timeline

    fileprivate struct CoverageBar: Identifiable {
        let id: String
        let label: String
        let module: String
        let start: Date
        let end: Date
        let clippedStart: Bool
    }

    @ViewBuilder private func coverageChart(_ lines: [OverviewMath.StoreLine]) -> some View {
        let now = Date()
        // One bar per distinct store path that reports a time range (first reporter wins).
        let ranged: [OverviewMath.StoreLine] = {
            var seen = Set<String>()
            return lines.filter { line in
                guard line.store.availability.isAvailable, let range = line.store.timeRange, DossierDate.isPlausible(range.lowerBound) else { return false }
                return seen.insert(line.store.path.standardizedFileURL.path + "|" + line.store.name).inserted
            }
        }()
        let earliest = ranged.compactMap { $0.store.timeRange?.lowerBound }.min() ?? now
        let windowStart = coverage.start(earliest: earliest, now: now)
        let bars: [CoverageBar] = ranged.compactMap { line in
            guard let range = line.store.timeRange else { return nil }
            let end = min(range.upperBound, now)
            guard end >= windowStart else { return nil }
            let start = max(range.lowerBound, windowStart)
            // Keep very short ranges visible: at least 1/300 of the window.
            let minimum = now.timeIntervalSince(windowStart) / 300
            let paddedStart = end.timeIntervalSince(start) < minimum ? end.addingTimeInterval(-minimum) : start
            return CoverageBar(id: line.id, label: line.store.name, module: line.module.title, start: max(paddedStart, windowStart), end: end, clippedStart: range.lowerBound < windowStart)
        }
        let moduleOrder = modules.map(\.title)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Coverage", subtitle: "The period each store's records span — how far back the system remembers", symbol: "calendar.day.timeline.left") {
                Picker("", selection: $coverage) {
                    ForEach(CoverageWindow.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if bars.isEmpty {
                Text(model.isLoading ? "Reading the stores…" : "No store reported a time range in this window.")
                    .font(.callout).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .card()
            } else {
                CoverageRows(bars: bars, start: windowStart, end: now, modules: moduleOrder, yearsOnly: coverage == .all)
                    .card()
            }
        }
    }

    // MARK: Out of reach

    @ViewBuilder private func protectedStores(_ lines: [OverviewMath.StoreLine]) -> some View {
        let blocked = lines.filter { if case .inaccessible = $0.store.availability { return true } else { return false } }
        let blockedPaths = Dictionary(grouping: blocked, by: { $0.store.path.standardizedFileURL.path })
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                "Not Readable",
                subtitle: blocked.isEmpty
                    ? "Everything the modules look for can be read. These stores hold more, but macOS protects them beyond Full Disk Access."
                    : "\(blockedPaths.count) store\(blockedPaths.count == 1 ? "" : "s") could not be opened — usually Full Disk Access is missing. Others are protected beyond it.",
                symbol: "lock.slash")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(blockedPaths.keys.sorted(), id: \.self) { path in
                    if let first = blockedPaths[path]?.first {
                        AccessRow(
                            title: first.store.name,
                            detail: "Used by " + Set(blockedPaths[path]!.map(\.module.title)).sorted().joined(separator: ", ") + ". Grant Full Disk Access in System Settings › Privacy & Security, then choose View › Refresh.",
                            path: first.store.path, availability: first.store.availability, beyond: false)
                        Divider()
                    }
                }
                ForEach(model.protected) { line in
                    AccessRow(title: line.store.title, detail: line.store.detail, path: line.store.url, availability: line.availability, beyond: true)
                    if line.id != model.protected.last?.id { Divider() }
                }
                if model.protected.isEmpty && blocked.isEmpty {
                    Text("Checking…").font(.callout).foregroundStyle(.tertiary).padding(.vertical, 6)
                }
            }
            .card()
        }
    }

    // MARK: Stores

    @ViewBuilder private func stores(_ lines: [OverviewMath.StoreLine], results: [ModuleResult]) -> some View {
        let reporting = results.filter { !$0.summary.stores.isEmpty }
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Stores", subtitle: lines.isEmpty ? "Reading…" : "\(lines.count) entries from \(reporting.count) areas — stores shared by several areas appear once per area", symbol: "externaldrive")
            if !lines.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow {
                        Text("Store"); Text("Status")
                        Text("Size").gridColumnAlignment(.trailing)
                        Text("Rows").gridColumnAlignment(.trailing)
                        Text("Time Range"); Text("Notes")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    Divider()
                    ForEach(reporting) { result in
                        GridRow {
                            Label(result.title, systemImage: result.symbol)
                                .font(.callout.weight(.semibold))
                                .gridCellColumns(6)
                                .padding(.top, 10).padding(.bottom, 4)
                        }
                        ForEach(lines.filter { $0.module.id == result.id }) { line in
                            GridRow {
                                HStack(spacing: 6) {
                                    Circle().fill(color(line.store.availability)).frame(width: 7, height: 7)
                                    Text(line.store.name).font(.callout).lineLimit(1)
                                }
                                .padding(.leading, 6)
                                Text(line.store.availability.label)
                                    .font(.callout)
                                    .foregroundStyle(line.store.availability.isAvailable ? Color.secondary : Color.orange)
                                Text(Format.bytes(line.store.sizeBytes)).font(.callout).monospacedDigit()
                                Text(Format.count(line.store.rowCount)).font(.callout).monospacedDigit()
                                Text(DossierDate.range(line.store.timeRange)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                Text(line.store.note ?? "").font(.callout).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            .padding(.vertical, 4)
                            .help(privacyMode ? line.store.name : Format.tildePath(line.store.path))
                            .contextMenu {
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([line.store.path]) }
                                Button("Copy Path") { Pasteboard.copy(line.store.path.path) }
                                Button("Open in Raw Explorer") { navigate?(DeepLink(sectionID: "raw.files", payload: line.store.path.path)) }
                                if let target = line.module.firstSectionID {
                                    Button("Open \(line.module.title)") { navigate?(DeepLink(sectionID: target, payload: "")) }
                                }
                            }
                        }
                        Divider()
                    }
                }
                .card()
            }
        }
    }

    private func color(_ availability: Availability) -> Color {
        switch availability {
        case .available: return .green
        case .missing: return .gray
        case .inaccessible: return .orange
        }
    }
}

// MARK: - Pieces

private struct ModuleCard: View {
    let module: any DossierModule
    let result: ModuleResult?
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: module.symbol)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(module.title).font(.headline).lineLimit(1)
                    if let result {
                        let stores = result.summary.stores
                        let readable = stores.filter { $0.availability.isAvailable }
                        let blocked = stores.count - readable.count
                        let bytes = Self.distinctBytes(readable)
                        Text("\(module.sections.count) section\(module.sections.count == 1 ? "" : "s") · \(readable.count) store\(readable.count == 1 ? "" : "s") · \(Format.bytes(bytes))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                        HStack(spacing: 6) {
                            let sensitive = result.summary.facts.filter { $0.sensitivity == .sensitive }.count
                            if sensitive > 0 { TagLabel("\(sensitive) sensitive", tint: Sensitivity.sensitive.tint) }
                            if blocked > 0 { TagLabel("\(blocked) unavailable", tint: .orange) }
                            if stores.isEmpty { TagLabel("nothing found", tint: .secondary) }
                            else if sensitive == 0 && blocked == 0 { TagLabel("\(result.summary.facts.count) facts", tint: .secondary) }
                            Spacer(minLength: 0)
                            Text(String(format: "%.2f s", result.seconds)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                                .lineLimit(1).layoutPriority(-1)
                                .help("Time this area's summary took to load")
                        }
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Reading…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card(padding: 12)
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous).strokeBorder(Color.accentColor.opacity(hovering ? 0.5 : 0), lineWidth: 1))
        .onHover { hovering = $0 }
        .help("Open \(module.title)")
    }

    static func distinctBytes(_ stores: [StoreInfo]) -> Int64 {
        var byPath: [String: Int64] = [:]
        for store in stores { byPath[store.path.path] = max(byPath[store.path.path] ?? 0, store.sizeBytes ?? 0) }
        let paths = byPath.keys.sorted()
        return paths.reduce(0) { sum, path in
            let nested = paths.contains { $0 != path && $0 != "/" && path.hasPrefix($0 + "/") }
            return nested ? sum : sum + byPath[path]!
        }
    }
}

private struct FactCard: View {
    let fact: Fact
    let module: ModuleResult
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: fact.symbol ?? module.symbol)
                    .imageScale(.small)
                    .foregroundStyle(fact.sensitivity.tint)
                    .frame(width: 24, height: 24)
                    .background(fact.sensitivity.tint.opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(fact.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(fact.value)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .sensitive(fact.sensitivity)
                    Text(module.title).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card(padding: 10)
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous).strokeBorder(fact.sensitivity.tint.opacity(hovering ? 0.55 : 0), lineWidth: 1))
        .onHover { hovering = $0 }
        .help("\(fact.sensitivity.label) · open \(module.title)")
    }
}

private struct AccessRow: View {
    let title: String
    let detail: String
    let path: URL
    let availability: Availability
    /// True for stores that stay closed even with Full Disk Access.
    let beyond: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.callout.weight(.semibold))
                    TagLabel(status, tint: tint)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(Format.tildePath(path))
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .sensitive(.personal)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }

    private var status: String {
        switch availability {
        case .available: return Paths.isDemo ? "present in the demo data" : "readable on this Mac"
        case .missing: return "not present"
        case .inaccessible(let reason): return beyond ? "protected — \(reason.lowercased())" : "no access — \(reason.lowercased())"
        }
    }

    private var symbol: String {
        switch availability {
        case .available: return "lock.open"
        case .missing: return "questionmark.folder"
        case .inaccessible: return beyond ? "lock.shield" : "lock.fill"
        }
    }

    private var tint: Color {
        switch availability {
        case .available: return .green
        case .missing: return .secondary
        case .inaccessible: return .orange
        }
    }
}

/// Gantt-style rows: one line per store, a capsule for the period its records span.
private struct CoverageRows: View {
    let bars: [OverviewView.CoverageBar]
    let start: Date
    let end: Date
    let modules: [String]
    let yearsOnly: Bool

    private let labelWidth: CGFloat = 250
    private let ticks = 6

    private func color(_ module: String) -> Color { ChartPalette.color(modules.firstIndex(of: module) ?? 0) }

    private func tickLabel(_ fraction: Double) -> String {
        let date = start.addingTimeInterval(end.timeIntervalSince(start) * fraction)
        return date.formatted(yearsOnly ? .dateTime.year() : .dateTime.month(.abbreviated).year(.twoDigits))
    }

    var body: some View {
        let span = max(end.timeIntervalSince(start), 1)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(bars) { bar in
                HStack(spacing: 10) {
                    Text(bar.label)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: labelWidth, alignment: .leading)
                    GeometryReader { geo in
                        let x0 = geo.size.width * bar.start.timeIntervalSince(start) / span
                        let x1 = geo.size.width * bar.end.timeIntervalSince(start) / span
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.primary.opacity(0.05)).frame(height: 1)
                            UnevenRoundedRectangle(
                                topLeadingRadius: bar.clippedStart ? 0 : 4, bottomLeadingRadius: bar.clippedStart ? 0 : 4,
                                bottomTrailingRadius: 4, topTrailingRadius: 4)
                                .fill(color(bar.module).opacity(0.85))
                                .frame(width: max(x1 - x0, 3), height: 8)
                                .offset(x: min(x0, geo.size.width - 3))
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
                .frame(height: 17)
                .help("\(bar.label) — \(bar.module)")
            }
            HStack(spacing: 10) {
                Color.clear.frame(width: labelWidth, height: 1)
                HStack(spacing: 0) {
                    ForEach(0..<ticks, id: \.self) { i in
                        Text(tickLabel(Double(i) / Double(ticks)))
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .overlay(alignment: .trailing) { Text("now").font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.top, 6)
            FlowLayout(spacing: 14, lineSpacing: 4) {
                ForEach(modules.filter { m in bars.contains { $0.module == m } }, id: \.self) { module in
                    HStack(spacing: 5) {
                        Circle().fill(color(module)).frame(width: 7, height: 7)
                        Text(module).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 10)
        }
    }
}
