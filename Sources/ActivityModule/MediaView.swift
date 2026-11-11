import DossierCore
import SwiftUI

/// (4) Media history: the Now Playing log of every device, top artists / titles, and the
/// non-music text that ends up stored as "titles".
struct MediaView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case history = "History", charts = "Top Charts", usage = "Media Usage"
        var id: String { rawValue }
    }

    @ObservedObject private var selection = ActivitySelection.shared
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @State private var mode: Mode = .history
    @State private var allDevices = true
    @State private var filter: ActivityStore.MediaFilter = .all
    @State private var search = ""
    @State private var selected: NowPlayingEvent?

    private var deviceKey: String? { allDevices ? nil : selection.deviceID }

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (mode, allDevices, filter, search, selected)
        VStack(spacing: 0) {
            HeaderStrip {
                StripControls {
                    DevicePicker(allowsAll: true, allSelected: $allDevices)
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                } caption: {
                    Text("What the system-wide Now Playing widget showed, on every synced device")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            switch mode {
            case .history: history
            case .charts: MediaChartsView(device: deviceKey, token: refreshToken, showFlagged: { filter = .flagged; mode = .history })
            case .usage: MediaUsageTable(token: refreshToken)
            }
            if let stream = Biome.stream(named: "Media.NowPlaying") {
                StoreFooter(stream.url, note: mode == .usage ? "App.MediaUsage · knowledgeC /app/mediaUsage" : "Media.NowPlaying · local + remote segments")
            }
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink else { return }
            if link.payload.hasPrefix("q:") {
                mode = .history; allDevices = true; filter = .all
                search = String(link.payload.dropFirst(2))
            } else if link.payload == "tab:charts" {
                mode = .charts
            } else if link.payload == "tab:usage" {
                mode = .usage
            } else if link.payload == "flagged" {
                mode = .history; filter = .flagged
            }
        }
    }

    private struct TableKey: Hashable { let device: String?; let filter: ActivityStore.MediaFilter; let token: Int }

    private var history: some View {
        let key = TableKey(device: deviceKey, filter: filter, token: refreshToken)
        let names = Dictionary(uniqueKeysWithValues: selection.devices.map { ($0.id, $0.name) })
        return PagedTable(
            columns: columns(names),
            searchPrompt: "Filter titles, artists, apps",
            reloadKey: key,
            exportName: "now-playing",
            emptyTitle: "No Now Playing Records",
            filter: $search,
            fetch: { request in
                try ActivityAccess.requireBiome()
                await ActivityStore.shared.sync(token: key.token)
                return await ActivityStore.shared.mediaPage(device: key.device, filter: key.filter, search: request.search, sort: request.sort, offset: request.offset, limit: request.limit).rows
            },
            count: { request in
                await ActivityStore.shared.mediaPage(device: key.device, filter: key.filter, search: request.search, sort: request.sort, offset: 0, limit: 0).total
            },
            onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
        ) {
            Picker("Show", selection: $filter) {
                ForEach(ActivityStore.MediaFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
        }
        .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let event = selected { inspector(event, names) }
        }
    }

    private func columns(_ names: [String: String]) -> [PagedColumn<NowPlayingEvent>] {
        [
            PagedColumn<NowPlayingEvent>("Time", id: "date", width: 150, min: 146) { DossierDate.sortable($0.date) },
            PagedColumn("State", id: "state", width: 78, min: 70) { $0.stateLabel }
                .cell { e in
                    HStack(spacing: 5) {
                        Image(systemName: e.state == 1 ? "play.fill" : (e.state == 2 ? "pause.fill" : (e.state == 3 ? "stop.fill" : "ellipsis")))
                            .imageScale(.small).foregroundStyle(e.state == 1 ? Color.green : Color.secondary).frame(width: 12)
                        Text(e.stateLabel).foregroundStyle(e.state == 1 ? .primary : .secondary)
                    }
                    .font(.callout)
                },
            PagedColumn("Title", id: "title", width: 280, min: 140, sensitivity: .sensitive) { $0.title }
                .cell { e in
                    HStack(spacing: 5) {
                        if e.flag != .none {
                            Image(systemName: "text.quote").imageScale(.small).foregroundStyle(.orange).help(e.flag.explanation)
                        }
                        Text(e.title.isEmpty ? "—" : e.title).lineLimit(1)
                    }
                    .font(.callout)
                },
            PagedColumn("Artist", id: "artist", width: 170, min: 110, sensitivity: .personal) { $0.artist },
            PagedColumn("Album", id: "album", width: 170, sensitivity: .personal, hiddenByDefault: true) { $0.album },
            PagedColumn("App", id: "app", width: 130, min: 110, sensitivity: .personal) { $0.appName }
                .cell { e in AppLabel(bundle: e.bundle, name: e.appName).font(.callout) },
            PagedColumn("Output Route", id: "route", width: 130, min: 100, sensitivity: .personal) { $0.route },
            PagedColumn("Device", id: "device", width: 130, sensitivity: .personal, secondary: true) { names[$0.deviceID] ?? "Unknown device" },
            PagedColumn("Kind", id: "kind", width: 64, sortable: false, secondary: true) { $0.kindLabel },
            PagedColumn("Length", id: "duration", width: 64, alignment: .trailing, secondary: true) { $0.duration > 0 ? Format.usage($0.duration) : "—" },
            PagedColumn("Flag", id: "flag", width: 130, secondary: true) { $0.flag.rawValue },
            PagedColumn("Bundle ID", id: "bundle", width: 220, sortable: false, sensitivity: .personal, monospaced: true, secondary: true, hiddenByDefault: true) { $0.bundle },
        ]
    }

    @ViewBuilder private func inspector(_ e: NowPlayingEvent, _ names: [String: String]) -> some View {
        InspectorPage(title: e.title.isEmpty ? "Untitled" : e.title, subtitle: e.artist.isEmpty ? e.appName : e.artist, sensitivity: .sensitive, onClose: { selected = nil }) {
            if e.flag != .none {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.quote").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.flag.rawValue).font(.callout.weight(.semibold))
                        Text(e.flag.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            KeyValueGrid([
                KeyValueItem("Title", e.title, sensitivity: .sensitive),
                KeyValueItem("Artist", e.artist.isEmpty ? nil : e.artist, sensitivity: .personal),
                KeyValueItem("Album", e.album.isEmpty ? nil : e.album, sensitivity: .personal),
                KeyValueItem("Genre", e.genre.isEmpty ? nil : e.genre),
                KeyValueItem("State", e.stateLabel),
                KeyValueItem("Time", DossierDate.medium(e.date) + " (" + DossierDate.relative(e.date) + ")"),
                KeyValueItem("Length", e.duration > 0 ? Format.usage(e.duration) : nil),
                KeyValueItem("Media type", e.mediaType.isEmpty ? nil : e.mediaType, monospaced: true),
                KeyValueItem("App", e.appName, sensitivity: .personal),
                KeyValueItem("Bundle ID", e.bundle, sensitivity: .personal, monospaced: true),
                KeyValueItem("Output route", e.route.isEmpty ? nil : e.route, sensitivity: .personal),
                KeyValueItem("Device", names[e.deviceID] ?? "Unknown device", sensitivity: .personal),
            ])
            AsyncContent(reloadKey: e.id) {
                await ActivityStore.shared.mediaPlays(device: nil).filter { $0.title == e.title && $0.artist == e.artist }
            } content: { plays in
                InspectorGroupTitle("Plays of this item (\(plays.count))")
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(plays.suffix(12).reversed().enumerated()), id: \.offset) { _, p in
                        HStack {
                            Text(DossierDate.sortable(p.date)).monospacedDigit()
                            Spacer()
                            Text(names[p.deviceID] ?? "").foregroundStyle(.secondary).sensitive(.personal)
                        }
                        .font(.caption)
                    }
                }
            }
            Text("Any app that publishes Now Playing information is recorded here — music players, but also browsers, video and messaging apps, whose page or clip titles are stored word for word.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Charts

struct MediaChartsView: View {
    let device: String?
    let token: Int
    let showFlagged: () -> Void

    private struct Key: Hashable { let device: String?; let token: Int }
    private struct Loaded: Sendable {
        let summary: MediaSummary
        let flagged: [MediaPlay]
    }

    var body: some View {
        AsyncContent(reloadKey: Key(device: device, token: token), emptyTitle: "No Media History", emptySymbol: "music.note") {
            try ActivityAccess.requireBiome()
            await ActivityStore.shared.sync(token: token)
            let summary = await ActivityStore.shared.mediaSummary(device: device)
            var seen = Set<String>()
            let flagged = await ActivityStore.shared.mediaPlays(device: device).reversed().filter { $0.flag != .none && seen.insert($0.key).inserted }
            return Loaded(summary: summary, flagged: Array(flagged.prefix(10)))
        } isEmpty: { $0.summary.events == 0 } content: { loaded in
            let s = loaded.summary
            ScrollPage {
                StatTileRow([
                    Stat("Plays", Format.compact(s.plays), caption: s.mirrored > 0 ? "\(Format.compact(s.mirrored)) mirrored plays merged" : "\(Format.compact(s.events)) raw events", symbol: "play.circle.fill", tint: .pink),
                    Stat("Titles", Format.count(s.distinctTitles), caption: "\(Format.count(s.distinctArtists)) artists", symbol: "music.note.list", tint: .purple),
                    Stat("Time Playing", Format.usage(s.listened), caption: device == nil ? "busiest device" : "this device", symbol: "headphones", tint: .blue),
                    Stat("Top Artist", s.topArtists.first?.label ?? "—", caption: s.topArtists.first.map { "\(Int($0.value)) plays" }, symbol: "music.mic", tint: .orange, sensitivity: .personal),
                    Stat("Flagged Text", Format.count(s.flaggedTitles), caption: "\(Format.count(s.flagged)) plays are not tracks", symbol: "text.quote", tint: .orange),
                    Stat("History", s.timeRange.map { "\(max(1, Int($0.upperBound.timeIntervalSince($0.lowerBound) / 86_400))) days" } ?? "—", caption: s.timeRange.map { "since " + DossierDate.day($0.lowerBound) }, symbol: "calendar", tint: .green),
                ])
                HStack(alignment: .top, spacing: Metrics.blockSpacing) {
                    TitledCard("Top Artists", subtitle: "Plays per artist (flagged items excluded)", symbol: "music.mic") {
                        BarChartView(s.topArtists, tint: .pink, labelSensitivity: .personal)
                    }
                    TitledCard("Top Titles", subtitle: "Most played tracks", symbol: "music.note") {
                        BarChartView(s.topTitles, tint: .purple, labelSensitivity: .personal)
                    }
                }
                HStack(alignment: .top, spacing: Metrics.blockSpacing) {
                    TitledCard("Players", subtitle: "Apps that published Now Playing info", symbol: "app.badge") {
                        let maxPlays = Double(s.topApps.first?.plays ?? 1)
                        VStack(spacing: 0) {
                            ForEach(Array(s.topApps.enumerated()), id: \.offset) { i, app in
                                RankedAppRow(rank: i + 1, bundle: app.bundle, name: app.name, fraction: Double(app.plays) / maxPlays, value: Format.count(app.plays), tint: .pink)
                            }
                        }
                    }
                    TitledCard("Output Routes", subtitle: "Where the audio went (playing events)", symbol: "hifispeaker") {
                        BarChartView(s.topRoutes, tint: .teal, labelSensitivity: .personal)
                    }
                }
                TitledCard("When You Listen", subtitle: "Plays by weekday and hour", symbol: "square.grid.3x3.fill") {
                    TimelineHeatmap(.weekdayByHour(bins: s.hours), tint: .pink)
                }
                if !loaded.flagged.isEmpty {
                    TitledCard(title: "Non-Music Text Captured as Titles", subtitle: "Latest examples. These are page, video or message titles stored verbatim in the media history.", symbol: "text.quote") {
                        Button("Show All Flagged", action: showFlagged).controlSize(.small)
                    } content: {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(loaded.flagged.enumerated()), id: \.offset) { _, p in
                                HStack(spacing: 8) {
                                    AppIcon(bundle: p.bundle, size: 16)
                                    Text(p.title).font(.callout).lineLimit(1).sensitive(.sensitive)
                                    Spacer(minLength: 8)
                                    TagLabel(p.flag.rawValue, tint: .orange)
                                    Text(DossierDate.short(p.date)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Media usage sessions

struct MediaUsageTable: View {
    let token: Int

    var body: some View {
        AsyncContent(reloadKey: token, emptyTitle: "No Media Usage Sessions", emptySymbol: "play.rectangle") {
            await ActivityStore.shared.sync(token: token)
            return await ActivityStore.shared.media().usage
        } isEmpty: { $0.isEmpty } content: { rows in
            VStack(spacing: 0) {
                ExplainerText("Screen Time's record of apps playing media on this Mac: Biome App.MediaUsage start / stop events paired by session id, and the same intervals as stored in knowledgeC.")
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                PagedTable(
                    columns: [
                        PagedColumn<MediaUsageSession>("Start", id: "start", width: 150, min: 146) { DossierDate.sortable($0.start) },
                        PagedColumn("End", id: "end", width: 150, min: 146) { DossierDate.sortable($0.end) },
                        PagedColumn("Duration", id: "duration", width: 80, min: 70, alignment: .trailing) { row in row.end.map { Format.usage($0.timeIntervalSince(row.start)) } ?? "open" },
                        PagedColumn("App", id: "app", width: 200, min: 140, sensitivity: .personal) { $0.name }
                            .cell { row in AppLabel(bundle: row.bundle, name: row.name).font(.callout) },
                        PagedColumn("Source", id: "source", width: 190, min: 150, secondary: true) { $0.source },
                        PagedColumn("URL", id: "url", width: 260, min: 120, sensitivity: .sensitive, secondary: true) { $0.url },
                        PagedColumn("Bundle ID", id: "bundle", width: 220, sensitivity: .personal, monospaced: true, secondary: true, hiddenByDefault: true) { $0.bundle },
                    ],
                    searchPrompt: "Filter apps",
                    reloadKey: rows.count,
                    exportName: "media-usage",
                    fetch: { request in
                        MemoryPager.page(rows, request, matches: { r, q in r.name.localizedCaseInsensitiveContains(q) || r.bundle.localizedCaseInsensitiveContains(q) || r.source.localizedCaseInsensitiveContains(q) }, sorters: [
                            "start": { $0.start < $1.start },
                            "end": { ($0.end ?? .distantFuture) < ($1.end ?? .distantFuture) },
                            "duration": { ($0.end ?? $0.start).timeIntervalSince($0.start) < ($1.end ?? $1.start).timeIntervalSince($1.start) },
                            "app": { $0.name.lowercased() < $1.name.lowercased() },
                            "source": { $0.source < $1.source },
                            "url": { $0.url < $1.url },
                            "bundle": { $0.bundle < $1.bundle },
                        ])
                    },
                    count: { request in MemoryPager.count(rows, request, matches: { r, q in r.name.localizedCaseInsensitiveContains(q) || r.bundle.localizedCaseInsensitiveContains(q) || r.source.localizedCaseInsensitiveContains(q) }) }
                )
            }
        }
    }
}
