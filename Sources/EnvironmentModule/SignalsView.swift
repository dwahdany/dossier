import SwiftUI
import Charts
import DossierCore

/// Section 6 — notification logs (who notifies you, when) and "discoverability" feature
/// signals (which system features you have used).
struct SignalsView: View {
    enum Log: String, CaseIterable, Identifiable {
        case notifications = "Notifications", signals = "Feature Signals"
        var id: String { rawValue }
    }

    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @State private var log: Log = .notifications
    @State private var filter = ""

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (log, filter)
        let token = refreshToken
        AsyncContent(reloadKey: token) {
            try await SignalsLoader.load(token: token)
        } isEmpty: { $0.notifications.isEmpty && $0.signals.isEmpty && $0.knowledgeTotal == 0 } content: { data in
            VStack(spacing: 0) {
                ScrollPage { page(data) }
                StoreFooter(EnvPaths.stream("Notification.Usage"), note: "Notification.Delivery · Discoverability.Signals · knowledgeC /notification/usage")
            }
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let payload = deepLink?.payload, !payload.isEmpty else { return }
            if payload.hasPrefix("signal:") { log = .signals; filter = String(payload.dropFirst(7)) } else { log = .notifications; filter = payload }
        }
    }

    @ViewBuilder private func page(_ data: SignalsData) -> some View {
        Explainer("The notification system logs every notification an app posts and how you dealt with it; CoreDuet keeps a second copy. “Discoverability signals” are small markers apps leave when you use a feature (taking a screenshot, opening Notification Centre, using Universal Control) so the Tips system stops suggesting what you already know.")
        let top = data.perApp.first
        EnvTiles([
            Stat("Notifications", Format.compact(data.distinctCount), caption: DossierDate.range(data.notificationRange), symbol: "bell.badge", tint: .red),
            Stat("Apps Notifying", Format.count(data.perApp.count), caption: "\(Format.count(data.usageCount)) usage + \(Format.count(data.deliveryCount)) delivery log entries", symbol: "app.badge", tint: .orange),
            Stat("Most Active", top.map { EnvFormat.appName($0.bundle) } ?? "—", caption: top.map { "\($0.distinct) notifications" }, symbol: "flame", tint: .pink, sensitivity: .personal),
            Stat("Feature Signals", Format.compact(data.signals.count), caption: "\(data.perSignal.count) distinct features", symbol: "sparkles", tint: .purple),
        ])

        HStack(alignment: .top, spacing: Metrics.blockSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Notifications per App", subtitle: "Two logs of the same notifications, side by side", symbol: "bell")
                NotificationAppsChart(rows: Array(data.perApp.prefix(12))).card()
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("CoreDuet Copy", subtitle: "knowledgeC /notification/usage · \(Format.count(data.knowledgeTotal)) events", symbol: "externaldrive")
                let shown = Array(data.knowledgePerApp.prefix(12))
                let names = EnvFormat.appNames(shown.map(\.bundle))
                BarChartView(shown.map { ChartBar(names[$0.bundle] ?? $0.bundle, Double($0.count)) }, tint: .orange, labelSensitivity: .personal).card()
            }
        }

        SectionHeader("Notification Timeline", subtitle: "Log entries per day in each of the two logs", symbol: "calendar")
        LineChartView(data.notificationsPerDay, style: .bars, unit: .day).frame(height: 190).card()

        SectionHeader("When Notifications Arrive", subtitle: "Weekday × hour of day", symbol: "clock")
        TimelineHeatmap(.weekdayByHour(data.notifications.map(\.date)), tint: .red).card()

        HStack(alignment: .top, spacing: Metrics.blockSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Feature Signals", subtitle: "How often each marker was recorded", symbol: "sparkles")
                BarChartView(data.perSignal.prefix(12).map { ChartBar($0.identifier.replacingOccurrences(of: "com.apple.", with: ""), Double($0.count)) }, tint: .purple).card()
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Signals per Day", subtitle: DossierDate.range(data.signalRange), symbol: "calendar")
                LineChartView(data.signalsPerDay, style: .bars, unit: .day, tint: .purple).frame(height: 190).card()
            }
        }

        SectionHeader("Event Log", symbol: "list.bullet") {
            Picker("Log", selection: $log) {
                ForEach(Log.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        switch log {
        case .notifications:
            PagedTable(
                rows: data.notifications,
                columns: [
                    PagedColumn<NotificationEvent>("Time", id: "date", width: 150) { DossierDate.sortable($0.date) },
                    PagedColumn("App", id: "app", width: 200, sensitivity: .personal) { EnvFormat.appName($0.bundle) }.cell { row in
                        AppLabel(bundle: EnvFormat.bundleID(row.bundle), name: EnvFormat.appName(row.bundle)).font(.callout)
                    },
                    PagedColumn("Bundle ID", id: "bundle", width: 260, sensitivity: .personal, monospaced: true, secondary: true, hiddenByDefault: true) { $0.bundle },
                    PagedColumn("Log", id: "stream", width: 80) { $0.stream },
                    PagedColumn("Event", id: "detail", width: 110, secondary: true) { $0.detail },
                    PagedColumn("Identifier", id: "identifier", width: 330, sensitivity: .personal, monospaced: true, secondary: true) { $0.identifier },
                ].readableMinimums(),
                searchPrompt: "Filter notifications",
                reloadKey: AnyHashable(data.notifications.count),
                exportName: "notification-log",
                emptyTitle: "No Notifications Logged",
                filter: $filter
            )
            .tableCard(height: 360)
        case .signals:
            PagedTable(
                rows: data.signals,
                columns: [
                    PagedColumn<FeatureSignal>("Time", id: "date", width: 150) { DossierDate.sortable($0.date) },
                    PagedColumn("Signal", id: "identifier", width: 320, monospaced: true) { $0.identifier },
                    PagedColumn("Context", id: "context", width: 180) { $0.context },
                    PagedColumn("OS Build", id: "build", width: 130, monospaced: true, secondary: true) { $0.build },
                ].readableMinimums(),
                searchPrompt: "Filter signals",
                reloadKey: AnyHashable(data.signals.count),
                exportName: "feature-signals",
                emptyTitle: "No Feature Signals Logged",
                filter: $filter
            )
            .tableCard(height: 360)
        }
    }
}

/// Horizontal grouped bars: usage vs delivery log entries per app. Not stacked — both
/// logs describe the same notifications.
private struct NotificationAppsChart: View {
    let rows: [(bundle: String, usage: Int, delivery: Int, distinct: Int)]

    private struct Segment: Identifiable {
        let id: String
        let app: String
        let series: String
        let count: Int
    }

    var body: some View {
        let names = EnvFormat.appNames(rows.map(\.bundle))
        let segments = rows.flatMap { row -> [Segment] in
            let app = names[row.bundle] ?? row.bundle
            return [Segment(id: row.bundle + "|u", app: app, series: "Usage", count: row.usage),
                    Segment(id: row.bundle + "|d", app: app, series: "Delivery", count: row.delivery)]
        }
        if segments.isEmpty {
            Text("No data").font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 80)
        } else {
            Chart(segments) { s in
                BarMark(x: .value("Log entries", s.count), y: .value("App", s.app))
                    .foregroundStyle(by: .value("Log", s.series))
                    .position(by: .value("Log", s.series), axis: .vertical, span: .fixed(18))
                    .cornerRadius(2)
            }
            .chartForegroundStyleScale(["Usage": ChartPalette.color(0), "Delivery": ChartPalette.color(1)])
            .chartYAxis { AxisMarks(preset: .aligned, position: .leading) { _ in AxisValueLabel() } }
            .chartXAxis { AxisMarks { _ in AxisGridLine(); AxisValueLabel() } }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: CGFloat(rows.count) * 28 + 54)
            .sensitive(.personal)
        }
    }
}
