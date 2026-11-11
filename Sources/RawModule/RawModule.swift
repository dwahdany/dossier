import SwiftUI
import SQLite3
import DossierCore

/// Raw Explorer — the reference module. Guarantees completeness: every store, SQLite
/// database, Biome stream and stray file is browsable even where no curated view exists.
public final class RawModule: DossierModule {
    public let id = "raw"
    public let title = "Raw Explorer"
    public let symbol = "cylinder.split.1x2"
    public let group = SidebarGroup.raw

    public init() {}

    public var sections: [ModuleSection] {
        [
            ModuleSection(id: "raw.stores", title: "Stores", symbol: "externaldrive") { StoresSection() },
            ModuleSection(id: "raw.sqlite", title: "SQLite Explorer", symbol: "tablecells") { SQLiteSection() },
            ModuleSection(id: "raw.biome", title: "Biome Stream Explorer", symbol: "waveform.path.ecg") { BiomeSection() },
            ModuleSection(id: "raw.files", title: "Files & Plists", symbol: "doc.text.magnifyingglass") { FilesSection() },
        ]
    }

    // MARK: Summary

    public func summary() async -> ModuleSummary {
        async let rowsTask = RawCatalog.shared.storeRows()
        async let databasesTask = RawCatalog.shared.databases()
        async let streamsTask = RawCatalog.shared.streams()
        async let peersTask = RawCatalog.shared.devicePeers()
        let (rows, databases, streams, peers) = await (rowsTask, databasesTask, streamsTask, peersTask)

        let biome = streams.filter { $0.origin.hasPrefix("Biome") }
        let other = streams.filter { !$0.origin.hasPrefix("Biome") }
        let dbCounts = Dictionary(grouping: databases, by: \.storeID).mapValues(\.count)
        let stores = rows.map { row -> StoreInfo in
            var info = StoreInfo(
                name: row.store.title, path: row.store.url,
                sizeBytes: row.availability.isAvailable ? row.bytes : nil,
                availability: row.availability,
                note: dbCounts[row.store.id].map { "\($0) database\($0 == 1 ? "" : "s")" }
            )
            if row.store.id == "biome.streams" {
                info.rowCount = biome.reduce(0) { $0 + $1.stats.records }
                let ranges = biome.compactMap(\.stats.timeRange)
                if let lo = ranges.map(\.lowerBound).min(), let hi = ranges.map(\.upperBound).max() { info.timeRange = lo...hi }
            }
            return info
        }

        // "Biome" facts cover ~/Library/Biome/streams only, so they agree with the Streams
        // module; SEGB streams kept elsewhere (Duet Expert, daemon containers) are separate.
        let records = biome.reduce(0) { $0 + $1.stats.records }
        let active = biome.filter { $0.stats.records > 0 }.count
        let remote = Set(biome.flatMap { $0.stream.devices.compactMap(\.identifier) })
        var facts: [Fact] = [
            Fact("SQLite databases found", Format.count(databases.count), sensitivity: .low, symbol: "cylinder.split.1x2", sectionID: "raw.sqlite"),
            Fact("Biome streams with data", "\(active) of \(biome.count)", sensitivity: .low, symbol: "waveform.path.ecg", sectionID: "raw.biome"),
            Fact("Biome event records", Format.count(records), sensitivity: .personal, symbol: "list.bullet.rectangle", sectionID: "raw.biome"),
        ]
        if !other.isEmpty {
            let otherActive = other.filter { $0.stats.records > 0 }.count
            let otherRecords = other.reduce(0) { $0 + $1.stats.records }
            facts.append(Fact(
                "Other SEGB streams (Duet Expert, app daemons)",
                "\(otherActive) of \(other.count) with data, \(Format.count(otherRecords)) records",
                sensitivity: .low, symbol: "waveform", sectionID: "raw.biome"
            ))
        }
        if !remote.isEmpty {
            // Devices with data here that sync.db's DevicePeer table does not list cannot
            // be named from this module; say so instead of implying the listed platforms
            // cover all of them.
            let names = Set(remote.compactMap { peers[$0]?.displayName }).sorted()
            let unlisted = remote.filter { peers[$0] == nil }.count
            let parts = names + (unlisted > 0 ? ["\(unlisted) not listed in sync.db"] : [])
            facts.append(Fact(
                "Other devices syncing activity to this Mac",
                parts.isEmpty ? "\(remote.count)" : "\(remote.count) (\(parts.joined(separator: ", ")))",
                sensitivity: .personal, symbol: "laptopcomputer.and.iphone", sectionID: "raw.biome"
            ))
        }
        return ModuleSummary(stores: stores, facts: facts)
    }

    // MARK: Search

    public func search(_ query: String, limit: Int) async -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return [] }
        var hits: [SearchHit] = []

        for entry in await RawCatalog.shared.streams() where entry.stream.name.localizedCaseInsensitiveContains(needle) {
            hits.append(SearchHit(
                title: entry.stream.name,
                subtitle: "Biome stream · \(Format.count(entry.stats.records)) records · \(entry.origin)",
                moduleID: id, sectionID: "raw.biome", payload: entry.id, symbol: "waveform.path.ecg", sensitivity: .low
            ))
            if hits.count >= limit { return hits }
        }
        if Task.isCancelled { return hits }
        for db in await RawCatalog.shared.databases() where db.name.localizedCaseInsensitiveContains(needle) || db.folder.localizedCaseInsensitiveContains(needle) {
            hits.append(SearchHit(
                title: db.name,
                subtitle: "SQLite database · \(db.storeTitle)\(db.folder.isEmpty ? "" : " › " + db.folder) · \(Format.bytes(db.size))",
                moduleID: id, sectionID: "raw.sqlite", payload: db.url.path, symbol: "cylinder", sensitivity: .low
            ))
            if hits.count >= limit { return hits }
        }
        if Task.isCancelled { return hits }
        for (db, tables) in await RawCatalog.shared.tableIndex() {
            for table in tables where table.localizedCaseInsensitiveContains(needle) {
                hits.append(SearchHit(
                    title: table,
                    subtitle: "Table in \(db.name) · \(db.storeTitle)",
                    moduleID: id, sectionID: "raw.sqlite", payload: db.url.path + "\t" + table, symbol: "tablecells", sensitivity: .low
                ))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    // MARK: Self-test

    public func selfTest() async -> [SelfTestLine] {
        var lines: [SelfTestLine] = []

        // Access.
        lines.append(Paths.hasFullDiskAccess() ? .pass("Full Disk Access", "protected stores are readable") : .warn("Full Disk Access", "not granted — most stores will be inaccessible"))
        let rows = await RawCatalog.shared.storeRows()
        let available = rows.filter { $0.availability.isAvailable }
        lines.append(.check("Known stores", !available.isEmpty, "\(available.count) of \(rows.count) readable, \(Format.bytes(available.reduce(Int64(0)) { $0 + $1.bytes }))"))
        for row in rows where !row.availability.isAvailable {
            lines.append(.info("  " + row.store.title, row.availability.label))
        }

        // SQLite: open every discovered database read-only and read its schema.
        let databases = await RawCatalog.shared.databases()
        var opened = 0, tables = 0, immutable = 0
        var failures: [String] = []
        for entry in databases {
            do {
                let db = try SQLiteDB(path: entry.url.path)
                tables += try await db.tables(includeViews: true).count
                if db.isImmutableFallback { immutable += 1 }
                opened += 1
            } catch {
                failures.append("\(entry.name): \(error.localizedDescription)")
            }
        }
        lines.append(SelfTestLine(databases.isEmpty ? .warn : (opened > 0 ? .pass : .fail), "SQLite discovery", "\(databases.count) databases, \(opened) opened read-only (\(immutable) via immutable fallback), \(Format.count(tables)) tables/views"))
        for failure in failures.prefix(8) { lines.append(.warn("  cannot open", failure)) }
        if failures.count > 8 { lines.append(.warn("  cannot open", "… and \(failures.count - 8) more")) }

        lines.append(contentsOf: await RawModule.readOnlyEnforcementTest())

        // SEGB: parse every segment, verify CRCs of all live records.
        let streams = await RawCatalog.shared.streams()
        var segments = 0, live = 0, deleted = 0, crcOK = 0, crcChecked = 0, decodable = 0
        var versions = Set<Int>()
        for entry in streams {
            for segment in entry.stream.dataSegments() {
                guard let file = try? SEGBFile(url: segment.url) else { continue }
                segments += 1
                versions.insert(file.version.rawValue)
                for e in file.entries {
                    if !e.state.isLive { deleted += 1; continue }
                    live += 1
                    crcChecked += 1
                    let payload = file.payload(e)
                    if CRC32.checksum(payload) == e.crc { crcOK += 1 }
                    if ProtoMessage(payload) != nil { decodable += 1 }
                }
            }
        }
        lines.append(SelfTestLine(streams.isEmpty ? .warn : .pass, "Biome streams", "\(streams.count) streams, \(segments) segments, format v\(versions.sorted().map(String.init).joined(separator: "/v"))"))
        if crcChecked > 0 {
            lines.append(.check("SEGB record framing", crcOK == crcChecked, "\(Format.count(live)) live + \(Format.count(deleted)) deleted records; CRC-32 valid for \(Format.count(crcOK)) of \(Format.count(crcChecked))"))
            lines.append(.check("Protobuf decoder", Double(decodable) >= Double(live) * 0.9, "\(Format.count(decodable)) of \(Format.count(live)) payloads parse as protobuf"))
        }

        lines.append(contentsOf: RawModule.syntheticDecoderTests())
        lines.append(contentsOf: await RawModule.verificationDump(streams: streams))
        return lines
    }

    /// Extra output for cross-checking against independent tools, enabled by environment:
    /// * `DOSSIER_RAW_VERIFY_STREAMS=Name1,Name2` — per-device live/deleted record counts
    ///   (remote devices are numbered in identifier order, identifiers are not printed).
    /// * `DOSSIER_RAW_VERIFY_DB=<path>` — per-table row counts as the SQLite explorer
    ///   computes them, plus the first-page row ids of the largest table.
    private static func verificationDump(streams: [StreamEntry]) async -> [SelfTestLine] {
        var lines: [SelfTestLine] = []
        let env = ProcessInfo.processInfo.environment
        if let names = env["DOSSIER_RAW_VERIFY_STREAMS"]?.split(separator: ",").map(String.init) {
            for name in names {
                guard let entry = streams.first(where: { $0.stream.name == name }) else {
                    lines.append(.warn("verify stream \(name)", "not found")); continue
                }
                let devices = entry.stream.devices.sorted { ($0.identifier ?? "") < ($1.identifier ?? "") }
                var remoteIndex = 0
                for device in devices {
                    let label: String
                    if device.isLocal { label = "local" } else { label = "remote[\(remoteIndex)]"; remoteIndex += 1 }
                    let stats = BiomeStreamReader(entry.stream).stats(device: device)
                    lines.append(.info("verify stream \(name) \(label)", RawModule.verifyLine(stats)))
                }
            }
        }
        // * `DOSSIER_RAW_VERIFY_SEGB_FILE=<path>` — the same figures for one segment file.
        if let path = env["DOSSIER_RAW_VERIFY_SEGB_FILE"] {
            let url = URL(fileURLWithPath: path)
            let segment = BiomeSegment(url: url, device: .local, size: FileProbe.info(url)?.size ?? 0, modified: nil, isTombstone: false)
            let stream = BiomeStream(name: url.lastPathComponent, url: url.deletingLastPathComponent(), segments: [segment])
            let stats = BiomeStreamReader(stream).stats()
            lines.append(.info("verify segb file", RawModule.verifyLine(stats) + " version=v\(stats.versions.sorted().map(String.init).joined(separator: ","))"))
        }
        if let path = env["DOSSIER_RAW_VERIFY_DB"], let db = try? await SQLiteDB.shared(path) {
            var largest: (String, Int) = ("", -1)
            for table in ((try? await db.tables()) ?? []).sorted() {
                let n = await db.rowCount(of: table) ?? -1
                lines.append(.info("verify table \(table)", "\(n)"))
                if n > largest.1 { largest = (table, n) }
            }
            if largest.1 > 0, let shape = try? await RawSQL.shape(dbPath: path, table: largest.0) {
                let first = (try? await RawSQL.page(shape, PageRequest(offset: 0, limit: 5))) ?? []
                let second = (try? await RawSQL.page(shape, PageRequest(offset: 5, limit: 5, cursor: first.last.map { AnyHashable($0.id) }))) ?? []
                let sorted = (try? await RawSQL.page(shape, PageRequest(offset: 0, limit: 5, sort: PageSort(columnID: shape.columns[0].name, ascending: false)))) ?? []
                lines.append(.info("verify page \(largest.0)", "rowids \((first + second).map { String($0.id) }.joined(separator: ",")) | desc by \(shape.columns[0].name): \(sorted.map { $0.values[0].description }.joined(separator: ","))"))
            }
        }
        return lines
    }

    /// Live / deleted counts and first / last record timestamps (seconds since 2001) — the
    /// figures an independent SEGB parser can reproduce.
    private static func verifyLine(_ stats: BiomeStreamReader.Stats) -> String {
        let first = stats.timeRange.map { String(format: "%.3f", $0.lowerBound.timeIntervalSinceReferenceDate) } ?? "-"
        let last = stats.timeRange.map { String(format: "%.3f", $0.upperBound.timeIntervalSinceReferenceDate) } ?? "-"
        return "live=\(stats.records) deleted=\(stats.deleted) segments=\(stats.segments) first=\(first) last=\(last)"
    }

    /// Creates a scratch database in the temporary directory (never a system store) and
    /// verifies that ``SQLiteDB`` refuses every kind of modification.
    private static func readOnlyEnforcementTest() async -> [SelfTestLine] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dossier-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("scratch.db").path
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else { return [.warn("Read-only enforcement", "could not create scratch database")] }
        sqlite3_exec(handle, "CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c BLOB); CREATE INDEX t_b ON t(b); INSERT INTO t(b, c) VALUES ('one', x'00ff'), ('two', NULL), ('three', x'62706c697374');", nil, nil, nil)
        sqlite3_close(handle)

        guard let db = try? SQLiteDB(path: path) else { return [.fail("Read-only enforcement", "could not reopen scratch database")] }
        var lines: [SelfTestLine] = []
        let n = await db.rowCount(of: "t")
        lines.append(.check("SQLite wrapper reads", n == 3, "scratch table has \(n ?? -1) rows; columns: \(await db.columns(of: "t").map(\.name).joined(separator: ","))"))
        let attempts = [
            "INSERT INTO t(b) VALUES ('x')", "UPDATE t SET b = 'x'", "DELETE FROM t", "DROP TABLE t",
            "CREATE TABLE u(a)", "ATTACH DATABASE '\(dir.path)/other.db' AS o", "PRAGMA journal_mode=DELETE",
            "PRAGMA query_only=OFF", "VACUUM",
            "CREATE INDEX i ON t(b)", "CREATE TEMP TABLE tmp(a)", "REINDEX", "ANALYZE",
            "WITH x(v) AS (SELECT 'y') INSERT INTO t(b) SELECT v FROM x",
            "PRAGMA wal_checkpoint(TRUNCATE)", "PRAGMA writable_schema=1", "PRAGMA user_version=5",
            "PRAGMA optimize", "PRAGMA incremental_vacuum", "BEGIN IMMEDIATE", "SELECT load_extension('x')",
        ]
        let before = try? Data(contentsOf: URL(fileURLWithPath: path))
        var blocked = 0
        var leaked: [String] = []
        for sql in attempts {
            do { _ = try await db.query(sql); leaked.append(sql) } catch { blocked += 1 }
        }
        let after = await db.rowCount(of: "t")
        let otherExists = FileManager.default.fileExists(atPath: dir.path + "/other.db")
        let unchanged = before != nil && before == (try? Data(contentsOf: URL(fileURLWithPath: path)))
        lines.append(.check("Read-only enforcement", leaked.isEmpty && after == 3 && !otherExists && unchanged, (unchanged ? "file bytes unchanged; " : "FILE CHANGED; ") + "\(blocked) of \(attempts.count) write statements rejected" + (leaked.isEmpty ? "" : "; NOT rejected: \(leaked.joined(separator: " | "))")))
        return lines
    }

    /// Decoder checks on synthetic data (no personal data involved).
    private static func syntheticDecoderTests() -> [SelfTestLine] {
        var lines: [SelfTestLine] = []

        // Protobuf: field 1 varint 150, field 2 string "testing", field 3 nested {1: 150}, field 4 double.
        var pb = Data([0x08, 0x96, 0x01, 0x12, 0x07] + Array("testing".utf8) + [0x1A, 0x03, 0x08, 0x96, 0x01, 0x21])
        withUnsafeBytes(of: (700_000_000.5).bitPattern.littleEndian) { pb.append(contentsOf: $0) }
        if let m = ProtoMessage(pb) {
            let ok = m[1]?.uint == 150 && m[2]?.string == "testing" && m.int(at: 3, 1) == 150 && m[4]?.double == 700_000_000.5 && m[4]?.cocoaDate != nil
            lines.append(.check("Protobuf synthetic message", ok, "\(m.fields.count) fields"))
        } else {
            lines.append(.fail("Protobuf synthetic message", "did not parse"))
        }
        lines.append(.check("Protobuf rejects garbage", ProtoMessage(Data([0xFF, 0xFF, 0xFF, 0x07, 0x03])) == nil))

        // Plists: binary round trip and NSKeyedArchiver resolution.
        let plist: [String: Any] = ["name": "value", "n": 42, "list": [1.5, true, Date(timeIntervalSinceReferenceDate: 1)], "blob": Data([1, 2, 3])]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0), let v = PlistDecoder.decodePlist(data) {
            let ok = v["name"]?.string == "value" && v["n"]?.int == 42 && v["list"]?[0]?.double == 1.5 && v["list"]?[1]?.bool == true && v["blob"]?.data == Data([1, 2, 3])
            lines.append(.check("Binary plist parser", ok))
        } else {
            lines.append(.fail("Binary plist parser", "did not parse"))
        }
        let object: NSDictionary = ["title": "hello" as NSString, "items": [1, 2, 3] as NSArray, "when": NSDate(timeIntervalSinceReferenceDate: 60), "url": NSURL(string: "https://example.com/a")!]
        if let archive = try? NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: false), let v = PlistDecoder.decodeAny(archive) {
            let ok = v["title"]?.string == "hello" && v["items"]?.array?.count == 3 && v["when"]?.date == Date(timeIntervalSinceReferenceDate: 60) && v["url"]?.string == "https://example.com/a"
            lines.append(.check("NSKeyedArchiver unarchiving", ok, BlobSniffer.sniff(archive).label))
        } else {
            lines.append(.fail("NSKeyedArchiver unarchiving", "did not decode"))
        }

        // SEGB v1 (legacy framing, not present on current macOS): synthetic file.
        let payloads = [Data("first".utf8), Data(), Data("third record".utf8)]
        var v1 = Data(count: 56)
        v1.replaceSubrange(52..<56, with: Array("SEGB".utf8))
        for (i, p) in payloads.enumerated() {
            let deleted = i == 1
            let body = deleted ? Data(count: 6) : p
            var header = Data()
            withUnsafeBytes(of: Int32(body.count).littleEndian) { header.append(contentsOf: $0) }
            withUnsafeBytes(of: Int32(deleted ? 3 : 1).littleEndian) { header.append(contentsOf: $0) }
            withUnsafeBytes(of: (700_000_000.0 + Double(i)).bitPattern.littleEndian) { header.append(contentsOf: $0) }
            withUnsafeBytes(of: (700_000_000.0 + Double(i)).bitPattern.littleEndian) { header.append(contentsOf: $0) }
            withUnsafeBytes(of: CRC32.checksum(body).littleEndian) { header.append(contentsOf: $0) }
            withUnsafeBytes(of: Int32(0).littleEndian) { header.append(contentsOf: $0) }
            v1.append(header)
            v1.append(body)
            while v1.count % 8 != 0 { v1.append(0) }
        }
        let end = UInt32(v1.count)
        withUnsafeBytes(of: end.littleEndian) { v1.replaceSubrange(0..<4, with: $0) }
        v1.append(Data(count: 256))   // preallocated tail
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dossier-selftest-\(UUID().uuidString).segb")
        defer { try? FileManager.default.removeItem(at: url) }
        if (try? v1.write(to: url)) != nil, let file = try? SEGBFile(url: url) {
            let live = Array(file.records())
            let ok = file.version == .v1 && file.entries.count == 3 && live.count == 2 && live.first?.payload == payloads[0] && live.last?.payload == payloads[2] && live.allSatisfy { file.crcMatches($0.entry) }
            lines.append(.check("SEGB v1 reader (synthetic file)", ok, "\(file.entries.count) records, \(live.count) live"))
        } else {
            lines.append(.fail("SEGB v1 reader (synthetic file)", "could not read"))
        }
        return lines
    }
}
