import SwiftUI
import Charts
import DossierCore

/// (5) Calls — call table with duration charts, from Siri Remembers, the Mac's call
/// history or knowledgeC call intents.
struct CallsView: View {
    @State private var source = CallSource.remembers
    @State private var selected: CallRow?
    @Environment(\.refreshToken) private var refreshToken

    private struct Loaded: Sendable {
        let stats: CallStats
    }

    var body: some View {
        let token = refreshToken
        let source = source
        VStack(spacing: 0) {
            HeaderStrip {
                Picker("Source", selection: $source) {
                    ForEach(CallSource.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 330)
                HeaderNote(source.note)
            }
            AsyncContent(reloadKey: AnyHashable([AnyHashable(token), AnyHashable(source)]), emptyTitle: "No Calls", emptySymbol: "phone.badge.waveform") {
                Loaded(stats: CallMath.stats(try await CommsCache.shared.calls(source, token)))
            } isEmpty: { $0.stats.total == 0 } content: { loaded in
                SummaryOverTable {
                    summary(loaded.stats)
                } table: {
                    PagedTable(
                        columns: columns,
                        searchPrompt: "Filter calls",
                        reloadKey: AnyHashable([AnyHashable(token), AnyHashable(source)]),
                        exportName: "calls",
                        emptyTitle: "No Calls",
                        fetch: { request in try await Self.table(source, token).page(request) },
                        count: { request in try await Self.table(source, token).count(request) },
                        onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
                    )
                    .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                        if let selected { inspector(selected) }
                    }
                }
            }
            StoreFooter(source.url, note: source == .remembers ? "interactions (INStartCallIntent)" : source == .callHistory ? "ZCALLRECORD" : "ZOBJECT /app/intents")
        }
        .onChange(of: source) { selected = nil }
    }

    // MARK: Summary strip

    private func summary(_ stats: CallStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StatTileRow([
                Stat("Calls", Format.count(stats.total), caption: DossierDate.range(stats.range), symbol: "phone"),
                Stat("Incoming", Format.count(stats.incoming), caption: Format.percent(Double(stats.incoming) / Double(max(stats.total, 1)), digits: 0), symbol: "phone.arrow.down.left", tint: .blue),
                Stat("Outgoing", Format.count(stats.outgoing), caption: Format.percent(Double(stats.outgoing) / Double(max(stats.total, 1)), digits: 0), symbol: "phone.arrow.up.right", tint: .green),
                Stat("Talk Time", durationText(stats.seconds), caption: stats.connected > 0 ? "avg \(Format.duration(stats.seconds / Double(stats.connected)))" : nil, symbol: "timer", tint: .orange),
                Stat("Longest Call", durationText(stats.longest), caption: "\(Format.count(stats.connected)) calls connected", symbol: "hourglass", tint: .purple),
            ], minTileWidth: 140)
            HStack(alignment: .top, spacing: 12) {
                // The two fixed-content cards give way first (down to their minimum), so the
                // month chart keeps a readable width at the minimum window.
                chartCard("Talk time per month") { monthChart(stats) }.frame(minWidth: 170)
                chartCard("Call length") { bucketChart(stats) }.frame(minWidth: 170, maxWidth: 250)
                chartCard("Most talk time with") {
                    if stats.topPeople.isEmpty {
                        Text("No named call partners.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        peopleChart(stats)
                    }
                }
                .frame(minWidth: 210, maxWidth: 300)
            }
            .frame(height: 178)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func chartCard<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .card(padding: 10)
    }

    private struct MonthPoint: Identifiable {
        var id: String { "\(month.timeIntervalSince1970)|\(series)" }
        let month: Date
        let series: String
        let minutes: Double
    }

    private func monthChart(_ stats: CallStats) -> some View {
        let totals = Dictionary(stats.months.map { ($0.month, $0.seconds) }, uniquingKeysWith: +)
        let hours = (totals.values.max() ?? 0) >= 3 * 3600
        let points = stats.months.filter { $0.direction != .unspecified }.map {
            MonthPoint(month: $0.month, series: $0.direction.label, minutes: $0.seconds / (hours ? 3600 : 60))
        }
        return Chart(points) { point in
            BarMark(x: .value("Month", point.month, unit: .month), y: .value("Minutes", point.minutes))
                .foregroundStyle(by: .value("Direction", point.series))
        }
        .chartForegroundStyleScale(domain: ["Incoming", "Outgoing"], range: [CommDirection.incoming.tint, CommDirection.outgoing.tint])
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Format.number(v, maxDigits: 1)) \(hours ? "h" : "min")").font(.caption2) } }
            }
        }
        // Room for the last month label, which Charts otherwise clips at the plot edge.
        .chartXScale(range: .plotDimension(endPadding: 16))
        .chartLegend(position: .bottom, alignment: .leading, spacing: 2)
    }

    private func bucketChart(_ stats: CallStats) -> some View {
        Chart(Array(stats.buckets.enumerated()), id: \.offset) { _, bucket in
            BarMark(x: .value("Calls", bucket.count), y: .value("Length", bucket.label))
                .foregroundStyle(Color.orange.gradient)
                .cornerRadius(3)
                .annotation(position: .trailing, alignment: .leading, spacing: CGFloat(3)) {
                    Text(Format.count(bucket.count)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
        }
        .chartYScale(domain: stats.buckets.map(\.label))
        .chartXAxis(.hidden)
        .chartXScale(domain: 0...Double(max(stats.buckets.map(\.count).max() ?? 1, 1)) * 1.25)
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .leading) { value in
                AxisValueLabel { if let label = value.as(String.self) { Text(label).font(.caption2) } }
            }
        }
    }

    private func peopleChart(_ stats: CallStats) -> some View {
        let people = Array(stats.topPeople.prefix(6))
        let longest = max(people.map(\.seconds).max() ?? 1, 1)
        return GeometryReader { card in
          // Names take at most 104 pt, less in a narrow card so the bars stay visible.
          let nameWidth = min(104, max(60, card.size.width * 0.4))
          VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                HStack(spacing: 6) {
                    Text(person.name).font(.caption).lineLimit(1).frame(width: nameWidth, alignment: .trailing).sensitive(.sensitive)
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.purple.gradient)
                            .frame(width: max(2, proxy.size.width * CGFloat(person.seconds / longest)))
                    }
                    .frame(height: 11)
                    Text(person.seconds > 0 ? Format.duration(person.seconds) : "\(person.count)×")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).frame(width: 58, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
          }
        }
    }

    // MARK: Table

    private static func table(_ source: CallSource, _ token: Int) async throws -> MemoryTable<CallRow> {
        MemoryTable(
            rows: try await CommsCache.shared.calls(source, token),
            search: { [$0.person, $0.handle, AppNames.name($0.bundle), $0.status, $0.direction.label, $0.detail].joined(separator: " ") },
            keys: [
                "date": .number { $0.date?.timeIntervalSince1970 ?? 0 },
                "direction": .number { Double($0.direction.rawValue) },
                "person": .text { $0.person.isEmpty ? $0.handle : $0.person },
                "handle": .text { $0.handle },
                "seconds": .number { $0.seconds },
                "app": .text { AppNames.name($0.bundle) },
                "status": .text { $0.status },
                "device": .text { $0.device },
            ])
    }

    private var columns: [PagedColumn<CallRow>] {
        [
            PagedColumn<CallRow>("Time", id: "date", width: 150, min: 146) { DossierDate.sortable($0.date) },
            PagedColumn("Dir", id: "direction", width: 56) { $0.direction.label }
                .cell { DirectionCell(direction: $0.direction) },
            PagedColumn("With", id: "person", width: 200, min: 90, sensitivity: .sensitive) { $0.person.isEmpty ? $0.handle : $0.person }
                .cell { row in
                    Text(row.person.isEmpty ? (row.handle.isEmpty ? "Unknown" : row.handle) : row.person)
                        .font(.callout.weight(row.person.isEmpty ? .regular : .medium)).lineLimit(1)
                        .foregroundStyle(row.person.isEmpty && row.handle.isEmpty ? .tertiary : .primary)
                },
            PagedColumn("Handle", id: "handle", width: 150, min: 110, sensitivity: .sensitive, monospaced: true, secondary: true) { $0.handle },
            PagedColumn("Duration", id: "seconds", width: 84, min: 72, alignment: .trailing) { durationText($0.seconds) },
            PagedColumn("App", id: "app", width: 110, min: 84, sensitivity: .personal) { AppNames.name($0.bundle) },
            PagedColumn("Status", id: "status", width: 150, secondary: true) { $0.status },
            PagedColumn("Recorded On", id: "device", width: 130, sensitivity: .personal, secondary: true) { $0.device },
        ]
    }

    @ViewBuilder private func inspector(_ row: CallRow) -> some View {
        InspectorPage(title: row.person.isEmpty ? (row.handle.isEmpty ? "Unknown caller" : row.handle) : row.person,
                      subtitle: "\(row.direction.label) call · \(AppNames.name(row.bundle))", sensitivity: .sensitive, onClose: { selected = nil }) {
            KeyValueGrid([
                KeyValueItem("Time", DossierDate.medium(row.date)),
                KeyValueItem("Direction", row.direction.label),
                KeyValueItem("With", row.person.isEmpty ? nil : row.person, sensitivity: .sensitive),
                KeyValueItem("Handle", row.handle.isEmpty ? nil : row.handle, sensitivity: .sensitive, monospaced: true),
                KeyValueItem("Duration", durationText(row.seconds)),
                KeyValueItem("Status", row.status),
                KeyValueItem("App", AppNames.name(row.bundle), sensitivity: .personal),
                KeyValueItem("Bundle id", row.bundle, monospaced: true),
                KeyValueItem("Details", row.detail.isEmpty ? nil : row.detail, sensitivity: .personal),
                KeyValueItem("Recorded on", row.device, sensitivity: .personal),
                KeyValueItem("Source", source.rawValue),
            ])
            Text(source.note).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
