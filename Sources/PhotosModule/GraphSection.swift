import SwiftUI
import Charts
import DossierCore

/// (3) Graph inferences: what the PhotosGraph knowledge graph has concluded — who the owner is, home and
/// work, frequent locations, relationships, social groups, pets, businesses, public events, meanings,
/// sensitive ("taboo") categories and languages.
struct GraphSection: View {
    enum Tab: String, CaseIterable, Identifiable {
        case identity = "Identity & Places", people = "People & Groups", events = "Businesses & Events", meanings = "Meanings & Sensitive", structure = "Structure"
        var id: String { rawValue }
        /// Title for the strip when the full titles do not fit the pane.
        var shortTitle: String {
            switch self {
            case .identity: return "Identity"
            case .people: return "People"
            case .events: return "Events"
            case .meanings: return "Meanings"
            case .structure: return "Structure"
            }
        }
        var key: String {
            switch self {
            case .identity: return "identity"
            case .people: return "people"
            case .events: return "events"
            case .meanings: return "meanings"
            case .structure: return "structure"
            }
        }
    }

    @ObservedObject private var selection = PhotosLibrarySelection.shared
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @State private var tab: Tab = .identity

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = tab
        VStack(spacing: 0) {
            SectionStrip {
                FittingSegmentedPicker(label: "View", options: Tab.allCases.map { .init(value: $0, title: $0.rawValue, shortTitle: $0.shortTitle) }, selection: $tab)
            } trailing: {
                LibraryMenu()
            }
            content.requiresLibrary(selection.current)
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink, link.payload.hasPrefix("tab:") else { return }
            let key = String(link.payload.dropFirst(4))
            if let match = Tab.allCases.first(where: { $0.key == key }) { tab = match }
        }
    }

    @ViewBuilder
    private var content: some View {
        let lib = selection.current
        let token = refreshToken
        AsyncContent(reloadKey: lib?.id ?? "") {
            guard let lib else { throw PhotosError.noLibrary() }
            await PhotosCaches.shared.sync(token: token)
            return try await PhotosCaches.shared.graph(for: lib).1
        } content: { inf in
            VStack(spacing: 0) {
                ScrollPage {
                    switch tab {
                    case .identity: GraphIdentityPage(inf: inf)
                    case .people: GraphPeoplePage(inf: inf)
                    case .events: GraphEventsPage(inf: inf)
                    case .meanings: GraphMeaningsPage(inf: inf)
                    case .structure: GraphStructurePage(inf: inf)
                    }
                }
                StoreFooter(inf.url, note: "Label, Node, Edge, NodeValue, EdgeValue")
            }
        }
    }
}

private func coordinateText(_ lat: Double?, _ lon: Double?) -> String {
    guard let lat, let lon else { return "" }
    return String(format: "%.4f, %.4f", lat, lon)
}

// MARK: Identity & places

private struct GraphIdentityPage: View {
    let inf: GraphInferences

    var body: some View {
        InfoNote("The PhotosGraph is a knowledge graph that photoanalysisd rebuilds from your library: every moment is linked to the people present, the address, the time, scenes and inferred meanings. From it Photos derives who you are, where you live and work, who matters to you and what your trips and memories are. Everything below is the system’s inference, not something you entered.")

        StatTileRow([
            Stat("Nodes", Format.compact(inf.nodeCount), caption: "\(inf.labelCount) labels", symbol: "circle.hexagongrid", tint: .blue),
            Stat("Edges", Format.compact(inf.edgeCount), caption: "\(Format.compact(inf.sceneEdges)) scene links", symbol: "point.3.connected.trianglepath.dotted", tint: .indigo),
            Stat("Moments", Format.compact(inf.momentCount), caption: "events in the library", symbol: "clock.arrow.circlepath", tint: .orange),
            Stat("Covers", inf.momentRange.map { DossierDate.day($0.lowerBound) } ?? "—", caption: "first moment", symbol: "calendar", tint: .gray, sensitivity: .personal),
            Stat("People", Format.count(inf.people.count), caption: "\(inf.relationships.count) relationship edges", symbol: "person.2", tint: .purple),
            Stat("Home / Work", "\(inf.places.filter { $0.kind == "Home" && $0.latitude != nil }.count) / \(inf.places.filter { $0.kind == "Work" && $0.latitude != nil }.count)", caption: "addresses inferred", symbol: "house", tint: .green),
            Stat("Trips", Format.count(inf.longTrips + inf.shortTrips), caption: "\(inf.longTrips) long · \(inf.shortTrips) short", symbol: "airplane", tint: .teal),
        ])

        AdaptiveColumns(minWidth: 380) {
            TitledCard("Me", subtitle: "The node that stands for the library owner", symbol: "person.crop.circle") {
                KeyValueGrid([
                    KeyValueItem("Name on the Me node", inf.meName.flatMap { $0.isEmpty ? nil : $0 } ?? "not set", sensitivity: .sensitive),
                    KeyValueItem("Contact card linked", inf.meHasContact ? "Yes" : "No"),
                    KeyValueItem("Inferred to be face cluster", inf.meInferredPerson ?? "no inference stored", sensitivity: .sensitive),
                    KeyValueItem("Library languages", infoValue("languageIdentifiers"), sensitivity: .personal),
                    KeyValueItem("Locale", infoValue("localeIdentifier"), sensitivity: .personal),
                    KeyValueItem("Selfies counted", infoValue("numberOfSelfies")),
                ].filter { !$0.value.isEmpty && $0.value != "—" }, labelWidth: 180)
            }
            TitledCard("Languages", subtitle: "Languages attached to the countries you photographed in", symbol: "character.bubble") {
                MiniTable([.init("Language"), .init("Countries", sensitivity: .sensitive)],
                          rows: inf.languages.map { l in [Locale.current.localizedString(forIdentifier: l.locale).map { "\($0) (\(l.locale))" } ?? l.locale, l.countries.joined(separator: ", ")] }, limit: 8)
            }
        }

        SectionHeader("Home & Work", subtitle: "Addresses the graph marks as someone’s home or workplace (IS_HOME_WORK → IS_OWNED_BY)", symbol: "house") { SensitivityBadge(.sensitive) }
        VStack(alignment: .leading, spacing: 12) {
            MiniTable([.init("Kind"), .init("Owner", sensitivity: .sensitive), .init("Address", sensitivity: .sensitive), .init("Coordinates", sensitivity: .sensitive, secondary: true), .init("Moments", alignment: .trailing)],
                      rows: inf.places.map { [$0.kind, $0.owner, $0.address, coordinateText($0.latitude, $0.longitude), $0.moments > 0 ? Format.count($0.moments) : ""] },
                      emptyText: "The graph holds no home or work nodes.")
            let points = inf.places.compactMap { p -> MapPoint? in
                guard let lat = p.latitude, let lon = p.longitude else { return nil }
                return MapPoint(id: p.id, latitude: lat, longitude: lon, title: p.kind, weight: Double(max(p.moments, 1)))
            } + inf.frequent.compactMap { f -> MapPoint? in
                guard let lat = f.latitude, let lon = f.longitude else { return nil }
                return MapPoint(id: "f\(f.id)", latitude: lat, longitude: lon, title: "Frequent", weight: Double(max(f.moments, 1)))
            }
            if !points.isEmpty {
                let focus = MapFocus.densest(points)
                PointMapView(focus.points, maxMarkers: 40, tint: .green).frame(height: 260)
                if focus.omitted > 0 {
                    Text("Map shows the area with the most moments; \(focus.omitted) place\(focus.omitted == 1 ? "" : "s") elsewhere are listed above only.").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .card()

        SectionHeader("Frequent Locations", subtitle: "Places where many moments were captured over a period of time, with the date range the graph assigns", symbol: "mappin.and.ellipse") { SensitivityBadge(.sensitive) }
        MiniTable([.init("Address", sensitivity: .sensitive), .init("From", sensitivity: .personal), .init("To", sensitivity: .personal), .init("Moments", alignment: .trailing), .init("Coordinates", sensitivity: .sensitive, secondary: true)],
                  rows: inf.frequent.map { [$0.address, DossierDate.day($0.start), DossierDate.day($0.end), Format.count($0.moments), coordinateText($0.latitude, $0.longitude)] },
                  emptyText: "No frequent locations in the graph.")
            .card()

        SectionHeader("Most Photographed Addresses", subtitle: "Address nodes ranked by the number of moments linked to them", symbol: "building.2") { SensitivityBadge(.sensitive) }
        RankList(inf.addresses.map { RankList.Item(id: $0.id, name: $0.address, value: Double($0.moments), valueText: Format.count($0.moments), detail: coordinateText($0.latitude, $0.longitude)) },
                 tint: .red, sensitivity: .sensitive, limit: 10)
            .card()
    }

    private func infoValue(_ key: String) -> String {
        inf.info.first { $0.key == key }?.value ?? ""
    }
}

// MARK: People & groups

private struct GraphPeoplePage: View {
    let inf: GraphInferences
    @State private var expanded: Int32?

    var body: some View {
        InfoNote("Photos scores how you relate to each recognised person from signals such as shared trips, weekends, nights out, family holidays, matching family names and how often you are photographed together. The edge label is its conclusion; the confidence and the raw signals are stored on the edge.")

        SectionHeader("Inferred Relationships", subtitle: "Edges from the Me node to a person: the type, the confidence of the scored edge, and whether the graph adopted the relationship. Click a row for the stored signals.", symbol: "heart.text.square") { SensitivityBadge(.sensitive) }
        let showAdopted = Set(inf.relationships.map(\.adopted)).count > 1
        VStack(alignment: .leading, spacing: 0) {
            if inf.relationships.isEmpty {
                Text("No relationship edges in the graph.").font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(Array(inf.relationships.enumerated()), id: \.element.id) { index, rel in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: expanded == rel.id ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.tertiary).frame(width: 10)
                        Text(rel.person).font(.callout).lineLimit(1).sensitive(.sensitive).frame(minWidth: 160, maxWidth: 240, alignment: .leading)
                        TagLabel(rel.type, tint: tint(rel.type))
                        if showAdopted, rel.adopted { TagLabel("adopted", tint: .green).help("The graph also stores this relationship as an attribute-less edge in its relationship domain — the conclusion it acts on.") }
                        Spacer(minLength: 8)
                        if let c = rel.confidence {
                            ProgressView(value: min(max(c, 0), 1)).frame(width: 120)
                            Text(Format.percent(c, digits: 0)).font(.callout).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                        } else {
                            Text("listed without a score").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { expanded = expanded == rel.id ? nil : rel.id }
                    if expanded == rel.id {
                        if rel.signals.isEmpty {
                            Text("No signals stored on this edge.").font(.caption).foregroundStyle(.tertiary).padding(.leading, 20)
                        } else {
                            KeyValueGrid(rel.signals.map { KeyValueItem($0.key, $0.value) }, labelWidth: 260).padding(.leading, 20)
                        }
                    }
                }
                .padding(.vertical, 6)
                if index < inf.relationships.count - 1 { Divider().opacity(0.5) }
            }
        }
        .card()

        SectionHeader("People in the Graph", subtitle: "Person nodes with the moments they appear in, relationship tags and inferred attributes (raw codes)", symbol: "person.2") { SensitivityBadge(.sensitive) }
        // Ten columns need about 900 pt; a narrower page shows the six that carry the inference
        // and leaves out the group count, the raw sex / age codes and the birthday.
        ViewThatFits(in: .horizontal) {
            peopleTable(full: true).frame(idealWidth: 860)
            peopleTable(full: false).frame(idealWidth: 0)
        }
        .card()

        SectionHeader("Social Groups", subtitle: "Sets of people who repeatedly appear together, with each member’s importance within the group", symbol: "person.3") { SensitivityBadge(.sensitive) }
        AdaptiveColumns(minWidth: 300) {
            ForEach(Array(inf.groups.enumerated()), id: \.element.id) { index, group in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Group \(index + 1)").font(.subheadline.weight(.semibold))
                        if group.userVerified { TagLabel("verified", tint: .green) }
                        Spacer()
                        Text("\(Format.count(group.moments)) moments").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    ForEach(Array(group.members.enumerated()), id: \.offset) { i, member in
                        HStack {
                            Text(member).font(.callout).lineLimit(1).sensitive(.sensitive)
                            Spacer()
                            ProgressView(value: min(max(group.memberImportance[i], 0), 1)).frame(width: 70)
                        }
                    }
                    if let importance = group.importance {
                        Text("Group importance \(Format.number(importance))").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .card(padding: 12)
            }
        }
        if inf.groups.isEmpty {
            Text("No social groups in the graph.").font(.callout).foregroundStyle(.tertiary)
        }

        SectionHeader("Pets", subtitle: "Animals the graph tracks as individuals", symbol: "pawprint")
        MiniTable([.init("Name", sensitivity: .personal), .init("Species code", secondary: true), .init("Owner", sensitivity: .sensitive), .init("Moments", alignment: .trailing)],
                  rows: inf.pets.map { [$0.name, $0.speciesCode.map { "code \($0)" } ?? "", $0.owner, Format.count($0.moments)] }, emptyText: "No pets in the graph.")
            .card()
    }

    private func peopleTable(full: Bool) -> some View {
        var columns: [MiniTable.Column] = [
            .init("Person", sensitivity: .sensitive), .init("Moments", alignment: .trailing), .init("Assets", alignment: .trailing), .init("Relationship", sensitivity: .sensitive),
            .init("Tags", sensitivity: .sensitive), .init("Activities", sensitivity: .sensitive),
        ]
        if full {
            columns += [.init("Groups", alignment: .trailing), .init("Sex code", secondary: true), .init("Age code", secondary: true), .init("Birthday", sensitivity: .sensitive)]
        }
        let rows: [[String]] = inf.people.map { p in
            let name: String = p.name + (p.isMe ? " (Me)" : "") + (p.favorite ? " ♥" : "")
            var row: [String] = [name, Format.count(p.moments), Format.count(p.assets), p.relationships.joined(separator: ", "), p.tags.joined(separator: ", "), p.activities.joined(separator: ", ")]
            if full {
                row.append(p.groups > 0 ? String(p.groups) : "")
                row.append(p.sexCode.map { "code \($0)" } ?? "")
                row.append(p.ageCategory.map { "code \($0)" } ?? "")
                row.append(p.birthday.map { DossierDate.day($0) } ?? "")
            }
            return row
        }
        return MiniTable(columns, rows: rows, limit: 12)
    }

    private func tint(_ type: String) -> Color {
        switch type.lowercased() {
        case "partner": return .pink
        case "family": return .orange
        case "friend": return .blue
        case "coworker": return .teal
        default: return .purple
        }
    }
}

// MARK: Businesses & events

private struct GraphEventsPage: View {
    let inf: GraphInferences

    var body: some View {
        InfoNote("When a moment’s time and location match a known business or a public event (concert, match, festival), the graph links them. Business data comes from Apple Maps look-ups cached in the library; the visit itself is inferred from when and where your photos were taken.")

        SectionHeader("Public Events Attended", subtitle: "Moments matched to a public event, with performers and categories", symbol: "music.mic") { SensitivityBadge(.sensitive) }
        MiniTable([.init("Event", sensitivity: .sensitive), .init("Date", sensitivity: .personal), .init("Performers", sensitivity: .sensitive), .init("Categories"), .init("Venue", sensitivity: .sensitive)],
                  rows: inf.events.map { [$0.name, DossierDate.day($0.date), $0.performers.joined(separator: ", "), $0.categories.joined(separator: ", "), $0.venue] },
                  emptyText: "No public events in the graph.")
            .card()

        SectionHeader("Businesses Visited", subtitle: "\(inf.businesses.count) businesses linked to moments", symbol: "building.2") { SensitivityBadge(.sensitive) }
        let points = inf.businesses.compactMap { b -> MapPoint? in
            guard let lat = b.latitude, let lon = b.longitude else { return nil }
            return MapPoint(id: "b\(b.id)", latitude: lat, longitude: lon, title: "", weight: Double(max(b.visits, 1)))
        }
        if !points.isEmpty {
            let focus = MapFocus.densest(points)
            PointMapView(focus.points, maxMarkers: 80, tint: .orange).frame(height: 300)
            Text(focus.omitted > 0 ? "Map shows the area with the most visits (\(focus.points.count) businesses); \(focus.omitted) more elsewhere are in the table." : "Marker numbers are visit counts.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        MiniTable([.init("Business", sensitivity: .sensitive), .init("Categories"), .init("Visits", alignment: .trailing), .init("First", sensitivity: .personal), .init("Last", sensitivity: .personal), .init("Capacity", alignment: .trailing, secondary: true)],
                  rows: inf.businesses.map { [$0.name, $0.categories.prefix(3).joined(separator: ", "), Format.count($0.visits), DossierDate.day($0.first), DossierDate.day($0.last), $0.venueCapacity.map { Format.count($0) } ?? ""] },
                  limit: 20, emptyText: "No businesses in the graph.")
            .card()
    }
}

// MARK: Meanings & sensitive

private struct GraphMeaningsPage: View {
    let inf: GraphInferences

    var body: some View {
        InfoNote("A “meaning” is the graph’s guess at what a moment was: a birthday, a dinner, a hike, a concert. It combines scenes, time of day, people present and the kind of place. “Taboo” classes mark moments the system considers sensitive so that Memories avoids them.")

        AdaptiveColumns {
            TitledCard("Moment Meanings", subtitle: "Number of moments per inferred meaning", symbol: "sparkles") {
                RankList(inf.meanings, tint: .purple, limit: 12)
            }
            TitledCard("Sensitive (Taboo) Categories", subtitle: "Classes used to keep moments out of Memories. Moments, flagged assets and highest confidence.", symbol: "exclamationmark.shield") {
                MiniTable([.init("Class"), .init("Type code", secondary: true), .init("Moments", alignment: .trailing), .init("Assets", alignment: .trailing), .init("Max confidence", alignment: .trailing)],
                          rows: inf.taboo.map { [$0.name, $0.typeCode.map { "code \($0)" } ?? "", Format.count($0.moments), Format.count($0.assets), $0.maxConfidence.map { Format.percent($0, digits: 0) } ?? ""] },
                          emptyText: "No taboo classes in the graph.")
            }
            TitledCard("Person Activities", subtitle: "Activities recognised for people in moments", symbol: "figure.walk") {
                RankList(inf.activities, tint: .teal, limit: 10)
            }
            TitledCard("Holidays Celebrated", subtitle: "Moments linked to a holiday", symbol: "gift") {
                RankList(inf.holidays, tint: .red, sensitivity: .personal, limit: 10)
            }
            TitledCard("Kinds of Places", subtitle: "Points of interest matched to moments", symbol: "mappin.circle") {
                RankList(inf.pois, tint: .orange, limit: 10)
            }
            TitledCard("Kinds of Regions", subtitle: "Regions of interest (beach, mountain, urban …)", symbol: "mountain.2") {
                RankList(inf.rois, tint: .green, limit: 10)
            }
            TitledCard("How You Got Around", subtitle: "Mobility inferred for moments", symbol: "car") {
                RankList(inf.mobility, tint: .blue, limit: 6)
            }
            TitledCard("Memory Types Planned", subtitle: "Memory nodes the graph has prepared, by type", symbol: "sparkles.rectangle.stack") {
                RankList(inf.memoryTypes, tint: .yellow, limit: 10)
            }
        }

        SectionHeader("Scenes Across Moments", subtitle: "Scene labels ranked by the number of moments they were detected in (the per-asset classifier results are in Search Index)", symbol: "tag")
        RankList(inf.scenes, tint: .teal, limit: 15).card()
    }
}

// MARK: Structure

private struct GraphStructurePage: View {
    let inf: GraphInferences

    var body: some View {
        InfoNote("photosgraph.kgdb is an SQLite database. Nodes and edges carry labels stored as sparse bitmaps; each node belongs to one numeric domain plus one or more type labels. The domain names below are descriptive, derived from the type labels found in each domain.")

        AdaptiveColumns(minWidth: 420) {
            TitledCard("Node Domains", subtitle: "\(Format.count(inf.nodeCount)) nodes", symbol: "circle.hexagongrid") {
                MiniTable([.init("Domain", secondary: true), .init("Contents"), .init("Nodes", alignment: .trailing), .init("Type labels", secondary: true)],
                          rows: inf.domains.map { [String($0.code), $0.name, Format.count($0.nodes), $0.kinds] }, limit: 40)
            }
            TitledCard("Edge Labels", subtitle: "\(Format.count(inf.edgeCount)) edges", symbol: "arrow.triangle.branch") {
                RankList(inf.edgeLabels, tint: .indigo, limit: 24)
            }
        }

        SectionHeader("Graph Info Node", subtitle: "Library-wide counters and algorithm versions the graph keeps about itself", symbol: "info.circle")
        KeyValueGrid(inf.info.map { KeyValueItem($0.key, $0.value, sensitivity: $0.key.lowercased().contains("locale") || $0.key.lowercased().contains("language") ? .personal : .low) }, labelWidth: 330)
            .card()
    }
}
