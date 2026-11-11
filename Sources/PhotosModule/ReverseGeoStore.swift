import Foundation
import DossierCore

// Per-asset reverse-geocode archives: ZADDITIONALASSETATTRIBUTES.ZREVERSELOCATIONDATA.
//
// Each blob is an NSKeyedArchiver graph (about 2 KB) of a PLRevGeoLocationInfo:
//   addressString   one-line postal address
//   countryCode     ISO country code
//   isHome          Photos' own judgement that the photo was taken at the owner's home
//   postalAddress   CNPostalAddress: _street, _subLocality, _city, _postalCode, _state, _country, …
//   mapItem         PLRevGeoMapItem: sortedPlaceInfos = [{ name, placeType, area }] from the
//                   smallest named place (street) up to the country
// Blobs are decoded per table page and for the selected row; the only pass over all of them is
// `ReverseGeoCache.index`, which runs in the background, chunked and cancellable.

/// One decoded archive.
struct ReverseGeoInfo: Sendable {
    struct Place: Sendable, Identifiable {
        let id: Int
        let name: String
        /// PLRevGeoPlaceInfo.placeType — an integer level (1 is the country, larger is finer).
        let level: Int?
        /// Area of the named place in m², 0 for point-like places.
        let area: Double?
    }

    var address = ""
    var countryCode = ""
    var isHome = false
    var provider = ""
    var version: Int?
    var street = ""
    /// Postal address components in archive order: (label, value).
    var postal: [(label: String, value: String)] = []
    var places: [Place] = []

    /// One line for table cells: the stored address string, else the postal components.
    var line: String {
        let text = address.isEmpty ? postal.map(\.value).joined(separator: ", ") : address
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func decode(_ data: Data) -> ReverseGeoInfo? {
        guard let root = PlistDecoder.decodeAny(data), root.dict != nil else { return nil }
        var info = ReverseGeoInfo()
        info.address = root["addressString"]?.string ?? ""
        info.countryCode = root["countryCode"]?.string ?? ""
        info.isHome = root["isHome"]?.bool ?? false
        info.provider = root["geoServiceProvider"]?.string ?? ""
        info.version = root["version"]?.int.map(Int.init)
        if let postal = root["postalAddress"]?.dict {
            for (key, value) in postal where key.hasPrefix("_") {
                guard let text = value.string, !text.isEmpty else { continue }
                if key == "_street" { info.street = text }
                info.postal.append((label: Self.label(key), value: text))
            }
        }
        let item = root["mapItem"]
        let list = item?["sortedPlaceInfos"]?.array ?? item?["finalPlaceInfos"]?.array ?? []
        for (index, place) in list.enumerated() {
            guard let name = place["name"]?.string, !name.isEmpty else { continue }
            info.places.append(Place(id: index, name: name, level: place["placeType"]?.int.map(Int.init), area: place["area"]?.double))
        }
        return info
    }

    /// "_subAdministrativeArea" → "Sub administrative area"
    private static func label(_ key: String) -> String {
        let name = String(key.dropFirst())
        if name == "ISOCountryCode" { return "ISO country code" }
        let spaced = GraphInferences.spaced(name).lowercased()
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

/// One asset with a reverse-geocode archive (table row; the blob itself is not kept).
struct AssetAddressRow: Sendable, Identifiable, Hashable {
    let id: Int64
    let date: Date?
    let latitude: Double?
    let longitude: Double?
    let address: String
    let countryCode: String
    let isHome: Bool
    /// False when the archive could not be decoded.
    let decoded: Bool
    /// ZREVERSELOCATIONDATAISVALID
    let valid: Bool?
    let uuid: String

    var coordinates: String {
        guard let latitude, let longitude else { return "—" }
        return String(format: "%.5f, %.5f", latitude, longitude)
    }
}

/// Result of the one pass over every archive.
struct ReverseGeoIndex: Sendable {
    var total = 0
    var decoded = 0
    /// Archives whose postal address has a street.
    var withStreet = 0
    /// ZASSET primary keys Photos flagged as taken at home.
    var home: [Int64] = []
    /// ZASSET primary key → one-line address (for the filter field).
    var addresses: [Int64: String] = [:]
    var seconds = 0.0
}

enum ReverseGeoStore {
    static func available(_ db: SQLiteDB) async -> Bool {
        let hasBlob = await db.hasColumns("ZADDITIONALASSETATTRIBUTES", ["ZREVERSELOCATIONDATA", "ZASSET"])
        let hasAsset = await db.hasColumns("ZASSET", ["Z_PK", "ZDATECREATED"])
        return hasBlob && hasAsset
    }

    /// Assets that carry an archive (index-only; nothing is decoded).
    static func archiveCount(_ lib: PhotosLibrary) async -> Int? {
        guard let db = try? await lib.photos(), await available(db) else { return nil }
        return await db.count("SELECT count(*) FROM ZADDITIONALASSETATTRIBUTES WHERE ZREVERSELOCATIONDATA IS NOT NULL")
    }

    /// One page, newest first by default. Keyset paging on (ZDATECREATED, Z_PK) — the date index
    /// Core Data keeps on ZASSET drives the order, so no page ever sorts the table. Only this
    /// page's archives are decoded.
    ///
    /// - Parameter only: restrict to these asset keys (at-home filter, address search); nil = all.
    static func rows(_ lib: PhotosLibrary, only: [Int64]?, request: PageRequest) async throws -> [AssetAddressRow] {
        let db = try await lib.photos()
        guard await available(db) else {
            throw DossierError.missing("This library has no ZREVERSELOCATIONDATA column: reverse-geocoded addresses are not stored per asset on this macOS version.")
        }
        if let only, only.isEmpty { return [] }
        let a = await db.existing("ZASSET", ["ZLATITUDE", "ZLONGITUDE", "ZUUID"])
        let x = await db.existing("ZADDITIONALASSETATTRIBUTES", ["ZREVERSELOCATIONDATAISVALID"])
        let ascending = request.sort?.columnID == "ZDATECREATED" && request.sort?.ascending == true
        var clauses = ["x.ZREVERSELOCATIONDATA IS NOT NULL", "a.ZDATECREATED IS NOT NULL"]
        var params: [SQLValue] = []
        if let only { clauses.append("a.Z_PK IN (\(only.map(String.init).joined(separator: ",")))") }
        if let cursor = request.cursor?.base as? Int64 {
            clauses.append("(a.ZDATECREATED, a.Z_PK) \(ascending ? ">" : "<") (SELECT ZDATECREATED, Z_PK FROM ZASSET WHERE Z_PK = ?)")
            params.append(.integer(cursor))
        }
        let direction = ascending ? "ASC" : "DESC"
        let sql = """
            SELECT a.Z_PK, a.ZDATECREATED, \(sqlColumn(a, "ZLATITUDE", prefix: "a.")), \(sqlColumn(a, "ZLONGITUDE", prefix: "a.")), x.ZREVERSELOCATIONDATA,
                   \(sqlColumn(x, "ZREVERSELOCATIONDATAISVALID", prefix: "x.")), \(sqlColumn(a, "ZUUID", prefix: "a.", fallback: "''"))
            FROM ZASSET a JOIN ZADDITIONALASSETATTRIBUTES x ON x.ZASSET = a.Z_PK
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY a.ZDATECREATED \(direction), a.Z_PK \(direction) LIMIT ?
            """
        params.append(.integer(Int64(request.limit)))
        return try await db.rows(sql, params).map { row in
            let info = row[4].data.flatMap(ReverseGeoInfo.decode)
            let lat = row[2].double, lon = row[3].double
            let located = lat.map { (-90...90).contains($0) } == true && lon.map { (-180...180).contains($0) } == true && !(lat == 0 && lon == 0)
            return AssetAddressRow(id: row[0].int ?? 0, date: row[1].cocoaDate, latitude: located ? lat : nil, longitude: located ? lon : nil,
                                   address: info?.line ?? "", countryCode: info?.countryCode ?? "", isHome: info?.isHome ?? false, decoded: info != nil,
                                   valid: row[5].int.map { $0 != 0 }, uuid: row[6].string ?? "")
        }
    }

    /// The full archive of one asset, for the inspector.
    static func info(_ lib: PhotosLibrary, asset: Int64) async throws -> (info: ReverseGeoInfo?, bytes: Int) {
        let db = try await lib.photos()
        guard await available(db) else { return (nil, 0) }
        guard let data = try await db.first("SELECT ZREVERSELOCATIONDATA FROM ZADDITIONALASSETATTRIBUTES WHERE ZASSET = ? AND ZREVERSELOCATIONDATA IS NOT NULL LIMIT 1", [.integer(asset)])?[0].data else { return (nil, 0) }
        return (ReverseGeoInfo.decode(data), data.count)
    }

    /// Runs `each(asset, archive)` over every archive. Chunked by primary key so that other
    /// queries on Photos.sqlite interleave, checked for cancellation between chunks, and the
    /// per-row work happens off the database queue.
    private static func forEachArchive(_ lib: PhotosLibrary, progress: @escaping @Sendable (Int, Int) -> Void, each: (Int64, Data) -> Void) async throws -> Int {
        let db = try await lib.photos()
        guard await available(db) else { return 0 }
        let total = await db.count("SELECT count(*) FROM ZADDITIONALASSETATTRIBUTES WHERE ZREVERSELOCATIONDATA IS NOT NULL") ?? 0
        var last: Int64 = 0
        var seen = 0
        progress(0, total)
        while true {
            try Task.checkCancellation()
            let rows = try await db.rows("SELECT Z_PK, ZASSET, ZREVERSELOCATIONDATA FROM ZADDITIONALASSETATTRIBUTES WHERE Z_PK > ? AND ZREVERSELOCATIONDATA IS NOT NULL ORDER BY Z_PK LIMIT 1000", [.integer(last)])
            guard let pk = rows.last?[0].int else { break }
            last = pk
            for row in rows {
                if let asset = row[1].int, let data = row[2].data { each(asset, data) }
            }
            seen += rows.count
            progress(seen, max(total, seen))
            if rows.count < 1000 { break }
        }
        return seen
    }

    /// Which assets Photos flagged as taken at home. Reads only the `isHome` boolean of each
    /// archive (`KeyedArchiveProbe`), without building the object graph — a fraction of a second
    /// for tens of thousands of archives.
    static func buildHomeFlags(_ lib: PhotosLibrary, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> HomeFlags {
        var flags = HomeFlags()
        let start = Date()
        flags.total = try await forEachArchive(lib, progress: progress) { asset, data in
            guard let home = KeyedArchiveProbe.rootBool(data, key: "isHome") else { return }
            flags.checked += 1
            if home { flags.home.append(asset) }
        }
        flags.seconds = Date().timeIntervalSince(start)
        return flags
    }

    /// Decodes every archive once into a one-line address per asset, for the filter field.
    static func buildIndex(_ lib: PhotosLibrary, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> ReverseGeoIndex {
        var index = ReverseGeoIndex()
        let start = Date()
        index.total = try await forEachArchive(lib, progress: progress) { asset, data in
            guard let info = ReverseGeoInfo.decode(data) else { return }
            index.decoded += 1
            if !info.street.isEmpty { index.withStreet += 1 }
            if info.isHome { index.home.append(asset) }
            let line = info.line
            if !line.isEmpty { index.addresses[asset] = line }
        }
        index.seconds = Date().timeIntervalSince(start)
        return index
    }
}

/// Result of the quick pass over the `isHome` flags.
struct HomeFlags: Sendable {
    var total = 0
    /// Archives whose flag could be read.
    var checked = 0
    /// ZASSET primary keys flagged as taken at home.
    var home: [Int64] = []
    var seconds = 0.0
}

/// Reads one boolean of an NSKeyedArchiver root object straight from the binary plist, without
/// materialising the archive: trailer → top dictionary → `$top.root` UID → `$objects[uid]` →
/// value of `key`. Returns nil for anything that is not a well-formed keyed archive with that key.
enum KeyedArchiveProbe {
    static func rootBool(_ data: Data, key: String) -> Bool? {
        data.withUnsafeBytes { raw -> Bool? in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            guard n > 40, p[0] == 0x62, p[1] == 0x70, p[2] == 0x6C, p[3] == 0x69, p[4] == 0x73, p[5] == 0x74 else { return nil }   // "bplist"
            func be(_ offset: Int, _ size: Int) -> Int? {
                guard size > 0, size <= 8, offset >= 0, offset + size <= n else { return nil }
                var v: UInt64 = 0
                for i in 0..<size { v = v << 8 | UInt64(p[offset + i]) }
                return v > UInt64(Int.max) ? nil : Int(v)
            }
            let trailer = n - 32
            let offsetSize = Int(p[trailer + 6]), refSize = Int(p[trailer + 7])
            guard let count = be(trailer + 8, 8), let top = be(trailer + 16, 8), let table = be(trailer + 24, 8),
                  (1...8).contains(offsetSize), (1...8).contains(refSize), count > 0, count < n, table < trailer else { return nil }
            func offset(_ object: Int) -> Int? {
                guard object >= 0, object < count, let o = be(table + object * offsetSize, offsetSize), o >= 8, o < trailer else { return nil }
                return o
            }
            /// Marker nibble count, following the int object when the nibble is 0xF. Returns (count, first byte after the header).
            func header(_ at: Int) -> (count: Int, body: Int)? {
                let low = Int(p[at] & 0x0F)
                if low != 0x0F { return (low, at + 1) }
                guard at + 1 < n, p[at + 1] & 0xF0 == 0x10 else { return nil }
                let size = 1 << Int(p[at + 1] & 0x0F)
                guard let c = be(at + 2, size) else { return nil }
                return (c, at + 2 + size)
            }
            func isASCII(_ object: Int, _ text: [UInt8]) -> Bool {
                guard let at = offset(object), p[at] & 0xF0 == 0x50, let h = header(at), h.count == text.count, h.body + h.count <= n else { return false }
                for i in 0..<text.count where p[h.body + i] != text[i] { return false }
                return true
            }
            /// Object number stored under `name` in the dictionary object `dict`.
            func value(_ dict: Int, _ name: String) -> Int? {
                guard let at = offset(dict), p[at] & 0xF0 == 0xD0, let h = header(at), h.count < 4096, h.body + 2 * h.count * refSize <= n else { return nil }
                let text = Array(name.utf8)
                for i in 0..<h.count {
                    guard let k = be(h.body + i * refSize, refSize) else { return nil }
                    if isASCII(k, text) { return be(h.body + (h.count + i) * refSize, refSize) }
                }
                return nil
            }
            guard let topDict = value(top, "$top"), let rootRef = value(topDict, "root"), let objects = value(top, "$objects"),
                  let uidAt = offset(rootRef), p[uidAt] & 0xF0 == 0x80, let uid = be(uidAt + 1, Int(p[uidAt] & 0x0F) + 1),
                  let arrayAt = offset(objects), p[arrayAt] & 0xF0 == 0xA0, let array = header(arrayAt), uid < array.count,
                  let rootObject = be(array.body + uid * refSize, refSize),
                  let flag = value(rootObject, key), let flagAt = offset(flag) else { return nil }
            switch p[flagAt] {
            case 0x09: return true
            case 0x08: return false
            default: return nil
            }
        }
    }
}

/// Holds the results per library and makes sure only one pass of each kind runs at a time.
actor ReverseGeoCache {
    static let shared = ReverseGeoCache()

    private enum Kind: String { case home, index }
    private var done: [String: any Sendable] = [:]
    private var running: [String: Task<any Sendable, Error>] = [:]
    private var progress: [String: (done: Int, total: Int)] = [:]

    private func key(_ lib: PhotosLibrary, _ kind: Kind) -> String { lib.id + "|" + kind.rawValue }

    /// Progress of a running address pass, nil when none is running.
    func indexProgress(_ lib: PhotosLibrary) -> (done: Int, total: Int)? {
        let k = key(lib, .index)
        return running[k] == nil ? nil : (progress[k] ?? (0, 0))
    }

    /// Assets flagged as taken at home (quick pass, cached).
    func homeFlags(_ lib: PhotosLibrary) async throws -> HomeFlags {
        try await shared(key(lib, .home)) { report in try await ReverseGeoStore.buildHomeFlags(lib, progress: report) }
    }

    /// One-line address per asset (full decode of every archive, cached). Several callers share one pass.
    func index(_ lib: PhotosLibrary) async throws -> ReverseGeoIndex {
        try await shared(key(lib, .index)) { report in try await ReverseGeoStore.buildIndex(lib, progress: report) }
    }

    private func shared<T: Sendable>(_ key: String, _ build: @escaping @Sendable (@escaping @Sendable (Int, Int) -> Void) async throws -> T) async throws -> T {
        if let cached = done[key] as? T { return cached }
        let task: Task<any Sendable, Error>
        if let existing = running[key] {
            task = existing
        } else {
            task = Task.detached(priority: .userInitiated) {
                try await build { done, total in
                    Task { await ReverseGeoCache.shared.report(key, done, total) }
                }
            }
            running[key] = task
        }
        do {
            let result = try await task.value
            if running[key] == task { running[key] = nil; progress[key] = nil; done[key] = result }
            guard let typed = result as? T else { throw CancellationError() }
            return typed
        } catch {
            if running[key] == task { running[key] = nil; progress[key] = nil }
            throw error
        }
    }

    private func report(_ key: String, _ done: Int, _ total: Int) {
        if running[key] != nil { progress[key] = (done, total) }
    }

    /// Stops a running address pass (the section went away); finished results are kept.
    func cancelIndex(_ lib: PhotosLibrary) {
        running[key(lib, .index)]?.cancel()
    }

    func reset() {
        for task in running.values { task.cancel() }
        running.removeAll(); progress.removeAll(); done.removeAll()
    }
}
