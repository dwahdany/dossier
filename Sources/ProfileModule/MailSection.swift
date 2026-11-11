import SwiftUI
import AppKit
import DossierCore

/// (5) Found in Mail: what `suggestd` ("Siri found in apps") extracted from messages —
/// contacts, events and reservations, Wallet passes, links and the text they came from.
struct MailSection: View {
    @State private var kind = MailKind.contacts
    @State private var filter = ""
    @State private var counts: SuggestionCounts?
    @Environment(\.deepLink) private var deepLink
    @Environment(\.refreshToken) private var refreshToken

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (kind, filter, counts)
        VStack(spacing: 0) {
            SectionStrip(explanation) {
                ModePicker(modes: MailKind.allCases, title: label, selection: $kind)
            }
            Group {
                switch kind {
                case .contacts: ContactsTable(filter: $filter)
                case .events: EventsTable(filter: $filter)
                case .passes: PassesTable(filter: $filter)
                case .urls: URLsTable(filter: $filter)
                case .snippets: SnippetsTable(filter: $filter)
                }
            }
            .id(kind)
            StoreFooter(kind == .snippets ? ProfilePaths.snippetsDB : ProfilePaths.suggestionsDB, note: note)
        }
        .task(id: refreshToken) {
            counts = await SnapshotReadiness.track { try? await SuggestionsStore.counts() }
        }
        .onChange(of: kind) { filter = "" }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink, !link.payload.isEmpty else { return }
            // Payload: "<kind>\t<filter text>"
            let parts = splitPayload(link.payload)
            if let wanted = MailKind.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(parts.mode.lowercased()) }) { kind = wanted }
            DispatchQueue.main.async { filter = parts.rest }
        }
    }

    private func label(_ item: MailKind) -> String {
        guard let counts else { return item.rawValue }
        let n: Int
        switch item {
        case .contacts: n = counts.contacts
        case .events: n = counts.events
        case .passes: n = counts.passes
        case .urls: n = counts.urls
        case .snippets: n = counts.mailSnippets + counts.entitySnippets
        }
        return "\(item.rawValue)  \(Format.count(n))"
    }

    private var explanation: String {
        switch kind {
        case .contacts: return "People that are not in your address book but whose name, e-mail or phone number was harvested from message headers and signatures (“pseudo-contacts”). They power “Siri found a contact” suggestions."
        case .events: return "Reservations and events recognised in mail and app donations — hotels, rental cars, tickets — parsed into schema.org records and offered as calendar suggestions."
        case .passes: return "Wallet passes that arrived as mail attachments. The complete signed .pkpass — including barcodes and booking details — is embedded in the database."
        case .urls: return "Links harvested from messages and calendar entries. Links whose query carries a token, code or password-like parameter are flagged: anyone holding such a link may be able to use it."
        case .snippets: return "Short text excerpts kept as evidence for extracted entities and summaries of processed e-mails (up to a few hundred characters each)."
        }
    }

    private var note: String {
        switch kind {
        case .contacts: return "entity (type 4) · contactDetails"
        case .events: return "events · eventTags · locations"
        case .passes: return "entity (type 26) · entityTags WPD / WPDD"
        case .urls: return "urls"
        case .snippets: return "emailSnippets · snippets"
        }
    }
}

// MARK: - Pseudo-contacts

private struct ContactsTable: View {
    @Binding var filter: String
    @State private var selected: PseudoContact?

    var body: some View {
        PagedTable(
            columns: [
                PagedColumn<PseudoContact>("Name", id: "title", width: 220, min: 140, sensitivity: .sensitive) { $0.name }
                    .cell { Text($0.name.isEmpty ? "(no name)" : $0.name).font(.callout.weight(.medium)).lineLimit(1) },
                PagedColumn("Details", id: "details_text", width: 340, min: 160, sortable: false, sensitivity: .sensitive) { $0.details },
                PagedColumn("Count", id: "details", width: 60, min: 60, alignment: .trailing) { Format.count($0.detailCount) },
                PagedColumn("Message Date", id: "created", width: 150, min: 146) { DossierDate.sortable($0.created) },
                PagedColumn("Last Seen", id: "lastSeen", width: 150, min: 146) { DossierDate.sortable($0.lastSeen) },
                PagedColumn("Entity", id: "id", width: 70, min: 70, alignment: .trailing, sortable: false, secondary: true, hiddenByDefault: true) { String($0.id) },
            ],
            searchPrompt: "Filter names, addresses, numbers",
            exportName: "pseudo-contacts",
            emptyTitle: "No Pseudo-Contacts",
            filter: $filter,
            fetch: { req in try await SuggestionsStore.contacts(offset: req.offset, limit: req.limit, sort: req.sort, search: req.search) },
            count: { req in try await SuggestionsStore.contactCount(search: req.search) },
            onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
        )
        .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected {
                InspectorPage(title: selected.name.isEmpty ? "(no name)" : selected.name, subtitle: "Pseudo-contact", sensitivity: .sensitive, onClose: { self.selected = nil }) {
                    KeyValueGrid([
                        KeyValueItem("Name", selected.name, sensitivity: .sensitive),
                        KeyValueItem("Message date", DossierDate.medium(selected.created)),
                        KeyValueItem("Last seen", DossierDate.medium(selected.lastSeen)),
                    ])
                    AsyncContent(reloadKey: selected.id) {
                        try await SuggestionsStore.contactDetail(selected)
                    } content: { detail in
                        VStack(alignment: .leading, spacing: 16) {
                            if !detail.details.isEmpty {
                                InspectorGroupTitle("Harvested details")
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(detail.details) { item in
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(item.kind).font(.caption).foregroundStyle(.secondary).frame(width: 96, alignment: .trailing)
                                            Text(item.value).font(.callout).textSelection(.enabled).sensitive(.sensitive)
                                            Spacer(minLength: 4)
                                            if let confidence = item.confidence, confidence > 0 {
                                                Text(Format.percent(confidence, digits: 0)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                }
                            }
                            if !detail.references.isEmpty {
                                InspectorGroupTitle("Found in")
                                ForEach(Array(detail.references.enumerated()), id: \.offset) { _, reference in
                                    HStack {
                                        AppLabel(bundle: reference.bundle).font(.callout)
                                        Text("message " + reference.identifier).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).sensitive(.personal)
                                    }
                                }
                            }
                            TagList(tags: detail.tags)
                        }
                    }
                    .frame(minHeight: 60)
                }
            }
        }
    }
}

/// Raw tag list of a Suggestions entity.
private struct TagList: View {
    let tags: [SuggestionTag]
    var body: some View {
        if !tags.isEmpty {
            InspectorGroupTitle("Tags")
            VStack(alignment: .leading, spacing: 5) {
                ForEach(tags) { tag in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(tag.meaning).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                        Text(tag.value.isEmpty ? "✓" : tag.value)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .sensitive(.personal)
                    }
                }
            }
        }
    }
}

// MARK: - Events

private struct EventsTable: View {
    @Binding var filter: String
    @State private var selected: SuggestedEvent?

    var body: some View {
        PagedTable(
            columns: [
                PagedColumn<SuggestedEvent>("Event", id: "title", width: 280, min: 220, sensitivity: .sensitive) { $0.title }
                    .cell { row in
                        HStack(spacing: 6) {
                            Text(row.title).font(.callout.weight(.medium)).lineLimit(1).strikethrough(row.cancelled)
                            if row.cancelled { FlagLabel(text: "Cancelled", symbol: "xmark.circle.fill", tint: .red) }
                        }
                    },
                PagedColumn("Kind", id: "category", width: 110, min: 80, sortable: false) { $0.category },
                PagedColumn("Starts", id: "start", width: 150, min: 146, sensitivity: .personal) { DossierDate.sortable($0.start) },
                PagedColumn("Ends", id: "end", width: 150, min: 146, sensitivity: .personal) { DossierDate.sortable($0.end) },
                PagedColumn("Source", id: "source", width: 190, min: 110, sortable: false, secondary: true) { row in
                    row.app.isEmpty ? (row.domain.isEmpty ? row.origin : row.domain) : AppNames.name(row.app)
                },
                PagedColumn("All Day", id: "allDay", width: 60, min: 60, sortable: false, secondary: true) { $0.allDay ? "Yes" : "" },
                PagedColumn("Extracted", id: "created", width: 150, min: 146, hiddenByDefault: true) { DossierDate.sortable($0.created) },
            ],
            searchPrompt: "Filter events",
            exportName: "suggested-events",
            emptyTitle: "No Events",
            filter: $filter,
            fetch: { req in try await SuggestionsStore.events(offset: req.offset, limit: req.limit, sort: req.sort, search: req.search) },
            count: { req in try await SuggestionsStore.eventCount(search: req.search) },
            onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
        )
        .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected { EventInspector(event: selected) { self.selected = nil } }
        }
    }
}

private struct EventInspector: View {
    let event: SuggestedEvent
    let onClose: () -> Void

    var body: some View {
        InspectorPage(title: event.title, subtitle: event.category.isEmpty ? "Suggested event" : event.category, sensitivity: .sensitive, onClose: onClose) {
            KeyValueGrid([
                KeyValueItem("Title", event.title, sensitivity: .sensitive),
                KeyValueItem("Starts", DossierDate.medium(event.start), sensitivity: .personal),
                KeyValueItem("Ends", DossierDate.medium(event.end), sensitivity: .personal),
                KeyValueItem("Status", event.cancelled ? "Cancelled" : "Active"),
                KeyValueItem("Source", [event.origin, event.domain, event.app.isEmpty ? "" : AppNames.name(event.app)].filter { !$0.isEmpty }.joined(separator: " · ")),
                KeyValueItem("Extracted", DossierDate.medium(event.created)),
            ])
            AsyncContent(reloadKey: event.id) {
                try await SuggestionsStore.eventDetail(event)
            } content: { detail in
                VStack(alignment: .leading, spacing: 16) {
                    let points = detail.locations.compactMap { location -> MapPoint? in
                        guard let lat = location.latitude, let lon = location.longitude else { return nil }
                        return MapPoint(id: String(location.id), latitude: lat, longitude: lon, title: location.label.isEmpty ? location.address : location.label)
                    }
                    if !points.isEmpty {
                        PointMapView(points, maxMarkers: 20, tint: .orange).frame(height: 160)
                    }
                    if !detail.locations.isEmpty {
                        InspectorGroupTitle("Locations")
                        ForEach(detail.locations) { location in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(location.label.isEmpty ? "Location" : location.label).font(.callout.weight(.medium))
                                if !location.address.isEmpty { Text(location.address).font(.callout).foregroundStyle(.secondary) }
                                if !location.airport.isEmpty { Text("Airport " + location.airport).font(.caption).foregroundStyle(.secondary) }
                            }
                            .textSelection(.enabled)
                            .sensitive(.sensitive)
                        }
                    }
                    ForEach(Array(detail.schemaItems.enumerated()), id: \.offset) { index, item in
                        InspectorGroupTitle(detail.schemaItems.count > 1 ? "Parsed reservation \(index + 1) (schema.org)" : "Parsed reservation (schema.org)")
                        KeyValueGrid(item.enumerated().map { KeyValueItem($0.element.0, $0.element.1, sensitivity: .sensitive, id: "\(index)-\($0.offset)") }, valueLineLimit: 4)
                    }
                    if !detail.metadata.isEmpty {
                        InspectorGroupTitle("Extraction metadata")
                        KeyValueGrid(detail.metadata.enumerated().map { KeyValueItem($0.element.0, $0.element.1, id: "m\($0.offset)") })
                    }
                    if let content = detail.content {
                        InspectorGroupTitle("Source text")
                        Text(content).font(.callout).textSelection(.enabled).sensitive(.sensitive)
                    }
                    if let ics = detail.ics {
                        InspectorGroupTitle("Calendar invitation (ICS)")
                        Text(ics).font(.caption.monospaced()).textSelection(.enabled).lineLimit(40).sensitive(.sensitive)
                    }
                    TagList(tags: detail.tags)
                }
            }
            .frame(minHeight: 60)
        }
    }
}

// MARK: - Wallet passes

private struct PassesTable: View {
    @Binding var filter: String
    @State private var selected: WalletPassRow?

    var body: some View {
        PagedTable(
            columns: [
                PagedColumn<WalletPassRow>("Pass", id: "title", width: 280, min: 160, sensitivity: .sensitive) { $0.title }
                    .cell { row in
                        HStack(spacing: 6) {
                            Image(systemName: "wallet.pass").foregroundStyle(.orange).imageScale(.small)
                            Text(row.title).font(.callout.weight(.medium)).lineLimit(1)
                        }
                    },
                PagedColumn("Issuer", id: "organization", width: 180, min: 100, sortable: false, sensitivity: .personal) { $0.organization },
                PagedColumn("Description", id: "description", width: 220, min: 130, sortable: false, sensitivity: .personal) { $0.description },
                PagedColumn("State", id: "state", width: 90, min: 90, sortable: false, secondary: true) { $0.state },
                PagedColumn("Received", id: "created", width: 150, min: 146) { DossierDate.sortable($0.created) },
                PagedColumn("Archive", id: "size", width: 80, min: 80, alignment: .trailing) { Format.bytes($0.archiveBytes) },
                PagedColumn("Sensitivity", id: "sensitivity", width: 116, min: 110, sortable: false) { _ in "Sensitive" }
                    .cell { _ in SensitivityBadge(.sensitive, compact: false) },
                PagedColumn("Serial", id: "serial", width: 180, min: 110, sortable: false, sensitivity: .sensitive, monospaced: true, secondary: true, hiddenByDefault: true) { $0.serial },
            ],
            searchPrompt: "Filter passes",
            exportName: "wallet-passes",
            emptyTitle: "No Wallet Passes",
            filter: $filter,
            fetch: { req in try await SuggestionsStore.passes(offset: req.offset, limit: req.limit, sort: req.sort, search: req.search) },
            count: { req in try await SuggestionsStore.passCount(search: req.search) },
            onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
        )
        .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected { PassInspector(pass: selected) { self.selected = nil } }
        }
    }
}

private struct PassInspector: View {
    let pass: WalletPassRow
    let onClose: () -> Void
    @Environment(\.privacyMode) private var privacyMode

    var body: some View {
        InspectorPage(title: pass.title, subtitle: "Wallet pass · " + pass.organization, sensitivity: .sensitive, onClose: onClose) {
            HStack(spacing: 6) {
                SensitivityBadge(.sensitive)
                Text("Contains booking data and scannable codes").font(.caption).foregroundStyle(.secondary)
            }
            AsyncContent(reloadKey: pass.id) {
                try await SuggestionsStore.passDetail(pass)
            } content: { detail in
                VStack(alignment: .leading, spacing: 16) {
                    card(detail)
                    KeyValueGrid([
                        KeyValueItem("Style", detail.style),
                        KeyValueItem("Issuer", detail.organization, sensitivity: .personal),
                        KeyValueItem("Description", detail.description, sensitivity: .personal),
                        KeyValueItem("Relevant date", detail.relevantDate.isEmpty ? nil : detail.relevantDate, sensitivity: .personal),
                        KeyValueItem("Expires", detail.expirationDate.isEmpty ? nil : detail.expirationDate, sensitivity: .personal),
                        KeyValueItem("Voided", detail.voided ? "Yes" : "No"),
                        KeyValueItem("Received", DossierDate.medium(pass.created)),
                        KeyValueItem("State", pass.state.isEmpty ? nil : pass.state),
                    ])
                    ForEach(Array(detail.groups.enumerated()), id: \.offset) { groupIndex, group in
                        InspectorGroupTitle(group.name + " fields")
                        KeyValueGrid(group.fields.enumerated().map {
                            KeyValueItem($0.element.label.isEmpty ? "—" : $0.element.label, $0.element.value, sensitivity: .sensitive, id: "\(groupIndex)-\($0.offset)")
                        }, valueLineLimit: 8)
                    }
                    if !detail.barcodes.isEmpty {
                        InspectorGroupTitle("Barcode payload")
                        ForEach(Array(detail.barcodes.enumerated()), id: \.offset) { _, code in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(code.format).font(.caption).foregroundStyle(.secondary)
                                RevealableSecret(value: code.message)
                            }
                        }
                    }
                    if !detail.authenticationToken.isEmpty {
                        InspectorGroupTitle("Update service")
                        KeyValueGrid([KeyValueItem("URL", detail.webService, sensitivity: .personal, monospaced: true)])
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Authentication token").font(.caption).foregroundStyle(.secondary)
                            RevealableSecret(value: detail.authenticationToken)
                        }
                    }
                    if !detail.locations.isEmpty {
                        InspectorGroupTitle("Relevant locations")
                        if !privacyMode {
                            PointMapView(detail.locations.enumerated().map { MapPoint(id: String($0.offset), latitude: $0.element.latitude, longitude: $0.element.longitude, title: $0.element.text) }, maxMarkers: 20, tint: .orange)
                                .frame(height: 150)
                        }
                        ForEach(Array(detail.locations.enumerated()), id: \.offset) { _, location in
                            Text((location.text.isEmpty ? "" : location.text + " — ") + ProfileFormat.coordinate(location.latitude, location.longitude))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).sensitive(.sensitive)
                        }
                    }
                    InspectorGroupTitle("Identifiers")
                    KeyValueGrid([
                        KeyValueItem("Pass type", detail.passType, monospaced: true),
                        KeyValueItem("Team", detail.team, monospaced: true),
                        KeyValueItem("Serial number", detail.serial, sensitivity: .sensitive, monospaced: true),
                        KeyValueItem("Source URL", pass.url.isEmpty ? nil : pass.url, sensitivity: .personal, monospaced: true),
                    ])
                    InspectorGroupTitle("Archive contents (\(Format.bytes(detail.archiveBytes)))")
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(detail.files.enumerated()), id: \.offset) { _, file in
                            HStack {
                                Text(file.name).font(.caption.monospaced()).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(Format.bytes(file.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 120)
        }
    }

    /// A small rendition of the pass front in its own colours.
    @ViewBuilder private func card(_ detail: WalletPassDetail) -> some View {
        let bg = PassColor(detail.background) ?? PassColor("rgb(60,60,67)")!
        let fg = PassColor(detail.foreground)
        let lb = PassColor(detail.label)
        let background = bg.color
        let foreground = fg.flatMap { $0.contrasts(with: bg) ? $0.color : nil } ?? bg.readableText
        let labelColor = lb.flatMap { $0.contrasts(with: bg) ? $0.color : nil } ?? foreground.opacity(0.7)
        let front = detail.groups.filter { $0.name == "Primary" || $0.name == "Secondary" || $0.name == "Header" }.flatMap(\.fields).prefix(4)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let data = detail.logo, let image = NSImage(data: data), !privacyMode {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 110, maxHeight: 30, alignment: .leading)
                }
                Text(detail.logoText.isEmpty ? detail.organization : detail.logoText).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(detail.style).font(.caption2).foregroundStyle(labelColor)
            }
            ForEach(Array(front.enumerated()), id: \.offset) { _, field in
                VStack(alignment: .leading, spacing: 0) {
                    if !field.label.isEmpty { Text(field.label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(labelColor) }
                    Text(field.value).font(.callout).lineLimit(2)
                }
            }
        }
        .foregroundStyle(foreground)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .sensitive(.sensitive)
    }
}

// MARK: - URLs

private struct URLsTable: View {
    @Binding var filter: String
    @State private var selected: HarvestedURL?

    var body: some View {
        PagedTable(
            columns: [
                PagedColumn<HarvestedURL>("Link", id: "url", width: 380, min: 180, sensitivity: .sensitive) { $0.url }
                    .cell { row in
                        HStack(spacing: 6) {
                            if !row.secrets.isEmpty { FlagLabel(text: "Token in link", symbol: "key.fill") }
                            Text(row.host.isEmpty ? row.url : row.host).font(.callout.weight(.medium)).lineLimit(1)
                            Text(row.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    },
                PagedColumn("Title", id: "title", width: 240, min: 120, sensitivity: .personal) { $0.title.isEmpty ? $0.documentTitle : $0.title },
                PagedColumn("Flagged Parameters", id: "secrets", width: 140, min: 80, sortable: false) { $0.secrets.joined(separator: ", ") },
                PagedColumn("From", id: "handle", width: 170, min: 100, sensitivity: .sensitive) { $0.handle },
                PagedColumn("App", id: "bundle", width: 110, min: 110) { AppNames.name($0.bundle) },
                PagedColumn("Date", id: "date", width: 150, min: 146) { DossierDate.sortable($0.date) },
            ],
            searchPrompt: "Filter links",
            exportName: "harvested-links",
            emptyTitle: "No Links",
            filter: $filter,
            fetch: { req in try await SuggestionsStore.urls(offset: req.offset, limit: req.limit, sort: req.sort, search: req.search) },
            count: { req in try await SuggestionsStore.urlCount(search: req.search) },
            onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
        )
        .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected {
                InspectorPage(title: selected.host.isEmpty ? "Link" : selected.host, subtitle: "Harvested link", sensitivity: .personal, onClose: { self.selected = nil }) {
                    if !selected.secrets.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "key.fill").foregroundStyle(.orange)
                            Text("This link carries passcode-like parameters (\(selected.secrets.joined(separator: ", "))). It may grant access to an account, meeting or document without further login.")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    KeyValueGrid([
                        KeyValueItem("URL", selected.url, sensitivity: .sensitive, monospaced: true),
                        KeyValueItem("Title", selected.title.isEmpty ? nil : selected.title, sensitivity: .personal),
                        KeyValueItem("Document", selected.documentTitle.isEmpty ? nil : selected.documentTitle, sensitivity: .personal),
                        KeyValueItem("Received from", selected.handle.isEmpty ? nil : selected.handle, sensitivity: .sensitive),
                        KeyValueItem("App", AppNames.name(selected.bundle)),
                        KeyValueItem("Date", DossierDate.medium(selected.date)),
                        KeyValueItem("Flags", String(selected.flags)),
                    ], valueLineLimit: 12)
                    Button("Copy Link") { Pasteboard.copy(selected.url) }.controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Snippets

private struct SnippetsTable: View {
    @Binding var filter: String
    @State private var selected: SnippetRow?

    var body: some View {
        PagedTable(
            columns: [
                PagedColumn<SnippetRow>("Kind", id: "kind", width: 70, min: 70) { $0.kind }
                    .cell { DotLabel(text: $0.kind, color: $0.kind == "Mail" ? .blue : .purple).font(.callout) },
                PagedColumn("Title", id: "title", width: 280, min: 140, sensitivity: .sensitive) { $0.title }
                    .cell { Text($0.title).font(.callout.weight(.medium)).lineLimit(1) },
                PagedColumn("Excerpt", id: "content", width: 620, min: 240, sensitivity: .sensitive) { Format.oneLine($0.content, max: 300) },
                PagedColumn("Length", id: "length", width: 64, min: 64, alignment: .trailing, sortable: false, secondary: true) { Format.count($0.content.count) },
            ],
            searchPrompt: "Search snippet text",
            exportName: "snippets",
            emptyTitle: "No Snippets",
            filter: $filter,
            fetch: { req in try await SuggestionsStore.snippets(offset: req.offset, limit: req.limit, sort: req.sort, search: req.search) },
            count: { req in try await SuggestionsStore.snippetCount(search: req.search) },
            onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
        )
        .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected {
                InspectorPage(title: selected.title.isEmpty ? "Snippet" : selected.title, subtitle: selected.kind == "Mail" ? "E-mail snippet" : "Entity snippet", sensitivity: .sensitive, onClose: { self.selected = nil }) {
                    AsyncContent(reloadKey: selected.id) {
                        await SuggestionsStore.snippetContext(selected)
                    } content: { context in
                        if !context.isEmpty {
                            KeyValueGrid(context.enumerated().map { KeyValueItem($0.element.0, $0.element.1, sensitivity: .sensitive, id: "c\($0.offset)") })
                        }
                    }
                    InspectorGroupTitle("Text")
                    Text(selected.content).font(.callout).textSelection(.enabled).sensitive(.sensitive)
                }
            }
        }
    }
}
