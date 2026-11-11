import DossierCore
import MailSearchModule

// Standalone host for the "mailsearch" module: build, self-test, snapshot or run it in isolation.
//   swift run dossier-dev-mailsearch --selftest
//   swift run dossier-dev-mailsearch --snapshot mailsearch /path/outside/the/repo/mailsearch.png [--dark]
//   swift run dossier-dev-mailsearch            (opens a minimal window with only this module)
DossierRunner.main(modules: [MailSearchModule()])
