import Foundation

/// Demo mode's safety net (`DOSSIER_DEMO_ROOT`, see ``Paths/demoRoot``).
///
/// Three layers keep a demo run away from the owner's real stores:
///
/// 1. **Path resolution** — every store path derives from ``Paths/home`` or
///    ``Paths/system(_:isDirectory:)``, which resolve below the demo root.
/// 2. **Reader guard** — Core's readers (`Paths.probe`, `FileProbe`, `SQLiteDB`, `SEGBFile`)
///    ask ``Paths/allows(_:)`` first and treat anything outside the root as missing. Every
///    answer is recorded here; a refusal is a bug in a path construction and fails the
///    self-test.
/// 3. **Kernel sandbox** — ``activate()`` applies a sandbox profile to the process that
///    denies reading (and writing) the real store locations, so that even code that
///    bypasses both layers above gets "Operation not permitted" instead of real data.
///
/// Outside demo mode nothing here does anything.
public enum DemoGuard {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var checked = Set<String>()
    nonisolated(unsafe) private static var refused = Set<String>()
    nonisolated(unsafe) private static var sandboxState: SandboxState = .notRequested
    private static let recordLimit = 200_000

    enum SandboxState: Equatable { case notRequested, active(Int), failed(String) }

    static func record(_ path: String, allowed: Bool) {
        lock.lock(); defer { lock.unlock() }
        if allowed {
            if checked.count < recordLimit { checked.insert(path) }
        } else if refused.count < 1_000 {
            refused.insert(path)
        }
    }

    /// Real locations that hold personal stores: what the sandbox denies and what the
    /// open-descriptor check looks for. Deliberately broader than what the app reads; the
    /// self-test checks that it covers the real counterpart of everything a demo run read
    /// (``selfTestAudit()``), so a store a module starts reading has to be added here.
    static func realStoreRoots() -> [String] {
        let home = Paths.realHome.path
        let library = [
            "IntelligencePlatform", "Biome", "PersonalizationPortrait", "Suggestions", "Assistant", "LanguageModeling",
            "Trial", "Metadata", "DuetExpertCenter", "DoNotDisturb", "Containers", "Daemon Containers", "Group Containers",
            "KeyboardServices", "Spelling", "Mail", "Messages", "Safari", "Calendars", "Reminders", "Photos",
            "Cookies", "Mobile Documents", "Accounts", "IdentityServices", "Sharing", "HomeKit", "Health",
            "Application Support/Knowledge", "Application Support/CallHistoryDB", "Application Support/CallHistoryTransactions",
            "Application Support/AddressBook", "Application Support/com.apple.TCC", "Application Support/CloudDocs",
            "Application Support/com.apple.ProtectedCloudStorage", "Application Support/FaceTime",
            "Application Support/com.apple.spotlight",
            "Preferences/com.apple.assistant.backedup.plist",
        ].map { home + "/Library/" + $0 }
        var roots = library + [
            home + "/Pictures",
            "/private/var/db/CoreDuet", "/private/var/db/locationd",
        ]
        // The real per-user Darwin directory's Screen Time store.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count)
        if n > 0, n <= buffer.count {
            roots.append(Paths.canonicalPath(String(cString: buffer) + "com.apple.ScreenTimeAgent"))
        }
        return roots
    }

    /// The real store location a demo root collides with, if any: the root lies inside one
    /// (the sandbox would then have to leave that whole location readable) or contains one
    /// (the reader guard would then accept real stores as "below the root"). Demo mode
    /// refuses to start with such a root.
    static func rootCollision() -> String? {
        guard let demo = Paths.demoRoot?.path else { return nil }
        let home = Paths.canonicalPath(Paths.realHome.path)
        if demo == "/" || Paths.isBelow(home, demo) { return home }
        return realStoreRoots().first { root in
            let real = Paths.canonicalPath(root)
            return Paths.isBelow(demo, real) || Paths.isBelow(real, demo)
        }
    }

    /// Set `DOSSIER_DEMO_ALLOW_UNSANDBOXED=1` to let a demo run continue although the
    /// kernel sandbox could not be applied (for example inside another sandbox that
    /// forbids `sandbox_init`). Path resolution and the reader guard still hold then.
    public static let allowUnsandboxedVariable = "DOSSIER_DEMO_ALLOW_UNSANDBOXED"
    static var allowsUnsandboxed: Bool { ProcessInfo.processInfo.environment[allowUnsandboxedVariable] == "1" }

    /// Why the kernel sandbox is not in force in this demo run, or nil when it is (or
    /// outside demo mode).
    public static var sandboxFailure: String? {
        guard Paths.isDemo else { return nil }
        lock.lock(); defer { lock.unlock() }
        switch sandboxState {
        case .active: return nil
        case .failed(let message): return message
        case .notRequested: return "DemoGuard.activate() was not called"
        }
    }

    /// Stops a demo run that would draw the app (window, `--snapshot`, `--screenshot`,
    /// `--uitest`) without the kernel sandbox: frameworks read some real locations on
    /// their own (the text system reads the spelling dictionaries when a search field is
    /// typed into), and only the sandbox keeps those away. Does nothing outside demo mode,
    /// with the sandbox on, or when ``allowUnsandboxedVariable`` is set.
    public static func requireSandboxForRendering() {
        guard let failure = sandboxFailure, !allowsUnsandboxed else { return }
        fputs("error: demo mode could not apply its sandbox (\(failure)), so the real stores are not blocked for this process.\n"
              + "       Not drawing anything. Set \(allowUnsandboxedVariable)=1 to continue on path resolution and the reader guard alone.\n", stderr)
        exit(2)
    }

    /// Applies the kernel sandbox in demo mode. Call once, before anything is read. Safe to
    /// call outside demo mode (does nothing). Never prompts; a denied read just fails.
    public static func activate() {
        guard Paths.isDemo else { return }
        lock.lock()
        let already = sandboxState != .notRequested
        lock.unlock()
        if already { return }
        if let collision = rootCollision() {
            // Only the kind of location is named: the path is the user's own.
            fputs("error: \(Paths.demoRootVariable) must not be, contain or lie inside a location that holds real stores (\((collision as NSString).abbreviatingWithTildeInPath)). Choose a folder elsewhere, for example below /tmp.\n", stderr)
            exit(2)
        }
        applyPresentation()

        let roots = realStoreRoots()
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var profile = "(version 1)\n(allow default)\n(deny file-read* file-write*\n"
        for root in roots {
            profile += "  (subpath \(quoted(root)))\n"
            let resolved = Paths.canonicalPath(root)
            if resolved != root { profile += "  (subpath \(quoted(resolved)))\n" }
        }
        profile += ")\n"

        // `sandbox_init` is deprecated API without a replacement for a process that wants
        // to restrict itself; looked up dynamically so a missing symbol degrades to a
        // self-test warning instead of a link error.
        typealias SandboxInit = @convention(c) (UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        let state: SandboxState
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_init") {
            let sandboxInit = unsafeBitCast(symbol, to: SandboxInit.self)
            var message: UnsafeMutablePointer<CChar>?
            if sandboxInit(profile, 0, &message) == 0 {
                state = .active(roots.count)
            } else {
                state = .failed(message.map { String(cString: $0) } ?? "sandbox_init failed")
            }
        } else {
            state = .failed("sandbox_init is not available")
        }
        lock.lock(); sandboxState = state; lock.unlock()
    }

    /// Locale and time zone of a demo run: the invented owner's, not this Mac's, so that a
    /// screenshot shows neither the real owner's regional formats nor activity at odd hours.
    /// `DOSSIER_DEMO_LOCALE` (default `en_NZ`) and `DOSSIER_DEMO_TZ` (default
    /// `Pacific/Auckland`) override; an empty value keeps this Mac's setting.
    public static let defaultLocale = "en_NZ"
    public static let defaultTimeZone = "Pacific/Auckland"

    private static func applyPresentation() {
        let env = ProcessInfo.processInfo.environment
        let locale = env["DOSSIER_DEMO_LOCALE"] ?? defaultLocale
        if !locale.isEmpty {
            // The argument domain is volatile (nothing is written to disk) and wins over
            // the user's preferences; it must be set before the first Locale.current.
            var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            domain["AppleLocale"] = locale
            domain["AppleLanguages"] = [locale.replacingOccurrences(of: "_", with: "-")]
            UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        }
        let zone = env["DOSSIER_DEMO_TZ"] ?? defaultTimeZone
        if !zone.isEmpty, let timeZone = TimeZone(identifier: zone) {
            setenv("TZ", zone, 1)      // SQLite's 'localtime', strftime
            tzset()
            NSTimeZone.default = timeZone
        }
    }

    /// Paths of the regular files this process has open right now.
    static func openFilePaths() -> [String] {
        var out: [String] = []
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        for fd in 0..<getdtablesize() {
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG || (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            guard fcntl(fd, F_GETPATH, &buffer) == 0 else { continue }
            out.append(String(cString: buffer))
        }
        return out
    }

    /// Self-test lines for the start of a demo run: where paths point and whether the
    /// sandbox is on. Empty outside demo mode.
    public static func selfTestSetup() -> [SelfTestLine] {
        guard let root = Paths.demoRoot else { return [] }
        var lines: [SelfTestLine] = []
        let exists = (FileProbe.info(root)?.isDirectory ?? false)
        lines.append(.check("demo: root is a directory", exists, exists ? "showing a synthetic data set, not this Mac" : "DOSSIER_DEMO_ROOT does not name a directory — every store will be missing"))

        var urls: [URL] = Paths.knownStores().map(\.url) + Paths.protectedStores().map(\.url)
        urls += [Paths.home, Paths.library, Paths.graphDB, Paths.knowledgeC, Paths.interactionC, Paths.coreRecents, Paths.callHistory,
                 Paths.biomeStreams, Paths.biomeSyncDB, Paths.daemonContainers, Paths.coreSpotlight]
        urls += [Paths.photosLibrary, Paths.darwinUserDirectory].compactMap { $0 }
        urls += Biome.streamRoots()
        let outside = urls.filter { !Paths.isBelow(Paths.canonicalPath($0.path), root.path) }
        lines.append(.check("demo: every known store path resolves below the root", outside.isEmpty,
                            outside.isEmpty ? "\(urls.count) locations" : outside.map(\.path).prefix(5).joined(separator: ", ")))
        lines.append(.check("demo: Full Disk Access check reports granted", Paths.hasFullDiskAccess()))

        lock.lock(); let state = sandboxState; lock.unlock()
        switch state {
        case .active(let count):
            // Proof, not just a flag: a denied directory must now be unreadable. Only
            // attempted while the sandbox is on, so it can never read anything (and only
            // `opendir`, never a listing). The probes come in two kinds: locations that
            // privacy protection (TCC) does not cover, where a denial can only be the
            // sandbox's, and — as a fallback when none of those exists — a store that a
            // process without Full Disk Access is denied anyway.
            let probes: [(path: String, sandboxOnly: Bool)] = [
                ("Pictures", true), ("Library/Spelling", true), ("Library/KeyboardServices", true), ("Library/Biome", false),
            ]
            var observed: (name: String, denied: Bool, sandboxOnly: Bool)?
            for probe in probes {
                errno = 0
                let dir = opendir(Paths.realHome.appendingPathComponent(probe.path, isDirectory: true).path)
                let code = errno
                if let dir { closedir(dir) }
                if dir == nil, code == ENOENT || code == ENOTDIR { continue }
                observed = ("~/" + probe.path, dir == nil && (code == EPERM || code == EACCES), probe.sandboxOnly)
                break
            }
            if let observed {
                let detail: String
                if !observed.denied {
                    detail = "\(observed.name) could still be opened"
                } else if observed.sandboxOnly {
                    detail = "\(count) real locations unreadable for this process (probed \(observed.name), which only the sandbox protects)"
                } else {
                    detail = "\(count) real locations denied; probed \(observed.name), which macOS also denies without Full Disk Access, so this alone does not tell the two apart"
                }
                lines.append(.check("demo: kernel sandbox denies the real stores", observed.denied, detail))
            } else {
                lines.append(.info("demo: kernel sandbox active", "\(count) real locations denied; none of the probe directories exists on this Mac, so the denial itself was not observed"))
            }
        case .failed(let message):
            lines.append(sandboxMissingLine("demo: kernel sandbox not active", message))
        case .notRequested:
            lines.append(sandboxMissingLine("demo: kernel sandbox not requested", "DemoGuard.activate() was not called"))
        }
        return lines
    }

    /// A demo run without the kernel sandbox fails the self-test, so that
    /// `scripts/make-screenshots.sh` never takes pictures without that layer; the override
    /// (``allowUnsandboxedVariable``) turns it into a warning.
    private static func sandboxMissingLine(_ label: String, _ message: String) -> SelfTestLine {
        if allowsUnsandboxed {
            return .warn(label, message + " — \(allowUnsandboxedVariable)=1: relying on path resolution and the reader guard")
        }
        return .check(label, false, message + " — the real stores are not blocked for this process (\(allowUnsandboxedVariable)=1 accepts that)")
    }

    /// The real location a path below the demo root stands for (`<root>/Home/x` → the
    /// real `~/x`, `<root>/private/var/db/x` → `/private/var/db/x`, the demo per-user
    /// directory → the real one); nil for the root, the demo home and paths outside.
    static func realCounterpart(of path: String) -> String? {
        guard let demo = Paths.demoRoot?.path, Paths.isBelow(path, demo), path != demo else { return nil }
        let rest = String(path.dropFirst(demo.count))            // "/Home/Library/…", "/private/var/…"
        if rest == "/Home" { return nil }
        if rest.hasPrefix("/Home/") { return Paths.canonicalPath(Paths.realHome.path) + rest.dropFirst("/Home".count) }
        if Paths.isBelow(rest, Paths.demoDarwinUserDirectory) {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let n = confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count)
            guard n > 0, n <= buffer.count else { return nil }
            var real = Paths.canonicalPath(String(cString: buffer))
            if real.hasSuffix("/") { real.removeLast() }
            return real + rest.dropFirst(Paths.demoDarwinUserDirectory.count)
        }
        return rest
    }

    /// Self-test lines for the end of a demo run (after every module's self-test and
    /// summary): nothing outside the root was asked for, and no real store file is open.
    public static func selfTestAudit() -> [SelfTestLine] {
        guard Paths.isDemo else { return [] }
        lock.lock()
        let checkedCount = checked.count
        let refusedPaths = refused.sorted()
        lock.unlock()
        var lines: [SelfTestLine] = []
        // Shown through displayPath / last components only: the list may name real paths.
        lines.append(.check("demo: no reader asked for a location outside the root", refusedPaths.isEmpty,
                            refusedPaths.isEmpty
                                ? "\(checkedCount) distinct locations checked, all below the root (or self-test scratch files)"
                                : "\(refusedPaths.count) refused: " + refusedPaths.prefix(5).joined(separator: ", ")))
        // Layer 3 must cover what layers 1 and 2 let through: the real counterpart of every
        // location a reader asked for has to be on the sandbox's deny list, or a path bug
        // there would not be stopped. Compared as strings; nothing real is touched.
        let denied = realStoreRoots().map { Paths.canonicalPath($0) }
        lock.lock()
        let asked = checked
        lock.unlock()
        var uncovered = Set<String>()
        for path in asked {
            guard let real = realCounterpart(of: path) else { continue }
            // The read-only system volume holds macOS itself, nothing of the owner's.
            if Paths.isBelow(real, "/System") || Paths.isBelow(real, "/usr") { continue }
            // Ancestors of denied roots (~/Library, /private/var/db) are only listed, to find the stores.
            if denied.contains(where: { Paths.isBelow(real, $0) || Paths.isBelow($0, real) }) { continue }
            // Shown by its first components only (below the home directory: two more).
            let home = Paths.canonicalPath(Paths.realHome.path)
            let relative = Paths.isBelow(real, home) ? "~" + real.dropFirst(home.count) : real
            uncovered.insert(relative.split(separator: "/", omittingEmptySubsequences: false).prefix(4).joined(separator: "/"))
        }
        lines.append(.check("demo: the sandbox denies the real counterpart of every location read", uncovered.isEmpty,
                            uncovered.isEmpty ? "\(denied.count) denied locations cover them all"
                                              : "not on the deny list (DemoGuard.realStoreRoots): " + uncovered.sorted().prefix(8).joined(separator: ", ")))
        let roots = realStoreRoots()
        let open = openFilePaths()
        let leaked = open.filter { path in roots.contains { Paths.isBelow(Paths.canonicalPath(path), Paths.canonicalPath($0)) } }
        lines.append(.check("demo: no open file lies in a real store", leaked.isEmpty,
                            leaked.isEmpty ? "\(open.count) open files and directories inspected" : leaked.prefix(5).joined(separator: ", ")))
        return lines
    }
}
