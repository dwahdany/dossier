import SwiftUI
import Charts
import DossierCore

/// 46-pt control strip at the top of a section (pickers, library menu).
struct SectionStrip<Leading: View, Trailing: View>: View {
    private let leading: Leading
    private let trailing: Trailing

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading(); self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            leading
            Spacer(minLength: 0)
            // The library menu keeps its width; whatever is on the leading side has to adapt.
            trailing.layoutPriority(1)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .frame(height: 46)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// One-sentence description next to a strip's controls. Wraps onto a second line when the pane
/// is narrow instead of being cut off mid-sentence; the full sentence is also the tooltip.
struct StripCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .help(text)
    }
}

/// Short explanatory paragraph: what a store is and where the data comes from.
struct InfoNote: View {
    let text: String
    var symbol = "info.circle"

    init(_ text: String, symbol: String = "info.circle") { self.text = text; self.symbol = symbol }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Ranked list with proportional bars: a compact table for "top N" data inside a card.
struct RankList: View {
    struct Item: Identifiable {
        let id: String
        let name: String
        let value: Double
        let valueText: String
        var detail: String = ""
    }

    let items: [Item]
    var tint: Color = .accentColor
    var sensitivity: Sensitivity = .low
    var limit = 12
    /// Width of the proportional bar; narrow cards pass less so the names stay readable.
    var barWidth: CGFloat = 110
    @State private var expanded = false

    init(_ items: [Item], tint: Color = .accentColor, sensitivity: Sensitivity = .low, limit: Int = 12) {
        self.items = items; self.tint = tint; self.sensitivity = sensitivity; self.limit = limit
    }

    func barWidth(_ width: CGFloat) -> RankList {
        var copy = self
        copy.barWidth = width
        return copy
    }

    init(_ counts: [NamedCount], tint: Color = .accentColor, sensitivity: Sensitivity = .low, limit: Int = 12) {
        self.init(counts.map { Item(id: $0.name + $0.detail, name: $0.name, value: Double($0.count), valueText: Format.count($0.count), detail: $0.detail) }, tint: tint, sensitivity: sensitivity, limit: limit)
    }

    init(_ counts: [GCount], tint: Color = .accentColor, sensitivity: Sensitivity = .low, limit: Int = 12) {
        self.init(counts.map { Item(id: $0.name, name: $0.name, value: Double($0.count), valueText: Format.count($0.count), detail: $0.detail) }, tint: tint, sensitivity: sensitivity, limit: limit)
    }

    var body: some View {
        let maxValue = max(items.map(\.value).max() ?? 1, 1)
        let shown = expanded ? items : Array(items.prefix(limit))
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text("Nothing recorded").font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle).sensitive(sensitivity)
                        if !item.detail.isEmpty {
                            Text(item.detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(tint.gradient)
                            .frame(width: max(2, geo.size.width * item.value / maxValue), height: 8)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(width: barWidth, height: 14)
                    Text(item.valueText).font(.callout).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                }
                .padding(.vertical, 4)
                if index < shown.count - 1 { Divider().opacity(0.5) }
            }
            if items.count > limit {
                Button(expanded ? "Show Fewer" : "Show All \(items.count)") { expanded.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.top, 6)
            }
        }
    }
}

/// Titled card.
struct TitledCard<Content: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    private let content: Content

    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                Text(title).font(.headline)
                Spacer(minLength: 0)
            }
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }
}

/// Two (or more) equal columns that collapse to one on narrow pages.
struct AdaptiveColumns<Content: View>: View {
    var minWidth: CGFloat = 360
    private let content: Content
    init(minWidth: CGFloat = 360, @ViewBuilder content: () -> Content) { self.minWidth = minWidth; self.content = content() }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
            content
        }
    }
}

/// Stacked year chart (photos vs videos or a single series).
struct YearChart: View {
    let years: [YearCount]
    var firstLabel = "Photos"
    var secondLabel: String? = "Videos"
    var height: CGFloat = 190

    private struct Point: Identifiable {
        let id: String
        let year: String
        let series: String
        let value: Int
    }

    var body: some View {
        let points: [Point] = years.flatMap { y -> [Point] in
            var out = [Point(id: "\(y.year)a", year: String(y.year), series: firstLabel, value: y.photos)]
            if let secondLabel { out.append(Point(id: "\(y.year)b", year: String(y.year), series: secondLabel, value: y.videos)) }
            return out
        }
        if points.isEmpty {
            Text("No dated items").font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 80)
        } else {
            Chart(points) { p in
                BarMark(x: .value("Year", p.year), y: .value("Items", p.value))
                    .foregroundStyle(by: .value("Kind", p.series))
                    .cornerRadius(2)
            }
            .chartForegroundStyleScale(domain: secondLabel.map { [firstLabel, $0] } ?? [firstLabel], range: [ChartPalette.color(0), ChartPalette.color(1)])
            .chartLegend(secondLabel == nil ? .hidden : .visible)
            .chartYAxis { AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let v = value.as(Int.self) { Text(Format.compact(v)) } }
            } }
            .frame(height: height)
        }
    }
}

/// Distribution of one coded attribute: proportional bars with "label (code)" rows.
struct CodeDistributionView: View {
    let distribution: PhotosStore.AttributeDistribution
    var showNote = true

    var body: some View {
        let total = max(distribution.counts.reduce(0) { $0 + $1.count }, 1)
        let analysed = max(distribution.analysed, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(distribution.attribute.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(distribution.attribute.column).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            ForEach(distribution.counts, id: \.code) { entry in
                let isZero = entry.code == 0 && distribution.counts.count > 1
                let fraction = isZero ? Double(entry.count) / Double(total) : Double(entry.count) / Double(analysed)
                HStack(spacing: 8) {
                    Text(distribution.attribute.table.label(entry.code))
                        .font(.caption)
                        .foregroundStyle(isZero ? .secondary : .primary)
                        .lineLimit(1)
                        .frame(width: 128, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.primary.opacity(0.06))
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(isZero ? AnyShapeStyle(Color.secondary.opacity(0.35)) : AnyShapeStyle(ChartPalette.color(entry.code - 1).gradient))
                                .frame(width: max(2, geo.size.width * fraction))
                        }
                    }
                    .frame(height: 9)
                    Text(Format.count(entry.count)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                    Text(Format.percent(fraction, digits: 0)).font(.caption2).monospacedDigit().foregroundStyle(.tertiary).frame(width: 34, alignment: .trailing)
                }
            }
            if showNote {
                Text(distribution.attribute.note).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card(padding: 12)
    }
}

/// Coverage bars: how much of the library each analysis has processed.
struct CoverageList: View {
    let rows: [Coverage]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.name).font(.callout)
                        Text(row.detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(Format.count(row.done)) · \(Format.percent(min(row.fraction, 1), digits: 0))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(row.fraction, 1)).progressViewStyle(.linear).tint(row.fraction >= 0.95 ? Color.green : Color.accentColor)
                }
            }
        }
    }
}

// MARK: - Reveal on demand

/// Tracks which free-text rows (captions, OCR, titles) the user has explicitly revealed.
final class RevealStore: ObservableObject, @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<String>()
    private var all = false

    var revealAll: Bool {
        get { lock.lock(); defer { lock.unlock() }; return all }
        set { objectWillChange.send(); lock.lock(); all = newValue; if !newValue { ids.removeAll() }; lock.unlock() }
    }

    func isRevealed(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return all || ids.contains(id)
    }

    func toggle(_ id: String) {
        objectWillChange.send()
        lock.lock()
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        lock.unlock()
    }

    func reveal(_ id: String) {
        objectWillChange.send()
        lock.lock(); ids.insert(id); lock.unlock()
    }

    func reset() {
        objectWillChange.send()
        lock.lock(); ids.removeAll(); all = false; lock.unlock()
    }
}

/// Table cell for sensitive free text: hidden until the row is revealed.
struct RevealCell: View {
    let id: String
    let text: String
    let hiddenSummary: String
    @ObservedObject var store: RevealStore

    var body: some View {
        if store.isRevealed(id) {
            Text(text).font(.callout).lineLimit(2).sensitive(.sensitive)
                .help("Click the eye in the inspector or use the context action to hide again")
        } else {
            HStack(spacing: 6) {
                Button {
                    store.reveal(id)
                } label: {
                    Label("Reveal", systemImage: "eye")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                Text(hiddenSummary).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }
}

/// "Reveal all" toggle with a sensitivity marker, for table accessory bars.
struct RevealAllToggle: View {
    @ObservedObject var store: RevealStore

    var body: some View {
        HStack(spacing: 6) {
            SensitivityBadge(.sensitive, compact: true)
            Toggle("Reveal All", isOn: Binding(get: { store.revealAll }, set: { store.revealAll = $0 }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
        }
        .help("Text is hidden until you reveal a row. Turn this on to show every row.")
    }
}

extension View {
    /// Fills the pane with a placeholder when there is no Photos library at all.
    @ViewBuilder
    func requiresLibrary(_ library: PhotosLibrary?) -> some View {
        if library == nil {
            StatePlaceholder.missing("No Photos library was found in ~/Pictures. Use the library menu to choose one.")
        } else {
            self
        }
    }
}

// MARK: - Mini table

/// Small static table for a few dozen rows inside a card (no paging, no selection).
struct MiniTable: View {
    struct Column {
        let title: String
        var alignment: HorizontalAlignment = .leading
        var sensitivity: Sensitivity = .low
        var secondary = false
        var monospacedDigits = false
        init(_ title: String, alignment: HorizontalAlignment = .leading, sensitivity: Sensitivity = .low, secondary: Bool = false) {
            self.title = title; self.alignment = alignment; self.sensitivity = sensitivity; self.secondary = secondary
            self.monospacedDigits = alignment == .trailing
        }
    }

    let columns: [Column]
    let rows: [[String]]
    var limit = 15
    var emptyText = "Nothing recorded"
    @State private var expanded = false

    init(_ columns: [Column], rows: [[String]], limit: Int = 15, emptyText: String = "Nothing recorded") {
        self.columns = columns; self.rows = rows; self.limit = limit; self.emptyText = emptyText
    }

    var body: some View {
        let shown = expanded ? rows : Array(rows.prefix(limit))
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                Text(emptyText).font(.callout).foregroundStyle(.tertiary).padding(.vertical, 4)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                            Text(column.title.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                // A header is never hyphenated or wrapped; a table with too many
                                // columns for its pane has to drop columns instead (see the callers).
                                .lineLimit(1)
                                .fixedSize()
                                .gridColumnAlignment(column.alignment)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                                let text = index < row.count ? row[index] : ""
                                Text(text.isEmpty ? "—" : text)
                                    .font(.callout)
                                    .monospacedDigit()
                                    .foregroundStyle(column.secondary || text.isEmpty ? .secondary : .primary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .sensitive(text.isEmpty ? .low : column.sensitivity)
                            }
                        }
                    }
                }
                if rows.count > limit {
                    Button(expanded ? "Show Fewer" : "Show All \(rows.count)") { expanded.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Map focus

/// Picks the heaviest contiguous group of points so a map opens on something legible when
/// the data spans continents (same ≈ 800 km greedy grouping as the Places section).
enum MapFocus {
    static func groups(_ points: [MapPoint]) -> [[MapPoint]] {
        var groups: [(lat: Double, lon: Double, weight: Double, points: [MapPoint])] = []
        for p in points.sorted(by: { $0.weight > $1.weight }) where p.isValid {
            var best: (index: Int, distance: Double)?
            for (i, g) in groups.enumerated() {
                let dLat = abs(g.lat - p.latitude)
                let dLon = abs(g.lon - p.longitude) * cos(p.latitude * .pi / 180)
                let d = (dLat * dLat + dLon * dLon).squareRoot()
                if d < 7.5, d < (best?.distance ?? .infinity) { best = (i, d) }
            }
            let w = max(p.weight, 1)
            if let best {
                var g = groups[best.index]
                g.lat = (g.lat * g.weight + p.latitude * w) / (g.weight + w)
                g.lon = (g.lon * g.weight + p.longitude * w) / (g.weight + w)
                g.weight += w
                g.points.append(p)
                groups[best.index] = g
            } else {
                groups.append((p.latitude, p.longitude, w, [p]))
            }
        }
        return groups.sorted { $0.weight > $1.weight }.map(\.points)
    }

    static func densest(_ points: [MapPoint]) -> (points: [MapPoint], omitted: Int) {
        let all = groups(points)
        guard let first = all.first else { return ([], 0) }
        return (first, points.filter(\.isValid).count - first.count)
    }
}

// MARK: - Decoded values with the raw code on hover

/// One row of a ``HintedGrid``: a decoded value plus, optionally, the raw stored code as a tooltip.
struct HintedItem: Identifiable {
    var id: String { label }
    let label: String
    let value: String
    var hint: String?
    var sensitivity: Sensitivity = .low
    var monospaced = false

    init(_ label: String, _ value: String?, hint: String? = nil, sensitivity: Sensitivity = .low, monospaced: Bool = false) {
        self.label = label; self.value = value ?? ""; self.hint = hint; self.sensitivity = sensitivity; self.monospaced = monospaced
    }

    /// A coded column: the label alone, the column name and integer code in the tooltip.
    init(_ label: String, code: Int?, table: CodeTable, column: String, unset: String? = nil, sensitivity: Sensitivity = .low) {
        self.label = label
        self.value = code == nil ? "" : (code == 0 && unset != nil ? unset! : table.shortLabel(code))
        self.hint = code.map { "\(column) = \($0)" + (table.isProbable($0) ? " · label not confirmed by the store" : "") }
        self.sensitivity = sensitivity
    }
}

/// Same look as `KeyValueGrid`, with a tooltip per value. Rows without a value are dropped.
struct HintedGrid: View {
    let items: [HintedItem]
    var labelWidth: CGFloat?

    init(_ items: [HintedItem], labelWidth: CGFloat? = nil) {
        self.items = items.filter { !$0.value.isEmpty && $0.value != "—" }
        self.labelWidth = labelWidth
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(items) { item in
                GridRow {
                    Text(item.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .trailing)
                        .gridColumnAlignment(.trailing)
                        .lineLimit(2)
                    Text(item.value)
                        .font(item.monospaced ? .callout.monospaced() : .callout)
                        .textSelection(.enabled)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .sensitive(item.sensitivity)
                        .help(item.hint ?? "")
                }
            }
        }
    }
}

// MARK: - Segmented picker that degrades

/// A segmented control when it fits the strip; otherwise the same choices with short titles,
/// and a pop-up menu as the last resort — a section strip must never be wider than its pane.
struct FittingSegmentedPicker<Value: Hashable>: View {
    struct Option: Identifiable {
        var id: Value { value }
        let value: Value
        let title: String
        var shortTitle: String?
    }

    let label: String
    let options: [Option]
    @Binding var selection: Value

    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker(short: false).pickerStyle(.segmented).fixedSize()
            if options.contains(where: { $0.shortTitle != nil }) {
                picker(short: true).pickerStyle(.segmented).fixedSize()
            }
            picker(short: false).pickerStyle(.menu).fixedSize()
        }
        .labelsHidden()
    }

    private func picker(short: Bool) -> some View {
        Picker(label, selection: $selection) {
            ForEach(options) { option in
                Text(short ? (option.shortTitle ?? option.title) : option.title).tag(option.value)
            }
        }
    }
}
