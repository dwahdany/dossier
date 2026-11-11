import Foundation
import DossierCore

/// A known store with measured size / availability.
struct StoreRow: Identifiable, Sendable, Hashable {
    var id: String { store.id }
    let store: KnownStore
    let availability: Availability
    let bytes: Int64
    let files: Int
    let newest: Date?
}

/// A discovered SQLite database.
struct DatabaseEntry: Identifiable, Sendable, Hashable {
    var id: String { url.path }
    let url: URL
    let storeID: String
    let storeTitle: String
    /// Path relative to the store root (directory part only).
    let folder: String
    let size: Int64
    let modified: Date?
    var name: String { url.lastPathComponent }
}

/// A discovered Biome stream with aggregate statistics.
struct StreamEntry: Identifiable, Sendable, Hashable {
    var id: String { stream.id }
    let stream: BiomeStream
    /// Label of the root the stream was found under ("Biome", "DuetExpertCenter", ...).
    let origin: String
    let stats: BiomeStreamReader.Stats
    let remoteDevices: Int
    let hasLocal: Bool
}

/// A stray file (plist, JSON, protobuf, ...) inside a known store.
struct FileEntry: Identifiable, Sendable, Hashable {
    var id: String { url.path }
    let url: URL
    let storeTitle: String
    let folder: String
    let size: Int64
    let modified: Date?
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }
}

/// Lazily discovers and caches what exists under the known store roots. All work happens
/// on the actor (off the main thread); results are cached until ``reset()``.
actor RawCatalog {
    static let shared = RawCatalog()

    private var storeRowsCache: [StoreRow]?
    private var databasesCache: [DatabaseEntry]?
    private var streamsCache: [StreamEntry]?
    private var filesCache: [FileEntry]?
    private var tableIndexCache: [(db: DatabaseEntry, tables: [String])]?
    private var peersCache: [String: BiomeDevicePeer]?

    private var lastToken = 0

    /// Drops all caches when the app's refresh token changed since the last call.
    func sync(token: Int) {
        if token != lastToken { lastToken = token; reset() }
    }

    func reset() {
        storeRowsCache = nil; databasesCache = nil; streamsCache = nil
        filesCache = nil; tableIndexCache = nil; peersCache = nil
    }

    // MARK: Stores

    func storeRows() async -> [StoreRow] {
        if let storeRowsCache { return storeRowsCache }
        let stores = Paths.knownStores()
        let rows = await withTaskGroup(of: (Int, StoreRow).self) { group -> [StoreRow] in
            for (index, store) in stores.enumerated() {
                group.addTask {
                    let availability = Paths.probe(store.url)
                    guard availability.isAvailable else {
                        return (index, StoreRow(store: store, availability: availability, bytes: 0, files: 0, newest: nil))
                    }
                    let size = FileProbe.directorySize(store.url)
                    return (index, StoreRow(store: store, availability: availability, bytes: size.bytes, files: size.files, newest: size.newest))
                }
            }
            var collected: [(Int, StoreRow)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        storeRowsCache = rows
        return rows
    }

    // MARK: Databases

    func databases() async -> [DatabaseEntry] {
        if let databasesCache { return databasesCache }
        let stores = Paths.knownStores()
        let found = await withTaskGroup(of: (Int, [DatabaseEntry]).self) { group -> [DatabaseEntry] in
            for (index, store) in stores.enumerated() {
                group.addTask {
                    guard Paths.probe(store.url).isAvailable else { return (index, []) }
                    let rootPath = store.url.standardizedFileURL.path
                    let entries = FileProbe.discoverDatabases(under: store.url).map { url -> DatabaseEntry in
                        let info = FileProbe.info(url)
                        return DatabaseEntry(
                            url: url, storeID: store.id, storeTitle: store.title,
                            folder: RawCatalog.relativeFolder(of: url, root: rootPath),
                            size: FileProbe.databaseSize(url), modified: info?.modified
                        )
                    }
                    // Top-level databases first (the primary stores), then by folder / name.
                    let sorted = entries.sorted { a, b in
                        if a.folder.isEmpty != b.folder.isEmpty { return a.folder.isEmpty }
                        if a.folder != b.folder { return a.folder.localizedStandardCompare(b.folder) == .orderedAscending }
                        return a.name.localizedStandardCompare(b.name) == .orderedAscending
                    }
                    return (index, sorted)
                }
            }
            var collected: [(Int, [DatabaseEntry])] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        // A database can sit under two overlapping roots; keep the first occurrence.
        var seen = Set<String>()
        let unique = found.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
        databasesCache = unique
        return unique
    }

    static func relativeFolder(of url: URL, root: String) -> String {
        let dir = url.deletingLastPathComponent().standardizedFileURL.path
        guard dir.hasPrefix(root) else { return dir }
        let rel = String(dir.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rel
    }

    /// Table names of every discovered database (for global search). Uses short-lived
    /// connections so ~150 databases do not stay open.
    func tableIndex() async -> [(db: DatabaseEntry, tables: [String])] {
        if let tableIndexCache { return tableIndexCache }
        let dbs = await databases()
        var out: [(db: DatabaseEntry, tables: [String])] = []
        for entry in dbs {
            if Task.isCancelled { return out }
            guard let db = try? SQLiteDB(path: entry.url.path), let tables = try? await db.tables(includeViews: true) else { continue }
            out.append((entry, tables))
        }
        tableIndexCache = out
        return out
    }

    // MARK: Streams

    func streams() async -> [StreamEntry] {
        if let streamsCache { return streamsCache }
        var out: [StreamEntry] = []
        for root in Biome.streamRoots() {
            let origin = RawCatalog.originLabel(for: root)
            for stream in Biome.discoverStreams(under: root) {
                if Task.isCancelled { return out }
                let stats = BiomeStreamReader(stream).stats()
                let devices = stream.devices
                out.append(StreamEntry(
                    stream: stream, origin: origin, stats: stats,
                    remoteDevices: devices.filter { !$0.isLocal }.count,
                    hasLocal: devices.contains(.local)
                ))
            }
        }
        streamsCache = out
        return out
    }

    static func originLabel(for root: URL) -> String {
        let path = root.path
        if path.contains("/Biome/streams/") { return "Biome · " + root.lastPathComponent }
        if path.contains("/DuetExpertCenter/") { return "DuetExpertCenter" }
        if path.contains("/Daemon Containers/") {
            let map = Paths.daemonContainerMap()
            if let match = map.first(where: { path.hasPrefix($0.value.path) }) { return match.key }
            return "Daemon container"
        }
        return root.lastPathComponent
    }

    func devicePeers() async -> [String: BiomeDevicePeer] {
        if let peersCache { return peersCache }
        let peers = await Biome.devicePeers()
        peersCache = peers
        return peers
    }

    // MARK: Files

    /// Files that are neither SQLite databases nor SEGB segments (plists, JSON, protobuf
    /// caches, ...). Capped per store so pathological directories cannot blow up the list.
    func files() async -> [FileEntry] {
        if let filesCache { return filesCache }
        let databasePaths = Set(await databases().map { $0.url.standardizedFileURL.path })
        let out = RawCatalog.scanFiles(excluding: databasePaths)
        filesCache = out
        return out
    }

    /// Synchronous directory walk (kept out of async context on purpose).
    private static func scanFiles(excluding databasePaths: Set<String>) -> [FileEntry] {
        var out: [FileEntry] = []
        let perStoreCap = 6_000
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        for store in Paths.knownStores() where Paths.probe(store.url).isAvailable {
            let rootPath = store.url.standardizedFileURL.path
            guard let enumerator = FileManager.default.enumerator(at: store.url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { continue }
            var taken = 0
            for case let url as URL in enumerator {
                if taken >= perStoreCap || Task.isCancelled { break }
                let name = url.lastPathComponent
                let ext = url.pathExtension.lowercased()
                if name.hasSuffix("-wal") || name.hasSuffix("-shm") || name.hasSuffix("-journal") || name == "lock" || name == ".DS_Store" { continue }
                if databasePaths.contains(url.standardizedFileURL.path) { continue }
                // SEGB segments: extension-less, all-digit names inside local/remote/tombstone dirs.
                if ext.isEmpty, name.allSatisfy(\.isNumber) { continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let size = Int64(values.fileSize ?? 0)
                if size == 0 || size > 256 << 20 { continue }
                out.append(FileEntry(
                    url: url, storeTitle: store.title,
                    folder: RawCatalog.relativeFolder(of: url, root: rootPath),
                    size: size, modified: values.contentModificationDate
                ))
                taken += 1
            }
        }
        return out
    }
}
