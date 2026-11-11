import SwiftUI
import Charts
import MapKit
import DossierCore

/// (4) Places: heat / cluster map of asset coordinates (aggregated in SQL into grid cells),
/// places by level from the search index, the trips Photos detected, and — on a second tab —
/// the postal address and "at home" flag stored with every photo.
struct PlacesSection: View {
    enum Tab: String, CaseIterable, Identifiable {
        case map = "Map & Trips", addresses = "Address per Photo"
        var id: String { rawValue }
    }

    enum Level: String, CaseIterable, Identifiable {
        case country = "Countries", state = "States", city = "Cities", neighbourhood = "Neighbourhoods", street = "Streets"
        var id: String { rawValue }
        func code(_ backend: SearchBackend) -> Int {
            switch self {
            case .country: return backend.countryCode
            case .state: return backend.stateCode
            case .city: return backend.cityCode
            case .neighbourhood: return backend.neighbourhoodCode
            case .street: return backend.streetCode
            }
        }
    }

    @ObservedObject private var selection = PhotosLibrarySelection.shared
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @State private var tab: Tab = .map
    @State private var homeOnly = false
    @State private var addressFilter = ""
    @State private var level: Level = .country
    @State private var selectedCluster: MapCluster?
    /// nil = the busiest area (default), -1 = the whole world, otherwise an area id.
    @State private var areaID: Int?

    /// A contiguous part of the world with photos, so the map can open on something legible
    /// instead of a planet-wide view when the library spans continents.
    struct MapArea: Sendable, Identifiable, Hashable {
        let id: Int
        let name: String
        let count: Int
        let clusters: [MapCluster]
    }

    /// Greedy grouping of grid cells: a cell joins the nearest existing area within roughly
    /// 800 km, otherwise it starts a new one. Areas are named after the countries the
    /// PhotosGraph files its addresses under (no geocoding, nothing leaves the Mac).
    static func areas(from cells: [PhotosStore.GridCell], geo: [GeoName]) -> [MapArea] {
        struct Building {
            var lat: Double, lon: Double, weight: Double
            var cells: [PhotosStore.GridCell]
        }
        var building: [Building] = []
        for cell in cells.sorted(by: { $0.count > $1.count }) {
            var best: (index: Int, distance: Double)?
            for (i, area) in building.enumerated() {
                let dLat = abs(area.lat - cell.latitude)
                let dLon = abs(area.lon - cell.longitude) * cos(cell.latitude * .pi / 180)
                let d = (dLat * dLat + dLon * dLon).squareRoot()
                if d < 7.5, d < (best?.distance ?? .infinity) { best = (i, d) }
            }
            let w = Double(cell.count)
            if let best {
                var area = building[best.index]
                area.lat = (area.lat * area.weight + cell.latitude * w) / (area.weight + w)
                area.lon = (area.lon * area.weight + cell.longitude * w) / (area.weight + w)
                area.weight += w
                area.cells.append(cell)
                building[best.index] = area
            } else {
                building.append(Building(lat: cell.latitude, lon: cell.longitude, weight: w, cells: [cell]))
            }
        }
        return building.sorted { $0.weight > $1.weight }.enumerated().map { index, area in
            let lats = area.cells.map(\.latitude), lons = area.cells.map(\.longitude)
            let box = (lats.min()! - 0.3, lats.max()! + 0.3, lons.min()! - 0.3, lons.max()! + 0.3)
            var countries: [String: Int] = [:]
            for g in geo where g.latitude >= box.0 && g.latitude <= box.1 && g.longitude >= box.2 && g.longitude <= box.3 && !g.country.isEmpty {
                countries[g.country, default: 0] += 1
            }
            let top = countries.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(2).map(\.key)
            let fallback = String(format: "%.0f°%@ %.0f°%@", abs(area.lat), area.lat >= 0 ? "N" : "S", abs(area.lon), area.lon >= 0 ? "E" : "W")
            let name = top.isEmpty ? "Around \(fallback)" : top.joined(separator: " & ") + (countries.count > 2 ? " +\(countries.count - 2)" : "")
            let points = area.cells.map { MapPoint(id: "\($0.latitude),\($0.longitude)", latitude: $0.latitude, longitude: $0.longitude, weight: Double($0.count)) }
            return MapArea(id: index, name: name, count: Int(area.weight), clusters: MapCluster.make(from: points, limit: 160))
        }
    }

    private struct Loaded: Sendable {
        let library: PhotosLibrary
        let areas: [MapArea]
        let clusters: [MapCluster]
        let cells: Int
        let located: Int
        let total: Int
        let trips: [PhotosStore.Trip]
        let backend: SearchBackend?
        let countries: Int
        let cities: Int
        let bounds: String
    }

    var body: some View {
        // Deep links may set this state before a content closure has read it (ARCHITECTURE.md §6).
        let _ = (tab, homeOnly, addressFilter)
        VStack(spacing: 0) {
            SectionStrip {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .layoutPriority(1)
                StripCaption(tab == .map ? "Where your photos were taken, and the trips Photos derived from them" : "The address Photos resolved for each photo, and the photos it considers taken at home")
            } trailing: {
                LibraryMenu()
            }
            switch tab {
            case .map:
                content.requiresLibrary(selection.current)
            case .addresses:
                if let lib = selection.current {
                    AddressesPane(library: lib, homeOnly: $homeOnly, filterText: $addressFilter)
                } else {
                    StatePlaceholder.missing("No Photos library was found in ~/Pictures. Use the library menu to choose one.")
                }
            }
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            // "tab:addresses" opens the per-photo addresses, "home" additionally limits them to the at-home photos.
            guard let link = deepLink, !link.payload.isEmpty else { return }
            switch link.payload {
            case "home": tab = .addresses; homeOnly = true
            case "tab:addresses": tab = .addresses
            case "tab:map": tab = .map
            default:
                // "address:<text>" filters the per-photo addresses.
                if link.payload.hasPrefix("address:") { tab = .addresses; addressFilter = String(link.payload.dropFirst(8)) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let lib = selection.current
        let token = refreshToken
        AsyncContent(reloadKey: lib?.id ?? "") {
            guard let lib else { throw PhotosError.noLibrary() }
            await PhotosCaches.shared.sync(token: token)
            let cells = try await PhotosStore.locationGrid(lib)
            let points = cells.map { MapPoint(id: "\($0.latitude),\($0.longitude)", latitude: $0.latitude, longitude: $0.longitude, weight: Double($0.count)) }
            let clusters = MapCluster.make(from: points, limit: 160)
            let geo = (try? await PhotosCaches.shared.graph(for: lib).1.geo) ?? []
            let areas = Self.areas(from: cells, geo: geo)
            let trips = (try? await PhotosStore.trips(lib)) ?? []
            let backend = await SearchIndexStore.preferredBackend(lib)
            var countries = 0, cities = 0
            if let backend, let stats = try? await SearchIndexStore.stats(lib, backend: backend) {
                countries = stats.categories.first { $0.code == backend.countryCode }?.terms ?? 0
                cities = stats.categories.first { $0.code == backend.cityCode }?.terms ?? 0
            }
            let db = try await lib.photos()
            let total = await db.rowCount(of: "ZASSET") ?? 0
            var bounds = ""
            if let latMin = cells.map(\.latitude).min(), let latMax = cells.map(\.latitude).max(), let lonMin = cells.map(\.longitude).min(), let lonMax = cells.map(\.longitude).max() {
                bounds = String(format: "%.1f° to %.1f° lat · %.1f° to %.1f° lon", latMin, latMax, lonMin, lonMax)
            }
            return Loaded(library: lib, areas: areas, clusters: clusters, cells: cells.count, located: cells.reduce(0) { $0 + $1.count }, total: total, trips: trips,
                          backend: backend, countries: countries, cities: cities, bounds: bounds)
        } content: { loaded in
            VStack(spacing: 0) {
                ScrollPage { page(loaded) }
                StoreFooter(loaded.library.photosDB, note: "ZASSET (ZLATITUDE, ZLONGITUDE), ZPHOTOSHIGHLIGHT, search lexicon")
            }
        }
    }

    @ViewBuilder
    private func page(_ loaded: Loaded) -> some View {
        StatTileRow([
            Stat("Located Assets", Format.compact(loaded.located), caption: loaded.total > 0 ? Format.percent(Double(loaded.located) / Double(loaded.total), digits: 0) + " of the library" : nil, symbol: "mappin.and.ellipse", tint: .red),
            Stat("Map Cells", Format.count(loaded.cells), caption: "≈ 2 km grid squares visited", symbol: "square.grid.3x3", tint: .orange),
            Stat("Countries", Format.count(loaded.countries), caption: "in the search index", symbol: "globe.europe.africa", tint: .blue, sensitivity: .personal),
            Stat("Cities", Format.count(loaded.cities), caption: "in the search index", symbol: "building.2", tint: .indigo, sensitivity: .personal),
            Stat("Trips", Format.count(loaded.trips.count), caption: "\(loaded.trips.filter { $0.typeCode == 1 }.count) long · \(loaded.trips.filter { $0.typeCode == 2 }.count) short", symbol: "airplane", tint: .teal),
        ])

        let area = areaID == -1 ? nil : (loaded.areas.first { $0.id == areaID } ?? loaded.areas.first)
        SectionHeader("Where Photos Were Taken", subtitle: "Asset coordinates grouped into ≈ 2 km cells in SQL, then clustered for display. Marker size and number show how many assets fall there.", symbol: "map") {
            HStack(spacing: 10) {
                SensitivityBadge(.sensitive).fixedSize()
                Picker("Area", selection: Binding(get: { area?.id ?? -1 }, set: { areaID = $0; selectedCluster = nil })) {
                    ForEach(loaded.areas.prefix(24)) { a in
                        Text("\(a.name) · \(Format.compact(a.count))").tag(a.id)
                    }
                    Divider()
                    Text("Whole World · \(Format.compact(loaded.located))").tag(-1)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .sensitive(.sensitive)
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            PointMapView(clusters: area?.clusters ?? loaded.clusters, tint: .red, onSelect: { cluster in selectedCluster = cluster })
                .id(area?.id ?? -1)
                .frame(height: 420)
            HStack {
                if let c = selectedCluster {
                    Text("\(Format.count(Int(c.weight))) assets in \(c.points.count) cell\(c.points.count == 1 ? "" : "s") around \(String(format: "%.3f, %.3f", c.latitude, c.longitude))")
                        .font(.caption).foregroundStyle(.secondary).sensitive(.sensitive)
                } else {
                    Text("\(loaded.areas.count) separate area\(loaded.areas.count == 1 ? "" : "s") with photos. Click a marker for its asset count. Overall extent: \(loaded.bounds)").font(.caption).foregroundStyle(.tertiary).sensitive(.sensitive)
                }
                Spacer()
            }
        }
        .card()

        SectionHeader("Places by Level", subtitle: "Reverse-geocoded place names as indexed for search, with the number of assets tagged", symbol: "list.number") {
            FittingSegmentedPicker(label: "Level", options: Level.allCases.map { .init(value: $0, title: $0.rawValue) }, selection: $level)
        }
        placeList(loaded)

        SectionHeader("Trips", subtitle: "Day-group highlights: runs of days away from your frequent locations. Long and short trips match the trip nodes of the PhotosGraph.", symbol: "airplane")
        if loaded.trips.isEmpty {
            StatePlaceholder(title: "No Trips", symbol: "airplane", message: "Photos has not grouped any days into a trip in this library.").frame(height: 160).card()
        } else {
            TripTimeline(trips: loaded.trips).card()
            MiniTable([.init("Where", sensitivity: .sensitive), .init("Generated title", sensitivity: .personal), .init("Type"), .init("Start", sensitivity: .personal), .init("Length", alignment: .trailing), .init("Days with photos", alignment: .trailing), .init("Assets", alignment: .trailing)],
                      rows: loaded.trips.map { [$0.subtitle.isEmpty ? "Not titled yet" : $0.subtitle, $0.title, $0.type, DossierDate.day($0.start), String(format: "%.0f d", $0.duration.rounded(.up)), Format.count($0.days), Format.count($0.assets)] },
                      limit: 14)
                .card()
        }
    }

    @ViewBuilder
    private func placeList(_ loaded: Loaded) -> some View {
        if let backend = loaded.backend {
            let lib = loaded.library
            let level = level
            AsyncContent(reloadKey: "\(lib.id)|\(level.rawValue)") {
                try await SearchIndexStore.topTerms(lib, backend: backend, category: level.code(backend), limit: 40)
            } content: { places in
                RankList(places, tint: .red, sensitivity: .sensitive, limit: 12).card()
            }
            .frame(minHeight: 120)
        } else {
            StatePlaceholder.missing("No search index was found in this library, so place names are not available.").frame(height: 140).card()
        }
    }
}

/// Timeline of trips: one lane per trip type.
private struct TripTimeline: View {
    let trips: [PhotosStore.Trip]

    var body: some View {
        Chart(trips) { trip in
            BarMark(xStart: .value("Start", trip.start), xEnd: .value("End", max(trip.end, trip.start.addingTimeInterval(86_400 * 2))), y: .value("Type", trip.type), height: .fixed(16))
                .foregroundStyle(by: .value("Type", trip.type))
                .cornerRadius(3)
        }
        .chartForegroundStyleScale(range: [ChartPalette.color(0), ChartPalette.color(1), ChartPalette.color(2), ChartPalette.color(3)])
        .chartLegend(.hidden)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 8)) { _ in
            AxisGridLine().foregroundStyle(.quaternary)
            AxisValueLabel(format: .dateTime.month(.abbreviated).year())
        } }
        .frame(height: CGFloat(54 + 34 * Set(trips.map(\.type)).count))
        .sensitive(.personal)
    }
}
