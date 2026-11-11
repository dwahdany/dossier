import Foundation
import SwiftUI
import DossierCore

// MARK: - Small value types shared by the module

/// A decoded key/value pair shown in inspectors.
struct KV: Sendable, Hashable {
    let key: String
    let value: String
    init(_ key: String, _ value: String) { self.key = key; self.value = value }
}

/// Where the raw record behind a row lives, so the inspector can fetch it on demand
/// (rows themselves stay small).
enum RawRef: Sendable, Hashable {
    /// One record of a SEGB segment file.
    case segb(path: String, index: Int)
    /// `ZSTRUCTUREDMETADATA.Z_DKINTENTMETADATAKEY__SERIALIZEDINTERACTION` of a knowledgeC object.
    case knowledgeIntent(pk: Int64)
    /// One value of the iCloud key-value cache (`ZSYDMANAGEDKEYVALUE.ZPLISTDATAVALUE`).
    case kvs(database: String, pk: Int64)
    case none

    /// Loads the raw bytes (off the main actor).
    func load() async -> Data? {
        switch self {
        case .none:
            return nil
        case .segb(let path, let index):
            guard let file = try? SEGBFile(url: URL(fileURLWithPath: path)), file.entries.indices.contains(index) else { return nil }
            return file.payload(file.entries[index])
        case .knowledgeIntent(let pk):
            guard let db = await SQLiteDB.sharedIfAvailable(Paths.knowledgeC) else { return nil }
            let sql = "SELECT m.Z_DKINTENTMETADATAKEY__SERIALIZEDINTERACTION FROM ZOBJECT o JOIN ZSTRUCTUREDMETADATA m ON m.Z_PK = o.ZSTRUCTUREDMETADATA WHERE o.Z_PK = ?"
            return (try? await db.scalar(sql, [.integer(pk)]))?.data
        case .kvs(let database, let pk):
            guard let db = await SQLiteDB.sharedIfAvailable(URL(fileURLWithPath: database)) else { return nil }
            return (try? await db.scalar("SELECT ZPLISTDATAVALUE FROM ZSYDMANAGEDKEYVALUE WHERE Z_PK = ?", [.integer(pk)]))?.data
        }
    }
}

// MARK: - Store locations specific to this module

enum EnvPaths {
    static var linkdTranscripts: URL? {
        Paths.daemonContainerData("com.apple.linkd")?.appendingPathComponent("ActionTranscript", isDirectory: true)
    }
    static var miloDB: URL? {
        Paths.daemonContainerData("com.apple.milod")?.appendingPathComponent("com.apple.milod/milo.db")
    }
    static var routingDB: URL? {
        Paths.daemonContainerData("com.apple.intelligentroutingd")?.appendingPathComponent("com.apple.intelligentroutingd/intelligentRouting.sqlite")
    }
    static var kvsDirectory: URL? {
        Paths.daemonContainerData("com.apple.kvs")?.appendingPathComponent("com.apple.kvs", isDirectory: true)
    }
    /// All iCloud key-value cache databases (plain, encrypted, end-to-end encrypted…).
    static var kvsDatabases: [URL] {
        guard let dir = kvsDirectory,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension == "sqlite" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    static var focusCache: URL { Paths.duetExpertCenter.appendingPathComponent("DNDModeConfigurationsCache") }
    static var focusAssertions: URL { Paths.library.appendingPathComponent("DoNotDisturb/DB/Assertions.json") }

    static func stream(_ name: String) -> URL { Paths.biomeRestrictedStreams.appendingPathComponent(name, isDirectory: true) }
}

// MARK: - NSKeyedArchiver graph walker

/// Lazy view of an NSKeyedArchiver graph. Unlike a full unarchive it follows only the
/// references asked for, so archives with heavily shared sub-graphs stay cheap.
struct KeyedArchive {
    let objects: [PlistValue]
    let root: PlistValue?

    init?(_ data: Data) {
        guard let plist = PlistDecoder.decodePlist(data), let objects = plist["$objects"]?.array, let top = plist["$top"] else { return nil }
        self.objects = objects
        if let r = top["root"] { root = r } else { root = top.dict?.first?.value }
    }

    /// Follows a UID reference; non-references are returned unchanged, `$null` becomes nil.
    func deref(_ value: PlistValue?) -> PlistValue? {
        guard let value else { return nil }
        if case .uid(let index) = value {
            guard index != 0, objects.indices.contains(index) else { return nil }
            return objects[index]
        }
        return value
    }

    func className(_ value: PlistValue?) -> String? {
        guard let object = deref(value), case .uid(let ci)? = object["$class"], objects.indices.contains(ci) else { return nil }
        return objects[ci]["$classname"]?.string
    }

    /// Dereferenced member of an archived object.
    func member(_ value: PlistValue?, _ key: String) -> PlistValue? { deref(deref(value)?[key]) }

    func string(_ value: PlistValue?) -> String? {
        guard let object = deref(value) else { return nil }
        if let s = object.string { return s == "$null" ? nil : s }
        if let s = deref(object["NS.string"])?.string { return s }
        if let relative = deref(object["NS.relative"])?.string { return (deref(object["NS.base"])?.string ?? "") + relative }
        return nil
    }

    func date(_ value: PlistValue?) -> Date? {
        guard let object = deref(value) else { return nil }
        if let d = object.date { return d }
        if let t = object["NS.time"]?.double { return Date(timeIntervalSinceReferenceDate: t) }
        return nil
    }

    func uuid(_ value: PlistValue?) -> String? {
        guard let object = deref(value), let d = object["NS.uuidbytes"]?.data, d.count == 16 else { return nil }
        return d.withUnsafeBytes { NSUUID(uuidBytes: $0.bindMemory(to: UInt8.self).baseAddress).uuidString }
    }

    func data(_ value: PlistValue?) -> Data? {
        guard let object = deref(value) else { return nil }
        if let d = object.data { return d }
        if let d = deref(object["NS.data"])?.data { return d }
        return object["NS.bytes"]?.data
    }

    /// Elements of an archived array / set.
    func items(_ value: PlistValue?) -> [PlistValue] {
        guard let object = deref(value) else { return [] }
        if let list = object["NS.objects"]?.array { return list.compactMap { deref($0) } }
        return object.array?.compactMap { deref($0) } ?? []
    }

    /// Key/value pairs of an archived dictionary.
    func pairs(_ value: PlistValue?) -> [(key: PlistValue, value: PlistValue?)] {
        guard let object = deref(value), let keys = object["NS.keys"]?.array, let values = object["NS.objects"]?.array else { return [] }
        return zip(keys, values).compactMap { k, v in deref(k).map { ($0, deref(v)) } }
    }

    /// Every plain string stored in the archive (cheap way to find URLs / identifiers).
    var allStrings: [String] { objects.compactMap { $0.string } }

    /// The coordinates of an archived `CLCircularRegion`.
    func circularRegion(_ value: PlistValue?) -> (latitude: Double, longitude: Double, radius: Double, identifier: String?)? {
        guard let object = deref(value),
              let lat = object["kCLCircularRegionCodingKeyCenterLatitude"]?.double,
              let lon = object["kCLCircularRegionCodingKeyCenterLongitude"]?.double else { return nil }
        let radius = object["kCLCircularRegionCodingKeyRadius"]?.double ?? 0
        return (lat, lon, radius, string(object["kCLRegionCodingKeyIdentifier"]))
    }
}

// MARK: - Formatting helpers

enum EnvFormat {
    /// "OpenEventDetailsIntent" → "Open Event Details".
    static func humanize(_ identifier: String) -> String {
        var name = identifier
        for suffix in ["Intent", "Action"] where name.count > suffix.count + 2 && name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        if name.hasPrefix("IN"), name.count > 3, name.dropFirst(2).first?.isUppercase == true { name.removeFirst(2) }
        var out = ""
        var previous: Character?
        for ch in name {
            if ch.isUppercase, let p = previous, p.isLowercase || p.isNumber { out.append(" ") }
            out.append(ch == "_" ? " " : ch)
            previous = ch
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// 48-bit BSSID stored as an integer → "aa:bb:cc:dd:ee:ff".
    static func mac(_ value: Int64) -> String {
        (0..<6).reversed().map { String(format: "%02x", (value >> (Int64($0) * 8)) & 0xff) }.joined(separator: ":")
    }

    /// "aabbccddeeff" → "aa:bb:cc:dd:ee:ff".
    static func mac(hex: String) -> String {
        guard hex.count == 12, !hex.contains(":") else { return hex }
        var parts: [String] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            parts.append(String(hex[i..<j]))
            i = j
        }
        return parts.joined(separator: ":")
    }

    /// Last path component of a bundle identifier, for compact chart labels.
    static func shortBundle(_ bundle: String) -> String {
        var b = bundle
        if let r = b.range(of: "_SYSTEM_CENTER_:") { b.removeSubrange(r) }
        let parts = b.split(separator: ".")
        guard parts.count > 2 else { return b }
        let last = String(parts.last!)
        return last.count <= 3 && parts.count > 3 ? parts.suffix(2).joined(separator: ".") : last
    }

    /// Bundle identifier without the notification system's "_SYSTEM_CENTER_:" prefix.
    static func bundleID(_ raw: String) -> String {
        var b = raw
        if let r = b.range(of: "_SYSTEM_CENTER_:") { b.removeSubrange(r) }
        return b
    }

    /// App name for a bundle identifier (shared `AppDirectory`); values that are not
    /// bundle identifiers (tool paths, "(unknown)", plain names) are returned unchanged.
    static func appName(_ raw: String) -> String {
        let bundle = bundleID(raw)
        guard !bundle.isEmpty else { return "" }
        guard bundle.contains("."), !bundle.contains("/"), !bundle.contains(" ") else { return bundle }
        return AppDirectory.name(bundle)
    }

    /// Distinct display names for a list of bundle identifiers (chart categories): apps
    /// that share a name get the last identifier component appended.
    static func appNames(_ bundles: [String]) -> [String: String] {
        var names: [String: String] = [:]
        for b in bundles { names[b] = appName(b) }
        let clashes = Dictionary(grouping: bundles, by: { names[$0] ?? $0 }).filter { Set($0.value).count > 1 }
        for (_, group) in clashes {
            for b in Set(group) { names[b] = (names[b] ?? b) + " (" + shortBundle(b) + ")" }
        }
        return names
    }

    /// "macos.27_2.<build>.<model>.2" → (device "Mac", system "macOS 27.2").
    static func addedBy(_ version: String) -> String {
        let parts = version.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return version }
        let model = parts.count >= 4 ? parts[3].lowercased() : ""
        let number = parts[1].replacingOccurrences(of: "_", with: ".")
        let device: String
        if model.hasPrefix("iphone") { device = "iPhone" }
        else if model.hasPrefix("ipad") { device = "iPad" }
        else if model.hasPrefix("ipod") { device = "iPod touch" }
        else if model.hasPrefix("watch") { device = "Apple Watch" }
        else if model.hasPrefix("appletv") { device = "Apple TV" }
        else if model.hasPrefix("realitydevice") { device = "Apple Vision" }
        else if model.contains("mac") { device = "Mac" }
        else { device = "" }
        let system: String
        switch parts[0].lowercased() {
        case "macos": system = "macOS"
        case "iphoneos": system = device == "iPad" ? "iPadOS" : "iOS"
        case "watchos": system = "watchOS"
        case "appletvos", "tvos": system = "tvOS"
        case "xros": system = "visionOS"
        default: system = parts[0]
        }
        return (device.isEmpty ? "" : device + " · ") + system + " " + number
    }

    static func coordinate(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.5f, %.5f", lat, lon)
    }

    static func oneLine(_ text: String, max: Int = 160) -> String { Format.oneLine(text, max: max) }

    /// Wi-Fi band from a channel number (2.4 GHz channels are 1–14).
    static func band(channel: Int) -> String {
        if channel <= 0 { return "—" }
        return channel <= 14 ? "2.4 GHz" : "5 GHz"
    }

    /// Bluetooth SIG company identifiers that show up most often.
    static func bluetoothVendor(_ id: Int) -> String {
        switch id {
        case 0: return "—"
        case 76: return "Apple"
        case 6: return "Microsoft"
        case 10: return "Qualcomm (CSR)"
        case 117: return "Samsung"
        case 158: return "Bose"
        case 224: return "Google"
        case 301: return "Sony"
        default: return "Company \(id)"
        }
    }
}

/// Human-readable names for Biome / CoreDuet device identifiers (the shared
/// `BiomeDeviceNamer`: never shows any part of the identifier).
///
/// One label per device for the whole module, built once per refresh:
/// - devices listed in `sync.db` get the shared namer's label, with "iPhone / iPad"
///   narrowed when knowledgeC knows which of the two the owner has;
/// - devices that are not (or no longer) listed but still have stream data are called
///   "Unlisted <platform>", the platform being guessed from the bundle ids of their
///   `App.InFocus` records (the wording and heuristic Activity › Timeline uses);
/// - everything else (sync sites without data) keeps the shared namer's numbered
///   "Unknown device N", numbered like Biome › Device Sync.
struct DeviceNamer: Sendable {
    let namer: BiomeDeviceNamer
    /// Labels for unlisted devices whose platform could be inferred.
    var unlisted: [String: String] = [:]
    /// Inferred platform of those devices ("Apple Watch", "Mac", …).
    var unlistedPlatform: [String: String] = [:]
    /// "iPhone" or "iPad" when the owner's iOS-family device is known to be that.
    var handheld: String?
    var peers: [String: BiomeDevicePeer] { namer.peers }

    static func load() async -> DeviceNamer {
        if let cached = try? await EnvCache.shared.value("deviceNamer", { await build() }) { return cached }
        return DeviceNamer(namer: await BiomeDeviceNamer.load())
    }

    func name(_ device: BiomeDevice) -> String {
        switch device {
        case .local: return "This Mac"
        case .remote(let id): return name(identifier: id)
        }
    }

    func name(identifier id: String) -> String {
        if let label = unlisted[id] ?? unlisted[id.uppercased()] { return label }
        return refine(namer.label(identifier: id))
    }

    /// Platform name with "iPhone / iPad" narrowed where possible.
    func refine(_ text: String) -> String {
        guard let handheld else { return text }
        return text.replacingOccurrences(of: "iPhone / iPad", with: handheld)
    }

    private static func build() async -> DeviceNamer {
        let peers = await Biome.devicePeers()
        var withData = Set<String>()
        for stream in Biome.discoverAllStreams() {
            for segment in stream.dataSegments() {
                if let id = segment.device.identifier { withData.insert(id) }
            }
        }
        var sites: [String] = []
        if let db = await SQLiteDB.sharedIfAvailable(Paths.biomeSyncDB), await db.hasColumns("CRDTLocation", ["site"]) {
            sites = ((try? await db.rows("SELECT DISTINCT site FROM CRDTLocation LIMIT 5000")) ?? []).compactMap { $0[0].string }
        }
        var out = DeviceNamer(namer: BiomeDeviceNamer(peers: peers, identifiers: Array(withData), others: sites))

        var byPlatform: [String: [String]] = [:]
        for id in withData.sorted() where peers[id] == nil {
            if let platform = inferPlatform(.remote(id)) {
                out.unlistedPlatform[id] = platform
                byPlatform[platform, default: []].append(id)
            }
        }
        for (platform, ids) in byPlatform {
            for (i, id) in ids.enumerated() {
                out.unlisted[id] = ids.count == 1 ? "Unlisted \(platform)" : "Unlisted \(platform) (\(i + 1))"
            }
        }

        // sync.db only says "iOS family"; knowledgeC's sync peers carry hardware models.
        if peers.values.filter({ $0.platform == 2 }).count == 1, let db = await KnowledgeSource.db() {
            let models = await KnowledgeSource.deviceModels(db).values
            let phones = models.contains { $0.hasPrefix("iPhone") }, pads = models.contains { $0.hasPrefix("iPad") }
            if phones != pads { out.handheld = phones ? "iPhone" : "iPad" }
        }
        return out
    }

    /// Guesses the platform of a device missing from `DevicePeer` from the bundle ids
    /// (field 6) of its newest `App.InFocus` records. Nil when it has no such records.
    private static func inferPlatform(_ device: BiomeDevice) -> String? {
        guard let stream = Biome.stream(named: "App.InFocus") else { return nil }
        var mac = 0, ios = 0, watch = 0, tv = 0, n = 0
        BiomeStreamReader(stream).forEach(device: device, order: .newestFirst) { record in
            var bundle = ""
            FastProto.scan(record.payload) { field, value in
                if field == 6, case .bytes(let r) = value { bundle = FastProto.string(r) }
            }
            if bundle.hasPrefix("com.apple.springboard") || bundle.hasPrefix("com.apple.mobile") || bundle == "com.apple.Preferences" { ios += 1 }
            if ["com.apple.finder", "com.apple.loginwindow", "com.apple.dock", "com.apple.systempreferences", "com.apple.Terminal", "com.apple.Safari"].contains(bundle) { mac += 1 }
            if bundle == "com.apple.Carousel" || bundle.hasPrefix("com.apple.Nano") || bundle.contains(".watchkitapp") { watch += 1 }
            if bundle == "com.apple.PineBoard" || bundle == "com.apple.HeadBoard" || bundle.hasPrefix("com.apple.TV") { tv += 1 }
            n += 1
            return n < 600
        }
        guard n > 0 else { return nil }
        let best = max(mac, ios, watch, tv)
        if best == 0 { return "Device" }
        if best == watch { return "Apple Watch" }
        if best == tv { return "Apple TV" }
        return best == mac ? "Mac" : "iPhone / iPad"
    }
}

// MARK: - Shared view pieces

/// A short explanatory paragraph ("what is this store").
struct Explainer: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Inspector block that lazily fetches and shows the raw record behind a row.
struct RawRecordView: View {
    let ref: RawRef
    var title: String = "Record"
    var sensitivity: Sensitivity = .sensitive
    var height: CGFloat = 320

    var body: some View {
        AsyncContent(reloadKey: ref, emptyTitle: "No Raw Record", emptySymbol: "doc") {
            await ref.load() ?? Data()
        } isEmpty: { $0.isEmpty } content: { data in
            BlobInspector(data: data, title: title, sensitivity: sensitivity)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

extension Array where Element == KV {
    func items(sensitivity: Sensitivity = .personal) -> [KeyValueItem] {
        enumerated().map { KeyValueItem($0.element.key, $0.element.value, sensitivity: sensitivity, id: "\($0.offset)-\($0.element.key)") }
    }
}

/// Process-wide memo of loaded data sets, dropped when the user refreshes.
actor EnvCache {
    static let shared = EnvCache()
    private var token = 0
    private var tasks: [String: Any] = [:]

    func sync(token: Int) {
        if token != self.token {
            self.token = token
            tasks = [:]
        }
    }

    func value<T: Sendable>(_ key: String, _ make: @escaping @Sendable () async throws -> T) async throws -> T {
        if let existing = tasks[key] as? Task<T, Error> { return try await existing.value }
        let task = Task.detached(priority: .userInitiated) { try await make() }
        tasks[key] = task
        do {
            return try await task.value
        } catch {
            tasks[key] = nil
            throw error
        }
    }
}

/// Simple wall-clock timer for the self-test.
struct Stopwatch {
    private let start = DispatchTime.now()
    var ms: Int { Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000) }
}
