import SwiftUI
import DossierCore

/// Devices & Places — whereabouts, environment and system-level traces.
///
/// Sources: Biome streams (Bluetooth, Wi-Fi, authentication dialogs, feature signals,
/// screenshots, menu items, documents, intents, notifications, Focus), the linkd App
/// Intents transcript, knowledgeC (Bluetooth sessions, Maps destinations), the
/// microlocation and media-routing daemons, the iCloud key-value cache (known Wi-Fi
/// networks, printers, recent locations), the Focus configuration cache and Biome's sync
/// database. Everything is read-only; see the per-source files for the decoded layouts.
public final class EnvironmentModule: DossierModule {
    public let id = "environment"
    public let title = "Devices & Places"
    public let symbol = "mappin.and.ellipse"
    public let group = SidebarGroup.behaviour

    public init() {}

    public var sections: [ModuleSection] {
        [
            ModuleSection(id: "environment.places", title: "Places Map", symbol: "map") { PlacesView() },
            ModuleSection(id: "environment.networks", title: "Networks & Radios", symbol: "wifi") { NetworksView() },
            ModuleSection(id: "environment.devices", title: "My Devices", symbol: "laptopcomputer.and.iphone") { DevicesView() },
            ModuleSection(id: "environment.actions", title: "Actions Log", symbol: "bolt.horizontal") { ActionsView() },
            ModuleSection(id: "environment.focus", title: "Focus Modes", symbol: "moon") { FocusView() },
            ModuleSection(id: "environment.signals", title: "Notifications & Signals", symbol: "bell.badge") { SignalsView() },
        ]
    }

    /// The Biome streams this module decodes.
    static let streams = [
        "Device.Wireless.Bluetooth", "Device.Wireless.BluetoothNearbyDevice", "Device.Wireless.WiFi", "_DKEvent.Wifi.Connection",
        "LocalAuthentication.UI.Dialogs", "Discoverability.Signals", "Screenshots.Screenshot", "App.MenuItem",
        "App.DocumentInteraction", "App.Intent", "App.Intents.Transcript", "App.RelevantShortcuts",
        "Notification.Usage", "Notification.Delivery", "Mail.Search.Query", "SystemSettings.SearchTerms",
        "UserFocus.ComputedMode", "UserFocus.InferredMode",
    ]

    // MARK: Summary

    public func summary() async -> ModuleSummary {
        let token = 0
        async let actionsTask = try? ActionsLoader.load(token: token)
        async let placesTask = try? PlacesLoader.load(token: token)
        async let networksTask = try? NetworksLoader.load(token: token)
        async let devicesTask = try? DevicesLoader.load(token: token)
        async let focusTask = try? FocusLoader.load(token: token)
        async let signalsTask = try? SignalsLoader.load(token: token)
        let (actions, places, networks, devices, focus, signals) = await (actionsTask, placesTask, networksTask, devicesTask, focusTask, signalsTask)

        var stores: [StoreInfo] = []

        // Biome streams used by this module, as one store.
        var streamBytes: Int64 = 0, streamRecords = 0
        var streamRange: ClosedRange<Date>?
        for name in Self.streams + PlacesLoader.locationStreams.map(\.name) {
            let s = EnvBiome.stats(name)
            streamBytes += s.bytes
            streamRecords += s.records
            if let r = s.range { streamRange = streamRange.map { min($0.lowerBound, r.lowerBound)...max($0.upperBound, r.upperBound) } ?? r }
        }
        let biomeAvailability = Paths.probe(Paths.biomeRestrictedStreams)
        stores.append(StoreInfo(
            name: "Biome environment streams", path: Paths.biomeRestrictedStreams, sizeBytes: biomeAvailability.isAvailable ? streamBytes : nil,
            rowCount: biomeAvailability.isAvailable ? streamRecords : nil, timeRange: streamRange, availability: biomeAvailability,
            note: "\(Self.streams.count) streams: Bluetooth, Wi-Fi, intents, menus, screenshots, notifications, Focus"))

        var linkd = StoreInfo.file("linkd ActionTranscript", EnvPaths.linkdTranscripts, note: "App Intents executed, with parameters")
        if linkd.availability.isAvailable, let url = EnvPaths.linkdTranscripts {
            linkd.sizeBytes = FileProbe.directorySize(url, maxFiles: 20_000).bytes
            let rows = actions?.rows.filter { $0.store == "linkd ActionTranscript" } ?? []
            linkd.rowCount = rows.count
            if let lo = rows.map(\.date).min(), let hi = rows.map(\.date).max() { linkd.timeRange = lo...hi }
        }
        stores.append(linkd)

        var milo = StoreInfo.file("milo.db (microlocation)", EnvPaths.miloDB, note: "Wi-Fi fingerprints and place labels")
        if let m = networks?.milo, m.availability.isAvailable {
            milo.rowCount = m.measurements
            milo.timeRange = m.scanRange
        }
        stores.append(milo)

        var routing = StoreInfo.file("intelligentRouting.sqlite", EnvPaths.routingDB, note: "AirPlay / media route targets")
        routing.rowCount = devices?.targets.count
        stores.append(routing)

        var kvs = StoreInfo.file("iCloud key-value cache", EnvPaths.kvsDirectory, note: "Known Wi-Fi networks, printers, recent locations")
        if kvs.availability.isAvailable {
            kvs.sizeBytes = EnvPaths.kvsDatabases.reduce(0) { $0 + FileProbe.databaseSize($1) }
            let counts = await KVSSource.storeCounts([WifiKVS.store, WifiKVS.printerStore, "com.apple.eventkit.locations", "com.apple.passbook.locations"])
            kvs.rowCount = counts.values.reduce(0) { $0 + $1.keys }
            let ranges = counts.values.compactMap(\.range)
            if let lo = ranges.map(\.lowerBound).min(), let hi = ranges.map(\.upperBound).max() { kvs.timeRange = lo...hi }
        }
        stores.append(kvs)

        var sync = StoreInfo.file("Biome sync.db", Paths.biomeSyncDB, note: "Sync peers and session log")
        if let d = devices, d.syncAvailability.isAvailable {
            sync.rowCount = d.sessions.count + d.peers.filter(\.listed).count
            if let lo = d.sessions.map(\.start).min(), let hi = d.sessions.map(\.start).max() { sync.timeRange = lo...hi }
        }
        stores.append(sync)

        var focusStore = StoreInfo.file("Focus configuration cache", EnvPaths.focusCache, note: "Modes, allowed apps and people, triggers")
        focusStore.rowCount = focus?.modes.count
        stores.append(focusStore)

        var knowledge = StoreInfo.file("knowledgeC.db", Paths.knowledgeC, note: "Bluetooth sessions, Maps destinations, notification usage")
        if let n = networks, let s = signals, knowledge.availability.isAvailable {
            knowledge.rowCount = n.bluetooth.knowledgeSessions + n.bluetooth.knowledgeNotConnected + s.knowledgeTotal + (actions?.counts[.maps] ?? 0)
        }
        stores.append(knowledge)

        // Headline facts.
        var facts: [Fact] = []
        if let n = networks, !n.wifi.networks.isEmpty {
            let oldest = n.wifi.networks.compactMap(\.addedAt).min()
            let removed = n.wifi.networks.filter(\.isRemoved).count
            facts.append(Fact("Wi-Fi networks remembered", Format.count(n.wifi.networks.count - removed)
                              + (removed > 0 ? ", \(Format.count(removed)) more removed but still on record" : "")
                              + (oldest.map { ", going back to " + DossierDate.day($0) } ?? ""),
                              sensitivity: .sensitive, symbol: "wifi", sectionID: "environment.networks"))
        }
        if let p = places, !p.places.isEmpty {
            facts.append(Fact("Places on record", "\(Format.count(p.places.count)) (\(Format.count(p.withCoordinates)) with exact coordinates)",
                              sensitivity: .sensitive, symbol: "mappin.and.ellipse", sectionID: "environment.places"))
        }
        if let b = networks?.bluetooth, !b.devices.isEmpty {
            facts.append(Fact("Bluetooth accessories tracked", "\(Format.count(b.devices.count)) with \(Format.count(b.sessions.filter(\.primary).count)) connection sessions",
                              sensitivity: .personal, symbol: "headphones", sectionID: "environment.networks"))
        }
        if let m = networks?.milo, m.scans > 0 {
            let labels = m.lois.map(\.type).filter { !$0.isEmpty }
            facts.append(Fact("Wi-Fi fingerprints of your surroundings", "\(Format.count(m.scans)) scans of \(Format.count(m.bssids.count)) access points"
                              + (labels.isEmpty ? "" : ", labelled “\(Set(labels).sorted().joined(separator: ", "))”"),
                              sensitivity: .sensitive, symbol: "dot.radiowaves.left.and.right", sectionID: "environment.networks"))
        }
        if let d = devices {
            let feeding = d.peers.filter { !$0.isMe && $0.streams > 0 }
            if !feeding.isEmpty {
                facts.append(Fact("Other devices whose activity is copied here", "\(feeding.count) devices across \(Set(d.shares.map(\.stream)).count) streams",
                                  sensitivity: .personal, symbol: "laptopcomputer.and.iphone", sectionID: "environment.devices"))
            }
        }
        if let a = actions, !a.rows.isEmpty {
            let parts = [ActionKind.settings, .screenshot, .menu, .auth].compactMap { k in a.counts[k].map { "\($0) \(k.rawValue.lowercased())s" } }
            facts.append(Fact("System-level actions logged", Format.count(a.rows.count) + (parts.isEmpty ? "" : " — " + parts.prefix(3).joined(separator: ", ")),
                              sensitivity: .personal, symbol: "bolt.horizontal", sectionID: "environment.actions"))
        }
        if let f = focus, !f.modes.isEmpty {
            let geofenced = f.modes.filter { $0.triggers.contains { $0.latitude != nil } }.count
            let allowed = f.modes.reduce(0) { $0 + $1.allowedContacts.count }
            let silenced = f.modes.reduce(0) { $0 + $1.deniedContacts.count }
            facts.append(Fact("Focus modes configured", "\(f.modes.count), \(geofenced) with a location trigger, \(allowed + silenced) people rules stored (\(allowed) allowed, \(silenced) silenced)",
                              sensitivity: .sensitive, symbol: "moon", sectionID: "environment.focus"))
        }
        if let s = signals, s.usageCount + s.deliveryCount + s.signals.count > 0 {
            facts.append(Fact("Notification and feature-use events", "\(Format.count(s.distinctCount)) notifications from \(s.perApp.count) apps, \(Format.count(s.signals.count)) feature signals",
                              sensitivity: .personal, symbol: "bell.badge", sectionID: "environment.signals"))
        }
        return ModuleSummary(stores: stores, facts: facts)
    }

    // MARK: Search

    public func search(_ query: String, limit: Int) async -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2, limit > 0 else { return [] }
        var hits: [SearchHit] = []
        let perKind = max(3, limit / 4)
        func contains(_ text: String) -> Bool { text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }

        if let places = try? await PlacesLoader.load(token: 0) {
            for p in places.places where contains(p.title) || contains(p.address) || contains(p.label) {
                hits.append(SearchHit(title: p.title, subtitle: [p.kind.rawValue, p.address].filter { !$0.isEmpty }.joined(separator: " · "),
                                      moduleID: id, sectionID: "environment.places", payload: p.id, symbol: p.kind.symbol, sensitivity: .sensitive))
                if hits.count >= perKind { break }
            }
        }
        if Task.isCancelled { return [] }
        if let networks = try? await NetworksLoader.load(token: 0) {
            var n = 0
            for w in networks.wifi.networks where contains(w.ssid) {
                hits.append(SearchHit(title: w.ssid, subtitle: "Known Wi-Fi network" + (w.lastJoined.map { " · last joined " + DossierDate.day($0) } ?? ""),
                                      moduleID: id, sectionID: "environment.networks", payload: "wifi:" + w.ssid, symbol: "wifi", sensitivity: .sensitive))
                n += 1
                if n >= perKind { break }
            }
            n = 0
            for d in networks.bluetooth.devices where contains(d.name) || contains(d.address) {
                hits.append(SearchHit(title: d.name, subtitle: "Bluetooth accessory · \(d.sessions) sessions",
                                      moduleID: id, sectionID: "environment.networks", payload: "bt:" + d.name, symbol: "headphones", sensitivity: .personal))
                n += 1
                if n >= perKind { break }
            }
        }
        if Task.isCancelled { return [] }
        if let focus = try? await FocusLoader.load(token: 0) {
            func person(_ c: FocusContact) -> Bool { contains(c.name) || c.handles.contains(where: contains) }
            func app(_ a: FocusApp) -> Bool { contains(a.bundle) || contains(EnvFormat.appName(a.bundle)) }
            for m in focus.modes where contains(m.name) || m.allowedContacts.contains(where: person) || m.deniedContacts.contains(where: person)
                || m.allowedApps.contains(where: app) || m.deniedApps.contains(where: app) {
                let silenced = m.deniedContacts.count + m.deniedApps.count
                hits.append(SearchHit(title: m.name, subtitle: "Focus mode · \(m.allowedApps.count) apps, \(m.allowedContacts.count) people allowed" + (silenced > 0 ? ", \(silenced) silenced" : ""),
                                      moduleID: id, sectionID: "environment.focus", payload: m.id, symbol: "moon", sensitivity: .personal))
            }
        }
        if Task.isCancelled { return [] }
        if let actions = try? await ActionsLoader.load(token: 0) {
            var n = 0
            for row in actions.rows where contains(row.title) || contains(row.detail) {
                if Task.isCancelled { return [] }
                hits.append(SearchHit(title: row.title, subtitle: "\(row.kind.rawValue) · \(DossierDate.short(row.date))" + (row.detail.isEmpty ? "" : " · " + row.detail),
                                      moduleID: id, sectionID: "environment.actions", payload: row.id, symbol: row.kind.symbol, sensitivity: .personal))
                n += 1
                if n >= perKind { break }
            }
        }
        if let signals = try? await SignalsLoader.load(token: 0), hits.count < limit {
            for app in signals.perApp where contains(app.bundle) || contains(EnvFormat.appName(app.bundle)) {
                hits.append(SearchHit(title: EnvFormat.appName(app.bundle), subtitle: "\(app.distinct) notifications · \(app.bundle)",
                                      moduleID: id, sectionID: "environment.signals", payload: app.bundle, symbol: "bell", sensitivity: .personal))
                if hits.count >= limit { break }
            }
        }
        return Array(hits.prefix(limit))
    }

    // MARK: Self-test

    public func selfTest() async -> [SelfTestLine] {
        var lines: [SelfTestLine] = []
        func describe(_ range: ClosedRange<Date>?) -> String { range.map { " · " + DossierDate.sortable($0.lowerBound) + " … " + DossierDate.sortable($0.upperBound) } ?? "" }
        func availability(_ label: String, _ url: URL?) {
            switch Paths.probe(url) {
            case .available: lines.append(.pass(label, "readable"))
            case .missing: lines.append(.warn(label, "not present on this Mac"))
            case .inaccessible(let reason): lines.append(.warn(label, "inaccessible: \(reason)"))
            }
        }

        lines.append(.check("Full Disk Access", Paths.hasFullDiskAccess(), "needed for Biome, knowledgeC and daemon containers"))

        // Biome streams.
        for name in Self.streams + PlacesLoader.locationStreams.map(\.name) {
            let s = EnvBiome.stats(name)
            if !s.available {
                lines.append(.info("stream " + name, "absent"))
            } else {
                lines.append(.pass("stream " + name, "\(s.records) live records · \(Format.bytes(s.bytes))" + describe(s.range)))
            }
        }

        // Stores.
        availability("linkd ActionTranscript", EnvPaths.linkdTranscripts)
        availability("milo.db", EnvPaths.miloDB)
        availability("intelligentRouting.sqlite", EnvPaths.routingDB)
        availability("iCloud key-value cache", EnvPaths.kvsDirectory)
        availability("Biome sync.db", Paths.biomeSyncDB)
        availability("knowledgeC.db", Paths.knowledgeC)
        availability("Focus configuration cache", EnvPaths.focusCache)

        var timings: [String] = []

        var watch = Stopwatch()
        if let a = try? await ActionsLoader.load(token: 0) {
            timings.append("actions \(watch.ms) ms")
            for source in a.sources {
                lines.append(.pass("actions · " + source.name, "\(source.count) rows" + describe(source.range)))
            }
            let linkd = Linkd.counts()
            lines.append(.pass("linkd records", "\(linkd.records) records in all directories, \(linkd.distinct) distinct executions"))
            let kinds = ActionKind.allCases.compactMap { k in a.counts[k].map { "\(k.rawValue) \($0)" } }.joined(separator: ", ")
            lines.append(a.rows.isEmpty ? .warn("actions log", "no rows in any source") : .pass("actions log", "\(a.rows.count) rows — " + kinds))
            let ids = Set(a.rows.map(\.id))
            lines.append(.check("actions row ids unique", ids.count == a.rows.count, "\(ids.count) ids / \(a.rows.count) rows"))
        } else {
            lines.append(.fail("actions log", "loader failed"))
        }

        watch = Stopwatch()
        if let n = try? await NetworksLoader.load(token: 0) {
            timings.append("networks \(watch.ms) ms")
            let removed = n.wifi.networks.filter(\.isRemoved).count
            lines.append(.pass("known Wi-Fi networks", "\(n.wifi.networks.count) (\(removed) removed)" + describe(n.wifi.networks.compactMap(\.addedAt).min().flatMap { lo in n.wifi.networks.compactMap(\.lastJoined).max().map { min(lo, $0)...max(lo, $0) } })))
            lines.append(.pass("Wi-Fi join log", "\(n.wifi.joins.count) rows — " + n.wifi.streamCounts.map { "\($0.name) \($0.count)" }.joined(separator: ", ")))
            lines.append(.pass("printers", "\(n.wifi.printers.count)"))
            let m = n.milo
            lines.append(.pass("microlocation", "\(m.scans) scans, \(m.measurements) measurements, \(m.bssids.count) BSSIDs, \(m.lois.count) labelled places, \(m.events.count) log events, \(m.models.count) models" + describe(m.scanRange)))
            let histogramTotal = m.rssiHistogram.reduce(0) { $0 + $1.count }
            lines.append(.check("microlocation histogram covers all samples", histogramTotal == m.measurements && m.bssids.reduce(0) { $0 + $1.samples } == m.measurements, "\(histogramTotal) of \(m.measurements)"))
            let b = n.bluetooth
            lines.append(.pass("Bluetooth", "\(b.devices.count) accessories, \(b.sessions.filter(\.primary).count) sessions (+\(b.sessions.filter { !$0.primary }.count) duplicate-log), \(b.biomeEvents) Biome events (\(b.biomeEventsPerHost.map { "\($0.host): \($0.count)" }.joined(separator: "; "))), \(b.knowledgeSessions) knowledgeC connected intervals (+\(b.knowledgeNotConnected) not-connected intervals, not sessions), \(b.nearby.count) nearby sightings" + describe(b.range)))
        } else {
            lines.append(.fail("networks", "loader failed"))
        }

        watch = Stopwatch()
        if let d = try? await DevicesLoader.load(token: 0) {
            timings.append("devices \(watch.ms) ms")
            lines.append(.pass("sync peers", "\(d.peers.count) devices (\(d.peers.filter(\.listed).count) in DevicePeer; unlisted with data: \(d.peers.filter { !$0.listed && $0.streams > 0 }.map { "\($0.label) [\($0.streams) streams]" }.joined(separator: ", ").nilIfEmpty ?? "none"); \(Set(d.peers.map(\.label)).count) distinct labels), \(d.shares.count) stream shares over \(Set(d.shares.map(\.stream)).count) streams, \(d.sessions.count) sync sessions, \(d.merged.reduce(0) { $0 + $1.atoms }) merged events, last sync \(DossierDate.sortable(d.lastSync))"))
            lines.append(.pass("route targets", "\(d.targets.count) AirPlay / media targets, \(d.knowledgePeers.count) CoreDuet peers, \(d.identities.count) microlocation Bluetooth identities"))
        } else {
            lines.append(.fail("devices", "loader failed"))
        }

        watch = Stopwatch()
        if let f = try? await FocusLoader.load(token: 0) {
            timings.append("focus \(watch.ms) ms")
            let geofences = f.modes.flatMap(\.triggers).filter { $0.latitude != nil }.count
            lines.append(.pass("Focus modes", "\(f.modes.count) modes, \(f.modes.reduce(0) { $0 + $1.allowedApps.count }) allowed apps, \(f.modes.reduce(0) { $0 + $1.deniedApps.count }) silenced apps, \(f.modes.reduce(0) { $0 + $1.allowedContacts.count }) allowed contacts, \(f.modes.reduce(0) { $0 + $1.deniedContacts.count }) silenced contacts, \(f.modes.reduce(0) { $0 + $1.triggers.count }) triggers (\(geofences) geofences)"))
            lines.append(.pass("Focus activity", "\(f.events.count) events — computed \(f.computedCount), inferred \(f.inferredCount), assertions \(f.assertionCount)"))
        } else {
            lines.append(.fail("focus", "loader failed"))
        }

        watch = Stopwatch()
        if let p = try? await PlacesLoader.load(token: 0) {
            timings.append("places \(watch.ms) ms")
            let kinds = PlaceKind.allCases.compactMap { k in p.counts[k].map { "\(k.rawValue) \($0)" } }.joined(separator: ", ")
            lines.append(.pass("places", "\(p.places.count) places, \(p.withCoordinates) with coordinates — " + kinds))
            let ids = Set(p.places.map(\.id))
            lines.append(.check("place ids unique", ids.count == p.places.count))
            let bad = p.places.filter { place in
                guard let lat = place.latitude, let lon = place.longitude else { return false }
                return !(-90...90).contains(lat) || !(-180...180).contains(lon) || (lat == 0 && lon == 0)
            }.count
            lines.append(.check("place coordinates plausible", bad == 0, "\(bad) out of range"))
        } else {
            lines.append(.fail("places", "loader failed"))
        }

        watch = Stopwatch()
        if let s = try? await SignalsLoader.load(token: 0) {
            timings.append("signals \(watch.ms) ms")
            lines.append(.pass("notifications", "\(s.distinctCount) distinct notifications (\(s.usageCount) usage + \(s.deliveryCount) delivery log entries) from \(s.perApp.count) apps; knowledgeC copy \(s.knowledgeTotal)" + describe(s.notificationRange)))
            lines.append(.pass("feature signals", "\(s.signals.count) signals, \(s.perSignal.count) distinct" + describe(s.signalRange)))
        } else {
            lines.append(.fail("signals", "loader failed"))
        }

        watch = Stopwatch()
        let summary = await summary()
        timings.append("summary (cached) \(watch.ms) ms")
        lines.append(.check("summary", !summary.stores.isEmpty, "\(summary.stores.count) stores, \(summary.facts.count) facts"))
        lines.append(.info("timings", timings.joined(separator: ", ")))
        return lines
    }
}
