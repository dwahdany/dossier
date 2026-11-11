import DossierCore
import SwiftUI

/// (5) Web usage. Only Safari reports pages to Screen Time, so this is Safari's history
/// as the knowledge stores see it: URLs, domains and time in front.
struct WebUsageView: View {
    enum Source: String, CaseIterable, Identifiable {
        case all = "All Records", knowledge = "knowledgeC Intervals", biome = "Biome Intervals", navigations = "Safari Navigations"
        var id: String { rawValue }
    }

    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @State private var chosenSource: Source?
    @State private var search = ""
    @State private var selected: WebVisit?
    @State private var summaryHeight: CGFloat = 220

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (chosenSource, search, selected, summaryHeight)
        AsyncContent(reloadKey: refreshToken, emptyTitle: "No Web Usage Recorded", emptySymbol: "safari") {
            await ActivityStore.shared.sync(token: refreshToken)
            let probe = Paths.probe(Paths.knowledgeC)
            if case .inaccessible(let reason) = probe, Biome.stream(named: "App.WebUsage") == nil { throw DossierError.inaccessible(reason) }
            return await ActivityStore.shared.web()
        } isEmpty: { $0.all.isEmpty } content: { history in
            VStack(spacing: 0) {
                // The summary takes its natural height but never squeezes the table below
                // its minimum: in a short window it scrolls instead of growing the section.
                ScrollView {
                    summary(history)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { summaryHeight = $0 }
                        .uiTestProbe("scroll")
                }
                .frame(maxHeight: summaryHeight)
                .background(Color(nsColor: .windowBackgroundColor))
                .layoutPriority(1)
                Divider()
                table(history)
                    .frame(minHeight: 230)
                StoreFooter(Paths.knowledgeC, note: "ZOBJECT /app/webUsage · Biome App.WebUsage, Safari.Navigations, Safari.SearchEngine, Safari.PageLoad")
            }
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink, link.payload.hasPrefix("q:") else { return }
            chosenSource = .all
            search = String(link.payload.dropFirst(2))
        }
    }

    private static let explainer = "Safari only: the system records which page is in front for Screen Time (knowledgeC /app/webUsage and Biome App.WebUsage) and Safari logs navigations to Biome. Other browsers show up as app usage, but their pages are not stored here. Private Browsing windows are not reported."

    private func summary(_ history: WebHistory) -> some View {
        let urls = Set(history.all.map(\.url).filter { !$0.isEmpty })
        let tiles = StatTileRow([
            Stat("Time on Pages", Format.usage(history.totalSeconds), caption: "\(history.knowledge.isEmpty ? history.biome.count : history.knowledge.count) intervals", symbol: "clock.fill", tint: .blue),
            Stat("Domains", Format.count(history.domains.count), caption: "\(Format.count(urls.count)) distinct URLs", symbol: "globe", tint: .teal),
            Stat("Navigations", Format.count(history.navigations.count), caption: "Safari.Navigations", symbol: "arrow.triangle.turn.up.right.circle.fill", tint: .purple),
            Stat("Search Engine", history.searchEngines.first.map(Self.engineName) ?? "—", caption: "Safari.SearchEngine", symbol: "magnifyingglass", tint: .orange),
        ], minTileWidth: 130)
        // Wide: tiles and explainer beside the domain card. Narrow: tiles across the full
        // width, explainer and a shorter domain list below them.
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Metrics.blockSpacing) {
                VStack(alignment: .leading, spacing: 12) {
                    tiles
                    ExplainerText(Self.explainer)
                }
                .frame(minWidth: 580, idealWidth: 580, maxWidth: .infinity, alignment: .leading)
                domainCard(history, limit: 8).frame(width: 380)
            }
            VStack(alignment: .leading, spacing: 12) {
                tiles
                HStack(alignment: .top, spacing: Metrics.blockSpacing) {
                    ExplainerText(Self.explainer).frame(maxWidth: .infinity, alignment: .leading)
                    domainCard(history, limit: 4).frame(minWidth: 220, idealWidth: 320, maxWidth: 320)
                }
            }
        }
        .padding(Metrics.pagePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func domainCard(_ history: WebHistory, limit: Int) -> some View {
        let top = Array(history.domains.prefix(limit))
        let maxSeconds = max(top.first?.seconds ?? 1, 1)
        return TitledCard("Top Domains", subtitle: "Time in front", symbol: "globe") {
            VStack(spacing: 4) {
                ForEach(top) { d in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.domain).font(.callout).lineLimit(1).sensitive(.sensitive)
                            ProportionBar(fraction: d.seconds / maxSeconds, tint: .teal)
                        }
                        Text(d.seconds > 0 ? Format.usage(d.seconds) : "\(d.visits) nav.").font(.callout).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 60, alignment: .trailing)
                    }
                }
            }
        }
    }

    static func engineName(_ identifier: String) -> String {
        // Identifiers look like reversed host names of the provider ("com.google.www").
        let parts = identifier.split(separator: ".").filter { !["com", "www", "org", "net"].contains($0) }
        return parts.first.map { String($0).capitalized } ?? identifier
    }

    /// Default: the system's own intervals; "All Records" shows every store side by side.
    private func source(_ history: WebHistory) -> Source {
        chosenSource ?? (history.knowledge.isEmpty ? (history.biome.isEmpty ? .all : .biome) : .knowledge)
    }

    private func rows(_ history: WebHistory) -> [WebVisit] {
        switch source(history) {
        case .all: return history.all.sorted { $0.start > $1.start }
        case .knowledge: return history.knowledge
        case .biome: return history.biome
        case .navigations: return history.navigations
        }
    }

    private func table(_ history: WebHistory) -> some View {
        let data = rows(history)
        let source = source(history)
        let matches: @Sendable (WebVisit, String) -> Bool = { v, q in
            v.url.localizedCaseInsensitiveContains(q) || v.domain.localizedCaseInsensitiveContains(q) || v.source.localizedCaseInsensitiveContains(q)
        }
        return PagedTable(
            columns: [
                PagedColumn<WebVisit>("Start", id: "start", width: 150, min: 146) { DossierDate.sortable($0.start) },
                PagedColumn("Duration", id: "duration", width: 80, min: 70, alignment: .trailing) { $0.end == nil ? "—" : Format.usage($0.duration) },
                PagedColumn("Domain", id: "domain", width: 200, min: 130, sensitivity: .sensitive) { $0.domain },
                PagedColumn("URL", id: "url", width: 380, min: 180, sensitivity: .sensitive) { $0.url },
                PagedColumn("Record", id: "source", width: 100, min: 90) { $0.source }
                    .cell { v in TagLabel(v.source, tint: v.source == "knowledgeC" ? .blue : (v.source == "Biome" ? .purple : .teal)) },
                PagedColumn("Detail", id: "detail", width: 170, min: 120, secondary: true) { $0.detail },
                PagedColumn("End", id: "end", width: 150, min: 146, secondary: true, hiddenByDefault: true) { DossierDate.sortable($0.end) },
                PagedColumn("App", id: "bundle", width: 160, monospaced: true, secondary: true, hiddenByDefault: true) { $0.bundle },
            ],
            searchPrompt: "Filter URLs and domains",
            reloadKey: "\(source.rawValue)|\(data.count)",
            exportName: "web-usage",
            emptyTitle: "No Records",
            filter: $search,
            fetch: { request in
                MemoryPager.page(data, request, matches: matches, sorters: [
                    "start": { $0.start < $1.start },
                    "end": { ($0.end ?? .distantPast) < ($1.end ?? .distantPast) },
                    "duration": { $0.duration < $1.duration },
                    "domain": { $0.domain < $1.domain },
                    "url": { $0.url < $1.url },
                    "source": { $0.source < $1.source },
                    "detail": { $0.detail < $1.detail },
                    "bundle": { $0.bundle < $1.bundle },
                ])
            },
            count: { request in MemoryPager.count(data, request, matches: matches) },
            onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
        ) {
            Picker("Source", selection: Binding(get: { source }, set: { chosenSource = $0 })) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
        }
        .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let v = selected {
                InspectorPage(title: v.domain.isEmpty ? "Web Record" : v.domain, subtitle: v.source, sensitivity: .sensitive, onClose: { selected = nil }) {
                    KeyValueGrid([
                        KeyValueItem("URL", v.url, sensitivity: .sensitive, monospaced: true),
                        KeyValueItem("Domain", v.domain, sensitivity: .sensitive),
                        KeyValueItem("Start", DossierDate.medium(v.start)),
                        KeyValueItem("End", v.end.map { DossierDate.medium($0) }),
                        KeyValueItem("In front", v.end == nil ? nil : Format.usage(v.duration)),
                        KeyValueItem("Record", v.source + " · " + v.detail),
                        KeyValueItem("App", v.bundle, monospaced: true),
                    ], valueLineLimit: 12)
                    if let d = history.domains.first(where: { $0.domain == v.domain || v.domain.hasSuffix("." + $0.domain) || $0.domain.hasSuffix("." + v.domain) }) {
                        InspectorGroupTitle("This domain")
                        KeyValueGrid([
                            KeyValueItem("Total time", Format.usage(d.seconds)),
                            KeyValueItem("Intervals", Format.count(d.visits)),
                            KeyValueItem("Distinct URLs", Format.count(d.urls.count)),
                            KeyValueItem("Last seen", DossierDate.medium(d.last)),
                        ])
                    }
                    if !v.url.isEmpty {
                        Button("Copy URL") { Pasteboard.copy(v.url) }.controlSize(.small)
                    }
                }
            }
        }
    }
}
