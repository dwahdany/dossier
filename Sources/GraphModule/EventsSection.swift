import SwiftUI
import Charts
import DossierCore

// MARK: - Model

/// A calendar event node from `event_graph`.
struct EventInfo: Identifiable, Sendable {
    struct Participant: Sendable, Identifiable, Hashable {
        var id: String { "\(node)|\(isOrganizer)" }
        let node: Int64
        let name: String
        /// `PS734` participant obligation / kind as stored.
        let role: String
        let isOrganizer: Bool
    }

    struct Occurrence: Sendable, Identifiable, Hashable {
        let id: Int64
        let start: Date?
        let end: Date?
        /// Decoded date-components text as stored (`PS29` / `PS30`).
        let startText: String
        let endText: String
        let occurrenceText: String
    }

    let id: Int64
    var classID = ""
    var title = "Untitled event"
    var isAllDay = false
    var occurrences: [Occurrence] = []
    var participants: [Participant] = []
    var locationID: Int64?
    var locationName = ""
    var conferenceURLs: [String] = []
    var urls: [String] = []
    var identifiers: [(type: String, value: String)] = []
    var sources: Int64 = 0
    var confidence = 0.0
    var updated = 0.0
    var rows = 0

    var start: Date? { occurrences.compactMap(\.start).min() }
    var end: Date? { occurrences.compactMap(\.end).max() }
    var startText: String { start.map { isAllDay ? DossierDate.day($0) : DossierDate.sortable($0) } ?? (occurrences.first?.startText ?? "") }
    var attendeeCount: Int { Set(participants.map(\.node)).count }
    var organizer: Participant? { participants.first { $0.isOrganizer } }

    static let maxRows = 400_000

    static func load(index: GraphIndex) async throws -> [EventInfo] {
        let db = try await GraphPaths.open(GraphPaths.graph)
        guard await db.hasColumns("event_graph", GraphStore.graphColumns) else {
            throw DossierError.missing("graph.db has no event_graph table on this macOS version.")
        }
        let rows = try await db.rows(GraphStore.selectTriple + "event_graph ORDER BY subject LIMIT ?", [.integer(Int64(maxRows))], maxRows: maxRows)
        var bySubject: [Int64: [Triple]] = [:]
        var order: [Int64] = []
        for r in rows {
            guard let t = GraphStore.triple(r) else { continue }
            if bySubject[t.subject] == nil { order.append(t.subject) }
            bySubject[t.subject, default: []].append(t)
        }
        var events: [EventInfo] = []
        events.reserveCapacity(order.count)
        for subject in order {
            guard let triples = bySubject[subject] else { continue }
            var e = EventInfo(id: subject)
            e.rows = triples.count
            e.updated = triples.map(\.timestamp).max() ?? 0
            e.sources = triples.reduce(0) { $0 | $1.sources }
            e.confidence = triples.map(\.confidence).min() ?? 0
            for s in Statement.group(triples) {
                switch s.predicate {
                case P.isA: e.classID = s.simpleValue ?? ""
                case P.name: if let v = s.simpleValue, !v.trimmingCharacters(in: .whitespaces).isEmpty { e.title = v.trimmingCharacters(in: .whitespaces) }
                case "nm_isAllDay": e.isAllDay = ["1", "true"].contains((s.simpleValue ?? "").lowercased())
                case P.conferenceURL: if let v = s.simpleValue { e.conferenceURLs.append(v) }
                case P.url: if let v = s.simpleValue { e.urls.append(v) }
                case P.hasDate:
                    let start = s.field("nm_imputedStartTime").flatMap(Double.init).map { DossierDate.cocoa($0) }
                    let end = s.field("nm_imputedEndTime").flatMap(Double.init).map { DossierDate.cocoa($0) }
                    e.occurrences.append(Occurrence(
                        id: s.relationshipId, start: start, end: end,
                        startText: s.field(P.startTime).flatMap { GraphFormat.dateComponents($0)?.text } ?? "",
                        endText: s.field(P.endTime).flatMap { GraphFormat.dateComponents($0)?.text } ?? "",
                        occurrenceText: s.field("nm_occurrenceDate").flatMap { GraphFormat.dateComponents($0)?.text } ?? ""))
                case P.attendee, P.organizer:
                    for ref in s.fields(P.attendeeID).compactMap(GraphRef.parse) {
                        e.participants.append(Participant(node: ref, name: index.name(ref) ?? "Unknown person", role: s.field(P.obligation) ?? "", isOrganizer: s.predicate == P.organizer))
                    }
                case P.locationRel:
                    if let ref = s.field(P.hasLocation).flatMap(GraphRef.parse) {
                        e.locationID = ref
                        e.locationName = index.name(ref) ?? ""
                    }
                case P.identifier:
                    e.identifiers.append((s.field(P.identifierType) ?? "identifier", s.field(P.identifierID) ?? ""))
                default: break
                }
            }
            e.occurrences.sort { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
            events.append(e)
        }
        // Strictly newest start first (upcoming events lead, undated ones trail); the Events
        // table marks upcoming rows and offers an Upcoming / Past filter.
        return events.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
    }

    /// Whether the event starts at or after `now` (undated events count as past).
    func isUpcoming(at now: Date) -> Bool { (start ?? .distantPast) >= now }

    /// Length of the first occurrence, nil for all-day or open-ended events.
    var duration: TimeInterval? {
        guard !isAllDay, let o = occurrences.first, let s = o.start, let e = o.end, e > s else { return nil }
        return e.timeIntervalSince(s)
    }

    /// "30 min", "1 h", "1 h 30 min", "2 d 4 h": calendar-style, zero components dropped.
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = Int((seconds / 60).rounded())
        let parts: [(Int, String)] = [(minutes / 1440, "d"), (minutes % 1440 / 60, "h"), (minutes % 60, "min")]
        return parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " ")
    }
}

/// Which side of "now" the Events table shows; matches the chart legend.
enum EventScope: String, CaseIterable, Identifiable {
    case all, upcoming, past
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .upcoming: "Upcoming"
        case .past: "Past"
        }
    }
}

// MARK: - View

/// (5) Events: calendar events mirrored into the graph.
struct EventsSection: View {
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @Environment(\.privacyMode) private var privacyMode
    @State private var selected: Int64?
    @State private var inspectedEntity: Int64?
    @State private var filter = ""
    @State private var scope: EventScope = .all

    private struct Loaded: Sendable {
        let events: [EventInfo]
        let index: GraphIndex
        var byID: [Int64: EventInfo] { Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    }

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (selected, inspectedEntity, filter, scope)
        let token = refreshToken
        // Read state here so SwiftUI re-evaluates this body (the content closures below run inside AsyncContent).
        let _ = (selected, inspectedEntity)
        VStack(spacing: 0) {
            ExplainerBar(text: "Calendar events the graph pipeline copied from EventKit: a rolling window around today with decoded dates, attendees resolved to people nodes, locations and video-call links. Titles and join links are sensitive.")
            Divider()
            AsyncContent(reloadKey: token, emptyTitle: "No Events in the Graph", emptySymbol: "calendar") {
                await GraphStore.shared.sync(token: token)
                let index = try await GraphStore.shared.index()
                return Loaded(events: try await GraphStore.shared.events(), index: index)
            } isEmpty: { $0.events.isEmpty } content: { loaded in
                content(loaded)
            }
            StoreFooter(GraphPaths.graph, note: "event_graph")
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink else { return }
            if link.payload.hasPrefix("event:"), let id = Int64(link.payload.dropFirst(6)) { selected = id }
            else if !link.payload.isEmpty { filter = link.payload }
        }
    }

    @ViewBuilder
    private func content(_ loaded: Loaded) -> some View {
        let events = loaded.events
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                StatTileRow(stats(events), minTileWidth: 130)
                    .frame(maxWidth: 460)
                timeline(events)
                    .frame(maxWidth: .infinity)
                    .frame(height: 128)
                    .card(padding: 10)
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.vertical, 14)
            Divider()
            let now = Date()
            let upcoming = events.filter { $0.isUpcoming(at: now) }
            let past = events.filter { !$0.isUpcoming(at: now) }
            let shown = scope == .all ? events : (scope == .upcoming ? upcoming : past)
            PagedTable(
                rows: shown,
                columns: columns(loaded.index, now: now),
                searchPrompt: "Filter events",
                reloadKey: AnyHashable([AnyHashable(scope), AnyHashable(events.count)]),
                exportName: "graph-events",
                emptyTitle: scope == .upcoming ? "No Upcoming Events" : (scope == .past ? "No Past Events" : "No Events"),
                filter: $filter,
                // Upcoming alone reads best soonest-first; everything else newest-first.
                initialSort: PageSort(columnID: "start", ascending: scope == .upcoming),
                onSelect: { rows in
                    if rows.count == 1 { selected = rows[0].id; inspectedEntity = nil } else if rows.isEmpty { selected = nil }
                }
            ) {
                // Collapses to a pop-up when the inspector leaves no room beside the filter field.
                AdaptivePicker(title: "Show", selection: $scope, reserve: 150) {
                    Text("All  \(Format.count(events.count))").tag(EventScope.all)
                    Text("Upcoming  \(Format.count(upcoming.count))").tag(EventScope.upcoming)
                    Text("Past  \(Format.count(past.count))").tag(EventScope.past)
                }
                .layoutPriority(1)
            }
            // The initial sort is only read when the table is created.
            .id(scope)
            .detailInspector(isPresented: Binding(get: { selected != nil || inspectedEntity != nil }, set: { if !$0 { selected = nil; inspectedEntity = nil } })) {
                if let inspectedEntity {
                    EntityInspector(entityID: inspectedEntity, subtitle: selected == nil ? "Knowledge graph node" : "From event", onClose: { self.inspectedEntity = nil })
                } else if let selected, let event = loaded.byID[selected] {
                    inspector(event, loaded.index)
                } else if let selected {
                    EntityInspector(entityID: selected, onClose: { self.selected = nil })
                }
            }
        }
    }

    private func stats(_ events: [EventInfo]) -> [Stat] {
        let now = Date()
        let upcoming = events.filter { ($0.start ?? .distantPast) >= now }.count
        let people = Set(events.flatMap { $0.participants.map(\.node) }).count
        let calls = events.filter { !$0.conferenceURLs.isEmpty }.count
        return [
            Stat("Events", Format.count(events.count), caption: "\(upcoming) upcoming", symbol: "calendar", tint: .red),
            Stat("People Involved", Format.count(people), caption: "attendees + organizers", symbol: "person.2"),
            Stat("With Call Link", Format.count(calls), caption: "video conference URL", symbol: "video", tint: .orange),
        ]
    }

    private struct DayBin: Identifiable { let id: Date; let count: Int; let upcoming: Bool }

    @ViewBuilder
    private func timeline(_ events: [EventInfo]) -> some View {
        let calendar = Calendar.current
        let now = Date()
        let bins: [DayBin] = Dictionary(grouping: events.flatMap { $0.occurrences.compactMap(\.start) }) { calendar.startOfDay(for: $0) }
            .map { DayBin(id: $0.key, count: $0.value.count, upcoming: $0.key >= calendar.startOfDay(for: now)) }
            .sorted { $0.id < $1.id }
        if bins.isEmpty {
            Text("No dated occurrences").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                // Own legend in the title row: the chart's built-in one collides with the y-axis labels.
                HStack(spacing: 10) {
                    Text("Occurrences per day").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    ForEach([("Past", Color.secondary.opacity(0.55)), ("Upcoming", Color.red.opacity(0.8))], id: \.0) { item in
                        HStack(spacing: 4) {
                            Circle().fill(item.1).frame(width: 7, height: 7)
                            Text(item.0).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .fixedSize()
                    }
                }
                Chart {
                    ForEach(bins) { bin in
                        BarMark(x: .value("Day", bin.id, unit: .day), y: .value("Events", bin.count))
                            .foregroundStyle(by: .value("When", bin.upcoming ? "Upcoming" : "Past"))
                            .cornerRadius(2)
                    }
                    RuleMark(x: .value("Now", now))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartForegroundStyleScale(["Past": Color.secondary.opacity(0.55), "Upcoming": Color.red.opacity(0.8)])
                .chartLegend(.hidden)
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
                .chartXAxis { AxisMarks(preset: .aligned, values: .automatic(desiredCount: 5)) { AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            }
        }
    }

    private func columns(_ index: GraphIndex, now: Date) -> [PagedColumn<EventInfo>] {
        [
            PagedColumn<EventInfo>("Start", id: "start", width: 215, min: 130) { $0.startText }
                .sortKey { $0.start?.timeIntervalSinceReferenceDate ?? -.infinity }
                .cell { e in
                    HStack(spacing: 6) {
                        Text(e.startText).font(.callout).monospacedDigit().lineLimit(1)
                        if e.isUpcoming(at: now) { TagLabel("upcoming", tint: .red) }
                    }
                    .help(e.start.map { DossierDate.medium($0) } ?? "")
                },
            PagedColumn<EventInfo>("Title", id: "title", width: 280, min: 140, sensitivity: .sensitive) { $0.title },
            PagedColumn<EventInfo>("Duration", id: "duration", width: 90, alignment: .trailing) { e in
                e.isAllDay ? "all day" : (e.duration.map(EventInfo.durationText) ?? "")
            }
            .sortKey { e in e.isAllDay ? 86_400 : (e.duration ?? -1) },
            PagedColumn<EventInfo>("Attendees", id: "attendees", width: 75, alignment: .trailing) { $0.attendeeCount == 0 ? "" : "\($0.attendeeCount)" },
            PagedColumn<EventInfo>("Organizer", id: "organizer", width: 160, sensitivity: .sensitive) { $0.organizer?.name ?? "" },
            PagedColumn<EventInfo>("Location", id: "location", width: 190, sensitivity: .sensitive) { $0.locationName },
            PagedColumn<EventInfo>("Call", id: "call", width: 50, sortable: false) { $0.conferenceURLs.isEmpty ? "" : "link" }
                .cell { e in
                    if !e.conferenceURLs.isEmpty {
                        Image(systemName: "video.fill").foregroundStyle(.orange).help("Has a video-conference link (sensitive)")
                    }
                },
            PagedColumn<EventInfo>("Repeats", id: "occurrences", width: 65, alignment: .trailing) { $0.occurrences.count > 1 ? "\($0.occurrences.count)×" : "" },
            PagedColumn<EventInfo>("Updated", id: "updated", width: 150, secondary: true, hiddenByDefault: true) { DossierDate.sortable($0.updated > 0 ? DossierDate.cocoa($0.updated) : nil) },
            PagedColumn<EventInfo>("Node id", id: "id", width: 170, monospaced: true, secondary: true, hiddenByDefault: true) { GraphRef.string($0.id) },
        ]
    }

    private func inspector(_ e: EventInfo, _ index: GraphIndex) -> some View {
        InspectorPage(title: e.title, subtitle: "Event node · class \(e.classID.isEmpty ? "unknown" : e.classID)", sensitivity: .sensitive, onClose: { selected = nil }) {
            KeyValueGrid([
                KeyValueItem("Starts", e.start.map { DossierDate.medium($0) } ?? "—"),
                KeyValueItem("Ends", e.end.map { DossierDate.medium($0) } ?? "—"),
                KeyValueItem("All day", e.isAllDay ? "Yes" : "No"),
                KeyValueItem("Location", e.locationName.isEmpty ? "—" : e.locationName, sensitivity: .sensitive),
                KeyValueItem("Graph rows", Format.count(e.rows)),
                KeyValueItem("Updated", DossierDate.medium(e.updated > 0 ? DossierDate.cocoa(e.updated) : nil)),
            ])
            HStack(spacing: 6) {
                SourceBadges(mask: e.sources, catalog: index.sources)
                ConfidencePill(value: e.confidence)
            }
            if !e.conferenceURLs.isEmpty || !e.urls.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        InspectorGroupTitle("Links")
                        SensitivityBadge(.sensitive, compact: true)
                    }
                    ForEach(Array((e.conferenceURLs + e.urls).enumerated()), id: \.offset) { i, url in
                        HStack(spacing: 5) {
                            Image(systemName: i < e.conferenceURLs.count ? "video" : "link").foregroundStyle(.secondary).imageScale(.small)
                            Text(url).font(.callout.monospaced()).lineLimit(2).textSelection(.enabled).sensitive(.sensitive)
                        }
                    }
                    Text("Join links grant access to a meeting; the graph keeps them in clear text.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            if !e.participants.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    InspectorGroupTitle("People (\(e.attendeeCount))")
                    ForEach(e.participants) { p in
                        HStack(spacing: 6) {
                            Image(systemName: p.isOrganizer ? "person.badge.key.fill" : "person.fill").foregroundStyle(p.isOrganizer ? Color.orange : Color.blue).imageScale(.small)
                            Button(p.name) { inspectedEntity = p.node }
                                .buttonStyle(.link).font(.callout).lineLimit(1)
                                .sensitive(.sensitive)
                            if p.node == index.ownerID { TagLabel("you", tint: .accentColor) }
                            Spacer(minLength: 0)
                            Text(p.isOrganizer ? "organizer" : (p.role.isEmpty ? "attendee" : p.role)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !e.occurrences.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    InspectorGroupTitle("Date facets (\(e.occurrences.count))")
                    ForEach(e.occurrences.prefix(30)) { o in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(DossierDate.medium(o.start)) → \(o.end.map { DossierDate.short($0) } ?? "—")").font(.callout).monospacedDigit()
                            Text("stored components: \(o.startText.isEmpty ? "—" : o.startText)\(o.occurrenceText.isEmpty ? "" : " · occurrence \(o.occurrenceText)")")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            if !e.identifiers.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    InspectorGroupTitle("Identifiers")
                    ForEach(Array(e.identifiers.enumerated()), id: \.offset) { _, ident in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ident.type).font(.caption).foregroundStyle(.secondary)
                            Text(ident.value).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle).textSelection(.enabled).sensitive(.personal)
                        }
                    }
                }
            }
            if let location = e.locationID {
                Button("Show location node") { inspectedEntity = location }.buttonStyle(.link).font(.callout)
            }
            Button("Show all raw statements") { inspectedEntity = e.id }.buttonStyle(.link).font(.callout)
        }
    }
}
