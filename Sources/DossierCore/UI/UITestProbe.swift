import SwiftUI

/// Layout probes for `--uitest` (see ``UITestRunner``).
///
/// Two kinds:
///
/// * **Section probe** (`uiTestSection`) — a transparent pass-through ``Layout`` around a
///   hosted section. It records what SwiftUI *proposed* to the section, the size the section
///   *took*, and the section's minimum (zero proposal) and ideal (unspecified proposal)
///   sizes. A section that takes more than it was proposed is clipped on screen.
/// * **Scroll-content probe** (`uiTestProbe`) — committed geometry of the content of a
///   vertical `ScrollView` against the scroll view's viewport.
///
/// SwiftUI also calls `placeSubviews` for *measurement* passes (a parent asking for a
/// minimum size makes children lay out at that size without anything reaching the screen).
/// The section probe therefore keeps one record per distinct placed size and the runner
/// picks the record whose size equals the **committed** geometry (`onGeometryChange`),
/// which only ever reflects what is displayed.
///
/// Outside `--uitest` (`UITestProbe.isActive == false`) the modifiers return the view
/// unchanged: no wrapper, no cost.
public enum UITestProbe {
    /// One probe measurement.
    public struct Measurement: Sendable {
        public var scope: String
        public var kind: String
        /// The proposal the placed size was derived from (nil = unspecified dimension).
        /// For scroll-content probes: the viewport width.
        public var proposedWidth: CGFloat?
        public var proposedHeight: CGFloat?
        public var placed: CGSize
        /// The smallest size the view accepts: width for a zero-width proposal at the placed
        /// height, height for a zero-height proposal at the placed width. (A joint 0x0
        /// proposal makes wrapping text answer with a one-word-wide, very tall column.)
        public var minimum: CGSize
        /// `sizeThatFits(.unspecified)` — the size the view would like.
        public var ideal: CGSize
        public var time = Date()

        /// Points by which the view exceeds the proposed width (0 when it fits).
        public var horizontalOverflow: CGFloat {
            guard let w = proposedWidth, w.isFinite, w > 0 else { return 0 }
            return max(0, placed.width - w)
        }

        public var verticalOverflow: CGFloat {
            guard let h = proposedHeight, h.isFinite, h > 0 else { return 0 }
            return max(0, placed.height - h)
        }
    }

    /// True for the lifetime of a `--uitest` process. Set once, before any view is built.
    nonisolated(unsafe) public internal(set) static var isActive = false

    private static let lock = NSLock()
    /// Section / root layout records: scope → placed size → latest record with that size.
    nonisolated(unsafe) private static var placements: [String: [String: Measurement]] = [:]
    /// Committed (displayed) size of each section / root.
    nonisolated(unsafe) private static var committed: [String: CGSize] = [:]
    /// Scroll-content records by probe instance.
    nonisolated(unsafe) private static var scrollRecords: [String: Measurement] = [:]
    nonisolated(unsafe) private static var inspectors = 0

    private static func sizeKey(_ size: CGSize) -> String { "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))" }

    static func recordPlacement(_ m: Measurement) {
        lock.lock(); defer { lock.unlock() }
        var bySize = placements[m.scope] ?? [:]
        bySize[sizeKey(m.placed)] = m
        if bySize.count > 24, let oldest = bySize.min(by: { $0.value.time < $1.value.time }) {
            bySize[oldest.key] = nil
        }
        placements[m.scope] = bySize
    }

    static func commit(_ scope: String, _ size: CGSize) {
        lock.lock(); committed[scope] = size; lock.unlock()
    }

    static func forget(scope: String) {
        lock.lock(); placements[scope] = nil; committed[scope] = nil; lock.unlock()
    }

    static func recordScrollContent(_ key: String, _ m: Measurement) {
        lock.lock(); scrollRecords[key] = m; lock.unlock()
    }

    static func forgetScrollContent(_ key: String) {
        lock.lock(); scrollRecords[key] = nil; lock.unlock()
    }

    static func inspectorChanged(_ delta: Int) {
        lock.lock(); inspectors = max(0, inspectors + delta); lock.unlock()
    }

    /// Number of ``detailInspector`` panels currently on screen (hidden kept-alive sections included).
    public static var inspectorCount: Int {
        lock.lock(); defer { lock.unlock() }
        return inspectors
    }

    /// The displayed size of a section (or `"root"`), nil if it was never laid out.
    public static func committedSize(scope: String) -> CGSize? {
        lock.lock(); defer { lock.unlock() }
        return committed[scope]
    }

    /// The layout record of the placement that is on screen: the one whose size equals the
    /// committed size. Nil when no placement with that size was recorded.
    public static func displayedPlacement(scope: String) -> Measurement? {
        lock.lock(); defer { lock.unlock() }
        guard let size = committed[scope], let bySize = placements[scope] else { return nil }
        if let exact = bySize[sizeKey(size)] { return exact }
        return bySize.values
            .filter { abs($0.placed.width - size.width) <= 1 && abs($0.placed.height - size.height) <= 1 }
            .max { $0.time < $1.time }
    }

    /// Scopes of every hosted section (kept-alive hidden ones included).
    public static func sectionScopes() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return committed.keys.filter { $0 != "root" }.sorted()
    }

    /// Scroll-content measurements inside `scope`.
    public static func scrollContents(scope: String) -> [Measurement] {
        lock.lock(); defer { lock.unlock() }
        return scrollRecords.values.filter { $0.scope == scope }.sorted { $0.kind < $1.kind }
    }
}

private struct UITestScopeKey: EnvironmentKey { static let defaultValue = "" }

extension EnvironmentValues {
    /// The section (or `"root"`) the enclosing probes report under.
    var uiTestScope: String {
        get { self[UITestScopeKey.self] }
        set { self[UITestScopeKey.self] = newValue }
    }
}

/// Pass-through layout (sizes and places its content exactly like a `ZStack` with
/// top-leading alignment) that records every placement.
private struct UITestProbeLayout: Layout {
    let scope: String
    let kind: String

    private func fit(_ subviews: Subviews, _ proposal: ProposedViewSize) -> CGSize {
        var size = CGSize.zero
        for subview in subviews {
            let s = subview.sizeThatFits(proposal)
            size.width = max(size.width, s.width)
            size.height = max(size.height, s.height)
        }
        return size
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        fit(subviews, proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
        UITestProbe.recordPlacement(UITestProbe.Measurement(
            scope: scope, kind: kind,
            proposedWidth: proposal.width, proposedHeight: proposal.height,
            placed: bounds.size,
            minimum: CGSize(
                width: fit(subviews, ProposedViewSize(width: 0, height: bounds.height)).width,
                height: fit(subviews, ProposedViewSize(width: bounds.width, height: 0)).height),
            ideal: fit(subviews, .unspecified)))
    }
}

/// Section / root probe.
private struct UITestSectionModifier: ViewModifier {
    let kind: String
    let scope: String

    func body(content: Content) -> some View {
        let scope = scope
        UITestProbeLayout(scope: scope, kind: kind) { content }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { UITestProbe.commit(scope, $0) }
            .environment(\.uiTestScope, scope)
            .onDisappear { UITestProbe.forget(scope: scope) }
    }
}

/// Scroll-content probe: committed geometry only.
private struct UITestScrollContentModifier: ViewModifier {
    let kind: String
    @Environment(\.uiTestScope) private var scope
    @State private var token = UUID().uuidString

    private struct Geometry: Equatable {
        var content: CGSize
        var viewport: CGSize?
    }

    func body(content: Content) -> some View {
        let key = scope + "|" + kind + "|" + token
        let scope = scope
        let kind = kind
        content
            .onGeometryChange(for: Geometry.self) { proxy in
                Geometry(content: proxy.size, viewport: proxy.bounds(of: .scrollView)?.size)
            } action: { geometry in
                UITestProbe.recordScrollContent(key, UITestProbe.Measurement(
                    scope: scope, kind: kind,
                    proposedWidth: geometry.viewport?.width, proposedHeight: nil,
                    placed: geometry.content, minimum: .zero, ideal: .zero))
            }
            .onDisappear { UITestProbe.forgetScrollContent(key) }
    }
}

public extension View {
    /// Shell use: marks `self` as the hosted view of section `id` (or `"root"` for the
    /// window content). The app shell and the dev shell wrap every section they host, so
    /// `--uitest` can name the section whose minimum size exceeds the detail column.
    /// Apply it **before** ``containedSection()``.
    @ViewBuilder func uiTestSection(_ id: String) -> some View {
        if UITestProbe.isActive {
            modifier(UITestSectionModifier(kind: id == "root" ? "root" : "section", scope: id))
        } else {
            self
        }
    }

    /// Component use, on the content **inside a vertical `ScrollView`**: reports the
    /// content's width against the scroll view's viewport (content wider than the viewport
    /// is clipped). ``ScrollPage`` and ``InspectorPage`` do this already; add it to
    /// hand-rolled `ScrollView { … }` roots: `ScrollView { stack.uiTestProbe("scroll") }`.
    @ViewBuilder func uiTestProbe(_ kind: String) -> some View {
        if UITestProbe.isActive {
            modifier(UITestScrollContentModifier(kind: kind))
        } else {
            self
        }
    }
}
