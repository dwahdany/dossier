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

    /// The home directory every store path derives from: the real home directory (not a
    /// sandbox container), or `<demo root>/Home` in demo mode (see ``demoRoot``).
    public static var home: URL { demoRoot?.appendingPathComponent("Home", isDirectory: true) ?? realHome }

    /// The current user's real home directory. Only for the demo-mode guards — store paths
    /// must derive from ``home``.
    static var realHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: Demo root

    /// Name of the environment variable that switches the whole app to a synthetic data set.
    public static let demoRootVariable = "DOSSIER_DEMO_ROOT"

    /// The demo root, when `DOSSIER_DEMO_ROOT` names a directory: every store path then
    /// resolves below it (``home`` → `<root>/Home`, absolute system locations through
    /// ``system(_:isDirectory:)`` → `<root><absolute path>`), Full Disk Access counts as
    /// granted and nothing outside the root is read. Read once at start.
    public static let demoRoot: URL? = {
        guard let raw = ProcessInfo.processInfo.environment[demoRootVariable], !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
        return URL(fileURLWithPath: canonicalPath(absolute), isDirectory: true)
    }()

    /// True while the app shows a synthetic data set instead of this Mac's stores.
    public static var isDemo: Bool { demoRoot != nil }

    /// An absolute system location outside the home directory (`/private/var/db/…`,
    /// `/System/Library/…`). In demo mode it resolves below the demo root. Never build such
    /// a URL by hand.
    public static func system(_ absolutePath: String, isDirectory: Bool = true) -> URL {
        if let demoRoot {
            let relative = absolutePath.hasPrefix("/") ? String(absolutePath.dropFirst()) : absolutePath
            return demoRoot.appendingPathComponent(relative, isDirectory: isDirectory)
        }
        return URL(fileURLWithPath: absolutePath, isDirectory: isDirectory)
    }

    /// Whether a location may be read: always outside demo mode; in demo mode only what
    /// lies below the demo root (or is one of the self-tests' own scratch files in the
    /// temporary directory, ``selfTestScratchPrefixes``). Core's readers call this before opening anything and treat a
    /// refused location as missing; refusals are kept for the self-test (``DemoGuard``).
    public static func allows(_ url: URL) -> Bool { allows(path: url.path) }

    public static func allows(path: String) -> Bool {
        guard let demoRoot else { return true }
        let canonical = canonicalPath(path)
        let ok = isBelow(canonical, demoRoot.path) || isSelfTestScratch(canonical)
        DemoGuard.record(canonical, allowed: ok)
        return ok
    }

    /// A location as shown in the UI: the home directory abbreviated to "~"; in demo mode
    /// the demo root itself is never shown (`<root>/Home/Library/x` → `~/Library/x`,
    /// `<root>/private/var/db/x` → `/private/var/db/x`).
    public static func displayPath(_ url: URL) -> String {
        guard let demoRoot else { return (url.path as NSString).abbreviatingWithTildeInPath }
        let path = canonicalPath(url.path)
        if isBelow(path, home.path) { return "~" + path.dropFirst(home.path.count) }
        if isBelow(path, demoRoot.path) {
            let rest = String(path.dropFirst(demoRoot.path.count))
            return rest.isEmpty ? "/" : rest
        }
        return path
    }

    private static let demoTemporaryDirectory = canonicalPath(NSTemporaryDirectory())

    /// Name prefixes of the scratch files and folders the self-tests create in the
    /// temporary directory. Nothing else there is readable in demo mode: other apps keep
    /// files in the same directory.
    public static let selfTestScratchPrefixes = ["dossier-selftest-", "dossier-shmtest-"]

    private static func isSelfTestScratch(_ canonical: String) -> Bool {
        guard isBelow(canonical, demoTemporaryDirectory), canonical != demoTemporaryDirectory else { return false }
        let base = demoTemporaryDirectory.hasSuffix("/") ? String(demoTemporaryDirectory.dropLast()) : demoTemporaryDirectory
        guard let first = canonical.dropFirst(base.count).split(separator: "/").first else { return false }
        return selfTestScratchPrefixes.contains { first.hasPrefix($0) }
    }

    static func isBelow(_ path: String, _ root: String) -> Bool {
        let root = root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root
        return path == root || path.hasPrefix(root + "/")
    }

    /// `realpath` of the deepest existing ancestor plus the remainder, so that a location
    /// that does not exist yet (or a symlink pointing out of the root) is still judged by
    /// where it really is. (`URL.resolvingSymlinksInPath` strips `/private`, hence this.)
    static func canonicalPath(_ path: String) -> String {
        var head = (path as NSString).standardizingPath
        if !head.hasPrefix("/") { head = "/" + head }
        // `standardizingPath` strips `/private` from `/private/var` and `/private/tmp`;
        // realpath below puts it back for anything that exists.
        var tail: [String] = []
        while true {
            if let resolved = realpath(head, nil) {
                let base = String(cString: resolved)
                free(resolved)
                return tail.isEmpty ? base : (base == "/" ? "" : base) + "/" + tail.reversed().joined(separator: "/")
            }
            if head == "/" || head.isEmpty { return path }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
    }
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
    public static var coreDuetPeople: URL { system("/private/var/db/CoreDuet/People") }
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
        guard allows(url) else { return .missing }
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
        if isDemo { return true }   // nothing protected is read: every path is below the demo root
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

    /// Where the per-user Darwin directory lives below a demo root.
    public static let demoDarwinUserDirectory = "/private/var/folders/demo/0"

    /// The per-user Darwin directory (`getconf DARWIN_USER_DIR`), where some agents keep
    /// their stores. In demo mode: `<root>/private/var/folders/demo/0`.
    public static var darwinUserDirectory: URL? {
        if isDemo { return system(demoDarwinUserDirectory) }
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
                       url: system("/private/var/db/locationd"), category: .other),
            KnownStore(id: "protected.coreduet.knowledge", title: "System knowledgeC",
                       detail: "The system-wide copy of the CoreDuet event store (device-level streams). The per-user knowledgeC.db is readable and shown under Activity.",
                       url: system("/private/var/db/CoreDuet/Knowledge"), category: .activity),
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
        guard Paths.allows(url) else { return nil }
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
        guard Paths.allows(url) else { return (0, 0, nil) }
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
        guard Paths.allows(url) else { return false }
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
        guard Paths.allows(root) else { return [] }
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
