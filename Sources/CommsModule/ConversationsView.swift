import SwiftUI
import DossierCore

/// (3) Conversations / groups — conversation titles with counts per app. Titles that are
/// really content (mail subject lines, issue titles) are flagged.
struct ConversationsView: View {
    @State private var selected: ConversationRow?
    @State private var filter = ""
    @State private var app = ""
    @State private var contentOnly = false
    @State private var data: ConversationData?
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @Environment(\.navigate) private var navigate

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (selected, filter, app, contentOnly, data)
        let token = refreshToken
        let app = app, contentOnly = contentOnly
        VStack(spacing: 0) {
            HeaderStrip {
                Picker("App", selection: $app) {
                    Text("All Apps").tag("")
                    Divider()
                    ForEach(data?.apps ?? []) { stat in
                        Text("\(AppNames.name(stat.bundle)) (\(stat.titles))").tag(stat.bundle)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                Toggle("Only titles that are content", isOn: $contentOnly)
                    .toggleStyle(.checkbox)
                Spacer(minLength: 8)
                HeaderNote("The “conversation name” each app donated with its messages.")
            }
            if let flagged = data?.apps.filter({ $0.contentKind != .conversation }), !flagged.isEmpty {
                contentBanner(flagged)
            }
            PagedTable(
                columns: columns,
                searchPrompt: "Filter titles",
                reloadKey: AnyHashable([AnyHashable(token), AnyHashable(app), AnyHashable(contentOnly)]),
                exportName: "conversations",
                emptyTitle: "No Conversations",
                filter: $filter,
                fetch: { request in try await Self.table(token, app: app, contentOnly: contentOnly).page(request) },
                count: { request in try await Self.table(token, app: app, contentOnly: contentOnly).count(request) },
                onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
            )
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { inspector(selected) }
            }
            StoreFooter(CommsPaths.remembersView, note: "entities (MessageGroup) via speakableGroupName")
        }
        .task(id: token) {
            await SnapshotReadiness.track { data = try? await CommsCache.shared.conversations(token) }
        }
        .task(id: deepLink?.nonce) {
            guard let link = deepLink, link.payload.hasPrefix("title:") else { return }
            let title = String(link.payload.dropFirst("title:".count))
            await SnapshotReadiness.track {
                filter = title
                if let rows = try? await CommsCache.shared.conversations(token).rows { selected = rows.first { $0.key == title || $0.title == title } }
            }
        }
    }

    private func contentBanner(_ flagged: [ConversationAppStat]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
            Text("Not conversation names: ").font(.callout.weight(.medium))
                + Text(flagged.map { "\(AppNames.name($0.bundle)) donates \(label($0.contentKind)) (\($0.titles) kept)" }.joined(separator: "; "))
                .font(.callout)
                + Text(". These titles are verbatim content.").font(.callout)
            Spacer(minLength: 0)
            SensitivityBadge(.sensitive, compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func label(_ kind: ConversationRow.Kind) -> String {
        switch kind {
        case .mailSubject: return "mail subject lines"
        case .issueTitle: return "issue / ticket titles"
        case .contentLike: return "per-message titles"
        case .conversation: return "conversation names"
        }
    }

    private static func table(_ token: Int, app: String, contentOnly: Bool) async throws -> MemoryTable<ConversationRow> {
        var rows = try await CommsCache.shared.conversations(token).rows
        if !app.isEmpty { rows = rows.filter { $0.bundle == app } }
        if contentOnly { rows = rows.filter(\.isContent) }
        return MemoryTable(
            rows: rows,
            search: { $0.title + " " + $0.key + " " + AppNames.name($0.bundle) + " " + $0.kind.rawValue },
            keys: [
                "title": .text { $0.title },
                "app": .text { AppNames.name($0.bundle) },
                "kind": .text { $0.kind.rawValue },
                "count": .number { Double($0.count) },
                "incoming": .number { Double($0.incoming) },
                "outgoing": .number { Double($0.outgoing) },
                "first": .number { $0.first?.timeIntervalSince1970 ?? 0 },
                "last": .number { $0.last?.timeIntervalSince1970 ?? 0 },
            ])
    }

    private var columns: [PagedColumn<ConversationRow>] {
        [
            PagedColumn<ConversationRow>("Title", id: "title", width: 340, min: 140, sensitivity: .sensitive) { $0.title }
                .cell { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.isContent ? "text.quote" : (row.isGroup ? "person.3.fill" : "bubble.left.fill"))
                            .imageScale(.small)
                            .foregroundStyle(row.isContent ? Color.orange : .secondary)
                            .frame(width: 18)
                        Text(Format.oneLine(row.title, max: 240)).font(.callout).lineLimit(1)
                    }
                },
            PagedColumn("App", id: "app", width: 120, min: 84, sensitivity: .personal) { AppNames.name($0.bundle) },
            PagedColumn("Title Is", id: "kind", width: 150, min: 96) { $0.kind.rawValue }
                .cell { row in
                    if row.isContent {
                        TagLabel(row.kind.rawValue, tint: .orange)
                    } else {
                        Text(row.isGroup ? "Group conversation" : "Conversation").font(.callout).foregroundStyle(.secondary)
                    }
                },
            PagedColumn("Messages", id: "count", width: 80, alignment: .trailing) { Format.count($0.count) },
            PagedColumn("In", id: "incoming", width: 60, alignment: .trailing) { Format.count($0.incoming) },
            PagedColumn("Out", id: "outgoing", width: 60, alignment: .trailing) { Format.count($0.outgoing) },
            PagedColumn("First", id: "first", width: 150, min: 146) { DossierDate.sortable($0.first) },
            PagedColumn("Last", id: "last", width: 150, min: 146) { DossierDate.sortable($0.last) },
        ]
    }

    @ViewBuilder private func inspector(_ row: ConversationRow) -> some View {
        InspectorPage(title: Format.oneLine(row.title, max: 80), subtitle: AppNames.name(row.bundle), sensitivity: .sensitive, onClose: { selected = nil }) {
            if row.isContent {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                    Text("This “title” is \(row.kind == .mailSubject ? "a mail subject line" : row.kind == .issueTitle ? "the title of an issue or ticket" : "most likely message content"), stored verbatim as if it were a conversation name.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .card(padding: 10)
            }
            InspectorGroupTitle("Full title")
            Text(row.title).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).sensitive(.sensitive)
            KeyValueGrid([
                KeyValueItem("App", AppNames.name(row.bundle), sensitivity: .personal),
                KeyValueItem("Bundle id", row.bundle, monospaced: true),
                KeyValueItem("Messages", "\(Format.count(row.count)) (\(Format.count(row.incoming)) in · \(Format.count(row.outgoing)) out)"),
                KeyValueItem("Group flag", row.isGroup ? "yes" : "no"),
                KeyValueItem("First", DossierDate.medium(row.first)),
                KeyValueItem("Last", DossierDate.medium(row.last)),
            ])
            if navigate != nil {
                Button("Show Messages in Timeline") { navigate?(DeepLink(sectionID: "comms.messages", payload: "conversation:" + row.key)) }
                    .controlSize(.small)
            }
            AsyncContent(reloadKey: row.id) {
                let detail = try await RemembersStore.conversationDetail(entityID: row.entityID, bundle: row.bundle)
                return ConversationDetailBox(months: detail.months, senders: detail.senders.map { SenderCount(name: $0.name, count: $0.count) })
            } content: { detail in
                VStack(alignment: .leading, spacing: 16) {
                    InspectorGroupTitle("Timeline")
                    PersonTimeline(months: detail.months)
                    if !detail.senders.isEmpty {
                        InspectorGroupTitle("Who writes here")
                        BarChartView(detail.senders.map { ChartBar($0.name, Double($0.count)) }, labelSensitivity: .sensitive)
                    }
                }
            }
            .frame(minHeight: 120)
        }
    }
}

struct SenderCount: Sendable { let name: String; let count: Int }
struct ConversationDetailBox: Sendable { let months: [MonthBucket]; let senders: [SenderCount] }
