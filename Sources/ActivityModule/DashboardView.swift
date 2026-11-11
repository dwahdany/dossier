import Charts
import DossierCore
import SwiftUI

/// (1) Dashboard: foreground time per app, daily totals, weekday × hour heatmap and the
/// daily rhythm (first / last activity) of one device.
struct DashboardView: View {
    @ObservedObject private var selection = ActivitySelection.shared
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @State private var topN = 12

    private struct Loaded: Sendable {
        let aggregate: FocusAggregate
        let focus: DeviceFocus
        let device: ActivityDevice?
    }

    private struct Key: Hashable { let device: String; let range: ActivityRange; let token: Int }

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = topN
        VStack(spacing: 0) {
            HeaderStrip {
                StripControls(captionTrailing: false) {
                    DevicePicker()
                    RangePicker()
                } caption: {
                    DeviceCaption(device: selection.device).sensitive(.personal)
                }
            }
            let key = Key(device: selection.deviceID, range: selection.range, token: refreshToken)
            AsyncContent(reloadKey: key, emptyTitle: "No Activity Recorded", emptySymbol: "chart.bar.xaxis") {
                await ActivityStore.shared.sync(token: key.token)
                try ActivityAccess.requireBiome()
                async let aggregate = ActivityStore.shared.aggregate(device: key.device, range: key.range)
                async let focus = ActivityStore.shared.focus(key.device)
                async let device = ActivityStore.shared.device(key.device)
                return await Loaded(aggregate: aggregate, focus: focus, device: device)
            } isEmpty: { $0.aggregate.apps.isEmpty } content: { loaded in
                page(loaded)
            }
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            if let link = deepLink { selection.apply(payload: link.payload) }
        }
    }

    @ViewBuilder private func page(_ loaded: Loaded) -> some View {
        let agg = loaded.aggregate
        ScrollPage {
            StatTileRow(stats(loaded))

            TitledCard(title: "Foreground Time per App", subtitle: "Time each app was frontmost, from paired App.InFocus start / stop events", symbol: "chart.bar.fill") {
                Picker("Show", selection: $topN) {
                    Text("Top 8").tag(8); Text("Top 12").tag(12); Text("Top 20").tag(20); Text("Top 30").tag(30)
                }
                .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
            } content: {
                BarChartView(agg.apps.prefix(topN).map { ChartBar(uniqueLabel($0, in: agg.apps), $0.total) }, labelSensitivity: .personal, valueLabel: Format.usage)
            }

            TitledCard("Daily Totals", subtitle: "Foreground time per calendar day (sessions are split at midnight)", symbol: "calendar") {
                LineChartView(agg.days.map { ChartPoint($0.day, $0.total / 3600) }, style: .bars, unit: .day, valueLabel: { String(format: $0 < 10 ? "%.1f h" : "%.0f h", $0) })
                    .frame(height: 190)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Metrics.blockSpacing) {
                    heatmapCard(agg)
                    rhythmCard(agg).frame(minWidth: 420)
                }
                VStack(alignment: .leading, spacing: Metrics.blockSpacing) {
                    heatmapCard(agg)
                    rhythmCard(agg)
                }
            }

            pairingNote(loaded)
            if let stream = Biome.stream(named: "App.InFocus") {
                StoreFooter(stream.url, note: "App.InFocus · \(loaded.device?.isLocal == false ? "remote" : "local") segments")
            }
        }
    }

    /// Two apps on different platforms can share a display name; chart labels must be unique.
    private func uniqueLabel(_ row: AppUsageRow, in rows: [AppUsageRow]) -> String {
        rows.contains { $0.name == row.name && $0.bundle != row.bundle } ? "\(row.name) (\(row.bundle))" : row.name
    }

    private func stats(_ loaded: Loaded) -> [Stat] {
        let agg = loaded.aggregate
        let dayCount = max(1, agg.days.count)
        var out = [
            Stat("Foreground Time", Format.usage(agg.total), caption: "\(Format.usage(agg.total / Double(dayCount))) per active day", symbol: "clock.fill", tint: .blue),
            Stat("Apps Used", Format.count(agg.apps.count), caption: "\(Format.compact(agg.activations)) activations", symbol: "square.grid.2x2.fill", tint: .purple),
            Stat("Most Used", agg.apps.first?.name ?? "—", caption: agg.apps.first.map { Format.usage($0.total) + " · " + Format.percent($0.total / max(agg.total, 1), digits: 0) }, symbol: "star.fill", tint: .orange, sensitivity: .personal),
            Stat("Days Covered", Format.count(agg.days.count), caption: agg.range.map { DossierDate.day($0.lowerBound) + " – " + DossierDate.day($0.upperBound) }, symbol: "calendar", tint: .green),
        ]
        if agg.systemTotal > 0 {
            out.append(Stat(loaded.device?.platform.contains("Mac") == true ? "Lock Screen" : "Home / Lock Screen", Format.usage(agg.systemTotal), caption: "not counted as app time", symbol: "lock.fill", tint: .gray))
        }
        out.append(Stat("Typical Session", Format.usage(agg.medianSession), caption: agg.capped > 0 ? "median · \(agg.capped) capped at 4 h" : "median time in front", symbol: "timer", tint: .teal))
        return out
    }

    private func heatmapCard(_ agg: FocusAggregate) -> some View {
        TitledCard("When You Are Active", subtitle: "Foreground time by weekday and hour of day (local time)", symbol: "square.grid.3x3.fill") {
            TimelineHeatmap(.weekdayByHour(bins: agg.heat), tint: .blue, valueLabel: Format.usage)
        }
    }

    private func rhythmCard(_ agg: FocusAggregate) -> some View {
        TitledCard("Daily Rhythm", subtitle: "First and last app activity of each day. A day runs 04:00 – 04:00 so late nights stay with their evening.", symbol: "sunrise.fill") {
            RhythmChart(days: Array(agg.rhythm.suffix(60))).frame(height: 240)
        }
    }

    @ViewBuilder private func pairingNote(_ loaded: Loaded) -> some View {
        let f = loaded.focus
        VStack(alignment: .leading, spacing: 6) {
            Label("How these numbers are derived", systemImage: "info.circle").font(.subheadline.weight(.semibold))
            ExplainerText("""
            The system logs an event every time an app comes to the front and another when it leaves (Biome stream App.InFocus). \
            Dossier pairs each start with the next stop of the same app. If a stop is missing, the session ends when the next app starts; \
            a session can never exceed 4 hours (the device slept without logging a stop)\(loaded.device?.isLocal == true ? "; on this Mac sessions are additionally cut wherever knowledgeC recorded the display as off" : ""). \
            Sessions shorter than half a second are ignored, and the lock screen, home screen and watch face are tracked separately.
            """)
            Text("\(Format.count(f.eventCount)) events → \(Format.count(f.sessions.count)) sessions · \(Format.count(f.impliedStops)) implied stops · \(Format.count(f.unmatchedStops)) unmatched stops · \(Format.count(f.cappedSessions)) capped · \(Format.count(f.droppedFlickers)) sub-0.5 s flickers dropped")
                .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
        }
    }
}

/// Range bars from first to last activity per logical day; hour axis runs 04:00 → 04:00.
struct RhythmChart: View {
    let days: [DayStat]

    var body: some View {
        if days.isEmpty {
            Text("No data").font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 80)
        } else {
            Chart(days) { day in
                if let first = day.first, let last = day.last {
                    BarMark(
                        x: .value("Day", day.day, unit: .day),
                        yStart: .value("First", first),
                        yEnd: .value("Last", max(last, first + 0.15)),
                        width: .ratio(0.55)
                    )
                    .foregroundStyle(Color.orange.opacity(0.35))
                    .cornerRadius(3)
                    PointMark(x: .value("Day", day.day, unit: .day), y: .value("First", first))
                        .foregroundStyle(.orange).symbolSize(28)
                    PointMark(x: .value("Day", day.day, unit: .day), y: .value("Last", last))
                        .foregroundStyle(.indigo).symbolSize(28)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false, reversed: true))
            .chartYScale(domain: 4...28)
            .chartYAxis {
                AxisMarks(values: [4, 8, 12, 16, 20, 24, 28]) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let h = value.as(Double.self) { Text(Format.clock(h)).monospacedDigit() }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartLegend(.hidden)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 10) {
                    legend("First activity", .orange)
                    legend("Last activity", .indigo)
                }
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.leading, 2).offset(y: -16)
            }
            .padding(.top, 16)
        }
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(text) }
    }
}
