import SwiftUI
import DossierCore

/// (1) Profile summary: what PersonalizationPortrait currently believes the owner cares
/// about — top topics, entities per category, places and where the evidence came from.
struct SummarySection: View {
    @Environment(\.navigate) private var navigate
    @Environment(\.refreshToken) private var refreshToken
    /// `nil` = automatic: unnamed topics are hidden when fewer than half of the top ones have a name.
    @State private var namedOnlyChoice: Bool?

    var body: some View {
        VStack(spacing: 0) {
            AsyncContent(reloadKey: refreshToken) {
                await PortraitStore.resetCaches()
                return try await PortraitStore.overview()
            } content: { overview in
                ScrollPage {
                    Explainer(text: "macOS continuously reads what you write and receive — mail, calendar, reminders, Maps guides, Photos — and distils it into an interest profile: Wikidata topics, named entities (people, organisations, places) and locations, each with a score. Siri suggestions, QuickType and Spotlight rank with it. Everything below is the system's inference, stored only on this Mac.")
                    StatTileRow(stats(overview))
                    // Side by side while each column is wide enough for the per-app table;
                    // stacked below that (always the case in the minimum window).
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: Metrics.blockSpacing) {
                            topicsBlock(overview)
                            sourcesBlock(overview)
                        }
                        .frame(minWidth: 900, idealWidth: 900, maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: Metrics.blockSpacing) {
                            topicsBlock(overview)
                            sourcesBlock(overview)
                        }
                    }
                    if overview.monthly.count > 1 {
                        SectionHeader("Documents Analysed Over Time", subtitle: "Source documents by month of the document's date", symbol: "calendar")
                        LineChartView(overview.monthly, style: .bars, unit: .month).frame(height: 190).card()
                    }
                    SectionHeader("Top Entities by Category", subtitle: "Most mentioned names per class, exactly as the system's tagger classified them — it also files pronouns and capitalised words under Person", symbol: "person.2") {
                        link("All Entities", "profile.entities")
                    }
                    entityGrid(overview)
                    SectionHeader("Top Places", subtitle: "Location records with the most evidence", symbol: "mappin.and.ellipse") {
                        link("All Places", "profile.places")
                    }
                    placeList(overview).card()
                }
            }
            StoreFooter(ProfilePaths.portraitDB, note: "tp_records · ne_records · loc_records · sources")
        }
    }

    private func topicsBlock(_ overview: PortraitOverview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Top Topics", subtitle: "Ranked by the system's cached topic score", symbol: "number") {
                HStack(spacing: 12) {
                    if !overview.topTopicsNamed.isEmpty {
                        Toggle("Named only", isOn: Binding(get: { namedOnly(overview) }, set: { namedOnlyChoice = $0 }))
                            .toggleStyle(.checkbox).font(.callout)
                            .help("Hide topic ids for which no name could be derived on this Mac")
                    }
                    link("All Topics", "profile.topics")
                }
            }
            topicList(overview).card()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func sourcesBlock(_ overview: PortraitOverview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Where It Comes From", subtitle: "Source documents per app", symbol: "tray.full")
            BarChartView(overview.apps.prefix(9).map { ChartBar(AppNames.name($0.bundle), Double($0.documents)) }).card()
            appTable(overview).card()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func link(_ title: String, _ section: String) -> some View {
        if let navigate {
            Button(title + " ›") { navigate(DeepLink(sectionID: section, payload: "")) }
                .buttonStyle(.link)
                .font(.callout)
        }
    }

    private func stats(_ o: PortraitOverview) -> [Stat] {
        [
            Stat("Topics", Format.compact(o.topics), caption: "\(Format.count(o.topicRecords)) extractions", symbol: "number", tint: .blue),
            Stat("Named Entities", Format.compact(o.entities), caption: "\(Format.count(o.entityRecords)) mentions", symbol: "person.text.rectangle", tint: .purple),
            Stat("Place Records", Format.compact(o.placeRecords), caption: "photos, Maps, mail", symbol: "mappin.and.ellipse", tint: .red),
            Stat("Source Documents", Format.compact(o.sources), caption: "\(o.apps.count) apps", symbol: "doc.text.magnifyingglass", tint: .orange),
            Stat("Contact Handles", Format.compact(o.handles), caption: "\(Format.count(o.significant)) significant", symbol: "at", tint: .teal),
            Stat("Evidence Window", o.timeRange.map { DossierDate.day($0.lowerBound) } ?? "—", caption: o.timeRange.map { "to " + DossierDate.day($0.upperBound) }, symbol: "clock.arrow.circlepath", tint: .green),
        ]
    }

    private func namedOnly(_ o: PortraitOverview) -> Bool {
        guard !o.topTopicsNamed.isEmpty else { return false }
        return namedOnlyChoice ?? (o.topTopics.filter { $0.name != nil }.count * 2 < o.topTopics.count)
    }

    private func topicList(_ o: PortraitOverview) -> some View {
        let topics = namedOnly(o) ? o.topTopicsNamed : o.topTopics
        let maxScore = topics.compactMap { $0.cachedScore ?? $0.score }.max() ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            if topics.isEmpty {
                Text("No topics recorded.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
                HStack(spacing: 10) {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 18, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if let name = topic.name {
                                Text(name).font(.callout.weight(.medium)).lineLimit(1).sensitive(.personal)
                            }
                            Text(topic.qid).font(topic.name == nil ? .callout.monospaced() : .caption.monospaced()).foregroundStyle(topic.name == nil ? .primary : .tertiary).lineLimit(1).layoutPriority(1).sensitive(.personal)
                            if topic.name == nil, let context = topic.context {
                                Text("seen with " + context).font(.caption).foregroundStyle(.secondary).lineLimit(1).sensitive(.sensitive)
                            }
                            Spacer(minLength: 4)
                            Text(ProfileFormat.score(topic.cachedScore ?? topic.score)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ScoreBar(fraction: maxScore > 0 ? (topic.cachedScore ?? topic.score) / maxScore : 0, tint: .blue)
                    }
                    if let url = ProfileFormat.wikidataURL(topic.qid) {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                            .foregroundStyle(.secondary)
                            .help("Look up \(topic.qid) on Wikidata (opens your browser; nothing is fetched automatically)")
                    }
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { navigate?(DeepLink(sectionID: "profile.topics", payload: topic.qid)) }
                if index < topics.count - 1 { Divider() }
            }
            Text(o.topicsNamed >= o.topics
                 ? "Topics are stored as Wikidata ids only. All \(Format.count(o.topics)) could be named without a lookup — from the system's own lists on this Mac and a built-in table of the topic model's vocabulary."
                 : "Topics are stored as Wikidata ids only. \(Format.count(o.topicsNamed)) of \(Format.count(o.topics)) could be named without a lookup; for the rest the entities found in the same documents are shown, and the arrow opens Wikidata.")
                .font(.caption).foregroundStyle(.tertiary).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func appTable(_ o: PortraitOverview) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                Text("App").gridColumnAlignment(.leading)
                Text("Docs").fixedSize().gridColumnAlignment(.trailing)
                Text("Topics").fixedSize().gridColumnAlignment(.trailing)
                Text("Entities").fixedSize().gridColumnAlignment(.trailing)
                Text("Places").fixedSize().gridColumnAlignment(.trailing)
                Text("Latest").fixedSize().gridColumnAlignment(.trailing)
            }
            .lineLimit(1)
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Divider().gridCellColumns(6)
            ForEach(o.apps.prefix(12)) { app in
                GridRow {
                    // The numbers keep their width; only the app name gives way.
                    AppLabel(bundle: app.bundle).font(.callout).frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
                    Text(Format.count(app.documents)).fixedSize()
                    Text(app.topics == 0 ? "–" : Format.count(app.topics)).fixedSize()
                    Text(app.entities == 0 ? "–" : Format.count(app.entities)).fixedSize()
                    Text(app.places == 0 ? "–" : Format.count(app.places)).fixedSize()
                    Text(DossierDate.day(app.last)).foregroundStyle(.secondary).fixedSize()
                }
                .lineLimit(1)
                .font(.callout.monospacedDigit())
            }
        }
    }

    private func entityGrid(_ o: PortraitOverview) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 420), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            ForEach(Array(o.entityGroups.prefix(12).enumerated()), id: \.element.category) { index, group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: PortraitLabels.entitySymbol(group.category)).foregroundStyle(ChartPalette.color(index)).frame(width: 18)
                        Text(PortraitLabels.entityCategory(group.category)).font(.callout.weight(.semibold))
                        Spacer(minLength: 4)
                        Text(Format.count(group.distinct)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Divider()
                    ForEach(Array(group.top.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 6) {
                            Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle).sensitive(.sensitive)
                            Spacer(minLength: 4)
                            Text(Format.count(item.mentions)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .card(padding: 12)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { navigate?(DeepLink(sectionID: "profile.entities", payload: "\(group.category)\t")) }
            }
        }
    }

    private func placeList(_ o: PortraitOverview) -> some View {
        let maxRecords = Double(o.topPlaces.map(\.records).max() ?? 1)
        return VStack(alignment: .leading, spacing: 0) {
            if o.topPlaces.isEmpty { Text("No location records.").font(.callout).foregroundStyle(.secondary) }
            ForEach(Array(o.topPlaces.enumerated()), id: \.element.id) { index, place in
                HStack(spacing: 12) {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(.red.opacity(0.8))
                    Text(place.name).font(.callout).lineLimit(1).sensitive(.sensitive).frame(maxWidth: .infinity, alignment: .leading)
                    Text(place.origin).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 190, alignment: .leading)
                    ScoreBar(fraction: Double(place.records) / max(maxRecords, 1), tint: .red).frame(width: 90)
                    Text(Format.count(place.records)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
                .padding(.vertical, 5)
                if index < o.topPlaces.count - 1 { Divider() }
            }
        }
    }
}
