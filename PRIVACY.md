# Privacy Policy

Dossier collects no data. It has no telemetry, no analytics, no update check and no
account, and it sends nothing it reads from your Mac's stores anywhere. Every store is
opened read-only.

**Network.** There are two cases, and neither carries store content:

- Maps download map tiles from Apple (MapKit) for the area they show, which tells Apple's
  tile servers roughly which region is on screen. Privacy Mode replaces maps with a
  placeholder, so nothing is requested then.
- The Interest Profile offers a "Look up on Wikidata" link per topic. If you click it, your
  browser opens wikidata.org with that one topic id. Nothing is looked up otherwise.

**On disk.** Dossier keeps no copy, cache or index of your data. It writes:

- a few preferences in its own user defaults: the last section and whether to reopen it,
  Privacy Mode and whether to start in it, collapsed sidebar groups, one table display
  option, a Photos library path if you chose one by hand, and the window and column
  layout that macOS saves for any app;
- files you ask for: CSV exports, and whatever you copy to the clipboard;
- only when started with the developer flags: PNGs (`--snapshot`, `--screenshot`), PNGs and
  a `report.json` (`--uitest`), and scratch test databases in the temporary directory
  during `--selftest`, which are removed afterwards.

MapKit may keep its own system-managed cache of map tiles.

Questions: https://github.com/dwahdany/dossier/issues
