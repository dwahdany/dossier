import SwiftUI
import DossierCore

// Entry point: CLI flags (--selftest, --snapshot, --list, ...) are handled by the shared
// runner; without flags the SwiftUI app starts.
DossierRunner.main(
    modules: ModuleRegistry.modules,
    extraSections: [
        OverviewView.section(modules: ModuleRegistry.modules),
        // `--snapshot app out.png`: the whole window content (sidebar + detail), for UI checks.
        // Optional environment: DOSSIER_SNAPSHOT_SECTION=<section id>, DOSSIER_SNAPSHOT_SEARCH=<query>,
        // DOSSIER_SNAPSHOT_NO_FDA=1 (show the permission screen).
        ModuleSection(id: "app", title: "Dossier", symbol: "macwindow") {
            RootView().environmentObject(AppState.forSnapshot())
        },
    ],
    launchApp: { DossierApplication.main() },
    uiTestShell: { AppUITestShell() }
)
