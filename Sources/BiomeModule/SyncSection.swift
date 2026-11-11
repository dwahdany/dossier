import SwiftUI
import DossierCore

/// (6) Sync: which devices exchange Biome streams with this Mac, what is replicated and
/// when sync happened.
struct SyncSection: View {
    @Environment(\.refreshToken) private var refreshToken

    var body: some View {
        let token = refreshToken
        AsyncContent(reloadKey: token, emptyTitle: "No Sync Data", emptySymbol: "arrow.triangle.2.circlepath") {
            await BiomeCatalog.shared.sync(token: token)
            let snapshot = await BiomeCatalog.shared.snapshot()
            return try await SyncStore.load(catalog: snapshot)
        } content: { data in
            page(data)
        }
    }

    private func bordered<V: View>(_ view: V, height: CGFloat) -> some View {
        view
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
    }

    private func deviceGrid(_ data: SyncOverview, compact: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: compact ? 12 : 18, verticalSpacing: 8) {
            GridRow {
                Text("Device"); Text("Platform"); if !compact { Text("OS build") }; Text("Last sync")
                Text("Stream-days").gridColumnAlignment(.trailing); Text("Events").gridColumnAlignment(.trailing); Text("Protocol").gridColumnAlignment(.trailing)
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(data.peers.filter { $0.isPeer || $0.atoms > 0 }) { peer in
                GridRow {
                    HStack(spacing: 6) {
                        Image(systemName: peer.isMe ? "desktopcomputer" : (peer.platform.contains("iPhone") ? "iphone" : "laptopcomputer"))
                            .foregroundStyle(peer.isMe ? Color.accentColor : Color.secondary)
                        Text(peer.label).lineLimit(1).sensitive(.personal)
                    }
                    Text(peer.platform).lineLimit(1).foregroundStyle(.secondary)
                    if !compact { Text(peer.build.isEmpty ? "—" : peer.build).font(.callout.monospaced()).foregroundStyle(.secondary) }
                    Text(peer.isMe ? "this device" : (peer.lastSync.map { compact ? DossierDate.short($0) : DossierDate.medium($0) } ?? "not syncing"))
                        .lineLimit(1).foregroundStyle(peer.lastSync == nil ? .tertiary : .primary)
                    Text(countOrDash(peer.locations)).monospacedDigit()
                    Text(countOrDash(peer.atoms)).monospacedDigit()
                    Text(peer.protocolVersion.map(String.init) ?? "—").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func page(_ data: SyncOverview) -> some View {
        let leftovers = data.peers.filter { !$0.isPeer && $0.atoms == 0 }
        ScrollPage {
            StatTileRow([
                Stat("Devices", "\(data.peers.filter(\.isPeer).count)", caption: "\(data.peers.filter { !$0.isMe && $0.lastSync != nil }.count) syncing · \(data.peers.filter { !$0.isPeer }.count) former", symbol: "laptopcomputer.and.iphone", tint: .teal),
                Stat("Synced Streams", "\(data.streamCount)", caption: "\(Format.count(data.locationTotal)) stream-days tracked", symbol: "arrow.triangle.2.circlepath", tint: .blue),
                Stat("Replicated Events", Format.compact(data.atomTotal), caption: "atoms in the CRDT log", symbol: "circle.hexagongrid", tint: .purple),
                Stat("Merged In", Format.compact(data.mergedTotal), caption: "events received, recent log", symbol: "arrow.down.left.circle", tint: .green),
                Stat("Last Device Sync", DossierDate.relative(data.lastSync), caption: DossierDate.medium(data.lastSync), symbol: "clock", tint: .orange),
                Stat("iCloud Mirror", "\(data.cloudRecords)", caption: data.lastCloudSync.map { "last " + DossierDate.relative($0) } ?? "never synced", symbol: "icloud", tint: .cyan),
            ], minTileWidth: 165)

            SectionHeader("Devices", subtitle: "Peers known to Biome sync. Streams from these devices are stored on this Mac under each stream's remote folder.", symbol: "laptopcomputer.and.iphone")
            // The complete grid when every cell fits on one line; otherwise a tighter one
            // (short dates, no OS build) instead of names and dates wrapping onto two lines.
            ViewThatFits(in: .horizontal) {
                deviceGrid(data, compact: false)
                deviceGrid(data, compact: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            if !leftovers.isEmpty {
                Text("\(leftovers.count) more former device\(leftovers.count == 1 ? "" : "s") survive only as \(Format.count(leftovers.reduce(0) { $0 + $1.locations })) old day markers without any events (device identifiers that no longer belong to a current peer). They are listed under What Syncs.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, -12)
            }

            SectionHeader("What Syncs", subtitle: "One row per synced stream and originating device. Sync identifiers are matched to stream folders through the segment files they reference.", symbol: "list.bullet.indent")
            if data.locations.isEmpty {
                StatePlaceholder(title: "Nothing Is Synced", symbol: "arrow.triangle.2.circlepath", message: "sync.db lists no CRDT locations.")
                    .frame(height: 140).card()
            } else {
                bordered(PagedTable(
                    rows: data.locations,
                    columns: [
                        PagedColumn<SyncOverview.Location>("Stream", id: "stream", width: 220, min: 150) { $0.resolvedStream ?? "Unresolved" }
                            .cell { row in
                                Text(row.resolvedStream ?? "not on this Mac").foregroundStyle(row.resolvedStream == nil ? .tertiary : .primary).lineLimit(1)
                            },
                        PagedColumn("From Device", id: "device", width: 120, sensitivity: .personal) { $0.device },
                        PagedColumn("Days", id: "days", width: 56, alignment: .trailing) { Format.count($0.days) },
                        PagedColumn("Events", id: "atoms", width: 76, alignment: .trailing) { countOrDash($0.atoms) },
                        PagedColumn("First Day", id: "first", width: 96, secondary: true) { $0.firstDay.map { DossierDate.sortable($0).prefix(10).description } ?? "" },
                        PagedColumn("Last Day", id: "last", width: 96, secondary: true) { $0.lastDay.map { DossierDate.sortable($0).prefix(10).description } ?? "" },
                        PagedColumn("Deletions", id: "deletions", width: 76, alignment: .trailing, secondary: true) { countOrDash($0.deletions) },
                        PagedColumn("Sync Identifier", id: "sync", width: 150, monospaced: true, secondary: true) { $0.syncStream },
                        PagedColumn("Day States", id: "states", width: 80, secondary: true) { $0.states },
                    ],
                    searchPrompt: "Filter streams or devices",
                    reloadKey: data.locations.count,
                    exportName: "biome-sync-locations"
                ), height: 330)
            }

            if !data.markerDays.isEmpty {
                SectionHeader("Per-Day Activity Markers", subtitle: "Number of synced streams that have a day marker, per day and originating device (last 120 days)", symbol: "calendar")
                LineChartView(data.markerDays, style: .bars, unit: .day)
                    .frame(height: 200)
                    .sensitive(.personal)
                    .card()
            }
            if !data.mergedDays.isEmpty {
                SectionHeader("Events Merged From Other Devices", subtitle: "By the \(data.mergedUnit == .hour ? "hour" : "day") the event was created on the originating device (the merge log keeps recent sessions only)", symbol: "arrow.down.left.circle")
                LineChartView(data.mergedDays, style: .bars, unit: data.mergedUnit)
                    .frame(height: 200)
                    .sensitive(.personal)
                    .card()
            }

            SectionHeader("Sync Sessions", subtitle: "Recent exchanges with other devices. Transport and reason are raw codes.", symbol: "clock.arrow.2.circlepath")
            if data.sessions.isEmpty {
                StatePlaceholder(title: "No Sessions Logged", symbol: "clock.arrow.2.circlepath", message: "The session log is empty.")
                    .frame(height: 140).card()
            } else {
                bordered(PagedTable(
                    rows: data.sessions,
                    columns: [
                        PagedColumn<SyncOverview.Session>("Started", id: "start", width: 150) { DossierDate.sortable($0.start) },
                        PagedColumn("Duration", id: "duration", width: 80, alignment: .trailing) { $0.duration.map { String(format: "%.2f s", $0) } ?? "" },
                        PagedColumn("Since Previous", id: "since", width: 110, alignment: .trailing, secondary: true) { $0.sincePrevious.map { Format.duration($0) } ?? "" },
                        PagedColumn("Messages", id: "messages", width: 76, alignment: .trailing) { countOrDash($0.messages) },
                        PagedColumn("Payload", id: "bytes", width: 86, alignment: .trailing) { $0.bytes > 0 ? Format.bytes($0.bytes) : "—" },
                        PagedColumn("Reciprocal", id: "reciprocal", width: 80) { $0.reciprocal ? "yes" : "no" },
                        PagedColumn("Transport", id: "transport", width: 76, alignment: .trailing, secondary: true) { $0.transport.map(String.init) ?? "" },
                        PagedColumn("Reason", id: "reason", width: 66, alignment: .trailing, secondary: true) { $0.reason.map(String.init) ?? "" },
                    ],
                    searchPrompt: nil,
                    reloadKey: data.sessions.count,
                    exportName: "biome-sync-sessions"
                ), height: min(300, CGFloat(data.sessions.count) * 26 + 70))
            }

            StoreFooter(SyncStore.url, note: "DevicePeer · CRDTLocation · CKAtom · AtomMergedLog · SyncSessionLog")
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
