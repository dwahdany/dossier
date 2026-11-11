import DossierCore
import BiomeModule

// Standalone host for the "biome" module: build, self-test, snapshot or run it in isolation.
//   swift run dossier-dev-biome --selftest
//   swift run dossier-dev-biome --snapshot biome /path/outside/the/repo/biome.png [--dark]
//   swift run dossier-dev-biome            (opens a minimal window with only this module)
DossierRunner.main(modules: [BiomeModule()])
