import SwiftUI
import DossierCore

/// (3) Named entities: people, organisations, places and works the system recognised in
/// the owner's documents, aggregated per name and category.
struct EntitiesSection: View {
    @State private var category: Int?
    @State private var bundle = ""
    @State private var categories: [(category: Int, distinct: Int)] = []
    @State private var apps: [String] = []
    @State private var selected: EntityRow?
    @State private var filter = ""
    @Environment(\.deepLink) private var deepLink
    @Environment(\.refreshToken) private var refreshToken

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (category, bundle, categories, apps, selected, filter)
        VStack(spacing: 0) {
            SectionStrip("Names that language analysis, data detectors, Maps, Photos and Contacts picked out of your documents. “Mentions” counts extractions, “Sentiment” is the average tone of the surrounding text (−1 … +1) where the system computed one.")
            PagedTable(
                columns: columns,
                searchPrompt: "Filter entities",
                reloadKey: "\(category ?? -1)|\(bundle)",
                exportName: "named-entities",
                emptyTitle: "No Entities",
                filter: $filter,
                fetch: { [category, bundle] req in
                    try await PortraitStore.entities(offset: req.offset, limit: req.limit, sort: req.sort, search: req.search, category: category, bundle: bundle.isEmpty ? nil : bundle)
                },
                count: { [category, bundle] req in
                    try await PortraitStore.entityCount(search: req.search, category: category, bundle: bundle.isEmpty ? nil : bundle)
                },
                onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
            ) {
                Picker("Category", selection: $category) {
                    Text("All Categories").tag(Int?.none)
                    Divider()
                    ForEach(categories, id: \.category) { item in
                        Text("\(PortraitLabels.entityCategory(item.category))  (\(Format.count(item.distinct)))").tag(Int?.some(item.category))
                    }
                }
                .labelsHidden().fixedSize()
                Picker("Source", selection: $bundle) {
                    Text("All Apps").tag("")
                    Divider()
                    ForEach(apps, id: \.self) { Text(AppNames.name($0)).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { EntityInspector(entity: selected) { self.selected = nil } }
            }
            StoreFooter(ProfilePaths.portraitDB, note: "ne_records ⨝ sources")
        }
        .task(id: refreshToken) {
            await SnapshotReadiness.track {
                categories = (try? await PortraitStore.entityCategories()) ?? []
                apps = await PortraitStore.entityApps()
            }
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink, !link.payload.isEmpty else { return }
            // Payload: "<category>\t<lower-cased name>" (either part may be empty).
            let parts = splitPayload(link.payload)
            let wanted = Int(parts.mode)
            category = parts.rest.isEmpty ? wanted : nil
            bundle = ""
            filter = parts.rest
            guard !parts.rest.isEmpty else { return }
            Task {
                let row = try? await SnapshotReadiness.track { try await PortraitStore.entity(key: parts.rest, category: wanted) }
                if let row { selected = row }
            }
        }
    }

    private var columns: [PagedColumn<EntityRow>] {
        [
            PagedColumn<EntityRow>("Entity", id: "name", width: 240, min: 140, sensitivity: .sensitive) { $0.name }
                .cell { Text($0.name).font(.callout.weight(.medium)).lineLimit(1) },
            PagedColumn("Category", id: "category", width: 150, min: 120) { PortraitLabels.entityCategory($0.category) }
                .cell { row in
                    HStack(spacing: 5) {
                        Image(systemName: PortraitLabels.entitySymbol(row.category)).foregroundStyle(.secondary).imageScale(.small).frame(width: 16)
                        Text(PortraitLabels.entityCategory(row.category)).lineLimit(1)
                    }
                    .font(.callout)
                },
            PagedColumn("Mentions", id: "mentions", width: 76, min: 76, alignment: .trailing) { Format.count($0.mentions) },
            PagedColumn("Documents", id: "documents", width: 84, min: 84, alignment: .trailing) { Format.count($0.documents) },
            PagedColumn("Score", id: "score", width: 70, min: 70, alignment: .trailing) { ProfileFormat.score($0.score) },
            PagedColumn("Sentiment", id: "sentiment", width: 84, min: 84, alignment: .trailing) { ProfileFormat.signed($0.sentiment) }
                .cell { row in
                    Text(ProfileFormat.signed(row.sentiment))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(abs(row.sentiment) < 0.0005 ? Color.secondary : (row.sentiment > 0 ? Color.green : Color.red))
                },
            PagedColumn("Source Apps", id: "apps", width: 170, min: 100, sortable: false) { AppNames.list($0.apps) },
            PagedColumn("Found By", id: "algos", width: 190, min: 110, sortable: false, secondary: true) { PortraitLabels.list($0.algorithms, PortraitLabels.entityAlgorithm) },
            PagedColumn("Last Seen", id: "last", width: 150, min: 146) { DossierDate.sortable($0.last) },
            PagedColumn("Occurrences", id: "occurrences", width: 90, min: 90, alignment: .trailing, hiddenByDefault: true) { Format.count($0.occurrences) },
        ]
    }
}

private struct EntityInspector: View {
    let entity: EntityRow
    let onClose: () -> Void

    var body: some View {
        InspectorPage(title: entity.name, subtitle: PortraitLabels.entityCategory(entity.category), sensitivity: .sensitive, onClose: onClose) {
            KeyValueGrid([
                KeyValueItem("Name", entity.name, sensitivity: .sensitive),
                KeyValueItem("Category", PortraitLabels.entityCategory(entity.category)),
                KeyValueItem("Mentions", "\(Format.count(entity.mentions)) extractions in \(Format.count(entity.documents)) documents"),
                KeyValueItem("Occurrences", Format.count(entity.occurrences) + " in source text"),
                KeyValueItem("Σ initial score", ProfileFormat.score(entity.score)),
                KeyValueItem("Sentiment", ProfileFormat.signed(entity.sentiment) + "  (" + ProfileFormat.sentimentLabel(entity.sentiment) + ")"),
                KeyValueItem("Source apps", AppNames.list(entity.apps)),
                KeyValueItem("Found by", PortraitLabels.list(entity.algorithms, PortraitLabels.entityAlgorithm)),
                KeyValueItem("Last seen", entity.last.map { DossierDate.medium($0) + " (" + DossierDate.relative($0) + ")" }),
            ])
            Text("Scores are the system's own estimates. An entity found by language analysis (CoreNLP) carries a sentiment but no score; imports from Maps, Photos, Calendar and Contacts carry a score.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            InspectorGroupTitle("Contributing documents")
            AsyncContent(reloadKey: "\(entity.key)|\(entity.category)", emptyTitle: "No Documents", emptySymbol: "doc") {
                try await PortraitStore.entityDocuments(key: entity.key, category: entity.category)
            } isEmpty: { $0.isEmpty } content: { documents in
                DocumentList(documents: documents, showsAlgorithm: PortraitLabels.entityAlgorithm)
            }
            .frame(minHeight: 80)
        }
    }
}
