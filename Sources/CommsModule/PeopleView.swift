import SwiftUI
import Charts
import DossierCore

/// (2) People — ranked counterparts from Siri Remembers with a detail inspector.
struct PeopleView: View {
    @State private var selected: PersonRow?
    @State private var filter = ""
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @Environment(\.navigate) private var navigate

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (selected, filter)
        let token = refreshToken
        VStack(spacing: 0) {
            HeaderStrip {
                Image(systemName: "person.2").foregroundStyle(.secondary)
                HeaderNote("Everyone who appears as sender, recipient or call partner in Siri Remembers. Handles that share a display name are merged into one person; interactions that only carry a channel or group title are listed under Conversations.")
            }
            PagedTable(
                columns: columns,
                searchPrompt: "Filter people, handles or apps",
                reloadKey: token,
                exportName: "people",
                emptyTitle: "No People",
                filter: $filter,
                fetch: { request in try await Self.table(token).page(request) },
                count: { request in try await Self.table(token).count(request) },
                onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
            )
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { inspector(selected) }
            }
            StoreFooter(CommsPaths.remembersView, note: "interactionEntities ⨝ entities (PersonHandle)")
        }
        .task(id: deepLink?.nonce) {
            guard let link = deepLink, link.payload.hasPrefix("person:") else { return }
            let key = String(link.payload.dropFirst("person:".count))
            await SnapshotReadiness.track {
                if let people = try? await CommsCache.shared.people(token), let person = people.first(where: { $0.id == key }) {
                    selected = person
                    filter = person.name
                }
            }
        }
    }

    private static func table(_ token: Int) async throws -> MemoryTable<PersonRow> {
        let people = try await CommsCache.shared.people(token)
        return MemoryTable(
            rows: people,
            search: { $0.name + " " + $0.handles.map(\.value).joined(separator: " ") + " " + $0.appList },
            keys: [
                "name": .text { $0.name },
                "total": .number { Double($0.total) },
                "messagesIn": .number { Double($0.messagesIn) },
                "messagesOut": .number { Double($0.messagesOut) },
                "calls": .number { Double($0.calls) },
                "callSeconds": .number { $0.callSeconds },
                "apps": .text { $0.appList },
                "handles": .number { Double($0.handles.count) },
                "first": .number { $0.first?.timeIntervalSince1970 ?? 0 },
                "last": .number { $0.last?.timeIntervalSince1970 ?? 0 },
            ])
    }

    private var columns: [PagedColumn<PersonRow>] {
        [
            PagedColumn<PersonRow>("Person", id: "name", width: 220, min: 120, sensitivity: .sensitive) { $0.name }
                .cell { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.named ? "person.crop.circle.fill" : "number.circle")
                            .foregroundStyle(row.named ? Color.accentColor : .secondary)
                        Text(row.name).font(.callout.weight(.medium)).lineLimit(1)
                    }
                },
            PagedColumn("Interactions", id: "total", width: 90, min: 86, alignment: .trailing) { Format.count($0.total) },
            PagedColumn("Msgs In", id: "messagesIn", width: 70, min: 64, alignment: .trailing) { Format.count($0.messagesIn) },
            PagedColumn("Msgs Out", id: "messagesOut", width: 74, min: 70, alignment: .trailing) { Format.count($0.messagesOut) },
            PagedColumn("Calls", id: "calls", width: 56, alignment: .trailing) { Format.count($0.calls) },
            PagedColumn("Talk Time", id: "callSeconds", width: 84, min: 76, alignment: .trailing) { durationText($0.callSeconds) },
            PagedColumn("Apps", id: "apps", width: 200, min: 80, sensitivity: .personal) { $0.appList },
            PagedColumn("Handles", id: "handles", width: 64, alignment: .trailing, hiddenByDefault: true) { Format.count($0.handles.count) },
            PagedColumn("First Seen", id: "first", width: 150, min: 146) { DossierDate.sortable($0.first) },
            PagedColumn("Last Seen", id: "last", width: 150, min: 146) { DossierDate.sortable($0.last) },
        ]
    }

    // MARK: Inspector

    @ViewBuilder private func inspector(_ person: PersonRow) -> some View {
        InspectorPage(title: person.name, subtitle: "\(Format.count(person.total)) interactions · \(person.handles.count) handle\(person.handles.count == 1 ? "" : "s")", sensitivity: .sensitive, onClose: { selected = nil }) {
            KeyValueGrid([
                KeyValueItem("Messages", "\(Format.count(person.messagesIn)) in · \(Format.count(person.messagesOut)) out"),
                KeyValueItem("Calls", person.calls > 0 ? "\(Format.count(person.callsIn)) in · \(Format.count(person.callsOut)) out · \(durationText(person.callSeconds))" : "none"),
                KeyValueItem("First seen", DossierDate.medium(person.first)),
                KeyValueItem("Last seen", "\(DossierDate.medium(person.last)) (\(DossierDate.relative(person.last)))"),
            ])
            if navigate != nil {
                Button("Show Messages in Timeline") { navigate?(DeepLink(sectionID: "comms.messages", payload: "person:" + person.id)) }
                    .controlSize(.small)
            }

            InspectorGroupTitle("Per app")
            BarChartView(person.apps.sorted { $0.value > $1.value }.prefix(10).map { ChartBar(AppNames.name($0.key), Double($0.value)) }, labelSensitivity: .personal)

            AsyncContent(reloadKey: person.id) {
                try await RemembersStore.personDetail(person.entityIDs)
            } content: { detail in
                VStack(alignment: .leading, spacing: 16) {
                    InspectorGroupTitle("Timeline")
                    PersonTimeline(months: detail.months)
                    InspectorGroupTitle("Hour of day")
                    HourBars(heat: detail.heat)
                    if !detail.conversations.isEmpty {
                        InspectorGroupTitle("Conversations")
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(detail.conversations.enumerated()), id: \.offset) { _, conversation in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(conversation.title).font(.callout).lineLimit(2).sensitive(.sensitive)
                                    Spacer(minLength: 6)
                                    Text("\(AppNames.name(conversation.bundle)) · \(Format.count(conversation.count))")
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 120)

            InspectorGroupTitle("Handles (\(person.handles.count))")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(person.handles.sorted { $0.count > $1.count }) { handle in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(handle.value).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled).sensitive(.sensitive)
                            Spacer(minLength: 6)
                            Text(Format.count(handle.count)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Text(([handle.kind, handle.label].compactMap { $0 } + handle.apps.map { AppNames.name($0) }).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Names and handles are what the donating apps reported; the system links them to a contact only when the app supplied one.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 24 bars: interactions per local hour of day (inspector-sized).
struct HourBars: View {
    let heat: [(weekday: Int, hour: Int, weight: Double)]

    var body: some View {
        var hours = [Double](repeating: 0, count: 24)
        for bin in heat where (0..<24).contains(bin.hour) { hours[bin.hour] += bin.weight }
        return Chart(Array(hours.enumerated()), id: \.offset) { hour, value in
            BarMark(x: .value("Hour", hour), y: .value("Interactions", value), width: .ratio(0.8))
                .foregroundStyle(Color.blue.gradient)
                .cornerRadius(2)
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                AxisValueLabel { if let h = value.as(Int.self) { Text(String(format: "%02d:00", h)).font(.caption2) } }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let v = value.as(Double.self) { Text(Format.compact(Int(v))).font(.caption2) } }
            }
        }
        .frame(height: 90)
    }
}

/// Stacked monthly bars (messages / calls × direction) sized for an inspector.
struct PersonTimeline: View {
    let months: [MonthBucket]

    private struct Point: Identifiable {
        var id: String { "\(month.timeIntervalSince1970)|\(series)" }
        let month: Date
        let series: String
        let count: Int
    }

    var body: some View {
        let points = months.filter { $0.direction != .unspecified }.map {
            Point(month: $0.month, series: "\($0.kind) \($0.direction == .incoming ? "in" : "out")", count: $0.count)
        }
        if points.isEmpty {
            Text("No dated interactions.").font(.callout).foregroundStyle(.secondary)
        } else {
            Chart(points) { point in
                BarMark(x: .value("Month", point.month, unit: .month), y: .value("Interactions", point.count))
                    .foregroundStyle(by: .value("Kind", point.series))
            }
            .chartForegroundStyleScale(domain: ["Messages in", "Messages out", "Calls in", "Calls out"], range: [Color.blue, .green, .orange, .purple])
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let v = value.as(Int.self) { Text(Format.compact(v)).font(.caption2) } }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 170)
        }
    }
}
