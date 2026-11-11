import SwiftUI

/// Leading list panes + main content, used by the SQLite and Biome explorers.
///
/// Subviews, in order: `pane, separator` for every leading pane, then the content
/// (`2 * panes + 1` views). Separators are flexible 1-pt views (``PaneSeparator``).
///
/// The panes adapt to the width that is offered so the content keeps a usable width:
///
/// 1. enough room: every pane at its ideal width, the content gets the rest;
/// 2. less: the panes shrink towards their minimum widths while the content keeps
///    `comfortableContent`;
/// 3. still less, and `stackedColumn` is set: the panes are stacked in one column of that
///    width range (the first pane on top), which frees a whole pane width for the content;
/// 4. otherwise the panes stay at their minimum and the content takes what is left.
///
/// Zero-width proposal (minimum-size query): the narrowest arrangement — the stacked
/// column (or the panes' minimum widths) plus the content's own minimum. Never the ideal.
struct ExplorerPanesLayout: Layout {
    var ideal: [CGFloat]
    var minimum: [CGFloat]
    var comfortableContent: CGFloat = 520
    var stackedColumn: ClosedRange<CGFloat>? = nil
    /// Share of the height the first pane gets when stacked.
    var stackedFirstShare: CGFloat = 0.55

    private static let separator: CGFloat = 1

    private struct Arrangement {
        var stacked = false
        var panes: [CGFloat] = []
        var content: CGFloat = 0
    }

    private var paneCount: Int { min(ideal.count, minimum.count) }
    private var canStack: Bool { stackedColumn != nil && paneCount > 1 }

    /// Width of everything except the content in the narrowest arrangement.
    private var narrowestChrome: CGFloat {
        if canStack, let column = stackedColumn { return column.lowerBound + Self.separator }
        return minimum.prefix(paneCount).reduce(0, +) + CGFloat(paneCount) * Self.separator
    }

    private func arrange(width: CGFloat) -> Arrangement {
        let n = paneCount
        let separators = CGFloat(n) * Self.separator
        let idealSum = ideal.prefix(n).reduce(0, +)
        let minSum = minimum.prefix(n).reduce(0, +)
        if width - idealSum - separators >= comfortableContent {
            return Arrangement(panes: Array(ideal.prefix(n)), content: width - idealSum - separators)
        }
        if width - minSum - separators >= comfortableContent {
            let spare = width - separators - comfortableContent - minSum
            let t = idealSum > minSum ? spare / (idealSum - minSum) : 0
            let panes = (0..<n).map { (minimum[$0] + (ideal[$0] - minimum[$0]) * t).rounded(.down) }
            return Arrangement(panes: panes, content: width - panes.reduce(0, +) - separators)
        }
        if canStack, let column = stackedColumn {
            let w = min(max(width - Self.separator - comfortableContent, column.lowerBound), column.upperBound).rounded(.down)
            return Arrangement(stacked: true, panes: Array(repeating: w, count: n), content: max(0, width - w - Self.separator))
        }
        return Arrangement(panes: Array(minimum.prefix(n)), content: max(0, width - minSum - separators))
    }

    private func stackedHeights(_ height: CGFloat) -> [CGFloat] {
        let n = paneCount
        let usable = max(0, height - CGFloat(n - 1) * Self.separator)
        guard n == 2 else { return Array(repeating: usable / CGFloat(max(n, 1)), count: n) }
        let first = (usable * stackedFirstShare).rounded(.down)
        return [first, usable - first]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let n = paneCount
        guard subviews.count == 2 * n + 1, let content = subviews.last else {
            return proposal.replacingUnspecifiedDimensions()
        }
        let contentMin = content.sizeThatFits(ProposedViewSize(width: 0, height: proposal.height)).width
        let minimumWidth = narrowestChrome + contentMin

        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = max(proposed, minimumWidth)
        } else {
            // Ideal: panes at their ideal width beside the content's ideal (at least comfortable).
            let contentIdeal = content.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height)).width
            width = ideal.prefix(n).reduce(0, +) + CGFloat(n) * Self.separator + max(contentIdeal, comfortableContent)
        }

        let a = arrange(width: width)
        var height = content.sizeThatFits(ProposedViewSize(width: a.content, height: proposal.height)).height
        if a.stacked {
            // Stacked panes share the height; their minimum is the sum.
            let share = proposal.height.map { stackedHeights($0) }
            var sum = CGFloat(n - 1) * Self.separator
            for i in 0..<n {
                sum += subviews[2 * i].sizeThatFits(ProposedViewSize(width: a.panes[i], height: share?[i])).height
            }
            height = max(height, sum)
        } else {
            for i in 0..<n {
                height = max(height, subviews[2 * i].sizeThatFits(ProposedViewSize(width: a.panes[i], height: proposal.height)).height)
            }
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let n = paneCount
        guard subviews.count == 2 * n + 1, let content = subviews.last else { return }
        let a = arrange(width: bounds.width)
        let s = Self.separator
        var x = bounds.minX
        if a.stacked {
            let column = a.panes.first ?? 0
            let heights = stackedHeights(bounds.height)
            var y = bounds.minY
            for i in 0..<n {
                subviews[2 * i].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: column, height: heights[i]))
                y += heights[i]
                if i < n - 1 {
                    // Separator between two stacked panes: horizontal.
                    subviews[2 * i + 1].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: column, height: s))
                    y += s
                }
            }
            x += column
            subviews[2 * n - 1].place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: s, height: bounds.height))
            x += s
        } else {
            for i in 0..<n {
                subviews[2 * i].place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: a.panes[i], height: bounds.height))
                x += a.panes[i]
                subviews[2 * i + 1].place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: s, height: bounds.height))
                x += s
            }
        }
        content.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: max(0, bounds.maxX - x), height: bounds.height))
    }
}

/// 1-pt separator for ``ExplorerPanesLayout``; takes whatever size it is given, so the
/// layout can use it vertically or horizontally.
struct PaneSeparator: View {
    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor))
    }
}
