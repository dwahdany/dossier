import SwiftUI
import AppKit

/// Entry point shared by the app and the per-module dev executables.
///
/// ```swift
/// // Sources/Dev/<id>/main.swift
/// DossierRunner.main(modules: [MyModule()])
/// ```
///
/// Command line:
/// ```
/// --list                                   print module and section ids
/// --selftest [moduleID]                    run self-tests, exit 1 if any FAIL
/// --summary [moduleID]                     print each module's summary() (stores + facts)
/// --search <query> [moduleID]              run search() and print the hits
/// --snapshot <moduleID|sectionID> <out.png> [--dark] [--size WxH] [--wait seconds]
///            [--privacy] [--payload <deep-link payload>] [--scale 1|2]
///                                          render a section offscreen to a PNG
/// --uitest [sectionID|moduleID|all] [--out <dir>] [--sizes WxH,WxH,...] [--query <text>]
///          [--no-interactions] [--wait seconds] [--payload <deep-link payload>] [--dark]
///          [--screen WxH]
///                                          real-window UI test: layout invariants at each
///                                          size, synthesized input, PNGs + report.json
/// (no flags)                               start the GUI
/// ```
@MainActor
public enum DossierRunner {
    /// - Parameters:
    ///   - modules: the modules to host.
    ///   - extraSections: additional snapshot-able sections that do not belong to a module
    ///     (the app registers its Overview here).
    ///   - launchApp: starts the GUI; defaults to the minimal dev shell.
    ///   - uiTestShell: the window shell `--uitest` hosts; defaults to the dev shell.
    public nonisolated static func main(
        modules: [any DossierModule],
        extraSections: [ModuleSection] = [],
        launchApp: (@MainActor () -> Void)? = nil,
        uiTestShell: (@MainActor () -> UITestShell)? = nil
    ) -> Never {
        // `main.swift` top-level code runs on the main thread but is not statically
        // main-actor isolated in Swift 5 mode.
        MainActor.assumeIsolated {
            run(modules: modules, extraSections: extraSections, launchApp: launchApp, uiTestShell: uiTestShell)
        }
    }

    private static func run(
        modules: [any DossierModule],
        extraSections: [ModuleSection],
        launchApp: (@MainActor () -> Void)?,
        uiTestShell: (@MainActor () -> UITestShell)?
    ) -> Never {
        let args = Array(CommandLine.arguments.dropFirst())

        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        /// Positional values following `flag` (until the next `--option`).
        func positionals(after flag: String) -> [String] {
            guard let i = args.firstIndex(of: flag) else { return [] }
            return Array(args[(i + 1)...].prefix { !$0.hasPrefix("--") })
        }

        if args.contains("--help") || args.contains("-h") {
            print(usage)
            exit(0)
        }

        if args.contains("--list") {
            for module in modules {
                print("\(module.id)\t\(module.title)\t[\(module.group.title)]")
                for section in module.sections { print("  \(section.id)\t\(section.title)") }
            }
            for section in extraSections { print("\(section.id)\t\(section.title)") }
            exit(0)
        }

        if args.contains("--selftest") {
            let filter = positionals(after: "--selftest").first
            let selected = modules.filter { filter == nil || $0.id == filter }
            if selected.isEmpty { fputs("No module with id \(filter ?? "")\n", stderr); exit(2) }
            // SwiftUI layout must run on the real main thread, i.e. before dispatchMain().
            let layoutLines = LayoutSelfTest.run()
            Task.detached {
                var failures = 0
                var timings: [(String, Double)] = []
                // Core guarantee every module relies on: reading never touches a store's files.
                print("== core — DossierCore")
                for line in await SQLiteDB.sidecarSelfTest() + layoutLines {
                    if line.status == .fail { failures += 1 }
                    print("  [\(line.status.rawValue)] \(line.label)\(line.detail.isEmpty ? "" : " — " + line.detail)")
                }
                for module in selected {
                    print("== \(module.id) — \(module.title)")
                    let started = Date()
                    for line in await module.selfTest() {
                        if line.status == .fail { failures += 1 }
                        print("  [\(line.status.rawValue)] \(line.label)\(line.detail.isEmpty ? "" : " — " + line.detail)")
                    }
                    let seconds = Date().timeIntervalSince(started)
                    timings.append((module.id, seconds))
                    print(String(format: "  (%.2fs)", seconds))
                }
                // Overview load: every module's summary() concurrently, as the app does.
                let summaryStart = Date()
                let summaryTimes = await withTaskGroup(of: (Int, Double, Int, Int).self) { group -> [(Int, Double, Int, Int)] in
                    for (index, module) in selected.enumerated() {
                        group.addTask {
                            let t0 = Date()
                            let summary = await module.summary()
                            return (index, Date().timeIntervalSince(t0), summary.stores.count, summary.facts.count)
                        }
                    }
                    var out: [(Int, Double, Int, Int)] = []
                    for await item in group { out.append(item) }
                    return out.sorted { $0.0 < $1.0 }
                }
                let summaryTotal = Date().timeIntervalSince(summaryStart)
                print("== timing")
                for (index, module) in selected.enumerated() {
                    let s = summaryTimes[index]
                    print("  " + module.id.padding(toLength: 12, withPad: " ", startingAt: 0)
                          + String(format: " selftest %6.2fs   summary %5.2fs   %2d stores  %2d facts", timings[index].1, s.1, s.2, s.3))
                }
                let limit = 6.0
                let status = summaryTotal <= limit ? "PASS" : "FAIL"
                if summaryTotal > limit { failures += 1 }
                print(String(format: "  [%@] all summaries, concurrently — %.2fs (limit %.0fs); self-tests %.2fs in total",
                             status, summaryTotal, limit, timings.reduce(0) { $0 + $1.1 }))
                print(failures == 0 ? "Self-test OK" : "Self-test: \(failures) failure(s)")
                exit(failures == 0 ? 0 : 1)
            }
            dispatchMain()
        }

        if args.contains("--summary") {
            let filter = positionals(after: "--summary").first
            let selected = modules.filter { filter == nil || $0.id == filter }
            Task.detached {
                for module in selected {
                    let started = Date()
                    let summary = await module.summary()
                    print(String(format: "== %@ — %@ (%.2fs)", module.id, module.title, Date().timeIntervalSince(started)))
                    for store in summary.stores {
                        print("  store: \(store.name) | \(store.availability.label) | \(Format.bytes(store.sizeBytes)) | rows \(Format.count(store.rowCount)) | \(DossierDate.range(store.timeRange))")
                    }
                    for fact in summary.facts {
                        print("  fact [\(fact.sensitivity.label)]: \(fact.label) = \(fact.value)")
                    }
                }
                exit(0)
            }
            dispatchMain()
        }

        if args.contains("--search") {
            let parts = positionals(after: "--search")
            guard let query = parts.first else { fputs(usage, stderr); exit(2) }
            let filter = parts.dropFirst().first
            let selected = modules.filter { filter == nil || $0.id == filter }
            Task.detached {
                // Concurrently, as the app's global search does.
                let started = Date()
                let results = await withTaskGroup(of: (Int, [SearchHit], Double).self) { group -> [(Int, [SearchHit], Double)] in
                    for (index, module) in selected.enumerated() {
                        group.addTask {
                            let t0 = Date()
                            let hits = await module.search(query, limit: 25)
                            return (index, hits, Date().timeIntervalSince(t0))
                        }
                    }
                    var out: [(Int, [SearchHit], Double)] = []
                    for await item in group { out.append(item) }
                    return out.sorted { $0.0 < $1.0 }
                }
                let sectionIDs = Set(selected.flatMap { $0.sections.map(\.id) })
                var bad = 0
                for (index, hits, seconds) in results {
                    let module = selected[index]
                    print(String(format: "== %@: %d hit(s) in %.2fs", module.id, hits.count, seconds))
                    for hit in hits {
                        let valid = sectionIDs.contains(hit.sectionID) && hit.moduleID == module.id
                        if !valid { bad += 1 }
                        print("  \(valid ? "" : "[BAD TARGET] ")\(hit.title) — \(hit.subtitle)  [\(hit.sectionID) | \(hit.payload)]")
                    }
                }
                print(String(format: "== %d hit(s) in %.2fs, %d with an unknown target section", results.reduce(0) { $0 + $1.1.count }, Date().timeIntervalSince(started), bad))
                exit(bad == 0 ? 0 : 1)
            }
            dispatchMain()
        }

        if args.contains("--snapshot") {
            let parts = positionals(after: "--snapshot")
            guard parts.count >= 2 else { fputs(usage, stderr); exit(2) }
            var options = SnapshotOptions()
            options.dark = args.contains("--dark")
            options.privacy = args.contains("--privacy")
            options.payload = value(after: "--payload")
            if let wait = value(after: "--wait").flatMap(Double.init) { options.timeout = wait }
            if let scale = value(after: "--scale").flatMap(Double.init) { options.scale = CGFloat(scale) }
            if let size = value(after: "--size") {
                let wh = size.lowercased().split(separator: "x").compactMap { Double($0) }
                if wh.count == 2 { options.size = CGSize(width: wh[0], height: wh[1]) }
            }
            let target = parts[0]
            var section: ModuleSection?
            var moduleTitle: String?
            for module in modules {
                if module.id == target { section = module.sections.first; moduleTitle = module.title; break }
                if let s = module.sections.first(where: { $0.id == target }) { section = s; moduleTitle = module.title; break }
            }
            if section == nil { section = extraSections.first { $0.id == target } }
            guard let section else {
                fputs("No module or section with id \"\(target)\". Use --list.\n", stderr)
                exit(2)
            }
            let ok = Snapshotter.render(section: section, moduleTitle: moduleTitle, to: URL(fileURLWithPath: parts[1]), options: options)
            exit(ok ? 0 : 1)
        }

        if args.contains("--uitest") {
            var options = UITestOptions()
            options.target = positionals(after: "--uitest").first ?? "all"
            if let out = value(after: "--out") { options.outDir = URL(fileURLWithPath: out) }
            if let query = value(after: "--query") { options.query = query }
            if let wait = value(after: "--wait").flatMap(Double.init) { options.loadTimeout = wait }
            options.interactions = !args.contains("--no-interactions")
            options.payload = value(after: "--payload")
            options.dark = args.contains("--dark")
            if let screen = value(after: "--screen") {
                let wh = screen.lowercased().split(separator: "x").compactMap { Double($0) }
                guard wh.count == 2, wh[0] >= 600, wh[1] >= 400 else { fputs("--screen expects WxH\n", stderr); exit(2) }
                options.screen = CGSize(width: wh[0], height: wh[1])
            }
            if let list = value(after: "--sizes") {
                let sizes = list.lowercased().split(separator: ",").compactMap { item -> CGSize? in
                    let wh = item.split(separator: "x").compactMap { Double($0) }
                    return wh.count == 2 ? CGSize(width: wh[0], height: wh[1]) : nil
                }
                if sizes.isEmpty { fputs("--sizes expects WxH[,WxH...]\n", stderr); exit(2) }
                options.sizes = sizes
            }
            let shell = uiTestShell?() ?? DevShellUITest(modules: modules)
            UITestRunner.run(shell: shell, options: options)
        }

        if let launchApp {
            launchApp()
        } else {
            DevShellApp.modules = modules
            DevShellApp.main()
        }
        exit(0)
    }

    private static let usage = """
    Usage:
      --list
      --selftest [moduleID]
      --summary [moduleID]
      --search <query> [moduleID]
      --snapshot <moduleID|sectionID> <out.png> [--dark] [--size WxH] [--wait seconds] [--privacy] [--payload <p>] [--scale 1|2]
      --uitest [sectionID|moduleID|all] [--out <dir>] [--sizes WxH,WxH,...] [--query <text>] [--no-interactions] [--wait seconds]
               [--payload <p>] [--dark] [--screen WxH]
      (no arguments: start the app)

    """
}

// MARK: - Offscreen snapshots

public struct SnapshotOptions {
    public var size = CGSize(width: 1280, height: 800)
    public var dark = false
    /// Maximum seconds to wait for the view to settle.
    public var timeout: TimeInterval = 20
    public var privacy = false
    public var payload: String?
    public var scale: CGFloat = 1
    public init() {}
}

/// Renders a section into a PNG without ever showing a window: the view is hosted in a
/// borderless window that is never ordered in (not on screen, not in the window list), the run loop is pumped until all
/// tracked loads (``SnapshotReadiness``) have settled, then the view hierarchy is drawn
/// into a bitmap. No Screen Recording permission is involved.
@MainActor
public enum Snapshotter {
    @discardableResult
    public static func render(section: ModuleSection, moduleTitle: String?, to url: URL, options: SnapshotOptions) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        SnapshotReadiness.isSnapshotting = true
        let appearance = NSAppearance(named: options.dark ? .darkAqua : .aqua)
        app.appearance = appearance

        let link = options.payload.map { DeepLink(sectionID: section.id, payload: $0) }
        let root = SnapshotChrome(title: section.title, subtitle: moduleTitle, symbol: section.symbol) { section.makeView() }
            .environment(\.privacyMode, options.privacy)
            .environment(\.deepLink, link)
            .environment(\.colorScheme, options.dark ? .dark : .light)
            .frame(width: options.size.width, height: options.size.height)

        let window = OffscreenWindow(
            contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: options.size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: options.size)
        window.contentView = hosting
        // The window is never ordered in: SwiftUI still runs tasks, lays out and draws
        // (Table, List, Charts included) for a hosting view that merely *has* a window.
        // Belt and braces: it is also transparent and positioned outside every screen.

        let started = Date()
        let minimum: TimeInterval = 0.8
        let quiet: TimeInterval = 0.45
        while true {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
            let elapsed = Date().timeIntervalSince(started)
            let settled = SnapshotReadiness.pending == 0 && Date().timeIntervalSince(SnapshotReadiness.lastChange) > quiet
            if elapsed > minimum && settled { break }
            if elapsed > options.timeout {
                fputs("snapshot: timed out after \(Int(options.timeout))s with \(SnapshotReadiness.pending) load(s) pending; capturing anyway\n", stderr)
                break
            }
        }
        // A few more turns so the final state is laid out and committed.
        for _ in 0..<6 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03)) }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        let pixelSize = NSSize(width: options.size.width * options.scale, height: options.size.height * options.scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(pixelSize.width), pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            fputs("snapshot: could not allocate bitmap\n", stderr)
            return false
        }
        rep.size = options.size   // points; pixel dimensions give the scale factor
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            fputs("snapshot: PNG encoding failed\n", stderr)
            return false
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            print("snapshot: wrote \(url.path) (\(Int(pixelSize.width))x\(Int(pixelSize.height)), loads: \(SnapshotReadiness.started), \(String(format: "%.1f", Date().timeIntervalSince(started)))s)")
            return true
        } catch {
            fputs("snapshot: \(error.localizedDescription)\n", stderr)
            return false
        }
    }
}

/// Borderless window that may live outside every screen (no frame constraining) and can
/// never become key or main.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Minimal stand-in for the app's window chrome in snapshots: a title strip above the
/// section view, on the window background.
private struct SnapshotChrome<Content: View>: View {
    let title: String
    let subtitle: String?
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(.bar)
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Dev shell

/// State of the dev shell window (also driven by `--uitest`).
@MainActor
final class DevShellState: ObservableObject {
    let modules: [any DossierModule]
    @Published var selection: String?
    @Published var privacyMode = false
    @Published var refreshToken = 0
    /// Pending navigation payload for the selected section (`--uitest` payload states).
    @Published var deepLink: DeepLink?

    init(modules: [any DossierModule]) { self.modules = modules }
}

/// The dev shell's window content: sidebar of sections + detail + toolbar.
struct DevShellView: View {
    static let minimumSize = CGSize(width: 900, height: 560)
    static let sidebarWidth: ClosedRange<CGFloat> = 180...400

    @ObservedObject var state: DevShellState

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selection) {
                ForEach(state.modules, id: \.id) { module in
                    Section(module.title) {
                        ForEach(module.sections) { section in
                            Label(section.title, systemImage: section.symbol).tag(section.id)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: DevShellView.sidebarWidth.lowerBound, ideal: 220, max: DevShellView.sidebarWidth.upperBound)
        } detail: {
            let sections = state.modules.flatMap(\.sections)
            if let section = sections.first(where: { $0.id == state.selection }) ?? sections.first {
                section.makeView()
                    .environment(\.deepLink, state.deepLink?.sectionID == section.id ? state.deepLink : nil)
                    .uiTestSection(section.id)
                    .containedSection(minimumWindow: DevShellView.minimumSize, narrowestSidebar: DevShellView.sidebarWidth.lowerBound)
                    .id(section.id)
                    .navigationTitle(section.title)
            } else {
                StatePlaceholder(title: "No Sections", symbol: "square.dashed")
            }
        }
        .environment(\.privacyMode, state.privacyMode)
        .environment(\.refreshToken, state.refreshToken)
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $state.privacyMode) { Label("Privacy Mode", systemImage: state.privacyMode ? "eye.slash" : "eye") }
                Button { SQLiteDB.resetPool(); state.refreshToken += 1 } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
            }
        }
        .frame(minWidth: DevShellView.minimumSize.width, minHeight: DevShellView.minimumSize.height)
    }
}

/// Minimal GUI used by `dossier-dev-<module>` executables: sidebar of sections + detail.
struct DevShellApp: App {
    static var modules: [any DossierModule] = []

    @NSApplicationDelegateAdaptor(DevAppDelegate.self) private var delegate
    @StateObject private var state = DevShellState(modules: DevShellApp.modules)

    var body: some Scene {
        WindowGroup("Dossier Dev") {
            DevShellView(state: state)
        }
    }
}

/// `--uitest` adapter for the dev shell.
@MainActor
final class DevShellUITest: UITestShell {
    private let state: DevShellState

    init(modules: [any DossierModule]) { state = DevShellState(modules: modules) }

    var name: String { "dev shell (" + state.modules.map(\.id).joined(separator: ", ") + ")" }
    func makeRootView() -> AnyView { AnyView(DevShellView(state: state)) }
    var minimumSize: CGSize { DevShellView.minimumSize }
    var sidebarWidthRange: ClosedRange<CGFloat> { DevShellView.sidebarWidth }
    var sections: [UITestSection] {
        state.modules.flatMap { module in module.sections.map { UITestSection(id: $0.id, moduleID: module.id, title: $0.title, payloads: $0.uiTestPayloads) } }
    }
    func open(section id: String, payload: String) -> Bool {
        guard state.modules.contains(where: { $0.sections.contains { $0.id == id } }) else { return false }
        state.selection = id
        state.deepLink = DeepLink(sectionID: id, payload: payload)
        return true
    }
    func sidebarRow(for id: String) -> Int? {
        var row = 0
        for module in state.modules {
            row += 1   // section header
            for section in module.sections {
                if section.id == id { return row }
                row += 1
            }
        }
        return nil
    }
    var selection: String? {
        get { state.selection }
        set {
            if state.deepLink?.sectionID != newValue { state.deepLink = nil }
            state.selection = newValue
        }
    }
    var privacyMode: Bool {
        get { state.privacyMode }
        set { state.privacyMode = newValue }
    }
    var blockedReason: String? { nil }
}

/// Makes a bundle-less SwiftPM executable behave like a regular foreground app.
public final class DevAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
