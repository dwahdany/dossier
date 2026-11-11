import SwiftUI
import Charts
import DossierCore

/// Section 3 — the owner's devices as this Mac sees them: Biome sync peers, what each one
/// contributes, sync sessions, CoreDuet peers, AirPlay targets and printers.
struct DevicesView: View {
    @Environment(\.refreshToken) private var refreshToken

    var body: some View {
        let token = refreshToken
        AsyncContent(reloadKey: token) {
            async let devices = DevicesLoader.load(token: token)
            async let printers = WifiKVS.printers()
            return try await (devices, printers)
        } content: { loaded in
            DevicesContent(data: loaded.0, printers: loaded.1)
        }
    }
}

private struct DevicesContent: View {
    let data: DevicesData
    let printers: [KnownPrinter]
    @State private var shareFilter = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollPage {
                Explainer("Biome streams sync between the devices signed in to your Apple Account. Each stream keeps what arrived from another device in its own “remote” folder, so this Mac holds copies of activity that happened on your phone, tablet or other Macs. The graph shows which devices feed data into this Mac.")
                let remote = data.peers.filter { !$0.isMe }
                EnvTiles([
                    Stat("Devices Feeding This Mac", Format.count(remote.filter { $0.streams > 0 }.count), caption: "\(data.peers.filter(\.listed).count) listed as sync peers", symbol: "laptopcomputer.and.iphone", tint: .blue),
                    Stat("Synced Streams", Format.count(Set(data.shares.map(\.stream)).count), caption: Format.bytes(data.shares.reduce(0) { $0 + $1.bytes }) + " from other devices", symbol: "arrow.triangle.2.circlepath", tint: .teal),
                    Stat("Last Sync", DossierDate.relative(data.lastSync), caption: DossierDate.medium(data.lastSync), symbol: "clock.arrow.circlepath", tint: .green),
                    Stat("AirPlay Targets", Format.count(data.targets.count), caption: "\(data.knowledgePeers.count) CoreDuet peers", symbol: "airplayaudio", tint: .orange),
                ])

                SectionHeader("Device Graph", subtitle: "Line weight follows the amount of stream data received from each device", symbol: "point.3.connected.trianglepath.dotted")
                DeviceGraph(peers: data.peers, targets: data.targets).frame(height: 300).card(padding: 0)

                SectionHeader("Sync Peers", subtitle: "Biome sync.db › DevicePeer, the remote folders found in the streams, and past sync sites still referenced by the sync history", symbol: "person.2.wave.2")
                PagedTable(
                    rows: data.peers,
                    columns: [
                        PagedColumn<SyncPeer>("Device", id: "label", width: 220, sensitivity: .personal) { $0.label },
                        PagedColumn("Platform", id: "platform", width: 110) { $0.platform },
                        PagedColumn("OS Build", id: "build", width: 90, monospaced: true) { $0.build },
                        PagedColumn("Last Sync", id: "sync", width: 150) { $0.isMe ? "(this device)" : DossierDate.sortable($0.lastSync) },
                        PagedColumn("Streams", id: "streams", width: 70, alignment: .trailing) { String($0.streams) },
                        PagedColumn("Data Held", id: "bytes", width: 90, alignment: .trailing, sortable: false) { $0.bytes > 0 ? Format.bytes($0.bytes) : "" },
                        PagedColumn("Newest Data", id: "newest", width: 150) { $0.newestData.map { DossierDate.sortable($0) } ?? "" },
                        PagedColumn("Merged Events", id: "atoms", width: 100, alignment: .trailing) { $0.mergedAtoms > 0 ? String($0.mergedAtoms) : "" },
                        PagedColumn("Sync History", id: "crdt", width: 100, alignment: .trailing, secondary: true) { $0.crdtStreams > 0 ? "\($0.crdtStreams) streams" : "" },
                        PagedColumn("Listed", id: "listed", width: 60, secondary: true) { $0.listed ? "yes" : "no" },
                        PagedColumn("Identifier", id: "id", width: 290, sensitivity: .personal, monospaced: true, secondary: true, hiddenByDefault: true) { $0.id },
                    ].readableMinimums(),
                    searchPrompt: nil,
                    reloadKey: AnyHashable(data.peers.count),
                    exportName: "sync-peers",
                    emptyTitle: "No Sync Peers"
                )
                .tableCard(height: embeddedTableHeight(rows: data.peers.count, max: 280))

                SectionHeader("What Syncs", subtitle: "Streams holding data that originated on another device", symbol: "arrow.down.left.and.arrow.up.right")
                PagedTable(
                    rows: data.shares,
                    columns: [
                        PagedColumn<StreamShare>("Stream", id: "stream", width: 280, monospaced: true) { $0.stream },
                        PagedColumn("From Device", id: "device", width: 220, sensitivity: .personal) { $0.device },
                        PagedColumn("Segments", id: "segments", width: 80, alignment: .trailing) { String($0.segments) },
                        PagedColumn("Size", id: "bytes", width: 90, alignment: .trailing, sortable: false) { Format.bytes($0.bytes) },
                        PagedColumn("Newest", id: "newest", width: 150) { DossierDate.sortable($0.newest) },
                    ].readableMinimums(),
                    searchPrompt: "Filter streams",
                    reloadKey: AnyHashable(data.shares.count),
                    exportName: "synced-streams",
                    emptyTitle: "Nothing Synced From Other Devices",
                    filter: $shareFilter
                )
                .tableCard(height: embeddedTableHeight(rows: data.shares.count, max: 360))

                // Side by side when each table gets a readable width, stacked in a narrow window.
                BalancedGrid(minItemWidth: 400, spacing: Metrics.blockSpacing) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader("Sync Sessions", subtitle: "\(data.sessions.count) logged exchanges (SyncSessionLog)", symbol: "arrow.left.arrow.right")
                        PagedTable(
                            rows: data.sessions,
                            columns: [
                                PagedColumn<SyncSession>("Started", id: "start", width: 150) { DossierDate.sortable($0.start) },
                                PagedColumn("Took", id: "took", width: 60, alignment: .trailing, sortable: false) { s in s.end.map { String(format: "%.1f s", $0.timeIntervalSince(s.start)) } ?? "" },
                                PagedColumn("Transport", id: "transport", width: 80) { $0.transport.map { "code \($0)" } ?? "" },
                                PagedColumn("Reason", id: "reason", width: 70) { $0.reason.map { "code \($0)" } ?? "" },
                                PagedColumn("Since Previous", id: "prev", width: 110, alignment: .trailing, sortable: false) { $0.sincePrevious.map { Format.duration($0) } ?? "" },
                            ].readableMinimums(),
                            searchPrompt: nil,
                            reloadKey: AnyHashable(data.sessions.count),
                            exportName: "sync-sessions",
                            emptyTitle: "No Sessions Logged"
                        )
                        .tableCard(height: 260)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader("Merged Events", subtitle: "Events merged into local streams, by stream and origin (AtomMergedLog)", symbol: "square.stack.3d.down.right")
                        PagedTable(
                            rows: data.merged,
                            columns: [
                                PagedColumn<MergedStream>("Stream", id: "stream", width: 150, monospaced: true) { $0.stream },
                                PagedColumn("Origin", id: "device", width: 170, sensitivity: .personal) { $0.device },
                                PagedColumn("Events", id: "atoms", width: 70, alignment: .trailing) { String($0.atoms) },
                                PagedColumn("Last", id: "last", width: 150) { DossierDate.sortable($0.last) },
                            ].readableMinimums(),
                            searchPrompt: nil,
                            reloadKey: AnyHashable(data.merged.count),
                            exportName: "merged-events",
                            emptyTitle: "Nothing Merged"
                        )
                        .tableCard(height: 260)
                    }
                }

                SectionHeader("AirPlay & Media Route Targets", subtitle: "Speakers, TVs and computers the routing daemon considers when suggesting where to play media", symbol: "airplayvideo")
                if data.targets.isEmpty {
                    emptyBlock(data.routingAvailability, "No route targets have been recorded.")
                } else {
                    PagedTable(
                        rows: data.targets,
                        columns: [
                            PagedColumn<RouteTarget>("Name", id: "name", width: 240, sensitivity: .personal) { $0.name },
                            PagedColumn("Model", id: "model", width: 180, sensitivity: .personal, monospaced: true) { $0.model },
                            PagedColumn("First Seen", id: "first", width: 150) { DossierDate.sortable($0.firstSeen) },
                            PagedColumn("Last Seen", id: "last", width: 150) { DossierDate.sortable($0.lastSeen) },
                            PagedColumn("Last Used", id: "used", width: 150) { $0.lastUsed.map { DossierDate.sortable($0) } ?? "never" },
                            PagedColumn("Found Via", id: "infra", width: 110, secondary: true) { $0.overInfrastructure ? "local network" : "other" },
                            PagedColumn("Kind", id: "type", width: 130, secondary: true, hiddenByDefault: true) { $0.type },
                        ].readableMinimums(),
                        searchPrompt: nil,
                        reloadKey: AnyHashable(data.targets.count),
                        exportName: "route-targets"
                    )
                    .tableCard(height: embeddedTableHeight(rows: data.targets.count, max: 240))
                    if !data.routingStats.isEmpty {
                        KeyValueGrid(data.routingStats.items(sensitivity: .low)).card()
                    }
                }

                SectionHeader("CoreDuet Sync Peers", subtitle: "Devices whose activity knowledgeC has synced (hardware model, last seen, synced event streams)", symbol: "externaldrive.connected.to.line.below")
                PagedTable(
                    rows: data.knowledgePeers,
                    columns: [
                        PagedColumn<KnowledgePeer>("Model", id: "model", width: 140, sensitivity: .personal, monospaced: true) { $0.model.isEmpty ? "(unknown)" : $0.model },
                        PagedColumn("Last Seen", id: "seen", width: 150) { DossierDate.sortable($0.lastSeen) },
                        PagedColumn("Events Here", id: "events", width: 90, alignment: .trailing) { $0.events > 0 ? String($0.events) : "" },
                        PagedColumn("Streams", id: "streams", width: 300, monospaced: true) { $0.streams.sorted().joined(separator: ", ") },
                        PagedColumn("iCloud", id: "cloud", width: 60, secondary: true) { $0.hasCloudID ? "yes" : "" },
                        PagedColumn("Nearby", id: "rapport", width: 60, secondary: true) { $0.hasRapportID ? "yes" : "" },
                        PagedColumn("Version", id: "version", width: 70, secondary: true, hiddenByDefault: true) { $0.version },
                    ].readableMinimums(),
                    searchPrompt: nil,
                    reloadKey: AnyHashable(data.knowledgePeers.count),
                    exportName: "coreduet-peers",
                    emptyTitle: "No CoreDuet Peers"
                )
                .tableCard(height: embeddedTableHeight(rows: data.knowledgePeers.count, max: 260))

                if !printers.isEmpty || !data.identities.isEmpty {
                    HStack(alignment: .top, spacing: Metrics.blockSpacing) {
                        if !printers.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionHeader("Printers", subtitle: "Synced through iCloud, with the networks they were used on", symbol: "printer")
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(printers) { printer in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(printer.name).font(.callout.weight(.medium)).sensitive(.personal)
                                            Text((printer.urls.first ?? "") + (printer.lastUsed.map { " · last used " + DossierDate.day($0) } ?? ""))
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).sensitive(.personal)
                                            if !printer.networks.isEmpty { FlowTags(tags: printer.networks, tint: .blue, sensitivity: .sensitive) }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .card()
                            }
                        }
                        if !data.identities.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionHeader("Devices Known to Microlocation", subtitle: "Bluetooth identities milod tracks for proximity", symbol: "dot.radiowaves.left.and.right")
                                KeyValueGrid(data.identities.map { KeyValueItem($0.name, "last seen " + DossierDate.medium($0.lastSeen), id: "i\($0.id)") })
                                    .sensitive(.personal)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .card()
                            }
                        }
                    }
                }
            }
            StoreFooter(Paths.biomeSyncDB, note: "DevicePeer · SyncSessionLog · AtomMergedLog · stream remote folders")
        }
    }

    @ViewBuilder private func emptyBlock(_ availability: Availability, _ text: String) -> some View {
        Group {
            if case .inaccessible(let reason) = availability {
                StatePlaceholder.inaccessible(reason)
            } else {
                StatePlaceholder(title: "Nothing Recorded", symbol: "tray", message: text)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .card()
    }
}

/// Hub-and-spoke picture: this Mac in the centre, sync peers on the left arc, media route
/// targets on the right arc.
private struct DeviceGraph: View {
    let peers: [SyncPeer]
    let targets: [RouteTarget]

    private struct Node: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        /// True when the caption is a hardware model (hidden in Privacy Mode).
        var subtitleIsModel = false
        let symbol: String
        let tint: Color
        let weight: Double
        let dashed: Bool
        var point: CGPoint = .zero
    }

    private func symbol(for peer: SyncPeer) -> String {
        if peer.platform.contains("iPhone") { return "iphone" }
        if peer.platform.contains("Watch") { return "applewatch" }
        if peer.platform.contains("Mac") { return "laptopcomputer" }
        return "questionmark.square.dashed"
    }

    private func nodes(in size: CGSize) -> (center: CGPoint, nodes: [Node]) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let left = peers.filter { !$0.isMe && ($0.streams > 0 || $0.listed) }.prefix(7).map { p in
            Node(id: "p" + p.id, title: p.label,
                 subtitle: p.streams > 0 ? "\(p.streams) streams · \(Format.bytes(p.bytes))" : "listed, no stream data",
                 symbol: symbol(for: p), tint: p.listed ? .blue : .gray, weight: Double(p.bytes), dashed: p.streams == 0)
        }
        let right = targets.prefix(6).map { t in
            Node(id: "t\(t.id)", title: t.name, subtitle: t.model.isEmpty ? "media route target" : t.model, subtitleIsModel: !t.model.isEmpty,
                 symbol: "airplayaudio", tint: .orange, weight: 0, dashed: true)
        }
        func place(_ list: [Node], side: CGFloat) -> [Node] {
            // Leave room above and below the outermost icons for their two-line captions.
            let rx = size.width * 0.34, ry = max(40, size.height / 2 - 64)
            return list.enumerated().map { i, node in
                var n = node
                let t = list.count == 1 ? 0.5 : Double(i) / Double(list.count - 1)
                // ±0.36π keeps the outermost nodes of the two arcs far enough apart for their captions.
                let angle = (-0.36 + 0.72 * t) * Double.pi
                n.point = CGPoint(x: center.x + side * rx * cos(angle), y: center.y + ry * sin(angle))
                return n
            }
        }
        return (center, place(Array(left), side: -1) + place(Array(right), side: 1))
    }

    var body: some View {
        GeometryReader { geo in
            let layout = nodes(in: geo.size)
            let maxWeight = max(layout.nodes.map(\.weight).max() ?? 1, 1)
            ZStack {
                ForEach(layout.nodes) { node in
                    Path { p in
                        p.move(to: layout.center)
                        p.addLine(to: node.point)
                    }
                    .stroke(node.tint.opacity(0.55), style: StrokeStyle(lineWidth: node.dashed ? 1 : 1.5 + 5 * sqrt(node.weight / maxWeight), lineCap: .round, dash: node.dashed ? [4, 4] : []))
                }
                ForEach(layout.nodes) { node in
                    // The spoke arrives from the hub: put the caption on the far side of the icon.
                    bubble(title: node.title, subtitle: node.subtitle, symbol: node.symbol, tint: node.tint, captionAbove: node.point.y < layout.center.y - 1, subtitleSensitivity: node.subtitleIsModel ? .personal : .low)
                        .position(node.point)
                }
                bubble(title: "This Mac", subtitle: peers.first(where: \.isMe).map { $0.build.isEmpty ? "sync hub" : "build \($0.build)" } ?? "sync hub", symbol: "macbook", tint: .accentColor, large: true)
                    .position(layout.center)
                if layout.nodes.isEmpty {
                    Text("No other devices found").font(.callout).foregroundStyle(.secondary).position(x: layout.center.x, y: geo.size.height - 24)
                }
            }
        }
    }

    /// Icon centred on the node's point, with the caption hanging below (or above) it, so
    /// spokes end in the icon and do not run through the text.
    private func bubble(title: String, subtitle: String, symbol: String, tint: Color, large: Bool = false, captionAbove: Bool = false, subtitleSensitivity: Sensitivity = .low) -> some View {
        let diameter: CGFloat = large ? 52 : 38
        return Image(systemName: symbol)
            .font(.system(size: large ? 24 : 17))
            .foregroundStyle(tint)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(Circle().strokeBorder(tint.opacity(0.7), lineWidth: large ? 2 : 1.2))
            .overlay(alignment: captionAbove ? .top : .bottom) {
                VStack(spacing: 1) {
                    Text(title).font(.caption.weight(.semibold)).lineLimit(1).sensitive(.personal)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).sensitive(subtitleSensitivity)
                }
                .padding(.horizontal, 5).padding(.vertical, 1)
                // Opaque backing: spokes to other nodes may still pass behind a caption.
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .frame(width: 170)
                .fixedSize(horizontal: false, vertical: true)
                .alignmentGuide(captionAbove ? .top : .bottom) { d in captionAbove ? d[.bottom] + 3 : d[.top] - 3 }
            }
    }
}
