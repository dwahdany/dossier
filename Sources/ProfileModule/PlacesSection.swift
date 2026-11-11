import SwiftUI
import DossierCore

/// (4) Places: location records of the interest profile on a map and in a table.
struct PlacesSection: View {
    @State private var origin = PlaceOrigin.all
    @State private var selected: PlaceRow?
    @State private var filter = ""
    @State private var showMap = true
    @Environment(\.deepLink) private var deepLink

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (origin, selected, filter, showMap)
        VStack(spacing: 0) {
            SectionStrip("Places macOS associates with you: locations of your photos (from the Photos knowledge graph), places saved in Maps guides or pinned, places you looked at in Maps, and addresses detected in mail. Coordinates are shown exactly as stored; nothing is geocoded online.") {
                Picker("", selection: $origin) {
                    ForEach(PlaceOrigin.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().fixedSize()
                Toggle(isOn: $showMap) { Image(systemName: "map") }
                    .toggleStyle(.button)
                    .help("Show or hide the map")
            }
            if showMap {
                HStack(spacing: 12) {
                AsyncContent(reloadKey: "\(origin.rawValue)|\(filter)") { [origin, filter] in
                    let rows = try await PortraitStore.places(offset: 0, limit: 20_000, sort: nil, search: filter, origin: origin, coordinatesOnly: true)
                    let points = rows.compactMap { row -> MapPoint? in
                        guard let lat = row.latitude, let lon = row.longitude else { return nil }
                        return MapPoint(id: String(row.id), latitude: lat, longitude: lon, title: row.name, weight: Double(row.records))
                    }
                    return MapCluster.make(from: points, limit: 160)
                } content: { clusters in
                    PointMapView(clusters: clusters, tint: .red, onSelect: { cluster in
                        if cluster.points.count == 1, let point = cluster.points.first { filter = point.title }
                    })
                }
                    .frame(minWidth: 260, idealWidth: 660, maxWidth: 660)
                    AsyncContent(load: { try await PortraitStore.placeOriginCounts() }) { counts in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Location Records by Origin").font(.headline)
                            BarChartView(counts.filter { $0.records > 0 }.map { ChartBar($0.origin.rawValue, Double($0.records)) }, tint: .red)
                            Spacer(minLength: 0)
                            Text("Photos contributes where your pictures were taken; Maps contributes places you saved, pinned or looked up.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .card()
                    }
                    .frame(minWidth: 220, maxWidth: .infinity)
                }
                .padding(12)
                // Shares the height with the table: full size in a tall window, down to
                // about half of it in the minimum window so several table rows stay visible.
                .frame(minHeight: 200, idealHeight: 364, maxHeight: 364)
                Divider()
            }
            PagedTable(
                columns: columns,
                searchPrompt: "Filter places",
                reloadKey: origin,
                exportName: "portrait-places",
                emptyTitle: "No Places",
                filter: $filter,
                fetch: { [origin] req in try await PortraitStore.places(offset: req.offset, limit: req.limit, sort: req.sort, search: req.search, origin: origin) },
                count: { [origin] req in try await PortraitStore.placeCount(search: req.search, origin: origin) },
                onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
            )
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { PlaceInspector(place: selected) { self.selected = nil } }
            }
            StoreFooter(ProfilePaths.portraitDB, note: "loc_records ⨝ sources")
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink, !link.payload.isEmpty else { return }
            origin = .all
            filter = link.payload
        }
    }

    private var columns: [PagedColumn<PlaceRow>] {
        [
            PagedColumn<PlaceRow>("Place", id: "name", width: 260, min: 150, sensitivity: .sensitive) { $0.name }
                .cell { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.hasCoordinate ? "mappin.circle.fill" : "envelope")
                            .foregroundStyle(row.hasCoordinate ? Color.red.opacity(0.8) : Color.secondary)
                            .imageScale(.small)
                        Text(row.name).font(.callout.weight(.medium)).lineLimit(1)
                    }
                },
            PagedColumn("Origin", id: "origin", width: 190, min: 130, sortable: false) { $0.origin },
            PagedColumn("City", id: "locality", width: 130, min: 80, sensitivity: .sensitive) { $0.locality },
            PagedColumn("Country", id: "country", width: 110, min: 110, sensitivity: .personal) { $0.country },
            PagedColumn("Records", id: "records", width: 70, min: 70, alignment: .trailing) { Format.count($0.records) },
            PagedColumn("Score", id: "score", width: 70, min: 70, alignment: .trailing) { ProfileFormat.score($0.score) },
            PagedColumn("Category", id: "category", width: 120, min: 120, secondary: true, hiddenByDefault: true) { PortraitLabels.locationCategory($0.category) },
            PagedColumn("Found By", id: "algorithm", width: 140, min: 80, secondary: true) { PortraitLabels.locationAlgorithm($0.algorithm) },
            PagedColumn("Coordinates", id: "coordinates", width: 160, min: 100, sortable: false, sensitivity: .sensitive, monospaced: true, secondary: true) { ProfileFormat.coordinate($0.latitude, $0.longitude) },
            PagedColumn("Last Seen", id: "last", width: 150, min: 146) { DossierDate.sortable($0.last) },
        ]
    }
}

private struct PlaceInspector: View {
    let place: PlaceRow
    let onClose: () -> Void

    var body: some View {
        InspectorPage(title: place.name, subtitle: place.origin, sensitivity: .sensitive, onClose: onClose) {
            if let lat = place.latitude, let lon = place.longitude {
                PointMapView([MapPoint(id: String(place.id), latitude: lat, longitude: lon, title: place.name)], maxMarkers: 1, tint: .red)
                    .frame(height: 170)
            }
            KeyValueGrid([
                KeyValueItem("Origin", place.origin),
                KeyValueItem("Category", PortraitLabels.locationCategory(place.category)),
                KeyValueItem("Found by", PortraitLabels.locationAlgorithm(place.algorithm)),
                KeyValueItem("Records", Format.count(place.records)),
                KeyValueItem("Σ initial score", ProfileFormat.score(place.score)),
                KeyValueItem("Coordinates", ProfileFormat.coordinate(place.latitude, place.longitude), sensitivity: .sensitive, monospaced: true),
                KeyValueItem("Last seen", DossierDate.medium(place.last)),
                KeyValueItem("Description", place.key, sensitivity: .sensitive),
            ])
            AsyncContent(reloadKey: place.id) {
                try await PortraitStore.placeDetail(place)
            } content: { detail in
                VStack(alignment: .leading, spacing: 16) {
                    if !detail.fields.isEmpty {
                        InspectorGroupTitle("Address (as stored)")
                        KeyValueGrid(detail.fields.map { KeyValueItem($0.0, $0.1, sensitivity: .sensitive) })
                    }
                    if !detail.areasOfInterest.isEmpty {
                        InspectorGroupTitle("Areas of interest")
                        Text(detail.areasOfInterest.joined(separator: ", ")).font(.callout).textSelection(.enabled).sensitive(.sensitive)
                    }
                    if !detail.contextualEntities.isEmpty {
                        InspectorGroupTitle("Entities mentioned with this place")
                        Text(detail.contextualEntities.joined(separator: ", ")).font(.callout).textSelection(.enabled).sensitive(.sensitive)
                    }
                    InspectorGroupTitle("Contributing documents")
                    DocumentList(documents: detail.documents, showsAlgorithm: PortraitLabels.locationAlgorithm, limitNote: 100)
                }
            }
            .frame(minHeight: 80)
        }
    }
}
