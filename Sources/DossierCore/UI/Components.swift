import SwiftUI
import AppKit

// MARK: - Layout metrics

/// Shared spacing / sizing constants. Use these instead of ad-hoc numbers.
public enum Metrics {
    /// Outer padding of scrolling pages.
    public static let pagePadding: CGFloat = 20
    /// Vertical spacing between page blocks (header + content groups).
    public static let blockSpacing: CGFloat = 22
    /// Inner padding of cards and tiles.
    public static let cardPadding: CGFloat = 14
    public static let cardCornerRadius: CGFloat = 10
    /// Default / minimum inspector width.
    public static let inspectorWidth: CGFloat = 340
    /// Height of table header / footer bars.
    public static let barHeight: CGFloat = 30
    /// Height of a section's control strip (``HeaderStrip``).
    public static let headerStripHeight: CGFloat = 46
}

// MARK: - Privacy mode

private struct SensitiveModifier: ViewModifier {
    let level: Sensitivity
    @Environment(\.privacyMode) private var privacyMode

    func body(content: Content) -> some View {
        if privacyMode && level >= .personal {
            content
                .redacted(reason: .placeholder)
                .blur(radius: level == .sensitive ? 4 : 2.5)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        } else {
            content
        }
    }
}

public extension View {
    /// Marks a value as private. With Privacy Mode on (`\.privacyMode`), `.personal` and
    /// `.sensitive` values are redacted and blurred; `.low` values are never hidden.
    func sensitive(_ level: Sensitivity = .sensitive) -> some View { modifier(SensitiveModifier(level: level)) }

    /// Standard card look: padded, rounded, subtle fill and hairline border.
    func card(padding: CGFloat = Metrics.cardPadding) -> some View {
        self
            .padding(padding)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
    }
}

/// Small capsule showing a sensitivity level.
public struct SensitivityBadge: View {
    private let level: Sensitivity
    private let compact: Bool

    public init(_ level: Sensitivity, compact: Bool = false) { self.level = level; self.compact = compact }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: level.symbol).imageScale(.small)
            if !compact { Text(level.label).lineLimit(1) }
        }
        .font(.caption2.weight(.medium))
        .fixedSize()                    // a capsule never wraps or collapses into a sliver
        .padding(.horizontal, compact ? 4 : 6)
        .padding(.vertical, 2)
        .foregroundStyle(level.tint)
        .background(level.tint.opacity(0.13), in: Capsule())
        .help("\(level.label) information")
    }
}

/// Small neutral capsule label ("bplist", "local", "v2").
public struct TagLabel: View {
    private let text: String
    private let tint: Color
    public init(_ text: String, tint: Color = .secondary) { self.text = text; self.tint = tint }

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.13), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Page scaffolds

/// A vertically scrolling page with standard padding and block spacing — the root of
/// dashboard-style sections (tiles, charts, grids). Table-centric sections should instead
/// put a ``PagedTable`` edge-to-edge.
public struct ScrollPage<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.blockSpacing) { content }
                .padding(Metrics.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .uiTestProbe("scrollpage")
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Title + optional subtitle + trailing accessory, heading a block of content.
public struct SectionHeader<Accessory: View>: View {
    private let title: String
    private let subtitle: String?
    private let symbol: String?
    private let accessory: Accessory

    public init(_ title: String, subtitle: String? = nil, symbol: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.accessory = accessory()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(.secondary).font(.headline)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            // The accessory (a picker, a badge, a button) is sized first; the title and
            // subtitle wrap in what is left instead of the accessory being squeezed.
            accessory.layoutPriority(1)
        }
    }
}

public extension SectionHeader where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, symbol: String? = nil) {
        self.init(title, subtitle: subtitle, symbol: symbol) { EmptyView() }
    }
}

/// Compact filter field for the top of a master list pane (the same look as the filter
/// field built into ``PagedTable``). Filtering itself is up to the caller.
///
/// ```swift
/// VStack(spacing: 0) { FilterField("Filter people", text: $filter); Divider(); List(...) }
/// ```
public struct FilterField: View {
    private let prompt: String
    @Binding private var text: String

    public init(_ prompt: String = "Filter", text: Binding<String>) { self.prompt = prompt; self._text = text }

    public var body: some View {
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

// MARK: - Stat tiles

/// Model for one headline number.
public struct Stat: Identifiable, Sendable {
    public var id: String { title }
    public var title: String
    public var value: String
    public var caption: String?
    public var symbol: String?
    public var tint: Color
    public var sensitivity: Sensitivity

    public init(_ title: String, _ value: String, caption: String? = nil, symbol: String? = nil, tint: Color = .accentColor, sensitivity: Sensitivity = .low) {
        self.title = title; self.value = value; self.caption = caption
        self.symbol = symbol; self.tint = tint; self.sensitivity = sensitivity
    }
}

/// A single headline-number tile.
public struct StatTile: View {
    private let stat: Stat
    private var fillsHeight = false
    public init(_ stat: Stat) { self.stat = stat }

    /// Stretches the card to the height it is offered (rows of equally tall tiles).
    func fillingHeight() -> StatTile {
        var copy = self
        copy.fillsHeight = true
        return copy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let symbol = stat.symbol {
                    Image(systemName: symbol).foregroundStyle(stat.tint).imageScale(.small)
                }
                Text(stat.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(stat.value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .sensitive(stat.sensitivity)
            if let caption = stat.caption {
                // A caption next to a private value usually qualifies it ("with <name>"),
                // so it is hidden together with the value.
                Text(caption).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    .sensitive(stat.sensitivity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .card()
    }
}

/// A grid that spreads its items **evenly** over as few rows as possible instead of
/// filling rows greedily: six items that fit five per row become 3 + 3 (not 5 + 1), nine
/// that fit five per row become 3 × 3 … so no row ends with one or two orphans.
///
/// With `maxPerRow = ⌊(width + spacing) / (minItemWidth + spacing)⌋`, it uses
/// `rows = ⌈n / maxPerRow⌉` and `columns = ⌈n / rows⌉`. Columns are equally wide (at most
/// `maxItemWidth`, leading-aligned) and every item in a row is offered the row's height,
/// so cards that accept it (`.frame(maxHeight: .infinity)`) line up.
///
/// ```swift
/// BalancedGrid(minItemWidth: 250, spacing: 12) {
///     ForEach(cards) { CardView($0) }
/// }
/// ```
public struct BalancedGrid: Layout {
    public var minItemWidth: CGFloat
    public var maxItemWidth: CGFloat
    public var spacing: CGFloat
    public var rowSpacing: CGFloat
    /// When set (and smaller than `minItemWidth`): all items stay on **one row** as long as
    /// each still gets this width — four tiles in 655 pt stay 4 x 1 instead of becoming
    /// 2 x 2. Below that the grid balances with `minItemWidth` as usual.
    public var singleRowMinItemWidth: CGFloat?

    public init(minItemWidth: CGFloat, maxItemWidth: CGFloat = .infinity, spacing: CGFloat = 12, rowSpacing: CGFloat? = nil,
                singleRowMinItemWidth: CGFloat? = nil) {
        self.minItemWidth = max(1, minItemWidth)
        self.maxItemWidth = max(self.minItemWidth, maxItemWidth)
        self.spacing = spacing
        self.rowSpacing = rowSpacing ?? spacing
        self.singleRowMinItemWidth = singleRowMinItemWidth
    }

    /// Number of columns for `count` items in `width` (public so callers can mirror it).
    public static func columns(count: Int, width: CGFloat, minItemWidth: CGFloat, spacing: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        guard width.isFinite else { return count }
        let maxPerRow = max(1, Int(((width + spacing) / (minItemWidth + spacing)).rounded(.down)))
        let rows = Int((Double(count) / Double(maxPerRow)).rounded(.up))
        return Int((Double(count) / Double(rows)).rounded(.up))
    }

    private struct Arrangement {
        var columns = 1
        var itemWidth: CGFloat = 0
        var rowHeights: [CGFloat] = []
        var size: CGSize = .zero
    }

    private func arrange(_ subviews: Subviews, width proposed: CGFloat?) -> Arrangement {
        let n = subviews.count
        guard n > 0 else { return Arrangement() }
        let width: CGFloat
        // A zero proposal is SwiftUI's minimum-size query: answer with one column, never the
        // one-row width, or the enclosing window/split view is forced wider than the screen.
        // Without a definite width (ideal-size query): at most four minimum-width columns.
        if let proposed, proposed.isFinite { width = max(proposed, minItemWidth) }
        else {
            let ideal = min(n, 4)
            width = CGFloat(ideal) * minItemWidth + CGFloat(ideal - 1) * spacing
        }
        var columns = BalancedGrid.columns(count: n, width: width, minItemWidth: minItemWidth, spacing: spacing)
        if let single = singleRowMinItemWidth, single > 0, columns < n,
           CGFloat(n) * single + CGFloat(n - 1) * spacing <= width {
            columns = n
        }
        let itemWidth = min(maxItemWidth, max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)))
        var heights: [CGFloat] = []
        var index = 0
        while index < n {
            let end = min(n, index + columns)
            let h = subviews[index..<end].map { $0.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height }.max() ?? 0
            heights.append(h)
            index = end
        }
        let used = itemWidth * CGFloat(columns) + spacing * CGFloat(columns - 1)
        let height = heights.reduce(0, +) + rowSpacing * CGFloat(max(0, heights.count - 1))
        // Fill the offered width when the items stretch; hug them when they are capped.
        let reportedWidth = maxItemWidth.isFinite ? used : width
        return Arrangement(columns: columns, itemWidth: itemWidth, rowHeights: heights, size: CGSize(width: reportedWidth, height: height))
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let a = arrange(subviews, width: bounds.width)
        var y = bounds.minY
        for (row, height) in a.rowHeights.enumerated() {
            for column in 0..<a.columns {
                let index = row * a.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (a.itemWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: a.itemWidth, height: height))
            }
            y += height + rowSpacing
        }
    }
}

/// Row of ``StatTile``s: equally wide tiles filling the available width on one line when
/// they fit; otherwise they are spread evenly over as few rows as possible (six tiles
/// that do not fit become 3 + 3, never 5 + 1). Tiles in a row are equally tall.
///
/// `style: .strip` is the compact form for low windows: one line of "title / value" pairs
/// (about 34 pt high instead of about 80 per row of tiles), wrapping when it has to. See
/// ``SectionIntro`` for the usual "paragraph + tiles above a table" block that switches by
/// itself.
public struct StatTileRow: View {
    public enum Style: Sendable { case tiles, strip }

    private let stats: [Stat]
    private let minWidth: CGFloat
    private let fills: Bool
    private let singleRowMin: CGFloat?
    private let style: Style

    /// - Parameters:
    ///   - fillsWidth: stretch the tiles across the full width (default). Pass false to
    ///     pack them to the leading edge at most 320 pt wide.
    ///   - singleRowMinTileWidth: keep all tiles on one row while each still gets this
    ///     width (smaller than `minTileWidth`), before balancing them over several rows.
    public init(_ stats: [Stat], minTileWidth: CGFloat = 150, fillsWidth: Bool = true,
                singleRowMinTileWidth: CGFloat? = nil, style: Style = .tiles) {
        self.stats = stats; self.minWidth = minTileWidth; self.fills = fillsWidth
        self.singleRowMin = singleRowMinTileWidth; self.style = style
    }

    public var body: some View {
        switch style {
        case .tiles:
            BalancedGrid(minItemWidth: minWidth, maxItemWidth: fills ? .infinity : 320, spacing: 12, singleRowMinItemWidth: singleRowMin) {
                ForEach(stats) { StatTile($0).fillingHeight() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .strip:
            FlowLayout(spacing: 18, lineSpacing: 6) {
                ForEach(stats) { stat in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(stat.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Text(stat.value)
                            .font(.system(.callout, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .sensitive(stat.sensitivity)
                    }
                    .help(stat.caption.map { "\(stat.title): \($0)" } ?? stat.title)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Intro of a section that continues with a table: an explanatory paragraph and headline
/// numbers. With `compact` (a low window) the paragraph moves behind an info button and
/// the numbers become a one-line strip, so the table below keeps most of the height.
///
/// ```swift
/// @State private var compact = false
/// VStack(spacing: 0) {
///     SectionIntro(text: "What this store is.", stats: stats, compact: compact)
///     Divider()
///     PagedTable(…)
/// }
/// .compactWhenLow($compact)               // on the view that fills the section
/// ```
public struct SectionIntro<Extra: View>: View {
    private let text: String
    private let stats: [Stat]
    private let compact: Bool
    private let extra: Extra
    @State private var showsText = false

    /// - Parameter extra: further controls shown below the numbers in both forms.
    public init(text: String, stats: [Stat], compact: Bool, @ViewBuilder extra: () -> Extra) {
        self.text = text; self.stats = stats; self.compact = compact; self.extra = extra()
    }

    public var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 8) {
                    StatTileRow(stats, style: .strip)
                    Button { showsText.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("About this store")
                        .popover(isPresented: $showsText, arrowEdge: .bottom) {
                            Text(text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 340, alignment: .leading)
                                .padding(14)
                        }
                }
                extra
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                StatTileRow(stats)
                extra
            }
            .padding(Metrics.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

public extension SectionIntro where Extra == EmptyView {
    init(text: String, stats: [Stat], compact: Bool) {
        self.init(text: text, stats: stats, compact: compact) { EmptyView() }
    }
}

public extension View {
    /// Sets `compact` while the view is lower than `threshold` (default 740 pt: the detail
    /// column of the minimum window is 560–600 pt high). Attach it to a view that fills the
    /// height it is offered, so the result does not depend on `compact` itself.
    func compactWhenLow(_ compact: Binding<Bool>, below threshold: CGFloat = 740) -> some View {
        onGeometryChange(for: Bool.self) { $0.size.height < threshold } action: { compact.wrappedValue = $0 }
    }
}

// MARK: - Key/value grid

/// One row of a ``KeyValueGrid``.
public struct KeyValueItem: Identifiable, Sendable {
    public let id: String
    public var label: String
    public var value: String
    public var sensitivity: Sensitivity
    public var monospaced: Bool

    public init(_ label: String, _ value: String?, sensitivity: Sensitivity = .low, monospaced: Bool = false, id: String? = nil) {
        self.id = id ?? label
        self.label = label; self.value = value ?? "—"; self.sensitivity = sensitivity; self.monospaced = monospaced
    }
}

/// Two-column label/value grid with selectable values (inspector details, metadata).
public struct KeyValueGrid: View {
    private let items: [KeyValueItem]
    private let labelWidth: CGFloat?
    private let lineLimit: Int?

    public init(_ items: [KeyValueItem], labelWidth: CGFloat? = nil, valueLineLimit: Int? = 6) {
        self.items = items; self.labelWidth = labelWidth; self.lineLimit = valueLineLimit
    }

    public var body: some View {
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
                        .lineLimit(lineLimit)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .sensitive(item.sensitivity)
                }
            }
        }
    }
}

// MARK: - Store footer

/// Footer bar naming the backing store with "Reveal in Finder" / "Copy Path" actions.
/// Put it at the bottom of every section so users always know where data comes from.
public struct StoreFooter: View {
    private let url: URL
    private let note: String?

    public init(_ url: URL, note: String? = nil) { self.url = url; self.note = note }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive").foregroundStyle(.tertiary).imageScale(.small)
            Text(Format.tildePath(url))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .sensitive(.personal)
                .help(Format.tildePath(url))
            if let note {
                // The note goes first when the footer is narrow, then the path truncates.
                Text(note).font(.caption).foregroundStyle(.tertiary).lineLimit(1).layoutPriority(-1)
            }
            Spacer(minLength: 8)
            // The two actions never wrap or truncate.
            Button("Copy Path") { Pasteboard.copy(url.path) }
                .buttonStyle(.link).font(.caption).lineLimit(1).fixedSize()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.link).font(.caption).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.barHeight - 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Inspector

public extension View {
    /// The standard trailing detail inspector: a resizable side panel used to show the
    /// selected row's details. Present it when a selection exists.
    ///
    /// ```swift
    /// PagedTable(...).detailInspector(isPresented: $showInspector) {
    ///     InspectorPage(title: row.title) { KeyValueGrid(row.items) }
    /// }
    /// ```
    ///
    /// - Parameter minimumContentWidth: the width the content (usually a table) should keep
    ///   beside the inspector. The inspector gives up width, down to 260 pt, before the
    ///   content goes below it. Narrower still, the content is squeezed to its own minimum
    ///   and finally the inspector overlays its trailing edge. This never raises the
    ///   section's minimum width.
    func detailInspector<I: View>(isPresented: Binding<Bool>, minimumContentWidth: CGFloat = 400, @ViewBuilder content: @escaping () -> I) -> some View {
        modifier(DetailInspectorModifier(isPresented: isPresented, minimumContentWidth: minimumContentWidth, inspector: content))
    }
}

private struct DetailInspectorModifier<I: View>: ViewModifier {
    @Binding var isPresented: Bool
    var minimumContentWidth: CGFloat = 400
    let inspector: () -> I
    @State private var width: CGFloat = Metrics.inspectorWidth

    func body(content: Content) -> some View {
        InspectorSplitLayout(preferredWidth: width, preferredContentWidth: minimumContentWidth) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if isPresented {
                ResizeHandle(width: $width, range: InspectorSplitLayout.widthRange)
                inspector()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transition(.move(edge: .trailing))
                    .onAppear { if UITestProbe.isActive { UITestProbe.inspectorChanged(1) } }
                    .onDisappear { if UITestProbe.isActive { UITestProbe.inspectorChanged(-1) } }
            }
        }
    }
}

/// Content + divider + trailing inspector. With room to spare the inspector has its
/// preferred width. As the width shrinks:
///
/// 1. the inspector gives up width, down to `widthRange.lowerBound`, while the content
///    keeps `preferredContentWidth` (a table beside a 340-pt inspector is not squeezed to
///    its bare minimum while the inspector stays wide);
/// 2. then the content shrinks to its own minimum beside the narrowest inspector;
/// 3. then the inspector **overlays** the trailing part of the content, so opening an
///    inspector never raises the section's minimum width — which, in the minimum window,
///    would push the whole split view out of the window.
///
/// Zero-width proposal (minimum-size query): the larger of the content's minimum and the
/// narrowest inspector — never the sum.
struct InspectorSplitLayout: Layout {
    static let widthRange: ClosedRange<CGFloat> = 260...720
    var preferredWidth: CGFloat
    var preferredContentWidth: CGFloat = 400

    struct Frames: Equatable {
        var content: CGFloat
        var handle: CGFloat
        var inspector: CGFloat
        var overlays = false
    }

    /// Pure width arithmetic (unit-testable): `contentMin` is the content's zero-proposal width.
    static func frames(width: CGFloat, contentMin: CGFloat, handle: CGFloat, preferredWidth: CGFloat, preferredContentWidth: CGFloat) -> Frames {
        let floor = widthRange.lowerBound
        let wanted = min(max(preferredWidth, floor), widthRange.upperBound)
        // 1. Content keeps its preferred width; the inspector takes the rest, up to `wanted`.
        let comfortable = width - max(contentMin, preferredContentWidth) - handle
        if comfortable >= floor {
            let inspector = min(wanted, comfortable)
            return Frames(content: width - inspector - handle, handle: handle, inspector: inspector)
        }
        // 2. Narrowest inspector beside whatever is left, down to the content's minimum.
        if width - contentMin - handle >= floor {
            return Frames(content: width - floor - handle, handle: handle, inspector: floor)
        }
        // 3. Not enough room beside the content: overlay its trailing edge.
        return Frames(content: width, handle: handle, inspector: min(floor, max(0, width - handle)), overlays: true)
    }

    private func frames(_ subviews: Subviews, width: CGFloat, height: CGFloat?) -> Frames {
        guard subviews.count >= 3 else { return Frames(content: width, handle: 0, inspector: 0) }
        let handle = subviews[1].sizeThatFits(ProposedViewSize(width: nil, height: height)).width
        let contentMin = subviews[0].sizeThatFits(ProposedViewSize(width: 0, height: height)).width
        return InspectorSplitLayout.frames(width: width, contentMin: contentMin, handle: handle,
                                           preferredWidth: preferredWidth, preferredContentWidth: preferredContentWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let floor = subviews.count >= 3 ? InspectorSplitLayout.widthRange.lowerBound + 1 : 0
        let size = content.sizeThatFits(proposal)
        guard let proposed = proposal.width, proposed.isFinite else {
            // Ideal: content plus the inspector at its preferred width.
            return CGSize(width: size.width + (subviews.count >= 3 ? preferredWidth + 1 : 0), height: size.height)
        }
        let contentMin = content.sizeThatFits(ProposedViewSize(width: 0, height: proposal.height)).width
        return CGSize(width: max(proposed, contentMin, floor), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let f = frames(subviews, width: bounds.width, height: bounds.height)
        content.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: f.content, height: bounds.height))
        guard subviews.count >= 3 else { return }
        let x = bounds.maxX - f.inspector
        subviews[1].place(at: CGPoint(x: x - f.handle, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: f.handle, height: bounds.height))
        subviews[2].place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: f.inspector, height: bounds.height))
    }
}

/// Hosts a section in a shell's detail column. It passes the section's minimum size on
/// only up to `cap` — what the shell's minimum window can offer beside the narrowest
/// sidebar. Up to that the split view makes room as usual (it narrows the sidebar);
/// beyond it the section is clipped at its trailing / bottom edge instead of pushing the
/// sidebar and toolbar out of the window. A hidden kept-alive section is bounded in the
/// same way, so it cannot wreck the section that is visible.
///
/// Zero proposal (minimum-size query): `min(section minimum, cap)` per axis.
struct ContainedSectionLayout: Layout {
    var cap: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var needed = CGSize.zero
        for subview in subviews {
            let s = subview.sizeThatFits(proposal)
            needed.width = max(needed.width, s.width)
            needed.height = max(needed.height, s.height)
        }
        func resolve(_ proposed: CGFloat?, _ needed: CGFloat, _ cap: CGFloat) -> CGFloat {
            // Unspecified (ideal) or unbounded query: the section's own answer.
            guard let proposed, proposed.isFinite else { return needed }
            return max(proposed, min(needed, cap))               // fill; grow only up to the cap
        }
        return CGSize(width: resolve(proposal.width, needed.width, cap.width),
                      height: resolve(proposal.height, needed.height, cap.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

public extension View {
    /// Shell use: hosts a section so that its minimum size can never break the window
    /// (see ``ContainedSectionLayout``). `--uitest` still reports such a section
    /// (`section-min`, `section-fits`).
    ///
    /// - Parameters:
    ///   - minimumWindow: the scene's `.frame(minWidth:minHeight:)`.
    ///   - narrowestSidebar: the sidebar's minimum column width.
    func containedSection(minimumWindow: CGSize, narrowestSidebar: CGFloat) -> some View {
        ContainedSectionLayout(cap: CGSize(width: max(0, minimumWindow.width - narrowestSidebar - 1), height: minimumWindow.height)) { self }
            .clipped()
    }
}

/// Draggable 1-pt divider that resizes the panel on its trailing side.
struct ResizeHandle: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    @State private var startWidth: CGFloat?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = startWidth ?? width
                                if startWidth == nil { startWidth = width }
                                width = min(max(base - value.translation.width, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}

/// Standard inspector content scaffold: title bar with close button, scrolling body.
public struct InspectorPage<Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let onClose: (() -> Void)?
    private let scrolls: Bool
    private let sensitivity: Sensitivity
    private let content: Content

    /// - Parameters:
    ///   - sensitivity: redaction level of the title / subtitle in Privacy Mode.
    ///   - scrolls: set to false if the content manages its own scrolling (e.g. a
    ///     ``BlobInspector`` or ``DataTreeView`` filling the panel).
    public init(title: String, subtitle: String? = nil, sensitivity: Sensitivity = .low, scrolls: Bool = true, onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.scrolls = scrolls; self.onClose = onClose
        self.sensitivity = sensitivity
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .sensitive(sensitivity)
                Spacer(minLength: 4)
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Close Inspector")
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if scrolls {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) { content }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .uiTestProbe("inspector")
                }
            } else {
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// Small uppercase caption used to title groups inside an inspector.
public struct InspectorGroupTitle: View {
    private let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.4)
    }
}

// MARK: - Pasteboard / export helpers

public enum Pasteboard {
    /// Replaces the general pasteboard's contents with `string`.
    public static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

public enum CSV {
    /// RFC-4180 escaping of one field.
    public static func escape(_ field: String) -> String {
        if field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    public static func document(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// Shows a save panel and writes the CSV (user-initiated export only).
    @MainActor
    public static func export(header: [String], rows: [[String]], suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName.hasSuffix(".csv") ? suggestedName : suggestedName + ".csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? document(header: header, rows: rows).data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
