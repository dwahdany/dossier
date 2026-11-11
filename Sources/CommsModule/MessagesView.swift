import SwiftUI
import DossierCore

/// (4) Messages timeline — every message interaction in Siri Remembers, paged in SQL,
/// with the retained text from knowledgeC attached where the system still has it.
struct MessagesView: View {
    enum RangePreset: String, CaseIterable, Identifiable {
        case all = "All Time", week = "Last 7 Days", month = "Last 30 Days", quarter = "Last 90 Days", custom = "Custom…"
        var id: String { rawValue }
    }

    @State private var apps: [String] = []
    @State private var app = ""
    @State private var direction = 0
    @State private var preset = RangePreset.all
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var hasText = false
    @State private var person: String?
    @State private var personLabel = ""
    @State private var conversation: String?
    @State private var selected: MessageRow?
    @State private var textCount: Int?
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink

    private var filter: MessageFilter {
        var f = MessageFilter()
        f.bundle = app.isEmpty ? nil : app
        f.direction = direction == 0 ? nil : CommDirection(rawValue: direction)
        f.hasText = hasText
        f.person = person
        f.conversation = conversation
        let now = Date()
        switch preset {
        case .all: break
        case .week: f.from = now.addingTimeInterval(-7 * 86_400)
        case .month: f.from = now.addingTimeInterval(-30 * 86_400)
        case .quarter: f.from = now.addingTimeInterval(-90 * 86_400)
        case .custom:
            f.from = Calendar.current.startOfDay(for: from)
            f.to = Calendar.current.startOfDay(for: to).addingTimeInterval(86_400)
        }
        return f
    }

    /// Reload key without the moving "now" of the relative presets.
    private var filterKey: [AnyHashable] {
        [app, direction, preset.rawValue, hasText, person ?? "", conversation ?? "",
         preset == .custom ? from.timeIntervalSince1970 : 0, preset == .custom ? to.timeIntervalSince1970 : 0, refreshToken]
    }

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (apps, app, direction, preset, from, to, hasText, person, personLabel, conversation, selected, textCount)
        let token = refreshToken
        let filter = filter
        VStack(spacing: 0) {
            HeaderStrip {
                Picker("App", selection: $app) {
                    Text("All Apps").tag("")
                    Divider()
                    ForEach(apps, id: \.self) { Text(AppNames.name($0)).tag($0) }
                }
                .labelsHidden().frame(minWidth: 110, maxWidth: 150)
                Picker("Direction", selection: $direction) {
                    Text("All").tag(0)
                    Text("Incoming").tag(1)
                    Text("Outgoing").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(minWidth: 190, maxWidth: 210)
                Picker("Range", selection: $preset) {
                    ForEach(RangePreset.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(minWidth: 105, maxWidth: 130)
                Toggle(isOn: $hasText) {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.doc").foregroundStyle(.orange)
                        Text(textCount.map { "Has text (\(Format.count($0)))" } ?? "Has text").lineLimit(1)
                    }
                }
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Only messages whose body text is still retained in knowledgeC")
                Spacer(minLength: 0)
            }
            if preset == .custom {
                // Its own row: next to the other controls the two date fields do not fit
                // the minimum window.
                HStack(spacing: 8) {
                    Text("From").font(.caption).foregroundStyle(.secondary)
                    DatePicker("From", selection: $from, displayedComponents: .date).labelsHidden().frame(width: 100)
                    Text("to").font(.caption).foregroundStyle(.secondary)
                    DatePicker("To", selection: $to, displayedComponents: .date).labelsHidden().frame(width: 100)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            }
            if person != nil || conversation != nil {
                HStack(spacing: 8) {
                    Text("Showing only").font(.caption).foregroundStyle(.secondary)
                    if person != nil {
                        chip(symbol: "person.crop.circle", text: personLabel) { person = nil }
                    }
                    if let conversation {
                        chip(symbol: "bubble.left.and.bubble.right", text: Format.oneLine(conversation, max: 60)) { self.conversation = nil }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            }
            PagedTable(
                columns: columns,
                searchPrompt: "Filter person, handle, conversation",
                reloadKey: AnyHashable(filterKey),
                exportName: "messages",
                emptyTitle: "No Messages",
                fetch: { request in
                    let texts = await IntentStore.shared.snapshotOrEmpty(token: token).textByIntentID
                    let namer = await CommsCache.shared.deviceNamer(token)
                    return try await RemembersStore.messages(filter, request: request, texts: texts, namer: namer)
                },
                count: { request in
                    let texts = await IntentStore.shared.snapshotOrEmpty(token: token).textByIntentID
                    return try await RemembersStore.messageCount(filter, search: request.search, texts: texts)
                },
                onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
            )
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { inspector(selected) }
            }
            StoreFooter(CommsPaths.remembersView, note: "interactions (INSendMessageIntent) + text from knowledgeC /app/intents")
        }
        .task(id: token) {
            await SnapshotReadiness.track {
                apps = (try? await RemembersStore.messageApps()) ?? []
                let snapshot = await IntentStore.shared.snapshotOrEmpty(token: token)
                var onlyText = MessageFilter()
                onlyText.hasText = true
                // Count what the timeline can actually show: retained texts whose interaction is in Siri Remembers.
                textCount = (try? await RemembersStore.messageCount(onlyText, search: "", texts: snapshot.textByIntentID)) ?? 0
            }
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink else { return }
            if link.payload.hasPrefix("person:") {
                let key = String(link.payload.dropFirst("person:".count))
                person = key
                personLabel = String(key.dropFirst(2))
                conversation = nil
            } else if link.payload.hasPrefix("conversation:") {
                conversation = String(link.payload.dropFirst("conversation:".count))
                person = nil
            } else if link.payload == "hastext" {
                hasText = true
            }
        }
    }

    private func chip(symbol: String, text: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).imageScale(.small)
            Text(text).font(.caption).lineLimit(1).sensitive(.sensitive)
            Button(action: remove) { Image(systemName: "xmark.circle.fill").imageScale(.small) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.14), in: Capsule())
    }

    private var columns: [PagedColumn<MessageRow>] {
        [
            PagedColumn<MessageRow>("Time", id: "startDate", width: 150, min: 146) { DossierDate.sortable($0.date) },
            PagedColumn("App", id: "bundleId", width: 110, min: 84, sensitivity: .personal) { AppNames.name($0.bundle) },
            PagedColumn("Dir", id: "direction", width: 56) { $0.direction.label }
                .cell { DirectionCell(direction: $0.direction) },
            PagedColumn("Person", id: "person", width: 180, min: 80, sortable: false, sensitivity: .sensitive) { $0.person }
                .cell { row in
                    Text(row.person.isEmpty ? "—" : row.person).font(.callout).lineLimit(1)
                        .foregroundStyle(row.person.isEmpty ? .tertiary : .primary)
                },
            PagedColumn("Conversation", id: "title", width: 200, min: 80, sortable: false, sensitivity: .sensitive) { $0.title }
                .cell { row in
                    HStack(spacing: 4) {
                        if row.isGroup { Image(systemName: "person.3.fill").imageScale(.small).foregroundStyle(.secondary) }
                        Text(row.title.isEmpty ? "—" : Format.oneLine(row.title, max: 160)).font(.callout).lineLimit(1)
                            .foregroundStyle(row.title.isEmpty ? .tertiary : .primary)
                    }
                },
            PagedColumn("Retained Text", id: "text", width: 320, min: 120, sortable: false, sensitivity: .sensitive) { $0.text ?? "" }
                .cell { row in
                    if let text = row.text {
                        HStack(spacing: 5) {
                            Image(systemName: row.textIsCode ? "key.fill" : "lock.doc.fill").imageScale(.small).foregroundStyle(.orange)
                            Text(Format.oneLine(text, max: 200)).font(.callout).lineLimit(1)
                        }
                    } else {
                        Text("not retained").font(.callout).foregroundStyle(.tertiary)
                    }
                },
            PagedColumn("Device", id: "device", width: 130, sortable: false, sensitivity: .personal, secondary: true, hiddenByDefault: true) { $0.device },
            PagedColumn("Interaction ID", id: "id", width: 280, sortable: false, monospaced: true, secondary: true, hiddenByDefault: true) { $0.interactionID },
        ]
    }

    // MARK: Inspector

    private struct EntityLine: Sendable, Identifiable {
        let id: Int
        let parameter: String
        let type: String
        let value: String
        let fields: String
    }

    @ViewBuilder private func inspector(_ row: MessageRow) -> some View {
        InspectorPage(title: row.person.isEmpty ? (row.title.isEmpty ? "Message" : Format.oneLine(row.title, max: 60)) : row.person,
                      subtitle: "\(AppNames.name(row.bundle)) · \(row.direction.label)", sensitivity: .sensitive, onClose: { selected = nil }) {
            if let text = row.text {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        InspectorGroupTitle("Retained message text")
                        Spacer()
                        if row.textIsCode { TagLabel("looks like a one-time code", tint: .red) }
                        SensitivityBadge(.sensitive, compact: true)
                    }
                    Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).sensitive(.sensitive)
                }
                .card(padding: 10)
            } else {
                Text("The body of this message is not stored. Siri Remembers keeps who, when and where; the text exists only for recent messages in knowledgeC.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            KeyValueGrid([
                KeyValueItem("Time", DossierDate.medium(row.date)),
                KeyValueItem("App", AppNames.name(row.bundle), sensitivity: .personal),
                KeyValueItem("Bundle id", row.bundle, monospaced: true),
                KeyValueItem("Direction", row.direction.label),
                KeyValueItem(row.direction == .incoming ? "From" : "To", row.person.isEmpty ? nil : row.person, sensitivity: .sensitive),
                KeyValueItem("Conversation", row.title.isEmpty ? nil : row.title, sensitivity: .sensitive),
                KeyValueItem("Group", row.isGroup ? "yes" : "no"),
                KeyValueItem("Recorded on", row.device, sensitivity: .personal),
                KeyValueItem("Handling status", RemembersSchema.statusLabel(row.status)),
                KeyValueItem("Interaction ID", row.interactionID, monospaced: true),
            ])
            InspectorGroupTitle("Linked entities")
            AsyncContent(reloadKey: row.id) {
                try await RemembersStore.interactionEntities(row.id).enumerated().map {
                    EntityLine(id: $0.offset, parameter: $0.element.parameter, type: $0.element.type, value: $0.element.id, fields: $0.element.fields)
                }
            } content: { entities in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entities) { entity in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(entity.parameter) · \(entity.type)").font(.caption).foregroundStyle(.secondary)
                            Text(entity.value).font(.callout.monospaced()).lineLimit(3).textSelection(.enabled).sensitive(.sensitive)
                            if entity.fields.count > 2 {
                                Text(entity.fields).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(3).sensitive(.sensitive)
                            }
                        }
                    }
                    if entities.isEmpty { Text("No linked entities.").font(.callout).foregroundStyle(.secondary) }
                }
            }
            .frame(minHeight: 60)
        }
    }
}
