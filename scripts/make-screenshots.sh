#!/bin/bash
# Renders every picture the README uses into docs/images/, from generated demo data.
#
#   scripts/make-screenshots.sh [--only name[,name…]] [--keep] [--out DIR]
#
# Steps: builds the app (release), stages it as a throwaway Dossier.app in a temporary
# folder (so the permission screen has an app icon to show), writes the synthetic demo data
# set with scripts/make-demo-data.py, and takes each picture with `Dossier --screenshot`
# while DOSSIER_DEMO_ROOT points at that data set. Nothing appears on screen: the window is
# hosted off-screen and drawn in-process, at 1320x840 points and 2 pixels per point.
#
#   --only a,b     render only these pictures (names as in the table below, without .png)
#   --keep         keep the temporary folder (demo data, staged app) and print its path
#   --out DIR      write somewhere else than docs/images
#   -h, --help     show this help
#
# Environment:
#   DOSSIER_SCRATCH   SwiftPM scratch path for the build (default: .build)
#   DOSSIER_SEED      seed for the demo data (default: the generator's)
#   DOSSIER_NOW       fixed clock for the demo data, e.g. 2026-01-31T09:00:00Z (default: now)
#   DOSSIER_TMP       where the temporary folder is created (default: /tmp)
#
# The demo data never contains anything from this Mac, and in demo mode the app cannot read
# the real stores (see DEVELOPMENT.md, "Demo data"). The pictures with a map need the
# network: MapKit downloads Apple map tiles for the invented places (public landmarks in
# New Zealand). Without a connection those maps come out blank.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

die() { echo "error: $*" >&2; exit 1; }

only=""; keep=0; OUT="$ROOT/docs/images"
while [ $# -gt 0 ]; do
    case "$1" in
        --only) [ $# -ge 2 ] || die "--only needs a list"; only=",$2,"; shift ;;
        --keep) keep=1 ;;
        --out)  [ $# -ge 2 ] || die "--out needs a directory"; OUT="$2"; shift ;;
        -h|--help) sed -n '2,/^set -e/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

SCRATCH="${DOSSIER_SCRATCH:-$ROOT/.build}"
SIZE="1320x840"

echo "==> swift build -c release"
swift build -c release --product Dossier --scratch-path "$SCRATCH"
BINARY="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/Dossier"
[ -x "$BINARY" ] || die "$BINARY not found"

WORK="$(cd "$(mktemp -d "${DOSSIER_TMP:-/tmp}/dossier-shots.XXXXXX")" && pwd -P)"   # resolved: deep links carry real paths
cleanup() { if [ "$keep" -eq 1 ]; then echo "kept $WORK"; else rm -rf "$WORK"; fi; }
trap cleanup EXIT

echo "==> drawing the app icon"
ICONSET="$WORK/AppIcon.iconset"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET" >/dev/null
mkdir -p "$OUT"
cp "$ICONSET/icon_256x256@2x.png" "$OUT/icon.png"

# A minimal bundle around the binary: the permission screen offers its drag-the-icon flow
# only when the process runs from an .app, and takes the icon from the bundle.
APP="$WORK/Dossier.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Dossier"
iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Dossier</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>dev.dossier.viewer.screenshots</string>
    <key>CFBundleName</key><string>Dossier</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
DOSSIER="$APP/Contents/MacOS/Dossier"

echo "==> generating demo data"
DEMO="$WORK/demo"
args=("$DEMO")
[ -z "${DOSSIER_SEED:-}" ] || args+=(--seed "$DOSSIER_SEED")
[ -z "${DOSSIER_NOW:-}" ] || args+=(--now "$DOSSIER_NOW")
/usr/bin/python3 "$ROOT/scripts/make-demo-data.py" "${args[@]}" >/dev/null
export DOSSIER_DEMO_ROOT="$DEMO"

# The data set must be sound before it is photographed, and the demo sandbox must be on:
# the self-test fails without it, and the app then refuses to draw anything.
"$DOSSIER" --selftest > "$WORK/selftest.txt" 2>&1 || { grep -n "FAIL" "$WORK/selftest.txt" >&2 || true; die "self-test failed on the demo data"; }

# Row ids differ per seed: take the deep-link payloads from the app's own search.
hit() { # <query> <module> <section>  → payload of the first hit in that section
    "$DOSSIER" --search "$1" "$2" 2>/dev/null | sed -n "s/.*\[$3 | \(.*\)\]\$/\1/p" | head -1
}
PARTNER_NODE="$(hit "Alex Marlowe" graph graph.entities | sed 's/^entity://')"
[ -n "$PARTNER_NODE" ] || die "the demo data has no graph node for the persona's partner"
ENTITY_DB="$DEMO/Home/Library/Biome/databases/IntelligencePlatform.Entity/IntelligencePlatform.Entity.sqlite3"
TAB="$(printf '\t')"

shot() { # <name> <target> [options…]      SHOT_SIZE=WxH overrides the window size for one picture
    local name="$1" target="$2"; shift 2
    if [ -n "$only" ] && [ "${only#*,"$name",}" = "$only" ]; then return 0; fi
    echo "==> $name.png"
    "$DOSSIER" --screenshot "$target" "$OUT/$name.png" --size "${SHOT_SIZE:-$SIZE}" --scale 2 "$@" >/dev/null \
        2> >(grep -v "sandbox_extension_issue_file_to_process" >&2)   # noise from the demo sandbox when run from a bundle
}

#    file name            section                 state
shot overview-light       overview
shot overview-dark        overview                --dark
shot graph-me             graph.me
shot graph-people         graph.people            --payload "person:$PARTNER_NODE"
shot interest-profile     profile.summary
shot communications       comms.retained
shot mail-index           mailsearch.cascade      --select-row 0
SHOT_SIZE=1320x700 \
shot activity-timeline    activity.timeline
shot places-map           environment.places      --linger 4
shot photos-graph         photos.graph
shot unified-timeline     biome.timeline
shot sqlite-explorer      raw.sqlite              --payload "$ENTITY_DB${TAB}FlightReservations" --select-row 0 --linger 2
shot search               overview                --query "Alex"
DOSSIER_SNAPSHOT_NO_FDA=1 \
shot full-disk-access     overview

echo "==> done: $OUT"
echo "    Look at every picture before committing it: each must show only the invented"
echo "    persona and the \"Demo data\" marker in the sidebar footer."
