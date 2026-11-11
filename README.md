# Dossier

A native macOS viewer that shows the owner of a Mac what the system's on-device
knowledge and personalization stores hold about them: the personal knowledge graph,
the interest profile, who you talk to, what copies of your mail exist in search
indexes, app and media activity, places and devices, what Photos inferred, and the raw
event streams underneath.

Dossier is SwiftUI throughout (sidebar, tables, Swift Charts, MapKit, inspectors, light
and dark mode, no web views), has no third-party dependencies, and opens every store
strictly read-only.

## What each sidebar area shows

| Area | Sections | Backed by |
|---|---|---|
| **Overview** | Totals, one card per area, headline facts ranked most private first | every module's summary |
| **Knowledge Graph** | Me, Entities, People & Relationships, Graph View, Events, Derived Views & Inferences, Ontology | `~/Library/IntelligencePlatform` (`graph.db`, `ontology.db`, `Artifacts/…` entity tagging, relevance, features, inferred triples, views) |
| **Interest Profile** | Summary, Topics, Named Entities, Places, Found in Mail, Contacts Intelligence, Vocabulary & Identifiers | `~/Library/PersonalizationPortrait`, `~/Library/Suggestions`, `~/Library/Assistant` (speech vocabulary), keyboard language modeling, Family Sharing cache, `~/Library/Trial` |
| **Communications** | Summary, People, Conversations, Messages Timeline, Calls, Other Siri Memories, Mail & Meeting Contacts, Retained Content, Recents, VIPs & Favourites | Siri Remembers `view.db` (IntelligencePlatform artifacts), knowledgeC `/app/intents`, `/private/var/db/CoreDuet/People/interactionC.db`, CallHistoryDB, CoreRecents, iCloud key-value cache |
| **Mail & Search Index** | Summary, Cascade Entities, Semantic Index, Spotlight Knowledge, Harvesting Pipeline, iCloud Key-Value Cache | `~/Library/Biome/sets` (Cascade sets: mail entities, body text, attachments, reminders, contacts, …), the hybridsearchd daemon container (Kuzu index), `~/Library/Metadata/CoreSpotlight/SpotlightKnowledge`, ProactiveHarvesting / TextUnderstanding Biome streams, the kvs daemon container |
| **Activity** | Summary, App Usage, Timeline, Media History, Web Usage, Predictions & Routine | Biome `App.InFocus`, `ScreenTime.AppUsage`, `Media.NowPlaying`, `App.WebUsage`, `Safari.*`; knowledgeC; `~/Library/DuetExpertCenter` |
| **Devices & Places** | Places Map, Networks & Radios, My Devices, Actions Log, Focus Modes, Notifications & Signals | Biome device, notification, screenshot, intent and discoverability streams; `~/Library/Biome/sync/sync.db`; DuetExpertCenter Focus caches; kvs (Wi-Fi networks, locations); milod; linkd |
| **Photos Intelligence** | Summary, People & Faces, Graph Inferences, Places & Trips, Search Index, Captions & OCR, Memories & Sharing | `Photos Library.photoslibrary`: `database/Photos.sqlite`, `database/search/psi.sqlite`, `private/com.apple.photoanalysisd/…/photosgraph*.kgdb`, `private/com.apple.mediaanalysisd/…/MediaAnalysis.sqlite`. Only the library's databases are read; photo and video files are never opened or decoded. |
| **Streams & System Log** | Stream Catalogue, Stream Records, Unified Timeline, knowledgeC, AI Telemetry, Device Sync | `~/Library/Biome/streams` (local and synced-device segments), `~/Library/Biome/sync`, DuetExpertCenter streams, the linkd App Intents transcripts, `~/Library/Application Support/Knowledge/knowledgeC.db` |
| **Raw Explorer** | Stores, SQLite Explorer (browse, schema, read-only SQL console), Biome Stream Explorer, Files & Plists | every known store, without interpretation |

Toolbar search queries all areas at once; a hit opens the matching section and row.
**Privacy Mode** (⇧⌘P) blurs personal and sensitive values and replaces maps with a
placeholder so the window can be shared on screen.

## Requirements

- macOS 15 or later (deployment target). Developed and tested only on macOS 27.2,
  Apple silicon.
- Swift 6 toolchain (Xcode 16 or later; built here with Swift 6.4 / Xcode 27.2). The
  package is built with SwiftPM, there is no `.xcodeproj`.
- Full Disk Access for the process that runs it (see below).

## Install

Download `Dossier-<version>.dmg` from the repository's Releases page, open it and drag
Dossier to Applications. Release builds are universal (Apple silicon and Intel), signed
with a Developer ID and notarized by Apple.

## Build and run

```sh
swift build -c release                 # everything
swift run -c release Dossier           # start the app from a terminal

scripts/make-app.sh                    # build/Dossier.app, ad-hoc signed, with icon
```

`scripts/make-app.sh` needs no signing identity, no keychain, no sudo and no network.

For a distributable build set `CODESIGN_IDENTITY` to a "Developer ID Application: …"
identity and create a notarytool keychain profile (`NOTARY_PROFILE`, default
`dossier-notary`):

```sh
scripts/make-app.sh --notarize --dmg   # universal, hardened runtime, notarized, stapled dmg
scripts/release.sh                     # the same, then tag v<VERSION> and draft a GitHub release
```

### Full Disk Access

Almost all of these stores are protected by macOS. Without Full Disk Access Dossier
shows a permission screen and, if you continue, marks the stores as inaccessible.

- **Running `Dossier.app`:** choose "Open Privacy & Security…" on the permission screen.
  A small panel with the Dossier icon follows the System Settings window; drag the icon
  into the Full Disk Access list and switch it on. Dossier notices the grant by itself.
  A locally built bundle is signed ad hoc, so its identity changes with every rebuild
  and the permission has to be granted again after rebuilding; release builds keep it.
- **Running from a terminal** (`swift run`, or the binary directly): the terminal
  application is the one that needs Full Disk Access; the binary inherits it.

Dossier never asks for administrator rights and never tries to change permissions
itself.

## Privacy guarantees

- **Read-only.** SQLite databases are opened with `SQLITE_OPEN_READONLY` through the URI
  `file:<path>?mode=ro&readonly_shm=1`, with `PRAGMA query_only=ON` and an authorizer
  that rejects everything but reads, including in the SQL console. No index is created,
  nothing is vacuumed or checkpointed, and no `-shm` file is created or written. If a
  database cannot be opened that way, Dossier falls back to an immutable snapshot of
  the main file and labels the result as possibly stale. Stream and set files are
  memory-mapped read-only.
- **Network.** The only network use is MapKit downloading Apple map tiles for the area
  a map shows, which tells Apple's tile servers roughly which region is being viewed.
  Privacy Mode replaces maps with a placeholder. Dossier itself sends no store
  content anywhere; there is no telemetry, no update check and no web view. Topic names come from tables
  on the Mac and a list compiled into the app, not from lookups. The Interest Profile's topic
  pages offer an optional "Look up on Wikidata" link: clicking it opens your browser
  on wikidata.org with that one topic id. Nothing is looked up unless you click.
- **Persistence.** Dossier keeps no copy, cache or index of your data on disk; derived
  indexes (mail index, semantic-index scan) live in memory for the run. What it does
  write: a handful of preferences in its own user defaults (last section and whether to
  restore it, Privacy Mode and whether to start in it, collapsed sidebar groups, a table
  display option, a manually chosen Photos library path), files you
  explicitly export or copy (CSV export, Copy), PNGs when you use `--snapshot`, PNGs
  and a `report.json` when you use `--uitest` (written to `--out <dir>`, by default a
  `dossier-uitest` folder in the temporary directory, and not removed afterwards), and
  scratch test databases in the temporary directory during `--selftest`, which are
  removed afterwards. MapKit may keep its own system-managed cache of downloaded map
  tiles.
- **No prompts.** No sudo, no AppleScript, no keychain access. One known gap: without
  Full Disk Access, macOS itself may ask whether Dossier may access data from other
  apps when a section reads inside another app's container; the app warns about this
  before continuing without access.

## Command-line flags

The same binary (`.build/release/Dossier` or `Dossier.app/Contents/MacOS/Dossier`)
has a headless mode. With no arguments it starts the app.

```
--list                         modules and section ids
--selftest [moduleID]          read every store, print PASS/WARN/FAIL per check and a
                               timing table; exit status 1 on any failure
--summary [moduleID]           stores (path, size, rows, time range) and headline facts
--search <query> [moduleID]    what toolbar search would return
--snapshot <sectionID|moduleID|overview|app> <out.png>
          [--dark] [--size WxH] [--scale 1|2] [--wait seconds]
          [--privacy] [--payload <deep link>]
                               render one section offscreen to a PNG; no window opens
--uitest [sectionID|moduleID|all] [--out <dir>] [--sizes WxH,WxH]
                               host the real app shell in an off-screen window, check
                               layout at several sizes, click, scroll, type and resize;
                               writes PNGs and report.json; exit status 1 on any failure
```

`--summary`, `--search`, `--snapshot` and `--uitest` output contains personal data. Keep it out of
any repository (`*.png` and `*.csv` are git-ignored as a safety net).

Each area also builds as its own small executable, `dossier-dev-<moduleID>`, that takes
the same flags and compiles only that module.

## Limitations

- **Tested on one machine and one OS version** (macOS 27.2). Schemas differ between
  macOS versions; Dossier probes tables and columns and degrades to "missing" or
  "inaccessible" states, but layouts on other versions are untested.
- **Reverse-engineered formats.** None of these stores is documented. Biome SEGB
  framing, the protobuf payloads (decoded without schemas; typed column names exist for
  about 50 streams and are inferred from the data), CoreData enum codes, Photos face
  and memory codes, NSKeyedArchiver payloads and the Cascade set encoding are decoded
  heuristically. Labels can be wrong; the Raw Explorer shows the undecoded values.
- **Stores that stay opaque or out of reach.**
  - The hybridsearchd semantic index is a Kuzu database. It cannot be queried; Dossier
    only scans the file for JSON payloads that sit whole inside a page, on demand.
  - The classic Spotlight app-content index is listed by size but not decoded.
  - Embedding vectors are counted, not interpreted.
  - Anything macOS denies even with Full Disk Access is shown as inaccessible.
  - Stores that exist only on other devices are visible only as far as they sync to
    this Mac.
- **Derived figures are estimates.** De-duplicating Now Playing events mirrored between
  devices, counting distinct notifications across two logs, naming devices that are
  missing from the sync database, and "seen with" context for topics are heuristics.
- **Live stores.** The system writes to these stores while Dossier reads them, so two
  views can differ by a few rows; Refresh (⌘R) re-reads.
- **Very wide tables** in the SQLite Explorer show 24 columns by default; showing all
  columns of a 100+ column table is slow.
- Filtering large non-mail Cascade sets decodes every item (with progress), and the
  first address filter in Photos decodes all reverse-geocode archives once.

## Architecture

`ARCHITECTURE.md` describes the module protocol, the shared data layer (`SQLiteDB`,
SEGB reader, schema-less protobuf, plist decoding), the shared UI components, the
snapshot harness and the rules every module follows.

```
Sources/DossierCore        data access, shared UI, CLI runner
Sources/DossierApp         app shell: sidebar, Overview, search, settings
Sources/<Name>Module       one feature area each (Graph, Profile, Comms, MailSearch,
                           Activity, Environment, Photos, Biome, Raw)
Sources/Dev/<id>           per-module dev executables
scripts/make-app.sh        builds and signs build/Dossier.app
```
