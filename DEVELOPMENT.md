# Developing Dossier

How to build, test, photograph and release Dossier. For what the app does and how to use
it, see the [README](README.md); for how the code is organised and how to write a module,
see [ARCHITECTURE.md](ARCHITECTURE.md).

- [Requirements](#requirements)
- [Build and run](#build-and-run)
- [Self-test](#self-test)
- [Checking the app without a person at the screen](#checking-the-app-without-a-person-at-the-screen)
- [Demo data](#demo-data)
- [Screenshots](#screenshots)
- [Signing and notarization](#signing-and-notarization)
- [Releasing on GitHub](#releasing-on-github)
- [Architecture](#architecture)

## Requirements

- A Swift 6 toolchain (Xcode 16 or later; developed with Swift 6.4 / Xcode 27.2). The
  package is built with SwiftPM; there is no `.xcodeproj`.
- No third-party packages: Apple frameworks only (SwiftUI, Charts, MapKit, SQLite3,
  AppKit, Compression).
- For the demo data: `/usr/bin/python3` (3.9 or later, standard library only; where
  `/usr/lib/libcompression.dylib` can be loaded it is used through `ctypes` for LZFSE, so
  compressed blobs differ in bytes, not in content, on a system without it).
- Full Disk Access for the process that reads real stores: the terminal application when
  you run the binary from a terminal, the app itself when you run `Dossier.app`. Demo mode
  needs none.

## Build and run

```sh
swift build -c release                 # everything
swift run -c release Dossier           # start the app from a terminal

scripts/make-app.sh                    # build/Dossier.app: native, ad-hoc signed, with icon
scripts/make-app.sh --universal        # arm64 + x86_64
scripts/make-app.sh --dmg              # … and build/Dossier-<version>.dmg
```

| Option        | Effect                                                                   |
|---------------|--------------------------------------------------------------------------|
| `--universal` | Build both architectures instead of this Mac's.                          |
| `--dmg`       | Compressed disk image with an `/Applications` shortcut.                  |
| `--notarize`  | Developer ID build (implies `--universal`), notarized and stapled; see [Signing and notarization](#signing-and-notarization). |

`scripts/make-app.sh` builds in release mode, assembles the bundle, draws the icon with
`scripts/make-icon.swift` (no image assets are checked in for the bundle), writes the
`Info.plist` with the version from the `VERSION` file, and signs. Without options it needs
no signing identity, no keychain, no sudo and no network, and it never launches the app.

Each area also builds as its own small executable, `dossier-dev-<moduleID>`, that takes the
same flags and compiles only that module and `DossierCore`:

```sh
swift build --product dossier-dev-graph --scratch-path .build-graph
.build-graph/debug/dossier-dev-graph --selftest
```

## Self-test

```sh
.build/release/Dossier --selftest             # every store; exit status 1 on any FAIL
.build/release/Dossier --selftest photos      # one module
.build/release/Dossier --summary              # stores (path, size, rows, range) and headline facts
.build/release/Dossier --search "<query>"     # what toolbar search returns, with deep-link targets
.build/release/Dossier --list                 # module and section ids
```

There is no XCTest target: the checks live in the app and run against the stores they are
about. `--selftest` prints `PASS` / `WARN` / `FAIL` / `INFO` lines per module and ends with
a timing table. Its `core` block checks the guarantees every module relies on, on scratch
databases in the temporary directory: that reading never creates or touches a store's
`-shm` / `-wal` files, that the LZFSE decoder reads what the demo generator writes, and
that the shared layouts answer minimum-size queries correctly. Each module then reads its
stores, cross-checks counts between stores where two hold the same events, and reports
schema it does not recognise as a warning, not a crash. The `raw` block also holds the
write-rejection check (21 kinds of modifying statements are refused and leave a scratch
database byte-identical), so `--selftest <another module>` does not run that one. The run fails if all module
summaries together, loaded concurrently as the Overview does, take more than 6 seconds.

Run it on your real stores (needs Full Disk Access) and on demo data; the two exercise
different things. Its output on real stores contains counts and names from your Mac.

## Checking the app without a person at the screen

Three flags render the UI without ever putting a window on screen: nothing is ordered in,
activated or posted to the system, and no Screen Recording or Accessibility permission is
involved.

```sh
D=.build/release/Dossier
$D --snapshot graph.me out.png [--dark] [--size 1400x850] [--scale 2] [--payload <deep link>] [--privacy]
$D --screenshot graph.me out.png [--dark] [--size 1320x840] [--payload <deep link>] [--query <text>] [--select-row 0]
$D --uitest all --out /path/outside/the/repo
```

- **`--snapshot`** hosts one section's view alone, with a plain title strip standing in
  for the toolbar. Fast, and the tool for looking at a section while working on it.
  `--snapshot app` renders the window content with the sidebar.
- **`--screenshot`** draws the whole window as the app builds it: title bar, toolbar,
  search field, and the sidebar with the shown module expanded. `--size` is the window
  size in points and the PNG has two pixels per point unless `--scale 1`. `--query` types
  into global search; `--select-row n` selects a row in each table so an inspector is
  open; `DOSSIER_SNAPSHOT_NO_FDA=1` shows the permission screen.
- **`--uitest`** hosts the same window, visits every section at several window sizes and
  checks layout invariants (nothing clipped, minimum sizes honoured, toolbar not
  overflowing, tables not squeezed), then clicks, scrolls, types into search, opens the
  first hit, resizes, and toggles the sidebar and Privacy Mode with synthesized events.
  It writes a PNG per state and a `report.json`; exit status 1 on any failure. A full run
  takes between five and fifteen minutes, depending on the machine and the data.

What these pictures are and are not: they are drawn in-process (`cacheDisplay`), without
the window server. Layout, text, tables, charts and toolbar are what the app shows.
Materials are flat rather than translucent, and the window looks like an inactive one
(grey traffic lights, grey rather than accent-coloured selection, a default button that is
not filled). Sidebar icons lose their system tint that way, so captures tint them
explicitly. Interactive MapKit maps do not render off-screen at all; map views switch to a
static `MKMapSnapshotter` image in these modes, which downloads tiles like the live map.
Hover, drag, context menus, menu-bar commands and keyboard shortcuts are not exercised.

Output made from real stores contains personal data. Write it outside the repository;
`*.png`, `*.csv` and `report.json` are git-ignored as a safety net.

[ARCHITECTURE.md §3 and §3a](ARCHITECTURE.md#3-build-self-test-snapshot) have every option,
the list of invariants and how to read the report.

## Demo data

Nothing published about Dossier may show a real person's stores, so the app has a demo
mode and the repository has a generator for the data it shows.

```sh
/usr/bin/python3 scripts/make-demo-data.py /tmp/dossier-demo      # [--seed N] [--only graph,biome] [--now 2026-01-31T09:00:00Z]
/usr/bin/python3 scripts/make-demo-data.py --check                # unit checks of the format writers

export DOSSIER_DEMO_ROOT=/tmp/dossier-demo
.build/release/Dossier --selftest          # adds the demo checks
swift run -c release Dossier               # the app on demo data
```

**The generator** writes about 400 files (160 MB) in the layouts and formats of the real
stores: SQLite and CoreData databases, Biome SEGB streams with valid checksums, protobuf
payloads, plists and keyed archives, a Photos library's databases (no pictures). One
module per sidebar area lives in `scripts/demo/<moduleID>.py`; the shared invented person
is `scripts/demo/persona.py` and the format writers are `scripts/demo/lib.py`. The rule
for all of it is **schema from the real stores, content always invented**: table and
column names, enum codes and field numbers describe Apple's formats, while every name,
address, message, place, count and date is made up. People have `example.com` /
`.org` / `.net` addresses and phone numbers in the range reserved for fiction; places are
public landmarks and invented businesses; private places carry no house number. With the
same `--seed` and `--now`, two runs write the same content; without `--now` all dates are
relative to the current time. Container folder names derive from the seed alone. The script only deletes an output
folder it created itself and refuses your home folder, `~/Library`, `~/Pictures` and the
system locations that hold stores.

**Demo mode** (`DOSSIER_DEMO_ROOT` set to that folder) is enforced in three layers, so a
demo run cannot show or read a real store by accident:

1. Every store path derives from `Paths`, which resolves below the demo root.
2. Core's readers (`SQLiteDB`, the SEGB reader, file probes) refuse any location outside
   the root, with symbolic links resolved first. The only exception is the self-tests' own
   scratch files in the temporary directory (`dossier-selftest-*`, `dossier-shmtest-*`).
3. A sandbox profile applied at start-up denies the process reading and writing the real
   store locations, so code that built a path by hand, or a framework reading on its own
   (the text system opens the spelling dictionaries when the search field is typed into),
   gets "Operation not permitted".

Demo mode refuses a root that is, contains or lies inside one of those real locations. If
the sandbox cannot be applied (for example when the process already runs inside another
sandbox), the window, `--snapshot`, `--screenshot` and `--uitest` refuse to start and
`--selftest` fails, so pictures are never taken without the third layer;
`DOSSIER_DEMO_ALLOW_UNSANDBOXED=1` overrides that and leaves the first two layers.

The app then shows a "Demo data" marker in the sidebar footer, resolves names and icons
only for apps that ship with macOS (so a picture does not reveal which apps are installed
on the Mac that made it), and uses the `en_NZ` locale and `Pacific/Auckland` time zone
(`DOSSIER_DEMO_LOCALE`, `DOSSIER_DEMO_TZ`). Its UI preferences (last section, Privacy
Mode, sidebar state) live in a separate defaults domain, `dev.dossier.viewer.demo`, so a
demo run and the real app do not change each other. `--selftest` verifies the three layers
and, at the end, that nothing outside the root was asked for, that the sandbox's list
covers the real counterpart of every location that was read, and that no open file lies in
a real store. The sandbox list is a fixed list of store locations, not "everything outside the
root", and it uses `sandbox_init`, which Apple has deprecated; if that ever stops working
the self-test says so and the other two layers remain.

Limits worth knowing: where a field's real values are not known the generators invent
them, so demo data proves the readers work on well-formed stores, not that they survive
every real one. The persona's UTC offset is fixed at +13, so times of day are an hour off
for a `--now` in the New Zealand winter. Details, the helper API and the per-store
contract are in [ARCHITECTURE.md §9](ARCHITECTURE.md#9-demo-data).

## Screenshots

The pictures in the README show the invented person from the demo data, not anybody's Mac.
One script makes all of them:

```sh
scripts/make-screenshots.sh                       # every picture → docs/images/
scripts/make-screenshots.sh --only search,graph-me
scripts/make-screenshots.sh --keep                # keep the temporary demo data and staged app
```

It builds the release binary, stages it as a throwaway `Dossier.app` in a temporary folder
(the permission screen only offers its drag-the-icon flow, and only has an icon, when the
process runs from a bundle), generates fresh demo data, runs the self-test on it, and takes
each picture with `--screenshot` at 1320x840 points, two pixels per point, while
`DOSSIER_DEMO_ROOT` is set. It also writes `docs/images/icon.png` from
`scripts/make-icon.swift`. The table of pictures (file name, section, deep link) is at the
end of the script; deep-link payloads that contain row ids are looked up through the app's
own `--search`, so they follow the data.

The pictures are not byte-identical between runs: the demo data's dates follow the clock
(`DOSSIER_NOW=2026-01-31T09:00:00Z` pins them), and the map picture depends on the map
tiles Apple serves. **`places-map.png` needs the network**: MapKit downloads tiles for the
invented places, which are public landmarks in New Zealand, so the request says nothing
about anyone. Offline, that map comes out blank.

Before committing new pictures, look at each one: it must show only the persona and the
"Demo data" marker. `.gitignore` ignores `*.png` everywhere except `docs/images/`.

## Signing and notarization

By default the bundle is signed ad hoc. That is all you need on the Mac that built it, but
every ad-hoc rebuild has a new code identity, so macOS treats it as a different app and
Full Disk Access has to be granted again. An ad-hoc build copied to another Mac is stopped
by Gatekeeper.

For a build that opens cleanly elsewhere, and keeps its permission across updates, you
need an Apple Developer ID:

```sh
# once: store credentials for notarytool in the keychain
xcrun notarytool store-credentials dossier-notary --apple-id you@example.com --team-id TEAMID

export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE=dossier-notary        # the default
scripts/make-app.sh --notarize --dmg
```

`--notarize` builds universal, signs with the hardened runtime and a secure timestamp,
submits the app to Apple, staples the ticket, checks the result with Gatekeeper, and with
`--dmg` signs, notarizes and staples the disk image as well. It checks the identity and
the keychain profile before building. `notarytool` and `stapler` ship with Xcode, not with
the Command Line Tools.

## Releasing on GitHub

```sh
scripts/release.sh            # notarized build, tag v<VERSION>, DRAFT release with dmg and checksum
scripts/release.sh --publish  # the same, published immediately
scripts/release.sh --notes notes.md
```

The script refuses to run with uncommitted changes, an unpushed HEAD or an existing tag,
and needs `CODESIGN_IDENTITY`, the notarytool profile and a logged-in `gh`. Bump `VERSION`
for each release. The README's download badge points at the latest *published* release:
the script makes a draft unless `--publish` is given, and until a release is published the
badge and the Releases link lead nowhere. The dmg must be attached under the name the
script gives it (`Dossier-<version>.dmg`). The README describes the current source, so
publish a release from the commit whose README you are showing (demo mode, for one, is
only in 0.2.0 and later).

## Architecture

A single Swift package (`Package.swift`; Swift 5 language mode, tools version 6.0):

| Target | Role |
|---|---|
| `DossierCore` | Shared library: store locations and probing (`Paths`), the read-only SQLite wrapper, the Biome SEGB reader, schema-less protobuf, plist and keyed-archive decoding, shared UI components (paged tables, charts, maps, inspectors, tree and hex views), the command-line runner, the off-screen harnesses, demo mode. |
| `DossierApp` | The executable `Dossier`: window, sidebar, toolbar search, Overview, Settings, the permission screen. `ModuleRegistry.swift` is the one list of modules. |
| `GraphModule`, `ProfileModule`, `CommsModule`, `MailSearchModule`, `ActivityModule`, `EnvironmentModule`, `PhotosModule`, `BiomeModule`, `RawModule` | One sidebar area each. A module implements `DossierModule`: its sections, a cheap `summary()` for the Overview, `search()` for global search and `selfTest()`. Modules depend on Core only. `RawModule` is the reference implementation. |
| `Sources/Dev/<id>` | `dossier-dev-<id>`: a minimal shell hosting one module. |

Scripts and documents:

- `scripts/make-app.sh` — builds, bundles, signs and packages the app.
- `scripts/release.sh` — notarized build, tag and GitHub release.
- `scripts/make-icon.swift` — draws the app icon into an `.iconset`.
- `scripts/make-demo-data.py`, `scripts/demo/` — the demo data generator.
- `scripts/make-screenshots.sh` — the README pictures.
- [ARCHITECTURE.md](ARCHITECTURE.md) — the rules all code follows (read-only, no prompts,
  no personal data in the repository, I/O off the main thread), the module protocol, the
  data layer and UI components with examples, the UI-test invariants and layout rules, UI
  conventions, a checklist for module changes, and the demo-data contract and helper API.
- [PRIVACY.md](PRIVACY.md) — the privacy policy.
