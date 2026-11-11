import SwiftUI
import DossierCore

/// App-wide UI state shared by the window, the menu commands and Settings.
@MainActor
final class AppState: ObservableObject {
    static let overviewID = "overview"

    let modules: [any DossierModule] = ModuleRegistry.modules

    /// Selected sidebar item: `"overview"` or a section id.
    @Published var selection: String? {
        didSet {
            if persists, let selection { UserDefaults.standard.set(selection, forKey: "lastSection") }
            recordHistory(old: oldValue)
            // A deep link is consumed by its target section; leaving for another section
            // drops it so a later revisit does not replay a stale navigation.
            if let link = deepLink, link.sectionID != selection { deepLink = nil }
        }
    }
    @Published var privacyMode: Bool {
        didSet { if persists { UserDefaults.standard.set(privacyMode, forKey: "privacyMode") } }
    }
    @Published var refreshToken = 0
    private var persists = true
    /// Snapshot of the permission screen: keep it up although access is actually granted.
    private var accessOverridden = false

    // Back / forward history of visited sections (like a browser).
    @Published private(set) var backStack: [String] = []
    @Published private(set) var forwardStack: [String] = []
    private var travelling = false

    private func recordHistory(old: String?) {
        guard let old, old != selection, !travelling else { return }
        backStack.append(old)
        if backStack.count > 50 { backStack.removeFirst(backStack.count - 50) }
        forwardStack.removeAll()
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        if let current = selection { forwardStack.append(current) }
        travel(to: target)
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        if let current = selection { backStack.append(current) }
        travel(to: target)
    }

    private func travel(to id: String) {
        travelling = true
        searchText = ""
        select(id)
        travelling = false
    }

    /// Selects a section and makes sure its sidebar group is expanded so the selection
    /// is visible.
    func select(_ id: String) {
        if persists, let module = section(id)?.module {
            let key = "collapsedModules"
            var collapsed = Set((UserDefaults.standard.string(forKey: key) ?? "").split(separator: ",").map(String.init))
            if collapsed.remove(module.id) != nil {
                UserDefaults.standard.set(collapsed.sorted().joined(separator: ","), forKey: key)
            }
        }
        selection = id
    }
    @Published var searchText = ""
    @Published var searchPresented = false
    @Published var deepLink: DeepLink?
    @Published var hasFullDiskAccess = true
    @Published var permissionDismissed = false

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["restoreLastSection": true, "privacyOnLaunch": false])
        privacyMode = defaults.bool(forKey: "privacyOnLaunch") || defaults.bool(forKey: "privacyMode")
        let last = defaults.string(forKey: "lastSection")
        if defaults.bool(forKey: "restoreLastSection"), let last, last == AppState.overviewID || modules.contains(where: { $0.sections.contains { $0.id == last } }) {
            selection = last
        } else {
            selection = AppState.overviewID
        }
        hasFullDiskAccess = Paths.hasFullDiskAccess()
    }

    /// State for `--snapshot app`, configured from the environment (never persisted).
    static func forSnapshot() -> AppState {
        let env = ProcessInfo.processInfo.environment
        let state = AppState()
        state.persists = false
        state.selection = env["DOSSIER_SNAPSHOT_SECTION"] ?? AppState.overviewID
        state.privacyMode = CommandLine.arguments.contains("--privacy")
        if let query = env["DOSSIER_SNAPSHOT_SEARCH"] { state.searchText = query }
        if env["DOSSIER_SNAPSHOT_NO_FDA"] != nil { state.hasFullDiskAccess = false; state.accessOverridden = true }
        return state
    }

    /// State for `--uitest`: nothing persisted, starts on the Overview with Privacy Mode off.
    static func forUITest() -> AppState {
        let state = AppState()
        state.persists = false
        state.selection = AppState.overviewID
        state.privacyMode = false
        state.backStack = []
        return state
    }

    /// Sidebar groups in display order.
    var groups: [(group: SidebarGroup, modules: [any DossierModule])] {
        var order: [SidebarGroup] = []
        var map: [SidebarGroup: [any DossierModule]] = [:]
        for module in modules {
            if map[module.group] == nil { order.append(module.group) }
            map[module.group, default: []].append(module)
        }
        return order.sorted { $0.order < $1.order }.map { ($0, map[$0]!) }
    }

    /// All section ids in sidebar order (for next / previous navigation).
    var orderedSelectionIDs: [String] {
        [AppState.overviewID] + groups.flatMap { $0.modules.flatMap { $0.sections.map(\.id) } }
    }

    func section(_ id: String?) -> (module: any DossierModule, section: ModuleSection)? {
        guard let id else { return nil }
        for module in modules {
            if let section = module.sections.first(where: { $0.id == id }) { return (module, section) }
        }
        return nil
    }

    func navigate(_ link: DeepLink) {
        searchText = ""
        searchPresented = false
        guard link.sectionID == AppState.overviewID || section(link.sectionID) != nil else { return }
        deepLink = link.payload.isEmpty ? nil : link
        select(link.sectionID)
        // `selection`'s observer drops a deep link for another section; set it again in
        // case the selection did not change (same section, new payload).
        if !link.payload.isEmpty { deepLink = link }
    }

    func open(_ hit: SearchHit) {
        navigate(DeepLink(sectionID: hit.sectionID, payload: hit.payload))
    }

    func refresh() {
        SQLiteDB.resetPool()
        hasFullDiskAccess = Paths.hasFullDiskAccess()
        refreshToken += 1
    }

    func step(_ delta: Int) {
        let ids = orderedSelectionIDs
        guard !ids.isEmpty else { return }
        let current = selection.flatMap { ids.firstIndex(of: $0) } ?? 0
        select(ids[(current + delta + ids.count) % ids.count])
    }

    func recheckAccess() {
        guard !accessOverridden else { return }
        let granted = Paths.hasFullDiskAccess()
        guard granted != hasFullDiskAccess else { return }
        hasFullDiskAccess = granted
        if granted {
            AppDragPanel.shared.close()
            refresh()
        }
    }

    /// Opens System Settings › Privacy & Security › Full Disk Access (user-initiated only).
    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        // The icon to drag into the list, floating beside the Settings window.
        if !hasFullDiskAccess { AppDragPanel.shared.show() }
    }
}
