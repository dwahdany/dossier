import Charts
import DossierCore
import SwiftUI

/// (2) App usage table per device with an inspector: timeline, time of day and what you
/// open next.
struct AppUsageView: View {
    @ObservedObject private var selection = ActivitySelection.shared
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @State private var selectedBundle: String?
    @State private var filter = ""
    @State private var total: Double = 1
    @State private var maxTotal: Double = 1

    private struct Key: Hashable { let device: String; let range: ActivityRange; let token: Int }

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (selectedBundle, filter, total, maxTotal)
        let key = Key(device: selection.deviceID, range: selection.range, token: refreshToken)
        let isLocal = selection.deviceID == ActivityDevice.localID
        VStack(spacing: 0) {
            HeaderStrip {
                StripControls(captionTrailing: false) {
                    DevicePicker()
                    RangePicker()
                } caption: {
                    DeviceCaption(device: selection.device).sensitive(.personal)
                }
            }
            PagedTable(
                columns: columns(isLocal: isLocal),
                searchPrompt: "Filter apps",
                reloadKey: key,
                exportName: "app-usage",
                emptyTitle: "No App Usage",
                filter: $filter,
                fetch: { request in
                    try ActivityAccess.requireBiome()
                    await ActivityStore.shared.sync(token: key.token)
                    return await ActivityStore.shared.appRows(device: key.device, range: key.range, request: request)
                },
                count: { request in
                    let rows = await ActivityStore.shared.appRows(device: key.device, range: key.range, request: PageRequest(offset: 0, limit: .max, sort: nil, search: request.search))
                    return rows.count
                },
                onSelect: { rows in selectedBundle = rows.count == 1 ? rows.first?.bundle : (rows.isEmpty ? nil : selectedBundle) }
            )
            .detailInspector(isPresented: Binding(get: { selectedBundle != nil }, set: { if !$0 { selectedBundle = nil } })) {
                if let bundle = selectedBundle {
                    AppInspector(device: key.device, range: key.range, bundle: bundle, token: key.token, onClose: { selectedBundle = nil })
                }
            }
            if let stream = Biome.stream(named: "App.InFocus") {
                StoreFooter(stream.url, note: isLocal ? "App.InFocus + ScreenTime.AppUsage, knowledgeC /app/usage, _ATXDataStore.db appInfo" : "App.InFocus · remote segments")
            }
        }
        .task(id: key) {
            let agg = await SnapshotReadiness.track { await ActivityStore.shared.aggregate(device: key.device, range: key.range) }
            total = max(1, agg.total)
            maxTotal = max(1, agg.apps.first?.total ?? 1)
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink else { return }
            guard link.payload.hasPrefix("app:") else { selection.apply(payload: link.payload); return }
            let parts = link.payload.dropFirst(4).split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                selection.deviceID = parts[0]
                selection.range = .all
                selectedBundle = parts[1]
            } else if let only = parts.first {
                selectedBundle = only
            }
        }
    }

    private func columns(isLocal: Bool) -> [PagedColumn<AppUsageRow>] {
        let total = self.total
        let maxTotal = self.maxTotal
        var cols: [PagedColumn<AppUsageRow>] = [
            PagedColumn<AppUsageRow>("App", id: "name", width: 220, min: 140, sensitivity: .personal) { $0.name }
                .cell { row in AppLabel(bundle: row.bundle, name: row.name).font(.callout) },
            PagedColumn("Total Time", id: "total", width: 90, min: 80, alignment: .trailing) { Format.usage($0.total) },
            PagedColumn("Share", id: "share", width: 150, min: 90, sortable: false) { Format.percent($0.total / total) }
                .cell { row in
                    HStack(spacing: 6) {
                        ProportionBar(fraction: row.total / maxTotal)
                        Text(Format.percent(row.total / total)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                    }
                },
            PagedColumn("Activations", id: "activations", width: 96, min: 90, alignment: .trailing) { Format.count($0.activations) },
            PagedColumn("Median", id: "median", width: 80, min: 70, alignment: .trailing) { Format.usage($0.median) },
            PagedColumn("Longest", id: "longest", width: 86, min: 76, alignment: .trailing) { Format.usage($0.longest) },
            PagedColumn("Days", id: "days", width: 54, min: 50, alignment: .trailing) { Format.count($0.daysActive) },
            PagedColumn("Last Used", id: "last", width: 150, min: 146) { DossierDate.sortable($0.last) },
            PagedColumn("First Seen", id: "first", width: 150, min: 146, hiddenByDefault: true) { DossierDate.sortable($0.first) },
        ]
        if isLocal {
            cols += [
                PagedColumn("Screen Time", id: "screentime", width: 104, min: 100, alignment: .trailing, secondary: true) { $0.screenTimeSeconds.map(Format.usage) ?? "—" },
                PagedColumn("knowledgeC", id: "knowledge", width: 104, min: 100, alignment: .trailing, secondary: true) { $0.knowledgeSeconds.map(Format.usage) ?? "—" },
                PagedColumn("Launch Gap", id: "gap", width: 100, min: 96, alignment: .trailing, secondary: true, hiddenByDefault: true) { $0.atxMedianGap.map(Format.usage) ?? "—" },
                PagedColumn("Daily Dose", id: "dose", width: 90, alignment: .trailing, secondary: true, hiddenByDefault: true) { $0.dailyDose.map(Format.usage) ?? "—" },
            ]
        }
        cols.append(PagedColumn("Bundle ID", id: "bundle", width: 240, sensitivity: .personal, monospaced: true, secondary: true, hiddenByDefault: !isLocal ? false : true) { $0.bundle })
        return cols
    }
}

// MARK: - Inspector

struct AppInspector: View {
    let device: String
    let range: ActivityRange
    let bundle: String
    let token: Int
    let onClose: () -> Void

    private struct Key: Hashable { let device: String; let range: ActivityRange; let bundle: String; let token: Int }

    var body: some View {
        InspectorPage(title: AppNames.name(bundle), subtitle: bundle, sensitivity: .personal, onClose: onClose) {
            AsyncContent(reloadKey: Key(device: device, range: range, bundle: bundle, token: token), emptyTitle: "No Sessions", emptySymbol: "app.dashed") {
                guard let detail = await ActivityStore.shared.appDetail(device: device, range: range, bundle: bundle) else {
                    throw DossierError.message("This app has no sessions on the selected device and range.")
                }
                return detail
            } content: { detail in
                content(detail)
            }
        }
    }

    @ViewBuilder private func content(_ detail: AppDetail) -> some View {
        let row = detail.row
        HStack(spacing: 10) {
            AppIcon(bundle: bundle, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.usage(row.total)).font(.title2.weight(.semibold)).monospacedDigit()
                Text("in front across \(Format.count(row.activations)) activations").font(.caption).foregroundStyle(.secondary)
            }
        }
        .sensitive(.personal)

        KeyValueGrid(items(detail))

        if detail.daily.count > 1 {
            InspectorGroupTitle("Time per day")
            let hours = (detail.daily.map(\.value).max() ?? 0) >= 2 * 3600
            LineChartView(detail.daily.map { ChartPoint($0.date, $0.value / (hours ? 3600 : 60)) }, style: .bars, unit: .day, tint: AppColor.color(bundle),
                          valueLabel: { String(format: hours ? "%.1f h" : "%.0f min", $0) })
                .frame(height: 130)
                .padding(.bottom, 4)
        }

        InspectorGroupTitle("Time of day")
        HourBars(values: detail.hourly, tint: AppColor.color(bundle)).frame(height: 70)

        InspectorGroupTitle("What you open before and after")
        if detail.next.isEmpty && detail.previous.isEmpty {
            Text("No app switches within 60 seconds were recorded.").font(.callout).foregroundStyle(.secondary)
        } else {
            TransitionGraph(center: row.name, previous: Array(detail.previous.prefix(6)), next: Array(detail.next.prefix(6)))
                .sensitive(.personal)
            Text("Counted when the other app was frontmost within 60 seconds. Home screen and lock screen in between are skipped.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }

        if !detail.atxNext.isEmpty {
            InspectorGroupTitle("DuetExpert: launched next (learned scores)")
            let top = detail.atxNext.prefix(6)
            let maxScore = max(top.map(\.score).max() ?? 1, 0.0001)
            VStack(spacing: 0) {
                ForEach(Array(top.enumerated()), id: \.offset) { _, item in
                    RankedAppRow(rank: nil, bundle: item.bundle, name: item.name, fraction: item.score / maxScore, value: Format.number(item.score, maxDigits: 2), tint: .purple)
                }
            }
            Text("Time-decayed launch counts from _ATXDataStore.db (appInfo.subsequentLaunchCounts): the system's own model of what follows this app.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }

        if !detail.recent.isEmpty {
            InspectorGroupTitle("Latest sessions")
            VStack(alignment: .leading, spacing: 3) {
                ForEach(detail.recent) { block in
                    HStack {
                        Text(DossierDate.sortable(block.start)).monospacedDigit()
                        Spacer()
                        Text(Format.usage(block.duration)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func items(_ detail: AppDetail) -> [KeyValueItem] {
        let row = detail.row
        var out = [
            KeyValueItem("Median session", Format.usage(row.median)),
            KeyValueItem("Longest", Format.usage(row.longest) + (row.capped > 0 ? " (\(row.capped) capped)" : "")),
            KeyValueItem("Days active", Format.count(row.daysActive)),
            KeyValueItem("First seen", DossierDate.medium(row.first)),
            KeyValueItem("Last used", row.last.map { DossierDate.medium($0) + " (" + DossierDate.relative($0) + ")" }),
        ]
        if let s = row.screenTimeSeconds { out.append(KeyValueItem("Screen Time", Format.usage(s) + " (ScreenTime.AppUsage)")) }
        if let s = row.knowledgeSeconds { out.append(KeyValueItem("knowledgeC", Format.usage(s) + " (/app/usage)")) }
        if let info = detail.atxInfo {
            if let d = info.installDate { out.append(KeyValueItem("Installed", DossierDate.medium(d))) }
            if let d = info.lastLaunch { out.append(KeyValueItem("Last launch", DossierDate.medium(d) + " (DuetExpert)")) }
            if let d = info.lastSpotlightLaunch { out.append(KeyValueItem("Via Spotlight", DossierDate.medium(d))) }
            if let g = info.medianGap { out.append(KeyValueItem("Launch gap", "median \(Format.usage(g))" + (info.averageGap.map { ", mean \(Format.usage($0))" } ?? ""))) }
        }
        if let dose = row.dailyDose { out.append(KeyValueItem("Daily dose", Format.usage(dose) + " (moving average)")) }
        out.append(KeyValueItem("Bundle ID", row.bundle, sensitivity: .personal, monospaced: true))
        return out
    }
}

/// 24 bars, one per hour of day.
struct HourBars: View {
    let values: [Double]
    var tint: Color = .accentColor

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { hour, value in
            BarMark(x: .value("Hour", hour), y: .value("Seconds", value), width: .fixed(7))
                .foregroundStyle(tint.gradient)
                .cornerRadius(2)
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18]) { value in
                AxisValueLabel { if let h = value.as(Int.self) { Text(String(format: "%02d", h)) } }
            }
        }
        .chartYAxis(.hidden)
    }
}

/// "Before → app → after" flow diagram drawn in a Canvas: edge width ∝ switch count.
struct TransitionGraph: View {
    let center: String
    let previous: [TransitionEdge]
    let next: [TransitionEdge]

    private let rowHeight: CGFloat = 24

    var body: some View {
        let rows = max(previous.count, next.count, 1)
        Canvas { context, size in
            let maxCount = CGFloat(max(previous.map(\.count).max() ?? 1, next.map(\.count).max() ?? 1, 1))
            let sideWidth = size.width * 0.36
            let boxHeight = min(size.height - 8, max(44, CGFloat(rows) * rowHeight * 0.7))
            let centerRect = CGRect(x: size.width / 2 - 30, y: (size.height - boxHeight) / 2, width: 60, height: boxHeight)
            context.fill(Path(roundedRect: centerRect, cornerRadius: 8), with: .color(.accentColor.opacity(0.16)))
            context.stroke(Path(roundedRect: centerRect, cornerRadius: 8), with: .color(.accentColor.opacity(0.5)), lineWidth: 1)
            var centerContext = context
            centerContext.clip(to: Path(centerRect.insetBy(dx: 3, dy: 2)))
            centerContext.draw(Text(center).font(.caption2.weight(.semibold)).foregroundStyle(.primary), at: CGPoint(x: centerRect.midX, y: centerRect.midY), anchor: .center)

            func y(_ index: Int, of count: Int) -> CGFloat {
                let block = CGFloat(count) * rowHeight
                return (size.height - block) / 2 + (CGFloat(index) + 0.5) * rowHeight
            }
            func anchorY(_ yy: CGFloat) -> CGFloat {
                centerRect.midY + (yy - size.height / 2) * (boxHeight - 12) / max(size.height, 1)
            }
            func curve(from: CGPoint, to: CGPoint, count: Int, color: Color) {
                var path = Path()
                path.move(to: from)
                path.addCurve(to: to, control1: CGPoint(x: (from.x + to.x) / 2, y: from.y), control2: CGPoint(x: (from.x + to.x) / 2, y: to.y))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1 + 5 * CGFloat(count) / maxCount, lineCap: .round))
            }
            for (i, edge) in previous.enumerated() {
                let yy = y(i, of: previous.count)
                curve(from: CGPoint(x: sideWidth, y: yy), to: CGPoint(x: centerRect.minX, y: anchorY(yy)), count: edge.count, color: .teal.opacity(0.55))
                var side = context
                side.clip(to: Path(CGRect(x: 0, y: yy - rowHeight / 2, width: sideWidth - 6, height: rowHeight)))
                side.draw(Text(edge.name).font(.caption) + Text("  \(edge.count)").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: 0, y: yy), anchor: .leading)
            }
            for (i, edge) in next.enumerated() {
                let yy = y(i, of: next.count)
                curve(from: CGPoint(x: centerRect.maxX, y: anchorY(yy)), to: CGPoint(x: size.width - sideWidth, y: yy), count: edge.count, color: .orange.opacity(0.6))
                var side = context
                side.clip(to: Path(CGRect(x: size.width - sideWidth + 6, y: yy - rowHeight / 2, width: sideWidth - 6, height: rowHeight)))
                side.draw(Text("\(edge.count)  ").font(.caption2).foregroundStyle(.secondary) + Text(edge.name).font(.caption), at: CGPoint(x: size.width - sideWidth + 6, y: yy), anchor: .leading)
            }
        }
        .frame(height: CGFloat(rows) * rowHeight + 12)
        .overlay(alignment: .top) {
            HStack {
                Text("BEFORE").frame(maxWidth: .infinity, alignment: .leading)
                Text("AFTER").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).offset(y: -12)
        }
        .padding(.top, 12)
        .accessibilityLabel("Apps used before and after \(center)")
    }
}
