import SwiftUI
import DossierCore

/// One selectable chip of a ``ChipBar``.
struct Chip: Identifiable {
    let id: String
    let title: String
    let symbol: String?
    let count: Int?
}

/// Horizontally scrolling row of filter chips with counts.
struct ChipBar: View {
    let chips: [Chip]
    /// Wrap onto further lines instead of scrolling sideways.
    var wraps = false
    let isOn: (String) -> Bool
    let toggle: (String) -> Void

    var body: some View {
        if wraps {
            FlowLayout(spacing: 6, lineSpacing: 5) { buttons }
                .padding(.vertical, 2)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { buttons }
                    .padding(.vertical, 2)
            }
        }
    }

    private var buttons: some View {
        ForEach(chips) { chip in
            let on = isOn(chip.id)
            Button { toggle(chip.id) } label: {
                HStack(spacing: 5) {
                    if let symbol = chip.symbol { Image(systemName: symbol).imageScale(.small) }
                    Text(chip.title).lineLimit(1)
                    if let count = chip.count {
                        Text(Format.compact(count)).monospacedDigit().foregroundStyle(on ? AnyShapeStyle(.primary.opacity(0.7)) : AnyShapeStyle(.tertiary))
                    }
                }
                .font(.callout)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(on ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(chip.title)
        }
    }
}

extension View {
    /// Frames an embedded table (inside a scrolling dashboard) like a card.
    func tableCard(height: CGFloat) -> some View {
        self
            .frame(height: height)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5))
    }
}

enum EnvSymbol {
    /// Focus symbols come from iOS; fall back when macOS has no such SF Symbol.
    static func available(_ name: String, fallback: String = "moon.fill") -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : fallback
    }
}

enum EnvColor {
    /// Maps the UIKit colour names stored with Focus modes to SwiftUI colours.
    static func named(_ name: String) -> Color {
        let key = name.lowercased()
        let table: [(String, Color)] = [
            ("teal", .teal), ("indigo", .indigo), ("purple", .purple), ("pink", .pink), ("red", .red), ("orange", .orange),
            ("yellow", .yellow), ("green", .green), ("mint", .mint), ("cyan", .cyan), ("blue", .blue), ("brown", .brown), ("gray", .gray),
        ]
        return table.first { key.contains($0.0) }?.1 ?? .indigo
    }
}

/// Height for an embedded table showing `rows` rows (header, filter bar and footer included).
func embeddedTableHeight(rows: Int, max: CGFloat = 360) -> CGFloat {
    Swift.min(max, CGFloat(Swift.max(rows, 2)) * 26 + 96)
}

/// A titled list of tags that wraps onto several lines.
struct FlowTags: View {
    let tags: [String]
    var tint: Color = .secondary
    var sensitivity: Sensitivity = .personal

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                TagLabel(tag, tint: tint).sensitive(sensitivity)
            }
        }
    }
}

/// Stat tiles filling the available width (shared `StatTileRow`, 170-pt minimum tiles).
func EnvTiles(_ stats: [Stat]) -> StatTileRow { StatTileRow(stats, minTileWidth: 170, singleRowMinTileWidth: 150) }

extension Array {
    /// Raises the minimum widths of table columns so a table that gets narrow (window at
    /// its minimum, inspector open) scrolls sideways instead of squeezing every column to
    /// an unreadable stub. Columns up to 160 pt are sized to their content (timestamps,
    /// counts, codes) and keep that width; wider text columns may shrink to half.
    func readableMinimums<Row>() -> [PagedColumn<Row>] where Element == PagedColumn<Row> {
        map { column in
            var c = column
            let floor = c.idealWidth <= 160 ? c.idealWidth : Swift.max(120, (c.idealWidth * 0.5).rounded())
            c.minWidth = Swift.max(c.minWidth, Swift.min(floor, c.maxWidth))
            return c
        }
    }
}
