import SwiftUI
import Charts
import DossierCore

/// Filter field heading a master list pane.
struct PaneFilter<Accessory: View>: View {
    let prompt: String
    @Binding var text: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary).imageScale(.small)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.callout)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
            accessory
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.barHeight + 4)
    }
}

/// Master list + detail pane that adapts to the width it is given.
///
/// * Below `compactBelow` the master list uses `compactMasterWidth`.
/// * While the detail pane shows an inspector and there is no room for list, table and
///   inspector side by side, the master list is tucked away (kept alive, so its scroll
///   position and selection survive) and comes back when the inspector closes. Without
///   this the inspector would cover most of the table in the minimum window.
struct MasterDetailSplit<Master: View, Detail: View>: View {
    var masterWidth: CGFloat
    var compactMasterWidth: CGFloat
    var compactBelow: CGFloat = 800
    /// Narrowest useful detail pane (table) beside an open inspector.
    var minDetailWithInspector: CGFloat = 360
    var inspectorOpen: Bool
    @ViewBuilder var master: Master
    @ViewBuilder var detail: Detail

    @State private var width: CGFloat = 0

    var body: some View {
        let listWidth = width > 0 && width < compactBelow ? compactMasterWidth : masterWidth
        let needed = listWidth + 1 + minDetailWithInspector + 1 + 260
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

/// One line of caption text that degrades gracefully: the first variant that fits the
/// offered width is shown; with `orNothing` the text disappears when not even the last
/// one fits (instead of being squeezed to an ellipsis).
struct FittingText: View {
    let variants: [String]
    var orNothing = false

    init(_ variants: [String], orNothing: Bool = false) {
        var seen: [String] = []
        for v in variants where !v.isEmpty && !seen.contains(v) { seen.append(v) }
        self.variants = seen
        self.orNothing = orNothing
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(variants, id: \.self) { Text($0).lineLimit(1) }
            if orNothing { Color.clear.frame(width: 0, height: 0) }
        }
    }
}

/// Table cell for a field that holds a bundle identifier: icon and app name from the
/// shared `AppDirectory`, the identifier as secondary text. Values that are not shaped
/// like a bundle identifier (process names, several values) are shown as they are.
struct AppCell: View {
    let identifier: String

    static func name(_ identifier: String) -> String {
        if identifier.contains(", ") {
            return identifier.components(separatedBy: ", ").map(RecordDecoder.appName).joined(separator: ", ")
        }
        return RecordDecoder.appName(identifier)
    }

    var body: some View {
        if identifier.isEmpty {
            Text("")
        } else if RecordDecoder.looksLikeBundleID(identifier) {
            HStack(spacing: 6) {
                AppLabel(bundle: identifier)
                Text(identifier)
                    .font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(-1)
            }
        } else {
            Text(Self.name(identifier)).lineLimit(1).help(identifier)
        }
    }
}

/// Stable colour per stream family.
enum FamilyTint {
    static func color(_ family: String) -> Color {
        switch family {
        case "App": return .blue
        case "Siri": return .purple
        case "Apple Intelligence", "IntelligenceFlow", "ToolKit": return .pink
        case "Device & System", "Accessibility", "UserFocus": return .teal
        case "Photos & Media": return .orange
        case "Notifications": return .red
        case "Location": return .green
        case "Analytics Pipeline": return .gray
        case "ProactiveHarvesting", "TextUnderstanding", "Mail": return .indigo
        case "Proactive Suggestions": return .brown
        case "knowledgeC": return .mint
        default:
            var hash = 5381
            for u in family.unicodeScalars { hash = (hash &* 33) ^ Int(u.value) }
            return ChartPalette.color(abs(hash))
        }
    }
}

/// Tiny bar chart of counts per day (no axes) for table cells.
struct Sparkline: View {
    let values: [Int]
    var tint: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            guard let peak = values.max(), peak > 0, !values.isEmpty else { return }
            let step = size.width / CGFloat(values.count)
            let barWidth = max(1, step - 1)
            for (i, v) in values.enumerated() where v > 0 {
                // Square-root scale keeps quiet days visible next to busy ones.
                let h = max(1.5, size.height * CGFloat((Double(v) / Double(peak)).squareRoot()))
                let rect = CGRect(x: CGFloat(i) * step, y: size.height - h, width: barWidth, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 0.5), with: .color(tint.opacity(0.85)))
            }
            let base = Path(CGRect(x: 0, y: size.height - 0.5, width: size.width, height: 0.5))
            context.fill(base, with: .color(.secondary.opacity(0.25)))
        }
        .frame(height: 14)
        .accessibilityLabel("Records per day")
    }
}

/// Records per day as a proper chart (axes, optional per-device series).
struct DayChart: View {
    let points: [ChartPoint]
    var height: CGFloat = 150

    var body: some View {
        LineChartView(points, style: .bars, unit: .day)
            .frame(height: height)
    }

    static func points(_ days: [Int: Int], series: String = "") -> [ChartPoint] {
        days.sorted { $0.key < $1.key }.map { ChartPoint(DayIndex.date($0.key), Double($0.value), series: series) }
    }
}

/// Inspector for one SEGB record: decoded fields, annotated protobuf tree and hex dump.
struct RecordInspectorView: View {
    let ref: RecordRef
    let title: String
    let subtitle: String
    let info: BiomeStreamInfo
    let onClose: () -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case fields = "Fields", tree = "Tree", hex = "Hex"
        var id: String { rawValue }
    }
    @State private var mode: Mode?

    var body: some View {
        let schema = info.schema
        InspectorPage(title: title, subtitle: subtitle, sensitivity: .low, scrolls: false, onClose: onClose) {
            AsyncContent(reloadKey: ref) {
                try LoadedRecord.load(ref, schema: schema)
            } content: { record in
                let current = mode ?? (record.fields.isEmpty ? .tree : .fields)
                VStack(spacing: 0) {
                    Picker("View", selection: Binding(get: { current }, set: { mode = $0 })) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    Divider()
                    switch current {
                    case .fields:
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                if record.fields.isEmpty {
                                    Text("No field of this stream has a documented meaning yet. The Tree tab shows the raw protobuf structure.")
                                        .font(.callout).foregroundStyle(.secondary)
                                } else {
                                    InspectorGroupTitle("Decoded fields")
                                    KeyValueGrid(record.fields, valueLineLimit: 12)
                                }
                                InspectorGroupTitle("Record")
                                KeyValueGrid([
                                    KeyValueItem("Written", DossierDate.iso(record.timestamp)),
                                    KeyValueItem("Stream", info.name, monospaced: true),
                                    KeyValueItem("Payload", "\(Format.bytes(record.payload.count)) · \(BlobSniffer.sniff(record.payload).label)"),
                                    KeyValueItem("State", record.state),
                                    KeyValueItem("CRC-32", String(format: "%08x", record.crc) + (record.crcOK ? "  ✓ verified" : "  ✗ mismatch"), monospaced: true),
                                    KeyValueItem("Segment", "\(ref.segmentURL.lastPathComponent) #\(ref.entryIndex) · SEGB v\(record.version)", monospaced: true),
                                    KeyValueItem("Segment created", DossierDate.medium(record.segmentCreated)),
                                ])
                                InspectorGroupTitle("About this stream")
                                Text(info.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    case .tree:
                        DataTreeView(record.nodes, sensitivity: info.sensitivity, expandedDepth: 3)
                    case .hex:
                        HexView(record.payload)
                    }
                }
            }
        }
    }
}

/// "12,345" or an em dash for zero.
func countOrDash(_ n: Int) -> String { n > 0 ? Format.count(n) : "—" }
