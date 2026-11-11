import DossierCore
import ProfileModule

// Standalone host for the "profile" module: build, self-test, snapshot or run it in isolation.
//   swift run dossier-dev-profile --selftest
//   swift run dossier-dev-profile --snapshot profile /path/outside/the/repo/profile.png [--dark]
//   swift run dossier-dev-profile            (opens a minimal window with only this module)
DossierRunner.main(modules: [ProfileModule()])
