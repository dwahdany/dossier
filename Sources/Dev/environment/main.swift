import DossierCore
import EnvironmentModule

// Standalone host for the "environment" module: build, self-test, snapshot or run it in isolation.
//   swift run dossier-dev-environment --selftest
//   swift run dossier-dev-environment --snapshot environment /path/outside/the/repo/environment.png [--dark]
//   swift run dossier-dev-environment            (opens a minimal window with only this module)
DossierRunner.main(modules: [EnvironmentModule()])
