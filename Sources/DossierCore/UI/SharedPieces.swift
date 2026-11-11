import SwiftUI
import Charts

// MARK: - Flow layout

/// Wrapping horizontal layout for chips, badges and keyword clouds (left-aligned rows,
/// hugging its content's width).
///
/// Sizing: a zero-width proposal (minimum-size query) is answered with the widest item's
/// own minimum — one item per row — never with the one-row width. Without a width
/// (ideal-size query) rows wrap at `idealWidth`, so a cloud of 200 chips does not report
/// an ideal width of several thousand points. An item wider than a row is offered the row
/// width, so text that can truncate does.
public struct FlowLayout: Layout {
    public var spacing: CGFloat
    public var lineSpacing: CGFloat
    /// Width rows wrap at when the layout is asked for its ideal size.
    public var idealWidth: CGFloat

    /// - Parameter lineSpacing: vertical gap between rows; defaults to `spacing`.
    public init(spacing: CGFloat = 6, lineSpacing: CGFloat? = nil, idealWidth: CGFloat = 640) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing ?? spacing
        self.idealWidth = idealWidth
    }

    private func itemSize(_ sub: LayoutSubview, row: CGFloat) -> CGSize {
        let ideal = sub.sizeThatFits(.unspecified)
        guard row.isFinite, ideal.width > row else { return ideal }
        return sub.sizeThatFits(ProposedViewSize(width: row, height: nil))
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Narrowest width at which every item can still be laid out.
        let narrowest = subviews.map { $0.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width }.max() ?? 0
        let width = max(proposal.width ?? idealWidth, narrowest)
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let size = itemSize(sub, row: width)
            if x > 0, x + size.width > width { x = 0; y += lineHeight + lineSpacing; lineHeight = 0 }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width.isFinite ? min(width, maxX) : maxX, height: y + lineHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = itemSize(sub, row: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += lineHeight + lineSpacing; lineHeight = 0 }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Strips

/// The 46-pt control strip at the top of a section: pickers, segmented modes, a one-line
/// explanation. Bar material with a hairline below — the same look in every module.
///
/// ```swift
/// VStack(spacing: 0) {
///     HeaderStrip { Picker(…); Spacer(); Toggle(…) }
///     PagedTable(…)
/// }
/// ```
///
/// The strip is a plain one-line `HStack`: its minimum width is the sum of its controls'
/// minimums, and it must fit the detail column of the minimum window (about 700 pt; less
/// beside a master list). Controls that cannot shrink (segmented pickers, `.fixedSize()`)
/// are the usual reason a section fails `section-min`. Helpers:
///
/// * ``AdaptiveSegmentedPicker`` — segmented while it fits, a pop-up button otherwise.
/// * ``FittingStrip`` — controls plus a caption that is dropped when it does not fit.
/// * For more tiers nest `ViewThatFits(in: .horizontal)` **in pairs** (see ARCHITECTURE §3a).
public struct HeaderStrip<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: spacing) { content }
            .padding(.horizontal, 14)
            .frame(height: Metrics.headerStripHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
    }
}

/// Caption strip at the bottom of a list pane ("42 tables · 3 views").
public struct PaneFooter: View {
    private let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: Metrics.barHeight - 4)
            .background(.bar)
    }
}

/// Header-strip content: controls at the leading edge and a caption that is **dropped** —
/// never truncated to a stub — when the strip is too narrow for both.
///
/// ```swift
/// HeaderStrip {
///     FittingStrip { Picker(…); Toggle(…) } caption: { Text("Last 28 days · 1,204 events") }
/// }
/// ```
public struct FittingStrip<Controls: View, Caption: View>: View {
    private let spacing: CGFloat
    private let captionTrailing: Bool
    private let controls: Controls
    private let caption: Caption

    /// - Parameter captionTrailing: true (default) puts the caption at the trailing edge;
    ///   false lets it follow the controls directly.
    public init(spacing: CGFloat = 12, captionTrailing: Bool = true, @ViewBuilder controls: () -> Controls, @ViewBuilder caption: () -> Caption) {
        self.spacing = spacing; self.captionTrailing = captionTrailing
        self.controls = controls(); self.caption = caption()
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) {
                controls
                if captionTrailing { Spacer(minLength: 0) }
                caption.lineLimit(1).fixedSize()
                if !captionTrailing { Spacer(minLength: 0) }
            }
            HStack(spacing: spacing) {
                controls
                Spacer(minLength: 0)
            }
        }
    }
}

/// Offers its content `reserve` points less width than it was offered, but reports the
/// content's own size. Around a `ViewThatFits` in a shared strip it makes the wide variant
/// win only while `reserve` points remain for the strip's other controls. A zero-width
/// proposal is passed on as zero, so the minimum is the content's true minimum.
public struct ReservingWidthLayout: Layout {
    public var reserve: CGFloat
    public init(reserve: CGFloat) { self.reserve = reserve }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let sub = subviews.first else { return .zero }
        return sub.sizeThatFits(ProposedViewSize(width: proposal.width.map { max(0, $0 - reserve) }, height: proposal.height))
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// A picker that is a segmented control while there is room for it and collapses to a
/// pop-up button otherwise. Its minimum width is the pop-up button's, so a strip of mode
/// pickers never forces a section wider than the window.
///
/// ```swift
/// AdaptiveSegmentedPicker("Show", selection: $scope, reserve: 150) {
///     ForEach(Scope.allCases) { Text($0.title).tag($0) }
/// }
/// ```
public struct AdaptiveSegmentedPicker<Selection: Hashable, Options: View>: View {
    private let title: String
    @Binding private var selection: Selection
    private let reserve: CGFloat
    private let options: () -> Options

    /// - Parameter reserve: width to leave for the picker's neighbours (a filter field)
    ///   before the segmented form is chosen.
    public init(_ title: String, selection: Binding<Selection>, reserve: CGFloat = 0, @ViewBuilder options: @escaping () -> Options) {
        self.title = title; self._selection = selection; self.reserve = reserve; self.options = options
    }

    public var body: some View {
        ReservingWidthLayout(reserve: reserve) {
            ViewThatFits(in: .horizontal) {
                Picker(title, selection: $selection, content: options)
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                Picker(title, selection: $selection, content: options)
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
            }
        }
    }
}

/// Master list + detail pane that adapts to the width it is given.
///
/// * Below `compactBelow` the master list uses `compactMasterWidth`.
/// * While the detail pane shows an inspector (`inspectorOpen`) and there is no room for
///   list, detail and inspector side by side, the master list is tucked away (kept alive,
///   so its scroll position and selection survive) and comes back when the inspector
///   closes. Without this a ``detailInspector`` covers most of the table in the minimum
///   window.
///
/// ```swift
/// AdaptiveMasterDetail(masterWidth: 280, compactMasterWidth: 230, inspectorOpen: selected != nil) {
///     List(…)
/// } detail: {
///     PagedTable(…).detailInspector(isPresented: $showInspector) { … }
/// }
/// ```
public struct AdaptiveMasterDetail<Master: View, Detail: View>: View {
    private let masterWidth: CGFloat
    private let compactMasterWidth: CGFloat
    private let compactBelow: CGFloat
    private let minDetailWithInspector: CGFloat
    private let inspectorOpen: Bool
    private let master: Master
    private let detail: Detail

    @State private var width: CGFloat = 0

    /// - Parameters:
    ///   - minDetailWithInspector: narrowest useful detail pane (table) beside an open,
    ///     260-pt inspector; below it the master list is hidden.
    public init(masterWidth: CGFloat, compactMasterWidth: CGFloat? = nil, compactBelow: CGFloat = 800,
                minDetailWithInspector: CGFloat = 360, inspectorOpen: Bool,
                @ViewBuilder master: () -> Master, @ViewBuilder detail: () -> Detail) {
        self.masterWidth = masterWidth
        self.compactMasterWidth = compactMasterWidth ?? masterWidth
        self.compactBelow = compactBelow
        self.minDetailWithInspector = minDetailWithInspector
        self.inspectorOpen = inspectorOpen
        self.master = master(); self.detail = detail()
    }

    public var body: some View {
        let listWidth = width > 0 && width < compactBelow ? compactMasterWidth : masterWidth
        let needed = listWidth + 1 + minDetailWithInspector + 1 + InspectorSplitLayout.widthRange.lowerBound
        let hidden = inspectorOpen && width > 0 && width < needed
        HStack(spacing: 0) {
            master
                .frame(width: listWidth)
                .frame(width: hidden ? 0 : listWidth, alignment: .leading)
                .clipped()
                .allowsHitTesting(!hidden)
                .accessibilityHidden(hidden)
            if !hidden { Divider() }
            detail
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
