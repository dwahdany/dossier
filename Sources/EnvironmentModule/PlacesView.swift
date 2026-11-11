import SwiftUI
import DossierCore

/// Section 1 — every place the stores hold: coordinates on a map, address-only places in
/// the table, with source filters.
struct PlacesView: View {
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @State private var hidden: Set<PlaceKind> = []
    @State private var markerIDs: Set<String>?
    @State private var selected: Place?
    @State private var filter = ""

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (hidden, markerIDs, selected, filter)
        let token = refreshToken
        AsyncContent(reloadKey: token) {
            try await PlacesLoader.load(token: token)
        } content: { data in
            content(data)
        }
        .task(id: deepLink?.nonce) {
            guard let link = deepLink, !link.payload.isEmpty else { return }
            guard let data = try? await PlacesLoader.load(token: token), let place = data.places.first(where: { $0.id == link.payload }) else { return }
            hidden = []
            markerIDs = nil
            filter = place.title
            selected = place
        }
    }

    private func content(_ data: PlacesData) -> some View {
        let visible = data.places.filter { !hidden.contains($0.kind) }
        let rows = markerIDs.map { ids in visible.filter { ids.contains($0.id) } } ?? visible
        let points = visible.compactMap { place -> MapPoint? in
            guard let lat = place.latitude, let lon = place.longitude else { return nil }
            return MapPoint(id: place.id, latitude: lat, longitude: lon, title: place.title, weight: 1, radius: place.radius)
        }
        let chips = PlaceKind.allCases.filter { (data.counts[$0] ?? 0) > 0 }.map {
            Chip(id: $0.rawValue, title: $0.rawValue, symbol: $0.symbol, count: data.counts[$0])
        }
        return VStack(spacing: 0) {
            // The inspector sits beside header, map and table; the status bars below keep
            // the full width.
            VStack(spacing: 0) {
            let chipBar = ChipBar(chips: chips, isOn: { id in !hidden.contains { $0.rawValue == id } }, toggle: { id in
                guard let kind = PlaceKind(rawValue: id) else { return }
                if hidden.contains(kind) { hidden.remove(kind) } else { hidden.insert(kind) }
                markerIDs = nil
            })
            let mapped = Text("\(points.count) of \(visible.count) on the map")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
                .help("Only places stored with a coordinate can be drawn. Address-only places are listed in the table.")
            // All chips and the count on one line where they fit; otherwise the chips wrap
            // onto a second line instead of being cut off at the edge.
            ViewThatFits(in: .horizontal) {
                HeaderStrip { HStack(spacing: 12) { chipBar; Spacer(minLength: 0); mapped } }
                VStack(alignment: .leading, spacing: 4) {
                    ChipBar(chips: chips, wraps: true, isOn: chipBar.isOn, toggle: chipBar.toggle)
                    mapped
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            }
            if data.places.isEmpty {
                StatePlaceholder(title: "No Places Stored", symbol: "mappin.slash", message: "None of the location-bearing stores hold a place on this Mac.")
                    .frame(maxHeight: .infinity)
            } else {
                PointMapView(points, maxMarkers: 150, tint: .red, onSelect: { cluster in
                    markerIDs = Set(cluster.points.map(\.id))
                    selected = cluster.points.count == 1 ? data.places.first { $0.id == cluster.points[0].id } : nil
                })
                .frame(minHeight: 150, idealHeight: 330, maxHeight: 380)
                .padding(12)
                .background(Color(nsColor: .windowBackgroundColor))
                Divider()
                if let markerIDs {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.and.ellipse").foregroundStyle(.red)
                        Text("Showing \(markerIDs.count) place\(markerIDs.count == 1 ? "" : "s") at the selected marker").font(.callout)
                        Spacer()
                        Button("Show All") { self.markerIDs = nil }.controlSize(.small)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.08))
                    Divider()
                }
                PagedTable(
                    rows: rows,
                    columns: [
                        PagedColumn<Place>("Place", id: "title", width: 230, sensitivity: .sensitive) { $0.title },
                        PagedColumn("Source", id: "kind", width: 190) { $0.kind.rawValue }.cell { place in
                            Label(place.kind.rawValue, systemImage: place.kind.symbol).lineLimit(1)
                        },
                        PagedColumn("Address", id: "address", width: 280, sensitivity: .sensitive) { $0.address.isEmpty ? "—" : $0.address },
                        PagedColumn("Coordinate", id: "coord", width: 150, sensitivity: .sensitive, monospaced: true) { $0.coordinateText },
                        PagedColumn("Label", id: "label", width: 130, sensitivity: .personal) { $0.label },
                        PagedColumn("Last Used", id: "date", width: 145) { DossierDate.sortable($0.date) },
                        PagedColumn("Uses", id: "uses", width: 50, alignment: .trailing) { String($0.uses) },
                        PagedColumn("Radius", id: "radius", width: 70, alignment: .trailing, hiddenByDefault: true) { $0.radius.map { "\(Int($0)) m" } ?? "" },
                        PagedColumn("Added By", id: "origin", width: 180, monospaced: true, secondary: true, hiddenByDefault: true) { $0.origin },
                    ].readableMinimums(),
                    searchPrompt: "Filter places",
                    reloadKey: AnyHashable([AnyHashable(hidden), AnyHashable(markerIDs ?? []), AnyHashable(refreshToken), AnyHashable(data.places.count)]),
                    exportName: "places",
                    emptyTitle: "No Matching Places",
                    filter: $filter,
                    onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
                )
                .frame(minHeight: 160)
            }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { PlaceInspector(place: selected) { self.selected = nil } }
            }
            LocationStreamsBar(streams: data.streams)
            StoreFooter(EnvPaths.kvsDirectory ?? Paths.biomeRestrictedStreams, note: "iCloud key-value cache · Biome · knowledgeC · Focus cache · milod")
        }
    }
}

/// Explicit status of the Biome location streams — on a Mac most of them stay empty.
private struct LocationStreamsBar: View {
    let streams: [StreamStatus]

    var body: some View {
        let empty = streams.filter { $0.records == 0 }
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "location.slash").foregroundStyle(.secondary).imageScale(.small)
                Text(empty.count == streams.count ? "Biome location streams hold no records on this Mac:" : "Biome location streams:")
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(streams) { stream in
                            TagLabel(stream.records > 0 ? "\(stream.name) · \(Format.count(stream.records))" : stream.name + (stream.exists ? " · empty" : " · absent"),
                                     tint: stream.records > 0 ? .green : .secondary)
                                .help(stream.note)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(.bar)
        }
    }
}

private struct PlaceInspector: View {
    let place: Place
    let onClose: () -> Void

    var body: some View {
        InspectorPage(title: place.title, subtitle: place.kind.rawValue, sensitivity: .sensitive, onClose: onClose) {
            if place.hasCoordinate, let lat = place.latitude, let lon = place.longitude {
                PointMapView([MapPoint(id: place.id, latitude: lat, longitude: lon, title: place.title, radius: place.radius)], tint: .red)
                    .frame(height: 170)
            }
            KeyValueGrid([
                KeyValueItem("Address", place.address.isEmpty ? "—" : place.address, sensitivity: .sensitive),
                KeyValueItem("Coordinate", place.hasCoordinate ? place.coordinateText : "Not stored — address only", sensitivity: .sensitive, monospaced: place.hasCoordinate),
                KeyValueItem("Radius", place.radius.map { "\(Int($0)) m" }),
                KeyValueItem("Label", place.label.isEmpty ? nil : place.label, sensitivity: .personal),
                KeyValueItem("Last used", DossierDate.medium(place.date)),
                KeyValueItem("Store", place.store),
            ].filter { $0.value != "—" || $0.label == "Address" })
            Explainer(place.kind.explanation)
            if !place.details.isEmpty {
                InspectorGroupTitle("Details")
                KeyValueGrid(place.details.items(sensitivity: .sensitive))
            }
            if place.ref != .none {
                InspectorGroupTitle("Raw Record")
                RawRecordView(ref: place.ref, title: place.kind.rawValue)
            }
        }
    }
}
