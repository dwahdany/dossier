import DossierCore
import SwiftUI

/// Device / range selection shared by all Activity sections, so switching sections keeps
/// looking at the same device.
@MainActor
final class ActivitySelection: ObservableObject {
    static let shared = ActivitySelection()
    @Published var deviceID: String = ActivityDevice.localID
    @Published var range: ActivityRange = .all
    @Published var devices: [ActivityDevice] = []
    private var loadedToken = -1

    var device: ActivityDevice? { devices.first { $0.id == deviceID } }

    /// Deep-link helper: "device:#<n>" selects the n-th device of the list (identifiers are
    /// never used in payloads typed by hand), "range:<7|30|all>" the range.
    func apply(payload: String) {
        for part in payload.split(separator: ";") {
            if part.hasPrefix("device:#"), let n = Int(part.dropFirst(8)) {
                pendingIndex = n
                if devices.indices.contains(n) { deviceID = devices[n].id }
            } else if part.hasPrefix("range:") {
                switch part.dropFirst(6) {
                case "7": range = .week
                case "30": range = .month
                default: range = .all
                }
            }
        }
    }

    private var pendingIndex: Int?

    func load(token: Int) async {
        guard token != loadedToken || devices.isEmpty else { return }
        await SnapshotReadiness.track {
            await ActivityStore.shared.sync(token: token)
            let list = await ActivityStore.shared.devices()
            devices = list
            loadedToken = token
            if let n = pendingIndex, list.indices.contains(n) { deviceID = list[n].id; pendingIndex = nil }
            if !list.contains(where: { $0.id == deviceID }), let first = list.first { deviceID = first.id }
        }
    }
}

enum ActivityAccess {
    /// Throws the error that makes `AsyncContent` / `PagedTable` show the right placeholder
    /// when the Biome stream directory is absent or blocked by TCC.
    static func requireBiome() throws {
        switch Paths.probe(Paths.biomeRestrictedStreams) {
        case .available: return
        case .inaccessible(let reason): throw DossierError.inaccessible(reason)
        case .missing: throw DossierError.missing("The Biome stream directory (~/Library/Biome/streams/restricted) does not exist on this Mac.")
        }
    }
}

/// Menu picker listing the devices that contributed activity records.
struct DevicePicker: View {
    @ObservedObject var selection = ActivitySelection.shared
    /// Adds an "All Devices" entry (id "").
    var allowsAll = false
    @Binding var allSelected: Bool
    @Environment(\.refreshToken) private var refreshToken

    init(allowsAll: Bool = false, allSelected: Binding<Bool> = .constant(false)) {
        self.allowsAll = allowsAll
        self._allSelected = allSelected
    }

    var body: some View {
        let binding = Binding<String>(
            get: { allowsAll && allSelected ? "" : selection.deviceID },
            set: { id in
                if id.isEmpty { allSelected = true } else { allSelected = false; selection.deviceID = id }
            })
        Picker(selection: binding) {
            if allowsAll {
                Label("All Devices", systemImage: "square.stack.3d.up").tag("")
                Divider()
            }
            ForEach(selection.devices) { device in
                Label(device.name, systemImage: device.symbol).tag(device.id)
            }
        } label: {
            Text("Device")
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .sensitive(.personal)
        .help("Devices whose activity is stored on this Mac. Other devices appear because their Biome streams sync through iCloud.")
        .task(id: refreshToken) { await selection.load(token: refreshToken) }
    }
}

struct RangePicker: View {
    @ObservedObject var selection = ActivitySelection.shared
    var body: some View {
        Picker("Range", selection: $selection.range) {
            ForEach(ActivityRange.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// Short "platform · build" caption for the selected device.
struct DeviceCaption: View {
    let device: ActivityDevice?
    var body: some View {
        if let device {
            HStack(spacing: 5) {
                Image(systemName: device.symbol)
                Text(caption(device))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func caption(_ d: ActivityDevice) -> String {
        var parts = [d.isLocal ? "Recorded on this Mac" : "\(d.platform), synced through iCloud"]
        if let b = d.build, !b.isEmpty { parts.append("OS build \(b)") }
        return parts.joined(separator: " · ")
    }
}

/// Header-strip content: controls at the leading edge and a caption at the trailing edge.
/// The caption is dropped — never truncated to a stub — when the strip is too narrow for both.
struct StripControls<Controls: View, Caption: View>: View {
    /// false: the caption follows the controls directly instead of sitting at the trailing edge.
    var captionTrailing = true
    @ViewBuilder var controls: Controls
    @ViewBuilder var caption: Caption

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                controls
                if captionTrailing { Spacer(minLength: 0) }
                caption.lineLimit(1).fixedSize()
                if !captionTrailing { Spacer(minLength: 0) }
            }
            HStack(spacing: 12) {
                controls
                Spacer(minLength: 0)
            }
        }
    }
}

/// Two blocks side by side when at least `minWidth` is available, otherwise stacked.
/// (`ViewThatFits` alone cannot decide this for cards: wrapping text makes their ideal
/// width a single long line, so the threshold is stated explicitly.)
struct SideBySide<Leading: View, Trailing: View>: View {
    var minWidth: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Metrics.blockSpacing) { leading; trailing }
                .frame(idealWidth: minWidth)
            VStack(alignment: .leading, spacing: Metrics.blockSpacing) { leading; trailing }
        }
    }
}

/// Card with a title row, used for dashboard blocks.
struct TitledCard<Content: View, Accessory: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

extension TitledCard where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol
        self.accessory = EmptyView(); self.content = content()
    }
}

/// A ranked row: icon + name, proportion bar, trailing value.
struct RankedAppRow: View {
    let rank: Int?
    let bundle: String
    let name: String
    var detail: String?
    let fraction: Double
    let value: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 8) {
            if let rank {
                Text("\(rank)").font(.caption).monospacedDigit().foregroundStyle(.tertiary).frame(width: 18, alignment: .trailing)
            }
            AppIcon(bundle: bundle, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.callout).lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                ProportionBar(fraction: fraction, tint: tint)
            }
            .sensitive(.personal)
            Text(value).font(.callout).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}

/// Sorts / filters / pages an in-memory array for `PagedTable`'s fetch closure with typed
/// sort keys (the built-in in-memory table sorts by cell text, which mis-orders durations).
enum MemoryPager {
    static func page<Row>(
        _ rows: [Row], _ request: PageRequest,
        matches: (Row, String) -> Bool,
        sorters: [String: (Row, Row) -> Bool]
    ) -> [Row] {
        var out = rows
        let needle = request.search.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty { out = out.filter { matches($0, needle) } }
        if let sort = request.sort, let less = sorters[sort.columnID] {
            // Stable sort so equal keys keep the default order.
            let indexed = out.enumerated().sorted { a, b in
                if less(a.element, b.element) { return sort.ascending }
                if less(b.element, a.element) { return !sort.ascending }
                return a.offset < b.offset
            }
            out = indexed.map(\.element)
        }
        return Array(out.dropFirst(request.offset).prefix(request.limit))
    }

    static func count<Row>(_ rows: [Row], _ request: PageRequest, matches: (Row, String) -> Bool) -> Int {
        let needle = request.search.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty ? rows.count : rows.filter { matches($0, needle) }.count
    }
}
