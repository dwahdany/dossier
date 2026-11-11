import SwiftUI
import Charts
import DossierCore

/// (6) Correspondent ranking from interactionC: per-contact in/out counters plus the
/// keywords the system extracted from meeting titles.
struct CorrespondentsView: View {
    @State private var selected: CorrespondentRow?
    @State private var filter = ""
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink

    private struct MonthPoint: Sendable, Identifiable {
        var id: String { "\(month.timeIntervalSince1970)|\(label)" }
        let month: Date
        let label: String
        let count: Int
    }

    private struct Loaded: Sendable {
        let past: Int
        let scheduled: Int
        let scheduledUntil: Date?
        let contacts: Int
        let keywords: [KeywordCount]
        let keywordLinks: Int
        let mechanisms: [MechanismTotal]
        let range: ClosedRange<Date>?
        let months: [MonthPoint]
    }

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (selected, filter)
        let token = refreshToken
        VStack(spacing: 0) {
            HeaderStrip {
                HeaderNote("interactionC is the CoreDuet “People” store: Mail and Calendar record every message and invitation with its sender and recipients, so the system can rank who to suggest when you address a mail or share something. Meeting titles are broken into keywords.")
            }
            AsyncContent(reloadKey: token) {
                let o = try await InteractionCStore.overview()
                return Loaded(past: o.past, scheduled: o.scheduled, scheduledUntil: o.scheduledUntil, contacts: o.contacts, keywords: o.keywords, keywordLinks: o.keywordLinks,
                              mechanisms: o.mechanisms, range: o.range, months: o.months.map { MonthPoint(month: $0.month, label: $0.label, count: $0.count) })
            } content: { loaded in
                SummaryOverTable {
                    summary(loaded)
                } table: {
                    PagedTable(
                        columns: columns,
                        searchPrompt: "Filter contacts",
                        reloadKey: token,
                        exportName: "correspondents",
                        emptyTitle: "No Contacts",
                        filter: $filter,
                        fetch: { request in try await Self.table(token).page(request) },
                        count: { request in try await Self.table(token).count(request) },
                        onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
                    )
                    .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                        if let selected { inspector(selected) }
                    }
                }
            }
            StoreFooter(Paths.interactionC, note: "ZCONTACTS · ZINTERACTIONS · ZKEYWORDS")
        }
        .task(id: deepLink?.nonce) {
            guard let link = deepLink, link.payload.hasPrefix("contact:"), let pk = Int64(link.payload.dropFirst("contact:".count)) else { return }
            await SnapshotReadiness.track {
                if let rows = try? await CommsCache.shared.correspondents(token), let row = rows.first(where: { $0.id == pk }) {
                    selected = row
                    filter = row.identifier
                }
            }
        }
    }

    // MARK: Summary

    private func summary(_ loaded: Loaded) -> some View {
        let incoming = loaded.mechanisms.filter { $0.direction != 1 }.reduce(0) { $0 + $1.count }
        let outgoing = loaded.mechanisms.filter { $0.direction == 1 }.reduce(0) { $0 + $1.count }
        let total = max(incoming + outgoing, 1)
        var stats = [
            Stat("Contacts", Format.count(loaded.contacts), caption: "senders and recipients", symbol: "person.2"),
            Stat("Interactions", Format.count(loaded.past), caption: DossierDate.range(loaded.range), symbol: "tray.full", tint: .indigo),
            Stat("Incoming", Format.count(incoming), caption: Format.percent(Double(incoming) / Double(total), digits: 0), symbol: "arrow.down.left", tint: .blue),
            Stat("Outgoing", Format.count(outgoing), caption: Format.percent(Double(outgoing) / Double(total), digits: 0), symbol: "arrow.up.right", tint: .green),
        ]
        if loaded.scheduled > 0 {
            // Future occurrences of calendar events: on record, but they have not happened.
            stats.append(Stat("Scheduled Meetings", Format.count(loaded.scheduled), caption: loaded.scheduledUntil.map { "up to \(DossierDate.day($0))" }, symbol: "calendar.badge.clock", tint: .orange))
        }
        stats.append(Stat("Keywords", Format.count(loaded.keywords.count), caption: "\(Format.count(loaded.keywordLinks)) uses in meeting titles", symbol: "textformat", tint: .purple))
        return VStack(alignment: .leading, spacing: 12) {
            StatTileRow(stats, minTileWidth: 140)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Interactions per month").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    monthChart(loaded).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .card(padding: 10)
                .frame(minWidth: 240)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Keywords from meeting titles").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if loaded.keywords.isEmpty {
                        Text("No keywords stored.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            KeywordCloud(keywords: Array(loaded.keywords.prefix(90)))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .card(padding: 10)
                .frame(minWidth: 280, maxWidth: 470)
            }
            .frame(height: 178)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func monthChart(_ loaded: Loaded) -> some View {
        let recent = loaded.months.suffix(60)
        return Chart(Array(recent)) { point in
            BarMark(x: .value("Month", point.month, unit: .month), y: .value("Interactions", point.count))
                .foregroundStyle(by: .value("Kind", point.label))
        }
        .chartForegroundStyleScale(range: ChartPalette.colors)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let v = value.as(Int.self) { Text(Format.compact(v)).font(.caption2) } }
            }
        }
        // Room for the last month label, which Charts otherwise clips at the plot edge.
        .chartXScale(range: .plotDimension(endPadding: 16))
        .chartLegend(position: .bottom, alignment: .leading, spacing: 2)
    }

    // MARK: Table

    private static func table(_ token: Int) async throws -> MemoryTable<CorrespondentRow> {
        MemoryTable(
            rows: try await CommsCache.shared.correspondents(token),
            search: { $0.name + " " + $0.identifier },
            keys: [
                "name": .text { $0.name.isEmpty ? $0.identifier : $0.name },
                "identifier": .text { $0.identifier },
                "sent": .number { Double($0.sent) },
                "received": .number { Double($0.received) },
                "coRecipient": .number { Double($0.coRecipient) },
                "total": .number { Double($0.total) },
                "first": .number { $0.first?.timeIntervalSince1970 ?? 0 },
                "last": .number { $0.last?.timeIntervalSince1970 ?? 0 },
            ])
    }

    private var columns: [PagedColumn<CorrespondentRow>] {
        [
            PagedColumn<CorrespondentRow>("Contact", id: "name", width: 210, min: 100, sensitivity: .sensitive) { $0.name.isEmpty ? $0.identifier : $0.name }
                .cell { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.personID == nil ? "envelope" : "person.crop.circle.fill")
                            .foregroundStyle(row.personID == nil ? Color.secondary : Color.accentColor)
                            .help(row.personID == nil ? "Not linked to a Contacts card" : "Linked to a Contacts card")
                        Text(row.name.isEmpty ? row.identifier : row.name).font(.callout.weight(.medium)).lineLimit(1)
                    }
                },
            PagedColumn("Address", id: "identifier", width: 240, min: 100, sensitivity: .sensitive, secondary: true) { $0.identifier },
            PagedColumn("Wrote to You", id: "sent", width: 96, min: 92, alignment: .trailing) { Format.count($0.sent) },
            PagedColumn("You Wrote", id: "received", width: 84, min: 78, alignment: .trailing) { Format.count($0.received) },
            PagedColumn("Co-recipient", id: "coRecipient", width: 96, min: 92, alignment: .trailing) { Format.count($0.coRecipient) },
            PagedColumn("Total", id: "total", width: 70, alignment: .trailing) { Format.count($0.total) },
            PagedColumn("First", id: "first", width: 150, min: 146) { DossierDate.sortable($0.first) },
            PagedColumn("Last", id: "last", width: 150, min: 146) { DossierDate.sortable($0.last) },
        ]
    }

    // MARK: Inspector

    private struct DetailBox: Sendable {
        struct Line: Sendable, Identifiable { let id: Int; let label: String; let count: Int }
        let byApp: [Line]
        let keywords: [KeywordCount]
        let months: [ChartPoint]
    }

    @ViewBuilder private func inspector(_ row: CorrespondentRow) -> some View {
        InspectorPage(title: row.name.isEmpty ? row.identifier : row.name, subtitle: row.identifier, sensitivity: .sensitive, onClose: { selected = nil }) {
            KeyValueGrid([
                KeyValueItem("Wrote to you", Format.count(row.sent)),
                KeyValueItem("You wrote to them", Format.count(row.received)),
                KeyValueItem("Co-recipient", "\(Format.count(row.coRecipient)) (addressed together with you)"),
                KeyValueItem("First", DossierDate.medium(row.first)),
                KeyValueItem("Last", DossierDate.medium(row.last)),
                KeyValueItem("Contacts card", row.personID == nil ? "not linked" : "linked"),
                KeyValueItem("Contact id", row.personID, monospaced: true),
            ])
            AsyncContent(reloadKey: row.id) {
                let d = try await InteractionCStore.detail(contact: row.id)
                return DetailBox(
                    byApp: d.byApp.enumerated().map { DetailBox.Line(id: $0.offset, label: $0.element.label, count: $0.element.count) },
                    keywords: d.keywords, months: d.months.map { ChartPoint($0.month, Double($0.count)) })
            } content: { detail in
                VStack(alignment: .leading, spacing: 16) {
                    if !detail.byApp.isEmpty {
                        InspectorGroupTitle("Interactions by kind")
                        BarChartView(detail.byApp.map { ChartBar($0.label, Double($0.count)) })
                    }
                    if !detail.months.isEmpty {
                        InspectorGroupTitle("Timeline")
                        LineChartView(detail.months, style: .bars, unit: .month).frame(height: 150)
                    }
                    if !detail.keywords.isEmpty {
                        InspectorGroupTitle("Keywords of shared meetings")
                        KeywordCloud(keywords: detail.keywords)
                    }
                }
            }
            .frame(minHeight: 100)
        }
    }
}

/// Words sized by frequency, wrapped like text.
struct KeywordCloud: View {
    let keywords: [KeywordCount]

    var body: some View {
        let maxCount = Double(keywords.map(\.count).max() ?? 1)
        FlowLayout(spacing: 6, lineSpacing: 5) {
            ForEach(keywords) { keyword in
                let weight = (Double(keyword.count) / maxCount).squareRoot()
                HStack(spacing: 3) {
                    Text(keyword.word).font(.system(size: 11 + 7 * weight, weight: weight > 0.6 ? .semibold : .regular))
                    Text("\(keyword.count)").font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(Color.accentColor.opacity(0.07 + 0.16 * weight), in: Capsule())
                .sensitive(.personal)
            }
        }
    }
}
