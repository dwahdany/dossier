import SwiftUI
import Charts
import DossierCore

/// (7) Memories, highlights, suggestions and sharing statistics.
struct MemoriesSection: View {
    enum Tab: String, CaseIterable, Identifiable {
        case memories = "Memories", highlights = "Highlights", suggestions = "Suggestions", sharing = "Sharing & Engagement"
        var id: String { rawValue }
    }

    @ObservedObject private var selection = PhotosLibrarySelection.shared
    @Environment(\.deepLink) private var deepLink
    @State private var tab: Tab = .memories
    @State private var memoryFilter = ""

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (tab, memoryFilter)
        VStack(spacing: 0) {
            SectionStrip {
                FittingSegmentedPicker(label: "View", options: Tab.allCases.map { .init(value: $0, title: $0.rawValue, shortTitle: $0 == .sharing ? "Sharing" : nil) }, selection: $tab)
            } trailing: {
                LibraryMenu()
            }
            if let lib = selection.current {
                switch tab {
                case .memories: MemoriesPane(library: lib, filterText: $memoryFilter)
                case .highlights: HighlightsPane(library: lib)
                case .suggestions: SuggestionsPane(library: lib)
                case .sharing: SharingPane(library: lib)
                }
                StoreFooter(lib.photosDB, note: footerNote)
            } else {
                StatePlaceholder.missing("No Photos library was found in ~/Pictures. Use the library menu to choose one.")
            }
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink, !link.payload.isEmpty else { return }
            if link.payload.hasPrefix("tab:") {
                let key = String(link.payload.dropFirst(4))
                if let match = Tab.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(key.lowercased()) }) { tab = match }
            } else {
                tab = .memories
                memoryFilter = link.payload
            }
        }
    }

    private var footerNote: String {
        switch tab {
        case .memories: return "ZMEMORY"
        case .highlights: return "ZPHOTOSHIGHLIGHT"
        case .suggestions: return "ZSUGGESTION"
        case .sharing: return "ZADDITIONALASSETATTRIBUTES, ZSHARE, ZSHAREPARTICIPANT, ZCLOUDSHAREDCOMMENT, ZGENERICALBUM"
        }
    }
}

// MARK: Memories

private struct MemoriesPane: View {
    let library: PhotosLibrary
    @Binding var filterText: String
    @State private var selected: PhotosStore.MemoryRow?

    var body: some View {
        let lib = library
        VStack(spacing: 0) {
            AsyncContent(reloadKey: lib.id) {
                try await PhotosStore.memoryStats(lib)
            } content: { stats in
                // Tiles and the type ranking always; the per-year chart joins them once the pane is
                // wide enough for all three. Fixed widths here used to make the section wider
                // than a minimum-size window.
                GeometryReader { geo in
                let wide = geo.size.width >= 1080
                // Narrow: the ranking keeps 260 pt of content, the tiles get the rest (up to 400).
                let tilesWidth = wide ? 400 : min(400, max(292, geo.size.width - 2 * Metrics.pagePadding - 14 - 284))
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        StatTileRow([
                            Stat("Memories", Format.count(stats.total), caption: "generated for you", symbol: "sparkles.rectangle.stack", tint: .yellow),
                            Stat("Played", Format.count(stats.played), caption: "\(Format.count(stats.viewed)) viewed · \(Format.count(stats.shared)) shared", symbol: "play.circle", tint: .green),
                            Stat("Favourites", Format.count(stats.favorites), caption: "\(Format.count(stats.rejected)) rejected by you", symbol: "heart", tint: .pink),
                            Stat("Not Yet Shown", Format.count(stats.pending), caption: "pending state ≠ 0", symbol: "hourglass", tint: .orange),
                        ], minTileWidth: 140)
                        Text("Memories are stories Photos assembles on its own from the PhotosGraph. The type is the first component of the graph memory identifier; score, play counts and your reactions feed back into what is suggested next.")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(4).frame(maxHeight: .infinity, alignment: .top)
                            .help("Memories are stories Photos assembles on its own from the PhotosGraph. The type is the first component of the graph memory identifier; score, play counts and your reactions feed back into what is suggested next.")
                    }
                    .frame(width: tilesWidth, alignment: .topLeading)
                    if wide {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Created per Year").font(.subheadline.weight(.semibold))
                            YearChart(years: stats.perYear, firstLabel: "Memories", secondLabel: nil, height: 192)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .card(padding: 12)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("By Type").font(.subheadline.weight(.semibold))
                        ScrollView { RankList(stats.kinds, tint: .yellow, limit: 30).barWidth(wide ? 110 : 40) }.frame(height: 192)
                    }
                    .frame(minWidth: 260, idealWidth: 340, maxWidth: wide ? 340 : .infinity)
                    .card(padding: 12)
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.vertical, 12)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }
            }
            .frame(height: 272)
            Divider()
            PagedTable(
                columns: [
                    PagedColumn<PhotosStore.MemoryRow>("Created", id: "ZCREATIONDATE", width: 150, min: 130, sensitivity: .personal) { DossierDate.sortable($0.created) },
                    PagedColumn("Title", id: "ZTITLE", width: 220, min: 120, sensitivity: .sensitive) { $0.title.isEmpty || $0.title.contains("|PGGraph") ? "Untitled" : $0.title },
                    PagedColumn("Subtitle", id: "ZSUBTITLE", width: 170, sortable: false, sensitivity: .personal) { $0.subtitle },
                    PagedColumn("Type", id: "ZGRAPHMEMORYIDENTIFIER", width: 150) { $0.kind },
                    PagedColumn("Score", id: "ZSCORE", width: 62, alignment: .trailing) { $0.score.map { Format.number($0, maxDigits: 2) } ?? "—" },
                    PagedColumn("Plays", id: "ZPLAYCOUNT", width: 54, alignment: .trailing) { $0.plays > 0 ? String($0.plays) : "—" },
                    PagedColumn("State", id: "ZPENDINGSTATE", width: 110) { row in
                        ((row.favorite ? ["favourite"] : []) + (row.rejected ? ["rejected"] : []) + (row.stateText.isEmpty ? [] : [row.stateText])).joined(separator: ", ")
                    },
                    PagedColumn("Category", id: "ZCATEGORY", width: 70, alignment: .trailing, secondary: true, hiddenByDefault: true) { $0.category.map { "code \($0)" } ?? "—" },
                    PagedColumn("Covers From", id: "ZSTARTDATE", width: 110, sensitivity: .personal, hiddenByDefault: true) { DossierDate.day($0.start) },
                ],
                searchPrompt: "Filter memories",
                reloadKey: lib.id,
                exportName: "photos-memories",
                emptyTitle: "No Memories",
                filter: $filterText,
                fetch: { req in try await PhotosStore.memories(lib, request: req) },
                count: { req in try await PhotosStore.memoryCount(lib, search: req.search) },
                onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
            )
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let m = selected {
                    InspectorPage(title: m.title.isEmpty || m.title.contains("|PGGraph") ? "Untitled Memory" : m.title, subtitle: m.kind, sensitivity: .personal, onClose: { selected = nil }) {
                        HintedGrid([
                            HintedItem("Subtitle", m.subtitle, sensitivity: .personal),
                            HintedItem("Created", DossierDate.medium(m.created)),
                            HintedItem("Covers", m.start.map { DossierDate.day($0) + " – " + DossierDate.day(m.end ?? $0) }, sensitivity: .personal),
                            HintedItem("Score", m.score.map { Format.number($0) }, hint: "ZSCORE — how strongly Photos ranks this memory"),
                            HintedItem("Views / plays / shares", "\(m.views) / \(m.plays) / \(m.shares)"),
                            HintedItem("Last viewed", m.lastViewed.map { DossierDate.medium($0) }),
                            HintedItem("Your reaction", m.favorite ? "Favourite" : (m.rejected ? "Rejected" : "None"), hint: "ZFAVORITE = \(m.favorite ? 1 : 0) · ZREJECTED = \(m.rejected ? 1 : 0)"),
                            HintedItem("State", m.stateText.isEmpty ? "Not pending, not featured" : m.stateText.prefix(1).uppercased() + m.stateText.dropFirst(),
                                       hint: "ZPENDINGSTATE = \(m.pending.map(String.init) ?? "NULL") · ZFEATUREDSTATE = \(m.featured.map(String.init) ?? "NULL")"),
                            HintedItem("Internal category", m.category.map { "\($0)" + ((m.subcategory ?? 0) != 0 ? " · subcategory \(m.subcategory ?? 0)" : "") },
                                       hint: "ZCATEGORY / ZSUBCATEGORY — integer classes whose names are not stored in the library; the memory type above comes from the graph identifier"),
                            HintedItem("Created by", m.userCreated ? "You" : "Photos"),
                        ])
                        if !m.graphIdentifier.isEmpty {
                            InspectorGroupTitle("Built from")
                            MemoryRecipeView(library: lib, identifier: m.graphIdentifier)
                            Text("The recipe the graph used: the memory type, then the graph nodes (people, places, dates, scenes) the story was assembled from. Hover a chip for the stored node name.")
                                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

// MARK: Highlights

private struct HighlightsPane: View {
    let library: PhotosLibrary
    @State private var kind: Int? = nil
    @State private var selected: PhotosStore.HighlightRow?

    var body: some View {
        let lib = library
        let kind = kind
        VStack(spacing: 0) {
            AsyncContent(reloadKey: lib.id) {
                try await PhotosStore.highlightKinds(lib)
            } content: { kinds in
                GeometryReader { geo in
                // The ranking card takes about 40 % of the pane (up to 440 pt); in a narrow pane a little
                // over half, with a shorter bar, so its names stay readable.
                let inner = geo.size.width - 2 * Metrics.pagePadding
                let narrow = inner < 860
                let cardWidth = narrow ? max(300, inner * 0.6) : min(480, inner * 0.42)
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Highlights are the units of the Library tab: days, months, years and “day groups” (trips). Each stores a generated title, a promotion score and whether Photos chose to surface it. Kind and type are integer codes; the names shown are confirmed by the date spans and by the trip nodes of the PhotosGraph.")
                            .font(.callout).foregroundStyle(.secondary).frame(maxHeight: .infinity, alignment: .top)
                        FittingSegmentedPicker(
                            label: "Kind",
                            options: [.init(value: Int?.none, title: "All Kinds")] + [0, 1, 2, 3].map { .init(value: Int?.some($0), title: PhotosCodes.highlightKind.shortLabel($0)) },
                            selection: $kind
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("By Kind and Type").font(.subheadline.weight(.semibold))
                        ScrollView { RankList(kinds, tint: .indigo, limit: 8).barWidth(narrow ? 40 : 110) }
                    }
                    .frame(width: cardWidth - 24)
                    .card(padding: 12)
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.vertical, 12)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                }
            }
            .frame(height: 206)
            Divider()
            PagedTable(
                columns: [
                    PagedColumn<PhotosStore.HighlightRow>("Start", id: "ZSTARTDATE", width: 150, min: 130, sensitivity: .personal) { DossierDate.sortable($0.start) },
                    PagedColumn("Title", id: "ZTITLE", width: 230, min: 120, sensitivity: .sensitive) { $0.title.isEmpty ? "—" : $0.title },
                    PagedColumn("Subtitle", id: "ZSUBTITLE", width: 170, sortable: false, sensitivity: .personal) { $0.subtitle },
                    PagedColumn("Kind", id: "ZKIND", width: 90) { PhotosCodes.highlightKind.shortLabel($0.kind) },
                    PagedColumn("Type", id: "ZTYPE", width: 110) { PhotosCodes.highlightType(kind: $0.kind, type: $0.type) },
                    PagedColumn("Assets", id: "ZASSETSCOUNT", width: 64, alignment: .trailing) { Format.count($0.assets) },
                    PagedColumn("Promotion", id: "ZPROMOTIONSCORE", width: 80, alignment: .trailing) { $0.promotion.map { Format.number($0, maxDigits: 2) } ?? "—" },
                    PagedColumn("End", id: "ZENDDATE", width: 150, sensitivity: .personal, hiddenByDefault: true) { DossierDate.sortable($0.end) },
                ],
                searchPrompt: "Filter highlights",
                reloadKey: "\(lib.id)|\(kind ?? -1)",
                exportName: "photos-highlights",
                emptyTitle: "No Highlights",
                fetch: { req in try await PhotosStore.highlights(lib, kind: kind, request: req) },
                count: { req in try await PhotosStore.highlightCount(lib, kind: kind, search: req.search) },
                onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
            )
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let h = selected {
                    InspectorPage(title: h.title.isEmpty ? "Highlight" : h.title, subtitle: PhotosCodes.highlightKind.shortLabel(h.kind), sensitivity: .personal, onClose: { selected = nil }) {
                        HintedGrid([
                            HintedItem("Subtitle", h.subtitle, sensitivity: .personal),
                            HintedItem("From", DossierDate.medium(h.start), sensitivity: .personal),
                            HintedItem("To", DossierDate.medium(h.end), sensitivity: .personal),
                            HintedItem("Kind", code: h.kind, table: PhotosCodes.highlightKind, column: "ZKIND"),
                            HintedItem("Type", PhotosCodes.highlightType(kind: h.kind, type: h.type), hint: "ZTYPE = \(h.type)"),
                            HintedItem("Assets", Format.count(h.assets)),
                            HintedItem("Promotion score", h.promotion.map { Format.number($0) }, hint: "ZPROMOTIONSCORE — how strongly Photos surfaces this highlight"),
                            HintedItem("Internal classes", "category \(h.category ?? 0) · mood \(h.mood ?? 0) · enrichment \(h.enrichment ?? 0) · visibility \(h.visibility ?? 0)",
                                       hint: "ZCATEGORY, ZMOOD, ZENRICHMENTSTATE, ZVISIBILITYSTATE — integer classes whose names are not stored in the library"),
                            HintedItem("Smart description", h.description, sensitivity: .sensitive),
                        ])
                    }
                }
            }
        }
    }
}

// MARK: Suggestions

private struct SuggestionsPane: View {
    let library: PhotosLibrary

    var body: some View {
        let lib = library
        AsyncContent(reloadKey: lib.id, emptyTitle: "No Suggestions", emptySymbol: "lightbulb") {
            try await PhotosStore.suggestions(lib)
        } isEmpty: { $0.isEmpty } content: { rows in
            VStack(spacing: 0) {
                HStack {
                    Text("Suggestions are assets Photos proposes on its own: featured photos, wallpaper and widget picks, sharing suggestions. Type and subtype are stored as codes and shown raw.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.vertical, 10)
                Divider()
                PagedTable(
                    rows: rows,
                    columns: [
                        PagedColumn<PhotosStore.SuggestionRow>("Created", id: "created", width: 150, min: 130) { DossierDate.sortable($0.created) },
                        PagedColumn("Type", id: "type", width: 80) { $0.type.map { "type \($0)" } ?? "—" },
                        PagedColumn("Subtype", id: "subtype", width: 96) { $0.subtype.map { "subtype \($0)" } ?? "—" },
                        PagedColumn("Title", id: "title", width: 220, sensitivity: .sensitive) { $0.title.isEmpty ? "—" : $0.title },
                        PagedColumn("Subtitle", id: "subtitle", width: 170, sensitivity: .personal) { $0.subtitle },
                        PagedColumn("Assets", id: "assets", width: 64, alignment: .trailing) { Format.count($0.assets) },
                        PagedColumn("State", id: "state", width: 70, secondary: true) { $0.state.map { "code \($0)" } ?? "—" },
                        PagedColumn("Featured", id: "featured", width: 76, secondary: true) { $0.featured.map { "code \($0)" } ?? "—" },
                        PagedColumn("Covers", id: "covers", width: 190, sensitivity: .personal, hiddenByDefault: true) { r in r.start.map { DossierDate.day($0) + " – " + DossierDate.day(r.end ?? $0) } ?? "—" },
                    ],
                    searchPrompt: "Filter suggestions",
                    reloadKey: "\(lib.id)|\(rows.count)",
                    exportName: "photos-suggestions",
                    emptyTitle: "No Suggestions"
                )
            }
        }
    }
}

// MARK: Sharing

private struct SharingPane: View {
    let library: PhotosLibrary

    var body: some View {
        let lib = library
        AsyncContent(reloadKey: lib.id) {
            try await PhotosStore.sharing(lib)
        } content: { s in
            ScrollPage {
                InfoNote("Photos counts how often you open, play and share each asset, and records who contributed what to shared libraries and albums. These counters feed the ranking of memories and featured photos.")
                StatTileRow([
                    Stat("Views", Format.compact(s.totalViews), caption: "\(Format.count(s.viewedAssets)) assets opened at least once", symbol: "eye", tint: .blue),
                    Stat("Most Viewed", Format.count(s.maxViews), caption: "views of a single asset", symbol: "flame", tint: .orange),
                    Stat("Plays", Format.count(s.totalPlays), caption: "video and Live Photo plays", symbol: "play.circle", tint: .green),
                    Stat("Shares", Format.count(s.totalShares), caption: "\(Format.count(s.sharedAssets)) assets shared", symbol: "square.and.arrow.up", tint: .teal),
                    Stat("Favourites", Format.count(s.favorites), caption: "marked with a heart", symbol: "heart", tint: .pink),
                    Stat("Shared Library", Format.compact(s.sharedLibraryAssets), caption: "assets in a shared library", symbol: "person.2.crop.square.stack", tint: .purple),
                    Stat("Comments / Likes", "\(Format.count(s.comments)) / \(Format.count(s.likes))", caption: "\(Format.count(s.myComments)) by you", symbol: "bubble.left.and.bubble.right", tint: .indigo),
                    Stat("Last Viewed", DossierDate.relative(s.lastViewed), caption: "most recent asset opened", symbol: "clock", tint: .gray, sensitivity: .personal),
                ])
                AdaptiveColumns {
                    TitledCard("How Often Assets Are Opened", subtitle: "Assets by view count (ZVIEWCOUNT)", symbol: "eye") {
                        RankList(s.viewHistogram, tint: .blue, limit: 8)
                    }
                    TitledCard("Contributions", subtitle: "Assets each participant added to a shared library or album", symbol: "person.2") {
                        RankList(s.participants.filter { $0.contributed > 0 }.map {
                            RankList.Item(id: String($0.id), name: $0.isCurrentUser ? "\($0.name) (you)" : $0.name, value: Double($0.contributed), valueText: Format.count($0.contributed),
                                          detail: "share \($0.share ?? 0)" + ($0.linkedPerson ? " · linked to a face cluster" : ""))
                        }, tint: .purple, sensitivity: .sensitive, limit: 8)
                    }
                    TitledCard("Shares", subtitle: "Shared libraries, shared albums and links", symbol: "square.and.arrow.up.on.square") {
                        MiniTable([.init("Title", sensitivity: .sensitive), .init("Kind"), .init("Created", sensitivity: .personal), .init("Assets", alignment: .trailing), .init("People", alignment: .trailing)],
                                  rows: s.shares.map { [$0.title.isEmpty ? "Untitled" : $0.title, $0.kind, DossierDate.day($0.created), Format.count($0.assets), String($0.participants)] }, limit: 10)
                    }
                    TitledCard("Albums by Kind", subtitle: "Rows of ZGENERICALBUM per Core Data entity", symbol: "rectangle.stack") {
                        RankList(s.albums, tint: .green, limit: 8)
                    }
                }
            }
        }
    }
}

// MARK: - Memory recipe

extension PhotosStore.MemoryRow {
    /// "pending, featured" — the same decoding in the table and the inspector: a non-zero
    /// ZPENDINGSTATE means the memory has not been shown yet, a non-zero ZFEATUREDSTATE that
    /// Photos currently features it.
    var stateText: String {
        var parts: [String] = []
        if (pending ?? 0) != 0 { parts.append("pending") }
        if (featured ?? 0) != 0 { parts.append("featured") }
        return parts.joined(separator: ", ")
    }
}

/// One ingredient of a memory: a typed graph node ("City · <name>", "Year · 2023", "Person").
struct MemoryRecipeNode: Identifiable, Hashable {
    enum Family { case type, person, place, time, content, other }
    let id: Int
    let kind: String
    var value: String
    let family: Family
    /// Stored node class and values, for the tooltip.
    let raw: String
    /// ZPERSONUUID when the node is a person, so the name can be looked up.
    var personUUID: String?

    /// ZGRAPHMEMORYIDENTIFIER is "<MemoryType>|PGGraph<Kind>Node|<value>…|PGGraph<Kind>Node|…":
    /// the memory type followed by the graph nodes it was built from, each with zero or more
    /// values (a unique key and a name for locations, a unit and a number for calendar units,
    /// a local identifier for people, moments and highlight groups).
    static func parse(_ identifier: String) -> [MemoryRecipeNode] {
        let tokens = identifier.split(separator: "|", omittingEmptySubsequences: true).map(String.init)
        guard let first = tokens.first else { return [] }
        var out = [MemoryRecipeNode(id: 0, kind: "Type", value: GraphInferences.spaced(first), family: .type, raw: first)]
        var index = 1
        func isNode(_ t: String) -> Bool { t.hasPrefix("PGGraph") && t.hasSuffix("Node") && t.count > 11 }
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard isNode(token) else { continue }
            var values: [String] = []
            while index < tokens.count, !isNode(tokens[index]) { values.append(tokens[index]); index += 1 }
            out.append(node(id: out.count, class: token, values: values))
        }
        return out
    }

    private static func node(id: Int, class cls: String, values: [String]) -> MemoryRecipeNode {
        let inner = String(cls.dropFirst(7).dropLast(4))
        let raw = ([cls] + values).joined(separator: " | ")
        let last = values.last ?? ""
        // "<UUID>/L0/070": a local identifier, meaningless to read.
        let isIdentifier = last.count >= 36 && last.prefix(36).allSatisfy { $0.isHexDigit || $0 == "-" }
        let isNumber = !last.isEmpty && last.allSatisfy { $0.isNumber || $0 == "-" }
        switch inner {
        case "Person":
            return MemoryRecipeNode(id: id, kind: "Person", value: "", family: .person, raw: raw, personUUID: isIdentifier ? String(last.prefix(36)) : nil)
        case "Me":
            return MemoryRecipeNode(id: id, kind: "Me", value: "", family: .person, raw: raw)
        case "SocialGroup":
            return MemoryRecipeNode(id: id, kind: "Social group", value: "", family: .person, raw: raw)
        case "CalendarUnit":
            let unit = values.first ?? ""
            if unit == "MonthDay", let n = Int(last), (101...1231).contains(n), (1...31).contains(n % 100) {
                let months = Calendar.current.shortMonthSymbols
                return MemoryRecipeNode(id: id, kind: "Day", value: "\(n % 100) \(months[min(max(n / 100, 1), months.count) - 1])", family: .time, raw: raw)
            }
            return MemoryRecipeNode(id: id, kind: unit.isEmpty ? "Date" : GraphInferences.spaced(unit), value: values.count > 1 ? last : "", family: .time, raw: raw)
        case "Season", "OverTheYears", "Weekend", "Holiday":
            let kind = GraphInferences.spaced(inner)
            return MemoryRecipeNode(id: id, kind: kind, value: last == inner ? "" : GraphInferences.spaced(last), family: .time, raw: raw)
        case "HighlightType":
            return MemoryRecipeNode(id: id, kind: "Trip type", value: GraphInferences.spaced(last), family: .content, raw: raw)
        case "HomeWork":
            return MemoryRecipeNode(id: id, kind: "Place", value: last, family: .place, raw: raw)
        case "SceneFeature":
            return MemoryRecipeNode(id: id, kind: "Scene", value: GraphInferences.spaced(last), family: .content, raw: raw)
        default:
            if inner.hasPrefix("Location") {
                let level = String(inner.dropFirst(8))
                var name = last
                if level == "Country", name.count == 2, let localized = Locale.current.localizedString(forRegionCode: name) { name = localized }
                return MemoryRecipeNode(id: id, kind: level.isEmpty ? "Location" : level, value: name, family: .place, raw: raw)
            }
            let kind = GraphInferences.spaced(inner)
            let value = isIdentifier || isNumber || last == inner ? "" : GraphInferences.spaced(last)
            let family: Family = ["Moment", "HighlightGroup", "Highlight"].contains(inner) ? .time : (inner.contains("Address") || inner.contains("Area") || inner.contains("Business") ? .place : .content)
            return MemoryRecipeNode(id: id, kind: kind, value: value, family: family, raw: raw)
        }
    }
}

/// The graph memory identifier as typed chips instead of a node-name dump.
private struct MemoryRecipeView: View {
    let library: PhotosLibrary
    let identifier: String
    @State private var names: [String: String] = [:]

    var body: some View {
        let nodes = MemoryRecipeNode.parse(identifier)
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(nodes) { node in
                chip(node)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: identifier) {
            let uuids = nodes.compactMap(\.personUUID)
            let lib = library
            guard !uuids.isEmpty else { names = [:]; return }
            names = await SnapshotReadiness.track { await PhotosStore.personNames(lib, uuids: uuids) }
        }
    }

    private func chip(_ node: MemoryRecipeNode) -> some View {
        let tint = tint(node.family)
        let value = node.personUUID.flatMap { names[$0] } ?? node.value
        return HStack(spacing: 4) {
            Image(systemName: symbol(node.family)).font(.caption2)
            Text(node.kind).font(.caption.weight(.medium))
            if !value.isEmpty {
                Text(value).font(.caption).foregroundStyle(.primary).lineLimit(1).sensitive(node.family == .type || node.family == .content ? .personal : .sensitive)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(tint.opacity(0.13), in: Capsule())
        .help(node.raw)
    }

    private func tint(_ family: MemoryRecipeNode.Family) -> Color {
        switch family {
        case .type: return .yellow
        case .person: return .purple
        case .place: return .red
        case .time: return .orange
        case .content: return .teal
        case .other: return .gray
        }
    }

    private func symbol(_ family: MemoryRecipeNode.Family) -> String {
        switch family {
        case .type: return "sparkles"
        case .person: return "person.fill"
        case .place: return "mappin"
        case .time: return "calendar"
        case .content: return "tag"
        case .other: return "circle"
        }
    }
}
