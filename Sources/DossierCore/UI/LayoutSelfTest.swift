import SwiftUI
import AppKit

/// Self-test of the shared layouts' sizing contract (`--selftest`, "core" block): a
/// zero-width proposal — SwiftUI's minimum-size query, which travels up to the window —
/// must be answered with the true minimum, an unspecified one with a modest ideal.
/// Uses fixed-size dummy views only; nothing is shown and no store is read.
@MainActor
public enum LayoutSelfTest {
    private final class Box { var sizes: [String: CGSize] = [:] }

    /// Pass-through layout that asks its content the questions a window asks.
    private struct Probe: Layout {
        let box: Box
        let widths: [CGFloat]

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let s = subviews.first else { return .zero }
            box.sizes["zero"] = s.sizeThatFits(ProposedViewSize(width: 0, height: nil))
            box.sizes["ideal"] = s.sizeThatFits(.unspecified)
            for w in widths { box.sizes["\(Int(w))"] = s.sizeThatFits(ProposedViewSize(width: w, height: nil)) }
            return s.sizeThatFits(proposal)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }

    private static func measure<V: View>(widths: [CGFloat] = [], @ViewBuilder _ content: () -> V) -> [String: CGSize] {
        let box = Box()
        let controller = NSHostingController(rootView: Probe(box: box, widths: widths) { content() })
        _ = controller.sizeThatFits(in: CGSize(width: 600, height: 600))
        return box.sizes
    }

    public static func run() -> [SelfTestLine] {
        var lines: [SelfTestLine] = []
        func check(_ label: String, _ ok: Bool, _ detail: String) { lines.append(.check(label, ok, detail)) }
        func near(_ a: CGFloat?, _ b: CGFloat) -> Bool { a.map { abs($0 - b) <= 1 } ?? false }
        func w(_ sizes: [String: CGSize], _ key: String) -> String { sizes[key].map { "\(Int($0.width))x\(Int($0.height))" } ?? "not measured" }

        // BalancedGrid: six 40-pt-high items, 100 pt minimum each.
        let grid = measure(widths: [330]) {
            BalancedGrid(minItemWidth: 100, spacing: 12) { ForEach(0..<6, id: \.self) { _ in Color.clear.frame(height: 40) } }
        }
        check("BalancedGrid minimum is one column", near(grid["zero"]?.width, 100), "zero-width proposal → \(w(grid, "zero")), expected 100 wide")
        check("BalancedGrid ideal is at most four columns", near(grid["ideal"]?.width, 4 * 100 + 3 * 12), "unspecified proposal → \(w(grid, "ideal")), expected 436 wide")
        check("BalancedGrid balances 6 items as 3 + 3", near(grid["330"]?.height, 2 * 40 + 12), "330 wide → \(w(grid, "330")), expected two rows (92 high)")
        check("BalancedGrid single-row option", BalancedGrid.columns(count: 4, width: 655, minItemWidth: 170, spacing: 12) == 2
              && near(measure(widths: [655]) {
                  BalancedGrid(minItemWidth: 170, spacing: 12, singleRowMinItemWidth: 150) { ForEach(0..<4, id: \.self) { _ in Color.clear.frame(height: 40) } }
              }["655"]?.height, 40), "4 items in 655 pt: 2 x 2 by default, one row with singleRowMinItemWidth 150")

        // FlowLayout: thirty 80x20 chips.
        let flow = measure(widths: [200]) {
            FlowLayout(spacing: 6) { ForEach(0..<30, id: \.self) { _ in Color.clear.frame(width: 80, height: 20) } }
        }
        check("FlowLayout minimum is its widest item", near(flow["zero"]?.width, 80), "zero-width proposal → \(w(flow, "zero")), expected 80 wide")
        check("FlowLayout ideal wraps", (flow["ideal"]?.width ?? .infinity) <= 640, "unspecified proposal → \(w(flow, "ideal")), expected at most 640 wide (one row would be 2574)")
        check("FlowLayout wraps at the offered width", (flow["200"]?.width ?? .infinity) <= 200 && (flow["200"]?.height ?? 0) > 20, "200 wide → \(w(flow, "200"))")

        // Filter bar: a flexible field and a rigid 300-pt accessory.
        let bar = measure(widths: [500, 400]) {
            FilterBarLayout(spacing: 8, fieldMinimum: 140, fieldIdeal: 220, fieldMaximum: 280) {
                Color.clear.frame(height: 22).layoutValue(key: FilterBarLayout.IsField.self, value: true)
                Color.clear.frame(width: 300, height: 22)
            }
        }
        check("Filter bar minimum is the wider part, not the sum", near(bar["zero"]?.width, 300), "zero-width proposal → \(w(bar, "zero")), expected 300 wide")
        check("Filter bar ideal is one line", near(bar["ideal"]?.width, 220 + 8 + 300) && near(bar["ideal"]?.height, 22), "unspecified proposal → \(w(bar, "ideal")), expected 528x22")
        check("Filter bar: one line while the field keeps 140 pt", near(bar["500"]?.height, 22), "500 wide → \(w(bar, "500")), expected 22 high")
        check("Filter bar: accessory moves to a second row", (bar["400"]?.height ?? 0) > 40 && near(bar["400"]?.width, 400), "400 wide → \(w(bar, "400")), expected two rows")

        // Inspector split arithmetic.
        func split(_ width: CGFloat, contentMin: CGFloat = 320) -> InspectorSplitLayout.Frames {
            InspectorSplitLayout.frames(width: width, contentMin: contentMin, handle: 1, preferredWidth: 340, preferredContentWidth: 400)
        }
        let wide = split(1000), tight = split(700), narrow = split(600), tiny = split(500)
        check("Inspector: preferred width when there is room", wide.inspector == 340 && wide.content == 659 && !wide.overlays, "1000 wide → content \(Int(wide.content)), inspector \(Int(wide.inspector))")
        check("Inspector gives up width before the content goes below 400", tight.inspector == 299 && tight.content == 400 && !tight.overlays, "700 wide → content \(Int(tight.content)), inspector \(Int(tight.inspector))")
        check("Inspector at 260 beside content above its minimum", narrow.inspector == 260 && narrow.content == 339 && !narrow.overlays, "600 wide → content \(Int(narrow.content)), inspector \(Int(narrow.inspector))")
        check("Inspector overlays when the content minimum does not fit", tiny.overlays && tiny.inspector == 260 && tiny.content == 500, "500 wide → content \(Int(tiny.content)), inspector \(Int(tiny.inspector)) overlaid")

        // Default column minimums.
        let mins = [60, 110, 140, 200, 400].map { PagedColumn<Int>.defaultMinimum(ideal: CGFloat($0)) }
        check("PagedColumn default minimum", mins == [60, 110, 110, 120, 160], "ideal 60 / 110 / 140 / 200 / 400 → \(mins.map { String(Int($0)) }.joined(separator: " / "))")
        return lines
    }
}
