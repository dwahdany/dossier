import Foundation

/// Whether a store can be read by this process.
public enum Availability: Sendable, Hashable {
    /// Exists and is readable.
    case available
    /// Does not exist on this Mac / macOS version.
    case missing
    /// Exists but the process may not read it (usually: Full Disk Access not granted).
    case inaccessible(String)

    public var isAvailable: Bool { if case .available = self { return true } else { return false } }

    public var label: String {
        switch self {
        case .available: return "Available"
        case .missing: return "Not present"
        case .inaccessible: return "No access"
        }
    }
}

/// A well-known on-device store location (a file or a directory).
public struct KnownStore: Identifiable, Sendable, Hashable {
    public enum Category: String, Sendable, CaseIterable {
        case knowledgeGraph = "Knowledge Graph"
        case activity = "Activity & Behaviour"
        case biome = "Biome"
        case personalization = "Personalization"
        case people = "People & Communication"
        case photos = "Photos"
        case daemons = "Daemon Containers"
        case other = "Other"
    }

    public let id: String
    public let title: String
    public let detail: String
    public let url: URL
    public let category: Category
    /// When true the URL is a directory that is scanned recursively for databases/files.
    public let isDirectory: Bool

    public init(id: String, title: String, detail: String, url: URL, category: Category, isDirectory: Bool = true) {
        self.id = id; self.title = title; self.detail = detail; self.url = url
        self.category = category; self.isDirectory = isDirectory
    }
}

/// Runtime-resolved locations of the system's knowledge & personalization stores.
///
/// Nothing here is hardcoded to a user name: everything derives from the current user's
/// home directory. All functions are safe to call from any thread; functions that touch the
/// disk are cheap (stat / small directory listings) unless documented otherwise.
public enum Paths {
    // MARK: Roots

    /// The real home directory (not a sandbox container).
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var library: URL { home.appendingPathComponent("Library", isDirectory: true) }

    private static func lib(_ relative: String, dir: Bool = true) -> URL {
        library.appendingPathComponent(relative, isDirectory: dir)
    }

    // MARK: IntelligencePlatform

    public static var intelligencePlatform: URL { lib("IntelligencePlatform") }
    public static var graphDB: URL { intelligencePlatform.appendingPathComponent("graph.db") }
    public static var ontologyDB: URL { intelligencePlatform.appendingPathComponent("ontology.db") }
    public static var intelligencePlatformArtifacts: URL { intelligencePlatform.appendingPathComponent("Artifacts", isDirectory: true) }

    // MARK: Knowledge / CoreDuet

    public static var knowledgeDirectory: URL { lib("Application Support/Knowledge") }
    public static var knowledgeC: URL { knowledgeDirectory.appendingPathComponent("knowledgeC.db") }
    public static var coreDuetPeople: URL { URL(fileURLWithPath: "/private/var/db/CoreDuet/People", isDirectory: true) }
    public static var interactionC: URL { coreDuetPeople.appendingPathComponent("interactionC.db") }
    public static var coreRecents: URL { lib("Containers/com.apple.corerecents.recentsd/Data/Library/Recents") }
    public static var duetExpertCenter: URL { lib("DuetExpertCenter") }
    /// Directory of the call history store (Phone / FaceTime calls synced across devices).
    public static var callHistoryDirectory: URL { lib("Application Support/CallHistoryDB") }
    /// `CallHistory.storedata` (CoreData SQLite).
    public static var callHistory: URL { callHistoryDirectory.appendingPathComponent("CallHistory.storedata") }

    // MARK: Biome

    public static var biome: URL { lib("Biome") }
    public static var biomeStreams: URL { biome.appendingPathComponent("streams", isDirectory: true) }
    public static var biomeRestrictedStreams: URL { biomeStreams.appendingPathComponent("restricted", isDirectory: true) }
    public static var biomeSets: URL { biome.appendingPathComponent("sets", isDirectory: true) }
    public static var biomeDatabases: URL { biome.appendingPathComponent("databases", isDirectory: true) }
    public static var biomeSyncDB: URL { biome.appendingPathComponent("sync/sync.db") }

    // MARK: Personalization

    public static var personalizationPortrait: URL { lib("PersonalizationPortrait") }
    public static var suggestions: URL { lib("Suggestions") }
    public static var assistant: URL { lib("Assistant") }
    /// Keyboard language models: learned typing vocabulary (`<lang>-dynamic.lm`).
    public static var languageModeling: URL { lib("LanguageModeling") }
    public static var trial: URL { lib("Trial") }
    public static var spotlightKnowledge: URL { lib("Metadata/CoreSpotlight/SpotlightKnowledge") }
    public static var coreSpotlight: URL { lib("Metadata/CoreSpotlight") }

    // MARK: Photos

    /// The system Photos library: `~/Pictures/Photos Library.photoslibrary` if present,
    /// otherwise the first `*.photoslibrary` bundle in `~/Pictures`.
    public static var photosLibrary: URL? {
        let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
        let standard = pictures.appendingPathComponent("Photos Library.photoslibrary", isDirectory: true)
        if FileManager.default.fileExists(atPath: standard.path) { return standard }
        let items = (try? FileManager.default.contentsOfDirectory(at: pictures, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension == "photoslibrary" }
    }
    public static var photosDatabaseDirectory: URL? { photosLibrary?.appendingPathComponent("database", isDirectory: true) }
    public static var photosSQLite: URL? { photosDatabaseDirectory?.appendingPathComponent("Photos.sqlite") }
    public static var photosSearchIndex: URL? { photosDatabaseDirectory?.appendingPathComponent("search/psi.sqlite") }
    public static var photosPrivate: URL? { photosLibrary?.appendingPathComponent("private", isDirectory: true) }

    // MARK: Daemon Containers

    public static var daemonContainers: URL { lib("Daemon Containers") }

    private static let daemonLock = NSLock()
    private static var daemonCache: [String: URL]?

    /// Maps `MCMMetadataIdentifier` (e.g. `com.apple.linkd`) → container directory
    /// (`~/Library/Daemon Containers/<uuid>`). Cached after the first call; pass
    /// `refresh: true` to rescan.
    public static func daemonContainerMap(refresh: Bool = false) -> [String: URL] {
        daemonLock.lock(); defer { daemonLock.unlock() }
        if let cached = daemonCache, !refresh { return cached }
        var map: [String: URL] = [:]
        let dirs = (try? FileManager.default.contentsOfDirectory(at: daemonContainers, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let meta = dir.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            guard let data = try? Data(contentsOf: meta),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let identifier = plist["MCMMetadataIdentifier"] as? String else { continue }
            map[identifier] = dir
        }
        daemonCache = map
        return map
    }

    /// The container root for a daemon bundle identifier, or nil if there is none.
    public static func daemonContainer(_ identifier: String) -> URL? { daemonContainerMap()[identifier] }

    /// The `Data` directory inside a daemon container.
    public static func daemonContainerData(_ identifier: String) -> URL? {
        daemonContainer(identifier)?.appendingPathComponent("Data", isDirectory: true)
    }

    // MARK: Probing

    /// Checks existence and readability without raising any permission prompt.
    public static func probe(_ url: URL?) -> Availability {
        guard let url else { return .missing }
        var st = stat()
        if lstat(url.path, &st) != 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return .missing }
            return .inaccessible(String(cString: strerror(code)))
        }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        if isDir {
            guard let dir = opendir(url.path) else {
                return .inaccessible(String(cString: strerror(errno)))
            }
            closedir(dir)
            return .available
        }
        let fd = open(url.path, O_RDONLY)
        if fd < 0 { return .inaccessible(String(cString: strerror(errno))) }
        close(fd)
        return .available
    }

    /// Heuristic Full Disk Access check: tries to open TCC-protected files read-only.
    /// Never triggers a prompt (TCC denies silently for FDA-class paths).
    public static func hasFullDiskAccess() -> Bool {
        let probes: [URL] = [
            lib("Application Support/com.apple.TCC/TCC.db", dir: false),
            knowledgeC,
            lib("Safari", dir: true),
            biome,
        ]
        var sawAny = false
        for url in probes {
            switch probe(url) {
            case .available: return true
            case .inaccessible: sawAny = true
            case .missing: continue
            }
        }
        return !sawAny
    }

    // MARK: Stores beyond Full Disk Access

    /// The per-user Darwin directory (`getconf DARWIN_USER_DIR`), where some agents keep
    /// their stores.
    public static var darwinUserDirectory: URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count)
        guard n > 0, n <= buffer.count else { return nil }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    /// Stores that hold more about the owner but are protected beyond Full Disk Access
    /// (root- or daemon-owned, or data-vaulted). The app never tries to get around that;
    /// it only reports whether they exist and why they cannot be read — ``probe(_:)``
    /// never prompts.
    public static func protectedStores() -> [KnownStore] {
        var out: [KnownStore] = [
            KnownStore(id: "protected.locationd", title: "Location Services & Significant Locations",
                       detail: "locationd's client list and the routine / significant-locations data. Owned by the location daemon; visible only in System Settings › Privacy & Security › Location Services after authentication.",
                       url: URL(fileURLWithPath: "/private/var/db/locationd", isDirectory: true), category: .other),
            KnownStore(id: "protected.coreduet.knowledge", title: "System knowledgeC",
                       detail: "The system-wide copy of the CoreDuet event store (device-level streams). The per-user knowledgeC.db is readable and shown under Activity.",
                       url: URL(fileURLWithPath: "/private/var/db/CoreDuet/Knowledge", isDirectory: true), category: .activity),
        ]
        if let darwin = darwinUserDirectory {
            out.insert(KnownStore(id: "protected.screentime", title: "Screen Time",
                                  detail: "Screen Time's own usage database (per-app and per-website time, pickups, notifications across your devices). Data-vaulted for the Screen Time agent; Biome's ScreenTime.AppUsage stream is the readable trace.",
                                  url: darwin.appendingPathComponent("com.apple.ScreenTimeAgent", isDirectory: true), category: .activity), at: 1)
        }
        return out
    }

    // MARK: Known stores

    /// Every well-known store root, in display order. Entries may be missing on a given
    /// macOS version; use ``probe(_:)``.
    public static func knownStores() -> [KnownStore] {
        var out: [KnownStore] = [
            KnownStore(id: "intelligenceplatform", title: "IntelligencePlatform", detail: "Personal knowledge graph, ontology, entity tagging, views", url: intelligencePlatform, category: .knowledgeGraph),
            KnownStore(id: "spotlightknowledge", title: "Spotlight Knowledge", detail: "CoreSpotlight knowledge graph", url: spotlightKnowledge, category: .knowledgeGraph),
            KnownStore(id: "knowledgec", title: "Knowledge (knowledgeC)", detail: "CoreDuet event streams: app usage, intents, web usage, devices", url: knowledgeDirectory, category: .activity),
            KnownStore(id: "duetexpertcenter", title: "DuetExpertCenter", detail: "Proactive app predictions, launch statistics, Focus modes", url: duetExpertCenter, category: .activity),
            KnownStore(id: "biome.streams", title: "Biome Streams", detail: "SEGB event streams from this Mac and synced devices", url: biomeStreams, category: .biome),
            KnownStore(id: "biome.sets", title: "Biome Sets (Cascade)", detail: "Synced entity sets: mail, reminders, contacts, photos assets", url: biomeSets, category: .biome),
            KnownStore(id: "biome.databases", title: "Biome Databases", detail: "Materialized Biome views", url: biomeDatabases, category: .biome),
            KnownStore(id: "biome.sync", title: "Biome Sync", detail: "Device peers and sync state", url: biome.appendingPathComponent("sync", isDirectory: true), category: .biome),
            KnownStore(id: "portrait", title: "PersonalizationPortrait", detail: "Topics, named entities and locations inferred per app", url: personalizationPortrait, category: .personalization),
            KnownStore(id: "suggestions", title: "Suggestions", detail: "Harvested contacts, events, reservations, snippets", url: suggestions, category: .personalization),
            KnownStore(id: "assistant", title: "Assistant (Siri)", detail: "Speech profiles and custom vocabulary", url: assistant, category: .personalization),
            KnownStore(id: "languagemodeling", title: "LanguageModeling (Keyboard)", detail: "Learned typing vocabulary and keyboard language models", url: languageModeling, category: .personalization),
            KnownStore(id: "trial", title: "Trial", detail: "Experiment / model rollout assignments", url: trial, category: .other),
            KnownStore(id: "coreduet.people", title: "CoreDuet People (interactionC)", detail: "Per-contact interaction history and counters", url: coreDuetPeople, category: .people),
            KnownStore(id: "corerecents", title: "CoreRecents", detail: "Recently used recipients", url: coreRecents, category: .people),
            KnownStore(id: "callhistory", title: "Call History", detail: "Phone and FaceTime call log (CallHistory.storedata)", url: callHistoryDirectory, category: .people),
        ]
        if let db = photosDatabaseDirectory {
            out.append(KnownStore(id: "photos.database", title: "Photos Database", detail: "People, faces, moments, memories, scene classifications, search index", url: db, category: .photos))
        }
        if let priv = photosPrivate {
            out.append(KnownStore(id: "photos.private", title: "Photos Analysis", detail: "PhotosGraph knowledge graph and media analysis captions", url: priv, category: .photos))
        }
        let daemons: [(String, String, String)] = [
            ("com.apple.hybridsearchd", "Hybrid Search", "Semantic search graph/vector index"),
            ("com.apple.linkd", "linkd (App Intents)", "App Intents action transcripts"),
            ("com.apple.kvs", "iCloud Key-Value Store", "Cached iCloud key-value data"),
            ("com.apple.milod", "milod (Microlocation)", "Microlocation models and visits"),
            ("com.apple.intelligentroutingd", "Intelligent Routing", "Media routing predictions"),
        ]
        for (identifier, title, detail) in daemons {
            if let url = daemonContainerData(identifier) {
                out.append(KnownStore(id: "daemon." + identifier, title: title, detail: detail, url: url, category: .daemons))
            }
        }
        return out
    }
}

// MARK: - File-system helpers

public enum FileProbe {
    public struct Info: Sendable, Hashable {
        public var size: Int64
        public var modified: Date?
        public var isDirectory: Bool
    }

    /// Size / mtime of a single file (lstat; no directory traversal).
    public static func info(_ url: URL) -> Info? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Info(
            size: Int64(st.st_size),
            modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
            isDirectory: (st.st_mode & S_IFMT) == S_IFDIR
        )
    }

    /// Size of a SQLite database including its `-wal` and `-shm` companions.
    public static func databaseSize(_ url: URL) -> Int64 {
        var total = info(url)?.size ?? 0
        for suffix in ["-wal", "-shm"] {
            total += info(URL(fileURLWithPath: url.path + suffix))?.size ?? 0
        }
        return total
    }

    /// Recursively sums file sizes under `url`. Potentially slow: call off the main thread.
    /// Returns (bytes, fileCount, newest mtime). Stops early if the task is cancelled.
    public static func directorySize(_ url: URL, maxFiles: Int = 2_000_000) -> (bytes: Int64, files: Int, newest: Date?) {
        var bytes: Int64 = 0
        var files = 0
        var newest: Date?
        if let info = info(url), !info.isDirectory { return (info.size, 1, info.modified) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return (0, 0, nil)
        }
        for case let item as URL in enumerator {
            if files % 512 == 0, Task.isCancelled { break }
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
            files += 1
            if let m = values.contentModificationDate, newest.map({ m > $0 }) ?? true { newest = m }
            if files >= maxFiles { break }
        }
        return (bytes, files, newest)
    }

    /// Common SQLite database extensions (informational; discovery checks file headers).
    public static let databaseExtensions: Set<String> = ["db", "sqlite", "sqlite3", "storedata", "kgdb", "sqlitedb", "database", "sql"]

    /// Extensions that are never SQLite databases; their headers are not even read.
    static let nonDatabaseExtensions: Set<String> = [
        "plist", "json", "pb", "xml", "txt", "log", "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "mov", "mp4",
        "m4a", "caf", "wav", "bin", "dat", "data", "strings", "car", "mlmodelc", "espresso", "weights", "shape", "net",
        "tmp", "lock", "gz", "zip", "bz2", "lzfse", "md", "html", "csv", "ini", "cfg", "yaml", "segb", "archive", "mdplist",
    ]

    /// True if the file starts with the SQLite header magic.
    public static func hasSQLiteHeader(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        return head.starts(with: Array("SQLite format 3\0".utf8))
    }

    /// Recursively discovers SQLite databases under `root` by header magic (any extension;
    /// `-wal`/`-shm`/`-journal` companions and obviously non-database extensions are
    /// skipped without being opened). Call off the main thread.
    public static func discoverDatabases(under root: URL, maxDepth: Int = 12) -> [URL] {
        var out: [URL] = []
        if let info = info(root), !info.isDirectory {
            return hasSQLiteHeader(root) ? [root] : []
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return [] }
        var seen = 0
        for case let item as URL in enumerator {
            seen += 1
            if seen % 256 == 0, Task.isCancelled { break }
            if enumerator.level > maxDepth { enumerator.skipDescendants(); continue }
            let name = item.lastPathComponent
            if name.hasSuffix("-wal") || name.hasSuffix("-shm") || name.hasSuffix("-journal") { continue }
            let ext = item.pathExtension.lowercased()
            if nonDatabaseExtensions.contains(ext) { continue }
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  (values.fileSize ?? 0) >= 512 else { continue }
            if hasSQLiteHeader(item) { out.append(item) }
        }
        return out.sorted { $0.path < $1.path }
    }
}
