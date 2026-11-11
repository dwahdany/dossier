import SwiftUI
import AppKit

// MARK: - Shell contract

/// One sidebar destination a UI test visits.
public struct UITestSection: Sendable {
    public var id: String
    /// Module the section belongs to (nil for shell-owned pages such as the Overview).
    public var moduleID: String?
    public var title: String
    /// Deep-link payloads that put the section into further states worth testing (the
    /// tabs behind a mode picker): from ``ModuleSection/uiTestPayloads``.
    public var payloads: [String]
    public init(id: String, moduleID: String?, title: String, payloads: [String] = []) {
        self.id = id; self.moduleID = moduleID; self.title = title; self.payloads = payloads
    }
}

/// What `--uitest` needs from a window shell: the *real* root view the user gets, plus
/// read/write access to the state the checks observe. Implemented by the app
/// (`AppUITestShell`) and by the dev shell (``DevShellUITest``).
@MainActor
public protocol UITestShell: AnyObject {
    var name: String { get }
    /// The window content exactly as the `Window` / `WindowGroup` scene builds it
    /// (including its `.frame(minWidth:minHeight:)`).
    func makeRootView() -> AnyView
    /// The scene's content minimum (`.frame(minWidth:minHeight:)`).
    var minimumSize: CGSize { get }
    /// `navigationSplitViewColumnWidth(min:…max:)` of the sidebar.
    var sidebarWidthRange: ClosedRange<CGFloat> { get }
    /// Every destination in sidebar order.
    var sections: [UITestSection] { get }
    /// Row index of a destination in the sidebar list (headers and disclosure rows count).
    func sidebarRow(for id: String) -> Int?
    var selection: String? { get set }
    var privacyMode: Bool { get set }
    /// Opens a section with a deep-link payload, as a search hit or a cross-module link
    /// does. Returns false when the shell cannot deliver deep links.
    func open(section id: String, payload: String) -> Bool
    /// Global search; `hasSearch == false` skips the search checks.
    var hasSearch: Bool { get }
    var searchText: String { get set }
    var searchIsRunning: Bool { get }
    /// Section ids of the current search hits, in display order.
    var searchHitSections: [String] { get }
    /// Non-nil when the shell cannot show sections at all (no Full Disk Access): the test
    /// then only checks the window as it is and never dismisses the permission screen.
    var blockedReason: String? { get }
    /// Other windows of the shell (Settings): name, content, expected fixed size.
    var auxiliaryViews: [(name: String, view: AnyView, size: CGSize?)] { get }
}

public extension UITestShell {
    func open(section id: String, payload: String) -> Bool { false }
    var hasSearch: Bool { false }
    var searchText: String { get { "" } set {} }
    var searchIsRunning: Bool { false }
    var searchHitSections: [String] { [] }
    var blockedReason: String? { nil }
    var auxiliaryViews: [(name: String, view: AnyView, size: CGSize?)] { [] }
}

public struct UITestOptions {
    /// `"all"`, a section id, or a module id.
    public var target = "all"
    public var outDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dossier-uitest")
    /// Content sizes to lay out at; nil = the shell minimum, 1360x860, 1800x1100.
    public var sizes: [CGSize]?
    public var query = "apple"
    /// Seconds to wait for one section's loads.
    public var loadTimeout: TimeInterval = 20
    /// Hard limit for the whole run (a hung tracking loop must not block a test loop).
    public var runTimeout: TimeInterval = 1500
    public var interactions = true
    /// Largest window the "screen" allows; a window that the content forces beyond the
    /// requested size is clamped to it, as the window server clamps to the display.
    public var screen = CGSize(width: 1800, height: 1169)
    /// Extra deep-link payload for the target section (`--payload`); tested as a further
    /// state after the section's default state and its declared `uiTestPayloads`.
    public var payload: String?
    /// Run everything in the dark appearance (`--dark`). Otherwise only the first section
    /// of each module gets one extra dark capture.
    public var dark = false
    public init() {}
}

/// What `--screenshot` renders.
public struct ScreenshotRequest {
    /// A section id, a module id (its first section) or `"overview"`.
    public var target = "overview"
    public var out = URL(fileURLWithPath: "screenshot.png")
    /// Size of the whole window in points, title bar included.
    public var size = CGSize(width: 1320, height: 840)
    public var scale: CGFloat = 2
    public var dark = false
    public var privacy = false
    public var payload: String?
    /// Text for the toolbar's global search; the picture then shows the hits.
    public var search: String?
    /// Seconds to wait for loads.
    public var timeout: TimeInterval = 30
    /// Extra seconds on screen before the capture (charts and maps that load in stages).
    public var linger: TimeInterval = 1.0
    public init() {}
}

// MARK: - Report

public struct UITestCheck: Codable {
    public enum Status: String, Codable { case pass, fail, skip, info }
    public var name: String
    public var status: Status
    public var detail: String
    public var numbers: [String: Double]?

    static func pass(_ name: String, _ detail: String = "", _ numbers: [String: Double]? = nil) -> UITestCheck {
        UITestCheck(name: name, status: .pass, detail: detail, numbers: numbers)
    }
    static func fail(_ name: String, _ detail: String, _ numbers: [String: Double]? = nil) -> UITestCheck {
        UITestCheck(name: name, status: .fail, detail: detail, numbers: numbers)
    }
    static func skip(_ name: String, _ detail: String) -> UITestCheck {
        UITestCheck(name: name, status: .skip, detail: detail, numbers: nil)
    }
    static func info(_ name: String, _ detail: String, _ numbers: [String: Double]? = nil) -> UITestCheck {
        UITestCheck(name: name, status: .info, detail: detail, numbers: numbers)
    }
    static func check(_ name: String, _ ok: Bool, _ detail: String, _ numbers: [String: Double]? = nil) -> UITestCheck {
        UITestCheck(name: name, status: ok ? .pass : .fail, detail: detail, numbers: numbers)
    }
}

struct UITestSizeReport: Codable {
    var size: String
    /// Section shown while measuring (nil: search results / blocked shell).
    var section: String?
    var context: String
    var numbers: [String: Double]
    var checks: [UITestCheck]
    var png: String?
    var pngDark: String?
    /// Captures further down the page (taken after scrolling), minimum size only.
    var pngScrolled: [String]?
}

struct UITestSectionReport: Codable {
    var id: String
    var module: String?
    var loadSeconds: Double
    var loadTimedOut: Bool
    var layouts: [UITestSizeReport]
    var interactions: [UITestCheck]
    var failures: [String]
}

struct UITestReport: Codable {
    var shell: String
    var target: String
    var minimumSize: String
    var sizes: [String]
    var chromeHeight: Double
    var sections: [UITestSectionReport]
    var global: [UITestCheck]
    var globalLayouts: [UITestSizeReport]
    var auxiliary: [UITestCheck]
    var failures: [String]
    var notes: [String]
    var seconds: Double
    var passed: Bool
}

// MARK: - Window

/// A real titled, resizable window with a unified toolbar — what a SwiftUI `Window` scene
/// creates — that lives outside every display and is never ordered in or activated.
/// It reports itself as key so controls take clicks and text input like a front window.
private final class UITestWindow: NSWindow {
    var maximumFrameSize = CGSize(width: 1800, height: 1169)
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// The window server never lets a window outgrow the display; content whose minimum
    /// size is larger gets clipped instead. Emulate that for the virtual screen.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        rect.size.width = min(rect.size.width, maximumFrameSize.width)
        rect.size.height = min(rect.size.height, maximumFrameSize.height)
        rect.origin = NSPoint(x: -30_000, y: -30_000)
        super.setFrame(rect, display: flag)
    }
}

// MARK: - Runner

/// `--uitest`: hosts the real shell in a real (off-screen, never activated) window, visits
/// sections, checks layout invariants at several window sizes, drives the UI with
/// in-process synthesized events and writes PNGs plus `report.json`.
@MainActor
public enum UITestRunner {
    private static var window: UITestWindow!
    private static var hosting: NSView!
    private static var shell: UITestShell!
    private static var options = UITestOptions()
    private static var chrome: CGFloat = 0
    private static var eventNumber = 0
    private static var testedSections: Set<String> = []
    /// AppKit animations (sidebar collapse) only run while the display is awake.
    /// Asked each time: the display can go to sleep in the middle of a long run.
    private static var displayAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
    private static var notes: [String] = []
    nonisolated(unsafe) private static var stage = "start" {
        didSet { if verbose { fputs("uitest: \(stage)\n", stderr) } }
    }
    nonisolated private static let verbose = ProcessInfo.processInfo.environment["DOSSIER_UITEST_VERBOSE"] != nil

    public static func run(shell: UITestShell, options: UITestOptions) -> Never {
        let started = Date()
        setvbuf(stdout, nil, _IOLBF, 0)   // keep section lines when stdout is a file and the run dies
        self.shell = shell
        self.options = options
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: options.dark ? .darkAqua : .aqua)
        UITestProbe.isActive = true
        SnapshotReadiness.isSnapshotting = true
        // Sidebar groups must be expanded so every row exists. The argument domain wins
        // over the persistent one and is never written to disk.
        var argumentDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        argumentDomain["collapsedModules"] = ""
        UserDefaults.standard.setVolatileDomain(argumentDomain, forName: UserDefaults.argumentDomain)
        try? FileManager.default.createDirectory(at: options.outDir, withIntermediateDirectories: true)
        startWatchdog()

        let minimum = shell.minimumSize
        var sizes = options.sizes ?? [minimum, CGSize(width: 1360, height: 860), CGSize(width: 1800, height: 1100)]
        let first = sizes.first ?? minimum

        let window = UITestWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: first.width, height: first.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.maximumFrameSize = options.screen
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: options.dark ? .darkAqua : .aqua)
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.toolbarStyle = .unified
        // Default sizingOptions (.minSize, .intrinsicContentSize, .maxSize): the content's
        // minimum and ideal sizes become window constraints, as in a SwiftUI scene.
        let hosting = NSHostingView(rootView: shell.makeRootView().uiTestSection("root"))
        window.contentView = hosting
        self.window = window
        self.hosting = hosting

        pump(0.4)
        window.layoutIfNeeded()
        chrome = max(0, hosting.safeAreaInsets.top)
        if ProcessInfo.processInfo.environment["DOSSIER_UITEST_DUMP"] != nil { dumpHierarchy() }

        // A window cannot outgrow the (virtual) screen: clamp such requests and say so,
        // instead of failing `window-size` for every section.
        let largest = CGSize(width: options.screen.width, height: options.screen.height - chrome)
        sizes = sizes.map { size in
            var clamped = CGSize(width: min(size.width, largest.width), height: min(size.height, largest.height))
            clamped.width = max(clamped.width, minimum.width)
            clamped.height = max(clamped.height, minimum.height)
            if clamped != size {
                notes.append("Requested size \(sizeLabel(size)) is outside what a window can have here (minimum \(sizeLabel(minimum)), screen \(sizeLabel(options.screen)) including \(Int(chrome)) pt of title bar; --screen WxH changes it): tested at \(sizeLabel(clamped)) instead.")
            }
            return clamped
        }
        var seenSizes = Set<String>()
        sizes = sizes.filter { seenSizes.insert(sizeLabel($0)).inserted }
        // Scrolling, the table click and the "row selected" layout use the smallest size.
        interactionSize = sizes.min { ($0.width, $0.height) < ($1.width, $1.height) } ?? minimum
        if let payload = options.payload, !shell.sections.contains(where: { $0.id == options.target }) {
            fputs("uitest: --payload needs a section id as the target (got \"\(options.target)\"); payload of \(payload.count) character(s) ignored\n", stderr)
            exit(2)
        }

        if displayAsleep {
            notes.append("The display is asleep: AppKit animations do not run, so the sidebar is toggled without animation (state set directly) instead of by a click on its toolbar button.")
        }
        var report = UITestReport(
            shell: shell.name, target: options.target, minimumSize: sizeLabel(minimum),
            sizes: sizes.map(sizeLabel), chromeHeight: Double(chrome), sections: [], global: [],
            globalLayouts: [], auxiliary: [], failures: [], notes: [], seconds: 0, passed: false)

        if let reason = shell.blockedReason {
            stage = "blocked shell"
            notes.append("Shell is blocked (\(reason)); sections were not opened.")
            for size in sizes {
                resize(to: size)
                var layout = layoutReport(size: size, context: "blocked", sectionID: nil)
                layout.png = capture(named: "blocked-\(sizeLabel(size)).png")
                report.globalLayouts.append(layout)
            }
        } else {
            let all = shell.sections
            let chosen: [UITestSection]
            if options.target == "all" {
                chosen = all
            } else {
                chosen = all.filter { $0.id == options.target || $0.moduleID == options.target }
            }
            if chosen.isEmpty {
                fputs("uitest: no section or module \"\(options.target)\". Known: \(all.map(\.id).joined(separator: ", "))\n", stderr)
                exit(2)
            }
            testedSections = Set(chosen.map(\.id))
            var darkDone = Set<String>()
            for section in chosen {
                let moduleKey = section.moduleID ?? section.id
                let dark = !options.dark && !darkDone.contains(moduleKey)
                darkDone.insert(moduleKey)
                let r = runSection(section, sizes: sizes, dark: dark)
                report.sections.append(r)
                print(sectionLine(r))
            }
            if options.interactions {
                runGlobal(&report, sizes: sizes, home: chosen.first!.id)
            }
        }
        runAuxiliary(&report)

        // Collect failures.
        for s in report.sections { report.failures += s.failures }
        for layout in report.globalLayouts {
            for c in layout.checks where c.status == .fail { report.failures.append("[\(layout.section ?? "window"), \(layout.context) @ \(layout.size)] \(c.name): \(c.detail)") }
        }
        for c in report.global where c.status == .fail { report.failures.append("[global] \(c.name): \(c.detail)") }
        for c in report.auxiliary where c.status == .fail { report.failures.append("[auxiliary] \(c.name): \(c.detail)") }
        report.notes = notes
        report.seconds = Date().timeIntervalSince(started)
        report.passed = report.failures.isEmpty

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let reportURL = options.outDir.appendingPathComponent("report.json")
        if let data = try? encoder.encode(report) { try? data.write(to: reportURL, options: .atomic) }

        print("")
        if !report.global.isEmpty {
            print("== interactions (window)")
            for c in report.global { print("  [\(c.status.rawValue.uppercased())] \(c.name)\(c.detail.isEmpty ? "" : " — " + c.detail)") }
        }
        for c in report.auxiliary { print("  [\(c.status.rawValue.uppercased())] \(c.name)\(c.detail.isEmpty ? "" : " — " + c.detail)") }
        for note in notes { print("  note: \(note)") }
        print("")
        if report.failures.isEmpty {
            print(String(format: "UI test OK — %d section(s), %d size(s), %.1fs. Report: %@", report.sections.count, sizes.count, report.seconds, reportURL.path))
        } else {
            print("UI test: \(report.failures.count) failure(s)")
            for f in report.failures { print("  FAIL \(f)") }
            print(String(format: "%d section(s), %d size(s), %.1fs. Report: %@", report.sections.count, sizes.count, report.seconds, reportURL.path))
        }
        exit(report.failures.isEmpty ? 0 : 1)
    }

    // MARK: Screenshot

    /// `--screenshot`: one picture of the real window shell (title bar, toolbar, sidebar)
    /// showing one section, drawn in-process from the same off-screen window `--uitest`
    /// uses. Nothing is tested; the exit status only says whether the PNG was written.
    public static func screenshot(shell: UITestShell, request: ScreenshotRequest) -> Never {
        self.shell = shell
        options = UITestOptions()
        options.dark = request.dark
        options.screen = CGSize(width: max(request.size.width, 600), height: max(request.size.height, 400))
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let appearance = NSAppearance(named: request.dark ? .darkAqua : .aqua)
        app.appearance = appearance
        SnapshotReadiness.isSnapshotting = true

        let all = shell.sections
        let target = all.first { $0.id == request.target } ?? all.first { $0.moduleID == request.target }
        if target == nil, request.search == nil, shell.blockedReason == nil {
            fputs("screenshot: no section or module \"\(request.target)\". Use --list.\n", stderr)
            exit(2)
        }
        // Only the shown module's sidebar group is expanded, so the selected row is in
        // view. The argument domain wins over the persistent one and is never written.
        var argumentDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let keep = target?.moduleID
        argumentDomain["collapsedModules"] = Set(all.compactMap(\.moduleID)).filter { $0 != keep }.sorted().joined(separator: ",")
        UserDefaults.standard.setVolatileDomain(argumentDomain, forName: UserDefaults.argumentDomain)

        let window = UITestWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: request.size.width, height: request.size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.maximumFrameSize = options.screen
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.toolbarStyle = .unified
        let hosting = NSHostingView(rootView: shell.makeRootView())
        window.contentView = hosting
        self.window = window
        self.hosting = hosting
        pump(0.4)
        window.layoutIfNeeded()
        // The requested size is the whole window, title bar included.
        window.setFrame(NSRect(x: -30_000, y: -30_000, width: request.size.width, height: request.size.height), display: true)
        pump(0.2)

        if shell.blockedReason == nil {
            shell.privacyMode = request.privacy
            if let target {
                if let payload = request.payload, shell.open(section: target.id, payload: payload) {} else { shell.selection = target.id }
                settle(timeout: request.timeout)
            }
            if let query = request.search, shell.hasSearch {
                shell.searchText = query
                let deadline = Date().addingTimeInterval(request.timeout)
                pump(0.6)
                while Date() < deadline, shell.searchIsRunning { pump(0.1) }
            }
        }
        // Loads that only start once the first ones are on screen (inspectors, static maps).
        settle(timeout: request.timeout)
        pump(request.linger)
        settle(timeout: request.timeout)
        let spinners = visibleSpinners()
        if spinners > 0 { fputs("screenshot: \(spinners) progress indicator(s) still visible; capturing anyway\n", stderr) }

        do {
            try FileManager.default.createDirectory(at: request.out.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard try capture(to: request.out, scale: request.scale) else {
                fputs("screenshot: could not draw the window\n", stderr)
                exit(1)
            }
        } catch {
            fputs("screenshot: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        let frame = window.frame.size
        print("screenshot: wrote \(request.out.path) (\(Int((frame.width * request.scale).rounded()))x\(Int((frame.height * request.scale).rounded())))")
        exit(0)
    }

    // MARK: Per section

    /// Size the window has while navigating between sections (a comfortable default, so
    /// one section's broken minimum-size layout does not make the next click miss).
    private static let navigationSize = CGSize(width: 1360, height: 860)

    private static var interactionSize = CGSize(width: 980, height: 600)

    private static func runSection(_ section: UITestSection, sizes: [CGSize], dark: Bool) -> UITestSectionReport {
        stage = "section \(section.id): navigate"
        var interactions: [UITestCheck] = []
        var r = UITestSectionReport(id: section.id, module: section.moduleID, loadSeconds: 0, loadTimedOut: false, layouts: [], interactions: [], failures: [])

        // Navigate by clicking the sidebar row, as a user does.
        resize(to: navigationSize)
        if options.interactions {
            interactions.append(clickSidebar(section.id))
        }
        if shell.selection != section.id {
            shell.selection = section.id
        }
        stage = "section \(section.id): load"
        let load = settle(timeout: options.loadTimeout)
        r.loadSeconds = load.seconds
        r.loadTimedOut = load.timedOut
        interactions += loadChecks(load, name: "load")

        let safe = fileSafe(section.id)
        runState(section, sizes: sizes, dark: dark, context: "initial", filePrefix: safe, report: &r, interactions: &interactions)

        // Further states: the tabs / modes a deep link selects.
        var payloads = section.payloads
        if let extra = options.payload, section.id == options.target, !payloads.contains(extra) { payloads.append(extra) }
        for (index, payload) in payloads.enumerated() {
            let label = "payload \(index + 1)"
            stage = "section \(section.id): \(label)"
            resize(to: navigationSize)
            guard shell.open(section: section.id, payload: payload), shell.selection == section.id else {
                interactions.append(.skip(label, "this shell cannot deliver deep links; payload \"\(payload)\" not tested"))
                continue
            }
            let load = settle(timeout: options.loadTimeout)
            interactions.append(.info(label, "opened with deep-link payload \"\(payload)\""))
            interactions += loadChecks(load, name: "\(label) load")
            runState(section, sizes: sizes, dark: false, context: label, filePrefix: "\(safe)-p\(index + 1)", report: &r, interactions: &interactions)
        }

        r.interactions = interactions
        for layout in r.layouts {
            for c in layout.checks where c.status == .fail {
                r.failures.append("[\(section.id) @ \(layout.size)\(layout.context == "initial" ? "" : ", " + layout.context)] \(c.name): \(c.detail)")
            }
        }
        for c in interactions where c.status == .fail {
            r.failures.append("[\(section.id)] \(c.name): \(c.detail)")
        }
        return r
    }

    private static func loadChecks(_ load: (seconds: Double, timedOut: Bool, spinners: Int), name: String) -> [UITestCheck] {
        var out: [UITestCheck] = []
        if load.timedOut {
            out.append(.fail(name, "still \(SnapshotReadiness.pending) load(s) pending after \(Int(options.loadTimeout))s"))
        } else if load.spinners > 0 {
            out.append(.fail(name, "\(load.spinners) progress indicator(s) still spinning in the section \(String(format: "%.1f", load.seconds))s after every tracked load finished: the captures show a loading state (a loader that does not report to SnapshotReadiness, or a load that never ends)"))
        }
        return out
    }

    /// Invariants and captures at every size for the state the section is in, then — at the
    /// smallest size — scrolling (with captures further down the page), the table-room
    /// check and the first-row click with the "row selected" layout.
    private static func runState(_ section: UITestSection, sizes: [CGSize], dark: Bool, context: String, filePrefix: String,
                                 report r: inout UITestSectionReport, interactions: inout [UITestCheck]) {
        let tag = context == "initial" ? "" : context + " "
        for (index, size) in sizes.enumerated() {
            stage = "section \(section.id): \(tag)layout \(sizeLabel(size))"
            resize(to: size)
            var layout = layoutReport(size: size, context: context, sectionID: section.id)
            layout.png = capture(named: "\(filePrefix)-\(sizeLabel(size)).png")
            if dark && index == 0 {
                setDark(true)
                layout.pngDark = capture(named: "\(filePrefix)-\(sizeLabel(size))-dark.png")
                setDark(false)
            }
            r.layouts.append(layout)
        }
        guard options.interactions else { return }

        let small = interactionSize
        stage = "section \(section.id): \(tag)scroll"
        resize(to: small)
        let scrolled = scrollDetail(capturePrefix: "\(filePrefix)-\(sizeLabel(small))")
        interactions.append(renamed(scrolled.check, tag))
        if !scrolled.pngs.isEmpty, let i = r.layouts.lastIndex(where: { $0.context == context && $0.size == sizeLabel(small) }) {
            r.layouts[i].pngScrolled = scrolled.pngs
        }
        interactions.append(renamed(tableRoom(at: small), tag))
        stage = "section \(section.id): \(tag)table"
        let table = clickFirstTableRow()
        interactions.append(renamed(table.check, tag))
        if table.changedLayout {
            // A selection usually opens the inspector: the tightest layout of the section.
            stage = "section \(section.id): \(tag)layout with selection"
            var layout = layoutReport(size: small, context: context == "initial" ? "row selected" : context + ", row selected", sectionID: section.id)
            layout.png = capture(named: "\(filePrefix)-\(sizeLabel(small))-selected.png")
            r.layouts.append(layout)
            clearTableSelection()
        }
    }

    private static func renamed(_ check: UITestCheck, _ tag: String) -> UITestCheck {
        guard !tag.isEmpty else { return check }
        var c = check
        c.name = tag + c.name
        return c
    }

    private static func sectionLine(_ r: UITestSectionReport) -> String {
        let status = r.failures.isEmpty ? "PASS" : "FAIL"
        let n = r.layouts.first?.numbers ?? [:]
        func v(_ key: String) -> String { n[key].map { String(Int($0.rounded())) } ?? "–" }
        var line = "[\(status)] \(r.id.padding(toLength: 26, withPad: " ", startingAt: 0)) "
        line += String(format: "load %4.1fs  ", r.loadSeconds)
        line += "contentMin \(v("contentMinWidth"))x\(v("contentMinHeight"))  sectionMin \(v("sectionMinWidth"))x\(v("sectionMinHeight"))  ideal \(v("sectionIdealWidth"))  sidebar \(v("sidebarWidth"))"
        let inter = r.interactions.map { "\($0.name)=\($0.status.rawValue)" }.joined(separator: " ")
        if !inter.isEmpty { line += "  | " + inter }
        for f in r.failures { line += "\n       " + f }
        return line
    }

    // MARK: Layout invariants

    /// Width left for a section in the minimum window with the sidebar at its narrowest
    /// (the split view squeezes the sidebar before it overflows) minus the divider.
    private static var detailBudget: CGFloat {
        shell.minimumSize.width - shell.sidebarWidthRange.lowerBound - 1
    }

    private static func layoutReport(size: CGSize, context: String, sectionID: String?) -> UITestSizeReport {
        var numbers: [String: Double] = [:]
        var checks: [UITestCheck] = []
        let minimum = shell.minimumSize
        let tolerance: CGFloat = 1

        // 1. The window has the size that was asked for (content did not force it larger).
        let frame = window.frame
        let content = window.contentRect(forFrameRect: frame).size
        let wantedHeight = size.height + chrome
        numbers["windowWidth"] = Double(frame.width)
        numbers["windowHeight"] = Double(frame.height)
        numbers["requestedWidth"] = Double(size.width)
        numbers["requestedHeight"] = Double(size.height)
        let layoutWidth = hosting.frame.width
        let layoutHeight = hosting.frame.height - chrome
        numbers["contentLayoutWidth"] = Double(layoutWidth)
        numbers["contentLayoutHeight"] = Double(layoutHeight)
        checks.append(.check(
            "window-size",
            abs(content.width - size.width) <= tolerance && abs(hosting.frame.height - wantedHeight) <= tolerance && abs(hosting.frame.width - content.width) <= tolerance,
            "requested \(sizeLabel(size)), window content \(fmt(content.width))x\(fmt(content.height - chrome)), hosted view \(fmt(layoutWidth))x\(fmt(layoutHeight))"))

        // 2. Minimum / ideal size of the whole content.
        let fitting = hosting.fittingSize
        numbers["fittingWidth"] = Double(fitting.width)
        numbers["fittingHeight"] = Double(fitting.height - chrome)
        if let root = UITestProbe.displayedPlacement(scope: "root") {
            numbers["contentMinWidth"] = Double(root.minimum.width)
            numbers["contentMinHeight"] = Double(root.minimum.height)
            numbers["contentIdealWidth"] = Double(root.ideal.width)
            numbers["contentIdealHeight"] = Double(root.ideal.height)
            let minOK = root.minimum.width <= minimum.width + tolerance && root.minimum.height <= minimum.height + tolerance
            checks.append(.check(
                "content-min", minOK,
                "window content minimum (zero proposal) \(fmt(root.minimum.width))x\(fmt(root.minimum.height)), allowed \(sizeLabel(minimum))" + (minOK ? "" : culprits())))
            // AppKit's own answer. It can exceed the SwiftUI minimum without binding the
            // window (seen after re-showing a collapsed sidebar), so on its own it is only
            // reported; `window-size` fails when the window really cannot shrink.
            let fits = fitting.width <= minimum.width + tolerance && fitting.height - chrome <= minimum.height + tolerance
            checks.append(UITestCheck(name: "appkit-fitting", status: fits ? .pass : .info,
                                      detail: "NSHostingView.fittingSize \(fmt(fitting.width))x\(fmt(fitting.height - chrome))", numbers: nil))
            checks.append(.check(
                "content-ideal", root.ideal.width <= 3000,
                "window content ideal \(fmt(root.ideal.width))x\(fmt(root.ideal.height)) (limit 3000 wide)"))
        } else {
            checks.append(.fail("content-min", "the root probe reported nothing (window content was never laid out)"))
        }

        // 3. Split view: sidebar present and inside its range, detail inside the window.
        let panes = panes()
        if let split = splitView(), panes.count >= 2 {
            let sidebar = panes[0].convert(panes[0].bounds, to: nil)
            let detail = panes[panes.count - 1].convert(panes[panes.count - 1].bounds, to: nil)
            let collapsed = split.isSubviewCollapsed(panes[0]) || sidebar.width < 1 || sidebar.maxX <= 0.5
            numbers["sidebarWidth"] = collapsed ? 0 : Double(sidebar.width)
            numbers["sidebarMinX"] = Double(sidebar.minX)
            numbers["detailMinX"] = Double(detail.minX)
            numbers["detailWidth"] = Double(detail.width)
            numbers["detailMaxX"] = Double(detail.maxX)
            let range = shell.sidebarWidthRange
            if context == "sidebar hidden" {
                checks.append(.check("sidebar", collapsed, collapsed ? "collapsed" : "still \(fmt(sidebar.width)) wide"))
            } else {
                let ok = !collapsed && sidebar.minX >= -tolerance
                    && sidebar.width >= range.lowerBound - tolerance && sidebar.width <= range.upperBound + tolerance
                checks.append(.check("sidebar", ok, "sidebar x \(fmt(sidebar.minX)) width \(fmt(sidebar.width)), expected x 0 and width \(fmt(range.lowerBound))…\(fmt(range.upperBound))"))
            }
            checks.append(.check(
                "detail-in-window", detail.minX >= -tolerance && detail.maxX <= frame.width + tolerance && detail.width > 100,
                "detail column x \(fmt(detail.minX))…\(fmt(detail.maxX)) in a window \(fmt(frame.width)) wide"))
        } else {
            checks.append(.fail("sidebar", "no split view with two panes found in the window"))
        }

        // 4. The section itself: takes no more than the detail column offers.
        if let sectionID {
            if let s = UITestProbe.displayedPlacement(scope: sectionID) {
                numbers["sectionProposedWidth"] = Double(s.proposedWidth ?? -1)
                numbers["sectionProposedHeight"] = Double(s.proposedHeight ?? -1)
                numbers["sectionPlacedWidth"] = Double(s.placed.width)
                numbers["sectionPlacedHeight"] = Double(s.placed.height)
                numbers["sectionMinWidth"] = Double(s.minimum.width)
                numbers["sectionMinHeight"] = Double(s.minimum.height)
                numbers["sectionIdealWidth"] = Double(s.ideal.width)
                numbers["sectionIdealHeight"] = Double(s.ideal.height)
                checks.append(.check(
                    "section-fits", s.horizontalOverflow <= tolerance && s.verticalOverflow <= tolerance,
                    "section laid out \(fmt(s.placed.width))x\(fmt(s.placed.height)) in a detail column offering \(fmt(s.proposedWidth))x\(fmt(s.proposedHeight))"
                        + (s.horizontalOverflow > tolerance ? " — \(fmt(s.horizontalOverflow)) pt clipped horizontally" : "")
                        + (s.verticalOverflow > tolerance ? " — \(fmt(s.verticalOverflow)) pt clipped vertically" : "")))
                // Budget at the window minimum: what is left of the minimum width beside the
                // sidebar as it is now, and the minimum height.
                let budget = detailBudget
                let sidebarNow = CGFloat(numbers["sidebarWidth"] ?? 0)
                numbers["sectionMinWidthBudget"] = Double(budget)
                numbers["sectionMinWidthBudgetCurrentSidebar"] = Double(minimum.width - sidebarNow - 1)
                numbers["sectionMinWidthBudgetWidestSidebar"] = Double(minimum.width - shell.sidebarWidthRange.upperBound - 1)
                var note = ""
                if s.minimum.width > minimum.width - sidebarNow - 1 + tolerance, sidebarNow > 0, s.minimum.width <= budget + tolerance {
                    note = " (fits only by squeezing the sidebar below its current \(fmt(sidebarNow)))"
                }
                checks.append(.check(
                    "section-min", s.minimum.width <= budget + tolerance && s.minimum.height <= minimum.height + tolerance,
                    "section minimum \(fmt(s.minimum.width))x\(fmt(s.minimum.height)); the minimum window leaves \(fmt(budget))x\(fmt(minimum.height)) beside the narrowest sidebar" + note))
                checks.append(.check(
                    "section-ideal", s.ideal.width <= 3000,
                    "section ideal \(fmt(s.ideal.width))x\(fmt(s.ideal.height)) (limit 3000 wide)"))
            } else if let shown = UITestProbe.committedSize(scope: sectionID) {
                numbers["sectionPlacedWidth"] = Double(shown.width)
                numbers["sectionPlacedHeight"] = Double(shown.height)
                checks.append(.fail("section-fits", "section is displayed \(fmt(shown.width))x\(fmt(shown.height)) but no layout pass with that size was recorded, so its proposal and minimum are unknown"))
            } else {
                checks.append(.fail("section-fits", "no section probe for \(sectionID): the shell did not wrap it in uiTestSection(_:) or it was never laid out"))
            }
            // Content of clipping containers (ScrollPage, inspector bodies).
            let inner = UITestProbe.scrollContents(scope: sectionID)
            let bad = inner.filter { $0.horizontalOverflow > tolerance }
            numbers["innerProbes"] = Double(inner.count)
            if !inner.isEmpty {
                numbers["innerMaxOverflow"] = Double(inner.map(\.horizontalOverflow).max() ?? 0)
            }
            checks.append(.check(
                "scroll-content-fits", bad.isEmpty,
                bad.isEmpty
                    ? "\(inner.count) scrolling container(s), none wider than its viewport"
                    : bad.map { "\($0.kind) content is \(fmt($0.placed.width)) wide in a \(fmt($0.proposedWidth)) wide viewport — \(fmt($0.horizontalOverflow)) pt clipped" }.joined(separator: "; ")))
        }

        // 5. AppKit view of the same thing: a non-table scroll view whose document is wider
        //    than its viewport scrolls / clips horizontally.
        var wide: [String] = []
        for scroll in visibleScrollViews() {
            guard let doc = scroll.documentView, !(doc is NSTableView), !(doc is NSTextView) else { continue }
            // A SwiftUI ScrollView that scrolls vertically only has no horizontal elasticity;
            // anything else scrolls sideways on purpose.
            if scroll.hasHorizontalScroller || scroll.horizontalScrollElasticity != .none { continue }
            let excess = doc.frame.width - scroll.contentView.bounds.width
            if excess > tolerance {
                wide.append("\(type(of: doc)) \(fmt(doc.frame.width)) wide in a \(fmt(scroll.contentView.bounds.width)) viewport")
            }
        }
        checks.append(.check("appkit-scroll-width", wide.isEmpty, wide.isEmpty ? "no scroll view document wider than its viewport" : wide.joined(separator: "; ")))

        // 6. Pop-up buttons (menu pickers, menus) squeezed to a sliver. `ViewThatFits` with
        //    three or more flat alternatives does this to the pop-ups of the later ones.
        if let detail = detailPane() {
            let slivers = allViews(of: NSPopUpButton.self, in: detail)
                .filter { isVisible($0) && $0.frame.width < 20 && $0.frame.height > 4 && !$0.visibleRect.isEmpty }
            numbers["popUpSlivers"] = Double(slivers.count)
            checks.append(.check("popup-width", slivers.isEmpty,
                                 slivers.isEmpty ? "no pop-up button narrower than 20 pt"
                                    : "\(slivers.count) pop-up button(s) squeezed to \(slivers.map { fmt($0.frame.width) }.joined(separator: ", ")) pt wide (intrinsic \(slivers.map { fmt($0.intrinsicContentSize.width) }.joined(separator: ", ")))"))
        }

        // 7. Toolbar: nothing pushed into the overflow menu.
        if let toolbar = window.toolbar {
            // Separators and spaces have no view and are never "visible".
            let all = toolbar.items.filter { !($0 is NSTrackingSeparatorToolbarItem) && !$0.itemIdentifier.rawValue.lowercased().contains("space") && !$0.itemIdentifier.rawValue.lowercased().contains("separator") }
            let visible = toolbar.visibleItems ?? []
            let hidden = all.filter { item in !visible.contains(where: { $0 === item }) }
            numbers["toolbarItems"] = Double(all.count)
            numbers["toolbarHidden"] = Double(hidden.count)
            checks.append(.check("toolbar", hidden.isEmpty, hidden.isEmpty ? "\(all.count) item(s), all visible" : "\(hidden.count) of \(all.count) toolbar item(s) in the overflow menu: \(hidden.map { $0.label.isEmpty ? $0.itemIdentifier.rawValue : $0.label }.joined(separator: ", "))"))
        } else {
            checks.append(.info("toolbar", "the window has no toolbar"))
        }

        return UITestSizeReport(size: sizeLabel(size), section: sectionID, context: context, numbers: numbers, checks: checks, png: nil, pngDark: nil, pngScrolled: nil)
    }

    /// Names the hosted sections (the visible one and hidden kept-alive ones) whose own
    /// minimum exceeds what the minimum window can offer — the usual cause of a window
    /// minimum that is too large.
    private static func culprits() -> String {
        let minimum = shell.minimumSize
        let bad = UITestProbe.sectionScopes().compactMap { UITestProbe.displayedPlacement(scope: $0) }
            .filter { $0.minimum.width > detailBudget + 1 || $0.minimum.height > minimum.height + 1 }
        guard !bad.isEmpty else { return "" }
        return " — caused by: " + bad.map { "\($0.scope) (minimum \(fmt($0.minimum.width))x\(fmt($0.minimum.height)))" }.joined(separator: ", ")
    }

    // MARK: Interactions

    private static func clickSidebar(_ id: String) -> UITestCheck {
        guard let row = shell.sidebarRow(for: id) else { return .skip("sidebar-click", "the shell has no sidebar row for \(id)") }
        guard let table = sidebarTable() else { return .fail("sidebar-click", "no sidebar list found in the window") }
        guard row < table.numberOfRows else {
            return .fail("sidebar-click", "sidebar has \(table.numberOfRows) rows, expected row \(row) for \(id)")
        }
        // Move away first so that a click on the already selected row still proves something.
        if shell.selection == id, let other = shell.sections.first(where: { $0.id != id }) {
            shell.selection = other.id
            pump(0.1)
        }
        // With margin: the bottom of the list is covered by the sidebar's footer bar.
        table.scrollToVisible(table.rect(ofRow: row).insetBy(dx: 0, dy: -90))
        pump(0.05)
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: min(rect.midX, rect.minX + 80), y: rect.midY), to: nil)
        click(at: point)
        pump(0.1)
        if shell.selection == id {
            return .pass("sidebar-click", "clicked row \(row), selection changed")
        }
        return .fail("sidebar-click", "clicked sidebar row \(row) for \(id), selection is \(shell.selection ?? "nil")")
    }

    /// Clicks every row of the sidebar (section rows, group headers, module disclosure rows)
    /// and fails when the selection ever becomes something that is not a destination.
    private static func clickEverySidebarRow() -> UITestCheck {
        guard let table = sidebarTable() else { return .skip("sidebar-every-row", "no sidebar list found in the window") }
        let valid = Set(shell.sections.map(\.id))
        var bad: [String] = []
        let rows = table.numberOfRows
        for row in 0..<rows {
            table.scrollToVisible(table.rect(ofRow: row).insetBy(dx: 0, dy: -90))
            pump(0.03)
            let rect = table.rect(ofRow: row)
            click(at: table.convert(NSPoint(x: min(rect.midX, rect.minX + 80), y: rect.midY), to: nil))
            pump(0.06)
            if let selection = shell.selection, !valid.contains(selection) {
                bad.append("row \(row) selected \"\(selection)\"")
                if let first = shell.sections.first { shell.selection = first.id; pump(0.03) }
            }
        }
        return .check("sidebar-every-row", bad.isEmpty,
                      bad.isEmpty ? "clicked all \(rows) rows; the selection was always a real section"
                        : "selection became a non-section: " + bad.joined(separator: "; "))
    }

    /// Fails when a table or list with rows has room for fewer than three of them at the
    /// smallest size (a table squeezed to its header by tiles, strips and footers).
    private static func tableRoom(at size: CGSize) -> UITestCheck {
        let sidebar = sidebarTable()
        let tables = allViews(of: NSTableView.self, in: detailPane() ?? hosting)
            .filter { $0 !== sidebar && isVisible($0) && $0.numberOfRows >= 3 && $0.frame.width > 40 }
        guard !tables.isEmpty else { return .skip("table-room", "no table or list with three or more rows") }
        var cramped: [String] = []
        var smallest = CGFloat.infinity
        for table in tables {
            guard let clip = table.enclosingScrollView?.contentView else { continue }
            let row = table.rect(ofRow: 0).height + table.intercellSpacing.height
            // The clip view also holds the header of a SwiftUI Table.
            let room = clip.bounds.height - (table.headerView?.frame.height ?? 0)
            smallest = min(smallest, room / max(row, 1))
            if room < row * 3 - 1 {
                cramped.append("\(type(of: table)) with \(table.numberOfRows) rows shows \(fmt(max(0, room))) pt of rows (\(String(format: "%.1f", Double(max(0, room) / max(row, 1)))) rows)")
            }
        }
        return .check("table-room", cramped.isEmpty,
                      cramped.isEmpty ? "\(tables.count) table(s) / list(s), each shows at least three rows at \(sizeLabel(size))"
                        : "at \(sizeLabel(size)): " + cramped.joined(separator: "; "),
                      smallest.isFinite ? ["fewestVisibleRows": Double(smallest)] : nil)
    }

    private static func scrollDetail(capturePrefix: String) -> (check: UITestCheck, pngs: [String]) {
        let candidates = visibleScrollViews().filter { scroll in
            guard let doc = scroll.documentView else { return false }
            return doc.frame.height > scroll.contentView.bounds.height + 20
        }
        guard let scroll = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            return (.skip("scroll", "nothing in the detail column is taller than its viewport at \(sizeLabel(interactionSize))"), [])
        }
        let clip = scroll.contentView
        let before = clip.bounds.origin.y
        var method = "scroll-wheel event"
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -160, wheel2: 0, wheel3: 0),
           let event = NSEvent(cgEvent: cg) {
            // Delivered straight to the scroll view (never posted to the system).
            scroll.scrollWheel(with: event)
            pump(0.25)
        }
        var after = clip.bounds.origin.y
        if abs(after - before) < 1 {
            // Flipped documents scroll the other way round.
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 160, wheel2: 0, wheel3: 0),
               let event = NSEvent(cgEvent: cg) {
                scroll.scrollWheel(with: event)
                pump(0.25)
            }
            after = clip.bounds.origin.y
        }
        if abs(after - before) < 1 {
            method = "programmatic scroll (wheel event had no effect)"
            let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(maxY, before + 160)))
            scroll.reflectScrolledClipView(clip)
            pump(0.15)
            after = clip.bounds.origin.y
        }
        let moved = abs(after - before) >= 1
        // Pages further down (not for tables: more rows of the same). Up to three
        // captures, a viewport apart, the last one at the end of the content.
        var pngs: [String] = []
        if let doc = scroll.documentView, !(doc is NSTableView) {
            let page = max(40, clip.bounds.height * 0.9)
            let maxY = max(0, doc.frame.height - clip.bounds.height)
            let down: CGFloat = doc.isFlipped ? 1 : -1
            var targets: [CGFloat] = []
            for k in 1...3 {
                let y = min(maxY, max(0, before + down * page * CGFloat(k)))
                if let last = targets.last, abs(last - y) < 1 { break }
                if abs(y - before) >= 1 { targets.append(y) }
            }
            if let last = targets.last, targets.count == 3 { targets[2] = doc.isFlipped ? max(last, maxY) : min(last, 0) }
            for (index, y) in targets.enumerated() {
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                scroll.reflectScrolledClipView(clip)
                pump(0.15)
                if SnapshotReadiness.pending > 0 { settle(timeout: 6) }
                if let png = capture(named: "\(capturePrefix)-scrolled\(index + 1).png") { pngs.append(png) }
            }
        }
        // Back to the top so later captures are comparable.
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: before))
        scroll.reflectScrolledClipView(clip)
        pump(0.05)
        let more = pngs.isEmpty ? "" : "; \(pngs.count) capture(s) further down the page"
        return (.check("scroll", moved, "\(method): offset \(fmt(before)) → \(fmt(after))\(more)", ["before": Double(before), "after": Double(after), "captures": Double(pngs.count)]), pngs)
    }

    private static func clickFirstTableRow() -> (check: UITestCheck, changedLayout: Bool) {
        let sidebar = sidebarTable()
        let tables = allViews(of: NSTableView.self, in: detailPane() ?? hosting)
            .filter { $0 !== sidebar && isVisible($0) && $0.numberOfRows > 0 && $0.frame.width > 40 }
        guard let table = tables.max(by: { $0.visibleRect.width * $0.visibleRect.height < $1.visibleRect.width * $1.visibleRect.height }) else {
            return (.skip("table-click", "no table or list with rows in this section"), false)
        }
        // Click the first rows until one becomes selected (header rows and an already
        // selected row prove nothing).
        let selectedBefore = table.selectedRowIndexes
        let inspectorsBefore = UITestProbe.inspectorCount
        var clicked: [Int] = []
        var selectedRow: Int?
        for row in 0..<min(table.numberOfRows, 5) where !selectedBefore.contains(row) {
            if table.delegate?.tableView?(table, isGroupRow: row) == true { continue }
            table.scrollRowToVisible(row)
            pump(0.05)
            let rect = table.rect(ofRow: row).intersection(table.visibleRect)
            if rect.isEmpty { continue }
            clicked.append(row)
            click(at: table.convert(NSPoint(x: rect.minX + min(60, rect.width / 2), y: rect.midY), to: nil))
            pump(0.2)
            if table.selectedRowIndexes.contains(row) { selectedRow = row; break }
        }
        let kind = String(describing: type(of: table))
        guard let selectedRow else {
            if clicked.isEmpty { return (.skip("table-click", "\(kind): none of the first rows is clickable"), false) }
            return (.fail("table-click", "\(kind) with \(table.numberOfRows) row(s): clicked row(s) \(clicked), none became selected (selection \(Array(selectedBefore)) → \(Array(table.selectedRowIndexes)))"), false)
        }
        settle(timeout: 6)
        let inspector = UITestProbe.inspectorCount > inspectorsBefore
        var detail = "\(kind) with \(table.numberOfRows) row(s): clicked row \(selectedRow), it became selected"
        detail += inspector ? ", the shared inspector opened" : ", no shared detailInspector appeared (the section may show details elsewhere or not at all)"
        return (.pass("table-click", detail, ["rows": Double(table.numberOfRows), "inspectorOpened": inspector ? 1 : 0]), true)
    }

    /// Clears table selections in the visible section so its inspector closes before the
    /// next section is visited (kept-alive sections stay in the layout).
    private static func clearTableSelection() {
        let sidebar = sidebarTable()
        for table in allViews(of: NSTableView.self, in: detailPane() ?? hosting) where table !== sidebar && isVisible(table) {
            if !table.selectedRowIndexes.isEmpty, table.allowsEmptySelection { table.deselectAll(nil) }
        }
        pump(0.25)
    }

    private static func runGlobal(_ report: inout UITestReport, sizes: [CGSize], home: String) {
        let minimum = shell.minimumSize
        let large = sizes.max(by: { $0.width < $1.width }) ?? minimum
        func goHome() {
            shell.searchText = ""
            shell.selection = home
            settle(timeout: options.loadTimeout)
        }

        // Live resize: large → minimum → large, invariants after each step.
        stage = "global: live resize"
        goHome()
        var resizeFailures: [String] = []
        for (step, size) in [large, minimum, large, minimum].enumerated() {
            animateResize(to: size)
            var layout = layoutReport(size: size, context: "live resize step \(step + 1)", sectionID: home)
            layout.png = capture(named: "resize-\(step + 1)-\(sizeLabel(size)).png")
            resizeFailures += layout.checks.filter { $0.status == .fail }.map { "\(sizeLabel(size)): \($0.name)" }
            report.globalLayouts.append(layout)
        }
        report.global.append(.check("live-resize", resizeFailures.isEmpty, resizeFailures.isEmpty ? "\(sizeLabel(large)) → \(sizeLabel(minimum)) → \(sizeLabel(large)) → \(sizeLabel(minimum)) in steps, invariants hold at each end" : resizeFailures.joined(separator: "; ")))

        // Below the minimum: the window must refuse.
        stage = "global: below minimum"
        let tiny = CGSize(width: minimum.width - 300, height: minimum.height - 200)
        setContentSize(tiny)
        pump(0.15)
        let got = hosting.frame.size
        report.global.append(.check(
            "refuses-below-minimum", got.width >= minimum.width - 1 && got.height - chrome >= minimum.height - 1,
            "asked for \(sizeLabel(tiny)), window content stayed \(fmt(got.width))x\(fmt(got.height - chrome))"))
        resize(to: minimum)

        // Every sidebar row, including group headers and module disclosure rows.
        stage = "global: every sidebar row"
        resize(to: large)
        report.global.append(clickEverySidebarRow())
        goHome()
        resize(to: minimum)

        // Sidebar toggle.
        stage = "global: sidebar toggle"
        report.global.append(contentsOf: toggleSidebar(&report, home: home))

        // Privacy mode.
        stage = "global: privacy"
        report.global.append(togglePrivacy())

        // Global search.
        stage = "global: search"
        resize(to: CGSize(width: 1360, height: 860))
        report.global.append(contentsOf: search(&report))
        goHome()
    }

    private static func toggleSidebar(_ report: inout UITestReport, home: String) -> [UITestCheck] {
        guard let split = splitView() else { return [.fail("sidebar-toggle", "no split view")] }
        var checks: [UITestCheck] = []
        var method = ""
        func isCollapsed() -> Bool {
            guard let first = panes().first else { return true }
            let rect = first.convert(first.bounds, to: nil)
            return split.isSubviewCollapsed(first) || rect.width < 1 || rect.maxX <= 0.5
        }
        /// Clicks the toolbar's sidebar button and waits for the animated collapse. AppKit
        /// only runs that animation while the display is awake; with the display asleep
        /// (or if the click had no effect) the split view item is collapsed directly,
        /// without animation, and the result says so.
        func toggle(expectCollapsed: Bool) -> Bool {
            // Layout passes *during* the animation keep restarting it: plain run-loop
            // turns, one layout, then look.
            func wait() -> Bool {
                for _ in 0..<2 {
                    spin(0.7)
                    pump(0.05)
                    if isCollapsed() == expectCollapsed { return true }
                }
                return false
            }
            let item = (split.delegate as? NSSplitViewController)?.splitViewItems.first
            if displayAsleep {
                method = "display is asleep, so AppKit animations do not run: set NSSplitViewItem.isCollapsed directly instead of clicking"
            } else if let button = toolbarItem(matching: { $0.itemIdentifier == .toggleSidebar || $0.itemIdentifier.rawValue.hasSuffix("toggleSidebar") }), let point = centre(of: button) {
                method = "clicked the toolbar's sidebar button"
                click(at: point)
                if wait() { return true }
                if item?.isCollapsed == expectCollapsed {
                    // The click was taken but the animation never finished. A real
                    // failure, unless the display fell asleep meanwhile (it stops
                    // AppKit's animations): then finish without animation, below.
                    guard displayAsleep else { return false }
                    method = "clicked the toolbar's sidebar button, but the display went to sleep and the animation did not run; set NSSplitViewItem.isCollapsed directly"
                    item?.isCollapsed = !expectCollapsed
                    pump(0.2)
                } else {
                    method = "the click on the toolbar's sidebar button had no effect; set NSSplitViewItem.isCollapsed directly"
                }
            } else {
                method = "no clickable sidebar button in the toolbar; set NSSplitViewItem.isCollapsed directly"
            }
            guard let item else { return false }
            item.isCollapsed = expectCollapsed      // not the animator proxy: immediate
            pump(0.3)
            return isCollapsed() == expectCollapsed
        }
        guard !isCollapsed() else { return [.fail("sidebar-toggle", "sidebar was already collapsed before the test")] }
        let hidden = toggle(expectCollapsed: true)
        var layout = layoutReport(size: shell.minimumSize, context: "sidebar hidden", sectionID: home)
        layout.png = capture(named: "sidebar-hidden.png")
        report.globalLayouts.append(layout)
        if verbose { fputs("uitest: sidebar hide → \(hidden) (\(method))\n", stderr) }
        checks.append(.check("sidebar-toggle-hide", hidden, "\(method): sidebar \(hidden ? "collapsed" : "did not collapse")"))
        let shown = toggle(expectCollapsed: false)
        var back = layoutReport(size: shell.minimumSize, context: "sidebar shown again", sectionID: home)
        back.png = capture(named: "sidebar-shown.png")
        report.globalLayouts.append(back)
        checks.append(.check("sidebar-toggle-show", shown, "\(method): sidebar \(shown ? "came back" : "stayed hidden")"))
        return checks
    }

    private static func togglePrivacy() -> UITestCheck {
        let before = shell.privacyMode
        let plain = capture(named: "privacy-off.png")
        var method = "clicked the toolbar's Privacy Mode toggle"
        if let item = toolbarItem(matching: { ($0.label + " " + ($0.toolTip ?? "") + " " + $0.itemIdentifier.rawValue).localizedCaseInsensitiveContains("privacy") }),
           let point = centre(of: item) {
            click(at: point)
            pump(0.3)
        }
        if shell.privacyMode == before, let point = accessibilityCentre(label: "Privacy Mode") {
            method = "clicked the Privacy Mode control found through the in-process accessibility tree"
            click(at: point)
            pump(0.3)
        }
        guard shell.privacyMode != before else {
            // State-level fallback so the rendering can still be checked.
            shell.privacyMode.toggle()
            pump(0.3)
            _ = capture(named: "privacy-on.png")
            shell.privacyMode = before
            pump(0.2)
            return .fail("privacy-toggle", "could not toggle Privacy Mode through the toolbar with synthesized clicks (toolbar item not found or click had no effect); toggled through shell state only for the capture")
        }
        let redacted = capture(named: "privacy-on.png")
        let differs = plain != nil && redacted != nil && !filesEqual(plain!, redacted!)
        // And back.
        if let item = toolbarItem(matching: { ($0.label + " " + ($0.toolTip ?? "") + " " + $0.itemIdentifier.rawValue).localizedCaseInsensitiveContains("privacy") }),
           let point = centre(of: item) {
            click(at: point)
            pump(0.3)
        }
        if shell.privacyMode != before, let point = accessibilityCentre(label: "Privacy Mode") {
            click(at: point)
            pump(0.3)
        }
        let restored = shell.privacyMode == before
        if !restored { shell.privacyMode = before; pump(0.2) }
        return .check("privacy-toggle", restored, "\(method): state \(before) → \(!before) → \(restored ? "\(before)" : "stuck"); window rendering \(differs ? "changed" : "did not change (the visible section may show nothing private)")")
    }

    private static func search(_ report: inout UITestReport) -> [UITestCheck] {
        guard shell.hasSearch else { return [.skip("search", "this shell has no global search")] }
        guard let field = searchField() else {
            return [.fail("search-type", "no search field found in the window toolbar")]
        }
        var checks: [UITestCheck] = []
        let query = options.query
        guard window.makeFirstResponder(field) else { return [.fail("search-type", "the search field refused first responder")] }
        pump(0.1)
        var method = "synthesized key events"
        for ch in query { key(String(ch)) }
        pump(0.15)
        if shell.searchText != query {
            // Key events are translated by the current keyboard layout / input source and
            // may not yield the intended characters; insert the text into the field editor.
            method = "insertText on the field editor (key events produced \"\(shell.searchText)\")"
            if let editor = window.firstResponder as? NSTextView {
                editor.selectAll(nil)
                editor.insertText(query, replacementRange: editor.selectedRange())
            } else {
                field.stringValue = query
                if let action = field.action { NSApp.sendAction(action, to: field.target, from: field) }
            }
            pump(0.15)
        }
        checks.append(.check("search-type", shell.searchText == query, "\(method): search text is \(shell.searchText == query ? "the query" : "\"\(shell.searchText)\"")"))
        guard shell.searchText == query else { return checks }

        // Wait for hits.
        let deadline = Date().addingTimeInterval(20)
        pump(0.5)
        while Date() < deadline, shell.searchIsRunning || shell.searchHitSections.isEmpty {
            pump(0.1)
            if !shell.searchIsRunning && shell.searchHitSections.isEmpty && Date() > deadline.addingTimeInterval(-17) { break }
        }
        pump(0.3)
        let hits = shell.searchHitSections
        var layout = layoutReport(size: CGSize(width: 1360, height: 860), context: "search results", sectionID: nil)
        layout.png = capture(named: "search-results.png")
        report.globalLayouts.append(layout)
        checks.append(.check("search-results", !hits.isEmpty, "\(hits.count) hit(s) for the query (\(query.count) characters)", ["hits": Double(hits.count)]))
        guard let target = hits.first else { return checks }

        // Activate: Return in the search field opens the first hit.
        if window.firstResponder !== field.currentEditor() { window.makeFirstResponder(field) }
        key("\r", keyCode: 36)
        pump(0.3)
        var how = "Return in the search field"
        if !(shell.selection == target && shell.searchText.isEmpty) {
            if let editor = field.currentEditor() as? NSTextView {
                how = "insertNewline: sent to the field editor (the Return key event did nothing)"
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                pump(0.3)
            }
        }
        settle(timeout: options.loadTimeout)
        checks.append(.check(
            "search-activate", shell.selection == target && shell.searchText.isEmpty,
            "\(how): selection is \(shell.selection ?? "nil"), expected \(target); search text \(shell.searchText.isEmpty ? "cleared" : "not cleared")"))
        var landed = layoutReport(size: CGSize(width: 1360, height: 860), context: "after opening a search hit", sectionID: shell.selection)
        if let section = shell.selection, !testedSections.contains(section) {
            // The hit led into a section outside this run's target: report, do not fail.
            landed.context += " (section outside this run's target: findings are informational)"
            landed.checks = landed.checks.map { c in
                c.status == .fail ? UITestCheck(name: c.name, status: .info, detail: "would fail: " + c.detail, numbers: c.numbers) : c
            }
        }
        landed.png = capture(named: "search-opened.png")
        report.globalLayouts.append(landed)
        return checks
    }

    private static func runAuxiliary(_ report: inout UITestReport) {
        for aux in shell.auxiliaryViews {
            stage = "auxiliary \(aux.name)"
            let saved = (window: window, hosting: hosting)
            let w = UITestWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 300),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .aqua)
            let host = NSHostingView(rootView: aux.view)
            w.contentView = host
            window = w; hosting = host
            pump(0.4)
            w.layoutIfNeeded()
            let fitting = host.fittingSize
            let frame = host.frame.size
            let png = capture(named: "aux-\(fileSafe(aux.name)).png")
            if let expected = aux.size {
                let ok = abs(fitting.width - expected.width) <= 1 && abs(frame.width - expected.width) <= 1
                    && fitting.height >= expected.height - 1 && fitting.height <= expected.height + 120
                report.auxiliary.append(.check("aux-\(aux.name)", ok, "content fitting \(fmt(fitting.width))x\(fmt(fitting.height)), laid out \(fmt(frame.width))x\(fmt(frame.height)), expected \(sizeLabel(expected)) plus tab bar; png \(png ?? "–")"))
            } else {
                report.auxiliary.append(.check("aux-\(aux.name)", fitting.width <= options.screen.width && fitting.height <= options.screen.height, "content fitting \(fmt(fitting.width))x\(fmt(fitting.height)); png \(png ?? "–")"))
            }
            window = saved.window; hosting = saved.hosting
        }
    }

    // MARK: Window plumbing

    private static func startWatchdog() {
        let limit = options.runTimeout
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + limit)
        timer.setEventHandler {
            fputs("uitest: run exceeded \(Int(limit))s (stuck in: \(stage)); aborting\n", stderr)
            exit(3)
        }
        timer.resume()
        watchdog = timer
    }
    nonisolated(unsafe) private static var watchdog: DispatchSourceTimer?

    /// Run-loop turns without a forced layout pass (animations in flight).
    static func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.current.run(mode: .default, before: min(end, Date().addingTimeInterval(0.02)))
        } while Date() < end
    }

    static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.current.run(mode: .default, before: min(end, Date().addingTimeInterval(0.02)))
        } while Date() < end
        window?.layoutIfNeeded()
    }

    /// Indeterminate progress indicators (SwiftUI `ProgressView()`) visible in the detail column.
    private static func visibleSpinners() -> Int {
        guard let detail = detailPane() else { return 0 }
        return allViews(of: NSProgressIndicator.self, in: detail)
            .filter { $0.isIndeterminate && isVisible($0) && $0.frame.width > 1 && !$0.visibleRect.isEmpty }.count
    }

    /// Pumps the run loop until every tracked load has finished and stayed finished, and
    /// — for up to 8 s more — until no spinner is left in the detail column (a loader that
    /// does not report to `SnapshotReadiness`). `spinners` is what was still spinning.
    @discardableResult
    private static func settle(timeout: TimeInterval) -> (seconds: Double, timedOut: Bool, spinners: Int) {
        let started = Date()
        let minimum: TimeInterval = 0.25
        let quiet: TimeInterval = 0.3
        var quietSince: Date?
        while true {
            pump(0.03)
            let elapsed = Date().timeIntervalSince(started)
            let settled = SnapshotReadiness.pending == 0 && Date().timeIntervalSince(SnapshotReadiness.lastChange) > quiet
            if elapsed > minimum && settled {
                if quietSince == nil { quietSince = Date() }
                if visibleSpinners() == 0 || Date().timeIntervalSince(quietSince!) > min(8, timeout) { break }
            } else {
                quietSince = nil
            }
            if elapsed > timeout + 8 || (elapsed > timeout && quietSince == nil) { return (elapsed, true, visibleSpinners()) }
        }
        pump(0.08)
        let seconds = Date().timeIntervalSince(started)
        if verbose, seconds > 1 { fputs(String(format: "uitest:   settle took %.1fs (%d spinner(s) left) in: %@\n", seconds, visibleSpinners(), stage), stderr) }
        return (seconds, false, visibleSpinners())
    }

    private static func setContentSize(_ size: CGSize) {
        // `size` is the content below the toolbar; the hosting view also covers the toolbar.
        let frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height + chrome))
        window.setFrame(NSRect(x: -30_000, y: -30_000, width: frame.width, height: frame.height), display: true)
    }

    private static func resize(to size: CGSize) {
        setContentSize(size)
        pump(0.12)
        // A resize can start loads (a static map re-rendering for its new frame).
        if SnapshotReadiness.pending > 0 || Date().timeIntervalSince(SnapshotReadiness.lastChange) < 0.3 {
            settle(timeout: 8)
        }
        window.displayIfNeeded()
    }

    /// Resizes in steps, laying out at each, like a drag on the window edge.
    private static func animateResize(to size: CGSize) {
        let from = CGSize(width: hosting.frame.width, height: hosting.frame.height - chrome)
        let steps = 8
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            setContentSize(CGSize(width: from.width + (size.width - from.width) * t, height: from.height + (size.height - from.height) * t))
            pump(0.03)
        }
        pump(0.15)
        window.displayIfNeeded()
    }

    private static func setDark(_ dark: Bool) {
        let appearance = NSAppearance(named: dark != options.dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        window.appearance = appearance
        pump(0.25)
    }

    /// Draws the whole window (title bar and toolbar included) into a PNG, in-process.
    private static func capture(named name: String) -> String? {
        let url = options.outDir.appendingPathComponent(name)
        do {
            guard try capture(to: url, scale: 1) else { return nil }
            return url.path
        } catch {
            notes.append("could not write \(name): \(error.localizedDescription)")
            return nil
        }
    }

    /// The window frame view drawn into a bitmap of `scale` pixels per point.
    private static func capture(to url: URL, scale: CGFloat) throws -> Bool {
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let target: NSView = window.contentView?.superview ?? hosting
        let bounds = target.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int((bounds.width * scale).rounded()), pixelsHigh: Int((bounds.height * scale).rounded()),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        rep.size = bounds.size   // points; the pixel dimensions give the scale factor
        target.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        try png.write(to: url, options: .atomic)
        return true
    }

    private static func filesEqual(_ a: String, _ b: String) -> Bool {
        guard let x = FileManager.default.contents(atPath: a), let y = FileManager.default.contents(atPath: b) else { return false }
        return x == y
    }

    // MARK: Synthesized input (delivered to our own window only)

    /// A click, dispatched the way `NSWindow.sendEvent` does it: hit-test, then
    /// `mouseDown(with:)` / `mouseUp(with:)` on the view under the point. (`sendEvent`
    /// itself drops mouse events for a window that is not on screen, and this window never
    /// is.) Nothing is posted to the system event stream.
    private static func click(at point: NSPoint, count: Int = 1) {
        guard let frameView = window.contentView?.superview else { return }
        for n in 1...count {
            guard let target = frameView.hitTest(frameView.convert(point, from: nil)) else { return }
            eventNumber += 1
            let time = ProcessInfo.processInfo.systemUptime
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: n, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.02,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: n, pressure: 0)
            else { return }
            // AppKit controls track the mouse in a nested event loop that pulls the
            // mouse-up from the application's own queue, so it is queued first …
            NSApp.postEvent(up, atStart: false)
            target.mouseDown(with: down)
            // … and views that do not track (SwiftUI gestures) get it delivered afterwards.
            while let event = NSApp.nextEvent(matching: .any, until: Date.distantPast, inMode: .default, dequeue: true) {
                if event.type == .leftMouseUp { target.mouseUp(with: event) }
            }
            pump(0.03)
        }
    }

    private static func key(_ characters: String, keyCode: UInt16? = nil) {
        let code = keyCode ?? keyCodes[characters.lowercased()] ?? 0
        let time = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                                            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                // Straight to the first responder (see `click`).
                if type == .keyDown { window.firstResponder?.keyDown(with: event) } else { window.firstResponder?.keyUp(with: event) }
            }
        }
        pump(0.02)
    }

    /// ANSI virtual key codes for the characters a default query may contain.
    private static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, ".": 47, " ": 49,
    ]

    // MARK: View hierarchy helpers

    private static func allViews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var out: [T] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let match = view as? T { out.append(match) }
            stack.append(contentsOf: view.subviews.reversed())
        }
        return out
    }

    private static func splitView() -> NSSplitView? {
        allViews(of: NSSplitView.self, in: hosting).first { $0.isVertical && $0.arrangedSubviews.count >= 2 }
    }

    private static func panes() -> [NSView] {
        // Arranged subviews only: the split view also owns dividers and edge-interaction views.
        (splitView()?.arrangedSubviews ?? []).sorted { $0.frame.minX < $1.frame.minX }
    }

    private static func detailPane() -> NSView? { panes().last }

    private static func sidebarTable() -> NSTableView? {
        guard let first = panes().first else { return nil }
        return allViews(of: NSTableView.self, in: first).first
    }

    /// Not hidden and not faded out by itself or an ancestor (kept-alive sections are
    /// still in the hierarchy with opacity 0).
    private static func isVisible(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v.isHidden || v.alphaValue < 0.01 { return false }
            if let layer = v.layer, layer.opacity < 0.01 { return false }
            current = v.superview
        }
        return view.window != nil
    }

    private static func visibleScrollViews() -> [NSScrollView] {
        guard let detail = detailPane() else { return [] }
        return allViews(of: NSScrollView.self, in: detail).filter { isVisible($0) && $0.frame.width > 20 && $0.frame.height > 20 }
    }

    private static func searchField() -> NSSearchField? {
        if let toolbar = window.toolbar {
            for item in toolbar.items {
                if let search = item as? NSSearchToolbarItem { return search.searchField }
                if let view = item.view, let field = allViews(of: NSSearchField.self, in: view).first { return field }
            }
        }
        if let frameView = window.contentView?.superview { return allViews(of: NSSearchField.self, in: frameView).first }
        return nil
    }

    private static func toolbarItem(matching predicate: (NSToolbarItem) -> Bool) -> NSToolbarItem? {
        guard let toolbar = window.toolbar else { return nil }
        for item in toolbar.items {
            if predicate(item) { return item }
            if let group = item as? NSToolbarItemGroup, let sub = group.subitems.first(where: predicate) { return sub }
        }
        return nil
    }

    private static func centre(of item: NSToolbarItem) -> NSPoint? {
        guard let view = item.view, view.window === window, view.bounds.width > 1 else { return nil }
        let rect = view.convert(view.bounds, to: nil)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    /// Finds an element by accessibility label in the window's own accessibility tree
    /// (plain in-process method calls — no Accessibility permission involved) and returns
    /// its centre in window coordinates.
    private static func accessibilityCentre(label: String) -> NSPoint? {
        var queue: [Any] = [window as Any]
        var visited = 0
        while !queue.isEmpty, visited < 4000 {
            let element = queue.removeFirst()
            visited += 1
            guard let object = element as? NSObject else { continue }
            guard object.responds(to: #selector(NSAccessibilityProtocol.accessibilityChildren)),
                  object.responds(to: #selector(NSAccessibilityProtocol.accessibilityLabel)) else { continue }
            let children = (object as? NSAccessibilityProtocol)?.accessibilityChildren() ?? []
            let title = (object as? NSAccessibilityProtocol)?.accessibilityLabel() ?? ""
            let name = object.responds(to: #selector(NSAccessibilityProtocol.accessibilityTitle)) ? ((object as? NSAccessibilityProtocol)?.accessibilityTitle() ?? "") : ""
            if title == label || name == label, let ax = object as? NSAccessibilityProtocol {
                let frame = ax.accessibilityFrame()
                if frame.width > 1, frame.height > 1 {
                    let inWindow = window.convertFromScreen(frame)
                    return NSPoint(x: inWindow.midX, y: inWindow.midY)
                }
            }
            queue.append(contentsOf: children)
        }
        return nil
    }

    /// Debug aid: `DOSSIER_UITEST_DUMP=1` prints the AppKit view tree and toolbar items.
    static func dumpHierarchy() {
        func walk(_ view: NSView, _ depth: Int) {
            let f = view.frame
            print(String(repeating: "  ", count: depth) + "\(type(of: view)) \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))\(view.isHidden ? " hidden" : "")\(view.alphaValue < 1 ? " alpha \(view.alphaValue)" : "")\(view.layer.map { $0.opacity < 1 ? " layerOpacity \($0.opacity)" : "" } ?? "")")
            if depth < 40 { for sub in view.subviews { walk(sub, depth + 1) } }
        }
        if let frameView = window.contentView?.superview { walk(frameView, 0) }
        for item in window.toolbar?.items ?? [] {
            print("toolbar item: \(item.itemIdentifier.rawValue) label=\"\(item.label)\" class=\(type(of: item)) view=\(item.view.map { "\(type(of: $0)) \($0.frame)" } ?? "nil") visible=\(item.isVisible)")
        }
    }

    // MARK: Formatting

    private static func sizeLabel(_ size: CGSize) -> String { "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))" }
    private static func fmt(_ value: CGFloat?) -> String {
        guard let value else { return "unspecified" }
        if !value.isFinite { return "∞" }
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", Double(value))
    }
    private static func fileSafe(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
    }
}
