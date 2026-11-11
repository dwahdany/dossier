import DossierCore
import CommsModule

// Standalone host for the "comms" module: build, self-test, snapshot or run it in isolation.
//   swift run dossier-dev-comms --selftest
//   swift run dossier-dev-comms --snapshot comms /path/outside/the/repo/comms.png [--dark]
//   swift run dossier-dev-comms            (opens a minimal window with only this module)
DossierRunner.main(modules: [CommsModule()])
