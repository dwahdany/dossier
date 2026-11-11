"""Demo data for the Raw Explorer module (`raw`).

Raw Explorer has no stores of its own: its four sections (Stores, SQLite Explorer, Biome
Stream Explorer, Files & Plists) list whatever the *other* generators put under the known
store roots. This generator runs last and only completes the picture:

1. **`~/Library/Biome/databases`** — the "materialized Biome views" store that no curated
   module owns:
   * `IntelligencePlatform.Entity/IntelligencePlatform.Entity.sqlite3`: the flat entity
     view of the knowledge graph (`Person`, `Location`, `software`, `FlightReservations`,
     `SportsTeams`, `HolidayEvent` and their `…Changes` tables). People, places and apps
     are the persona's, with the same node ids as `graph.db` (app node ids are looked up
     in the demo root's own `graph.db` when the graph generator has written it).
   * `Siri.PostSiriEngagement.Indexes/…sqlite3`: three index views over a stream.
   * `Games.RecentlyPlayed/…sqlite3` — only when the Activity generator has not written it.
2. **Stray files** for Files & Plists, in the layouts those stores have on macOS: Trial
   namespace descriptors and factor packs (text, XML and binary plists, protobuf, JSON),
   DuetExpertCenter publisher bookmarks (NSKeyedArchiver), a Suggestions throttle state
   (opaque binary). A file that already exists is never replaced.
3. **Fallbacks, only when nobody else wrote them** (`--only raw`, or a generator that is
   still a stub): `Biome/sync/sync.db` through the shared helper, and — if there is not a
   single Biome stream in the root — a small set of streams (app focus, Screen Time, now
   playing, web usage, notifications, Wi-Fi, menu items) with this Mac and the persona's
   other devices, encoded with the field numbers of `Sources/BiomeModule/StreamRegistry.swift`.
   With the full generator set this part does nothing.

Finally the files written here get plausible modification times (minutes to months back)
instead of all sharing the second the script ran; other generators' files are not touched.

Format notes (schema from the real DDL, never rows): the entity view keys every row by the
graph node id (`subject`, `identifier = "md:<subject>"`), stores lists as JSON text and
times as Cocoa seconds; the FTS5 shadow tables of the real file use a private tokenizer and
are left out. Invented where the real value was not looked at: the `isA` class codes of
`SportsTeams` / `HolidayEvent`, `extractionSource`, the structure of factor packs and of the
bookmark archives' classes, every Trial namespace and factor name.
"""

from __future__ import annotations

import datetime
import json
import os
import pathlib
import random
import sqlite3
import struct

from . import lib
from .lib import pb
from .persona import Persona


def _js(value) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


# ----------------------------------------------------------------------------------------
# ~/Library/Biome/databases/IntelligencePlatform.Entity
# ----------------------------------------------------------------------------------------

ENTITY_DDL = """
CREATE TABLE "software" ("subject" INTEGER, "identifier" TEXT, "name" TEXT, "bundleIdentifier" TEXT, "applicationIdentifier" TEXT, "publishedBy" TEXT, PRIMARY KEY ("subject") ON CONFLICT REPLACE);
CREATE TABLE "SoftwareChanges" ("subject" ANY, "updatedTimestamp" DOUBLE, PRIMARY KEY ("subject") ON CONFLICT REPLACE);
CREATE TABLE "FlightReservations" ("subject" INTEGER, "identifier" TEXT, "title" TEXT, "description" TEXT, "flightNumber" TEXT, "carrierCode" TEXT, "departureAirportName" TEXT, "departureAirportCode" TEXT, "departureAirportLatitude" DOUBLE, "departureAirportLongitude" DOUBLE, "departureAirportAddress" TEXT, "departureTime" DOUBLE, "arrivalAirportName" TEXT, "arrivalAirportCode" TEXT, "arrivalAirportLatitude" DOUBLE, "arrivalAirportLongitude" DOUBLE, "arrivalAirportAddress" TEXT, "arrivalTime" DOUBLE, "passengerNames" TEXT, "extractionSource" TEXT, PRIMARY KEY ("subject") ON CONFLICT REPLACE);
CREATE TABLE "FlightReservationChanges" ("subject" ANY, "updatedTimestamp" DOUBLE, PRIMARY KEY ("subject") ON CONFLICT REPLACE);
CREATE TABLE "SportsTeams" ("subject" INTEGER, "identifier" TEXT, "isA" TEXT, "name" TEXT, "umcId" TEXT, "qid" TEXT, "leagueName" TEXT, "imageBytes" TEXT, PRIMARY KEY ("subject") ON CONFLICT REPLACE);
CREATE TABLE "HolidayEvent" ("subject" INTEGER, "identifier" TEXT, "isA" TEXT, "name" TEXT, "alternateIds" TEXT, "occurances" TEXT, PRIMARY KEY ("subject") ON CONFLICT REPLACE);
CREATE TABLE "Location" ("subject" INTEGER, "identifier" TEXT, "name" TEXT, "addressString" TEXT, "latitude" DOUBLE, "longitude" DOUBLE, "address" TEXT, PRIMARY KEY ("subject") ON CONFLICT REPLACE);
CREATE TABLE "LocationChanges" ("subject" ANY, "updatedTimestamp" DOUBLE, PRIMARY KEY ("subject") ON CONFLICT REPLACE);
CREATE TABLE "Person" ("subject" INTEGER, "identifier" TEXT, "fullName" TEXT, "firstNames" TEXT, "middleNames" TEXT, "familyNames" TEXT, "names" TEXT, "phoneticName" TEXT, "aliases" TEXT, "dateOfBirth" DOUBLE, "isCurrentUser" BOOLEAN, "previousFamilyName" TEXT, "visualIdentifier" TEXT, "contactIdentifier" TEXT, "employer" TEXT, "url" TEXT, "personRelationship" TEXT, "locations" TEXT, "emailAddresses" TEXT, "phoneNumbers" TEXT, PRIMARY KEY ("subject") ON CONFLICT REPLACE);
CREATE TABLE "PersonChanges" ("subject" ANY, "updatedTimestamp" DOUBLE, PRIMARY KEY ("subject") ON CONFLICT REPLACE);
CREATE INDEX "Software_identifierIdx" ON "software"("identifier");
CREATE INDEX "SoftwareChanges_updatedTimestampIndex" ON "SoftwareChanges"("updatedTimestamp", "subject");
CREATE INDEX "FlightReservations_identifierIdx" ON "FlightReservations"("identifier");
CREATE INDEX "FlightReservationChanges_updatedTimestampIndex" ON "FlightReservationChanges"("updatedTimestamp", "subject");
CREATE INDEX "locations_identifier_idx" ON "Location"("identifier");
CREATE INDEX "LocationChanges_updatedTimestampIndex" ON "LocationChanges"("updatedTimestamp", "subject");
CREATE INDEX "person_identifier_idx" ON "Person"("identifier");
CREATE INDEX "PersonChanges_updatedTimestampIndex" ON "PersonChanges"("updatedTimestamp", "subject");
"""

# Public sports teams (name, league). Which teams exist is public knowledge; the table is
# the system's catalogue, not a statement about the persona.
SPORTS_TEAMS = [
    ("Hurricanes", "Super Rugby Pacific"), ("Crusaders", "Super Rugby Pacific"), ("Blues", "Super Rugby Pacific"),
    ("Chiefs", "Super Rugby Pacific"), ("Highlanders", "Super Rugby Pacific"), ("Brumbies", "Super Rugby Pacific"),
    ("Wellington Phoenix", "A-League Men"), ("Auckland FC", "A-League Men"), ("Sydney FC", "A-League Men"),
    ("Melbourne Victory", "A-League Men"), ("New Zealand Breakers", "NBL"), ("New Zealand Warriors", "NRL"),
    ("Central Pulse", "ANZ Premiership"), ("Northern Mystics", "ANZ Premiership"),
]

# New Zealand public holidays: (slug, names by language, rule). Rule: (month, day) or
# (month, weekday 0 = Monday, n-th occurrence).
HOLIDAYS = [
    ("new_years_day", {"en": "New Year’s Day"}, (1, 1)),
    ("day_after_new_years_day", {"en": "Day after New Year’s Day"}, (1, 2)),
    ("waitangi_day", {"en": "Waitangi Day", "mi": "Te Rā o Waitangi"}, (2, 6)),
    ("anzac_day", {"en": "Anzac Day"}, (4, 25)),
    ("kings_birthday", {"en": "King’s Birthday"}, (6, 0, 1)),
    ("labour_day", {"en": "Labour Day"}, (10, 0, 4)),
    ("christmas_day", {"en": "Christmas Day", "mi": "Te Rā Kirihimete"}, (12, 25)),
    ("boxing_day", {"en": "Boxing Day"}, (12, 26)),
    ("wellington_anniversary", {"en": "Wellington Anniversary Day"}, (1, 0, 4)),
]

# Public airports (approximate public coordinates). The carrier is invented.
AIRPORTS = {
    "WLG": ("Wellington International Airport", -41.3272, 174.8053, "Stewart Duff Drive, Rongotai, Wellington 6022, New Zealand"),
    "AKL": ("Auckland Airport", -37.0082, 174.7850, "Ray Emery Drive, Māngere, Auckland 2022, New Zealand"),
    "ZQN": ("Queenstown Airport", -45.0211, 168.7392, "Sir Henry Wigley Drive, Frankton, Queenstown 9300, New Zealand"),
}
CARRIER = ("Tasman Skyways", "TY")


def _holiday_date(year: int, rule: tuple) -> datetime.date:
    if len(rule) == 2:
        return datetime.date(year, rule[0], rule[1])
    month, weekday, nth = rule
    first = datetime.date(year, month, 1)
    return first + datetime.timedelta(days=(weekday - first.weekday()) % 7 + 7 * (nth - 1))


def _graph_app_nodes(root: pathlib.Path) -> dict[str, int]:
    """Bundle id → node id from the demo root's own graph.db (written by the graph
    generator), so the entity view and the graph name the same nodes."""
    path = lib.library(root, "IntelligencePlatform/graph.db")
    if not path.exists():
        return {}
    try:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            return {obj: subject for subject, obj in
                    con.execute("SELECT subject, object FROM stable_graph WHERE predicate = 'nm_bundleID'")}
        finally:
            con.close()
    except sqlite3.Error:
        return {}


def _entity_view(root, persona: Persona, rng: random.Random, clock: lib.Clock) -> pathlib.Path:
    now = clock.now
    people, person_changes = [], []
    owner = persona.owner
    for p in persona.people:
        aliases = [p.given.lower(), p.family.lower(), p.full_name.lower()] + ([p.nickname.lower()] if p.nickname else [])
        born = None
        if p.birthday:
            born = lib.cocoa(datetime.datetime(*p.birthday, 12, tzinfo=datetime.timezone.utc))
        emails = [{"label": "_$!<Work>!$_" if e.endswith("example.org") else "_$!<Home>!$_", "emailAddress": e} for e in p.emails]
        phones = [{"label": "_$!<Mobile>!$_", "phoneNumber": n} for n in p.phones]
        locations = None
        if p is owner:
            locations = _js([f"md:{persona.place(k).graph_id}" for k in ("home", "work", "gym")])
        people.append({
            "subject": p.graph_id, "identifier": f"md:{p.graph_id}", "fullName": p.full_name,
            "firstNames": _js([p.given]), "familyNames": _js([p.family]), "aliases": _js(aliases),
            "dateOfBirth": born, "isCurrentUser": 1 if p is owner else 0,
            "contactIdentifier": _js([p.contact_id]),
            "employer": f"md:{persona.company_graph_id}" if p.organization == persona.company else None,
            "personRelationship": _js([p.relationship]) if p.relationship_label else None,
            "locations": locations,
            "emailAddresses": _js(emails) if emails else None,
            "phoneNumbers": _js(phones) if phones else None,
        })
        person_changes.append((p.graph_id, lib.cocoa(clock.ago(days=rng.uniform(0.1, 1 + 120 * (1 - p.closeness))))))

    locations, location_changes = [], []
    for place in persona.places:
        private = place.kind == "home"
        locations.append({
            "subject": place.graph_id, "identifier": f"md:{place.graph_id}",
            "name": None if private else place.name, "addressString": place.address,
            "latitude": round(place.latitude, 6), "longitude": round(place.longitude, 6),
            "address": _js({"postalCode": place.postal_code, "streetName": place.street, "city": place.city}),
        })
        location_changes.append((place.graph_id, lib.cocoa(clock.ago(days=rng.uniform(1, 200)))))

    graph_nodes = _graph_app_nodes(root)
    software, software_changes = [], []
    for app in persona.apps_on("mac"):
        node = graph_nodes.get(app.bundle_id) or rng.randrange(10 ** 17, 10 ** 18)
        software.append({"subject": node, "identifier": f"md:{node}", "name": app.name, "bundleIdentifier": app.bundle_id})
        software_changes.append((node, lib.cocoa(clock.ago(days=rng.uniform(0.2, 150)))))

    # Two trips harvested from confirmation mail: Auckland (past, both legs) and Queenstown
    # (upcoming). Booking references and seats are invented.
    partner = persona.person("partner")
    legs = [
        (-23, 7, 5, "WLG", "AKL", 65, 418, [owner], "K7QF2M", "14A"),
        (-20, 18, 40, "AKL", "WLG", 65, 447, [owner], "K7QF2M", "9C"),
        (16, 9, 30, "WLG", "ZQN", 85, 603, [owner, partner], "R3XW8D", "11D, 11E"),
        (20, 15, 55, "ZQN", "WLG", 80, 610, [owner, partner], "R3XW8D", "7A, 7B"),
    ]
    flights, flight_changes = [], []
    tz = datetime.timezone(datetime.timedelta(hours=persona.tz_offset_hours))
    for day, hour, minute, origin, destination, minutes, number, travellers, reference, seats in legs:
        local = (now.astimezone(tz) + datetime.timedelta(days=day)).replace(hour=hour, minute=minute, second=0, microsecond=0)
        depart = local.astimezone(datetime.timezone.utc)
        arrive = depart + datetime.timedelta(minutes=minutes)
        o, d = AIRPORTS[origin], AIRPORTS[destination]
        node = rng.randrange(10 ** 17, 10 ** 18)
        flights.append({
            "subject": node, "identifier": f"md:{node}",
            "title": f"{CARRIER[0]} {CARRIER[1]} {number} to {d[0].split(' ')[0]}",
            "description": f"Booking reference {reference} · Seat {seats} · Boarding closes {(local - datetime.timedelta(minutes=20)).strftime('%H:%M')}",
            "flightNumber": str(number), "carrierCode": CARRIER[1],
            "departureAirportName": o[0], "departureAirportCode": origin, "departureAirportLatitude": o[1],
            "departureAirportLongitude": o[2], "departureAirportAddress": o[3], "departureTime": lib.cocoa(depart),
            "arrivalAirportName": d[0], "arrivalAirportCode": destination, "arrivalAirportLatitude": d[1],
            "arrivalAirportLongitude": d[2], "arrivalAirportAddress": d[3], "arrivalTime": lib.cocoa(arrive),
            "passengerNames": _js([t.full_name for t in travellers]),
            "extractionSource": "com.apple.mail",
        })
        booked = min(depart - datetime.timedelta(days=rng.uniform(18, 30)), clock.ago(days=rng.uniform(2, 6)))
        flight_changes.append((node, lib.cocoa(booked)))

    teams = []
    for name, league in SPORTS_TEAMS:
        node = -rng.randrange(10 ** 18, 9 * 10 ** 18)
        teams.append({"subject": node, "identifier": f"md:{node}", "isA": "SB10", "name": name,
                      "umcId": "umc.cst." + "".join(rng.choice("0123456789abcdefghijklmnopqrstuvwxyz") for _ in range(25)),
                      "leagueName": league})

    holidays = []
    year = now.astimezone(tz).year
    for slug, names, rule in HOLIDAYS:
        node = -rng.randrange(10 ** 18, 9 * 10 ** 18)
        dates = [_holiday_date(y, rule).isoformat() for y in (year - 1, year, year + 1)]
        holidays.append({"subject": node, "identifier": f"md:{node}", "isA": "SB65", "name": _js(names),
                         "alternateIds": _js([f"holiday_NZ_{slug}", "ek:" + lib.hex_string(rng, 64)]),
                         "occurances": _js([{"NZ": dates}])})

    path = lib.library(root, "Biome/databases/IntelligencePlatform.Entity/IntelligencePlatform.Entity.sqlite3")
    return lib.create_db(path, ENTITY_DDL, {
        "Person": people, "PersonChanges": person_changes,
        "Location": locations, "LocationChanges": location_changes,
        "software": software, "SoftwareChanges": software_changes,
        "FlightReservations": flights, "FlightReservationChanges": flight_changes,
        "SportsTeams": teams, "HolidayEvent": holidays,
    })


# ----------------------------------------------------------------------------------------
# ~/Library/Biome/databases: index views and the recently-focused-apps view
# ----------------------------------------------------------------------------------------

def _index_view_ddl(table: str, columns: list[tuple[str, str]], index: str) -> str:
    cols = "".join(f'\t"{name}" {kind},\n' for name, kind in columns)
    keys = ",".join(name for name, _ in columns)
    return f"""
CREATE TABLE {table.lower()}_bookmark (pKey INTEGER PRIMARY KEY, serializedBookmark BLOB NOT NULL) STRICT;
CREATE TABLE "{table}"(
	"datestamp" REAL,
{cols}	"_bookmark.streamId" TEXT HIDDEN,
	"_bookmark.segmentName" TEXT HIDDEN,
	"_bookmark.iterationStartTime" REAL HIDDEN,
	"_bookmark.offset" INTEGER HIDDEN,
	"eventTimestamp" REAL
);
CREATE INDEX {index} ON {table}(datestamp,{keys});
"""


def _store_bookmark(stream: str, segment: str, offset: int, when: datetime.datetime) -> bytes:
    return lib.keyed_archive(lib.ArchiveObject("BMStoreBookmark", {
        "streamId": stream, "segmentName": segment, "iterationStartTime": lib.cocoa(when), "offset": offset,
    }))


def _siri_index_views(root, persona: Persona, rng: random.Random, clock: lib.Clock) -> pathlib.Path:
    """Index views over the post-Siri-engagement stream: one row per event, keyed by day
    and an opaque request / session / task identifier."""
    stream = "Siri.PostSiriEngagement"
    views = [
        ("SPDatestampLastRequestIdIndexView", [("lastRequestId", "TEXT")], "Datestamp_LastRequestId_Index"),
        ("SPDatestampClientSessionIdIndexView", [("clientSessionId", "TEXT")], "Datestamp_ClientSessionId_Index"),
        ("SPDatestampTaskIdIndexView", [("taskID", "TEXT")], "Datestamp_TaskId_Index"),
    ]
    events = clock.spread(rng, 420, days=120, hours=(7, 22), recent_bias=1.3)
    segment_start = events[0]
    tz = datetime.timezone(datetime.timedelta(hours=persona.tz_offset_hours))
    path = lib.library(root, f"Biome/databases/{stream}.Indexes/{stream}.Indexes.sqlite3")
    with lib.sqlite_db(path, "".join(_index_view_ddl(*v) for v in views)) as con:
        for table, _, _ in views:
            offset = 32
            session = lib.uuid_string(rng)
            previous = None
            for when in events:
                if previous is None or (when - previous).total_seconds() > 240:
                    session = lib.uuid_string(rng)          # a new Siri session after a pause
                previous = when
                if (when - segment_start).days >= 30:
                    segment_start = when
                day = when.astimezone(tz).replace(hour=0, minute=0, second=0, microsecond=0)
                key = session if "Session" in table else lib.uuid_string(rng)
                con.execute(f'INSERT INTO "{table}" VALUES (?, ?, ?, ?, ?, ?, ?)',
                            (lib.cocoa(day), key, stream, lib.segment_name(segment_start),
                             lib.cocoa(events[0]), offset, lib.cocoa(when)))
                offset += rng.randrange(96, 420) // 8 * 8
            con.execute(f"INSERT INTO {table.lower()}_bookmark VALUES (1, ?)",
                        (_store_bookmark(stream, lib.segment_name(segment_start), offset, events[-1]),))
            segment_start = events[0]
    return path


GAMES_DDL = """
CREATE TABLE appsrecentlyfocused_bookmark (pKey INTEGER PRIMARY KEY, serializedBookmark BLOB NOT NULL) STRICT;
CREATE TABLE appsrecentlyfocused_keyedAggregationMetadataTableName (
    "max(eventtimestamp)_max" REAL, "group_by_key_bundleid" TEXT
) STRICT;
CREATE TABLE appsrecentlyfocused_keyedFirstMatchingRecord (
    "displaytype" INTEGER, "bundleid" TEXT, "dyldplatform" INTEGER, "shortversionstring" TEXT, "launchtype" INTEGER, "exactversionstring" TEXT, "group_by_key_bundleid" TEXT, "eventtimestamp" REAL, "_eventbodydata" BLOB, "launchreason" TEXT, "starting" INTEGER, "isnativearchitecture" INTEGER, "_eventclassname" TEXT, "parentbundleid" TEXT, "type" INTEGER, "transitionreason" TEXT, "absolutetimestamp" REAL, "extensionhostid" TEXT, "duration" REAL
) STRICT;
CREATE TABLE AppsRecentlyFocused("bundleID" TEXT, "maxEventTimestamp" REAL) STRICT;
CREATE INDEX appsrecentlyfocused_index ON appsrecentlyfocused ( "bundleid", "maxeventtimestamp" );
CREATE UNIQUE INDEX appsrecentlyfocused_keyedAggregationMetadataTableName_index ON appsrecentlyfocused_keyedAggregationMetadataTableName ( "group_by_key_bundleid" );
CREATE UNIQUE INDEX appsrecentlyfocused_keyedFirstMatchingRecord_index ON appsrecentlyfocused_keyedFirstMatchingRecord ( "group_by_key_bundleid" );
"""


def _games_view(path: pathlib.Path, persona: Persona, rng: random.Random, clock: lib.Clock) -> pathlib.Path:
    """`AppsRecentlyFocused`: bundle id → latest focus time (Unix seconds)."""
    apps = sorted(persona.apps_on("mac"), key=lambda a: -a.weight)
    with lib.sqlite_db(path, GAMES_DDL) as con:
        for rank, app in enumerate(apps):
            last = clock.ago(minutes=rng.uniform(1, 30) * (1 + rank) ** 2 / app.weight)
            stamp = float(lib.unix(last))
            con.execute("INSERT INTO AppsRecentlyFocused VALUES (?, ?)", (app.bundle_id, stamp))
            con.execute("INSERT INTO appsrecentlyfocused_keyedAggregationMetadataTableName VALUES (?, ?)", (stamp, app.bundle_id))
            lib.insert(con, "appsrecentlyfocused_keyedFirstMatchingRecord", [{
                "bundleid": app.bundle_id, "group_by_key_bundleid": app.bundle_id, "eventtimestamp": stamp,
                "absolutetimestamp": lib.cocoa(last), "starting": 1, "type": 1, "launchtype": 0,
                "isnativearchitecture": 1, "_eventclassname": "BMAppInFocus",
                "launchreason": "com.apple.dock.launch" if rank % 3 else "com.apple.spotlight.launch",
            }])
        con.execute("INSERT INTO appsrecentlyfocused_bookmark VALUES (1, ?)",
                    (_store_bookmark("App.InFocus", lib.segment_name(clock.ago(days=9)), 4096 * rng.randrange(40, 400), clock.ago(minutes=2)),))
    return path


# ----------------------------------------------------------------------------------------
# Stray files: Trial, DuetExpertCenter bookmarks, Suggestions
# ----------------------------------------------------------------------------------------

# Invented experiment namespaces and invented factors (name → value). The namespace names
# are only used when the profile generator's triald.db is not there to name its own.
TRIAL_NAMESPACES = ["KEYBOARD_AUTOCORRECT_TUNING", "SPOTLIGHT_RANKING_WEIGHTS", "SUGGESTIONS_SMART_REPLY",
                    "PHOTOS_MEMORIES_CURATION", "APP_PREDICTION_BLENDING", "NOTIFICATION_DIGEST_RANKING"]
TRIAL_FACTORS = [
    # (words in the namespace name the factor set suits, factors)
    (("KEYBOARD", "DICTATION"), {"learningRate": 0.35, "maxCandidates": 6, "enableInlineCompletion": True}),
    (("SPOTLIGHT", "SEARCH"), {"recencyHalfLifeDays": 14, "engagementWeight": 0.6, "modelAsset": "ranker.mlmodelc"}),
    (("MAIL", "SUGGEST", "SIRI"), {"minConfidence": 0.72, "maxResults": 3, "languages": "en,mi"}),
    (("PHOTOS", "MEMORIES"), {"minItemsPerGroup": 12, "distanceThresholdKm": 120.0, "enabled": True}),
    (("PREDICTION", "WIDGET", "PROACTIVE"), {"slots": 8, "explorationRate": 0.05, "decayPerDay": 0.9}),
    (("NOTIFICATION", "DIGEST"), {"refreshTimes": "08:00,18:00", "urgencyThreshold": 0.8, "enabled": False}),
]


def _trial_factors(name: str, index: int) -> dict:
    for words, factors in TRIAL_FACTORS:
        if any(word in name for word in words):
            return factors
    return TRIAL_FACTORS[index % len(TRIAL_FACTORS)][1]


def _trial_namespaces(root) -> list[str]:
    """The experiment namespaces of the demo root's own triald.db (profile generator), so
    the Treatments folders match the experiments that database lists."""
    path = lib.library(root, "Trial/v7/Database/triald.db")
    if path.exists():
        try:
            con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
            try:
                names = [row[0] for row in con.execute("SELECT DISTINCT name FROM namespaces ORDER BY rowid LIMIT 8") if row[0]]
            finally:
                con.close()
            if names:
                return names
        except sqlite3.Error:
            pass
    return TRIAL_NAMESPACES

DUET_BOOKMARKS = [
    ("appLaunchPublisherBookmark", "App.InFocus"),
    ("notificationDigestPublisherBookmark", "Notification.Usage"),
    ("modeTransitionPublisherBookmark", "UserFocus.ComputedMode"),
    ("menuItemFeedbackPublisherBookmark", "App.MenuItem"),
    ("nowPlayingPublisherBookmark", "Media.NowPlaying"),
    ("webUsagePublisherBookmark", "App.WebUsage"),
]


def _put(path: pathlib.Path, data: bytes, written: list) -> None:
    """Writes a file unless another generator already did."""
    if path.exists():
        return
    lib.write_bytes(path, data)
    written.append(path)


def _trial_files(root, persona: Persona, rng: random.Random, clock: lib.Clock, written: list) -> None:
    trial = lib.library(root, "Trial")
    _put(trial / "schemaVersion.txt", b"7\n", written)
    descriptors = trial / "NamespaceDescriptors"
    _put(descriptors / "identifier", lib.uuid_string(rng).encode(), written)
    _put(descriptors / "ExternalParameters.plist", lib.plist_bytes({
        "deviceClass": "Mac", "osBuild": persona.this_mac.os_build, "osVersion": persona.this_mac.os_version,
        "regionCode": persona.region, "languageCode": persona.language, "internalBuild": False,
    }, binary=False), written)
    namespaces = [(name, _trial_factors(name, i)) for i, name in enumerate(_trial_namespaces(root))]
    for scope, chosen in (("system", namespaces[::2]), ("subject", namespaces[1::2])):
        _put(descriptors / f"{scope}.data", lib.plist_bytes({
            "version": 2, "updated": clock.ago(days=rng.uniform(1, 20)),
            "namespaces": [{"name": name, "compatibilityVersion": rng.randint(1, 4), "factors": sorted(factors)}
                           for name, factors in chosen],
        }), written)
    for name, factors in namespaces:
        pack_id = lib.hex_string(rng, 24)
        pack = trial / "Treatments" / name / "factorPacks" / pack_id
        # Factor pack: 1 = pack id, 2 = namespace, 3 = repeated factor {1 name, 2 value {1 bool | 2 string | 3 int | 4 double}}.
        levels = []
        for factor, value in factors.items():
            if isinstance(value, bool):
                level = [(1, value)]
            elif isinstance(value, str):
                level = [(2, value)]
            elif isinstance(value, int):
                level = [(3, value)]
            else:
                level = [(4, float(value))]
            levels.append((3, [(1, factor), (2, level)]))
        _put(pack / "factorPack.pb", pb.message([(1, pack_id), (2, name)] + levels), written)
        _put(pack / "assets" / "Manifest.json", (json.dumps({
            "namespace": name, "factorPackId": pack_id, "compatibilityVersion": rng.randint(1, 4),
            "deployment": rng.randint(1, 40), "downloaded": lib.iso(clock.ago(days=rng.uniform(2, 90))),
            "factors": factors,
        }, indent=2, ensure_ascii=False) + "\n").encode(), written)


def _duet_files(root, persona: Persona, rng: random.Random, clock: lib.Clock, written: list) -> None:
    duet = lib.library(root, "DuetExpertCenter")
    for name, stream in DUET_BOOKMARKS:
        archive = lib.keyed_archive(lib.ArchiveObject("ATXBookmark", {
            "urlPath": lib.ArchiveURL(f"file:///Users/robin/Library/DuetExpertCenter/Bookmarks/{name}"),
            "versionNumber": rng.randint(1, 3),
            "bookmark": lib.ArchiveObject("BMBookmarkNode", {"name": stream, "upstreams": []}),
            "metadata": None,
        }), mutable_collections=True)
        _put(duet / "Bookmarks" / name, archive, written)
    _put(duet / "ATXActionTimeEstimateAWDTrackerTimestamp", lib.keyed_archive(clock.at(1, 3, 12)), written)


def _suggestions_files(root, rng: random.Random, clock: lib.Clock, written: list) -> None:
    # Opaque fixed-size state: two timestamps (Cocoa seconds) and two counters.
    state = struct.pack("<ddQQ", lib.cocoa(clock.ago(hours=5)), lib.cocoa(clock.ago(days=1, hours=2)), rng.randint(3, 40), 0)
    _put(lib.library(root, "Suggestions/Harvesting/throttle-state"), state, written)


# ----------------------------------------------------------------------------------------
# Fallback Biome streams (only when the root has none)
# ----------------------------------------------------------------------------------------

MENU_ITEMS = ["File ▸ Save", "File ▸ Export…", "Edit ▸ Copy", "Edit ▸ Paste", "Edit ▸ Find ▸ Find…", "View ▸ Enter Full Screen",
              "File ▸ New Window", "Window ▸ Minimise", "File ▸ Print…", "Edit ▸ Undo", "View ▸ Show Sidebar", "File ▸ Duplicate"]


def _has_streams(root) -> bool:
    for kind in ("restricted", "public"):
        base = lib.library(root, f"Biome/streams/{kind}")
        if base.is_dir() and any((child / "local").is_dir() or (child / "remote").is_dir() for child in base.iterdir()):
            return True
    return False


def _fallback_streams(root, persona: Persona, rng: random.Random, clock: lib.Clock) -> None:
    mac = persona.this_mac
    platforms = [(None, "mac", mac, (14, 30), (20, 900), 60)]
    for key, per_day, seconds, days in (("iphone", (20, 44), (8, 420), 60), ("ipad", (3, 10), (30, 1200), 45)):
        device = persona.device(key)
        platforms.append((device.identifier, key, device, per_day, seconds, days))
    # Third-party apps keep one invented version / build for the whole history.
    versions = {a.bundle_id: (f"{rng.randint(3, 24)}.{rng.randint(0, 9)}", str(rng.randint(1000, 99999)))
                for a in persona.apps if not a.bundle_id.startswith("com.apple.")}

    focus_dir = lib.biome_stream_dir(root, "App.InFocus")
    screen_dir = lib.biome_stream_dir(root, "ScreenTime.AppUsage")
    for identifier, platform, device, per_day, lengths, days in platforms:
        focus, screen = [], []
        for start, seconds in clock.sessions(rng, days, per_day=per_day, seconds=lengths, hours=(7, 22)):
            app = persona.weighted_app(rng, platform)
            version, build = versions.get(app.bundle_id, (device.os_version, device.os_build))
            end = start + datetime.timedelta(seconds=seconds)
            for when, starting in ((start, True), (end, False)):
                focus.append((when, pb.message([
                    (1, "com.apple.dock.launch" if platform == "mac" else "com.apple.SpringBoard.transitionReason.homescreen"),
                    (2, 1), (3, starting), (4, pb.double(lib.cocoa(when))), (6, app.bundle_id),
                    (9, version), (10, build),
                ])))
                screen.append((when, pb.message([(1, starting), (2, pb.double(lib.unix(when))), (3, app.bundle_id)])))
        lib.write_stream(focus_dir, focus, device=identifier)
        lib.write_stream(screen_dir, screen, device=identifier)

    # Now playing: listening sessions on the phone and the Mac.
    playing_dir = lib.biome_stream_dir(root, "Media.NowPlaying")
    for identifier, bundle, route, count in ((None, "com.apple.Music", "MacBook Pro Speakers", 260),
                                             (persona.device("iphone").identifier, "com.apple.Music", "Robin’s AirPods Pro", 520)):
        records = []
        for start in clock.spread(rng, count // 4, days=70, hours=(7, 22)):
            when = start
            for _ in range(rng.randint(2, 6)):
                track = rng.choice(persona.tracks)
                for state, at in ((1, when), (2, when + datetime.timedelta(seconds=track.seconds))):
                    if at > clock.now:
                        continue
                    records.append((at, pb.message([
                        (2, pb.double(lib.cocoa(at))), (3, state), (4, track.album), (5, track.artist),
                        (6, pb.double(float(track.seconds))), (8, track.title), (10, "Music"),
                        (14, [(3, route)]), (15, bundle),
                    ])))
                when += datetime.timedelta(seconds=track.seconds + rng.randint(1, 20))
        lib.write_stream(playing_dir, records, device=identifier)

    # Web usage (Safari on the Mac).
    web = []
    for start, seconds in clock.sessions(rng, 60, per_day=(6, 22), seconds=(10, 900), hours=(8, 23)):
        domain, _title = rng.choice(persona.web_domains)
        view = lib.uuid_string(rng)
        for state, at in ((1, start), (2, start + datetime.timedelta(seconds=seconds))):
            web.append((at, pb.message([(1, view), (2, pb.double(lib.cocoa(at))), (3, state),
                                        (4, f"https://{domain}/"), (5, domain), (6, "com.apple.Safari")])))
    lib.write_stream(lib.biome_stream_dir(root, "App.WebUsage"), web)

    # Notifications on the phone and the Mac.
    usage_dir = lib.biome_stream_dir(root, "Notification.Usage")
    for identifier, platform, count in ((None, "mac", 900), (persona.device("iphone").identifier, "iphone", 2400)):
        noisy = [a for a in persona.apps_on(platform) if a.category in ("communication", "social", "productivity")]
        records = []
        for when in clock.spread(rng, count, days=45, hours=(7, 23), recent_bias=1.2):
            app = rng.choices(noisy, weights=[a.weight for a in noisy])[0]
            records.append((when, pb.message([(2, pb.double(lib.cocoa(when))), (3, rng.choice((1, 1, 1, 2, 4, 6))),
                                              (4, app.bundle_id), (5, lib.uuid_string(rng))])))
        lib.write_stream(usage_dir, records, device=identifier)

    # Wi-Fi joins: home in the morning and evening, work on weekdays, the café now and then.
    wifi = []
    by_place = {n.place: n.ssid for n in persona.networks if n.ssid != persona.device("iphone").name}
    tz = datetime.timezone(datetime.timedelta(hours=persona.tz_offset_hours))
    for day in range(90, -1, -1):
        weekday = (clock.now.astimezone(tz) - datetime.timedelta(days=day)).weekday()
        plan = [(7, "home")] + ([(9, "work"), (18, "home")] if weekday < 5 else [])
        if rng.random() < 0.25:
            plan.insert(1, (8 if weekday < 5 else 11, "cafe"))
        for hour, place in plan:
            if place not in by_place:
                continue
            joined = clock.at(day, hour, rng.randrange(60), rng.randrange(60))
            wifi.append((joined, pb.message([(1, by_place[place]), (2, True)])))
            left = joined + datetime.timedelta(minutes=rng.randint(35, 420))
            if left < clock.now:
                wifi.append((left, pb.message([(1, by_place[place]), (2, False)])))
    lib.write_stream(lib.biome_stream_dir(root, "Device.Wireless.WiFi"), wifi)

    # Menu items chosen on the Mac.
    menu_apps = [a for a in persona.apps_on("mac") if a.category in ("productivity", "developer", "browser", "utility")]
    menu = [(when, pb.message([(1, rng.choices(menu_apps, weights=[a.weight for a in menu_apps])[0].bundle_id),
                               (3, rng.choice(MENU_ITEMS))]))
            for when in clock.spread(rng, 700, days=60, hours=(8, 22))]
    lib.write_stream(lib.biome_stream_dir(root, "App.MenuItem"), menu)


# ----------------------------------------------------------------------------------------

def _age(paths: list, databases: list, rng: random.Random, clock: lib.Clock) -> None:
    """Modification times for the files written here: databases minutes to hours back,
    caches and descriptors days to months back."""
    for path in databases:
        stamp = lib.unix(clock.ago(minutes=rng.uniform(3, 600)))
        os.utime(path, (stamp, stamp))
    for path in paths:
        days = rng.choice((0.02, 0.3, 1, 2, 5, 9, 20, 45, 110)) * rng.uniform(0.6, 1.4)
        stamp = lib.unix(clock.ago(days=days))
        os.utime(path, (stamp, stamp))


def generate(root: pathlib.Path, persona: Persona, rng: random.Random, now: datetime.datetime) -> None:
    """Completes the demo root for the Raw Explorer (see the module docstring)."""
    clock = lib.Clock(now, persona.tz_offset_hours)
    databases: list[pathlib.Path] = []
    files: list[pathlib.Path] = []

    # 1. Materialized Biome views.
    databases.append(_entity_view(root, persona, rng, clock))
    databases.append(_siri_index_views(root, persona, rng, clock))
    games = lib.library(root, "Biome/databases/Games.RecentlyPlayed/Games.RecentlyPlayed.sqlite3")
    if not games.exists():
        databases.append(_games_view(games, persona, rng, clock))

    # 2. Stray files for Files & Plists.
    _trial_files(root, persona, rng, clock, files)
    _duet_files(root, persona, rng, clock, files)
    _suggestions_files(root, rng, clock, files)

    # 3. Fallbacks for what the other generators own.
    if not lib.library(root, "Biome/sync/sync.db").exists():
        lib.write_biome_sync_db(root, persona.devices, now, rng)
    if not _has_streams(root):
        _fallback_streams(root, persona, rng, clock)

    _age(files, databases, rng, clock)
