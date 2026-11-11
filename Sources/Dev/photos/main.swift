import DossierCore
import PhotosModule

// Standalone host for the "photos" module: build, self-test, snapshot or run it in isolation.
//   swift run dossier-dev-photos --selftest
//   swift run dossier-dev-photos --snapshot photos /path/outside/the/repo/photos.png [--dark]
//   swift run dossier-dev-photos            (opens a minimal window with only this module)
DossierRunner.main(modules: [PhotosModule()])
