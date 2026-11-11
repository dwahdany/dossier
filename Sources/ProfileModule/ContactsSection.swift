import SwiftUI
import DossierCore

/// (6) Contacts intelligence: which addresses and numbers appear in the owner's documents,
/// who the system considers significant, and which identities it attributes to the owner.
struct ContactsSection: View {
    enum Mode: String, CaseIterable, Identifiable {
        case handles = "Handles"
        case significant = "Significant"
        case you = "You"
        case names = "Learned Names"
        case family = "Family"
        case shared = "Shared with You"
        var id: String { rawValue }
    }

    @State private var mode = Mode.handles
    @State private var filter = ""
    @State private var familyFilter = ""
    @Environment(\.deepLink) private var deepLink

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (mode, filter, familyFilter)
        VStack(spacing: 0) {
            SectionStrip(explanation) {
                ModePicker(modes: Mode.allCases, title: \.rawValue, selection: $mode)
            }
            Group {
                switch mode {
                case .handles: HandlesTable(filter: $filter)
                case .significant: SignificantTable()
                case .you: YouPage()
                case .names: LearnedNamesTable()
                case .family: FamilyTable(filter: $familyFilter)
                case .shared: SharedTable()
                }
            }
            .id(mode)
            StoreFooter(footer.0, note: footer.1)
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink, !link.payload.isEmpty else { return }
            // Payload: "<mode>\t<filter>"
            let parts = splitPayload(link.payload)
            let wanted = Mode.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(parts.mode.lowercased()) })
            if let wanted { mode = wanted }
            DispatchQueue.main.async {
                if wanted == .family { familyFilter = parts.rest } else { filter = parts.rest }
            }
        }
    }

    private var explanation: String {
        switch mode {
        case .handles: return "Every e-mail address and phone number that occurs in a document the interest profile has processed, with the number of documents it appears in. This links people to the topics and entities found alongside them."
        case .significant: return "Handles the system flagged as significant contacts — people you correspond with often enough to boost their suggestions."
        case .you: return "What the system believes about your own identity: the cached “me” card, addresses you send mail from, and names it learned for you."
        case .names: return "Display names learned for addresses and numbers from message headers (Suggestions name caches). Used to label unknown senders and callers (“Maybe: …”)."
        case .family: return "Your Family Sharing group as cached for suggestions: every member's name, Apple Account, date of birth, role and purchase settings — a copy of the roster from your Apple Account."
        case .shared: return "Links other people sent you in Messages, ranked for the “Shared with You” shelves in Safari, Photos, Music and other apps."
        }
    }

    private var footer: (URL, String) {
        switch mode {
        case .handles: return (ProfilePaths.portraitDB, "cn_handles ⨝ cn_handles_sources ⨝ sources")
        case .significant: return (ProfilePaths.portraitDB, "significant_contacts")
        case .you: return (Paths.personalizationPortrait.appendingPathComponent("Contacts"), "me_card.pb · name_records · Suggestions emailMetadata")
        case .names: return (Paths.suggestions, "email-to-name.kvcache · phone-to-name.kvcache")
        case .family: return (ProfilePaths.familyCircleCache, "NSKeyedArchiver · FAFamilyCircle › _members")
        case .shared: return (ProfilePaths.socialHighlights, "SEGB stream")
        }
    }
}

// MARK: - Handles

private struct HandlesTable: View {
    @Binding var filter: String
    @State private var selected: HandleRow?

    var body: some View {
        PagedTable(
            columns: [
                PagedColumn<HandleRow>("Handle", id: "value", width: 300, min: 160, sensitivity: .sensitive) { $0.value }
                    .cell { row in
                        HStack(spacing: 6) {
                            Image(systemName: row.kind == "Phone" ? "phone" : "envelope").foregroundStyle(.secondary).imageScale(.small).frame(width: 16)
                            Text(row.value).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        }
                    },
                PagedColumn("Kind", id: "kind", width: 70, min: 70, sortable: false, secondary: true) { $0.kind },
                PagedColumn("Significant", id: "significant", width: 96, min: 96) { $0.significant ? "Significant" : "" }
                    .cell { row in if row.significant { FlagLabel(text: "Significant", symbol: "star.fill", tint: .yellow) } },
                PagedColumn("Documents", id: "documents", width: 84, min: 84, alignment: .trailing) { Format.count($0.documents) },
                PagedColumn("Source Apps", id: "apps", width: 170, min: 100, sortable: false) { AppNames.list($0.apps) },
                PagedColumn("First Seen", id: "first", width: 150, min: 146) { DossierDate.sortable($0.first) },
                PagedColumn("Last Seen", id: "last", width: 150, min: 146) { DossierDate.sortable($0.last) },
            ],
            searchPrompt: "Filter handles",
            exportName: "contact-handles",
            emptyTitle: "No Handles",
            filter: $filter,
            fetch: { req in try await PortraitStore.handles(offset: req.offset, limit: req.limit, sort: req.sort, search: req.search) },
            count: { req in try await PortraitStore.handleCount(search: req.search) },
            onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
        )
        .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected {
                InspectorPage(title: selected.value, subtitle: selected.kind + (selected.significant ? " · significant contact" : ""), sensitivity: .sensitive, onClose: { self.selected = nil }) {
                    KeyValueGrid([
                        KeyValueItem("Handle", selected.value, sensitivity: .sensitive),
                        KeyValueItem("Documents", Format.count(selected.documents)),
                        KeyValueItem("Source apps", AppNames.list(selected.apps)),
                        KeyValueItem("First seen", DossierDate.medium(selected.first)),
                        KeyValueItem("Last seen", DossierDate.medium(selected.last)),
                        KeyValueItem("Significant", selected.significant ? "Yes" : "No"),
                    ])
                    AsyncContent(reloadKey: selected.id) {
                        try await PortraitStore.handleDetail(selected.id)
                    } content: { detail in
                        VStack(alignment: .leading, spacing: 16) {
                            if !detail.entities.isEmpty {
                                InspectorGroupTitle("Entities in the same documents")
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(detail.entities.enumerated()), id: \.offset) { _, entity in
                                        HStack(spacing: 6) {
                                            Image(systemName: PortraitLabels.entitySymbol(entity.category)).foregroundStyle(.secondary).imageScale(.small).frame(width: 16)
                                            Text(entity.name).font(.callout).lineLimit(1).sensitive(.sensitive)
                                            Spacer(minLength: 4)
                                            Text(Format.count(entity.count)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                            InspectorGroupTitle("Documents")
                            DocumentList(documents: detail.documents, limitNote: 100)
                        }
                    }
                    .frame(minHeight: 80)
                }
            }
        }
    }
}

private struct SignificantTable: View {
    var body: some View {
        AsyncContent(emptyTitle: "No Significant Contacts", emptySymbol: "star") {
            try await PortraitStore.significantContacts()
        } isEmpty: { $0.isEmpty } content: { rows in
            PagedTable(
                rows: rows,
                columns: [
                    PagedColumn<SignificantRow>("Handle", width: 320, min: 160, sensitivity: .sensitive) { $0.handle }
                        .cell { row in
                            HStack(spacing: 6) {
                                Image(systemName: "star.fill").foregroundStyle(.yellow).imageScale(.small)
                                Text(row.handle).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            }
                        },
                    PagedColumn("Kind", width: 80, min: 80, secondary: true) { $0.kind },
                    PagedColumn("Profile Documents", width: 130, min: 130, alignment: .trailing) { String($0.documents) },
                ],
                searchPrompt: "Filter significant contacts",
                reloadKey: rows.count,
                exportName: "significant-contacts")
        }
    }
}

// MARK: - You

private struct YouPage: View {
    private struct Loaded: Sendable {
        var meCard: [(label: String, value: String)] = []
        var names: [(name: String, score: Double?)] = []
        var addresses: [OwnAddress] = []
        var addressError: String?
    }

    var body: some View {
        AsyncContent {
            var loaded = Loaded()
            loaded.meCard = PortraitStore.meCard()
            loaded.names = PortraitStore.nameRecords()
            do { loaded.addresses = try await SuggestionsStore.ownAddresses() } catch { loaded.addressError = error.localizedDescription }
            return loaded
        } content: { loaded in
            ScrollPage {
                StatTileRow([
                    Stat("Me Card", loaded.meCard.isEmpty ? "Not cached" : (loaded.meCard.first { $0.label == "Display name" || $0.label == "Given name" }?.value ?? "Cached"),
                         caption: "the system's name for you", symbol: "person.crop.circle", tint: .blue, sensitivity: .sensitive),
                    Stat("Own Addresses", Format.count(loaded.addresses.count), caption: "you send mail from", symbol: "paperplane", tint: .teal),
                    Stat("Name Records", Format.count(loaded.names.count), caption: "learned name variants", symbol: "textformat", tint: .purple),
                ])
                HStack(alignment: .top, spacing: Metrics.blockSpacing) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader("Me Card", subtitle: "Contacts/me_card.pb — cached copy of your own contact card", symbol: "person.crop.circle")
                        Group {
                            if loaded.meCard.isEmpty {
                                Text("No cached me card.").font(.callout).foregroundStyle(.secondary)
                            } else {
                                KeyValueGrid(loaded.meCard.enumerated().map {
                                    KeyValueItem($0.element.label, $0.element.value, sensitivity: .sensitive, monospaced: $0.element.label.contains("identifier"), id: "me\($0.offset)")
                                })
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                        SectionHeader("Name Records", subtitle: "Names learned from Contacts, with the system's confidence", symbol: "textformat")
                        Group {
                            if loaded.names.isEmpty {
                                Text("No name records.").font(.callout).foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 5) {
                                    ForEach(Array(loaded.names.prefix(200).enumerated()), id: \.offset) { _, record in
                                        HStack {
                                            Text(record.name).font(.callout).sensitive(.sensitive)
                                            Spacer(minLength: 4)
                                            if let score = record.score { Text(ProfileFormat.score(score)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader("Your Sender Addresses", subtitle: "Authors of messages tagged as sent by you (Suggestions)", symbol: "paperplane")
                        Group {
                            if let error = loaded.addressError {
                                Text(error).font(.callout).foregroundStyle(.secondary)
                            } else if loaded.addresses.isEmpty {
                                Text("No sent messages have been processed.").font(.callout).foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(loaded.addresses) { address in
                                        HStack(spacing: 8) {
                                            Image(systemName: "envelope").foregroundStyle(.secondary).imageScale(.small)
                                            Text(address.address).font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled).sensitive(.sensitive)
                                            Spacer(minLength: 4)
                                            Text("\(Format.count(address.messages)) sent").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                            Text(DossierDate.day(address.last)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                        }
                                        .padding(.vertical, 5)
                                        Divider()
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }
}

private struct LearnedNamesTable: View {
    var body: some View {
        AsyncContent(emptyTitle: "No Learned Names", emptySymbol: "person.crop.circle.badge.questionmark") {
            SuggestionsStore.learnedNames()
        } isEmpty: { $0.isEmpty } content: { rows in
            PagedTable(
                rows: rows,
                columns: [
                    PagedColumn<LearnedName>("Handle", width: 320, min: 160, sensitivity: .sensitive) { $0.handle }
                        .cell { Text($0.handle).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle) },
                    PagedColumn("Learned Name", width: 280, min: 140, sensitivity: .sensitive) { $0.name },
                    PagedColumn("Kind", width: 80, min: 80, secondary: true) { $0.source },
                ],
                searchPrompt: "Filter names",
                reloadKey: rows.count,
                exportName: "learned-names")
        }
    }
}

private struct SharedTable: View {
    var body: some View {
        AsyncContent(emptyTitle: "No Shared Links", emptySymbol: "person.2.wave.2") {
            try PortraitStore.socialHighlights()
        } isEmpty: { $0.isEmpty } content: { rows in
            PagedTable(
                rows: rows,
                columns: [
                    PagedColumn<SocialHighlight>("Link", width: 380, min: 180, sensitivity: .sensitive) { $0.url }
                        .cell { row in
                            HStack(spacing: 6) {
                                Text(ProfileFormat.host(row.url).isEmpty ? row.url : ProfileFormat.host(row.url)).font(.callout.weight(.medium)).lineLimit(1)
                                Text(row.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        },
                    PagedColumn("From", width: 160, min: 100, sensitivity: .sensitive) { $0.sender },
                    PagedColumn("Conversation", width: 140, min: 80, sensitivity: .sensitive) { $0.title },
                    PagedColumn("App", width: 110, min: 110) { AppNames.name($0.app) },
                    PagedColumn("Kind", width: 110, min: 110, secondary: true) { $0.kind },
                    PagedColumn("Shared", width: 150, min: 146) { DossierDate.sortable($0.contentDate) },
                    PagedColumn("Last Ranked", width: 150, min: 146) { DossierDate.sortable($0.date) },
                    PagedColumn("Rankings", width: 76, min: 76, alignment: .trailing) { String($0.appearances) },
                ],
                searchPrompt: "Filter shared links",
                reloadKey: rows.count,
                exportName: "shared-with-you")
        }
    }
}
