import SwiftUI
import DossierCore

/// (2) Topics: every Wikidata topic the system attached to the owner, with scores, decay
/// and the apps / algorithms that produced it. A second mode shows IntelligencePlatform's
/// "first-party topics" stores.
struct TopicsSection: View {
    enum Mode: String, CaseIterable, Identifiable {
        case portrait = "Portrait Topics"
        case firstParty = "First-Party Topics"
        var id: String { rawValue }
    }

    @State private var mode = Mode.portrait
    @State private var selected: TopicRow?
    @State private var filter = ""
    @State private var namedOnly = false
    @Environment(\.deepLink) private var deepLink

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (mode, selected, filter, namedOnly)
        VStack(spacing: 0) {
            SectionStrip(mode == .portrait
                         ? "Each topic is a Wikidata id found in your documents. The store holds ids only; names come from the system's own lists on this Mac and a built-in table of the topic model's vocabulary — nothing is looked up online. Gazetteer topics are name matches in your text and often coincidental. “System score” is the ranking macOS caches for suggestions."
                         : "IntelligencePlatform keeps separate short-term and long-term topic scores derived from Apple apps (News, Podcasts, TV…). They are often empty on a Mac.") {
                ModePicker(modes: Mode.allCases, title: \.rawValue, selection: $mode)
            }
            switch mode {
            case .portrait: portrait
            case .firstParty: FirstPartyTopicsView()
            }
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink, !link.payload.isEmpty else { return }
            if link.payload == "firstparty" { mode = .firstParty; return }
            mode = .portrait
            namedOnly = false
            filter = link.payload
            let qid = link.payload
            Task {
                let row = try? await SnapshotReadiness.track { try await PortraitStore.topic(qid) }
                if let row { selected = row }
            }
        }
    }

    private var portrait: some View {
        VStack(spacing: 0) {
            PagedTable(
                columns: columns,
                searchPrompt: "Filter by name or QID",
                reloadKey: namedOnly,
                exportName: "portrait-topics",
                emptyTitle: "No Topics",
                filter: $filter,
                fetch: { [namedOnly] req in try await PortraitStore.topics(offset: req.offset, limit: req.limit, sort: req.sort, search: req.search, namedOnly: namedOnly) },
                count: { [namedOnly] req in try await PortraitStore.topicCount(search: req.search, namedOnly: namedOnly) },
                onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
            ) {
                Toggle("Named only", isOn: $namedOnly)
                    .toggleStyle(.checkbox)
                    .help("Hide topics for which no name could be derived on this Mac")
            }
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { TopicInspector(topic: selected) { self.selected = nil } }
            }
            StoreFooter(ProfilePaths.portraitDB, note: "tp_records ⨝ sources · Topics/ScoreCache")
        }
    }

    private var columns: [PagedColumn<TopicRow>] {
        [
            PagedColumn<TopicRow>("Topic", id: "topic_id", width: 270, min: 140, sensitivity: .personal) { row in
                row.name.map { "\($0) (\(row.qid))" } ?? (row.context.map { "\(row.qid) (seen with \($0))" } ?? row.qid)
            }
                .cell { row in
                    HStack(spacing: 6) {
                        if let name = row.name {
                            Text(name).font(.callout.weight(.medium)).lineLimit(1)
                            Text(row.qid).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                        } else {
                            Text(row.qid).font(.callout.monospaced()).layoutPriority(1)
                            if let context = row.context {
                                Text("seen with " + context).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                },
            PagedColumn("Name From", id: "origin", width: 190, min: 110, sortable: false, secondary: true, hiddenByDefault: true) { $0.nameOrigin ?? "—" },
            PagedColumn("System Score", id: "cached", width: 130, min: 110) { $0.cachedScore.map { ProfileFormat.score($0) } ?? "—" }
                .cell { row in
                    HStack(spacing: 8) {
                        Text(row.cachedScore.map { ProfileFormat.score($0) } ?? "—").font(.callout.monospacedDigit()).frame(width: 44, alignment: .trailing)
                        if let cached = row.cachedScore { ScoreBar(fraction: cached, tint: .blue) }
                    }
                },
            PagedColumn("Σ Initial", id: "score", width: 80, min: 80, alignment: .trailing) { ProfileFormat.score($0.score) },
            PagedColumn("Decay", id: "decay", width: 64, min: 64, alignment: .trailing, secondary: true) { $0.decay == 0 ? "none" : ProfileFormat.score($0.decay) },
            PagedColumn("Extractions", id: "records", width: 86, min: 86, alignment: .trailing) { Format.count($0.records) },
            PagedColumn("Documents", id: "documents", width: 84, min: 84, alignment: .trailing) { Format.count($0.documents) },
            PagedColumn("Source Apps", id: "apps", width: 170, min: 100, sortable: false) { AppNames.list($0.apps) },
            PagedColumn("Found By", id: "algos", width: 200, min: 120, sortable: false, secondary: true) { PortraitLabels.list($0.algorithms, PortraitLabels.topicAlgorithm) },
            PagedColumn("Last Seen", id: "last", width: 150, min: 146) { DossierDate.sortable($0.last) },
            PagedColumn("First Seen", id: "first", width: 150, min: 146, hiddenByDefault: true) { DossierDate.sortable($0.first) },
            PagedColumn("Sentiment", id: "sentiment", width: 80, min: 80, alignment: .trailing, hiddenByDefault: true) { ProfileFormat.signed($0.sentiment) },
        ]
    }
}

private struct TopicInspector: View {
    let topic: TopicRow
    let onClose: () -> Void

    var body: some View {
        InspectorPage(title: topic.title, subtitle: "Topic · " + topic.qid, sensitivity: .personal, onClose: onClose) {
            if let url = ProfileFormat.wikidataURL(topic.qid) {
                HStack {
                    Link(destination: url) { Label("Look up on Wikidata", systemImage: "arrow.up.right.square") }
                    Spacer()
                    Button("Copy QID") { Pasteboard.copy(topic.qid) }.controlSize(.small)
                }
                Text(topic.name == nil
                     ? "The store holds only this id and nothing on this Mac names it. Opening the link sends the id — nothing else — to wikidata.org in your browser."
                     : "The store holds only the id; the name comes from: \(topic.nameOrigin ?? "local file"). Opening the link sends only the id to wikidata.org.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            KeyValueGrid([
                KeyValueItem("System score", topic.cachedScore.map { ProfileFormat.score($0) } ?? "not in score cache"),
                KeyValueItem("Σ initial score", ProfileFormat.score(topic.score)),
                KeyValueItem("Decay rate", topic.decay == 0 ? "none (score does not fade)" : ProfileFormat.score(topic.decay)),
                KeyValueItem("Sentiment", ProfileFormat.signed(topic.sentiment)),
                KeyValueItem("Extractions", Format.count(topic.records)),
                KeyValueItem("Documents", Format.count(topic.documents)),
                KeyValueItem("Source apps", AppNames.list(topic.apps)),
                KeyValueItem("Found by", PortraitLabels.list(topic.algorithms, PortraitLabels.topicAlgorithm)),
                KeyValueItem("First seen", DossierDate.medium(topic.first)),
                KeyValueItem("Last seen", topic.last.map { DossierDate.medium($0) + " (" + DossierDate.relative($0) + ")" }),
            ])
            SeenWithList(qid: topic.qid)
            InspectorGroupTitle("Contributing documents")
            AsyncContent(reloadKey: topic.qid, emptyTitle: "No Documents", emptySymbol: "doc") {
                try await PortraitStore.topicDocuments(topic.qid)
            } isEmpty: { $0.isEmpty } content: { documents in
                DocumentList(documents: documents, showsAlgorithm: PortraitLabels.topicAlgorithm)
            }
            .frame(minHeight: 80)
        }
    }
}

/// Named entities the system extracted from the same documents as a topic — the local
/// evidence for what a topic id is about.
private struct SeenWithList: View {
    let qid: String
    @State private var entities: [(name: String, category: Int, documents: Int)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !entities.isEmpty {
                InspectorGroupTitle("Seen with · entities in the same documents")
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entities.enumerated()), id: \.offset) { _, entity in
                        HStack(spacing: 6) {
                            Image(systemName: PortraitLabels.entitySymbol(entity.category)).foregroundStyle(.secondary).imageScale(.small).frame(width: 16)
                            Text(entity.name).font(.callout).lineLimit(1).sensitive(.sensitive)
                            Spacer(minLength: 4)
                            Text(Format.count(entity.documents)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .task(id: qid) {
            entities = await SnapshotReadiness.track { await PortraitStore.topicEntities(qid, limit: 12) }
        }
    }
}

private struct FirstPartyTopicsView: View {
    var body: some View {
        VStack(spacing: 0) {
            AsyncContent {
                await FirstPartyTopicStore.load()
            } content: { result in
                if result.stores.isEmpty {
                    StatePlaceholder.missing("No first-party topic stores exist under IntelligencePlatform/Artifacts/firstPartyTopics on this Mac.")
                } else if result.topics.isEmpty {
                    StatePlaceholder(
                        title: "No First-Party Topics",
                        symbol: "tray",
                        message: "The \(result.stores.count) topic stores (\(result.stores.map(\.name).joined(separator: ", "))) exist but hold no rows. They fill up from Apple News, Podcasts and similar apps, mostly on iPhone and iPad.")
                } else {
                    PagedTable(
                        rows: result.topics,
                        columns: [
                            PagedColumn<FirstPartyTopic>("Topic", width: 200, min: 120, sensitivity: .personal, monospaced: true) { $0.topic },
                            PagedColumn("Score", width: 90, min: 90, alignment: .trailing) { ProfileFormat.score($0.score) },
                            PagedColumn("Store", width: 260, min: 160, secondary: true) { $0.store },
                            PagedColumn("Most Recent Document", width: 320, min: 190, sensitivity: .personal, monospaced: true, secondary: true) { $0.document },
                        ],
                        searchPrompt: "Filter topics",
                        reloadKey: result.topics.count,
                        exportName: "first-party-topics")
                }
            }
            StoreFooter(ProfilePaths.firstPartyTopics, note: "scoredTopicsFirstParty*.db › topics")
        }
    }
}
