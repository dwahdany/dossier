import SwiftUI
import Charts
import DossierCore

/// (1) Overview — totals by app and source device, per-month chart, weekday × hour
/// heatmap and direction split, over the Siri Remembers store.
struct CommsOverviewView: View {
    private struct Loaded: Sendable {
        var overview: RemembersOverview
        var streams: [StreamStat]
        var sources: [SourceLine]
    }

    struct SourceLine: Identifiable, Sendable {
        var id: String { name }
        var name: String
        var what: String
        var count: String
        var availability: Availability
    }

    @Environment(\.refreshToken) private var refreshToken

    var body: some View {
        AsyncContent(reloadKey: refreshToken) {
            async let overview = RemembersStore.overview()
            async let streams = RemembersStore.streamStats()
            async let sources = Self.sources()
            return try await Loaded(overview: overview, streams: streams, sources: sources)
        } content: { loaded in
            page(loaded)
        }
    }

    // MARK: Page

    @ViewBuilder private func page(_ loaded: Loaded) -> some View {
        let o = loaded.overview
        ScrollPage {
            ExplainerCard(
                symbol: "bubble.left.and.bubble.right.fill",
                title: "Who the system knows you talk to",
                text: "Messaging and phone apps “donate” every message and call to Siri so it can suggest contacts and answer questions like “what did I miss”. Those donations are collected on each of your devices, synced to this Mac through Biome and kept for about a year in the Siri Remembers store. It records who, when, which app and which conversation — the message text itself is kept only briefly, in a different store (see Retained Content).")

            StatTileRow([
                Stat("Interactions", Format.compact(o.total), caption: DossierDate.range(o.range), symbol: "tray.full"),
                Stat("Messages", Format.compact(o.messages), caption: "\(o.apps.filter { $0.messages > 0 }.count) apps", symbol: "text.bubble", tint: .blue),
                Stat("Calls", Format.compact(o.calls), caption: o.callSeconds > 0 ? "\(Format.duration(o.callSeconds)) talk time" : nil, symbol: "phone", tint: .green),
                Stat("Handles", Format.compact(o.handleCount), caption: "phone numbers, e-mails, app ids", symbol: "person.2", tint: .purple),
                Stat("Conversations", Format.compact(o.conversationCount), caption: "distinct titles", symbol: "bubble.left.and.text.bubble.right", tint: .orange),
                Stat("Incoming", Format.percent(Double(o.incoming) / Double(max(o.incoming + o.outgoing, 1)), digits: 0), caption: "\(Format.compact(o.incoming)) of \(Format.compact(o.incoming + o.outgoing))", symbol: "arrow.down.left", tint: .teal),
                Stat("Source Devices", Format.count(o.devices.count), caption: o.devices.first?.name, symbol: "laptopcomputer.and.iphone", tint: .indigo, sensitivity: .personal),
            ])

            SectionHeader("Messages & Calls per Month", subtitle: "Incoming and outgoing interactions the system remembers", symbol: "calendar")
            monthChart(o).card()

            // Side by side while the heatmap keeps readable cells; stacked below that
            // (the minimum window leaves it under 300 pt next to the direction card).
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Metrics.blockSpacing) {
                    heatmapBlock(o).frame(minWidth: 420)
                    directionBlock(o).frame(width: 330)
                }
                VStack(alignment: .leading, spacing: Metrics.blockSpacing) {
                    heatmapBlock(o)
                    directionBlock(o)
                }
            }

            SectionHeader("By App", subtitle: "Messages and calls per donating app", symbol: "app.badge")
            appChart(o).card()

            SectionHeader("By Source Device", subtitle: "Where each interaction was recorded before it was synced here", symbol: "laptopcomputer.and.iphone")
            deviceList(o).card()

            SectionHeader("Sources", subtitle: "Every store this module reads", symbol: "externaldrive")
            sourceList(loaded).card()

            StoreFooter(CommsPaths.remembersView, note: "interactions · entities · interactionEntities")
        }
    }

    // MARK: Charts

    private struct MonthPoint: Identifiable {
        var id: String { "\(month.timeIntervalSince1970)|\(series)" }
        let month: Date
        let series: String
        let count: Int
    }

    private static let seriesOrder = ["Messages in", "Messages out", "Calls in", "Calls out"]
    private static let seriesColors: [Color] = [.blue, .green, .orange, .purple]

    private func monthPoints(_ o: RemembersOverview) -> [MonthPoint] {
        var sums: [String: MonthPoint] = [:]
        for bucket in o.months where bucket.direction != .unspecified {
            let series = "\(bucket.kind) \(bucket.direction == .incoming ? "in" : "out")"
            let key = "\(bucket.month.timeIntervalSince1970)|\(series)"
            let existing = sums[key]?.count ?? 0
            sums[key] = MonthPoint(month: bucket.month, series: series, count: existing + bucket.count)
        }
        return sums.values.sorted { ($0.month, Self.seriesOrder.firstIndex(of: $0.series) ?? 0) < ($1.month, Self.seriesOrder.firstIndex(of: $1.series) ?? 0) }
    }

    private func monthChart(_ o: RemembersOverview) -> some View {
        Chart(monthPoints(o)) { point in
            BarMark(x: .value("Month", point.month, unit: .month), y: .value("Interactions", point.count))
                .foregroundStyle(by: .value("Kind", point.series))
        }
        .chartForegroundStyleScale(domain: Self.seriesOrder, range: Self.seriesColors)
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits), centered: true)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let v = value.as(Int.self) { Text(Format.compact(v)).font(.caption2) } }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 220)
    }

    private struct AppPoint: Identifiable {
        var id: String { "\(app)|\(series)" }
        let app: String
        let series: String
        let count: Int
    }

    private func appChart(_ o: RemembersOverview) -> some View {
        let apps = Array(o.apps.filter { $0.messages + $0.calls > 0 }.prefix(14))
        var points: [AppPoint] = []
        for app in apps {
            let name = AppNames.name(app.bundle)
            points.append(AppPoint(app: name, series: "Messages in", count: app.messagesIn))
            points.append(AppPoint(app: name, series: "Messages out", count: app.messagesOut))
            points.append(AppPoint(app: name, series: "Calls in", count: app.callsIn))
            points.append(AppPoint(app: name, series: "Calls out", count: app.callsOut))
        }
        let totals = Dictionary(apps.map { (AppNames.name($0.bundle), $0.messages + $0.calls) }, uniquingKeysWith: +)
        return Chart {
            ForEach(points) { point in
                BarMark(x: .value("Interactions", point.count), y: .value("App", point.app))
                    .foregroundStyle(by: .value("Kind", point.series))
            }
            ForEach(apps) { app in
                let name = AppNames.name(app.bundle)
                BarMark(x: .value("Interactions", 0), y: .value("App", name))
                    .foregroundStyle(.clear)
                    .annotation(position: .trailing, alignment: .leading, spacing: CGFloat(4)) {
                        Text(Format.count(totals[name] ?? 0)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
            }
        }
        .chartForegroundStyleScale(domain: Self.seriesOrder, range: Self.seriesColors)
        .chartYScale(domain: apps.map { AppNames.name($0.bundle) })
        .chartXAxis { AxisMarks(position: .bottom) { value in
            AxisGridLine().foregroundStyle(.quaternary)
            AxisValueLabel { if let v = value.as(Int.self) { Text(Format.compact(v)).font(.caption2) } }
        } }
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .leading) { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label).font(.caption).lineLimit(1).frame(maxWidth: 170, alignment: .trailing).sensitive(.personal)
                    }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: CGFloat(apps.count) * 26 + 54)
    }

    private func heatmapBlock(_ o: RemembersOverview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("When You Communicate", subtitle: "Weekday × hour of day, local time", symbol: "clock")
            CommsHeatmap(.weekdayByHour(bins: o.heat))
                .card()
        }
    }

    private func directionBlock(_ o: RemembersOverview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Direction", subtitle: "Who starts the conversation", symbol: "arrow.left.arrow.right")
            directionCard(o).card()
        }
    }

    // MARK: Direction

    private func directionCard(_ o: RemembersOverview) -> some View {
        let messagesIn = o.apps.reduce(0) { $0 + $1.messagesIn }
        let messagesOut = o.apps.reduce(0) { $0 + $1.messagesOut }
        let callsIn = o.apps.reduce(0) { $0 + $1.callsIn }
        let callsOut = o.apps.reduce(0) { $0 + $1.callsOut }
        return VStack(alignment: .leading, spacing: 14) {
            SplitBar(title: "Messages", incoming: messagesIn, outgoing: messagesOut)
            SplitBar(title: "Calls", incoming: callsIn, outgoing: callsOut)
            Text("“Incoming” means someone else wrote or called; “outgoing” means you did. Many apps only donate what arrives as a notification, so incoming messages are over-represented.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Lists

    private func deviceList(_ o: RemembersOverview) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(o.devices.enumerated()), id: \.element.id) { index, device in
                if index > 0 { Divider().padding(.vertical, 6) }
                HStack(spacing: 10) {
                    Image(systemName: device.name == "This Mac" || device.detail.contains("Mac") ? "laptopcomputer" : "iphone")
                        .font(.title3).foregroundStyle(.secondary).frame(width: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(.callout.weight(.medium)).sensitive(.personal)
                        Text(device.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Format.count(device.count)).font(.callout).monospacedDigit()
                        Text("\(DossierDate.day(device.first)) – \(DossierDate.day(device.last))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if o.devices.isEmpty {
                Text("No device information in this store.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func sourceList(_ loaded: Loaded) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(loaded.sources.enumerated()), id: \.element.id) { index, source in
                if index > 0 { Divider().padding(.vertical, 6) }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(color(source.availability)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.name).font(.callout.weight(.medium))
                        Text(source.what).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Text(source.availability.isAvailable ? source.count : source.availability.label)
                        .font(.callout).monospacedDigit().foregroundStyle(source.availability.isAvailable ? .primary : .secondary)
                }
            }
            if !loaded.streams.isEmpty {
                Divider().padding(.vertical, 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Biome streams behind the view").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(loaded.streams) { stream in
                        HStack {
                            Text(stream.name).font(.caption.monospaced())
                            Spacer()
                            Text("\(Format.count(stream.records)) records · \(Format.bytes(stream.bytes)) · \(stream.devices.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit().sensitive(.personal)
                        }
                    }
                }
            }
        }
    }

    private func color(_ availability: Availability) -> Color {
        switch availability {
        case .available: return .green
        case .missing: return .gray
        case .inaccessible: return .orange
        }
    }

    // MARK: Sources

    private static func sources() async -> [SourceLine] {
        var out: [SourceLine] = []
        func count(_ url: URL?, _ sql: String) async -> String {
            guard let db = await CommsDB.openIfAvailable(url), let n = await db.count(sql) else { return "—" }
            return Format.count(n)
        }
        out.append(SourceLine(
            name: "Siri Remembers", what: "A year of message and call metadata donated by apps on all your devices.",
            count: await count(CommsPaths.remembersView, "SELECT count(*) FROM interactions") + " interactions",
            availability: Paths.probe(CommsPaths.remembersView)))
        out.append(SourceLine(
            name: "knowledgeC intents", what: "The last weeks of intents synced from your other devices — including the text of some messages.",
            count: await count(Paths.knowledgeC, "SELECT count(*) FROM ZOBJECT WHERE ZSTREAMNAME = '/app/intents'") + " intents",
            availability: Paths.probe(Paths.knowledgeC)))
        out.append(SourceLine(
            name: "interactionC", what: "People you exchange mail and calendar invitations with on this Mac, with counters and meeting keywords.",
            count: await count(Paths.interactionC, "SELECT count(*) FROM ZCONTACTS") + " contacts",
            availability: Paths.probe(Paths.interactionC)))
        out.append(SourceLine(
            name: "Call History", what: "This Mac's log of phone and FaceTime calls.",
            count: await count(CommsPaths.callHistory, "SELECT count(*) FROM ZCALLRECORD") + " calls",
            availability: Paths.probe(CommsPaths.callHistory)))
        out.append(SourceLine(
            name: "CoreRecents", what: "Recently used addressees remembered for auto-completion in Mail, Calendar and Wallet.",
            count: await count(CommsPaths.recentsDB, "SELECT count(*) FROM contacts") + " addresses",
            availability: Paths.probe(CommsPaths.recentsDB)))
        let kvsRows = (try? await KVSStore.rows())?.count
        out.append(SourceLine(
            name: "iCloud Key-Value Cache", what: "Settings synced through iCloud: mail recents, VIP senders, favourite and blocked contacts.",
            count: kvsRows.map { Format.count($0) + " entries" } ?? "—",
            availability: Paths.probe(CommsPaths.kvsDirectory)))
        return out
    }
}

/// Incoming / outgoing proportion bar with counts.
struct SplitBar: View {
    let title: String
    let incoming: Int
    let outgoing: Int

    var body: some View {
        let total = max(incoming + outgoing, 1)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text(Format.count(incoming + outgoing)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(CommDirection.incoming.tint.gradient)
                        .frame(width: max(2, (proxy.size.width - 2) * CGFloat(incoming) / CGFloat(total)))
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(CommDirection.outgoing.tint.gradient)
                }
            }
            .frame(height: 12)
            HStack(spacing: 4) {
                Image(systemName: CommDirection.incoming.symbol).imageScale(.small).foregroundStyle(CommDirection.incoming.tint)
                Text("\(Format.count(incoming)) in · \(Format.percent(Double(incoming) / Double(total), digits: 0))").font(.caption).monospacedDigit()
                Spacer()
                Text("\(Format.count(outgoing)) out · \(Format.percent(Double(outgoing) / Double(total), digits: 0))").font(.caption).monospacedDigit()
                Image(systemName: CommDirection.outgoing.symbol).imageScale(.small).foregroundStyle(CommDirection.outgoing.tint)
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// Weekday × hour heatmap that spans the width it is given and maps colour through a
/// perceptual light-to-dark ramp between the 5th and 95th percentile of the non-empty
/// cells, so a single outlier hour does not flatten everything else into one shade.
struct CommsHeatmap: View {
    private let data: HeatmapData
    private let low: Double
    private let high: Double
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered: (row: Int, hour: Int)?

    private let gap: CGFloat = 2
    private let labelWidth: CGFloat = 40

    init(_ data: HeatmapData) {
        self.data = data
        let values = data.values.flatMap { $0 }.filter { $0 > 0 }.sorted()
        func percentile(_ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let position = p * Double(values.count - 1)
            let lower = Int(position.rounded(.down)), upper = min(values.count - 1, lower + 1)
            return values[lower] + (values[upper] - values[lower]) * (position - Double(lower))
        }
        low = percentile(0.05)
        high = percentile(0.95)
    }

    /// Sequential blue ramp (sRGB stops, roughly even lightness steps). Low values sit
    /// near the card background in either appearance, high values contrast with it.
    private static let lightStops: [(Double, Double, Double)] = [
        (0.87, 0.92, 0.97), (0.62, 0.79, 0.90), (0.31, 0.60, 0.82), (0.13, 0.41, 0.69), (0.03, 0.19, 0.42),
    ]
    private static let darkStops: [(Double, Double, Double)] = [
        (0.10, 0.19, 0.30), (0.12, 0.33, 0.53), (0.20, 0.53, 0.78), (0.47, 0.75, 0.94), (0.86, 0.95, 1.00),
    ]

    private func ramp(_ t: Double) -> Color {
        let stops = colorScheme == .dark ? Self.darkStops : Self.lightStops
        let x = min(max(t, 0), 1) * Double(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        let f = x - Double(i)
        let a = stops[i], b = stops[i + 1]
        return Color(.sRGB, red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }

    private func color(_ value: Double) -> Color {
        guard value > 0 else { return Color.primary.opacity(0.06) }
        guard high > low else { return ramp(0.6) }
        return ramp((value - low) / (high - low))
    }

    private func value(_ row: Int, _ hour: Int) -> Double {
        row < data.values.count && hour < data.values[row].count ? data.values[row][hour] : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            ForEach(Array(data.rowLabels.enumerated()), id: \.offset) { row, label in
                HStack(spacing: gap) {
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .trailing).padding(.trailing, 4)
                    ForEach(0..<24, id: \.self) { hour in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color(value(row, hour)))
                            .frame(maxWidth: .infinity)
                            .frame(height: 20)
                            .onHover { inside in
                                if inside { hovered = (row, hour) } else if hovered?.row == row, hovered?.hour == hour { hovered = nil }
                            }
                            .help("\(label) \(String(format: "%02d:00", hour)) — \(Format.count(Int(value(row, hour))))")
                    }
                }
            }
            HStack(spacing: gap) {
                Color.clear.frame(width: labelWidth + 4, height: 1)
                ForEach(0..<24, id: \.self) { hour in
                    // The label may be wider than one cell; it must not wrap or widen its column.
                    Color.clear.frame(maxWidth: .infinity).frame(height: 11)
                        .overlay(alignment: .leading) {
                            if hour % 3 == 0 {
                                Text(String(format: "%02d", hour))
                                    .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                            }
                        }
                }
            }
            HStack(spacing: 6) {
                Color.clear.frame(width: labelWidth + 4, height: 1)
                if let hovered {
                    Text("\(data.rowLabels[hovered.row]) \(String(format: "%02d:00", hovered.hour)) · \(Format.count(Int(value(hovered.row, hovered.hour))))")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("≤ \(Format.count(Int(low.rounded())))").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    HStack(spacing: 1) {
                        ForEach(0..<9, id: \.self) { i in
                            Rectangle().fill(ramp(Double(i) / 8)).frame(width: 12, height: 10)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    ViewThatFits(in: .horizontal) {
                        Text("≥ \(Format.count(Int(high.rounded()))) per hour · peak \(Format.count(Int(data.maxValue)))").lineLimit(1)
                        Text("≥ \(Format.count(Int(high.rounded()))) per hour").lineLimit(1)
                        Text("≥ \(Format.count(Int(high.rounded())))").lineLimit(1)
                    }
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .frame(height: 14)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
