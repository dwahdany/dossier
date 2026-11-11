import Foundation
import DossierCore

enum PlaceKind: String, CaseIterable, Sendable, Identifiable {
    case recents = "Calendar & Reminder Places"
    case geofence = "Shortcut Geofences"
    case focus = "Focus Triggers"
    case maps = "Maps Destinations"
    case wallet = "Wallet Addresses"
    case activity = "App Activity Locations"
    case micro = "Microlocation Labels"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .recents: return "calendar"
        case .geofence: return "location.circle"
        case .focus: return "moon"
        case .maps: return "map"
        case .wallet: return "wallet.pass"
        case .activity: return "app.badge"
        case .micro: return "dot.radiowaves.left.and.right"
        }
    }

    var explanation: String {
        switch self {
        case .recents: return "Locations you attached to calendar events and reminders (or tapped in detected addresses), kept as “recent locations” and synced through iCloud key-value storage."
        case .geofence: return "Circular regions apps donated with a relevant shortcut, so the system can surface a widget or suggestion when you arrive."
        case .focus: return "Geofences that switch a Focus on when you arrive and off when you leave."
        case .maps: return "Places looked up or navigated to in Maps on your devices, synced through CoreDuet. Only the address is stored, not a coordinate."
        case .wallet: return "Postal addresses used with Wallet and Apple Pay, synced through iCloud key-value storage."
        case .activity: return "Locations attached to app activities donated to CoreDuet."
        case .micro: return "Semantic place labels the microlocation daemon learned from Wi-Fi fingerprints. A label, not a coordinate."
        }
    }
}

struct Place: Identifiable, Sendable {
    let id: String
    let title: String
    let kind: PlaceKind
    let address: String
    let latitude: Double?
    let longitude: Double?
    let radius: Double?
    /// Most recent time the store associates with the place.
    let date: Date?
    let uses: Int
    /// Semantic label the store itself gives the place ("home", a Focus name, …).
    let label: String
    let origin: String
    let store: String
    let details: [KV]
    let ref: RawRef

    var hasCoordinate: Bool { latitude != nil && longitude != nil }
    var coordinateText: String {
        guard let latitude, let longitude else { return "—" }
        return EnvFormat.coordinate(latitude, longitude)
    }
}

/// A location stream that exists but may hold nothing.
struct StreamStatus: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let exists: Bool
    let records: Int
    let range: ClosedRange<Date>?
    let note: String
}

struct PlacesData: Sendable {
    var places: [Place] = []
    var streams: [StreamStatus] = []
    var counts: [PlaceKind: Int] = [:]
    var withCoordinates: Int { places.filter(\.hasCoordinate).count }
}

enum PlacesLoader {
    static let locationStreams: [(name: String, note: String)] = [
        ("Location.Semantic", "Arrivals at and departures from Home / Work / School / Gym"),
        ("Location.HashedCoordinates", "Coarse, hashed location samples for on-device learning"),
        ("Location.MicroLocationVisit", "Room-level visits recognised from Wi-Fi fingerprints"),
        ("Location.PointOfInterest.Category", "Category of the point of interest you are at"),
        ("FindMy.LocationChange", "Location changes of Find My items and people"),
        ("Device.Wireless.NFCTag", "NFC tags scanned"),
    ]

    static func load(token: Int) async throws -> PlacesData {
        await EnvCache.shared.sync(token: token)
        return try await EnvCache.shared.value("places") { await build() }
    }

    static func streamStatuses() -> [StreamStatus] {
        locationStreams.map { item in
            let stats = EnvBiome.stats(item.name)
            return StreamStatus(name: item.name, exists: stats.available, records: stats.records, range: stats.range, note: item.note)
        }
    }

    private static func build() async -> PlacesData {
        var data = PlacesData()
        var places: [Place] = []
        places += await recents()
        places += await wallet()
        places += geofences()
        places += focusTriggers()
        places += await mapsDestinations()
        places += await activityLocations()
        places += await microLabels()
        // What the map shows comes first: places stored with a coordinate, then the
        // address-only ones; most recently used first within each.
        places.sort {
            if $0.hasCoordinate != $1.hasCoordinate { return $0.hasCoordinate }
            return ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
        }
        data.places = places
        for p in places { data.counts[p.kind, default: 0] += 1 }
        data.streams = streamStatuses()
        return data
    }

    // kvs com.apple.eventkit.locations — keys "MR_<hash>": { n name, a address, S source
    // bundle, t [use dates], m { latitude, longitude, hAccuracy, mapKitHandle … } }.
    static func recents() async -> [Place] {
        var out: [Place] = []
        for entry in await KVSSource.entries(store: "com.apple.eventkit.locations") {
            guard entry.key.hasPrefix("MR_"), let value = entry.value else { continue }
            let meta = value["m"]
            let dates = value["t"]?.array?.compactMap(\.date) ?? []
            let name = value["n"]?.string ?? ""
            let address = (value["a"]?.string ?? "").replacingOccurrences(of: "\n", with: ", ")
            let source = value["S"]?.string ?? ""
            var details = [KV("Added by", source), KV("Times used", String(max(dates.count, 1)))]
            for d in dates.sorted(by: >).prefix(8) { details.append(KV("Used", DossierDate.medium(d))) }
            if let acc = meta?["hAccuracy"]?.double, acc > 0 { details.append(KV("Accuracy", "\(Int(acc)) m")) }
            if let handle = meta?["mapKitHandle"]?.data { details.append(KV("Maps place handle", Format.bytes(handle.count))) }
            out.append(Place(
                id: "ek|" + entry.database + "|\(entry.pk)", title: name.isEmpty ? (address.isEmpty ? "Unnamed place" : address) : name,
                kind: .recents, address: address, latitude: meta?["latitude"]?.double, longitude: meta?["longitude"]?.double, radius: nil,
                date: dates.max() ?? entry.modified, uses: max(dates.count, 1), label: "", origin: source,
                store: "iCloud key-value store · com.apple.eventkit.locations", details: details, ref: entry.ref))
        }
        return out
    }

    // kvs com.apple.passbook.locations — same envelope; `m.postalAddress` holds a postal
    // address. Entries that are plain e-mail / phone contacts are skipped (not places).
    static func wallet() async -> [Place] {
        var out: [Place] = []
        for entry in await KVSSource.entries(store: "com.apple.passbook.locations") {
            guard entry.key.hasPrefix("MR_"), let value = entry.value, let meta = value["m"] else { continue }
            let postal = meta["postalAddress"]
            let lat = meta["latitude"]?.double, lon = meta["longitude"]?.double
            guard postal != nil || lat != nil else { continue }
            let dates = value["t"]?.array?.compactMap(\.date) ?? []
            func part(_ keys: String...) -> String? { keys.compactMap { postal?[$0]?.string?.nilIfEmpty }.first }
            let street = part("Street", "street")?.replacingOccurrences(of: "\n", with: ", ")
            let city = [part("ZIP", "postalCode"), part("City", "city")].compactMap { $0 }.joined(separator: " ")
            let address = [street, city.nilIfEmpty, part("Country", "country")].compactMap { $0 }.joined(separator: ", ")
            let person = [meta["givenName"]?.string, meta["familyName"]?.string].compactMap { $0?.nilIfEmpty }.joined(separator: " ")
            var details = [KV("Added by", value["S"]?.string ?? ""), KV("Times used", String(max(dates.count, 1)))]
            if !person.isEmpty { details.append(KV("Name on address", person)) }
            out.append(Place(
                id: "pk|" + entry.database + "|\(entry.pk)", title: street ?? (address.isEmpty ? "Postal address" : address), kind: .wallet,
                address: address, latitude: lat, longitude: lon, radius: nil, date: dates.max() ?? entry.modified,
                uses: max(dates.count, 1), label: person.isEmpty ? "" : "Billing / shipping address", origin: value["S"]?.string ?? "",
                store: "iCloud key-value store · com.apple.passbook.locations", details: details, ref: entry.ref))
        }
        return out
    }

    // App.RelevantShortcuts — 1 bundle id, 3 NSKeyedArchiver INRelevantShortcut whose
    // relevance providers may include INLocationRelevanceProvider { region: CLCircularRegion }.
    static func geofences() -> [Place] {
        var out: [Place] = []
        var seen = Set<String>()
        EnvBiome.forEach("App.RelevantShortcuts") { record, msg in
            guard let blob = msg[3]?.data, let archive = KeyedArchive(blob) else { return }
            let bundle = msg[1]?.string ?? ""
            let widget = archive.string(archive.deref(archive.root)?["widgetKind"])
            for (i, object) in archive.objects.enumerated() {
                guard let region = archive.circularRegion(object) else { continue }
                let key = "\(bundle)|\(region.latitude)|\(region.longitude)|\(region.radius)"
                guard seen.insert(key).inserted else { continue }
                var details = [KV("Donated by", bundle)]
                if region.radius > 0 { details.append(KV("Radius", "\(Int(region.radius)) m")) }
                if let widget { details.append(KV("Widget", widget)) }
                if let id = region.identifier { details.append(KV("Region identifier", id)) }
                if let entry = object["kCLRegionCodingKeyNotifyOnEntry"]?.bool { details.append(KV("Notify on entry", entry ? "yes" : "no")) }
                if let exit = object["kCLRegionCodingKeyNotifyOnExit"]?.bool { details.append(KV("Notify on exit", exit ? "yes" : "no")) }
                out.append(Place(
                    id: "geo|\(record.id)|\(i)", title: "Geofence · " + EnvFormat.appName(bundle), kind: .geofence, address: "",
                    latitude: region.latitude, longitude: region.longitude, radius: region.radius > 0 ? region.radius : nil, date: record.timestamp, uses: 1,
                    label: "", origin: bundle, store: "Biome · App.RelevantShortcuts", details: details, ref: EnvBiome.ref(record)))
            }
        }
        return out
    }

    static func focusTriggers() -> [Place] {
        var out: [Place] = []
        for mode in FocusLoader.modes().modes {
            for trigger in mode.triggers {
                guard let lat = trigger.latitude, let lon = trigger.longitude else { continue }
                out.append(Place(
                    id: "focus|" + trigger.id, title: trigger.regionName ?? mode.name, kind: .focus, address: "",
                    latitude: lat, longitude: lon, radius: trigger.radius, date: mode.modified, uses: 1,
                    label: "\(mode.name) Focus", origin: "Focus", store: "DuetExpertCenter · DNDModeConfigurationsCache",
                    details: [KV("Focus", mode.name), KV("Trigger", trigger.stateLabel), KV("Radius", "\(Int(trigger.radius ?? 0)) m")], ref: .none))
            }
        }
        return out
    }

    static func mapsDestinations() async -> [Place] {
        struct Group { var intent: MapsIntent; var count: Int; var first: Date; var elements: Set<String> }
        var groups: [String: Group] = [:]
        var order: [String] = []
        for intent in await KnowledgeSource.mapsIntents() {
            let address = intent.address
            guard !address.isEmpty || intent.value("Name") != nil else { continue }
            let key = (intent.value("Name") ?? "") + "|" + address
            if var g = groups[key] {
                g.count += 1
                g.first = min(g.first, intent.date)
                if let e = intent.value("element") { g.elements.insert(e) }
                groups[key] = g
            } else {
                groups[key] = Group(intent: intent, count: 1, first: intent.date, elements: Set([intent.value("element")].compactMap { $0 }))
                order.append(key)
            }
        }
        return order.compactMap { key in
            guard let g = groups[key] else { return nil }
            let intent = g.intent
            var details = [KV("Interactions", String(g.count)), KV("First seen", DossierDate.medium(g.first)), KV("From device", intent.device)]
            if !g.elements.isEmpty { details.append(KV("Actions", g.elements.sorted().map { $0.replacingOccurrences(of: "_", with: " ").lowercased() }.joined(separator: ", "))) }
            for p in intent.params where !["element", "source", "compatibilityVersion", "resultIndex", "locale"].contains(p.key) {
                details.append(p)
            }
            return Place(
                id: "maps|\(intent.pk)", title: intent.value("Name") ?? intent.address, kind: .maps, address: intent.address,
                latitude: nil, longitude: nil, radius: nil, date: intent.date, uses: g.count,
                label: intent.value("category_type") ?? "", origin: intent.bundle, store: "knowledgeC · /app/intents",
                details: details, ref: .knowledgeIntent(pk: intent.pk))
        }
    }

    // knowledgeC structured metadata with coordinates (app activity / location streams).
    static func activityLocations() async -> [Place] {
        guard let db = await KnowledgeSource.db() else { return [] }
        let cols = await db.columnSet(of: "ZSTRUCTUREDMETADATA")
        let lat = "Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__LATITUDE", lon = "Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__LONGITUDE"
        guard cols.contains(lat), cols.contains(lon) else { return [] }
        func col(_ name: String) -> String { cols.contains(name) ? "m.\(name)" : "NULL" }
        let sql = """
            SELECT o.Z_PK, o.ZSTARTDATE, o.ZSTREAMNAME, o.ZVALUESTRING, m.\(lat), m.\(lon),
                   \(col("Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__DISPLAYNAME")), \(col("Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__LOCATIONNAME")),
                   \(col("Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__FULLYFORMATTEDADDRESS"))
            FROM ZSTRUCTUREDMETADATA m JOIN ZOBJECT o ON o.ZSTRUCTUREDMETADATA = m.Z_PK
            WHERE m.\(lat) IS NOT NULL AND m.\(lon) IS NOT NULL ORDER BY o.ZSTARTDATE DESC LIMIT 5000
            """
        var out: [Place] = []
        for row in (try? await db.rows(sql)) ?? [] {
            guard let pk = row[0].int, let la = row[4].double, let lo = row[5].double else { continue }
            let name = row[6].string ?? row[7].string ?? row[3].string ?? "Activity location"
            out.append(Place(
                id: "act|\(pk)", title: name, kind: .activity, address: row[8].string ?? "", latitude: la, longitude: lo, radius: nil,
                date: row[1].cocoaDate, uses: 1, label: "", origin: row[3].string ?? "", store: "knowledgeC · " + (row[2].string ?? ""),
                details: [KV("Stream", row[2].string ?? ""), KV("App", row[3].string ?? "")], ref: .none))
        }
        return out
    }

    static func microLabels() async -> [Place] {
        await MiloSource.lois().map { loi in
            Place(
                id: "loi|\(loi.id)", title: loi.type.isEmpty ? "Location of interest" : loi.type.capitalized, kind: .micro, address: "",
                latitude: nil, longitude: nil, radius: nil, date: loi.lastSeen, uses: 1, label: loi.type, origin: "milod",
                store: "milod · ZULLOIMO", details: [KV("Label", loi.type), KV("Last seen", DossierDate.medium(loi.lastSeen))], ref: .none)
        }
    }
}
