import DossierCore
import RawModule

// Standalone host for the "raw" module: build, self-test, snapshot or run it in isolation.
//   swift run dossier-dev-raw --selftest
//   swift run dossier-dev-raw --snapshot raw /path/outside/the/repo/raw.png [--dark]
//   swift run dossier-dev-raw            (opens a minimal window with only this module)
DossierRunner.main(modules: [RawModule()])
