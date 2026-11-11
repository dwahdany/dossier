import SwiftUI
import Charts
import DossierCore

/// (7) Retained verbatim content — where the system keeps actual words (message bodies,
/// subject lines, meeting keywords) rather than metadata, with one-time-code-like texts flagged.
struct RetainedContentView: View {
    @State private var selected: IntentRecord?
    @State private var codesOnly = false
    @State private var filter = ""
    @State private var showRaw = false
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink

    private struct AppLine: Sendable, Identifiable {
        var id: String { bundle }
        let bundle: String
        let withText: Int
        let total: Int
        let codes: Int
        let characters: Int
    }

    private struct OtherLine: Sendable, Identifiable {
        var id: String { what }
        let what: String
        let store: String
        let count: Int
    }

    private struct Loaded: Sendable {
        let apps: [AppLine]
        let texts: Int
        let codes: Int
        let characters: Int
        let messageIntents: Int
        let range: ClosedRange<Date>?
        let oldestText: Date?
        let truncated: Bool
        let other: [OtherLine]
    }

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (selected, codesOnly, filter, showRaw)
        let token = refreshToken
        let codesOnly = codesOnly
        VStack(spacing: 0) {
            AsyncContent(reloadKey: token) {
                try await Self.load(token)
            } content: { loaded in
                SummaryOverTable {
                    summary(loaded)
                } table: {
                    PagedTable(
                        columns: columns,
                        searchPrompt: "Search retained text, people or apps",
                        reloadKey: AnyHashable([AnyHashable(token), AnyHashable(codesOnly)]),
                        exportName: "retained-text",
                        emptyTitle: "No Retained Text",
                        filter: $filter,
                        fetch: { request in try await Self.table(token, codesOnly: codesOnly).page(request) },
                        count: { request in try await Self.table(token, codesOnly: codesOnly).count(request) },
                        onSelect: { rows in selected = rows.count == 1 ? rows.first : nil; showRaw = false },
                        accessory: {
                            Toggle(isOn: $codesOnly) {
                                HStack(spacing: 4) {
                                    Image(systemName: "key.fill").foregroundStyle(.red)
                                    Text("Only likely codes")
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    )
                    .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                        if let selected { inspector(selected) }
                    }
                }
            }
            StoreFooter(Paths.knowledgeC, note: "ZOBJECT /app/intents ⨝ ZSTRUCTUREDMETADATA (serialized INInteraction)")
        }
        .task(id: deepLink?.nonce) {
            guard let link = deepLink, link.payload.hasPrefix("intent:"), let pk = Int64(link.payload.dropFirst("intent:".count)) else { return }
            await SnapshotReadiness.track {
                let snapshot = await IntentStore.shared.snapshotOrEmpty(token: token)
                selected = snapshot.records.first { $0.id == pk }
            }
        }
    }

    private static func load(_ token: Int) async throws -> Loaded {
        let snapshot = try await IntentStore.shared.snapshot(token: token)
        let messages = snapshot.records.filter { $0.kind == .message }
        var apps: [String: (withText: Int, total: Int, codes: Int, characters: Int)] = [:]
        for record in messages {
            var entry = apps[record.bundle] ?? (0, 0, 0, 0)
            entry.total += 1
            if let text = record.text {
                entry.withText += 1
                entry.characters += text.count
                if record.isCode { entry.codes += 1 }
            }
            apps[record.bundle] = entry
        }
        let lines = apps.map { AppLine(bundle: $0.key, withText: $0.value.withText, total: $0.value.total, codes: $0.value.codes, characters: $0.value.characters) }
            .sorted { ($0.withText, $0.total) > ($1.withText, $1.total) }
        var other: [OtherLine] = []
        if let conversations = try? await CommsCache.shared.conversations(token) {
            for kind in [ConversationRow.Kind.mailSubject, .issueTitle, .contentLike] {
                let rows = conversations.rows.filter { $0.kind == kind }
                guard !rows.isEmpty else { continue }
                let appNames = Set(rows.map { AppNames.name($0.bundle) }).sorted().joined(separator: ", ")
                let what: String
                switch kind {
                case .mailSubject: what = "Mail subject lines (\(appNames))"
                case .issueTitle: what = "Issue / ticket titles (\(appNames))"
                default: what = "Per-message titles (\(appNames))"
                }
                other.append(OtherLine(what: what, store: "Siri Remembers · conversation titles", count: rows.count))
            }
            let names = conversations.rows.filter { !$0.isContent }.count
            if names > 0 { other.append(OtherLine(what: "Conversation and group names", store: "Siri Remembers · conversation titles", count: names)) }
        }
        if let overview = try? await InteractionCStore.overview(), !overview.keywords.isEmpty {
            other.append(OtherLine(what: "Keywords from meeting titles", store: "interactionC · ZKEYWORDS", count: overview.keywords.count))
        }
        let texts = snapshot.withText
        return Loaded(
            apps: lines, texts: texts.count, codes: texts.filter(\.isCode).count,
            characters: texts.reduce(0) { $0 + ($1.text?.count ?? 0) }, messageIntents: messages.count,
            range: snapshot.range, oldestText: texts.compactMap(\.date).min(), truncated: snapshot.truncated, other: other)
    }

    // MARK: Summary

    private func summary(_ loaded: Loaded) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StatTileRow([
                Stat("Message Bodies Kept", Format.count(loaded.texts), caption: "of \(Format.count(loaded.messageIntents)) recent message intents", symbol: "lock.doc", tint: .orange),
                Stat("Characters", Format.compact(loaded.characters), caption: "verbatim text", symbol: "textformat.size", tint: .orange),
                Stat("Likely One-Time Codes", Format.count(loaded.codes), caption: "flagged by a generic pattern", symbol: "key", tint: .red),
                Stat("Oldest Kept Text", loaded.oldestText.map { DossierDate.relative($0) } ?? "—", caption: DossierDate.day(loaded.oldestText), symbol: "clock.arrow.circlepath", tint: .purple),
            ], minTileWidth: 170)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Message intents with body text, per app").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    appChart(loaded).frame(minHeight: 118)
                    // The chart keeps its minimum height; the explanation uses what is left
                    // and falls back to a shorter wording in a narrow card.
                    ViewThatFits(in: .vertical) {
                        Text("Apps that route notifications through the system's communication-notification API hand over the message text with each donation; apps that only announce “new message” do not. Texts live in knowledgeC until it expires them (a few weeks).")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Apps using the communication-notification API hand over the message text; others do not. knowledgeC expires it after a few weeks.")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Text is kept for a few weeks.").lineLimit(1)
                    }
                    .font(.caption).foregroundStyle(.tertiary)
                    .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .card(padding: 12)
                .frame(minWidth: 250)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Other verbatim content in communication stores").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if loaded.other.isEmpty {
                        Text("None found.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(loaded.other) { line in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(line.what).font(.callout).lineLimit(2).sensitive(.personal)
                                Text(line.store).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(Format.count(line.count)).font(.callout).monospacedDigit()
                        }
                        .padding(.vertical, 1)
                    }
                    Spacer(minLength: 0)
                    if loaded.truncated {
                        Text("Only the newest \(Format.count(IntentStore.maxRecords)) intents were decoded.").font(.caption).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .card(padding: 12)
                .frame(minWidth: 290, maxWidth: 400)
            }
            .frame(height: 216)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private struct AppPoint: Identifiable {
        var id: String { "\(app)|\(series)" }
        let app: String
        let series: String
        let count: Int
    }

    private func appChart(_ loaded: Loaded) -> some View {
        let apps = Array(loaded.apps.prefix(6))
        let points = apps.flatMap { line -> [AppPoint] in
            let name = AppNames.name(line.bundle)
            return [AppPoint(app: name, series: "With text", count: line.withText), AppPoint(app: name, series: "Metadata only", count: line.total - line.withText)]
        }
        return Chart(points) { point in
            BarMark(x: .value("Intents", point.count), y: .value("App", point.app))
                .foregroundStyle(by: .value("Kind", point.series))
        }
        .chartForegroundStyleScale(domain: ["With text", "Metadata only"], range: [Color.orange, Color.secondary.opacity(0.35)])
        .chartYScale(domain: apps.map { AppNames.name($0.bundle) })
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let v = value.as(Int.self) { Text(Format.compact(v)).font(.caption2) } }
            }
        }
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .leading) { value in
                AxisValueLabel { if let label = value.as(String.self) { Text(label).font(.caption).sensitive(.personal) } }
            }
        }
        .chartLegend(position: .top, alignment: .trailing, spacing: 2)
        .frame(maxHeight: .infinity)
    }

    // MARK: Table

    private static func table(_ token: Int, codesOnly: Bool) async throws -> MemoryTable<IntentRecord> {
        let snapshot = try await IntentStore.shared.snapshot(token: token)
        var rows = snapshot.withText
        if codesOnly { rows = rows.filter(\.isCode) }
        return MemoryTable(
            rows: rows,
            search: { [$0.text ?? "", $0.counterpart, $0.groupName ?? "", AppNames.name($0.bundle), $0.serviceName ?? ""].joined(separator: " ") },
            keys: [
                "date": .number { $0.date?.timeIntervalSince1970 ?? 0 },
                "app": .text { AppNames.name($0.bundle) },
                "direction": .number { Double($0.direction.rawValue) },
                "who": .text { $0.counterpart },
                "conversation": .text { $0.groupName ?? "" },
                "text": .text { $0.text ?? "" },
                "length": .number { Double($0.text?.count ?? 0) },
                "flag": .number { $0.isCode ? 1 : 0 },
            ])
    }

    private var columns: [PagedColumn<IntentRecord>] {
        [
            PagedColumn<IntentRecord>("Time", id: "date", width: 150, min: 146) { DossierDate.sortable($0.date) },
            PagedColumn("App", id: "app", width: 100, min: 84, sensitivity: .personal) { AppNames.name($0.bundle) },
            PagedColumn("Dir", id: "direction", width: 56) { $0.direction.label }
                .cell { DirectionCell(direction: $0.direction) },
            PagedColumn("From / To", id: "who", width: 160, min: 80, sensitivity: .sensitive) { $0.counterpart },
            PagedColumn("Conversation", id: "conversation", width: 150, min: 80, sensitivity: .sensitive, hiddenByDefault: true) { $0.groupName ?? "" },
            PagedColumn("Retained Text", id: "text", width: 420, min: 160, sensitivity: .sensitive) { $0.text ?? "" }
                .cell { row in Text(Format.oneLine(row.text ?? "", max: 260)).font(.callout).lineLimit(1) },
            PagedColumn("Chars", id: "length", width: 56, alignment: .trailing, secondary: true) { Format.count($0.text?.count ?? 0) },
            PagedColumn("Flag", id: "flag", width: 120) { $0.isCode ? "Likely code" : "" }
                .cell { row in
                    if row.isCode { TagLabel("likely code", tint: .red) }
                },
        ]
    }

    // MARK: Inspector

    @ViewBuilder private func inspector(_ record: IntentRecord) -> some View {
        InspectorPage(title: record.counterpart.isEmpty ? AppNames.name(record.bundle) : record.counterpart,
                      subtitle: "\(AppNames.name(record.bundle)) · \(record.direction.label) \(record.kind.rawValue.lowercased())", sensitivity: .sensitive, onClose: { selected = nil }) {
            if let text = record.text {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        InspectorGroupTitle("Retained text")
                        Spacer()
                        if record.isCode { TagLabel("looks like a one-time code", tint: .red) }
                        SensitivityBadge(.sensitive, compact: true)
                    }
                    Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).sensitive(.sensitive)
                }
                .card(padding: 10)
            }
            KeyValueGrid([
                KeyValueItem("Time", DossierDate.medium(record.date)),
                KeyValueItem("App", AppNames.name(record.bundle), sensitivity: .personal),
                KeyValueItem("Bundle id", record.bundle, monospaced: true),
                KeyValueItem("Direction", record.direction.label),
                KeyValueItem("Sender", record.sender.map { $0.handle.isEmpty || $0.handle == $0.name ? $0.display : "\($0.display) (\($0.handle))" }, sensitivity: .sensitive),
                KeyValueItem("Recipients", record.recipients.isEmpty ? nil : record.recipients.map(\.display).joined(separator: ", "), sensitivity: .sensitive),
                KeyValueItem("Conversation", record.groupName, sensitivity: .sensitive),
                KeyValueItem("Service", record.serviceName, sensitivity: .personal),
                KeyValueItem("Conversation id", record.conversationID, sensitivity: .personal, monospaced: true),
                KeyValueItem("Synced from", record.remote ? "another device" : "this Mac"),
                KeyValueItem("Intent id", record.intentID, monospaced: true),
            ])
            DisclosureGroup("Raw record (decoded archive)", isExpanded: $showRaw) {
                if showRaw {
                    AsyncContent(reloadKey: record.id) {
                        guard let blob = await IntentStore.rawBlob(pk: record.id), let tree = IntentDecoder.interaction(blob) else {
                            throw DossierError.message("The record could not be decoded.")
                        }
                        return [DataNode.from(tree, key: "INInteraction")]
                    } content: { nodes in
                        DataTreeView(nodes, sensitivity: .sensitive).frame(height: 320)
                    }
                    .frame(minHeight: 80)
                }
            }
            .font(.callout)
        }
    }
}
