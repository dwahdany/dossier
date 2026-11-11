# Dossier — Architecture and Module Guide

Dossier is a native macOS (SwiftUI, macOS 15+) viewer that shows the owner of a Mac what
the system's on-device knowledge and personalization stores hold about them. It is a Swift
package (no `.xcodeproj`), built with `swift build`.

This document describes how the app is put together and what a feature module has to do:
the module protocol, the shared data layer and UI components in `DossierCore`, the
off-screen test harnesses, and the demo data set. Read it together with the doc comments in
`Sources/DossierCore`; the reference implementation of everything described here is
`Sources/RawModule`. Building, testing, screenshots and releasing are in
[DEVELOPMENT.md](DEVELOPMENT.md).

---

## 1. Rules for all code

1. **Strictly read-only** toward `~/Library`, `~/Pictures` and `/private/var`. Never write,
   vacuum, checkpoint, or open a system database read-write. Use `SQLiteDB` (opens
   `file:<path>?mode=ro`, `SQLITE_OPEN_READONLY`, `PRAGMA query_only=ON`, plus an authorizer
   that denies everything but reads). Never create indexes. Never call `sqlite3_open*`
   yourself on a system store.
2. **No prompts.** Never use `sudo`, `osascript`, `security`, `tccutil`, `sfltool` or
   anything that could raise a GUI / admin / keychain / permission prompt. "Operation not
   permitted" must become an *inaccessible* state in the UI (see `Availability`,
   `DossierError.inaccessible`, `StatePlaceholder.inaccessible`).
   Known gap (not reproduced, open): without Full Disk Access, reading a path under
   `~/Library/Containers/*` or `~/Library/Daemon Containers/*` (photolibraryd preferences,
   CoreRecents, the kvs / linkd / milod / hybridsearchd containers) can raise the macOS
   alert "would like to access data from other apps". The app shows the permission screen
   first and loads no section until the user confirms "Continue Without Access…", which
   says so. The proper fix belongs in `Paths` and the modules: skip those paths and report
   them as inaccessible while `Paths.hasFullDiskAccess()` is false.
3. **No personal data in the repository.** No owner names, e-mail addresses, phone numbers,
   contact names, device identifiers, UUIDs taken from data, message text — not in source,
   comments, tests, fixtures or docs. Paths derive from `Paths` (home directory at runtime),
   never `/Users/<name>`. Generic Apple identifiers (bundle ids, ontology codes, stream,
   table and column names) are fine. Real values are *shown at runtime*, never baked in.
   The demo data set (§9) follows the same rule from the other side: **schema from the
   real stores, content always invented.**
4. **No network** use involving personal data, and **no third-party dependencies** — Apple
   frameworks only (SwiftUI, Charts, MapKit, SQLite3, Foundation, AppKit, Compression…).
5. **Scripts and tests never put a window on screen**: no `open`, no `screencapture`, no
   posted input events. UI is checked through `--snapshot` / `--screenshot` / `--uitest`
   (off-screen), and PNGs made from real stores are written **outside the repository**
   (they contain personal data; `*.png` is git-ignored as a safety net, and only
   `docs/images/`, rendered from demo data, is exempt).
6. **All I/O off the main thread.** Page everything (`LIMIT`/`OFFSET` or keyset), `mmap`
   big files, never load a whole store into memory.
7. Schemas differ per macOS version: **probe** (`tableExists`, `columnNames`, `hasColumns`)
   and degrade gracefully when a store / table / column is missing.
8. **Modules are independent.** A feature module depends on `DossierCore` only, never on
   another module, and is registered in exactly one place (`ModuleRegistry.swift`).
   Anything two modules need (a reader, a component, a name table) belongs in Core;
   propose that as its own change rather than copying it into a module.

---

## 2. Repository layout

```
Package.swift                       all targets (Swift 5 language mode, tools 6.0)
README.md                           what the app does, install, privacy, limitations
DEVELOPMENT.md                      build, self-test, UI test, demo data, screenshots, signing, releasing
PRIVACY.md                          the privacy policy
LICENSE                             MIT
VERSION                             the release version (read by make-app.sh and release.sh)
Sources/DossierCore/                shared library
  Module.swift                      DossierModule protocol, ModuleSection, summaries, search hits
  Data/Paths.swift                  store locations, probing, daemon containers, FileProbe
  Data/SQLiteDB.swift               read-only SQLite wrapper + pool
  Data/SEGB.swift                   SEGB reader, Biome stream discovery, BiomeStreamReader
  Data/Protobuf.swift               schema-less protobuf decoder
  Data/PlistDecoding.swift          PlistValue, binary plist parser, NSKeyedArchiver resolver
  Data/DataNode.swift               display tree + BlobSniffer
  Data/Dates.swift                  DossierDate (epochs, formatting), Format (counts/bytes/durations)
  Data/FastProto.swift              FastProto (allocation-free protobuf walker), ByteNeedle, LZFSE
  Data/DemoGuard.swift              demo mode (DOSSIER_DEMO_ROOT): kernel sandbox, reader audit, self-test lines
  Data/AppDirectory.swift           AppDirectory (bundle id → name / icon), AppIcon, AppLabel
  UI/LoadState.swift                LoadState, AsyncContent, placeholders, environment values, SnapshotReadiness
  UI/PagedTable.swift               PagedTable, PagedColumn, PageRequest
  UI/Components.swift               Metrics, ScrollPage, SectionHeader, FilterField, StatTile(Row), KeyValueGrid,
                                    SensitivityBadge, TagLabel, StoreFooter, detailInspector, InspectorPage, CSV, Pasteboard
  UI/ChartViews.swift               BarChartView, LineChartView, TimelineHeatmap, ChartPalette
  UI/MapViews.swift                 PointMapView, MapPoint, MapCluster
  UI/TreeAndHex.swift               DataTreeView, HexView, BlobInspector
  UI/SharedPieces.swift             FlowLayout, HeaderStrip, PaneFooter, AdaptiveSegmentedPicker, FittingStrip,
                                    AdaptiveMasterDetail
  UI/LayoutSelfTest.swift           --selftest lines for the shared layouts' minimum / ideal sizes
  Runner/DossierRunner.swift        CLI (--selftest/--snapshot/...), offscreen snapshotter, dev shell
  Runner/UITest.swift               --uitest: real-window UI test (layout invariants, synthesized input, report);
                                    --screenshot: one picture of that window
  UI/UITestProbe.swift              layout probes used by --uitest (inactive otherwise)
Sources/DossierApp/                 executable "Dossier": window, sidebar, search, overview, settings
  ModuleRegistry.swift              THE module list (one file)
Sources/<Name>Module/               one library target per feature module
Sources/Dev/<id>/main.swift         executable "dossier-dev-<id>" hosting only that module
scripts/make-app.sh                 release build → build/Dossier.app (Info.plist, generated icon, ad-hoc signature);
                                    --universal, --dmg, --notarize (Developer ID, notarized, stapled)
scripts/make-icon.swift             draws the app icon into an .iconset (no external assets)
scripts/make-demo-data.py           builds the synthetic demo data set (§9); Python 3 standard library only
                                    (plus the system's libcompression through ctypes, when present)
scripts/make-screenshots.sh         renders the README pictures into docs/images/ from demo data
scripts/release.sh                  notarized build, tag, GitHub release
docs/images/                        README pictures (demo data only), app icon, download badge
scripts/demo/                       persona.py (the invented owner), lib.py (format writers), selfcheck.py,
                                    one generator per module id (<moduleID>.py)
```

Modules (target / id): `GraphModule`/`graph`, `CommsModule`/`comms`,
`ActivityModule`/`activity`, `EnvironmentModule`/`environment`, `ProfileModule`/`profile`,
`PhotosModule`/`photos`, `MailSearchModule`/`mailsearch`, `BiomeModule`/`biome`,
`RawModule`/`raw` (reference implementation, complete).

A module target may contain any number of files. Keep the class name, the `id` and the
`public init()`.

---

## 3. Build, self-test, snapshot

Each module also builds as its own small executable, which is the fast way to work on one.
SwiftPM takes a lock on its build directory, so two builds in one checkout queue behind
each other; a separate `--scratch-path` per build avoids that (`.build-*/` is git-ignored).

```sh
B=.build-<id>                                           # a build directory for this module
swift build --product dossier-dev-<id> --scratch-path $B    # this module + Core only (fast)
swift build --target <Name>Module --scratch-path $B         # compile check of the library alone

$B/debug/dossier-dev-<id> --list                    # module + section ids
$B/debug/dossier-dev-<id> --selftest                # prints PASS/WARN/FAIL lines, exit 1 on FAIL
$B/debug/dossier-dev-<id> --summary                 # prints summary(): stores + facts
$B/debug/dossier-dev-<id> --search "<query>"        # prints search() hits
# equivalent: swift run --scratch-path $B dossier-dev-<id> --selftest

# Offscreen snapshot of one section (no window ever appears, no Screen Recording needed):
$B/debug/dossier-dev-<id> --snapshot <sectionID|moduleID> /path/outside/repo/x.png \
      [--dark] [--size 1400x850] [--wait 20] [--privacy] [--payload "<deep link>"] [--scale 2]

# Whole app (builds every module):
swift build --scratch-path $B
$B/debug/Dossier --selftest [moduleID]              # same flags on the full app
$B/debug/Dossier --snapshot overview out.png        # the Overview dashboard
$B/debug/Dossier --snapshot app out.png             # whole window content (sidebar + detail)
```

A dev executable or `Dossier` started **without** flags opens the GUI; scripts always
pass one.

`--selftest` on the full app ends with a `== timing` table (self-test and `summary()` time
per module) and fails if all summaries, run concurrently as the Overview does, take more
than 6 s. `--search` runs every module concurrently and exits 1 if a hit names a section
that does not exist. `scripts/make-app.sh` builds `build/Dossier.app`; test the bundle with
`build/Dossier.app/Contents/MacOS/Dossier --selftest` (scripts never `open` it).

Snapshot facts:

* The section view is hosted in an `NSHostingView` inside a borderless window that is
  **never ordered in** (verified: the process owns no on-screen window and has no Dock
  icon); `Table`, `List`, `ScrollView` and Swift Charts render.
  Window toolbars do not exist in a snapshot — a simple title strip stands in.
* **MapKit `Map` does not snapshot reliably**: its GPU layer is captured only by accident
  of timing (blank once tiles have loaded) and `Annotation` views never are. Use
  `PointMapView` (§6), which switches to a static `MKMapSnapshotter` rendering while
  `SnapshotReadiness.isSnapshotting` is true. The same applies to any other Metal /
  AVFoundation-backed view.
* The harness waits until `SnapshotReadiness.pending == 0` for ~0.45 s (max `--wait`).
  `AsyncContent` and `PagedTable` report automatically. If you load data in your own
  `.task`, wrap it: `await SnapshotReadiness.track { ... }` (or `begin()` / `end()`),
  otherwise the snapshot is taken before your data arrives.
* `--payload` delivers a `DeepLink` to the section (same as a search hit).
* `DOSSIER_SNAPSHOT_SELECT_ROW=<n>` selects row *n* of every `PagedTable` after its first
  load, so inspectors can be captured.
* `--privacy` renders with Privacy Mode on — check that everything personal is blurred.
* `--snapshot app` honours `DOSSIER_SNAPSHOT_SECTION=<id>`, `DOSSIER_SNAPSHOT_SEARCH=<q>`,
  `DOSSIER_SNAPSHOT_NO_FDA=1`.
* `--screenshot <section> out.png` renders the **whole window** instead (title bar,
  toolbar, sidebar with only the shown module expanded) from the off-screen window of
  §3a, at 2 pixels per point by default: `--size WxH` is the window size in points,
  `--payload`, `--query <text>` (global search results), `--select-row n`, `--dark`,
  `--privacy`, `--wait`, `--linger <seconds>`. It is what `scripts/make-screenshots.sh`
  uses for the README pictures. The picture is drawn in-process, without the window
  server, so materials are flat and the window looks inactive (grey traffic lights, no
  accent-coloured selection); sidebar icons are tinted explicitly in captures because
  their system tint is lost that way (`SidebarLabelStyle`).
* Always look at the PNG after changing UI. Check light and dark.

---

## 3a. UI test in a real window (`--uitest`)

`--snapshot` renders one section at a fixed frame. It never asks for minimum or ideal
sizes, so it cannot see the bugs that only a real window shows: a view whose minimum size is
larger than the window can give makes the split view lay the detail column out wider than
the window (content clipped on both sides, sidebar pushed out, toolbar items in the overflow
menu). `--uitest` hosts the **real shell** — the same root view the `Window` scene builds
(`DossierApplication.windowContent`: `NavigationSplitView`, sidebar, toolbar, `.searchable`),
or the dev shell — in a real titled, resizable `NSWindow` through an `NSHostingView` with
default `sizingOptions`, so content minimum / ideal sizes reach the window exactly as in the
running app. The window sits at x = -30000, is never ordered in, never activated, and the
process has no Dock icon. Captures are drawn in-process (title bar and toolbar included).

```sh
B=.build-<id>;  OUT=/path/outside/repo/uitest      # PNGs and report contain personal data

# one module, in its dev executable (fast: build + ~20–35 s)
swift build --product dossier-dev-<id> --scratch-path $B
$B/debug/dossier-dev-<id> --uitest --out $OUT                 # every section of the module
$B/debug/dossier-dev-<id> --uitest <id>.<section> --out $OUT  # one section

# the full app
swift build --scratch-path $B
$B/debug/Dossier --uitest overview --out $OUT                 # one section (or `<moduleID>` for one module)
$B/debug/Dossier --uitest all --out $OUT                      # everything (5–15 min)

# options
#   --sizes 980x600,1360x860     content sizes (default: shell minimum, 1360x860, 1800x1100)
#   --query <text>               text typed into global search (default "apple")
#   --no-interactions            layout invariants and PNGs only
#   --wait <seconds>             load timeout per section (default 20)
#   --payload <deep-link payload> with a section id as the target: also test the section in
#                                the state this deep link selects (a tab behind a picker)
#   --dark                       run everything in the dark appearance
#   --screen WxH                 the virtual screen (default 1800x1169); a window cannot be
#                                larger, so bigger --sizes are clamped (with a note)
# DOSSIER_UITEST_VERBOSE=1 prints the current stage to stderr; DOSSIER_UITEST_DUMP=1 the AppKit view tree.
```

Exit code 0 = no failure, 1 = failures, 2 = bad arguments, 3 = run exceeded 25 minutes.
Run it after every UI change, before proposing a change to a module, and whenever you touch a custom
`Layout`, a header strip, a master–detail split or anything with `.fixedSize()`.

**What it does per section**, with the sidebar visible: clicks the section's sidebar row,
waits for loads (`SnapshotReadiness`, and up to 8 s more while a spinner is still visible
in the section — a capture that still shows a `ProgressView` fails the `load` check), then
for each size resizes the window, checks the invariants below and saves
`<section>-<W>x<H>.png` (plus `-dark` for the first section of each module; `--dark` runs
everything dark). Then, at the smallest tested size:

* scrolls the detail content and — for scrolling pages, not tables — saves up to three
  captures further down, a viewport apart, the last at the end of the content
  (`…-scrolled1.png` …), so what is below the fold of a `ScrollPage` is seen too;
* `table-room`: fails when a table or list with three or more rows shows fewer than three
  of them (a table squeezed to its header by tiles, strips and footers);
* clicks the first row of the section's largest table / list and — if a row became
  selected — checks the invariants again with the selection (usually: inspector open) and
  saves `…-selected.png`.

**Further states of a section (tabs behind a mode picker).** The default run only sees the
state a section opens in. Declare the others as deep-link payloads and handle them through
`@Environment(\.deepLink)` like a search hit:

```swift
ModuleSection(id: "activity.predictions", title: "Predictions", symbol: "sparkles",
              uiTestPayloads: ["tab:routines", "tab:intents"]) { PredictionsView() }
```

`--uitest` then opens the section once per payload (through the shell's normal deep-link
path) and repeats everything above in that state; contexts are `payload 1`, `payload 2`, …
and files `<section>-p1-<W>x<H>.png`. `--uitest <section> --payload <p>` does the same for
one ad-hoc payload. Payloads in source are generic mode names, never personal data.

**Invariants** (each is a named check in the report, with numbers):

| check | fails when |
| --- | --- |
| `window-size` | the window / hosted view is not the size that was requested — the content forced it larger |
| `content-min` | the window content's minimum size (zero proposal) exceeds the shell minimum (980x600 app, 900x560 dev shell); names the sections that cause it |
| `content-ideal` | the window content's ideal width is over 3000 |
| `sidebar` | the sidebar is not at x 0 or its width is outside the column's min…max — it was pushed out or squeezed |
| `detail-in-window` | the detail column starts left of the window or ends right of it |
| `section-fits` | the section was laid out larger than the detail column offered: that many points are **clipped on screen** at this size |
| `section-min` | the section's minimum size is larger than the minimum window leaves beside the narrowest sidebar (779x600 app, 719x560 dev shell). Fails at every size: it is a property of the section, and it is what breaks a window that honours minimum sizes |
| `section-ideal` | the section's ideal width is over 3000 |
| `scroll-content-fits` | the content of a `ScrollPage` / `InspectorPage` is wider than its viewport |
| `appkit-scroll-width` | a vertical-only scroll view's document is wider than its clip view |
| `popup-width` | a visible pop-up button (menu picker, `Menu`) in the section is narrower than 20 pt (layout rule 6) |
| `toolbar` | a toolbar item ended up in the overflow menu |

`appkit-fitting` (`NSHostingView.fittingSize`) is reported but never fails on its own.

`section-min` is a **lower bound** for a section that uses `ViewThatFits`: the minimum is
measured for the alternative that is on screen in that layout pass, so the same code can
report different minimums at different window sizes (seen: 342 … 683 for one section with
AppKit-backed controls). Trust `section-fits` at the minimum size and the PNG over a
passing `section-min` there.

**Window-level interactions** (once per run, on the first tested section): live resize
large → minimum → large → minimum in steps with the invariants at each end; a request below
the minimum must be refused; sidebar hide / show; Privacy Mode toggle through its toolbar
button; global search (app only): type the query, wait for hits, press Return and expect
the first hit's section to be selected and the search text cleared. The Settings content is
hosted separately and must be exactly its fixed size.

**How input is synthesized.** Nothing is posted to the system (no `CGEvent` posting, no
Accessibility or Screen Recording). `NSWindow.sendEvent` drops mouse events for a window
that is not on screen, so a click is dispatched the way `sendEvent` would: hit-test, then
`mouseDown(with:)` / `mouseUp(with:)` on the view under the point, with the mouse-up queued
in the app's own event queue first (AppKit controls pull it from there in their tracking
loop). Key events go to the window's first responder. Known limits — the report says which
path was taken:

* **Scrolling**: a scroll-wheel `NSEvent` is handed to the `NSScrollView`. Some scroll
  views ignore it (about a third, mostly tables); the harness then scrolls the clip view
  programmatically, which proves the content *can* scroll, not that wheel input works.
* **Sidebar toggle**: AppKit only runs the collapse animation while the display is awake.
  With the display asleep the harness sets `NSSplitViewItem.isCollapsed` directly instead
  of clicking the toolbar button, and adds a note.
* **Typing**: key events are translated by the current keyboard layout; if the search text
  does not come out as the query the harness inserts the text into the field editor.
* **Table click**: proves row selection and counts shared `detailInspector` panels; a
  section that shows details some other way is reported as "no shared inspector appeared".
* Hover, drag (inspector resize handle, column resize), context menus, menu-bar commands
  and keyboard shortcuts are **not** exercised. MapKit views render as static snapshots.
* Without Full Disk Access the run only captures the permission screen; it never dismisses it.

**Reading `report.json`** (`<out>/report.json`): `passed`, `failures` (flat list, one line
per failed check — start here), `notes`; `sections[]` with `id`, `module`, `loadSeconds`,
`interactions[]` and `layouts[]`; each layout has `size`, `context` (`initial`,
`row selected`), `png`, `checks[]` (`name`, `status` pass / fail / skip / info, `detail`)
and `numbers` — `sectionProposedWidth` (what the detail column offered),
`sectionPlacedWidth` (what the section took), `sectionMinWidth/Height`,
`sectionIdealWidth`, `sectionMinWidthBudget`, `sidebarWidth`, `detailMinX/MaxX`,
`contentMinWidth/Height`, `windowWidth/Height`; `pngScrolled` lists the captures further
down the page. `global[]` holds the window-level
interaction checks, `globalLayouts[]` their layouts and PNGs, `auxiliary[]` Settings.
Always look at the PNG of a failing layout.

**Layout rules this enforces**

1. **Every custom `Layout` must answer a zero-width proposal with its true minimum** — the
   narrowest width at which it can actually lay itself out (one column for a grid), never
   its one-row or ideal width. A proposal of 0 is SwiftUI's minimum-size query; the answer
   travels up to the split view and the window. Answer `nil` (ideal) with something modest.
   `BalancedGrid` once answered 0 with its one-row width: the Overview's minimum became
   2401 pt and the whole window broke. Reverting that fix makes `--uitest overview` fail
   (`section-min: section minimum 2401x0`).
2. A section's minimum must fit **779x600** (app; with a row selected too). Usual
   offenders: a header strip whose pickers / segmented controls cannot shrink, an
   `HStack` of fixed-width panes (master list + detail + inspector), `.fixedSize()` on wide
   content, a non-scrolling `VStack` taller than 600. Make strips wrap or scroll, give
   panes `minWidth` values that add up, put tall content in a `ScrollPage`.
3. Hand-rolled `ScrollView { … }` roots should mark their content with
   `.uiTestProbe("scroll")` so `scroll-content-fits` covers them.
4. Shells host sections through `.uiTestSection(id).containedSection(minimumWindow:narrowestSidebar:)`:
   a section minimum is passed on only up to what the minimum window can offer, beyond
   that the section is clipped at its trailing / bottom edge instead of wrecking the
   window. That containment is a safety net, not a licence — `section-min` and
   `section-fits` still fail.
5. `detailInspector` never raises a section's minimum. As the width shrinks the inspector
   first gives up width (down to 260 pt) while the content keeps `minimumContentWidth`
   (default 400), then the content shrinks to its own minimum, then the inspector overlays
   the content's trailing edge. A fixed master list + table + inspector does not fit the
   minimum window: use `AdaptiveMasterDetail`, which tucks the list away while the
   inspector is open.
6. **Nest `ViewThatFits` alternatives in pairs** when they contain pop-up buttons
   (`Picker` with `.menu` style or the default macOS style, `Menu`): in a flat
   `ViewThatFits` with three or more alternatives the pop-ups of the third and later ones
   are sized to a few points while every size invariant passes. Write
   `ViewThatFits { a; ViewThatFits { b; c } }`. `popup-width` catches the symptom.
   `ViewThatFits` also **builds the AppKit controls of every alternative again on each
   layout pass** (pop-up buttons, segmented controls): fine for one strip per section, far
   too slow in chrome that every table carries — a `PagedTable` footer written that way
   made a full `--uitest` run three times slower. There, put only `Text` alternatives
   inside `ViewThatFits` and switch controls on a measured width (`onGeometryChange`).
7. A custom `Layout` that wraps (`FlowLayout`, `BalancedGrid`, the filter bar) answers a
   zero-width proposal with its widest *item's* minimum, an unspecified one with a modest
   width (a few hundred points), and offers an item that is wider than a row the row width.
   `--selftest` checks this for the Core layouts in its "core" block (`LayoutSelfTest`);
   add a line there when you add a layout to Core.
8. Bars are one line: texts in strips and footers get `.lineLimit(1)`; what must not
   truncate gets `.fixedSize()` and what may go first a lower `layoutPriority` or a
   `ViewThatFits` alternative without it (`FittingStrip`, the `PagedTable` footer).

Never commit anything from the output directory.

---

## 4. The module protocol

```swift
public protocol DossierModule: AnyObject, Sendable {
    var id: String { get }                 // "graph" — prefix of all section ids
    var title: String { get }
    var symbol: String { get }             // SF Symbol
    var group: SidebarGroup { get }        // .identity / .people / .behaviour / .media / .raw
    var sections: [ModuleSection] { get }  // sidebar rows

    func summary() async -> ModuleSummary                             // Overview dashboard
    func search(_ query: String, limit: Int) async -> [SearchHit]     // global search
    func selfTest() async -> [SelfTestLine]                           // --selftest
}
```

Rules: `public final class`, no unprotected mutable state (put caches in an `actor`), the
three async methods never throw, never block the main actor, tolerate missing stores.

```swift
public final class ActivityModule: DossierModule {
    public let id = "activity"
    public let title = "Activity"
    public let symbol = "chart.bar.xaxis"
    public let group = SidebarGroup.behaviour
    public init() {}

    public var sections: [ModuleSection] {
        [
            ModuleSection(id: "activity.apps", title: "App Usage", symbol: "app.badge") { AppUsageView() },
            ModuleSection(id: "activity.web", title: "Web Usage", symbol: "safari") { WebUsageView() },
        ]
    }

    public func summary() async -> ModuleSummary {
        var stores = [StoreInfo.file("knowledgeC.db", Paths.knowledgeC)]           // probes availability + size
        var facts: [Fact] = []
        if let db = await SQLiteDB.sharedIfAvailable(Paths.knowledgeC), await db.tableExists("ZOBJECT") {
            stores[0].rowCount = await db.rowCount(of: "ZOBJECT")
            if let r = try? await db.first("SELECT min(ZSTARTDATE), max(ZSTARTDATE) FROM ZOBJECT"),
               let lo = r[0].cocoaDate, let hi = r[1].cocoaDate { stores[0].timeRange = lo...hi }
            facts.append(Fact("Most used app", "…", sensitivity: .personal, symbol: "app", sectionID: "activity.apps"))
        }
        return ModuleSummary(stores: stores, facts: facts)
    }

    public func search(_ query: String, limit: Int) async -> [SearchHit] {
        // SearchHit(title:subtitle:moduleID:sectionID:payload:symbol:sensitivity:)
        // `payload` is an opaque string your section understands (see deep links).
        []
    }

    public func selfTest() async -> [SelfTestLine] {
        [.check("knowledgeC readable", Paths.probe(Paths.knowledgeC).isAvailable)]   // also .pass/.warn/.fail/.info
    }
}
```

* **Section ids** are `"<moduleID>.<name>"`, stable (used for deep links, state restoration,
  `--snapshot`). A module with exactly one section appears as a single sidebar row; with
  several it becomes a disclosure group.
* **`summary()`** must be cheap (a few seconds at most): `count(*)`, `min/max`, no scans.
  Report every store you read as a `StoreInfo` (with `.missing` / `.inaccessible`
  availability when applicable) and a handful of headline `Fact`s — concrete "the system
  holds X about you" statements with an honest `Sensitivity`.
* **`search()`** returns at most `limit` hits and should check `Task.isCancelled` in loops.
  It is called concurrently with other modules on every (debounced) keystroke.
* **Deep links.** When the user opens a hit, the app selects `hit.sectionID` and sets
  `@Environment(\.deepLink)` to `DeepLink(sectionID:payload:nonce:)` for that section. React
  with `.onChange(of: deepLink?.nonce, initial: true) { if let link = deepLink { … } }` or
  `.task(id: deepLink?.nonce)`. `initial: true` matters: the section may be created by the
  navigation itself. The value is `nil` most of the time (and becomes `nil` again when the
  user leaves the section) — ignore `nil`, do not reset your state on it.
  The payload is an opaque string *you* define; make it a stable key of the thing to show
  (a row id, an entity id, a name), prefixed if the section shows several kinds
  (`"person:42"`). On receipt, the usual pattern is: load that one record by key and
  present it in the inspector (your own `selected` state drives `detailInspector`, it does
  not have to come from a table click), and/or narrow the table through
  `PagedTable(filter: $filterText)` by setting `filterText`. Test with
  `--snapshot <section> out.png --payload "<payload>"`.
  A hit with an empty payload just opens the section.
  To jump to another section yourself (cross-module links included):
  `@Environment(\.navigate) var navigate` → `navigate?(DeepLink(sectionID: "raw.sqlite", payload: path))`.
  `navigate` is `nil` in snapshots and in the dev shell (other modules are not loaded) —
  hide or disable such links when it is `nil`.
  Useful existing targets: `raw.sqlite` (`<db path>[\t<table>[\t<browse|schema|sql|sql!>]]`),
  `raw.biome` (stream name or directory path), `raw.files` (file path).
* **Sensitivity**: `.low` (technical), `.personal` (behaviour, titles, app usage),
  `.sensitive` (message text, contacts, locations, health, identity documents).

---

## 5. Data access

### 5.1 Paths

```swift
Paths.graphDB, Paths.ontologyDB, Paths.intelligencePlatformArtifacts
Paths.knowledgeC, Paths.interactionC, Paths.coreRecents, Paths.duetExpertCenter
Paths.biomeRestrictedStreams, Paths.biomeSets, Paths.biomeDatabases, Paths.biomeSyncDB
Paths.personalizationPortrait, Paths.suggestions, Paths.assistant, Paths.trial, Paths.spotlightKnowledge
Paths.callHistory, Paths.callHistoryDirectory, Paths.languageModeling
Paths.photosLibrary, Paths.photosSQLite, Paths.photosSearchIndex, Paths.photosPrivate      // optional URLs
Paths.daemonContainerData("com.apple.linkd")                                              // by MCMMetadataIdentifier
Paths.system("/private/var/db/…")       // an absolute location outside the home directory — never URL(fileURLWithPath:)
Paths.isDemo, Paths.demoRoot            // demo mode (§9): home and system() resolve below DOSSIER_DEMO_ROOT
Paths.allows(url)                       // false in demo mode for anything outside the root; Core's readers ask it
Paths.displayPath(url)                  // what to show for a location (= Format.tildePath): never the demo root itself
Paths.probe(url) -> Availability        // .available / .missing / .inaccessible(reason); never prompts
Paths.protectedStores()                 // stores beyond Full Disk Access (Screen Time, locationd, system knowledgeC): reported, never opened
Paths.hasFullDiskAccess()
Paths.knownStores()                     // every known root (used by Raw Explorer)
FileProbe.info(url), .databaseSize(url), .directorySize(url), .discoverDatabases(under:)
```

### 5.2 SQLite (`SQLiteDB`)

```swift
guard let db = await SQLiteDB.sharedIfAvailable(Paths.knowledgeC) else { throw DossierError.missing("knowledgeC.db") }
// or: let db = try await SQLiteDB.shared(path)   — throws SQLiteError (.missing / .inaccessible / .openFailed)

guard await db.hasColumns("ZOBJECT", ["ZSTREAMNAME", "ZSTARTDATE"]) else { throw DossierError.missing("ZOBJECT schema changed") }

let page = try await db.query(
    "SELECT Z_PK, ZSTREAMNAME, ZSTARTDATE FROM ZOBJECT WHERE ZSTREAMNAME = ? ORDER BY ZSTARTDATE DESC LIMIT ? OFFSET ?",
    [.text("/app/usage"), .integer(200), .integer(Int64(offset))])
for row in page.rows {
    let pk = row[0].int, stream = row["ZSTREAMNAME"].string, date = row[2].cocoaDate
}
let n = await db.count("SELECT count(*) FROM ZOBJECT WHERE ZSTREAMNAME = ?", [.text("/app/usage")])
let v = try await db.scalar("SELECT max(ZSTARTDATE) FROM ZOBJECT")
let histogram = try await db.reduce("SELECT ZSTARTDATE FROM ZOBJECT", into: [Int](repeating: 0, count: 24)) { acc, row in … }
try await db.forEach("SELECT …") { row in …; return true }       // streaming, return false to stop
```

* Connections are pooled per path (`SQLiteDB.shared`), confined to a private serial queue;
  every call is `async` and safe from the main actor. One connection per database means
  queries on the same file run **one after another**, across all modules: a slow
  aggregate delays every other query on that store until it finishes or is cancelled.
  Keep `summary()` and `search()` queries cheap and bounded (`LIMIT`).
* Writes are impossible by construction (read-only open, `query_only`, deny-all
  authorizer; the self-test proves 21 kinds of modifying statements are rejected and the
  file stays byte-identical). The URI is `file:<path>?mode=ro&readonly_shm=1`:
  `mode=ro` alone still lets SQLite open a WAL database's `-shm` read-write and rebuild
  or create it; `readonly_shm=1` maps it read-only and never creates one (the `core`
  self-test checks directory listing, inode, size and mtime on scratch WAL databases).
  A WAL database without a `-shm` falls back to `immutable=1`, which ignores the `-wal`:
  `db.isImmutableFallback` / `db.openModeNote` say so ("possibly stale") — show the note. `SQLiteError.writeAttempt` is what user-typed SQL gets.
* Some Apple databases use custom FTS tokenizers or virtual-table modules that are not
  available outside their framework; querying such a table throws — catch it and fall
  back to the plain tables.
* **Cancellation**: cancelling the calling `Task` interrupts the running statement
  (`sqlite3_interrupt`) and surfaces as `CancellationError`. `AsyncContent` and
  `PagedTable` cancel their loader's task when their key changes or the view goes away —
  so slow queries are cut off when the user moves on and `Task.isCancelled` checks in
  loaders fire. In your own `.task` code never write `try await Task.detached { … }.value`
  (an unstructured task does **not** inherit cancellation and runs to completion, blocking
  the store's connection); use `try await cancellableDetached(priority:) { … }`, which
  forwards cancellation. Do not wrap queries in unstructured `Task {}` that outlive views.
* `SQLValue` accessors: `.int .double .string .data .bool .cocoaDate .unixDate .isNull`.
  `SQLRow`: subscript by index or (case-insensitive) column name.
* `query(_:_:maxRows:cellByteLimit:)`: `maxRows` caps materialization (default 100 000;
  `result.truncated`); `cellByteLimit` truncates large text/blob cells for list display
  (`row.fullSizes` has the real sizes) — fetch the full value only for the selected row.
* Quote dynamic identifiers with `SQLiteDB.quote(name)`; bind all values as parameters.
* Schema probing: `tables()`, `tableExists`, `columns(of:)`, `columnNames(of:)`,
  `hasColumns`, `rowCount(of:)`, `schema()`. **`columnNames(of:)` returns lower-cased
  names** — `names.contains("ZORIGINATED")` is silently false. Use `columnSet(of:)`
  (`ColumnSet.contains` is case-insensitive) or `hasColumns`.
* Paging: prefer keyset paging (`WHERE rowid > ? ORDER BY rowid LIMIT ?`) for natural
  order — `PageRequest.cursor` carries the last row id; use `OFFSET` for sorted views.
  Large `OFFSET`s on unindexed sorts are slow but cancellable; that is acceptable, creating
  indexes is not.
* Aggregate in SQL (`GROUP BY`) rather than in Swift. Cocoa-epoch day bucket:
  `CAST((ZSTARTDATE + 978307200) / 86400 AS INTEGER)`; local hour:
  `strftime('%H', ZSTARTDATE + 978307200, 'unixepoch', 'localtime')`.
* The pool is reset by the toolbar's Refresh.

### 5.3 Biome SEGB streams

```swift
guard let stream = Biome.stream(named: "App.InFocus") else { … }          // or Biome.discoverAllStreams()
let reader = BiomeStreamReader(stream)
let stats = reader.stats()                                                 // records, deleted, bytes, timeRange (no payload decode)
reader.forEachMessage(device: nil, order: .newestFirst) { record, msg in   // synchronous — call from a detached task / actor
    let when = record.timestamp, device = record.device                    // .local or .remote(identifier)
    let bundle = msg[2]?.string
    return true                                                            // false stops
}
let peers = await Biome.devicePeers()                                      // identifier → BiomeDevicePeer (displayName, platformName)

let file = try SEGBFile(url: segment.url)                                  // one segment: entries (index), payload(entry), crcMatches
```

* Layout: `<root>/<Stream>/local/<segment>` and `<root>/<Stream>/remote/<device>/<segment>`;
  `tombstone/` subfolders are ignored for data. Roots: `Biome.streamRoots()`.
* Format (verified on real files, CRC-checked for every live record): **v2** = `SEGB` magic
  at offset 0, 32-byte header (`u32` entry count at +4, `f64` Cocoa creation time at +8),
  records from offset 32 aligned to 4 bytes (`u32 crc32 | u32 ? | payload`), 16-byte trailer
  entries growing backwards from EOF (`u32 endOffset relative to 32 | u32 state | f64 Cocoa
  timestamp`). State 1 = written, 3 = deleted (zero-filled), 4 = written (other). **v1**
  (legacy: magic at offset 52, 56-byte header, 32-byte record headers, 8-byte alignment) is
  implemented and covered by a synthetic test, but no v1 file exists on current macOS.
* Files are memory-mapped; an index of 40 bytes per record is built; payloads are copied
  one record at a time. Iteration is synchronous and CPU-bound: run it inside
  `AsyncContent`'s loader, a `PagedTable` fetch closure, or an actor — never on the main
  actor. For paged UI over a stream, keep an actor holding the `SEGBFile`s and an index of
  matching records (see `StreamRecordSource` in `RawModule/BiomeSection.swift`).
* "Newest first" is per segment/device, not a global merge across devices; sort by
  `record.timestamp` if you need a merged timeline.
* Device identifiers are personal data: show `BiomeDevicePeer.displayName`, not the UUID.
  `displayName` falls back to `platformName` (codes 2 = iOS device and 3 = Mac are
  verified, others are shown as "Platform n"); `model` is an OS build, not hardware.
* Segment files outside a standard stream directory: `Biome.loadStream(dir)` for a
  directory with `local/` / `remote/`, or build a `BiomeStream(name:url:segments:)` from
  `BiomeSegment(url:device:size:modified:)` values by hand.
* The reader was cross-checked against an independent Python parser (live / deleted
  counts and first / last timestamps per device, local and remote, plus a synthetic v1
  file): identical. `DOSSIER_RAW_VERIFY_STREAMS=A,B dossier-dev-raw --selftest` prints
  those figures.

### 5.4 Protobuf (schema-less)

```swift
guard let msg = ProtoMessage(payload) else { … }      // strict: nil unless the whole buffer parses
msg[1]?.string        msg[3]?.int        msg[4]?.double        msg[4]?.cocoaDate
msg[7]?.message?[1]?.string              msg.string(at: 7, 1)  msg.all(5).compactMap(\.string)
msg[2]?.uint  .sint (zigzag)  .bool  .float  .data  .packedVarints  .unixDate
msg.allStrings()                          // all string leaves (previews, search)
field.guess                               // .string / .message / .data heuristic for length-delimited fields
DataNode.from(msg)                        // tree for DataTreeView
```

Hot loops (aggregating 100k+ records, table cells) should not build a `ProtoMessage` per
record. `FastProto` walks the fields in place:

```swift
FastProto.scan(record.payload) { field, value in
    switch (field, value) {
    case (2, .fixed64(let bits)): time = FastProto.double(bits)
    case (6, .bytes(let b)): bundle = FastProto.string(b)        // b is only valid inside the closure
    default: break
    }
}
payload.withUnsafeBytes { FastProto.string($0, [5, 1, 2]) }      // first string at a nested path
ByteNeedle("text").matches(payload)                               // ASCII case-insensitive search in raw bytes
LZFSE.decode(data)                                                // `bvx…` streams (Cascade sets, Photos OCR archives)
```

Field numbers are discovered empirically (use Raw Explorer › Biome Stream Explorer or
`protoc --decode_raw`). Document the mapping you rely on in your module's source.

### 5.5 Plists and NSKeyedArchiver

```swift
let value: PlistValue? = PlistDecoder.decodeAny(data)   // bplist / XML plist; NSKeyedArchiver graphs are resolved
value?["key"]?.string    value?["list"]?[0]?.int    value?.value(at: "a", "b")?.date    value?.allStrings()
PlistDecoder.decodePlist(data)        // without archive resolution (UIDs stay .uid)
PlistDecoder.decodeJSON(data)
BlobSniffer.sniff(data)               // .binaryPlist .keyedArchive .xmlPlist .json .protobuf .text .image .sqlite .segb .gzip .binary
```

Archives are resolved without the original classes: collections, strings, data, dates,
URLs and UUIDs become plain values; any other object becomes a `.dict` with a `"$class"`
entry followed by its coded keys. Nested archives inside `Data` are left as data — decode
them on demand (the tree viewer expands small ones automatically).

### 5.6 Dates and formatting

```swift
DossierDate.cocoaOrUnix(seconds)   // columns that hold either epoch (Biome sync.db): > 1.2e9 ⇒ Unix
DossierDate.cocoa(seconds)  .unix(seconds)  .unixMillis(_)  .webKit(micros)  .guess(number)  .isPlausible(date)
DossierDate.table(date)      // "11 Nov, 16:29" (with year outside the current one), localized — table cells
DossierDate.sortable(date)   // "2026-11-11 10:55:12" — copy / CSV export and raw views (sorts lexicographically)
// PagedColumn.date("Time", id: "ZSTARTDATE") { $0.date }  — cell = .table, tooltip = .medium, export = .sortable
DossierDate.medium(date)  .short(date)  .day(date)  .iso(date)  .relative(date)  .range(closedRange)
Format.count(1234567)  .compact(1234567)  .bytes(n)  .duration(seconds)  .percent(0.42)  .number(1.5)
Format.oneLine(text, max: 240)  .tildePath(url)
```

---

## 6. Shared UI components

All in `DossierCore`. Use these instead of hand-rolled equivalents so the app looks like
one product.

### AsyncContent / LoadState / placeholders

```swift
AsyncContent(reloadKey: selectedID) {                 // runs detached, cancelled on key change / refresh
    try await store.loadDetail(selectedID)            // throw DossierError.inaccessible/.missing/.message for placeholders
} isEmpty: { $0.items.isEmpty } content: { detail in
    DetailView(detail)
}
AsyncContent(loadCollection: { try await store.items() }) { items in … }     // empty collection → empty placeholder

LoadingPlaceholder("Indexing…")
StatePlaceholder(title: "No Trips", symbol: "airplane", message: "…")
StatePlaceholder.inaccessible(reason)      StatePlaceholder.missing("Table X does not exist on this macOS version")
```

**State set before the content closure first runs is not seen.** If a deep link (or any
`.task`) sets a `@State` of your section while `AsyncContent` is still loading, the
closure later reads a stale value, because the section's `body` never read that state and
is not re-evaluated. Read such state at the top of `body`:

```swift
var body: some View {
    let _ = (selected, filter, mode)          // keeps body subscribed; see above
    AsyncContent { … } content: { data in content(data) }
}
```

Every section that takes deep links does this. State changed *after* the content is on
screen (row selection, pickers) works without it.

`LoadState<T>` (`.idle .loading .loaded .empty .inaccessible .missing .failed`) with
`LoadState.from(error:)` is available for hand-written loaders.

### PagedTable

```swift
struct Event: Identifiable, Sendable { let id: Int64; let date: Date; let bundle: String; let seconds: Double }

PagedTable(
    columns: [
        PagedColumn<Event>("Time", id: "ZSTARTDATE", width: 160, min: 150) { DossierDate.sortable($0.date) },
        PagedColumn("App", id: "ZVALUESTRING", width: 260, sensitivity: .personal) { $0.bundle },
        PagedColumn("Duration", id: "duration", width: 90, alignment: .trailing, sortable: false) { Format.duration($0.seconds) },
        PagedColumn("Row", id: "Z_PK", width: 70, secondary: true, hiddenByDefault: true) { String($0.id) },
    ],
    searchPrompt: "Filter apps",
    reloadKey: selectedStream,                 // restart from page 1 when this changes
    exportName: "app-usage",
    fetch: { req in try await store.events(offset: req.offset, limit: req.limit, sort: req.sort, search: req.search) },
    count: { req in try await store.eventCount(search: req.search) },
    onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
)
```

* `fetch` runs off the main actor; return fewer than `req.limit` rows to signal the end.
  `req.sort` is `PageSort(columnID:ascending:)` — make column ids your SQL column names and
  whitelist them before interpolating (`sort.sqlDirection` gives ASC/DESC).
  `req.cursor` is the last loaded row's id (keyset paging).
* Built in: infinite scroll, sortable headers, debounced filter field, column chooser,
  row-count footer, multi-select, ⌘C (TSV), context menu, CSV export, loading / empty /
  error / no-access overlays, Privacy Mode per column (`sensitivity:`).
* `.cell { row in … }` on a column supplies a custom cell view (the text closure is still
  used for copy/export).
* `PagedTable(rows:columns:reloadKey:…)` is the in-memory variant for small, already-loaded
  arrays. It filters on the column texts; it sorts by a column's `.sortKey { row in Double }`
  when given (durations, sizes, dates), otherwise numerically when every cell is a plain
  number (grouping separators and `%` are understood) and in natural string order if not.
  It also takes `accessory:`.
* `initialSort: PageSort(columnID:ascending:)` shows a sort indicator before the user
  clicks a header (and is passed to `fetch`). Pass the one that matches your query's default
  `ORDER BY` so the header shows which order the user is looking at.
* A failed further page keeps the loaded rows and shows "Couldn’t load more rows · Retry"
  in the footer; page fetches are cancelled on reload and when the table disappears.
* `selectedID: $rowID` (optional `Binding<Row.ID?>`) lets a section highlight a row from
  outside — deep links. Only rows that are already loaded can be highlighted.
* A trailing `accessory:` view builder puts extra controls into the filter bar. The bar
  sizes the accessory first (with what is left beside a 140-pt filter field), so pass
  something that adapts — `AdaptiveSegmentedPicker`, a two-alternative `ViewThatFits` —
  and it picks the form that fits. The field keeps 140…280 pt; when field and accessory do
  not fit on one line the accessory moves to a second row.
* Column widths: `width:` is the ideal. Without `min:` a column keeps its ideal width up
  to 110 pt and otherwise 60 % of it (between 110 and 160 pt), so a table that gets narrow
  (minimum window, inspector open) scrolls sideways instead of squeezing every column to a
  stub. Give `max:` to columns with fixed-length content (durations, counts) so they do not
  soak up the spare width of a wide window; `PagedColumn.date` caps itself at 1.5 x.
* The footer is one line at any width: it drops "N selected", then shortens the count to
  "200 / 6,465", and below about 300 pt shows the Columns / Export menus as icons.
* Changing the **set of columns** re-creates the table (it is identified by its column
  ids); swapping rows and columns in one update otherwise aborts inside SwiftUI.
* `filter: $text` (optional `Binding<String>`) exposes the filter field two-way, so a
  section can set it (deep links) or read it. `searchPrompt: nil` hides the field.
* Rows must be `Identifiable & Sendable` with **unique, stable ids** (row id / primary
  key; for SEGB records `BiomeStreamReader.Record.id`). Duplicate ids break selection.
* Loaded rows are kept (no eviction) — keep row structs small: display strings and ids,
  not blobs. Fetch the heavy payload for the selected row only.
* Tables go edge-to-edge (no padding), usually with `StoreFooter` below.

### Inspector

```swift
PagedTable(…)
    .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
        if let selected {
            InspectorPage(title: selected.title, subtitle: "App Usage", sensitivity: .personal, onClose: { self.selected = nil }) {
                KeyValueGrid([KeyValueItem("Bundle", selected.bundle, sensitivity: .personal, monospaced: true)])
                InspectorGroupTitle("Raw record")
                DataTreeView(selected.nodes).frame(height: 260)
            }
        }
    }
```

`detailInspector` adds a resizable trailing panel (default width `Metrics.inspectorWidth`).
When the section is too narrow for content + panel, the panel shrinks to 260 pt while the
content keeps `minimumContentWidth:` (default 400), then the content shrinks to its own
minimum, and finally the panel overlays the content's trailing edge (it never raises the
section's minimum width). For a master list beside the table use

```swift
AdaptiveMasterDetail(masterWidth: 280, compactMasterWidth: 230, inspectorOpen: selected != nil) {
    List(…)                                            // tucked away while list + table + inspector do not fit
} detail: {
    PagedTable(…).detailInspector(isPresented: …) { … }
}
```

`InspectorPage(scrolls: false)` is for content that scrolls itself (`BlobInspector`,
`DataTreeView`). Selection drives presentation: one selected row ⇒ inspector open.

### Strips, flow layout, app labels

```swift
HeaderStrip { Picker(…); Spacer(); Toggle(…) }     // THE 46-pt control strip at the top of a section
AdaptiveSegmentedPicker("Show", selection: $scope, reserve: 150) { … }   // segmented while it fits, pop-up otherwise
FittingStrip { Picker(…) } caption: { Text("Last 28 days") }             // caption dropped when the strip is narrow
PaneFooter("42 tables · 3 views")                  // caption strip under a master list
FlowLayout(spacing: 6, lineSpacing: 4) { ForEach(tags) { TagLabel($0) } }   // wrapping chips
AppLabel(bundle: "com.apple.mail")                 // icon + name; AppIcon(bundle:size:) for the icon alone
AppDirectory.name(bundle)                          // the one bundle-id → app-name resolver; .names(csv:), .isSystemSurface
BiomeDeviceNamer.load().label(record.device)       // "This Mac", peer name / platform, never the identifier
```

Do not re-implement these in a module: app and device names must read the same everywhere.

`HeaderStrip` is a plain one-line `HStack`: its minimum width is the sum of its controls'
minimums and has to fit the detail column of the minimum window. Segmented pickers and
`.fixedSize()` controls cannot shrink — use the two helpers above, and for more tiers nest
`ViewThatFits(in: .horizontal)` in pairs (§3a, layout rule 6). `FlowLayout` wraps at the
width it is given; asked for its ideal size it wraps at `idealWidth` (640).

### Stat tiles, headers, grids, badges

```swift
ScrollPage {                                              // dashboard-style section root
    StatTileRow([
        Stat("Apps Tracked", "142", caption: "last 30 days", symbol: "app.badge", tint: .blue),
        Stat("Top Contact", name, symbol: "person", sensitivity: .sensitive),
    ])
    SectionHeader("When You Use Your Mac", subtitle: "Events per weekday and hour", symbol: "clock")
    TimelineHeatmap(.weekdayByHour(dates)).card()
    SectionHeader("Top Apps") { Picker(…) }               // trailing accessory
    BarChartView(bars).card()
}
// StatTileRow stretches its tiles across the width when they fit on one line; otherwise
// it balances them over as few rows as possible (6 tiles → 3 + 3, never 5 + 1)
// (fillsWidth: false packs them to the leading edge). For your own card grids use the
// same layout instead of LazyVGrid(.adaptive), which leaves orphans on the last row:
//   BalancedGrid(minItemWidth: 250, spacing: 12) { ForEach(cards) { CardView($0) } }
// A Stat's caption is hidden together with its value in Privacy Mode.
// StatTileRow(stats, minTileWidth: 170, singleRowMinTileWidth: 150) keeps four tiles on one
// row while each still gets 150 pt instead of going 2 x 2 (the same option exists on
// BalancedGrid). StatTileRow(stats, style: .strip) is the one-line compact form; for the
// usual "paragraph + tiles above a table" block use
//   SectionIntro(text: "…", stats: stats, compact: compact)      // compact: strip + info button
// with `.compactWhenLow($compact)` on the view that fills the section (true below 740 pt).
// SectionHeader sizes its accessory first; title and subtitle wrap in what is left.
KeyValueGrid([KeyValueItem("First seen", DossierDate.medium(d)), KeyValueItem("E-mail", mail, sensitivity: .sensitive)])
SensitivityBadge(.sensitive)      TagLabel("remote", tint: .teal)
anyView.card()                    // padded rounded card
```

### Charts

```swift
BarChartView([ChartBar("Safari", 5400), ChartBar("Mail", 1800)], labelSensitivity: .personal, valueLabel: Format.duration)
BarChartView(bars, horizontal: false)
LineChartView(days.map { ChartPoint($0.day, Double($0.count)) }, style: .bars, unit: .day)          // .line / .area / .bars
LineChartView(points /* with series: */, style: .line)                                               // multi-series + legend
TimelineHeatmap(.weekdayByHour(dates), tint: .purple)                 // weekday × hour-of-day
TimelineHeatmap(.dayByHour(dates, days: 28))                          // last N days × hour
TimelineHeatmap(.weekdayByHour(bins: sqlBins))                        // from a SQL GROUP BY (weekday 1…7, hour, weight)
ChartPalette.color(i)
```

Use Swift Charts directly for anything more specific, but keep `ChartPalette` colours and
wrap charts in `.card()`. Charts size themselves (`BarChartView` by bar count, the others
`minHeight: 160`); add `.frame(height:)` to fix a height. Pass at most a few dozen bars
and a few thousand points — aggregate in SQL first.

### Maps

```swift
PointMapView(
    places.map { MapPoint(id: $0.key, latitude: $0.lat, longitude: $0.lon, title: $0.name, weight: Double($0.visits), radius: $0.radiusMetres) },
    maxMarkers: 150, tint: .red, valueLabel: { Format.compact(Int($0)) }
) { cluster in selectedPlaces = cluster.points }        // click: the cluster and all its member points
.frame(height: 360)                                      // always give it a height (or let it fill a pane)

let clusters = MapCluster.make(from: points, limit: 150) // for > ~50k points do this in your loader…
PointMapView(clusters: clusters)                         // …and pass the result
```

* Any number of points is fine: they are grid-clustered down to `maxMarkers` markers
  whose area and badge show the summed `weight`. Invalid coordinates ((0, 0), NaN, out
  of range) are dropped; an empty input shows a "No Locations" placeholder.
* `radius` (metres) draws a circle around an unclustered point (geofences, uncertainty).
* `sensitivity:` defaults to `.sensitive`: in Privacy Mode the map is replaced by a
  placeholder.
* `PointMapView.region(for:aspect:)` fits in Mercator space; the static snapshot passes
  its own aspect ratio so markers at high latitudes are not cropped.
* Interactive `Map` in the app, static `MKMapSnapshotter` image in `--snapshot` (see §3) —
  so maps show up in your PNGs. Do not hand-roll `Map` unless you accept blank snapshots.
* MapKit downloads map tiles for the visible region from Apple, as soon as a map appears.
  The region is fitted to the stored coordinates, so Apple's tile servers learn roughly
  which areas are on screen. That is the only network traffic in the app; no store content
  is sent. User-visible copy must say exactly that, never "nothing leaves this Mac".
  Privacy Mode replaces maps with a placeholder, so no tiles are requested then. Never geocode addresses or look up
  coordinates online — show what the store holds.

### Trees, hex, blobs

```swift
DataTreeView(DataNode.from(protoMessage))                              // protobuf
DataTreeView([DataNode.from(plistValue, key: "Root")], sensitivity: .sensitive)
HexView(data)
BlobInspector(data: blob, title: "ZVALUE")       // auto-detect: plist / NSKeyedArchiver / protobuf / JSON / text / image, + hex
```

### Store footer

```swift
StoreFooter(Paths.knowledgeC, note: "ZOBJECT")   // bottom of every section: path + Copy Path + Reveal in Finder
```

### Privacy Mode

`@Environment(\.privacyMode)` is the global toggle (toolbar eye button, ⇧⌘P). Mark values:

```swift
Text(contactName).sensitive(.sensitive)          // blurred + redacted while Privacy Mode is on
Text(appName).sensitive(.personal)               // also hidden; `.low` is never hidden
```

Shared components take a `sensitivity:` parameter (`PagedColumn`, `KeyValueItem`, `Stat`,
`Fact`, `SearchHit`, `DataTreeView`, `BlobInspector`, `BarChartView(labelSensitivity:)`,
`InspectorPage`, `PointMapView`). Defaults differ: `PagedColumn`, `KeyValueItem`, `Stat`
and `InspectorPage` default to `.low` (nothing hidden — you must opt in), `Fact` and
`SearchHit` to `.personal`, `PointMapView` to `.sensitive`. Blur / redaction does not
work on AppKit- or GPU-backed views (maps, images in `NSViewRepresentable`): replace
those with a placeholder when `privacyMode` is on. Everything that is about the owner or their contacts must be marked;
verify with `--snapshot … --privacy`.

### Refresh

`@Environment(\.refreshToken)` increments on ⌘R. `AsyncContent` and `PagedTable` reload on
their own. If you keep a cache (actor), invalidate it when the token changes — see
`RawCatalog.sync(token:)`.

---

## 7. UI conventions

* **Section root**: either a `ScrollPage { … }` dashboard (tiles → charts → lists) or a
  full-bleed `PagedTable` with optional header strip above and `StoreFooter` below. Master–
  detail sections use `HStack(spacing: 0) { list.frame(width: 230–300); Divider(); detail }`
  with a `FilterField("Filter…", text: $filter)` on top of the list (see
  `RawModule/SQLiteSection` for the complete pattern).
* **Naming**: a module's dashboard section is titled "Summary" (the window subtitle already
  names the module); "Overview" is reserved for the app's own first page. Do not reuse an
  SF Symbol that another section of the same sidebar group already uses.
* **Do not add window toolbars or `.navigationTitle`** in sections — the shell owns the
  title (section title + module subtitle), global search, Privacy Mode and Refresh. Put
  section-level controls (pickers, segmented modes) in a 46-pt header strip at the top of
  the section or in the `PagedTable` accessory.
* **Spacing** from `Metrics`: page padding 20, block spacing 22, card padding 14, corner
  radius 10, bars 26–34 pt. **Typography**: `.headline` block titles, `.callout` body and
  table cells, `.caption` secondary / footers, `.largeTitle` only on the Overview;
  monospaced only for identifiers, paths, hex, SQL; `.monospacedDigit()` for numbers.
* **Colour**: semantic colours only (`.primary/.secondary/.tertiary`, `Color(nsColor:)`,
  `.accentColor`, `ChartPalette`). Must look right in light and dark mode — snapshot both.
* **Materials**: `.bar` for header/footer strips, window background for pages, text
  background for tables/trees. No web views, no custom chrome.
* **Empty / error states**: always a `StatePlaceholder` with an icon, a short title-case
  title and one sentence; missing store ⇒ `.missing`, TCC denial ⇒ `.inaccessible`.
  Never show a blank pane or a raw error dump.
* **Numbers**: `Format.count` in tables, `Format.compact` in tiles/badges, right-aligned.
  **Dates**: `PagedColumn.date` (`DossierDate.table`) in tables, `.medium`/`.relative` in inspectors.
* **Identifiers** (UUIDs, row ids, `md:` references): secondary colour, hidden by default
  in tables, visible in the inspector. Prefer human names wherever the data provides them.
* **Keyboard**: tables and lists must be navigable with arrow keys; Return/double-click
  activates (`onActivate`), Esc closes the inspector (built into `InspectorPage`).
* **Explain provenance**: every view should make clear *which store* the data comes from
  (`StoreFooter`) and, for inferred data, that it is the system's inference, with its
  confidence/score if available.

---

## 8. Checklist for a module change

1. `swift build --product dossier-dev-<id> --scratch-path .build-<id>` — no warnings in
   the module's target.
2. `dossier-dev-<id> --selftest` — meaningful PASS lines (store availability, schema
   probes, row counts cross-checked against the `sqlite3` CLI opened with
   `file:…?mode=ro`), no FAIL.
3. `--summary` returns within a few seconds with stores + honest facts.
4. `--search` finds something sensible; hits open the right section with the right row.
5. Snapshot every section, light and dark, plus one with `--privacy` and one with
   `DOSSIER_SNAPSHOT_SELECT_ROW=0`; look at the PNGs; store them outside the repository.
6. `dossier-dev-<id> --uitest --out <dir outside the repo>` exits 0 (§3a); look at the PNGs
   of anything it flags, and the minimum-size, `-scrolled` and `-selected` ones in any
   case. Sections with tabs or modes declare `uiTestPayloads` so every tab is covered.
7. Grep your sources for personal data and absolute home paths.
8. Missing-store behaviour: temporarily point a path at a non-existent file and confirm
   the placeholder (do not commit that change).

---

## 9. Demo data

Screenshots in the README and anything else that is published must never show a real
person's stores. Dossier therefore has a **demo mode** that points the whole app at a
synthetic data set, and a generator that builds that data set.

**The rule: schema from the real stores, content always invented.** A generator may know a
store's file layout, table and column names, types, enum codes and protobuf field numbers —
learn them from the readers in `Sources/` or by looking at a real store read-only
(`sqlite3 "file:…?mode=ro"`, `.schema`, `typeof()`, `SELECT DISTINCT <enum column>`). It
may never contain a row, name, handle, address, coordinate, title, message, URL, topic
choice, app list, device name, SSID, count or date that came out of a real store. Generic
system vocabulary (ontology codes and labels, stream names, bundle ids of Apple apps) is
not personal data.

```sh
scripts/make-demo-data.py /tmp/dossier-demo            # [--seed N] [--only graph,biome] [--now 2026-01-31T09:00:00Z]
scripts/make-demo-data.py --check                      # unit checks of the helpers in scripts/demo/lib.py

export DOSSIER_DEMO_ROOT=/tmp/dossier-demo
$B/debug/Dossier --selftest                            # incl. the demo checks below
$B/debug/Dossier --summary                             # every store a module looks for, with its path
$B/debug/Dossier --snapshot overview /tmp/shots/overview.png --size 1400x1000 --scale 2
DOSSIER_SNAPSHOT_SECTION=graph.me $B/debug/Dossier --snapshot app /tmp/shots/window.png   # with the sidebar
$B/debug/dossier-dev-<id> --selftest                   # the dev executables honour the variable too
```

Choose a neutral directory for the root: a few views show raw paths, and the root's own
path would then appear in them. Run the script with `/usr/bin/python3` (3.9+); it needs
nothing but the standard library and never touches the network or a real store.

### 9.1 The demo-root contract (`DOSSIER_DEMO_ROOT`)

When the environment variable names a directory, for the whole process:

| | normal | demo mode |
| --- | --- | --- |
| `Paths.home` | the user's home directory | `<root>/Home` |
| `Paths.library`, every `Paths.*` store URL | `~/Library/…` | `<root>/Home/Library/…` |
| `Paths.system("/private/var/db/CoreDuet/People")` | that path | `<root>/private/var/db/CoreDuet/People` |
| `Paths.protectedStores()` | `/private/var/db/locationd`, …, the Darwin user directory | `<root>/private/var/…`, `<root>/private/var/folders/demo/0/…` |
| `Paths.photosLibrary` | first library in `~/Pictures` | first in `<root>/Home/Pictures` (no override, no remembered choice) |
| `Paths.daemonContainer(id)` | scan of `~/Library/Daemon Containers` | scan of `<root>/Home/Library/Daemon Containers` |
| `Paths.hasFullDiskAccess()` | probes protected files | `true` |
| `Paths.allows(url)` | `true` | `true` only below the root (and for the self-tests' own scratch files in the temporary directory, `dossier-selftest-*` / `dossier-shmtest-*`) |
| UI preferences (`AppState.preferences`, `@AppStorage`) | the app's user defaults | a separate domain, `dev.dossier.viewer.demo` |
| `Format.tildePath` / `Paths.displayPath` | `~/…` | `~/…` for `<root>/Home/…`, `/private/var/…` for `<root>/private/var/…` |
| `AppDirectory` (names, icons) | every installed app | only apps that ship with macOS (`/System/…`, Safari); others use the built-in name table and the placeholder icon |
| locale, time zone | this Mac's | `en_NZ`, `Pacific/Auckland` (`DOSSIER_DEMO_LOCALE`, `DOSSIER_DEMO_TZ`; empty = this Mac's) |

A store the generators have not written yet is simply missing: sections show their
"Not on This Mac" placeholders and `summary()` reports `.missing`.

Three layers keep a demo run away from the real stores (`DemoGuard`):

1. **Path resolution.** All store paths derive from `Paths.home` / `Paths.system`. **Modules
   never build a path with `NSHomeDirectory()`, `homeDirectoryForCurrentUser`,
   `"~"`, `getpwuid`, `/Users/…`, or `URL(fileURLWithPath: "/private/var/…")` /
   `"/System/…"`** — use `Paths`. Never follow an absolute path stored *inside* a store
   without `Paths.allows(path:)` (as `PhotosLibraryLocator` does for `SystemLibraryPath`).
2. **Reader guard.** `Paths.probe`, `FileProbe`, `SQLiteDB` and `SEGBFile` ask
   `Paths.allows` and treat a location outside the root as missing; symlinks are resolved
   first (`realpath`), so a link pointing out of the root does not get through. Every
   refusal is recorded and fails the self-test.
3. **Kernel sandbox.** `DemoGuard.activate()` (called by `DossierRunner` before anything
   else) applies a sandbox profile to the process that denies reading and writing the real
   store locations (`~/Library/Biome`, `IntelligencePlatform`, `Containers`,
   `Daemon Containers`, `Mail`, `Messages`, `Safari`, `~/Pictures`, `/private/var/db/CoreDuet`,
   … — `DemoGuard.realStoreRoots()`). Code that bypasses layers 1 and 2 —
   `Data(contentsOf:)` on a hand-built path — gets "Operation not permitted", not data.
   It uses `sandbox_init`, which is deprecated API. If it is unavailable or fails (it
   does inside another sandbox), the window, `--snapshot`, `--screenshot` and `--uitest`
   refuse to start and the self-test fails, because frameworks read some real locations
   on their own (the text system opens `~/Library/Spelling` when the search field is typed
   into) and only this layer stops that. `DOSSIER_DEMO_ALLOW_UNSANDBOXED=1` continues on
   layers 1 and 2 alone and turns the failure into a WARN.

A demo root that is, contains or lies inside one of the real store locations is refused at
start (`DemoGuard.rootCollision()`): the sandbox could not deny that location otherwise.
**A module that starts reading a new location must add its real root to
`DemoGuard.realStoreRoots()`**; the self-test fails until it does (below).

`--selftest` in demo mode adds, in the `core` block: the root is a directory; every known
store path resolves below it; the Full Disk Access check reports granted; the sandbox
denies a real location (observed, not assumed: it probes `~/Pictures`, which privacy
protection does not cover, so the denial can only be the sandbox's). And at the very end,
after every module's self-test and summary: no reader asked for a location outside the
root; the real counterpart of every location that was read lies on the sandbox's deny
list; no file this process has open lies in a real store. The second-layer audit only sees what goes
through Core's readers — direct `Data(contentsOf:)` / `FileManager` calls in a module are
covered by layers 1 and 3, not counted there.

**UI.** `DemoBadge()` (Core) renders a small "Demo data" capsule in demo mode and nothing
otherwise. The app shows it in the sidebar footer, `--snapshot` in its title strip, so a
screenshot always says what it is. The Overview's headline, introduction, window subtitle
and store states do not claim "this Mac" in demo mode. Section copy inside modules still
says "your Mac" / "you" in places; the badge is what makes the picture honest.

### 9.2 The persona (`scripts/demo/persona.py`)

One invented person shared by all generators: **Robin Sample**, Wellington, New Zealand,
product designer at the invented company **Kōwhai Labs**. Family, friends and colleagues
are invented; every e-mail address uses `example.com` / `example.org` / `example.net`;
phone numbers are in the range reserved for fiction (`+1 202 555 01xx`); places are public
landmarks, invented cafés and public streets in Wellington with approximate public
coordinates (private places carry no house number); devices are "Robin's MacBook Pro"
(this Mac), "Robin's iPhone", "Robin's Apple Watch", "Robin's iPad" with random
identifiers; apps are Apple apps and very widely used third-party apps; music is
public-domain classical works and invented artists.

```python
persona.owner                         # Person: .given .family .full_name .emails .phones .handle .contact_id .graph_id
persona.others                        # everyone else;  persona.family;  persona.people_with("colleague")
persona.person("partner")             # by key ("alex") or relationship
persona.weighted_person(rng)          # someone else, close contacts more often (Person.closeness)
persona.place("home")                 # Place: .name .kind .street .city .postal_code .country .latitude .longitude
                                      #        .address .label .visits_per_month .graph_id .jitter(rng, metres)
persona.places                        # home, work, cafés, landmarks, transit, gym, parents, three trips
persona.this_mac, persona.remote_devices, persona.device("iphone")
                                      # Device: .name .kind .platform (2 iPhone/iPad, 3 Mac, 4 Watch) .model
                                      #         .os_version .os_build .identifier .ids_identifier .is_me
persona.apps, persona.apps_on("iphone"), persona.app("com.apple.MobileSMS"), persona.weighted_app(rng, "mac")
persona.tracks, persona.podcasts, persona.topics, persona.web_domains, persona.networks
persona.company, persona.locale, persona.time_zone, persona.tz_offset_hours, persona.languages
```

Identifiers (contact ids, graph node ids, device identifiers) derive from the seed, names
never do. Use the persona's identifiers wherever two stores must agree (a device
identifier under `remote/` and in `sync.db`; a person's `graph_id` in the graph and in a
view). Add to the persona when several modules need the same new thing; keep
module-specific invention in the module's generator. Topic `qid`s are best effort — check
them against the table compiled into the app before relying on them.

### 9.3 Generator API

One file per module id, `scripts/demo/<moduleID>.py`, exposing exactly:

```python
def generate(root: pathlib.Path, persona: Persona, rng: random.Random, now: datetime.datetime) -> None:
```

* `root` — the demo root. Write only below it, through `lib.library(root, …)`,
  `lib.system(root, …)`, `lib.photos_library(root)`, `lib.daemon_container(root, …)`.
* `persona` — §9.2, the same object for every module.
* `rng` — a `random.Random` seeded from `--seed` **and the module id**: your output does
  not change when another module draws more numbers. Take every random choice and every
  identifier from it (`lib.uuid_string(rng)`); never `uuid.uuid4()`, `random.random()`,
  `os.urandom`.
* `now` — timezone-aware UTC. **All dates are relative to it** (`lib.Clock`), so the data
  always looks current; nothing is in the future unless the store holds future things
  (calendar events). Do not call `datetime.now()` yourself.

Rules: standard library only; no network; never read anything outside `root`; SQLite
files through `lib.sqlite_db` / `lib.create_db` (rollback journal, no `-wal` / `-shm`);
write no absolute path into a store unless the real store holds one (and then an invented
one such as `/Users/robin/…`); several modules may write into the same directory
(`Biome/streams/restricted`, `knowledgeC.db`) — the modules run in the order of
`demo.MODULE_IDS`, a shared *file* belongs to the first module that needs it and later
ones append (`sqlite3.connect` on the existing file, `lib.write_stream` adds segments).
`graph.py` is the worked example.

Work loop for one module:

```sh
scripts/make-demo-data.py $ROOT --only <id>          # or without --only for the full set
DOSSIER_DEMO_ROOT=$ROOT $B/debug/dossier-dev-<id> --selftest
DOSSIER_DEMO_ROOT=$ROOT $B/debug/dossier-dev-<id> --summary        # which stores are still "Not present"
DOSSIER_DEMO_ROOT=$ROOT $B/debug/dossier-dev-<id> --snapshot <section> $OUT/x.png   # look at the PNG
```

### 9.4 Helper reference (`scripts/demo/lib.py`)

```python
from demo import lib
from demo.lib import pb
```

**Paths**

```python
lib.home(root)                                   # <root>/Home
lib.library(root, "Biome/sync/sync.db")          # <root>/Home/Library/…
lib.system(root, "/private/var/db/CoreDuet/People/interactionC.db")
lib.darwin_user_dir(root)                        # <root>/private/var/folders/demo/0
lib.photos_library(root)                         # <root>/Home/Pictures/Photos Library.photoslibrary
lib.daemon_container(root, "com.apple.linkd", rng)   # creates the container + metadata plist, returns its Data dir
lib.ensure_dir(p); lib.ensure_parent(p); lib.write_bytes(p, data); lib.write_text(p, text)
```

**Dates**

```python
clock = lib.Clock(now, persona.tz_offset_hours)
clock.ago(days=3, hours=2)                        # datetime
clock.at(days_ago=1, hour=8, minute=30)           # 08:30 in the persona's time zone yesterday (never in the future)
clock.spread(rng, 200, days=90, hours=(7, 23), recent_bias=1.5)   # sorted datetimes in waking hours
clock.sessions(rng, days=30, per_day=(3, 9), seconds=(20, 1800))  # [(start, seconds)], non-overlapping
lib.cocoa(dt)        # seconds since 2001 (CoreData, Biome, NSDate)      lib.from_cocoa(seconds)
lib.unix(dt)  lib.unix_ms(dt)  lib.webkit_us(dt)  lib.iso(dt)
```

**Identifiers** — `lib.uuid_string(rng)` (upper case; `upper=False`), `lib.uuid_obj(rng)`,
`lib.hex_string(rng, 16)`.

**SQLite**

```python
lib.create_db(path, DDL, {"ZOBJECT": [(1, "/app/usage", 7.5e8), {"Z_PK": 2, "ZSTREAMNAME": "/app/intents"}]})

with lib.sqlite_db(path, DDL, user_version=34) as con:      # commit + close on exit
    lib.insert(con, "t", rows)                              # tuples (all columns) or dicts (named columns)
    lib.coredata_tables(con, {"Interaction": 1, "Contact": 2}, rng, max_pk={"Interaction": 40})
                                                            # Z_PRIMARYKEY / Z_METADATA / Z_MODELCACHE
```

Copy the DDL from the real store's `sqlite_master` (schema only). Virtual tables whose
module is not in the system SQLite (custom FTS tokenizers) cannot be created — leave them
out; the readers already fall back to the plain tables.

**Protobuf** — a message is a list of `(field, value)` pairs (repeat a number for repeated
fields) or a dict:

```python
payload = pb.message([
    (1, "com.apple.Safari"),          # str → length-delimited
    (2, lib.cocoa(when)),             # float → 64-bit double (Biome timestamps)
    (3, True), (4, 42),               # bool / int → varint
    (5, [(1, "nested"), (2, 7)]),     # list of pairs or dict → nested message
    (6, b"\x00\x01"),                 # bytes
    (7, None),                        # left out
    (8, pb.sint(-3)), (9, pb.fixed64(1)), (10, pb.fixed32(1)), (11, pb.float32(0.5)),
    (12, pb.packed([1, 2, 3])),       # also pb.packed_doubles / pb.packed_floats
])
```

**Biome SEGB** (version 2, the framing §5.3 describes; checked against the app's reader:
record counts, first / last timestamps and all CRCs agree)

```python
stream = lib.biome_stream_dir(root, "App.InFocus")                  # ~/Library/Biome/streams/restricted/App.InFocus
lib.write_stream(stream, [(when, payload), …])                      # → local/<segment>, split every 4000 records
lib.write_stream(stream, records, device=persona.device("iphone").identifier)   # → remote/<identifier>/<segment>
lib.SEGBRecord(when, payload, deleted=True)                         # a deleted record (state 3, zero-filled)
lib.write_segb(path, records)   lib.segb_bytes(records)             # one segment file, anywhere
lib.write_biome_sync_db(root, persona.devices, now, rng)            # ~/Library/Biome/sync/sync.db › DevicePeer
```

Segment files are named after their first record (microseconds since 2001) and padded to
4096-byte pages like the originals. Other stream roots work the same way: pass
`lib.library(root, "DuetExpertCenter/streams/<name>")` or a directory inside a daemon
container as the stream directory. `sync.db` is written by whoever runs first among the
modules that need device names (`write_biome_sync_db(..., extra_ddl=…)` adds tables).

**Plists and keyed archives**

```python
lib.write_plist(path, {"SystemLibraryPath": "…", "when": clock.ago(days=1)}, binary=True)
lib.plist_bytes(value, binary=True)
blob = lib.keyed_archive({                                           # NSKeyedArchiver, root object under $top.root
    "name": "Robin", "when": clock.ago(days=2), "tags": ["a", "b"],  # dict / list / set / datetime / uuid.UUID / bytes
    "link": lib.ArchiveURL("https://example.com/"),
    "member": lib.ArchiveObject("FAFamilyMember", {"_firstName": "Robin", "_age": 34}, classes=["FAFamilyMember", "NSObject"]),
}, mutable_collections=False, top_key="root")
```

**Compression.** Python has no LZFSE encoder. `lib.lzfse_stored(data)` writes a valid LZFSE
stream made of *uncompressed blocks* (`bvx-` + length + bytes, ended by `bvx$`), which
Apple's decoder — and so `LZFSE.decode` in Core — reads like any other (`--selftest`
checks this in the `core` block). Use it wherever a store holds LZFSE (`bvx…`) data; it
cannot represent an empty payload. Zip archives: `zipfile` (stored or deflated). zlib:
`zlib`.

### 9.5 Verification

* `scripts/make-demo-data.py --check` — helper unit checks: protobuf against the reference
  byte vectors of the encoding documentation, SEGB against a second reader, SQLite journal
  mode and leftovers, plists and archives through `plistlib`, the persona's own rules
  (reserved e-mail domains and phone range, unique identifiers, determinism per seed).
* `DOSSIER_DEMO_ROOT=… Dossier --selftest` — the app's own readers on the generated data:
  the `raw` block parses every segment and verifies every record's CRC-32
  (`DOSSIER_RAW_VERIFY_STREAMS=<name>` prints per-device counts and first / last timestamps
  to compare with what the generator wrote), plus the demo checks of §9.1.
* Look at every screenshot before it is published: it must show only persona data and the
  "Demo data" marker.

### 9.6 Limitations

* The sandbox list is a fixed list of real store locations, not "everything outside the
  root": the process still reads what any AppKit process reads (fonts, its own
  preferences, system frameworks). A Photos library outside `~/Pictures` is not on the
  list — it is unreachable in demo mode only because the locator ignores overrides.
* Maps still download Apple map tiles for the area shown (Wellington in the demo set).
* The persona's UTC offset is fixed (+13, New Zealand daylight time), so "waking hours"
  are an hour off during New Zealand winter.
* Deterministic apart from the clock: with the same `--seed` and `--now` two runs write
  the same content; SQLite file bytes can still differ between SQLite versions.

