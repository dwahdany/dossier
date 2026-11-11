import SwiftUI
import DossierCore

/// (5) Search index: every category the Photos search index knows, the terms in it and how many
/// assets carry each term — scene labels, places, people, document classes and recognised text.
struct SearchIndexSection: View {
    @ObservedObject private var selection = PhotosLibrarySelection.shared
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @State private var backend: SearchBackend?
    @State private var category: Int?
    @State private var filterText = ""
    @State private var categoryFilter = ""
    @State private var showSynonyms = false
    @StateObject private var reveal = RevealStore()

    private struct Loaded: Sendable {
        let library: PhotosLibrary
        let backends: [SearchBackend]
        let backend: SearchBackend
        let stats: SearchIndexStats
    }

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (backend, category, filterText, categoryFilter, showSynonyms)
        VStack(spacing: 0) {
            content.requiresLibrary(selection.current)
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink, link.payload.hasPrefix("term:") else { return }
            let parts = link.payload.dropFirst(5).split(separator: ":", maxSplits: 1).map(String.init)
            if let code = parts.first.flatMap({ Int($0) }) {
                backend = .leo
                category = code
                filterText = parts.count > 1 ? parts[1] : ""
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let lib = selection.current
        let token = refreshToken
        let wanted = backend
        AsyncContent(reloadKey: "\(lib?.id ?? "")|\(wanted?.rawValue ?? "")") {
            guard let lib else { throw PhotosError.noLibrary() }
            await PhotosCaches.shared.sync(token: token)
            let backends = await SearchIndexStore.availableBackends(lib)
            guard let chosen = wanted.flatMap({ backends.contains($0) ? $0 : nil }) ?? backends.first else {
                throw DossierError.missing("This library has neither a search lexicon in Photos.sqlite nor a psi.sqlite search index.")
            }
            let stats = try await SearchIndexStore.stats(lib, backend: chosen)
            return Loaded(library: lib, backends: backends, backend: chosen, stats: stats)
        } content: { loaded in
            VStack(spacing: 0) {
                SectionStrip {
                    Picker("Index", selection: Binding(get: { loaded.backend }, set: { backend = $0; category = nil; filterText = "" })) {
                        ForEach(loaded.backends) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    StripCaption("Terms Photos indexed for each asset so that search can find it")
                } trailing: {
                    LibraryMenu()
                }
                StatTileRow(tiles(loaded.stats), minTileWidth: 140)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 12)
                Divider()
                HStack(spacing: 0) {
                    categoryList(loaded).frame(width: 330)
                    Divider()
                    termTable(loaded)
                }
                StoreFooter(loaded.stats.source, note: loaded.backend == .leo ? "ZLEOLEXEME, ZLEOITEM" : "groups, ga, assets")
            }
        }
    }

    private func tiles(_ s: SearchIndexStats) -> [Stat] {
        let scenes = s.categories.first { $0.code == s.backend.sceneCode }
        let utility = s.categories.first { $0.code == s.backend.utilityCode }
        let documents = s.backend.documentCode.flatMap { code in s.categories.first { $0.code == code } }
        return [
            Stat("Indexed Assets", Format.compact(s.items), caption: "items the index can find", symbol: "photo.stack", tint: .blue),
            Stat("Terms", Format.compact(s.terms), caption: "\(s.categories.count) categories", symbol: "character.book.closed", tint: .indigo),
            Stat("Term–Asset Links", Format.compact(s.links), caption: s.items > 0 ? "≈ \(s.links / max(s.items, 1)) per asset" : nil, symbol: "link", tint: .teal),
            Stat("Scene Labels", Format.compact(scenes?.terms ?? 0), caption: "\(Format.compact(scenes?.assetLinks ?? 0)) assignments", symbol: "tag", tint: .green),
            Stat("OCR Words", Format.compact(s.categories.first { $0.code == s.backend.ocrCode }?.terms ?? 0), caption: "\(Format.count(s.ocrAssets)) assets with text", symbol: "text.viewfinder", tint: .orange),
            Stat("Utility Classes", Format.count((utility?.terms ?? 0) + (documents?.terms ?? 0)), caption: "\(Format.compact((utility?.assetLinks ?? 0) + (documents?.assetLinks ?? 0))) document-like assets", symbol: "doc.text.magnifyingglass", tint: .purple),
        ]
    }

    private func selectedCategory(_ loaded: Loaded) -> SearchCategoryRow? {
        if let category, let match = loaded.stats.categories.first(where: { $0.code == category }) { return match }
        return loaded.stats.categories.first { $0.code == loaded.backend.sceneCode } ?? loaded.stats.categories.first
    }

    private func categoryList(_ loaded: Loaded) -> some View {
        let current = selectedCategory(loaded)
        let needle = categoryFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = loaded.stats.categories.filter { needle.isEmpty || $0.name.lowercased().contains(needle) || $0.group.lowercased().contains(needle) || String($0.code).contains(needle) }
        let groups = Dictionary(grouping: rows, by: \.group)
        let order = ["Content", "People", "Places", "Time", "Media", "Library", "Other"].filter { groups[$0] != nil }
        return VStack(spacing: 0) {
            FilterField("Filter categories", text: $categoryFilter)
            Divider()
            List(selection: Binding(get: { current?.code }, set: { if let v = $0 { category = v; filterText = "" } })) {
                ForEach(order, id: \.self) { group in
                    Section(group) {
                        ForEach(groups[group] ?? []) { row in
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(row.name).font(.callout).lineLimit(1)
                                        if row.reveal { Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.orange).help("Free text from your photos — revealed per row") }
                                    }
                                    Text("code \(row.code) · \(Format.count(row.terms)) terms" + (row.synonyms > 0 ? " · \(Format.count(row.synonyms)) synonyms" : ""))
                                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Text(Format.compact(row.assetLinks)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .tag(row.code)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func termTable(_ loaded: Loaded) -> some View {
        if let current = selectedCategory(loaded) {
            let lib = loaded.library
            let backend = loaded.backend
            let code = current.code
            let hidden = current.reveal
            let store = reveal
            let synonyms = showSynonyms
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(current.name).font(.headline)
                    TagLabel("code \(current.code)")
                    if current.reveal { SensitivityBadge(.sensitive) }
                    Spacer()
                    Text("\(Format.count(current.assetLinks)) asset links").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                Divider()
                PagedTable(
                    columns: [
                        PagedColumn<SearchTermRow>("Term", id: "content", width: 320, min: 140, sensitivity: current.sensitivity) { row in
                            hidden && !store.isRevealed("t\(row.id)") ? "(hidden — reveal the row first)" : row.content
                        }
                        .cell { row in
                            if hidden {
                                RevealCell(id: "t\(row.id)", text: row.content, hiddenSummary: "\(row.content.count) characters", store: store)
                            } else {
                                HStack(spacing: 5) {
                                    Text(row.content.isEmpty ? "(empty)" : row.content).foregroundStyle(row.content.isEmpty ? .tertiary : .primary).lineLimit(1).sensitive(current.sensitivity)
                                    if row.isSynonym { TagLabel("synonym") }
                                }
                            }
                        },
                        PagedColumn("Assets", id: "assets", width: 80, alignment: .trailing) { Format.count($0.assets) },
                        PagedColumn("Share", id: "share", width: 70, alignment: .trailing, sortable: false, secondary: true) { loaded.stats.items > 0 ? Format.percent(Double($0.assets) / Double(loaded.stats.items)) : "—" },
                        PagedColumn("Identifier", id: "identifier", width: 200, sortable: false, monospaced: true, secondary: true, hiddenByDefault: !current.name.contains("Scene")) { $0.identifier },
                    ],
                    searchPrompt: "Filter terms",
                    reloadKey: "\(lib.id)|\(backend.rawValue)|\(code)|\(synonyms)",
                    exportName: "photos-search-terms-\(code)",
                    emptyTitle: "No Terms",
                    filter: $filterText,
                    fetch: { req in try await SearchIndexStore.terms(lib, backend: backend, category: code, synonyms: synonyms, request: req) },
                    count: { req in try await SearchIndexStore.termCount(lib, backend: backend, category: code, synonyms: synonyms, search: req.search) }
                ) {
                    if hidden { RevealAllToggle(store: store) }
                    if current.synonyms > 0 {
                        Toggle("Synonyms", isOn: $showSynonyms).toggleStyle(.switch).controlSize(.mini).font(.caption)
                            .help("Also list the alternative words that lead to the same term")
                    }
                }
            }
        } else {
            StatePlaceholder(title: "No Categories", symbol: "text.magnifyingglass", message: "The search index is empty.")
        }
    }
}
