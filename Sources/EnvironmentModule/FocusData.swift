import Foundation
import DossierCore

struct FocusApp: Identifiable, Sendable, Hashable {
    var id: String { "\(platform)|\(bundle)" }
    let bundle: String
    let platform: Int

    /// Platform codes of `DNDApplicationIdentifier`, inferred from the bundle ids they
    /// accompany (1: iPhone / iPad apps, 2: Mac apps, 3: Apple Watch apps).
    var platformName: String {
        switch platform {
        case 1: return "iOS"
        case 2: return "macOS"
        case 3: return "watchOS"
        default: return "Platform \(platform)"
        }
    }
}

struct FocusContact: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let handles: [String]
}

struct FocusTrigger: Identifiable, Sendable {
    let id: String
    let kind: String
    let symbol: String
    let enabledSetting: Int?
    let detail: String
    let latitude: Double?
    let longitude: Double?
    let radius: Double?
    let regionName: String?

    /// `DNDEnabledSetting`: 0 default, 1 enabled, 2 disabled.
    var stateLabel: String {
        switch enabledSetting {
        case 1: return "On"
        case 2: return "Off"
        case 0: return "Default"
        case .some(let v): return "Setting \(v)"
        case nil: return "—"
        }
    }
}

struct FocusMode: Identifiable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let tintName: String
    let semanticType: Int?
    let created: Date?
    let modified: Date?
    let modifiedByVersion: String
    let automaticallyGenerated: Bool
    let triggers: [FocusTrigger]
    let allowedApps: [FocusApp]
    let deniedApps: [FocusApp]
    let allowedContacts: [FocusContact]
    let deniedContacts: [FocusContact]
    /// Remaining configuration switches as stored (numeric codes).
    let settings: [KV]

    var isBuiltIn: Bool { id.hasPrefix("com.apple.") && !id.contains(".mode.") || id.hasSuffix(".default") || id.hasSuffix(".driving") }
}

/// A change of the active Focus, from one of several logs.
struct FocusEvent: Identifiable, Sendable {
    let id: String
    let date: Date
    let end: Date?
    let mode: String
    let event: String
    let source: String
    let detail: String
    let ref: RawRef
}

struct FocusData: Sendable {
    var modes: [FocusMode] = []
    var events: [FocusEvent] = []
    var cacheAvailability: Availability = .missing
    var computedCount = 0
    var inferredCount = 0
    var assertionCount = 0
}

enum FocusLoader {
    static func load(token: Int) async throws -> FocusData {
        await EnvCache.shared.sync(token: token)
        return try await EnvCache.shared.value("focus") { await build() }
    }

    static func modes() -> (modes: [FocusMode], availability: Availability) {
        let availability = Paths.probe(EnvPaths.focusCache)
        guard availability.isAvailable, let data = try? Data(contentsOf: EnvPaths.focusCache, options: .mappedIfSafe),
              let archive = KeyedArchive(data) else { return ([], availability) }
        var out: [FocusMode] = []
        for pair in archive.pairs(archive.root) {
            guard let identifier = archive.string(pair.key), let config = pair.value else { continue }
            out.append(decodeMode(archive, identifier: identifier, config))
        }
        // Most elaborately configured modes first.
        func richness(_ m: FocusMode) -> Int { m.allowedApps.count + m.deniedApps.count + m.allowedContacts.count + m.deniedContacts.count + 3 * m.triggers.count }
        out.sort { a, b in
            let ra = richness(a), rb = richness(b)
            return ra != rb ? ra > rb : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return (out, availability)
    }

    private static func build() async -> FocusData {
        var data = FocusData()
        let loaded = modes()
        data.modes = loaded.modes
        data.cacheAvailability = loaded.availability
        let names = Dictionary(loaded.modes.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var events: [FocusEvent] = []

        // UserFocus.ComputedMode — 1 assertion UUID, 2 starting (1) / ending (0), 3–5 codes,
        // 6 mode identifier.
        EnvBiome.forEach("UserFocus.ComputedMode") { record, msg in
            let mode = msg[6]?.string ?? ""
            let starting = msg[2]?.bool ?? false
            let codes = [3, 4, 5].compactMap { n in msg[n]?.int.map { "field \(n) = \($0)" } }.joined(separator: ", ")
            events.append(FocusEvent(
                id: "c|" + record.id, date: record.timestamp, end: nil, mode: names[mode] ?? mode,
                event: starting ? "Turned on" : "Turned off", source: "UserFocus.ComputedMode", detail: codes, ref: EnvBiome.ref(record)))
            data.computedCount += 1
        }
        // UserFocus.InferredMode — 1 Cocoa date, 2/7 UUIDs, 3 mode type code, 5 start flag,
        // 10 confidence, 12 origin code, 14 origin label.
        EnvBiome.forEach("UserFocus.InferredMode") { record, msg in
            let label = msg[14]?.string
            let type = msg[3]?.int ?? 0
            let confidence = msg[10]?.double
            var detail: [String] = []
            if let confidence { detail.append("confidence " + Format.number(confidence)) }
            if let origin = msg[12]?.int { detail.append("origin code \(origin)") }
            events.append(FocusEvent(
                id: "i|" + record.id, date: msg[1]?.cocoaDate ?? record.timestamp, end: nil,
                mode: label ?? "Mode type \(type)", event: (msg[5]?.bool ?? false) ? "Inferred start" : "Inferred end",
                source: "UserFocus.InferredMode", detail: detail.joined(separator: ", "), ref: EnvBiome.ref(record)))
            data.inferredCount += 1
        }
        // DoNotDisturb Assertions.json — finished Focus sessions with start and end.
        if let json = (try? Data(contentsOf: EnvPaths.focusAssertions)).flatMap(PlistDecoder.decodeJSON) {
            for (s, store) in (json["data"]?.array ?? []).enumerated() {
                for (i, record) in (store["storeInvalidationRecords"]?.array ?? []).enumerated() {
                    let assertion = record["invalidationAssertion"]
                    guard let start = assertion?["assertionStartDateTimestamp"]?.double else { continue }
                    let mode = assertion?.value(at: "assertionDetails", "assertionDetailsModeIdentifier")?.string ?? ""
                    let end = record["invalidationDateTimestamp"]?.double.map { DossierDate.cocoa($0) }
                    let client = assertion?.value(at: "assertionSource", "assertionClientIdentifier")?.string ?? ""
                    let reason = record["invalidationReason"]?.string ?? ""
                    events.append(FocusEvent(
                        id: "a|\(s)|\(i)", date: DossierDate.cocoa(start), end: end, mode: names[mode] ?? mode,
                        event: "Session", source: "DoNotDisturb Assertions",
                        detail: [client.nilIfEmpty.map { "by " + $0 }, reason.nilIfEmpty.map { "ended: " + $0 }].compactMap { $0 }.joined(separator: ", "),
                        ref: .none))
                    data.assertionCount += 1
                }
            }
        }
        data.events = events.sorted { $0.date > $1.date }
        return data
    }

    private static func decodeMode(_ a: KeyedArchive, identifier: String, _ config: PlistValue) -> FocusMode {
        let mode = a.deref(config["mode"])
        let configuration = a.deref(config["configuration"])
        let sender = a.deref(configuration?["senderConfiguration"])

        func apps(_ key: String) -> [FocusApp] {
            guard let container = a.deref(configuration?[key]) else { return [] }
            // Either a dictionary keyed by DNDApplicationIdentifier or a set of them.
            let keys = container["NS.keys"] != nil ? a.pairs(container).map(\.key) : a.items(container)
            return keys.compactMap { key in
                guard let bundle = a.string(key["bundleID"]) else { return nil }
                return FocusApp(bundle: bundle, platform: Int(key["platform"]?.int ?? 0))
            }.sorted { $0.bundle < $1.bundle }
        }
        func contacts(_ key: String) -> [FocusContact] {
            a.items(sender?[key]).enumerated().map { i, c in
                let parts = ["firstName", "middleName", "lastName"].compactMap { a.string(c[$0])?.nilIfEmpty }
                let org = a.string(c["organizationName"])?.nilIfEmpty
                let handles = (a.items(c["phoneNumbers"]) + a.items(c["emailAddresses"])).compactMap { a.string($0) }
                let name = parts.isEmpty ? (org ?? handles.first ?? "Contact") : parts.joined(separator: " ")
                return FocusContact(id: "\(key)-\(i)", name: name, handles: handles)
            }
        }

        var triggers: [FocusTrigger] = []
        for (i, trigger) in a.items(config["triggers"]).enumerated() {
            let cls = a.className(trigger) ?? "Trigger"
            let enabled = trigger["enabledSetting"]?.int.map(Int.init)
            var kind = cls.replacingOccurrences(of: "DNDModeConfiguration", with: "").replacingOccurrences(of: "Trigger", with: "")
            kind = EnvFormat.humanize(kind)
            var symbol = "bolt"
            var detail = ""
            var region: (latitude: Double, longitude: Double, radius: Double, identifier: String?)?
            switch cls {
            case "DNDModeConfigurationLocationTrigger":
                symbol = "location"
                region = a.circularRegion(trigger["region"])
                if let region {
                    detail = [region.identifier, EnvFormat.coordinate(region.latitude, region.longitude), "radius \(Int(region.radius)) m"]
                        .compactMap { $0 }.joined(separator: " · ")
                }
                if let text = a.string(trigger["detail"]) { detail += detail.isEmpty ? text : " · " + text }
            case "DNDModeConfigurationSmartTrigger":
                symbol = "sparkles"; detail = "Turns on automatically at times the system judges relevant"
            case "DNDModeConfigurationSleepingTrigger":
                symbol = "bed.double"; detail = "Follows the Sleep schedule"
            case "DNDModeConfigurationDrivingTrigger":
                symbol = "car"; detail = "Turns on when driving is detected"
            case "DNDModeConfigurationScheduleTrigger":
                symbol = "calendar.badge.clock"
                var parts: [String] = []
                for key in ["timePeriod", "weekdays", "startHour", "startMinute", "endHour", "endMinute"] {
                    guard let v = a.deref(trigger[key]) else { continue }
                    if let n = v.int { parts.append("\(key) \(n)") } else if case .dict(let pairs) = v {
                        let inner = pairs.filter { $0.key != "$class" }.compactMap { p in p.value.int.map { "\(p.key) \($0)" } }
                        if !inner.isEmpty { parts.append(inner.joined(separator: ", ")) }
                    }
                }
                detail = parts.joined(separator: " · ")
            case "DNDModeConfigurationApplicationTrigger":
                symbol = "app"
                let bundle = a.string(a.deref(trigger["applicationIdentifier"])?["bundleID"]) ?? a.string(trigger["bundleIdentifier"]) ?? ""
                let name = EnvFormat.appName(bundle)
                detail = name == bundle || name.isEmpty ? bundle : "\(name) (\(bundle))"
            default:
                break
            }
            triggers.append(FocusTrigger(
                id: "\(identifier)-\(i)", kind: kind.isEmpty ? "Trigger" : kind, symbol: symbol, enabledSetting: enabled, detail: detail,
                latitude: region?.latitude, longitude: region?.longitude, radius: region?.radius, regionName: region?.identifier))
        }

        var settings: [KV] = []
        if case .dict(let pairs)? = configuration {
            for pair in pairs where pair.key != "$class" {
                if let v = pair.value.int { settings.append(KV(pair.key, String(v))) } else if let b = pair.value.bool { settings.append(KV(pair.key, b ? "true" : "false")) }
            }
        }
        for key in ["dimsLockScreen", "impactsAvailability", "compatibilityVersion"] {
            if let v = config[key]?.int { settings.append(KV(key, String(v))) }
        }
        if let visibility = mode?["visibility"]?.int { settings.append(KV("visibility", String(visibility))) }
        settings.sort { $0.key < $1.key }

        return FocusMode(
            id: identifier, name: a.string(mode?["name"]) ?? identifier,
            symbol: a.string(mode?["symbolImageName"]) ?? "moon.fill", tintName: a.string(mode?["tintColorName"]) ?? "",
            semanticType: mode?["semanticType"]?.int.map(Int.init),
            created: a.date(config["created"]), modified: a.date(config["lastModified"]),
            modifiedByVersion: a.string(config["lastModifiedByVersion"]) ?? "",
            automaticallyGenerated: config["automaticallyGenerated"]?.bool ?? false,
            triggers: triggers, allowedApps: apps("allowedApplicationIdentifiers"), deniedApps: apps("deniedApplicationIdentifiers"),
            allowedContacts: contacts("allowedContacts"), deniedContacts: contacts("deniedContacts"), settings: settings)
    }
}
