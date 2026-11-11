import SwiftUI
import DossierCore

/// `--uitest` adapter: hands the shared runner the real main-window content and the state
/// its checks observe (selection, Privacy Mode, global search).
@MainActor
final class AppUITestShell: UITestShell {
    private let state = AppState.forUITest()

    var name: String { "Dossier" }
    func makeRootView() -> AnyView { AnyView(DossierApplication.windowContent(state)) }
    var minimumSize: CGSize { DossierApplication.minimumSize }
    var sidebarWidthRange: ClosedRange<CGFloat> { RootView.sidebarWidth }

    var sections: [UITestSection] {
        [UITestSection(id: AppState.overviewID, moduleID: nil, title: "Overview")]
            + state.groups.flatMap { entry in
                entry.modules.flatMap { module in
                    module.sections.map { UITestSection(id: $0.id, moduleID: module.id, title: $0.title, payloads: $0.uiTestPayloads) }
                }
            }
    }

    /// Mirrors `Sidebar`: Overview, then per group a header row, then per module either
    /// one row (single section) or a disclosure row followed by its section rows. All
    /// groups are expanded during a UI test.
    func sidebarRow(for id: String) -> Int? {
        if id == AppState.overviewID { return 0 }
        var row = 1
        for entry in state.groups {
            row += 1   // group header
            for module in entry.modules {
                let sections = module.sections
                if sections.count == 1 {
                    if sections[0].id == id { return row }
                    row += 1
                } else {
                    row += 1   // disclosure row
                    for section in sections {
                        if section.id == id { return row }
                        row += 1
                    }
                }
            }
        }
        return nil
    }

    var selection: String? {
        get { state.selection }
        set { if let newValue { state.select(newValue) } else { state.selection = nil } }
    }
    func open(section id: String, payload: String) -> Bool {
        guard state.section(id) != nil else { return false }
        state.navigate(DeepLink(sectionID: id, payload: payload))
        return true
    }
    var privacyMode: Bool {
        get { state.privacyMode }
        set { state.privacyMode = newValue }
    }
    var hasSearch: Bool { true }
    var searchText: String {
        get { state.searchText }
        set { state.searchText = newValue }
    }
    var searchIsRunning: Bool { SearchCoordinator.shared.isSearching || SearchCoordinator.shared.query != state.searchText.trimmingCharacters(in: .whitespaces) }
    var searchHitSections: [String] { SearchCoordinator.shared.groups.flatMap { $0.hits.map(\.sectionID) } }

    /// Without Full Disk Access the window shows the permission screen. The test never
    /// dismisses it: reading stores in other apps' containers could raise a system alert.
    var blockedReason: String? { state.hasFullDiskAccess ? nil : "Full Disk Access is not granted" }

    var auxiliaryViews: [(name: String, view: AnyView, size: CGSize?)] {
        [("settings", AnyView(SettingsView().environmentObject(state)), CGSize(width: 480, height: 340))]
    }
}
