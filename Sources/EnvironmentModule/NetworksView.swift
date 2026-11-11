import SwiftUI
import Charts
import DossierCore

/// Section 2 — Wi-Fi networks, join log, microlocation Wi-Fi fingerprints and Bluetooth
/// devices with their connection sessions.
struct NetworksView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case wifi = "Wi-Fi Networks", joins = "Join Log", micro = "Microlocation", bluetooth = "Bluetooth"
        var id: String { rawValue }
    }

    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @State private var tab: Tab = .wifi
    @State private var wifiFilter = ""
    @State private var bluetoothFilter = ""

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (tab, wifiFilter, bluetoothFilter)
        let token = refreshToken
        VStack(spacing: 0) {
            HeaderStrip {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            AsyncContent(reloadKey: token) {
                try await NetworksLoader.load(token: token)
            } content: { data in
                switch tab {
                case .wifi: WifiNetworksPane(data: data.wifi, filter: $wifiFilter)
                case .joins: WifiJoinsPane(data: data.wifi)
                case .micro: MicrolocationPane(data: data.milo)
                case .bluetooth: BluetoothPane(data: data.bluetooth, filter: $bluetoothFilter)
                }
            }
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let payload = deepLink?.payload, let split = payload.firstIndex(of: ":") else { return }
            let value = String(payload[payload.index(after: split)...])
            switch payload[..<split] {
            case "wifi": tab = .wifi; wifiFilter = value
            case "bt": tab = .bluetooth; bluetoothFilter = value
            case "tab": tab = Tab.allCases.first { $0.rawValue == value } ?? tab
            default: break
            }
        }
    }
}

// MARK: - Known Wi-Fi networks

private struct WifiNetworksPane: View {
    let data: WifiData
    @Binding var filter: String
    @State private var selected: KnownNetwork?

    var body: some View {
        if !data.kvsAvailability.isAvailable {
            placeholder
        } else {
            VStack(spacing: 0) {
                let removed = data.networks.filter(\.isRemoved).count
                let oldest = data.networks.compactMap(\.addedAt).min()
                EnvTiles([
                    Stat("Known Networks", Format.count(data.networks.count), caption: "on record in iCloud, incl. removed", symbol: "wifi", tint: .blue),
                    Stat("Still Saved", Format.count(data.networks.count - removed), caption: "\(removed) removed, kept as tombstones", symbol: "checkmark.circle", tint: .green),
                    Stat("Earliest Added", DossierDate.day(oldest), caption: oldest.map { DossierDate.relative($0) }, symbol: "calendar", tint: .orange),
                    Stat("Hidden / Captive", "\(data.networks.filter(\.hidden).count) / \(data.networks.filter(\.captive).count)", caption: "hidden SSIDs / login portals", symbol: "eye.slash", tint: .purple),
                ])
                .padding(12)
                Divider()
                PagedTable(
                    rows: data.networks,
                    columns: [
                        PagedColumn<KnownNetwork>("Network", id: "ssid", width: 210, sensitivity: .sensitive) { $0.ssid },
                        PagedColumn("Last Joined", id: "joined", width: 160) { $0.lastJoinedText },
                        PagedColumn("Added", id: "added", width: 145) { DossierDate.sortable($0.addedAt) },
                        PagedColumn("Removed", id: "removed", width: 145) { n in n.isRemoved ? DossierDate.sortable(n.removedAt) : "" },
                        PagedColumn("Security", id: "security", width: 120) { $0.security },
                        PagedColumn("Added By", id: "addedBy", width: 170, secondary: true) { $0.addedByText }.cell { n in
                            Text(n.addedByText).font(.callout).foregroundStyle(.secondary).lineLimit(1).help(n.addedBy)
                        },
                        PagedColumn("Access Point", id: "bssid", width: 140, sensitivity: .sensitive, monospaced: true, secondary: true) { $0.bssid },
                        PagedColumn("Flags", id: "flags", width: 110, secondary: true, hiddenByDefault: true) { [$0.hidden ? "hidden" : nil, $0.captive ? "captive" : nil].compactMap { $0 }.joined(separator: ", ") },
                    ].readableMinimums(),
                    searchPrompt: "Filter networks",
                    reloadKey: AnyHashable(data.networks.count),
                    exportName: "known-wifi-networks",
                    emptyTitle: "No Known Networks",
                    filter: $filter,
                    onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
                )
                .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                    if let n = selected {
                        InspectorPage(title: n.ssid, subtitle: n.isRemoved ? "Removed Wi-Fi network" : "Known Wi-Fi network", sensitivity: .sensitive, onClose: { selected = nil }) {
                            Explainer("Every Wi-Fi network joined on any of your devices is remembered in iCloud so the others can join it too. The entry records when and by which device and OS version it was added, and when it was last joined.")
                            KeyValueGrid(n.details.items(sensitivity: .sensitive))
                            InspectorGroupTitle("Raw Value")
                            RawRecordView(ref: n.ref, title: "network." + n.ssid)
                        }
                    }
                }
                StoreFooter(EnvPaths.kvsDirectory ?? Paths.library, note: WifiKVS.store)
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        if case .inaccessible(let reason) = data.kvsAvailability {
            StatePlaceholder.inaccessible(reason)
        } else {
            StatePlaceholder.missing("The iCloud key-value cache (kvsd daemon container) was not found on this Mac.")
        }
    }
}

private struct WifiJoinsPane: View {
    let data: WifiData
    @State private var selected: WifiJoin?

    var body: some View {
        VStack(spacing: 0) {
            PagedTable(
                rows: data.joins,
                columns: [
                    PagedColumn<WifiJoin>("Time", id: "date", width: 150, min: 140) { DossierDate.sortable($0.date) },
                    PagedColumn("Event", id: "event", width: 200) { $0.event },
                    PagedColumn("Network", id: "ssid", width: 190, sensitivity: .sensitive) { $0.ssid },
                    PagedColumn("Access Point", id: "bssid", width: 140, sensitivity: .sensitive, monospaced: true) { $0.bssid },
                    PagedColumn("Channel", id: "channel", width: 100) { $0.channel },
                    PagedColumn("Until", id: "end", width: 145) { $0.end.map { DossierDate.sortable($0) } ?? "" },
                    PagedColumn("Source", id: "source", width: 220, secondary: true) { $0.source },
                    PagedColumn("Device", id: "device", width: 200, secondary: true, hiddenByDefault: true) { $0.device },
                ].readableMinimums(),
                searchPrompt: "Filter joins",
                reloadKey: AnyHashable(data.joins.count),
                exportName: "wifi-join-log",
                emptyTitle: "No Wi-Fi Joins Recorded",
                onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
            )
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let j = selected {
                    InspectorPage(title: j.ssid.isEmpty ? j.bssid : j.ssid, subtitle: j.event, sensitivity: .sensitive, onClose: { selected = nil }) {
                        KeyValueGrid([
                            KeyValueItem("When", DossierDate.medium(j.date)),
                            KeyValueItem("Until", j.end.map { DossierDate.medium($0) }),
                            KeyValueItem("Network", j.ssid.isEmpty ? nil : j.ssid, sensitivity: .sensitive),
                            KeyValueItem("Access point", j.bssid.isEmpty ? nil : j.bssid, sensitivity: .sensitive, monospaced: true),
                            KeyValueItem("Channel", j.channel.isEmpty ? nil : j.channel),
                            KeyValueItem("Source", j.source),
                            KeyValueItem("Device", j.device),
                        ])
                        Explainer("The join log merges four sources: the Biome Wi-Fi stream, CoreDuet's connection intervals, the access-point associations noted by the microlocation daemon, and the “last joined by user” date of each iCloud-synced network.")
                        if j.ref != .none {
                            InspectorGroupTitle("Raw Record")
                            RawRecordView(ref: j.ref, title: j.source)
                        }
                    }
                }
            }
            StoreFooter(EnvPaths.stream("Device.Wireless.WiFi"), note: data.streamCounts.map { "\($0.name): \($0.count)" }.joined(separator: " · "))
        }
    }
}

// MARK: - Microlocation

private struct MicrolocationPane: View {
    let data: MiloData

    var body: some View {
        if case .inaccessible(let reason) = data.availability {
            StatePlaceholder.inaccessible(reason)
        } else if !data.availability.isAvailable {
            StatePlaceholder.missing("The microlocation daemon (milod) keeps no database on this Mac.")
        } else {
            VStack(spacing: 0) {
                ScrollPage {
                    Explainer("milod learns room-level “microlocations” by periodically scanning nearby Wi-Fi access points and recording their signal strengths as a fingerprint. Fingerprints are grouped under labelled places such as “home” and used to predict, for example, which speaker or TV you are likely to AirPlay to.")
                    EnvTiles([
                        Stat("Wi-Fi Scans", Format.compact(data.scans), caption: DossierDate.range(data.scanRange), symbol: "dot.radiowaves.left.and.right", tint: .blue),
                        Stat("Signal Samples", Format.compact(data.measurements), caption: "access point × scan", symbol: "waveform", tint: .teal),
                        Stat("Access Points Seen", Format.count(data.bssids.count), caption: "distinct BSSIDs heard in scans", symbol: "wifi.router", tint: .orange),
                        Stat("Labelled Places", data.lois.map { $0.type.capitalized }.joined(separator: ", ").nilIfEmpty ?? "None", caption: "\(data.models.count) trained models", symbol: "house", tint: .green, sensitivity: .personal),
                    ])
                    HStack(alignment: .top, spacing: Metrics.blockSpacing) {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader("Signal Strength", subtitle: "Samples per 5 dBm bucket (closer to 0 is stronger)", symbol: "chart.bar")
                            RSSIHistogram(bins: data.rssiHistogram).frame(height: 200).card()
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader("Scans per Day", subtitle: "How often the Mac fingerprinted its surroundings", symbol: "calendar")
                            LineChartView(data.scansPerDay, style: .bars, unit: .day, tint: .teal).frame(height: 200).card()
                        }
                    }
                    SectionHeader("Access Points", subtitle: "Every BSSID heard during scans, strongest evidence of where this Mac has been", symbol: "wifi.router")
                    PagedTable(
                        rows: data.bssids,
                        columns: [
                            PagedColumn<MiloBSSID>("BSSID", id: "mac", width: 150, sensitivity: .sensitive, monospaced: true) { $0.mac },
                            PagedColumn("Samples", id: "samples", width: 80, alignment: .trailing) { String($0.samples) },
                            PagedColumn("Avg dBm", id: "avg", width: 80, alignment: .trailing) { String(format: "%.0f", $0.avgRSSI) }.cell { row in
                                SignalCell(rssi: row.avgRSSI)
                            },
                            PagedColumn("Range dBm", id: "range", width: 100, alignment: .trailing, sortable: false) { "\($0.minRSSI) … \($0.maxRSSI)" },
                            PagedColumn("Channel", id: "channel", width: 70, alignment: .trailing) { String($0.channel) },
                            PagedColumn("Band", id: "band", width: 70) { EnvFormat.band(channel: $0.channel) },
                            PagedColumn("Connected", id: "assoc", width: 80) { $0.associated ? "yes" : "" },
                            PagedColumn("First Heard", id: "first", width: 145) { DossierDate.sortable($0.first) },
                            PagedColumn("Last Heard", id: "last", width: 145) { DossierDate.sortable($0.last) },
                        ].readableMinimums(),
                        searchPrompt: "Filter access points",
                        reloadKey: AnyHashable(data.bssids.count),
                        exportName: "microlocation-access-points",
                        emptyTitle: "No Access Points Recorded"
                    )
                    .tableCard(height: embeddedTableHeight(rows: data.bssids.count, max: 380))

                    SectionHeader("Raw Signal Samples", subtitle: "One row per access point per scan, read page by page", symbol: "tablecells")
                    PagedTable(
                        columns: [
                            PagedColumn<MiloMeasurement>("Time", id: "ZTIMESTAMP", width: 160) { DossierDate.sortable($0.date) },
                            PagedColumn("BSSID", id: "ZSOURCEBSSID", width: 150, sensitivity: .sensitive, monospaced: true) { EnvFormat.mac($0.bssid) },
                            PagedColumn("dBm", id: "ZRSSI", width: 60, alignment: .trailing) { String($0.rssi) },
                            PagedColumn("Channel", id: "ZCHANNEL", width: 70, alignment: .trailing) { String($0.channel) },
                            PagedColumn("Scan", id: "ZSCANNINGEVENT", width: 70, alignment: .trailing, secondary: true) { $0.scan.map(String.init) ?? "" },
                        ].readableMinimums(),
                        searchPrompt: nil,
                        exportName: "microlocation-samples",
                        fetch: { request in try await MiloSource.measurements(request) },
                        count: { _ in await MiloSource.db()?.rowCount(of: "ZULWIFIMEASUREMENTMO") }
                    )
                    .tableCard(height: 300)

                    SectionHeader("Daemon Event Log", subtitle: "Screen lock state and model status changes noted while learning", symbol: "list.bullet.rectangle")
                    PagedTable(
                        rows: data.events,
                        columns: [
                            PagedColumn<MiloEvent>("Time", id: "date", width: 160) { DossierDate.sortable($0.date) },
                            PagedColumn("Event", id: "text", width: 520) { $0.text },
                        ].readableMinimums(),
                        searchPrompt: "Filter events",
                        reloadKey: AnyHashable(data.events.count),
                        exportName: "microlocation-events",
                        emptyTitle: "No Events"
                    )
                    .tableCard(height: embeddedTableHeight(rows: data.events.count, max: 300))

                    if !data.models.isEmpty || !data.services.isEmpty {
                        SectionHeader("Models & Clients", subtitle: "Trained localisation models and the services that ask for predictions", symbol: "brain")
                        KeyValueGrid(
                            data.models.map { KeyValueItem("Model type \($0.type)", "\(Format.bytes($0.bytes)), generated \(DossierDate.medium($0.generated))", id: "m\($0.id)") }
                                + data.services.enumerated().map { KeyValueItem("Client", "\($0.element.key) — \($0.element.value)", monospaced: false, id: "s\($0.offset)") }
                        ).card()
                    }
                }
                if let url = EnvPaths.miloDB { StoreFooter(url, note: "ZULWIFIMEASUREMENTMO · ZULSCANNINGEVENTMO · ZULLOIMO") }
            }
        }
    }
}

private struct SignalCell: View {
    let rssi: Double
    var body: some View {
        HStack(spacing: 6) {
            // −95 dBm (barely audible) … −30 dBm (next to the access point).
            let level = max(0, min(1, (rssi + 95) / 65))
            Capsule().fill(Color.primary.opacity(0.08)).frame(width: 34, height: 5)
                .overlay(alignment: .leading) { Capsule().fill(level > 0.6 ? Color.green : level > 0.3 ? Color.orange : Color.red).frame(width: 34 * level, height: 5) }
            Text(String(format: "%.0f", rssi)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct RSSIHistogram: View {
    let bins: [(bucket: Int, count: Int)]

    var body: some View {
        if bins.isEmpty {
            Text("No data").font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(bins, id: \.bucket) { bin in
                RectangleMark(
                    xStart: .value("dBm", Double(bin.bucket) + 0.3), xEnd: .value("dBm", Double(bin.bucket) + 4.7),
                    yStart: .value("Samples", 0), yEnd: .value("Samples", bin.count)
                )
                .foregroundStyle(Color.blue.gradient)
                .cornerRadius(2)
            }
            .chartXAxisLabel("Signal strength (dBm)")
            .chartYAxisLabel("Samples")
            .chartXAxis { AxisMarks(values: .stride(by: 10)) }
        }
    }
}

// MARK: - Bluetooth

private struct BluetoothPane: View {
    let data: BluetoothData
    @Binding var filter: String
    @State private var selected: BluetoothDevice?

    var body: some View {
        VStack(spacing: 0) {
            ScrollPage {
                Explainer("Each of your devices logs when a Bluetooth accessory connects and disconnects, with its name, address and battery levels. The logs sync between your devices, so this Mac also knows when your headphones were connected to your phone.")
                let hosts = Set(data.sessions.filter(\.primary).map(\.host))
                EnvTiles([
                    Stat("Accessories", Format.count(data.devices.count), caption: "distinct Bluetooth addresses", symbol: "headphones", tint: .blue),
                    Stat("Connection Sessions", Format.compact(data.sessions.filter(\.primary).count), caption: DossierDate.range(data.range), symbol: "link", tint: .teal),
                    Stat("Connected Time", Format.duration(data.devices.reduce(0) { $0 + $1.connectedSeconds }), caption: "summed over all accessories", symbol: "clock", tint: .orange),
                    Stat("Reporting Devices", Format.count(hosts.count), caption: "\(Format.count(data.biomeEvents)) Biome events · \(Format.count(data.knowledgeSessions)) CoreDuet sessions", symbol: "laptopcomputer.and.iphone", tint: .purple),
                ])

                SectionHeader("Connection Timeline", subtitle: "One lane per accessory; colour shows which of your devices it was connected to. Drawn from the Biome log, or CoreDuet's where Biome has nothing for an accessory", symbol: "chart.bar.xaxis")
                BluetoothTimeline(sessions: data.sessions, range: data.range).card()

                SectionHeader("Accessories", symbol: "headphones")
                PagedTable(
                    rows: data.devices,
                    columns: [
                        PagedColumn<BluetoothDevice>("Name", id: "name", width: 220, sensitivity: .sensitive) { $0.name },
                        PagedColumn("Sessions", id: "sessions", width: 70, alignment: .trailing) { String($0.sessions) },
                        PagedColumn("Connected", id: "time", width: 90, alignment: .trailing, sortable: false) { Format.duration($0.connectedSeconds) },
                        PagedColumn("Connected To", id: "hosts", width: 220, sensitivity: .personal) { $0.hosts.sorted().joined(separator: ", ") },
                        PagedColumn("Vendor", id: "vendor", width: 110) { $0.vendorID.map(EnvFormat.bluetoothVendor) ?? "" },
                        PagedColumn("First Seen", id: "first", width: 145) { DossierDate.sortable($0.first) },
                        PagedColumn("Last Seen", id: "last", width: 145) { DossierDate.sortable($0.last) },
                        PagedColumn("Battery", id: "battery", width: 150, secondary: true) { $0.lastBattery },
                        PagedColumn("Address", id: "address", width: 150, sensitivity: .sensitive, monospaced: true, secondary: true, hiddenByDefault: true) { $0.address },
                    ].readableMinimums(),
                    searchPrompt: "Filter accessories",
                    reloadKey: AnyHashable(data.devices.count),
                    exportName: "bluetooth-accessories",
                    emptyTitle: "No Bluetooth Accessories Recorded",
                    filter: $filter,
                    onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
                )
                .tableCard(height: embeddedTableHeight(rows: data.devices.count, max: 300))

                SectionHeader(selected.map { "Sessions of \($0.name)" } ?? "All Sessions", subtitle: "Select an accessory above to narrow the list", symbol: "list.bullet")
                let sessions = selected.map { d in data.sessions.filter { $0.address == d.address } } ?? data.sessions
                PagedTable(
                    rows: sessions,
                    columns: [
                        PagedColumn<BluetoothSession>("Connected", id: "start", width: 150) { DossierDate.sortable($0.start) },
                        PagedColumn("Disconnected", id: "end", width: 150) { $0.end.map { DossierDate.sortable($0) } ?? "still connected" },
                        PagedColumn("Duration", id: "duration", width: 90, alignment: .trailing, sortable: false) { $0.duration.map { Format.duration($0) } ?? "" },
                        PagedColumn("Accessory", id: "name", width: 220, sensitivity: .sensitive) { $0.name },
                        PagedColumn("Connected To", id: "host", width: 200, sensitivity: .personal) { $0.host },
                        PagedColumn("Log", id: "source", width: 100, secondary: true) { $0.source + ($0.primary ? "" : " (duplicate log)") },
                    ].readableMinimums(),
                    searchPrompt: "Filter sessions",
                    reloadKey: AnyHashable([AnyHashable(sessions.count), AnyHashable(selected?.address ?? "")]),
                    exportName: "bluetooth-sessions",
                    emptyTitle: "No Sessions"
                )
                .tableCard(height: embeddedTableHeight(rows: sessions.count, max: 340))

                if !data.nearby.isEmpty {
                    SectionHeader("Nearby Device Sightings", subtitle: "Anonymous identifiers of devices detected in Bluetooth range (Device.Wireless.BluetoothNearbyDevice)", symbol: "sensor.tag.radiowaves.forward")
                    PagedTable(
                        rows: data.nearby,
                        columns: [
                            PagedColumn<NearbyDevice>("Time", id: "date", width: 160) { DossierDate.sortable($0.date) },
                            PagedColumn("Identifier", id: "id", width: 300, sensitivity: .personal, monospaced: true) { $0.identifier },
                            PagedColumn("Codes", id: "codes", width: 260, secondary: true) { $0.codes },
                        ].readableMinimums(),
                        searchPrompt: nil,
                        reloadKey: AnyHashable(data.nearby.count),
                        exportName: "bluetooth-nearby"
                    )
                    .tableCard(height: embeddedTableHeight(rows: data.nearby.count, max: 220))
                }
            }
            StoreFooter(EnvPaths.stream("Device.Wireless.Bluetooth"), note: "plus knowledgeC /bluetooth/isConnected")
        }
    }
}

private struct BluetoothTimeline: View {
    let sessions: [BluetoothSession]
    let range: ClosedRange<Date>?

    var body: some View {
        // Cap the marks: the most recent sessions of the busiest accessories.
        let primary = sessions.filter(\.primary)
        let names = Dictionary(grouping: primary, by: \.name).sorted { $0.value.count > $1.value.count }.prefix(12).map(\.key)
        let shown = primary.filter { names.contains($0.name) }.prefix(3_000)
        let logEnd = range?.upperBound ?? Date()
        if shown.isEmpty {
            Text("No sessions").font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 80)
        } else {
            Chart(Array(shown)) { s in
                BarMark(
                    xStart: .value("Start", s.start),
                    xEnd: .value("End", max(s.end ?? logEnd, s.start.addingTimeInterval(60))),
                    y: .value("Accessory", s.name),
                    height: .fixed(12)
                )
                .foregroundStyle(by: .value("Connected to", s.host))
                .cornerRadius(2)
            }
            .chartForegroundStyleScale(range: ChartPalette.colors)
            .chartLegend(position: .bottom, alignment: .leading)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 8)) }
            .chartYAxis { AxisMarks(preset: .aligned, position: .leading) { _ in AxisValueLabel(); AxisGridLine() } }
            .frame(height: CGFloat(names.count) * 30 + 70)
            .sensitive(.sensitive)
        }
    }
}
