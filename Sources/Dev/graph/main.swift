import DossierCore
import GraphModule

// Standalone host for the "graph" module: build, self-test, snapshot or run it in isolation.
//   swift run dossier-dev-graph --selftest
//   swift run dossier-dev-graph --snapshot graph /path/outside/the/repo/graph.png [--dark]
//   swift run dossier-dev-graph            (opens a minimal window with only this module)
DossierRunner.main(modules: [GraphModule()])
