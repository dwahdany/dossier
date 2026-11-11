import DossierCore
import ActivityModule

// Standalone host for the "activity" module: build, self-test, snapshot or run it in isolation.
//   swift run dossier-dev-activity --selftest
//   swift run dossier-dev-activity --snapshot activity /path/outside/the/repo/activity.png [--dark]
//   swift run dossier-dev-activity            (opens a minimal window with only this module)
DossierRunner.main(modules: [ActivityModule()])
