"""Demo data for the Devices & Places module (`environment`).

Everything below describes the invented persona of `persona.py` (Robin Sample, Wellington).
One simulated routine drives all stores, so they agree with each other: on a weekday the
Mac leaves home, joins the office network, a Work Focus switches on at the office geofence,
the microlocation daemon fingerprints the same access points, and so on.

Stores written (paths as the app sees them):

* `~/Library/Biome/streams/restricted/<stream>` — the 18 streams of
  `EnvironmentModule.streams` (local, some also `remote/<iPhone | iPad | Watch>`), plus the
  six empty location streams the Places section lists;
* linkd container `Data/ActionTranscript/<bundle id>/local` and `…/System/local`
  (NSKeyedArchiver `LNTranscriptActionRecord` graphs in SEGB segments);
* milod container `Data/com.apple.milod/milo.db` (Wi-Fi fingerprints);
* intelligentroutingd container `Data/com.apple.intelligentroutingd/intelligentRouting.sqlite`;
* `~/Library/DuetExpertCenter/DNDModeConfigurationsCache` and
  `~/Library/DoNotDisturb/DB/Assertions.json` (Focus);
* SHARED, created when missing and appended to otherwise, never replaced:
  - `~/Library/Application Support/Knowledge/knowledgeC.db` — rows in `ZOBJECT`,
    `ZSOURCE`, `ZSTRUCTUREDMETADATA`, `ZSYNCPEER` for `/bluetooth/isConnected`,
    `/notification/usage`, `/app/intents` (Maps, Find My) and `/app/locationActivity`;
  - `~/Library/Biome/sync/sync.db` — `DevicePeer` (only when the file is missing),
    `SyncSessionLog`, `AtomMergedLog`, `CRDTLocation`, `Metadata`;
  - kvs container `Data/com.apple.kvs/com.apple.KeyValueService-Production.sqlite` and
    `…EndToEndEncrypted-Production.sqlite` — the store identifiers
    `com.apple.wifi.syncable-networks`, `com.apple.PrintKit.PrinterTool`,
    `com.apple.eventkit.locations`, `com.apple.passbook.locations`.

Formats come from the readers in `Sources/EnvironmentModule` and from the schema (table and
column names, archive class and key names, protobuf field numbers) of the real stores.
Every value is invented. Vocabulary that could not be taken from a schema is a guess and is
marked "guess" where it is defined.
"""

from __future__ import annotations

import datetime
import json
import pathlib
import random
import re
import sqlite3
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Any, Iterator, Optional

from . import lib
from .lib import pb
from .persona import Persona

UTC = datetime.timezone.utc
A = lib.ArchiveObject

#: Days of history the routine covers.
DAYS = 120
#: The Queenstown trip: first and last day, in days before now.
TRIP_FIRST, TRIP_LAST = 41, 38

#: Invented user name of the persona's Mac account (file paths inside stores).
USER_HOME = "/Users/robin"


class _Keyed(lib.ArchiveObject):
    """An archive object with a stable sort key, so that sets of them archive in the same
    order on every run (the archiver orders set members by `repr`)."""

    def __init__(self, class_name: str, fields: dict, sort_key: str):
        super().__init__(class_name, fields)
        self.sort_key = sort_key

    def __repr__(self) -> str:
        return f"{self.class_name}:{self.sort_key}"


# ----------------------------------------------------------------------------------------
# The routine
# ----------------------------------------------------------------------------------------

@dataclass
class Segment:
    """The Mac is at `where` (and on that place's Wi-Fi) from `start` to `end`."""
    start: datetime.datetime
    end: datetime.datetime
    where: str            # home / work / cafe / coffee / airport / trip / parents
    day: int              # days before now
    kind: str             # office / wfh / weekend / trip / parents
    open: bool = False    # still going on at `now`

    @property
    def seconds(self) -> float:
        return (self.end - self.start).total_seconds()


#: Wi-Fi network per place. The first five are the persona's; the rest are this module's.
SSID = {
    "home": "Sample-Home",
    "work": "KowhaiLabs",
    "cafe": "TuiAndFern-Guest",
    "coffee": "HarbourLight-WiFi",
    "airport": "Airport-Free-WiFi",
    "trip": "Lakeside-Lodge-Guest",
    "parents": "Helen-and-David",
    "gym": "TeAroClimbing-Members",
}


class World:
    """Clock, routine and identifiers shared by the writers below."""

    def __init__(self, root: pathlib.Path, persona: Persona, rng: random.Random, now: datetime.datetime):
        self.root = root
        self.p = persona
        self.rng = rng
        self.now = now if now.tzinfo else now.replace(tzinfo=UTC)
        self.clock = lib.Clock(self.now, persona.tz_offset_hours)
        self.tz = self.clock.tz
        self.mac = persona.this_mac
        self.iphone = persona.device("iphone")
        self.ipad = persona.device("ipad")
        self.watch = persona.device("watch")
        self.days = self._routine()
        self.segments = [s for day in self.days for s in day]
        #: BSSIDs (integers) of the access points the Mac associates with, per place.
        self.bssid = {key: self.mac48() for key in SSID}
        self.focus_sessions = self._focus_sessions()

    # -- time ---------------------------------------------------------------------------
    def local(self, when: datetime.datetime) -> datetime.datetime:
        return when.astimezone(self.tz)

    def at(self, days_ago: int, minutes: float) -> datetime.datetime:
        """`minutes` after local midnight, `days_ago` days back (may lie in the future)."""
        local = self.local(self.now) - datetime.timedelta(days=days_ago)
        midnight = local.replace(hour=0, minute=0, second=0, microsecond=0)
        return (midnight + datetime.timedelta(minutes=minutes)).astimezone(UTC)

    def weekday(self, days_ago: int) -> int:
        return (self.local(self.now) - datetime.timedelta(days=days_ago)).weekday()

    def past(self, when: datetime.datetime) -> bool:
        return when < self.now

    def within(self, segment: Segment, lead: float = 0.0, tail: float = 0.0) -> datetime.datetime:
        """A random moment inside a segment, `lead` / `tail` seconds away from its ends."""
        span = max(1.0, segment.seconds - lead - tail)
        return segment.start + datetime.timedelta(seconds=lead + self.rng.random() * span)

    # -- identifiers --------------------------------------------------------------------
    def uuid(self) -> str:
        return lib.uuid_string(self.rng)

    def mac48(self) -> int:
        """A random 48-bit address with the locally-administered bit set (never a vendor's)."""
        value = self.rng.getrandbits(48)
        first = ((value >> 40) | 0x02) & 0xFE
        return (first << 40) | (value & 0xFFFFFFFFFF)

    @staticmethod
    def mac_text(value: int, separator: str = ":", upper: bool = False) -> str:
        text = separator.join(f"{(value >> (8 * i)) & 0xFF:02x}" for i in reversed(range(6)))
        return text.upper() if upper else text

    def blob(self, size: int) -> bytes:
        return self.rng.getrandbits(8 * size).to_bytes(size, "little")

    # -- routine ------------------------------------------------------------------------
    def _routine(self) -> list[list[Segment]]:
        rng = self.rng
        j = lambda n: rng.randint(-n, n)   # noqa: E731
        parents_day = next((d for d in range(70, 77) if self.weekday(d) == 5), 72)
        days: list[list[Segment]] = []
        for d in range(DAYS, -1, -1):
            weekday = self.weekday(d)
            plan: list[tuple[float, float, str]]
            if TRIP_LAST <= d <= TRIP_FIRST:
                kind = "trip"
                if d == TRIP_FIRST:
                    plan = [(390, 520, "home"), (560, 630, "airport"), (930, 1380, "trip")]
                elif d == TRIP_LAST:
                    plan = [(420, 510, "trip"), (1005, 1380, "home")]
                else:
                    plan = [(420 + j(15), 555, "trip"), (1080 + j(30), 1380, "trip")]
            elif d == parents_day:
                kind = "parents"
                plan = [(480, 580, "home"), (670, 1010, "parents"), (1120, 1370, "home")]
            elif weekday >= 5:
                kind = "weekend"
                plan = [(520 + j(25), 660, "home")]
                if rng.random() < 0.45:
                    plan.append((680 + j(8), 765 + j(10), "cafe"))
                plan.append((840 + j(30), 1385 + j(15), "home"))
            elif weekday == 4 or rng.random() < 0.14:
                kind = "wfh"
                if rng.random() < 0.35:
                    plan = [(435 + j(12), 735, "home"), (750 + j(5), 815 + j(8), "cafe"), (835 + j(5), 1370 + j(15), "home")]
                else:
                    plan = [(435 + j(12), 1370 + j(15), "home")]
            else:
                kind = "office"
                plan = [(415 + j(10), 490 + j(8), "home")]
                arrive, leave = 525 + j(10), 1040 + j(25)
                if rng.random() < 0.15:
                    plan += [(arrive, 612, "work"), (618, 648 + j(5), "coffee"), (660, leave, "work")]
                else:
                    plan.append((arrive, leave, "work"))
                plan.append((1085 + j(15), 1365 + j(20), "home"))
            segments: list[Segment] = []
            for start_min, end_min, where in plan:
                start, end = self.at(d, start_min), self.at(d, end_min)
                if start >= self.now:
                    continue
                still = end > self.now
                segments.append(Segment(start, min(end, self.now), where, d, kind, open=still))
            days.append(segments)
        return days

    def _focus_sessions(self) -> list[tuple[datetime.datetime, datetime.datetime, str, str, bool]]:
        """(start, end, mode identifier, cause, still on): cause is location / sleep / user."""
        rng = self.rng
        out = []
        for segment in self.segments:
            if segment.where == "work":
                out.append((segment.start + datetime.timedelta(seconds=rng.randint(60, 240)), segment.end, MODE_WORK, "location", segment.open))
        for d in range(DAYS, 0, -1):
            start = self.at(d, 22 * 60 + 30 + rng.randint(-10, 25))
            end = self.at(d - 1, 6 * 60 + 45 + rng.randint(-15, 20))
            if self.past(start):
                out.append((start, min(end, self.now), MODE_SLEEP, "sleep", end > self.now))
            if self.weekday(d) in (1, 3) and not TRIP_LAST <= d <= TRIP_FIRST:
                out.append((self.at(d, 17 * 60 + 55 + rng.randint(-5, 10)), self.at(d, 19 * 60 + 20 + rng.randint(-10, 15)), MODE_CLIMBING, "location", False))
            if rng.random() < 0.13:
                begin = self.at(d, rng.randint(13 * 60, 16 * 60))
                out.append((begin, begin + datetime.timedelta(minutes=rng.randint(45, 120)), MODE_DND, "user", False))
            if self.weekday(d) == 6 and rng.random() < 0.5:
                begin = self.at(d, rng.randint(10 * 60, 11 * 60))
                out.append((begin, begin + datetime.timedelta(minutes=rng.randint(25, 70)), MODE_DRIVING, "driving", False))
        return sorted(out, key=lambda s: s[0])

    def working_moments(self, count: int, days: int, where: tuple[str, ...] = ("home", "work")) -> list[datetime.datetime]:
        """`count` moments at which the Mac was in use at one of `where`, newest more likely."""
        pool = [s for s in self.segments if s.day <= days and s.where in where and s.seconds > 600]
        weights = [s.seconds * (1.0 + 0.8 * (1 - s.day / max(days, 1))) for s in pool]
        return sorted(self.within(s, 120, 120) for s in self.rng.choices(pool, weights=weights, k=count))


# ----------------------------------------------------------------------------------------
# SQLite helpers for files shared with other modules
# ----------------------------------------------------------------------------------------

@contextmanager
def shared_db(path: pathlib.Path) -> Iterator[sqlite3.Connection]:
    """Opens a database another module may already have created (or creates it), in
    rollback-journal mode, inside one transaction. Never deletes the file."""
    lib.ensure_parent(path)
    con = sqlite3.connect(str(path), isolation_level=None)
    try:
        con.execute("PRAGMA journal_mode=DELETE")
        con.execute("BEGIN")
        yield con
        con.execute("COMMIT")
    except BaseException:
        if con.in_transaction:
            con.execute("ROLLBACK")
        raise
    finally:
        con.close()


def ensure_table(con: sqlite3.Connection, ddl: str) -> None:
    """Creates the table of a one-line-per-column CoreData style `CREATE TABLE`, or adds
    the columns an existing table (created by another module) is missing."""
    name = re.search(r"CREATE TABLE\s+(\w+)", ddl).group(1)
    existing = {row[1] for row in con.execute(f"PRAGMA table_info({name})")}
    if not existing:
        con.execute(ddl)
        return
    body = ddl[ddl.index("(") + 1:ddl.rindex(")")]
    for part in body.split(","):
        tokens = part.split()
        if tokens and tokens[0] not in existing:
            con.execute(f"ALTER TABLE {name} ADD COLUMN {tokens[0]} {tokens[1] if len(tokens) > 1 else ''}")


def has_table(con: sqlite3.Connection, name: str) -> bool:
    return con.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", (name,)).fetchone() is not None


def next_pk(con: sqlite3.Connection, table: str) -> int:
    return con.execute(f"SELECT coalesce(max(Z_PK), 0) FROM {table}").fetchone()[0] + 1


def ensure_coredata(con: sqlite3.Connection, entities: dict[str, int], rng: random.Random) -> None:
    """`Z_PRIMARYKEY` / `Z_METADATA` / `Z_MODELCACHE`, with `Z_MAX` brought up to date."""
    if not has_table(con, "Z_PRIMARYKEY"):
        lib.coredata_tables(con, entities, rng)
    for name, ent in entities.items():
        table = "Z" + name.upper()
        if not has_table(con, table):
            continue
        highest = con.execute(f"SELECT coalesce(max(Z_PK), 0) FROM {table}").fetchone()[0]
        if con.execute("SELECT 1 FROM Z_PRIMARYKEY WHERE Z_NAME = ?", (name,)).fetchone():
            con.execute("UPDATE Z_PRIMARYKEY SET Z_MAX = max(coalesce(Z_MAX, 0), ?) WHERE Z_NAME = ?", (highest, name))
        elif not con.execute("SELECT 1 FROM Z_PRIMARYKEY WHERE Z_ENT = ?", (ent,)).fetchone():
            con.execute("INSERT INTO Z_PRIMARYKEY VALUES (?, ?, 0, ?)", (ent, name, highest))


def stream(w: World, name: str, records: list, device: Optional[str] = None) -> None:
    folder = lib.biome_stream_dir(w.root, name)
    if records:
        lib.write_stream(folder, records, device=device)
    else:
        lib.ensure_dir(folder / "local")


# ----------------------------------------------------------------------------------------
# Focus: configuration cache, activity streams, assertion log
# ----------------------------------------------------------------------------------------

MODE_DND = "com.apple.donotdisturb.mode.default"
MODE_WORK = "com.apple.focus.work"
MODE_SLEEP = "com.apple.sleep.sleep-mode"
MODE_PERSONAL = "com.apple.focus.personal-time"
MODE_DRIVING = "com.apple.donotdisturb.mode.driving"
MODE_REDUCE = "com.apple.focus.reduce-interruptions"
#: A custom mode: the identifier ends in the chosen symbol's name without punctuation.
MODE_CLIMBING = "com.apple.donotdisturb.mode.figureclimbing"


def _region(w: World, place_key: str, radius: float, identifier: Optional[str] = None) -> lib.ArchiveObject:
    place = w.p.place(place_key)
    return A("CLCircularRegion", {
        "kCLCircularRegionCodingKeyCenterLatitude": float(place.latitude),
        "kCLCircularRegionCodingKeyCenterLongitude": float(place.longitude),
        "kCLCircularRegionCodingKeyRadius": float(radius),
        "kCLCircularRegionCodingKeyLowPower": False,
        "kCLCircularRegionCodingKeyMonitoringNearby": False,
        "kCLCircularRegionEncodedKeyVersion": 1,
        "kCLRegionCodingKeyEmergency": False,
        "kCLRegionCodingKeyIdentifier": identifier or (place.street or place.name),
        "kCLRegionCodingKeyNotifyOnEntry": True,
        "kCLRegionCodingKeyNotifyOnExit": True,
        "kCLRegionCodingKeyOnBehalfOfBundleId": None,
        "kCLRegionCodingKeyRegionType": 1,
        "kCLRegionCodingKeyWirelessClientInfo": False,
        "reserved": 1,
    }, classes=["CLCircularRegion", "CLRegion", "NSObject"])


def _focus_app(bundle: str, platform: int) -> _Keyed:
    """`platform`: 1 iPhone / iPad apps, 2 Mac apps, 3 Apple Watch apps."""
    return _Keyed("DNDApplicationIdentifier", {"bundleID": bundle, "platform": platform}, f"{platform}:{bundle}")


def _focus_contact(person) -> _Keyed:
    return _Keyed("DNDMutableContact", {
        "contactIdentifier": person.contact_id,
        "firstName": person.given, "middleName": "", "lastName": person.family, "nickName": person.nickname,
        "organizationName": person.organization,
        "phoneNumbers": frozenset(person.phones), "emailAddresses": frozenset(person.emails),
    }, person.key)


def _trigger(kind: str, enabled: int = 1, **extra: Any) -> lib.ArchiveObject:
    return A(f"DNDModeConfiguration{kind}Trigger", {"compatibilityVersion": 0, "enabledSetting": enabled, **extra},
             classes=[f"DNDModeConfiguration{kind}Trigger", "DNDModeConfigurationTrigger", "NSObject"])


def write_focus(w: World) -> None:
    p, rng = w.p, w.rng
    person = p.person

    def apps(*pairs: tuple[str, int]) -> list[_Keyed]:
        return [_focus_app(bundle, platform) for bundle, platform in pairs]

    def app_configuration() -> lib.ArchiveObject:
        return A("DNDMutableApplicationConfiguration", {"allowedThreads": frozenset(), "deniedThreads": frozenset(), "minimumBreakthroughUrgency": 0})

    def mode(identifier: str, name: str, symbol: str, tint: str, semantic: int, *, created_days: int, modified_days: float,
             triggers: list, allowed_apps: list = (), denied_apps: list = (), allowed: list = (), denied: list = (),
             by: str = "", generated: bool = False, codes: Optional[dict] = None, dims: int = 0) -> lib.ArchiveObject:
        configuration = {
            "allowIntelligentManagement": 0, "applicationConfigurationType": 1 if allowed_apps else 0, "compatibility": 10,
            "hideApplicationBadges": 2, "minimumBreakthroughUrgency": 1, "senderConfigurationType": 1 if allowed else 0,
            "suppressionMode": 0, "suppressionType": 2,
        }
        configuration.update(codes or {})
        configuration.update({
            "allowedApplicationIdentifiers": {app: app_configuration() for app in allowed_apps},
            "deniedApplicationIdentifiers": frozenset(denied_apps),
            "allowedWebApplicationIdentifiers": frozenset(), "deniedWebApplicationIdentifiers": frozenset(),
            "senderConfiguration": A("DNDMutableSenderConfiguration", {
                "allowedContacts": frozenset(_focus_contact(x) for x in allowed),
                "deniedContacts": frozenset(_focus_contact(x) for x in denied),
                "allowedContactGroups": frozenset(), "deniedContactGroups": frozenset(),
                "allowedContactTypes": frozenset(), "deniedContactTypes": frozenset(),
                "phoneCallBypassSettings": A("DNDBypassSettings", {
                    "immediateBypassCNGroupIdentifier": None, "immediateBypassEventSourceType": 2,
                    "repeatEventSourceBehaviorEnabledSetting": 1}),
            }),
        })
        return A("DNDMutableModeConfiguration", {
            "automaticallyGenerated": generated, "compatibilityVersion": 2,
            "configuration": A("DNDMutableConfiguration", configuration),
            "created": w.clock.ago(days=created_days), "lastModified": w.clock.ago(days=modified_days),
            "dimsLockScreen": dims, "impactsAvailability": 0,
            "lastModifiedByDeviceID": by or None,
            # Format `NNN.N.N` (the DoNotDisturb framework version); digits invented.
            "lastModifiedByVersion": "927.2.1",
            "mode": A("DNDMode", {
                "identifier": lib.uuid_obj(rng), "modeIdentifier": identifier, "name": name, "semanticType": semantic,
                "symbolDescriptor": None, "symbolImageName": symbol, "tintColorName": tint, "visibility": 0}),
            "triggers": triggers,
        }, classes=["DNDMutableModeConfiguration", "DNDModeConfiguration", "NSObject"])

    partner, mother, father, sister = person("partner"), person("mother"), person("father"), person("sister")
    colleagues = [person("aroha")] + p.people_with("colleague")
    work_mac = [("com.tinyspeck.slackmacgap", 2), ("com.apple.mail", 2), ("com.apple.iCal", 2), ("com.figma.Desktop", 2),
                ("us.zoom.xos", 2), ("notion.id", 2), ("com.apple.Notes", 2), ("com.apple.reminders", 2)]
    work_ios = [("com.tinyspeck.chatlyio", 1), ("com.apple.mobilemail", 1), ("com.apple.mobilecal", 1), ("us.zoom.videomeetings", 1),
                ("com.apple.mobilephone", 1)]
    modes = {
        MODE_WORK: mode(
            MODE_WORK, "Work", "briefcase.fill", "systemTealColor", 4, created_days=540, modified_days=23.4,
            triggers=[_trigger("Location", region=_region(w, "work", 150.0), detail=None), _trigger("Smart", enabled=2)],
            allowed_apps=apps(*work_mac, *work_ios), allowed=[partner, *colleagues], by=w.mac.identifier),
        MODE_PERSONAL: mode(
            MODE_PERSONAL, "Personal", "person.fill", "systemPurpleColor", 5, created_days=540, modified_days=61.2,
            triggers=[_trigger("Location", region=_region(w, "home", 120.0), detail=None)],
            denied_apps=apps(("com.tinyspeck.slackmacgap", 2), ("com.tinyspeck.chatlyio", 1), ("us.zoom.xos", 2), ("com.figma.Desktop", 2),
                             ("notion.id", 2), ("com.github.stormbreaker.prod", 1)),
            denied=[person("aroha"), person("oliver"), person("landlord")], by=w.iphone.identifier,
            codes={"hideApplicationBadges": 1, "minimumBreakthroughUrgency": 0}),
        MODE_SLEEP: mode(
            MODE_SLEEP, "Sleep", "bed.double.fill", "systemMintColor", 1, created_days=700, modified_days=118.0,
            triggers=[_trigger("Sleeping")], allowed=[partner, mother, father, sister],
            allowed_apps=apps(("com.apple.mobilephone", 1), ("com.apple.Health", 1), ("com.apple.NanoAlarm", 3)),
            by=w.iphone.identifier, dims=2),
        MODE_CLIMBING: mode(
            MODE_CLIMBING, "Climbing", "figure.climbing", "systemOrangeColor", -1, created_days=255, modified_days=44.7,
            triggers=[_trigger("Location", region=_region(w, "gym", 100.0, "Te Aro Climbing Gym"), detail=None)],
            allowed_apps=apps(("com.apple.Music", 1), ("com.apple.SessionTrackerApp", 3), ("com.apple.MobileSMS", 1)),
            allowed=[partner, person("priya"), person("tom")], by=w.iphone.identifier),
        MODE_DND: mode(
            MODE_DND, "Do Not Disturb", "moon.fill", "systemIndigoColor", 0, created_days=700, modified_days=203.0,
            triggers=[], allowed=[partner, mother], by=w.mac.identifier,
            codes={"compatibility": 3, "hideApplicationBadges": 0}),
        MODE_DRIVING: mode(
            MODE_DRIVING, "Driving", "car.fill", "systemBlueColor", 2, created_days=700, modified_days=380.0,
            triggers=[_trigger("Driving")], allowed=[partner], by=w.iphone.identifier,
            codes={"compatibility": 3, "hideApplicationBadges": 0, "minimumBreakthroughUrgency": 0}),
        MODE_REDUCE: mode(
            MODE_REDUCE, "Reduce Interruptions", "apple.intelligence", "systemPinkColor", 9, created_days=160, modified_days=160.0,
            triggers=[], generated=True,
            codes={"allowIntelligentManagement": 2, "compatibility": 20, "hideApplicationBadges": 1, "minimumBreakthroughUrgency": 0}),
    }
    lib.write_bytes(lib.library(w.root, "DuetExpertCenter/DNDModeConfigurationsCache"), lib.keyed_archive(modes, mutable_collections=True))

    # UserFocus.ComputedMode — 1 assertion UUID, 2 starting / ending, 3–5 codes, 6 mode identifier.
    computed = []
    assertions = []
    #: Clients and lifetimes as the assertion log names them.
    client = {"location": "com.apple.focus.activity-manager", "sleep": "com.apple.donotdisturb.private.sleeping-trigger",
              "user": "com.apple.donotdisturb.control-center.module", "driving": "com.apple.donotdisturb.private.smart-trigger"}
    detail_identifier = {"location": "com.apple.donotdisturb.kit.lifetime.location", "sleep": "com.apple.donotdisturb.trigger.sleeping",
                         "user": "com.apple.FocusSettings", "driving": "com.apple.donotdisturb.trigger.smart"}
    for start, end, identifier, cause, still_on in w.focus_sessions:
        assertion = w.uuid()
        code = 3 if cause == "user" else 1
        computed.append((start, pb.message([(1, assertion), (2, True), (3, code), (4, 3), (5, 2), (6, identifier)])))
        if still_on:
            continue
        computed.append((end, pb.message([(1, assertion), (2, False), (3, code), (4, 3), (5, 2), (6, identifier)])))
        source = {"assertionClientIdentifier": client[cause], "assertionSourceDeviceIdentifier": w.mac.identifier if cause == "user" else w.iphone.identifier}
        assertions.append({
            "invalidationAssertion": {
                "assertionUUID": assertion,
                "assertionStartDateTimestamp": lib.cocoa(start),
                "assertionDetails": {
                    "assertionDetailsIdentifier": detail_identifier[cause],
                    "assertionDetailsModeIdentifier": identifier,
                    "assertionDetailsReason": "user-action" if cause == "user" else "schedule",
                    "assertionDetailsLifetime": {"assertionDetailsLifetimeType": "schedule" if cause == "sleep" else "default"},
                },
                "assertionSource": source,
            },
            "invalidationDateTimestamp": lib.cocoa(end),
            "invalidationReason": "user-changed-state" if cause == "user" else "client-ended",
            "invalidationSource": source,
        })
    stream(w, "UserFocus.ComputedMode", computed)
    lib.write_text(lib.library(w.root, "DoNotDisturb/DB/Assertions.json"), json.dumps({
        "header": {"version": 8, "timestamp": lib.cocoa(w.clock.ago(minutes=42))},
        "data": [{"storeInvalidationRecords": assertions[-400:], "storeInvalidationRequestRecords": []}],
    }, indent=1))

    # UserFocus.InferredMode — 1 Cocoa date, 2 / 7 UUIDs, 3 mode type, 5 start flag,
    # 10 confidence, 12 origin code, 14 origin label. The type and origin codes and the
    # labels (the app that gave the hint) are a guess.
    inferred = []
    hints = [(7, "com.apple.SessionTrackerApp", 4), (10, "com.apple.Maps", 2), (1, "com.apple.iCal", 8), (0, "com.apple.Music", 2)]
    for start, end, identifier, cause, still_on in w.focus_sessions:
        if identifier == MODE_CLIMBING:
            hint = hints[0]
        elif identifier == MODE_DRIVING:
            hint = hints[1]
        elif identifier == MODE_WORK and rng.random() < 0.35:
            hint = hints[2]
        elif identifier == MODE_DND and rng.random() < 0.6:
            hint = hints[3]
        else:
            continue
        a, b = w.uuid(), w.uuid()
        confidence = round(rng.uniform(0.62, 0.97), 3)
        begin = start - datetime.timedelta(seconds=rng.randint(20, 240))
        for when, flag in ((begin, True), (end, False)):
            if flag or not still_on:
                inferred.append((when, pb.message([(1, lib.cocoa(when)), (2, a), (3, hint[0]), (5, flag), (6, False), (7, b), (9, 1),
                                                    (10, confidence), (12, hint[2]), (13, 0), (14, hint[1])])))
    stream(w, "UserFocus.InferredMode", inferred)


# ----------------------------------------------------------------------------------------
# Wi-Fi: join streams, known networks (iCloud key-value cache), printers
# ----------------------------------------------------------------------------------------

def write_wifi_streams(w: World) -> None:
    rng = w.rng
    connects, intervals, phone = [], [], []
    gmt_offset = int(w.p.tz_offset_hours * 3600)
    for segment in w.segments:
        ssid = SSID[segment.where]
        connects.append((segment.start, pb.message([(1, ssid), (2, True)])))
        if not segment.open and rng.random() < 0.3:
            connects.append((segment.end, pb.message([(1, ssid), (2, False)])))
        if not segment.open:
            # A CoreDuet event: 1 { 1 stream name (guess), 2 { type, value } }, 2 start, 3 end,
            # 4 { 1 { type, value }, 3 SSID }, 5 event UUID, 8 creation date, 10 seconds from GMT.
            intervals.append((segment.end, pb.message([
                (1, [(1, "/wifi/connection"), (2, [(1, 2), (2, 1)])]),
                (2, lib.cocoa(segment.start)), (3, lib.cocoa(segment.end)),
                (4, [(1, [(1, 2), (2, rng.randint(1, 9))]), (3, ssid)]),
                (5, w.uuid()), (8, lib.cocoa(segment.end)), (10, gmt_offset)])))
        # The phone joins the same network a little earlier (it is in a pocket, not a bag) …
        phone.append((segment.start - datetime.timedelta(seconds=rng.randint(40, 400)), pb.message([(1, ssid), (2, True)])))
    # … and the climbing gym's on Tuesdays and Thursdays.
    for start, _end, identifier, _cause, _on in w.focus_sessions:
        if identifier == MODE_CLIMBING:
            phone.append((start + datetime.timedelta(seconds=rng.randint(30, 200)), pb.message([(1, SSID["gym"]), (2, True)])))
    stream(w, "Device.Wireless.WiFi", connects)
    stream(w, "Device.Wireless.WiFi", [r for r in phone if r[0] < w.now], device=w.iphone.identifier)
    stream(w, "_DKEvent.Wifi.Connection", intervals)


#: iCloud key-value cache (kvsd). Real schema of the three entity tables.
KVS_DDL = [
    "CREATE TABLE ZSYDMANAGEDDATABASE ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDIDMIGRATEFROMPLISTS INTEGER, ZFAILEDMIGRATIONCOUNT INTEGER, ZHASPERFORMEDONETIMEDATASEPARATEDLOCALDATARESET INTEGER, ZACACCOUNTIDENTIFIER VARCHAR, ZSYNCENGINEMETADATA BLOB, ZSYNCENGINESTATESERIALIZATION BLOB )",
    "CREATE TABLE ZSYDMANAGEDKEYVALUE ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZPLISTDATALENGTH INTEGER, ZSTORE INTEGER, ZVALUEMODIFICATIONDATE TIMESTAMP, ZKEY VARCHAR, ZRECORDNAME VARCHAR, ZPLISTDATAVALUE BLOB, ZSERVERSYSTEMFIELDSRECORDDATA BLOB )",
    "CREATE TABLE ZSYDMANAGEDSTORE ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZTOTALDATALENGTH INTEGER, ZDATABASE INTEGER, ZIDENTIFIER VARCHAR, ZSYNCANCHORSERVERSYSTEMFIELDSRECORDDATA BLOB )",
]
KVS_ENTITIES = {"SYDManagedDatabase": 1, "SYDManagedKeyValue": 2, "SYDManagedStore": 3}
KVS_PLAIN = "com.apple.KeyValueService-Production.sqlite"
KVS_E2E = "com.apple.KeyValueService.EndToEndEncrypted-Production.sqlite"


def kvs_put(w: World, database: str, store: str, entries: list[tuple[str, Any, datetime.datetime]]) -> None:
    """Adds one store identifier with its keys to a kvs database (shared with other modules)."""
    path = lib.daemon_container(w.root, "com.apple.kvs", w.rng) / "com.apple.kvs" / database
    with shared_db(path) as con:
        for ddl in KVS_DDL:
            ensure_table(con, ddl)
        if con.execute("SELECT count(*) FROM ZSYDMANAGEDDATABASE").fetchone()[0] == 0:
            con.execute("INSERT INTO ZSYDMANAGEDDATABASE (Z_PK, Z_ENT, Z_OPT, ZDIDMIGRATEFROMPLISTS, ZFAILEDMIGRATIONCOUNT, ZHASPERFORMEDONETIMEDATASEPARATEDLOCALDATARESET) VALUES (1, 1, 1, 1, 0, 1)")
        row = con.execute("SELECT Z_PK FROM ZSYDMANAGEDSTORE WHERE ZIDENTIFIER = ?", (store,)).fetchone()
        if row:
            store_pk = row[0]
        else:
            store_pk = next_pk(con, "ZSYDMANAGEDSTORE")
            con.execute("INSERT INTO ZSYDMANAGEDSTORE (Z_PK, Z_ENT, Z_OPT, ZTOTALDATALENGTH, ZDATABASE, ZIDENTIFIER) VALUES (?, 3, 1, 0, 1, ?)", (store_pk, store))
        pk = next_pk(con, "ZSYDMANAGEDKEYVALUE")
        total = 0
        for key, value, modified in entries:
            data = lib.plist_bytes(value)
            total += len(data)
            # A key exists once per store: an entry another generator wrote for the same key
            # (mailsearch adds the persona's five networks) is replaced, not duplicated.
            con.execute("DELETE FROM ZSYDMANAGEDKEYVALUE WHERE ZSTORE = ? AND ZKEY = ?", (store_pk, key))
            con.execute("INSERT INTO ZSYDMANAGEDKEYVALUE (Z_PK, Z_ENT, Z_OPT, ZPLISTDATALENGTH, ZSTORE, ZVALUEMODIFICATIONDATE, ZKEY, ZRECORDNAME, ZPLISTDATAVALUE) VALUES (?, 2, ?, ?, ?, ?, ?, ?, ?)",
                        (pk, w.rng.randint(1, 9), len(data), store_pk, lib.cocoa(modified), key, w.uuid(), data))
            pk += 1
        con.execute("UPDATE ZSYDMANAGEDSTORE SET ZTOTALDATALENGTH = coalesce(ZTOTALDATALENGTH, 0) + ? WHERE Z_PK = ?", (total, store_pk))
        ensure_coredata(con, KVS_ENTITIES, w.rng)


def write_known_networks(w: World) -> None:
    rng = w.rng
    last_on = {}
    for segment in w.segments:
        last_on[SSID[segment.where]] = segment.start
    def version(device, added: float) -> str:
        """`addedByVersion` of the system that was current `added` days ago: this persona's
        devices today, invented earlier releases and builds before that."""
        system = "macos" if device.kind == "Mac" else "iphoneos"
        if added < 50:
            number, build, model = device.os_version.replace(".", "_"), device.os_build, device.model
        elif added < 420:
            number, build, model = ("26_3", "25D41", device.model) if system == "macos" else ("26_3", "23D52", device.model)
        elif added < 780:
            number, build, model = ("15_4", "24E38", device.model) if system == "macos" else ("18_4", "22E47", "iPhone15,2")
        else:
            number, build, model = "13_1", "22C58", "MacBookPro16,1"   # an invented earlier Mac
        return f"{system}.{number}.{build}.{model.lower()}.2"   # the store writes the model in lower case

    mac, phone, pad = w.mac, w.iphone, w.ipad
    # ssid, flags, added (days ago), added by, removed (days ago), extra keys
    networks: list[tuple[str, tuple[str, ...], float, Any, Optional[float], dict]] = [
        (SSID["home"], ("isPSK", "isWPA3"), 611.3, mac, None, {"preferred": 611.2}),
        (SSID["work"], ("isEAP", "isWPA2"), 487.6, mac, None, {"seamless": ["KowhaiLabs-Guest"]}),
        ("KowhaiLabs-Guest", ("isPSK", "isWPA2"), 486.9, phone, None, {}),
        ("KL-Studio-IoT", ("isPSK", "isWPA2"), 301.4, mac, None, {"hidden": True}),
        (SSID["cafe"], ("isPSK", "isWPA2"), 302.5, phone, None, {}),
        (SSID["coffee"], ("isPSK", "isWPA2"), 214.2, phone, None, {}),
        (SSID["airport"], ("isPublic",), 402.8, phone, None, {"captive": True, "lowData": True}),
        ("Robin's iPhone", ("isPSK", "isWPA3", "isPersonalHotspot"), 505.0, mac, None, {}),
        (SSID["trip"], ("isPSK", "isWPA2"), TRIP_FIRST - 0.35, mac, TRIP_LAST - 1.6, {"captive": True}),
        (SSID["parents"], ("isPSK", "isWPA2"), 702.1, phone, None, {}),
        (SSID["gym"], ("isPSK", "isWPA2"), 258.4, phone, None, {}),
        ("Ferry-Guest-WiFi", ("isPublic", "isMoving"), 152.7, phone, None, {"captive": True}),
        ("Raman-Home", ("isPSK", "isWPA3"), 333.0, phone, None, {}),
        ("Library-Public", ("isPublic",), 226.5, pad, None, {"captive": True}),
        ("DesignConf-Auckland", ("isPSK", "isWPA2"), 190.4, phone, 186.2, {"captive": True}),
        ("OldFlat-5G", ("isPSK", "isWPA2"), 1404.0, mac, 615.0, {}),
    ]
    flags = ("isAppBased", "isEAP", "isMoving", "isPSK", "isPersonalHotspot", "isPublic", "isWEP", "isWPA", "isWPA2", "isWPA3")
    entries = []
    for ssid, on, added, by, removed, extra in networks:
        value: dict[str, Any] = {
            "SSID": ssid,
            "BSSID": World.mac_text(next((w.bssid[k] for k, s in SSID.items() if s == ssid), w.mac48())),
            "addedAt": w.clock.ago(days=added),
            "addedByVersion": version(by, added),
        }
        for flag in flags:
            value[flag] = flag in on
        value["isHidden"] = bool(extra.get("hidden"))
        value["isCaptive"] = bool(extra.get("captive"))
        value["isPrivacyProxyEnabled"] = "isPublic" not in on
        value["lowDataMode"] = bool(extra.get("lowData"))
        if "preferred" in extra:
            value["preferredOrderTimestamp"] = w.clock.ago(days=extra["preferred"])
        if "seamless" in extra:
            value["seamlessSSIDList"] = extra["seamless"]
        last = last_on.get(ssid)
        if removed is not None:
            last = w.clock.ago(days=removed + rng.uniform(0.3, 1.0))
            value["removedAt"] = w.clock.ago(days=removed)
        elif last is None:
            last = w.clock.ago(days=min(added, rng.uniform(3, 110)))
        # The owner joined by hand once (when adding the network, or lately for guest networks) …
        by_hand = w.clock.ago(days=added) if "isPublic" not in on and not extra.get("captive") else last
        value["lastJoinedByUserAt"] = by_hand
        # … the system only keeps the week (weeks since the Cocoa reference date) of its own joins.
        value["lastJoinedBySystemAtWeek"] = int(lib.cocoa(last) // 604_800)
        entries.append((f"network.{ssid}", value, max(last, w.clock.ago(days=added))))
    kvs_put(w, KVS_E2E, "com.apple.wifi.syncable-networks", entries)

    printers = [
        {
            "com.apple.printkit.printer-display-name": "Kōwhai Labs — Level 3 Colour",
            "com.apple.printkit.printer-location": "Level 3, by the kitchen",
            "com.apple.printkit.printer-urls": ["ipps://print-l3.example.org:631/ipp/print"],
            "com.apple.printkit.printer-networks": [SSID["work"]],
            "com.apple.printkit.printer-endpoints": [],
            "com.apple.printkit.last-used-date": w.working_moments(1, 9, ("work",))[0],
            "printer-dns-sd-name": "Kowhai Labs L3 Colour", "printer-uuid": w.uuid().lower(),
        },
        {
            "com.apple.printkit.printer-display-name": "Home Inkjet",
            "com.apple.printkit.printer-location": "Study",
            "com.apple.printkit.printer-urls": ["ipp://home-inkjet.local:631/ipp/print"],
            "com.apple.printkit.printer-networks": [SSID["home"]],
            "com.apple.printkit.printer-endpoints": [],
            "com.apple.printkit.last-used-date": w.clock.ago(days=17.4),
            "printer-dns-sd-name": "Home Inkjet", "printer-uuid": w.uuid().lower(),
        },
    ]
    kvs_put(w, KVS_PLAIN, "com.apple.PrintKit.PrinterTool", [("com.apple.printing.iCloudPrinters", printers, w.clock.ago(days=9))])


# ----------------------------------------------------------------------------------------
# Places: recent locations and Wallet addresses (kvs), shortcut geofences (Biome)
# ----------------------------------------------------------------------------------------

def write_place_stores(w: World) -> None:
    rng, p = w.rng, w.p
    # place key, name shown, source app, number of uses, most recent use (days ago)
    recents = [
        ("work", None, "com.apple.iCal", 14, 2.1), ("cafe", None, "com.apple.mobilecal", 9, 5.6),
        ("gym", None, "com.apple.mobilecal", 11, 3.2), ("te_papa", None, "com.apple.iCal", 2, 47.0),
        ("botanic", None, "com.apple.reminders", 3, 20.5), ("station", None, "com.apple.mobilecal", 4, 12.4),
        ("airport", None, "com.apple.mobilecal", 3, TRIP_FIRST + 0.6), ("market", None, "com.apple.reminders", 6, 6.3),
        ("coffee", None, "com.apple.iCal", 4, 9.8), ("parents", "Mum & Dad's", "com.apple.mobilecal", 5, 72.3),
        ("queenstown", None, "com.apple.mobilecal", 2, TRIP_FIRST - 1.2), ("auckland", "DesignConf — Sky Tower", "com.apple.iCal", 2, 188.0),
        ("zealandia", None, "com.apple.mobilecal", 1, 96.0), ("home", "Home", "com.apple.reminders", 7, 1.4),
        ("oriental", None, "com.apple.mobilecal", 3, 27.5),
    ]
    entries = []
    for key, name, source, uses, last in recents:
        place = p.place(key)
        dates = sorted([w.clock.ago(days=last)] + [w.clock.ago(days=last + rng.uniform(2, 240)) for _ in range(uses - 1)])
        lines = [place.street, f"{place.city} {place.postal_code}".strip(), place.country]
        value = {
            "n": name or place.name,
            "a": "\n".join(line for line in lines if line),
            "S": source,
            "t": dates,
            "k": f"{name or place.name}|{place.street}".lower(),
            "v": 2,
            "m": {
                "latitude": place.latitude, "longitude": place.longitude, "hAccuracy": float(rng.choice([15, 25, 40, 65])),
                "vAccuracy": -1.0, "radius": float(rng.choice([60, 100, 150])), "referenceFrame": 1, "locationType": 0,
                "mapKitHandle": w.blob(rng.randint(180, 420)),
            },
        }
        entries.append(("MR_" + lib.hex_string(rng, 32).upper(), value, dates[-1]))
    kvs_put(w, KVS_PLAIN, "com.apple.eventkit.locations", entries)

    owner, mother = p.owner, p.person("mother")
    home, parents = p.place("home"), p.place("parents")
    # Private addresses carry no house number (persona rule), so they name no real household.
    addresses = [
        (owner, home.street, home, 9, 4.2), (owner, f"{p.company}, Level 3, {p.place('work').street}", p.place("work"), 3, 33.0),
        (mother, parents.street, parents, 2, 151.0),
    ]
    entries = []
    for person, street, place, uses, last in addresses:
        dates = sorted([w.clock.ago(days=last)] + [w.clock.ago(days=last + rng.uniform(5, 300)) for _ in range(uses - 1)])
        value = {
            "n": person.full_name, "a": f"{street}\n{place.city} {place.postal_code}\n{place.country}", "S": "com.apple.Passbook",
            "t": dates, "k": f"{person.full_name}|{street}".lower(), "v": 2, "w": float(uses),
            "m": {
                "givenName": person.given, "familyName": person.family, "phoneticGivenName": "", "phoneticFamilyName": "",
                "contactFromContactInformation": False,
                "postalAddress": {"Street": street, "City": place.city, "ZIP": place.postal_code, "Country": place.country,
                                  "CountryCode": place.country_code.lower(), "ISOCountryCode": place.country_code.lower()},
            },
        }
        entries.append(("MR_" + lib.hex_string(rng, 32).upper(), value, dates[-1]))
    kvs_put(w, KVS_E2E, "com.apple.passbook.locations", entries)

    # App.RelevantShortcuts — 1 bundle id, 3 archived INRelevantShortcut with an
    # INLocationRelevanceProvider { region: CLCircularRegion } among its relevance providers.
    def shortcut(bundle: str, place_key: str, radius: float, widget: str, title: str) -> bytes:
        intent = A("INIntent", {
            "identifier": w.uuid(), "backingStore": A("INCodable", {"bytes": pb.message([(1, title)]), "codableDescriptionBytes": b"\x08\x01"}),
            "donationMetadata": None, "recordDeviceIdentifier": None, "recordDeviceUID": None, "recordRoute": None,
            "_indexingHash": rng.getrandbits(40), "_shouldForwardToAppOnSucccess": False, "audioSessionID": 0,
            "parameterCombinations": {},
        })
        return pb.message([(1, bundle), (3, lib.keyed_archive(A("INRelevantShortcut", {
            "relevanceProviders": [A("INLocationRelevanceProvider", {"region": _region(w, place_key, radius, w.uuid())},
                                     classes=["INLocationRelevanceProvider", "INRelevanceProvider", "NSObject"])],
            "shortcut": A("INShortcut", {"intent": intent, "userActivity": None, "activityBundleIdentifier": None,
                                         "activityImage": None, "activitySubtitle": None}),
            "shortcutRole": 0, "watchTemplate": None, "widgetKind": widget,
        })))])

    donors = [
        ("com.apple.Passbook", "airport", 500.0, "com.apple.Passbook.boardingPass", "Boarding pass", 3),
        ("com.apple.reminders", "market", 150.0, "com.apple.reminders.list", "Groceries", 14),
        ("com.apple.Fitness", "gym", 120.0, "com.apple.Fitness.activity", "Start a climbing workout", 22),
        ("com.apple.Maps", "work", 200.0, "com.apple.Maps.commute", "Commute", 30),
        ("com.apple.Maps", "home", 200.0, "com.apple.Maps.commute", "Commute", 30),
        ("com.apple.weather", "queenstown", 2500.0, "com.apple.weather.forecast", "Forecast", 4),
        ("com.apple.shortcuts", "home", 100.0, "com.apple.shortcuts.run", "Arrive home", 18),
        ("com.apple.podcasts", "station", 180.0, "com.apple.podcasts.upnext", "Up next", 9),
        ("com.apple.mobilecal", "cafe", 100.0, "com.apple.mobilecal.upnext", "Coffee with Priya", 5),
        ("com.apple.Passbook", "te_papa", 150.0, "com.apple.Passbook.eventTicket", "Exhibition ticket", 1),
    ]
    records = []
    for bundle, place_key, radius, widget, title, repeats in donors:
        payload = shortcut(bundle, place_key, radius, widget, title)
        newest = TRIP_FIRST if place_key in ("airport", "queenstown") else rng.uniform(0.3, 6)
        for index in range(repeats):
            records.append((w.clock.ago(days=newest + index * rng.uniform(1.5, 4.5)), payload))
    stream(w, "App.RelevantShortcuts", records, device=w.iphone.identifier)
    stream(w, "App.RelevantShortcuts", [])

    # Location streams the Places section reports on. A Mac keeps them, but empty.
    for name in ("Location.Semantic", "Location.HashedCoordinates", "Location.MicroLocationVisit",
                 "Location.PointOfInterest.Category", "FindMy.LocationChange"):
        stream(w, name, [])


# ----------------------------------------------------------------------------------------
# Bluetooth
# ----------------------------------------------------------------------------------------

@dataclass
class Accessory:
    key: str
    name: str
    product: int     # USB / Bluetooth product id (invented where not a well-known public one)
    vendor: int      # Bluetooth SIG company id: 76 Apple, 301 Sony; 0 where the maker is invented
    kind: int        # device type code as the stream stores it (which code means what is a guess)
    audio: bool      # Apple audio accessory
    address: str = ""


def bluetooth_sessions(w: World) -> tuple[dict[str, Accessory], list[tuple[datetime.datetime, Optional[datetime.datetime], str, str]]]:
    """Accessories and (start, end or None while connected, accessory key, host)."""
    rng = w.rng
    accessories = {a.key: a for a in [
        Accessory("airpods", "Robin's AirPods Pro", 8212, 76, 20, True),
        Accessory("keyboard", "Magic Keyboard", 666, 76, 18, False),
        Accessory("trackpad", "Magic Trackpad", 613, 76, 17, False),
        Accessory("sony", "WH-1000XM5", 3536, 301, 21, False),
        Accessory("speaker", "Harbour Mini Speaker", 4130, 0, 21, False),
        Accessory("car", "Corolla Hands-Free", 0, 0, 1, False),
    ]}
    for accessory in accessories.values():
        accessory.address = World.mac_text(w.mac48(), upper=True)
    minutes = lambda n: datetime.timedelta(minutes=n)   # noqa: E731
    out: list[tuple[datetime.datetime, Optional[datetime.datetime], str, str]] = []

    def add(start: datetime.datetime, end: datetime.datetime, key: str, host: str, segment: Optional[Segment] = None) -> None:
        if start >= w.now:
            return
        still = end >= w.now or (segment is not None and segment.open and end >= segment.end)
        out.append((start, None if still else end, key, host))

    for segment in w.segments:
        long_enough = segment.seconds > 5400
        if segment.where == "home" and long_enough:
            desk = segment.kind == "wfh" or rng.random() < 0.55
            if desk:
                begin = segment.start + minutes(rng.randint(4, 25))
                finish = segment.end - minutes(rng.randint(8, 50)) if not segment.open else segment.end
                add(begin, finish, "keyboard", "mac", segment)
                add(begin + minutes(rng.uniform(0.2, 2)), finish + minutes(rng.uniform(0, 1)) if not segment.open else finish, "trackpad", "mac", segment)
            if segment.kind == "wfh" and rng.random() < 0.5:
                begin = w.within(segment, 3600, 3 * 3600)
                add(begin, begin + minutes(rng.randint(50, 170)), "sony", "mac")
            elif rng.random() < 0.28:
                begin = w.within(segment, 1800, 2 * 3600)
                add(begin, begin + minutes(rng.randint(35, 95)), "airpods", "mac")
            if segment.kind == "weekend" and rng.random() < 0.4:
                begin = w.within(segment, 1200, 3 * 3600)
                add(begin, begin + minutes(rng.randint(55, 150)), "speaker", "mac")
        if segment.where == "work" and long_enough:
            cursor = segment.start + minutes(rng.randint(25, 80))
            for _ in range(rng.randint(1, 3)):
                length = minutes(rng.randint(22, 65))
                if cursor + length > segment.end - minutes(5):
                    break
                add(cursor, cursor + length, "airpods", "mac")
                cursor += length + minutes(rng.randint(40, 150))
        # The phone: AirPods on the walk to and from the office.
        if segment.where == "work":
            add(segment.start - minutes(rng.randint(26, 34)), segment.start - minutes(rng.randint(1, 4)), "airpods", "iphone")
            if not segment.open:
                add(segment.end + minutes(rng.randint(2, 6)), segment.end + minutes(rng.randint(28, 40)), "airpods", "iphone")
        if segment.where in ("cafe", "parents") and segment.kind in ("weekend", "parents") and rng.random() < 0.7:
            drive = minutes(rng.randint(12, 22) if segment.where == "cafe" else rng.randint(52, 64))
            add(segment.start - drive - minutes(3), segment.start - minutes(3), "car", "iphone")
            add(segment.end + minutes(4), segment.end + minutes(4) + drive, "car", "iphone")
    return accessories, sorted(out, key=lambda s: s[0])


def write_bluetooth_streams(w: World, accessories: dict[str, Accessory], sessions: list) -> None:
    rng = w.rng

    def event(accessory: Accessory, connected: bool) -> bytes:
        battery = [(6, rng.randint(40, 100)), (7, rng.randint(35, 100)), (8, rng.randint(35, 100))] if accessory.key == "airpods" else []
        return pb.message([(1, accessory.address), (2, accessory.name), (3, accessory.product), (4, connected), (5, accessory.kind),
                           *battery, (9, accessory.audio), (10, 1), (11, accessory.vendor)])

    local, phone = [], []
    for start, end, key, host in sessions:
        if key == "car":
            continue   # the car only shows up in CoreDuet's log (knowledgeC), synced from the phone
        target = local if host == "mac" else phone
        target.append((start, event(accessories[key], True)))
        if end is not None:
            target.append((end, event(accessories[key], False)))
    stream(w, "Device.Wireless.Bluetooth", local)
    stream(w, "Device.Wireless.Bluetooth", phone, device=w.iphone.identifier)

    # Device.Wireless.BluetoothNearbyDevice — 2 anonymous device identifier, 1 / 3 / 4 codes.
    pool = [w.uuid() for _ in range(14)]
    weights = [9, 7, 6, 4, 3, 3, 2, 2, 1, 1, 1, 1, 1, 1]
    nearby = [(when, pb.message([(1, 1), (2, rng.choices(pool, weights=weights)[0]), (3, 1), (4, 6)]))
              for when in w.working_moments(170, 30, ("home", "work", "cafe"))]
    stream(w, "Device.Wireless.BluetoothNearbyDevice", nearby)


# ----------------------------------------------------------------------------------------
# knowledgeC.db (shared with other modules)
# ----------------------------------------------------------------------------------------

KNOWLEDGE_DDL = [
    "CREATE TABLE ZOBJECT ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZUUIDHASH INTEGER, ZEVENT INTEGER, ZSOURCE INTEGER, ZCATEGORYTYPE INTEGER, ZINTEGERVALUE INTEGER, ZCOMPATIBILITYVERSION INTEGER, ZENDDAYOFWEEK INTEGER, ZENDSECONDOFDAY INTEGER, ZHASCUSTOMMETADATA INTEGER, ZHASSTRUCTUREDMETADATA INTEGER, ZSECONDSFROMGMT INTEGER, ZSHOULDSYNC INTEGER, ZSTARTDAYOFWEEK INTEGER, ZSTARTSECONDOFDAY INTEGER, ZVALUECLASS INTEGER, ZVALUEINTEGER INTEGER, ZVALUETYPECODE INTEGER, ZSTRUCTUREDMETADATA INTEGER, ZVALUE INTEGER, Z9_VALUE INTEGER, ZIDENTIFIERTYPE INTEGER, ZQUANTITYTYPE INTEGER, ZCREATIONDATE TIMESTAMP, ZLOCALCREATIONDATE TIMESTAMP, ZCONFIDENCE FLOAT, ZENDDATE TIMESTAMP, ZSTARTDATE TIMESTAMP, ZVALUEDOUBLE FLOAT, ZDOUBLEVALUE FLOAT, ZUUID VARCHAR, ZSTREAMNAME VARCHAR, ZVALUESTRING VARCHAR, ZSTRING VARCHAR, ZMETADATA BLOB )",
    "CREATE TABLE ZSOURCE ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZUSERID INTEGER, ZBUNDLEID VARCHAR, ZDEVICEID VARCHAR, ZGROUPID VARCHAR, ZINTENTID VARCHAR, ZITEMID VARCHAR, ZSOURCEID VARCHAR )",
    "CREATE TABLE ZSYNCPEER ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZLASTSEENDATE TIMESTAMP, ZCLOUDID VARCHAR, ZDEVICEID VARCHAR, ZMODEL VARCHAR, ZRAPPORTID VARCHAR, ZVERSION VARCHAR, ZUUID BLOB )",
    # The real table has some 200 metadata columns; these are the ones this module fills.
    "CREATE TABLE ZSTRUCTUREDMETADATA ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, Z_DKBLUETOOTHMETADATAKEY__BATTERYLEVELHEADPHONECASE INTEGER, Z_DKBLUETOOTHMETADATAKEY__BATTERYLEVELHEADPHONELEFT INTEGER, Z_DKBLUETOOTHMETADATAKEY__BATTERYLEVELHEADPHONERIGHT INTEGER, Z_DKBLUETOOTHMETADATAKEY__DEVICETYPE INTEGER, Z_DKBLUETOOTHMETADATAKEY__ISAPPLEAUDIODEVICE INTEGER, Z_DKBLUETOOTHMETADATAKEY__ISUSERWEARING INTEGER, Z_DKBLUETOOTHMETADATAKEY__PRODUCTID INTEGER, Z_DKINTENTMETADATAKEY__DIRECTION INTEGER, Z_DKINTENTMETADATAKEY__DONATEDBYSIRI INTEGER, Z_DKINTENTMETADATAKEY__INTENTHANDLINGSTATUS INTEGER, Z_DKINTENTMETADATAKEY__INTENTTYPE INTEGER, Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__LATITUDE FLOAT, Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__LONGITUDE FLOAT, Z_DKBLUETOOTHMETADATAKEY__ADDRESS VARCHAR, Z_DKBLUETOOTHMETADATAKEY__NAME VARCHAR, Z_DKINTENTMETADATAKEY__INTENTCLASS VARCHAR, Z_DKINTENTMETADATAKEY__INTENTVERB VARCHAR, Z_DKINTENTMETADATAKEY__INTERACTIONIDENTIFIER VARCHAR, Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__CITY VARCHAR, Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__COUNTRY VARCHAR, Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__DISPLAYNAME VARCHAR, Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__FULLYFORMATTEDADDRESS VARCHAR, Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__LOCATIONNAME VARCHAR, Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__POSTALCODE_V2 VARCHAR, Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__THOROUGHFARE VARCHAR, Z_DKNOTIFICATIONUSAGEMETADATAKEY__BUNDLEID VARCHAR, Z_DKNOTIFICATIONUSAGEMETADATAKEY__IDENTIFIER VARCHAR, ZMETADATAHASH VARCHAR, Z_DKINTENTMETADATAKEY__SERIALIZEDINTERACTION BLOB )",
]
KNOWLEDGE_ENTITIES = {"Object": 9, "Event": 11, "Source": 14, "StructuredMetadata": 15, "SyncPeer": 16}


class Knowledge:
    """Appends CoreDuet events to knowledgeC.db."""

    def __init__(self, w: World, con: sqlite3.Connection):
        self.w, self.con = w, con
        for ddl in KNOWLEDGE_DDL:
            ensure_table(con, ddl)
        self.object_pk = next_pk(con, "ZOBJECT")
        self.meta_pk = next_pk(con, "ZSTRUCTUREDMETADATA")
        self.source_pk = next_pk(con, "ZSOURCE")
        self.sources: dict[tuple, int] = {}
        self.metas: dict[tuple, int] = {}

    def source(self, bundle: Optional[str], device: Optional[str]) -> int:
        key = (bundle, device)
        if key not in self.sources:
            self.con.execute("INSERT INTO ZSOURCE (Z_PK, Z_ENT, Z_OPT, ZBUNDLEID, ZDEVICEID) VALUES (?, 14, 1, ?, ?)", (self.source_pk, bundle, device))
            self.sources[key] = self.source_pk
            self.source_pk += 1
        return self.sources[key]

    def meta(self, fields: dict[str, Any], share_key: Optional[tuple] = None) -> int:
        if share_key is not None and share_key in self.metas:
            return self.metas[share_key]
        columns = ["Z_PK", "Z_ENT", "Z_OPT", "ZMETADATAHASH"] + list(fields)
        values = [self.meta_pk, 15, 1, lib.hex_string(self.w.rng, 32)] + list(fields.values())
        self.con.execute(f"INSERT INTO ZSTRUCTUREDMETADATA ({', '.join(columns)}) VALUES ({', '.join('?' for _ in columns)})", values)
        if share_key is not None:
            self.metas[share_key] = self.meta_pk
        self.meta_pk += 1
        return self.meta_pk - 1

    def event(self, stream_name: str, start: datetime.datetime, end: datetime.datetime, source: int, meta: Optional[int],
              integer: Optional[int] = None, string: Optional[str] = None) -> int:
        w = self.w
        ls, le = w.local(start), w.local(end)
        second = lambda t: t.hour * 3600 + t.minute * 60 + t.second   # noqa: E731
        weekday = lambda t: (t.weekday() + 1) % 7 + 1                  # noqa: E731  1 = Sunday
        created = lib.cocoa(end) + w.rng.uniform(0.1, 3.0)
        self.con.execute(
            "INSERT INTO ZOBJECT (Z_PK, Z_ENT, Z_OPT, ZUUIDHASH, ZSOURCE, ZCOMPATIBILITYVERSION, ZENDDAYOFWEEK, ZENDSECONDOFDAY, ZHASCUSTOMMETADATA, "
            "ZHASSTRUCTUREDMETADATA, ZSECONDSFROMGMT, ZSHOULDSYNC, ZSTARTDAYOFWEEK, ZSTARTSECONDOFDAY, ZVALUECLASS, ZVALUEINTEGER, ZVALUETYPECODE, "
            "ZSTRUCTUREDMETADATA, ZCREATIONDATE, ZLOCALCREATIONDATE, ZCONFIDENCE, ZENDDATE, ZSTARTDATE, ZUUID, ZSTREAMNAME, ZVALUESTRING) "
            "VALUES (?, 11, 1, ?, ?, 0, ?, ?, 0, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, 1.0, ?, ?, ?, ?, ?)",
            (self.object_pk, w.rng.getrandbits(62), source, weekday(le), second(le), 1 if meta else 0, int(w.p.tz_offset_hours * 3600),
             weekday(ls), second(ls), 1 if string is None else 3, integer, w.rng.getrandbits(40), meta, created, created,
             lib.cocoa(end), lib.cocoa(start), w.uuid(), stream_name, string))
        self.object_pk += 1
        return self.object_pk - 1


def generic_intent(domain: str, parameters: list[tuple[str, Any]]) -> bytes:
    """A serialized interaction as the reader walks it: a keyed archive that holds the
    intent's protobuf backing store — 2 domain, 4 (repeated) { 1 name, 2 { 1 type,
    2 { 2 string } | 3 { 2 double } } }. The archive's class layout around it is a guess."""
    fields: list[tuple[int, Any]] = [(2, domain)]
    for name, value in parameters:
        if isinstance(value, float):
            fields.append((4, [(1, name), (2, [(1, 2), (3, [(2, value)])])]))
        else:
            fields.append((4, [(1, name), (2, [(1, 1), (2, [(2, str(value))])])]))
    return pb.message(fields)


def write_knowledge(w: World, accessories: dict[str, Accessory], sessions: list) -> None:
    rng, p = w.rng, w.p
    path = lib.library(w.root, "Application Support/Knowledge/knowledgeC.db")
    with shared_db(path) as con:
        k = Knowledge(w, con)
        phone, pad, watch = w.iphone.identifier, w.ipad.identifier, w.watch.identifier

        # Sync peers (hardware model per device identifier), unless another module listed them.
        pk = next_pk(con, "ZSYNCPEER")
        for device, seen_hours, rapport in ((w.iphone, 0.3, True), (w.watch, 1.7, True), (w.ipad, 19.5, False)):
            if con.execute("SELECT 1 FROM ZSYNCPEER WHERE ZDEVICEID = ?", (device.identifier,)).fetchone():
                continue
            con.execute("INSERT INTO ZSYNCPEER (Z_PK, Z_ENT, Z_OPT, ZLASTSEENDATE, ZCLOUDID, ZDEVICEID, ZMODEL, ZRAPPORTID, ZVERSION, ZUUID) VALUES (?, 16, ?, ?, ?, ?, ?, ?, ?, ?)",
                        (pk, rng.randint(40, 900), lib.cocoa(w.clock.ago(hours=seen_hours)), w.uuid(), device.identifier, device.model,
                         w.uuid() if rapport else None, "1", lib.uuid_obj(rng).bytes))
            pk += 1

        # /bluetooth/isConnected — a state stream synced from the phone: value 1 while
        # connected, value 0 for the gaps in between.
        by_device: dict[str, list] = {}
        for start, end, key, host in sessions:
            if host == "iphone" and end is not None and (key == "car" or rng.random() < 0.45):
                by_device.setdefault(key, []).append((start, end))
        for key, spans in by_device.items():
            accessory = accessories[key]
            fields = {
                "Z_DKBLUETOOTHMETADATAKEY__ADDRESS": accessory.address, "Z_DKBLUETOOTHMETADATAKEY__NAME": accessory.name,
                "Z_DKBLUETOOTHMETADATAKEY__DEVICETYPE": accessory.kind, "Z_DKBLUETOOTHMETADATAKEY__PRODUCTID": accessory.product,
                "Z_DKBLUETOOTHMETADATAKEY__ISAPPLEAUDIODEVICE": 1 if accessory.audio else 0,
            }
            meta = k.meta(fields)
            source = k.source(None, phone)
            previous_end = None
            for start, end in spans:
                if previous_end is not None and rng.random() < 0.5:
                    k.event("/bluetooth/isConnected", previous_end, start, source, meta, integer=0)
                k.event("/bluetooth/isConnected", start, end, source, meta, integer=1)
                previous_end = end

        # /app/intents — Maps (and Find My) interactions, mostly from the phone.
        destinations = [
            # place key, name override, category (guess), weight
            ("work", None, "office", 5), ("home", "Home", "", 8), ("cafe", None, "cafe", 6), ("coffee", None, "cafe", 3),
            ("te_papa", None, "museum", 2), ("botanic", None, "park", 3), ("mt_vic", None, "landmark", 2), ("cable_car", None, "landmark", 1),
            ("zealandia", None, "park", 2), ("oriental", None, "beach", 3), ("station", None, "station", 4), ("airport", None, "airport", 3),
            ("gym", None, "gym", 6), ("market", None, "market", 4), ("parents", "Mum & Dad", "", 3), ("auckland", None, "landmark", 1),
            ("queenstown", None, "park", 2), ("rotorua", None, "park", 1),
        ]
        # What was tapped (guess at the vocabulary).
        elements = ["DIRECTIONS", "PLACE_CARD", "SEARCH_RESULT", "SHARE_ETA", "CALL", "WEBSITE"]
        element_weights = [8, 6, 5, 1, 1, 1]
        moments = w.clock.spread(rng, 260, 110, hours=(7, 22), recent_bias=1.4)
        for when in moments:
            key, name, category, _weight = rng.choices(destinations, weights=[d[3] for d in destinations])[0]
            place = p.place(key)
            element = rng.choices(elements, weights=element_weights)[0]
            device = rng.choices([phone, None, watch, pad], weights=[10, 3, 1, 1])[0]
            parameters: list[tuple[str, Any]] = [("Name", name or place.name)]
            if place.street:
                parameters.append(("Street", place.street))
            parameters += [("City", place.city), ("ZIP", place.postal_code), ("Country", place.country), ("element", element)]
            if category:
                parameters.append(("category_type", category))
            parameters += [("source", "MAPS_APP"), ("locale", "en_NZ"), ("resultIndex", float(rng.randint(0, 4))), ("compatibilityVersion", 2.0)]
            verb = "GetDirections" if element in ("DIRECTIONS", "SHARE_ETA") else "ViewPlace"
            interaction = lib.keyed_archive(A("INInteraction", {
                "intent": A("INIntent", {"identifier": w.uuid(), "backingStore": A("INCodable", {"bytes": generic_intent("Maps", parameters)})}),
                "identifier": w.uuid(), "direction": 0, "intentHandlingStatus": 3,
            }))
            meta = k.meta({
                "Z_DKINTENTMETADATAKEY__INTENTCLASS": "INGenericIntent", "Z_DKINTENTMETADATAKEY__INTENTVERB": verb,
                "Z_DKINTENTMETADATAKEY__INTENTHANDLINGSTATUS": 3, "Z_DKINTENTMETADATAKEY__INTENTTYPE": 0, "Z_DKINTENTMETADATAKEY__DIRECTION": 0,
                "Z_DKINTENTMETADATAKEY__DONATEDBYSIRI": 0, "Z_DKINTENTMETADATAKEY__INTERACTIONIDENTIFIER": w.uuid(),
                "Z_DKINTENTMETADATAKEY__SERIALIZEDINTERACTION": interaction,
            })
            k.event("/app/intents", when, when, k.source("com.apple.Maps", device), meta, string="Maps")
        for when in w.clock.spread(rng, 9, 90, hours=(8, 22)):
            element = rng.choice(["DEVICES_TAB", "PEOPLE_TAB", "ITEMS_TAB"])
            interaction = lib.keyed_archive(A("INInteraction", {
                "intent": A("INIntent", {"identifier": w.uuid(), "backingStore": A("INCodable", {"bytes": generic_intent("FindMy", [("element", element), ("source", "FINDMY_APP")])})}),
                "identifier": w.uuid(), "direction": 0, "intentHandlingStatus": 3,
            }))
            meta = k.meta({
                "Z_DKINTENTMETADATAKEY__INTENTCLASS": "INGenericIntent", "Z_DKINTENTMETADATAKEY__INTENTVERB": "OpenFindMy",
                "Z_DKINTENTMETADATAKEY__INTENTHANDLINGSTATUS": 3, "Z_DKINTENTMETADATAKEY__INTERACTIONIDENTIFIER": w.uuid(),
                "Z_DKINTENTMETADATAKEY__SERIALIZEDINTERACTION": interaction,
            })
            k.event("/app/intents", when, when, k.source("com.apple.findmy", phone), meta, string="FindMy")

        # /notification/usage — CoreDuet's own copy of notification events, from the phone and iPad.
        phone_apps = [("com.apple.MobileSMS", 22), ("net.whatsapp.WhatsApp", 14), ("com.apple.mobilemail", 12), ("com.tinyspeck.chatlyio", 9),
                      ("com.burbn.instagram", 7), ("com.apple.mobilecal", 5), ("org.whispersystems.signal", 4), ("com.google.ios.youtube", 3),
                      ("com.apple.reminders", 3), ("com.apple.Fitness", 2), ("com.apple.Passbook", 1.5), ("com.apple.podcasts", 1.5)]
        for when in w.clock.spread(rng, 1650, 60, hours=(7, 23), recent_bias=1.1):
            bundle = rng.choices([a for a, _ in phone_apps], weights=[x for _, x in phone_apps])[0]
            device = phone if rng.random() < 0.88 else pad
            meta = k.meta({"Z_DKNOTIFICATIONUSAGEMETADATAKEY__BUNDLEID": bundle, "Z_DKNOTIFICATIONUSAGEMETADATAKEY__IDENTIFIER": w.uuid()},
                          share_key=("notification", bundle, device))
            k.event("/notification/usage", when, when, k.source(bundle, device), meta, string=bundle)

        # App activities that carry a location (a shared calendar event, a Maps place card).
        activities = [
            ("te_papa", "com.apple.Maps", 47.2), ("botanic", "com.apple.Maps", 20.6), ("airport", "com.apple.mobilecal", TRIP_FIRST + 0.7),
            ("queenstown", "com.apple.Maps", TRIP_FIRST - 1.1), ("gym", "com.apple.mobilecal", 3.3), ("cafe", "com.apple.mobilecal", 5.7),
            ("mt_vic", "com.apple.Maps", 13.4), ("zealandia", "com.apple.Maps", 96.1), ("oriental", "com.apple.Maps", 27.6),
            ("station", "com.apple.Maps", 12.5), ("market", "com.apple.Maps", 6.4), ("cable_car", "com.apple.Maps", 58.0),
            ("auckland", "com.apple.mobilecal", 188.2), ("rotorua", "com.apple.Maps", 143.0),
        ]
        for key, bundle, days in activities:
            place = p.place(key)
            when = w.clock.ago(days=days)
            meta = k.meta({
                "Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__LATITUDE": place.latitude,
                "Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__LONGITUDE": place.longitude,
                "Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__DISPLAYNAME": place.name,
                "Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__LOCATIONNAME": place.name,
                "Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__FULLYFORMATTEDADDRESS": place.address,
                "Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__THOROUGHFARE": place.street,
                "Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__CITY": place.city,
                "Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__POSTALCODE_V2": place.postal_code,
                "Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY__COUNTRY": place.country,
            })
            k.event("/app/locationActivity", when, when + datetime.timedelta(seconds=rng.randint(30, 600)), k.source(bundle, phone), meta, string=bundle)

        ensure_coredata(con, KNOWLEDGE_ENTITIES, rng)


# ----------------------------------------------------------------------------------------
# Microlocation (milod)
# ----------------------------------------------------------------------------------------

#: Real schema of the tables the app reads (milo.db has some twenty more, all unused here).
MILO_DDL = """
CREATE TABLE ZULASSOCIATEDSTATEMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZBAND INTEGER, ZCHANNEL INTEGER, ZISASSOCIATED INTEGER, ZLOI INTEGER, ZTIMESTAMP FLOAT, ZLOIID_DEPRECATED VARCHAR, ZMACADDRESS VARCHAR );
CREATE TABLE ZULBLEMEASUREMENTMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZBLECHANNEL INTEGER, ZDEVICEMODEL INTEGER, ZRSSI INTEGER, ZSCANNINGEVENT INTEGER, ZTIMESTAMP FLOAT, ZSOURCEIDSUUID VARCHAR );
CREATE TABLE ZULBLUETOOTHIDENTITYMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZLASTSEENTIMESTAMP FLOAT, ZBLUETOOTHID VARCHAR, ZDEVICENAME VARCHAR, ZSTABLEIDENTIFIER VARCHAR );
CREATE TABLE ZULCUSTOMLOIMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZLOI INTEGER, ZSERVICE INTEGER, ZLASTSEENTIMESTAMP FLOAT, ZLOIID_DEPRECATED VARCHAR, ZSERVICEID_DEPRECATED VARCHAR );
CREATE TABLE ZULEVENTLOGMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZTIMESTAMP FLOAT, ZEVENT VARCHAR );
CREATE TABLE ZULLABELMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZCONTEXTLAYERTYPE INTEGER, ZDEVICECLASS INTEGER, ZLOI INTEGER, ZSCANNINGEVENT INTEGER, ZSERVICE INTEGER, ZRECEIVEDTIMESTAMP FLOAT, ZLABELID VARCHAR, ZSERVICEUUID_DEPRECATED VARCHAR, ZTRIGGERUUID_DEPRECATED VARCHAR, ZUUID VARCHAR, ZMETADATA BLOB, ZDATA BLOB );
CREATE TABLE ZULLOIMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZISSPARECATEGORY INTEGER, ZLOICATEGORY INTEGER, ZCUSTOMLOI INTEGER, ZLASTSEENTIMESTAMP FLOAT, ZLOIGROUPID VARCHAR, ZLOIID VARCHAR, ZLOITYPE VARCHAR );
CREATE TABLE ZULMIGRATIONMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZSTATE INTEGER, ZTIMESTAMP FLOAT );
CREATE TABLE ZULMODELMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZMODELTYPE INTEGER, ZLOI INTEGER, ZSERVICE INTEGER, ZGENERATIONTIMESTAMP FLOAT, ZLOIID_DEPRECATED VARCHAR, ZMODELUUID VARCHAR, ZSERVICEUUID_DEPRECATED VARCHAR, ZMODEL BLOB, ZRAWMODELDATA BLOB );
CREATE TABLE ZULSCANNINGEVENTMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZBLESUSPENDED INTEGER, ZMOTIONSTATE INTEGER, ZSCANRESULT INTEGER, ZSCANTYPE INTEGER, ZUWBSUSPENDED INTEGER, ZWIFIASSOCIATIONBSSID INTEGER, ZWIFIASSOCIATIONRSSI INTEGER, ZWIFIDISABLED INTEGER, ZLOI INTEGER, ZMAGNETOMETER INTEGER, ZTIMESTAMP FLOAT, ZSCANEVENTUUID VARCHAR );
CREATE TABLE ZULSERVICEMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZLOCATIONTYPES INTEGER, ZSERVICETYPE INTEGER, ZLASTACTIVETIMESTAMP FLOAT, ZCLIENTID VARCHAR, ZSERVICEUUID VARCHAR );
CREATE TABLE ZULWIFIHISTOGRAMMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZLOI INTEGER, ZTIMESTAMP FLOAT, ZHISTOGRAM BLOB );
CREATE TABLE ZULWIFIMEASUREMENTMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZBAND INTEGER, ZCHANNEL INTEGER, ZFLAGS INTEGER, ZRSSI INTEGER, ZSOURCEBSSID INTEGER, ZSCANNINGEVENT INTEGER, ZTIMESTAMP FLOAT );
"""
MILO_ENTITIES = {"ULAssociatedStateMO": 4, "ULBLEMeasurementMO": 5, "ULBluetoothIdentityMO": 6, "ULCustomLoiMO": 9, "ULEventLogMO": 11,
                 "ULLabelMO": 13, "ULLoiMO": 15, "ULMigrationMO": 19, "ULModelMO": 20, "ULScanningEventMO": 28, "ULServiceMO": 30,
                 "ULWiFiHistogramMO": 32, "ULWiFiMeasurementMO": 33}


def write_milo(w: World, accessories: dict[str, Accessory]) -> None:
    rng = w.rng
    path = lib.daemon_container(w.root, "com.apple.milod", rng) / "com.apple.milod" / "milo.db"

    def access_points(associated: int, own: list[tuple[int, float]], others: int) -> list[tuple[int, int, float]]:
        """(bssid, channel, mean RSSI): the network's own radios first, then the neighbours'."""
        out = [(associated if i == 0 else w.mac48(), channel, rssi) for i, (channel, rssi) in enumerate(own)]
        for _ in range(others):
            out.append((w.mac48(), rng.choice([1, 1, 6, 6, 6, 11, 11, 13, 36, 44, 149]), rng.uniform(-90, -62)))
        return out

    sites = {
        "home": access_points(w.bssid["home"], [(44, -47.0), (6, -41.0)], 13),
        "work": access_points(w.bssid["work"], [(149, -52.0), (11, -49.0), (36, -63.0), (1, -60.0), (44, -71.0), (6, -68.0)], 11),
    }
    group = {"home": w.uuid(), "work": w.uuid()}
    loi_pk = {"home": 1, "work": 2}
    service_legacy, service_routing = w.uuid(), w.uuid()
    days = 45

    with lib.sqlite_db(path, MILO_DDL) as con:
        scans, measurements, associations, log = [], [], [], []
        scan_pk = measure_pk = 0
        last_seen: dict[str, datetime.datetime] = {}
        for segment in w.segments:
            if segment.day > days or segment.where not in sites:
                continue
            site = sites[segment.where]
            channel = site[0][1]
            associations.append((segment.start + datetime.timedelta(seconds=rng.randint(4, 30)), site[0][0], channel, 1, loi_pk[segment.where]))
            if not segment.open:
                associations.append((segment.end, site[0][0], channel, 0, loi_pk[segment.where]))
            log.append((segment.start + datetime.timedelta(seconds=rng.randint(30, 90)),
                        f"Changed Loi Event type: {segment.where}, reason:{rng.choice(['Mac screen on notification', 'Database ready'])}, groupId: {group[segment.where]}"))
            cursor = segment.start + datetime.timedelta(minutes=rng.uniform(1, 6))
            while cursor < segment.end:
                scan_pk += 1
                scans.append((scan_pk, 28, 1, 0, 0, 0, rng.choice([0, 0, 0, 1]), 0, site[0][0], int(rng.gauss(site[0][2], 3)), 0,
                              loi_pk[segment.where], None, lib.cocoa(cursor), w.uuid()))
                heard = [site[0]] + [ap for ap in site[1:] if rng.random() < (0.9 if ap[2] > -65 else 0.45)]
                for bssid, ap_channel, mean in heard:
                    measure_pk += 1
                    rssi = max(-96, min(-28, int(round(rng.gauss(mean, 3.5)))))
                    measurements.append((measure_pk, 33, 1, 1 if ap_channel <= 14 else 2, ap_channel, 0, rssi, bssid, scan_pk,
                                         lib.cocoa(cursor) + rng.uniform(0, 1.5)))
                last_seen[segment.where] = cursor
                if rng.random() < 0.06:
                    log.append((cursor + datetime.timedelta(seconds=2), f"Request Prediction Event, serviceId: {service_legacy}, requestId: {w.uuid()}, clientId: milo-internal-legacy-client-name-unsupervised"))
                if rng.random() < 0.05:
                    log.append((cursor + datetime.timedelta(seconds=5), f"Screen State Event isOnLockScreen: {rng.choice(['Yes', 'No'])}"))
                cursor += datetime.timedelta(minutes=rng.uniform(18, 46))
        lib.insert(con, "ZULSCANNINGEVENTMO", scans)
        lib.insert(con, "ZULWIFIMEASUREMENTMO", measurements)
        lib.insert(con, "ZULASSOCIATEDSTATEMO", [
            (i + 1, 4, 1, 1 if channel <= 14 else 2, channel, on, loi, lib.cocoa(when), None, World.mac_text(bssid, separator=""))
            for i, (when, bssid, channel, on, loi) in enumerate(associations)])
        lib.insert(con, "ZULLOIMO", [
            (loi_pk[key], 15, 3, 0, 0, None, lib.cocoa(last_seen.get(key, w.clock.ago(days=1))), group[key], w.uuid(), key) for key in ("home", "work")])
        lib.insert(con, "ZULSERVICEMO", [
            (1, 30, 5, 1, 1, lib.cocoa(w.clock.ago(minutes=38)), "milo-internal-legacy-client-name-unsupervised", service_legacy),
            (2, 30, 9, 1, 4, lib.cocoa(w.clock.ago(minutes=11)), "com.apple.intelligentroutingd", service_routing),
        ])
        # Daemon life-cycle lines, once per day the Mac was used. Version digits invented.
        for d in range(days, -1, -1):
            boot = w.at(d, 7 * 60 + rng.randint(0, 50))
            if boot >= w.now or rng.random() < 0.7:
                continue
            local = w.local(boot)
            offset = local.strftime("%z")
            log.append((boot, "Milo Init Event version: 4.0.2"))
            log.append((boot + datetime.timedelta(seconds=1), f"Milo Connected To Store, version: 4.0.2, boot time: {local:%Y-%m-%d %H:%M:%S}{offset[:3]}:{offset[3:]}"))
            log.append((boot + datetime.timedelta(seconds=3), f"Service Connecting Event, serviceId: {service_routing}, clientId: com.apple.intelligentroutingd"))
            log.append((boot + datetime.timedelta(seconds=3.4), f"Service Connecting Event, serviceId: {service_legacy}, clientId: milo-internal-legacy-client-name-unsupervised"))
            log.append((boot + datetime.timedelta(seconds=9), "Service Status Update Event isMapValid: Yes"))
        models = []
        for index, d in enumerate([43.2, 36.1, 29.3, 22.0, 15.4, 8.1, 1.3]):
            begin = w.clock.ago(days=d)
            log.append((begin, "Learning Begin Event"))
            log.append((begin + datetime.timedelta(seconds=rng.randint(40, 300)), "Learning Completed Event"))
            for model_type in (0, 2):
                models.append((len(models) + 1, 20, 1, model_type, 1 + index % 2, 1, lib.cocoa(begin) + rng.uniform(40, 300), None, w.uuid(), None,
                               w.blob(rng.randint(3000, 26000)), None))
        lib.insert(con, "ZULMODELMO", models)
        log = sorted((entry for entry in log if entry[0] < w.now), key=lambda entry: entry[0])
        lib.insert(con, "ZULEVENTLOGMO", [(i + 1, 11, 1, lib.cocoa(when), text) for i, (when, text) in enumerate(log)])
        identities = [(w.iphone.name, 0.2), (w.watch.name, 0.4), (accessories["airpods"].name, 2.6), (w.ipad.name, 21.0), ("Living Room", 3.1)]
        lib.insert(con, "ZULBLUETOOTHIDENTITYMO", [
            (i + 1, 6, 4, lib.cocoa(w.clock.ago(hours=hours)), w.uuid(), name, w.uuid()) for i, (name, hours) in enumerate(identities)])
        lib.insert(con, "ZULMIGRATIONMO", [(1, 19, 1, 2, lib.cocoa(w.clock.ago(days=310)))])
        ensure_coredata(con, MILO_ENTITIES, rng)


# ----------------------------------------------------------------------------------------
# Devices: Biome sync.db, AirPlay / media route targets
# ----------------------------------------------------------------------------------------

SYNC_EXTRA_DDL = [
    "CREATE TABLE IF NOT EXISTS Metadata (\n key TEXT UNIQUE PRIMARY KEY ON CONFLICT REPLACE NOT NULL,\n value\n)",
    "CREATE TABLE IF NOT EXISTS CRDTLocation (\n id INTEGER primary key,\n stream STRING NOT NULL,\n site STRING NOT NULL,\n day INTEGER NOT NULL,\n state INTEGER NOT NULL\n)",
    "CREATE TABLE IF NOT EXISTS SyncSessionLog (\n session_id BLOB,\n start_timestamp INTEGER,\n end_timestamp INTEGER,\n transport INTEGER,\n reason INTEGER,\n is_reciprocal BOOL,\n time_since_previous_sync INTEGER\n)",
    "CREATE TABLE IF NOT EXISTS SyncMessageLog (\n session_id BLOB,\n message_id INTEGER,\n timestamp INTEGER,\n device_identifier STRING,\n reachable BOOL,\n is_reciprocal BOOL,\n atom_batch_bytes INTEGER\n)",
    "CREATE TABLE IF NOT EXISTS AtomMergedLog (\n session_id BLOB,\n message_id INTEGER,\n stream STRING,\n merge_result INTEGER,\n owning_site_identifier STRING,\n relayed_by_site_identifier STRING,\n synced_at INTEGER,\n event_created_at INTEGER\n)",
]


def write_sync(w: World) -> None:
    rng = w.rng
    path = lib.library(w.root, "Biome/sync/sync.db")
    if not path.exists():
        lib.write_biome_sync_db(w.root, w.p.devices, w.now, rng)
    with shared_db(path) as con:
        for ddl in SYNC_EXTRA_DDL:
            con.execute(ddl)
        empty = lambda table: con.execute(f"SELECT count(*) FROM {table}").fetchone()[0] == 0   # noqa: E731
        remote = [w.iphone, w.watch, w.ipad]
        # Sync sessions: every half hour or so while the Mac is awake, for a month.
        sessions = []
        if empty("SyncSessionLog"):
            previous = None
            for segment in w.segments:
                if segment.day > 30:
                    continue
                cursor = segment.start + datetime.timedelta(minutes=rng.uniform(1, 9))
                while cursor < segment.end:
                    session = lib.uuid_obj(rng).bytes
                    took = rng.uniform(0.3, 6.5)
                    reason = rng.choices([1, 2, 3, 6], weights=[5, 9, 3, 2])[0]
                    since = (cursor - previous).total_seconds() if previous else None
                    sessions.append((session, cursor, took, reason))
                    con.execute("INSERT INTO SyncSessionLog VALUES (?, ?, ?, ?, ?, ?, ?)",
                                (session, lib.cocoa(cursor), lib.cocoa(cursor) + took, rng.choices([2, 3], weights=[4, 1])[0], reason,
                                 1 if reason == 6 else 0, since))
                    previous = cursor
                    cursor += datetime.timedelta(minutes=rng.uniform(14, 55))
        if sessions and empty("SyncMessageLog"):
            for session, when, took, reason in sessions:
                for message, device in enumerate(rng.sample(remote, rng.randint(1, 3))):
                    con.execute("INSERT INTO SyncMessageLog VALUES (?, ?, ?, ?, ?, ?, ?)",
                                (session, message + 1, lib.cocoa(when) + rng.uniform(0, took), device.identifier, 1, 1 if reason == 6 else 0,
                                 rng.randint(200, 48_000)))
        # Events merged into the CRDT-synced streams, by stream and owning device.
        merged_streams = [("AppLaunch", [8, 2, 3]), ("NowPlaying", [5, 3, 1]), ("feedbackSocialHighlights", [2, 0, 1])]
        if sessions and empty("AtomMergedLog"):
            for session, when, took, _reason in sessions:
                for name, weights in merged_streams:
                    for device, weight in zip(remote, weights):
                        for _ in range(sum(1 for _ in range(weight) if rng.random() < 0.22)):
                            stamp = lib.cocoa(when) + rng.uniform(0, took)
                            con.execute("INSERT INTO AtomMergedLog VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                                        (session, rng.randint(1, 3), name, 1, device.identifier, None, stamp, stamp - rng.uniform(20, 5400)))
        if empty("CRDTLocation"):
            today = int(lib.unix(w.now) // 86_400)
            for name, weights in merged_streams:
                for device, weight in zip([w.mac] + remote, [9] + weights):
                    for back in range(28):
                        if weight and rng.random() < min(1.0, 0.35 + weight / 10):
                            con.execute("INSERT INTO CRDTLocation (stream, site, day, state) VALUES (?, ?, ?, ?)", (name, device.identifier, today - back, 1))
        last = lib.cocoa(sessions[-1][1]) if sessions else lib.cocoa(w.clock.ago(minutes=17))
        for key, value in (("LastSyncDate", last), ("LastSyncAttemptDate", last), ("LastCloudKitSyncDate", lib.cocoa(w.clock.ago(hours=5.2))),
                           ("LastCloudKitAttemptDate", lib.cocoa(w.clock.ago(hours=5.2))), ("LastVacuumDate", lib.cocoa(w.clock.ago(days=6.4))),
                           ("CKRecordBackfillCompleted_AppLaunch", 1)):
            if not con.execute("SELECT 1 FROM Metadata WHERE key = ?", (key,)).fetchone():
                con.execute("INSERT INTO Metadata VALUES (?, ?)", (key, value))


#: Real schema of the tables the app reads (the database has some fifteen more).
ROUTING_DDL = """
CREATE TABLE ZIRAVOUTPUTDEVICEMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDEVICESUBTYPE INTEGER, ZDEVICETYPE INTEGER, ZDISCOVEREDOVERINFRA INTEGER, ZDISCOVEREDWITHBROKER INTEGER, ZHASAIRPLAYPROPERTIES INTEGER, ZNODE INTEGER, ZDEVICEID VARCHAR, ZDEVICENAME VARCHAR, ZMODELID VARCHAR );
CREATE TABLE ZIRCANDIDATEMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZCANDIDATESCONTAINER INTEGER, ZFIRSTSEENDATE TIMESTAMP, ZLASTSEENDATE TIMESTAMP, ZLASTUSEDDATE TIMESTAMP, ZCANDIDATEIDENTIFIER VARCHAR );
CREATE TABLE ZIRCANDIDATESCONTAINERMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZREPLAYEVENT INTEGER, ZSERVICE INTEGER );
CREATE TABLE ZIRNODEMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZISLOCAL INTEGER, ZAVOUTPUTDEVICE INTEGER, ZCANDIDATE INTEGER, ZRAPPORTDEVICE INTEGER, ZAVOUTPUDEVICEIDENTIFIER VARCHAR, ZIDSIDENTIFIER VARCHAR, ZRAPPORTIDENTIFIER VARCHAR );
CREATE TABLE ZIRSERVICEMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZSERVICEPACKAGE INTEGER, ZCANDIDATESCONTAINER INTEGER, ZHISTORYCONTAINER INTEGER, ZMILOSERVICE INTEGER, ZREPLAYEVENTCONTAINER INTEGER, ZSTATISTICS INTEGER, ZLASTSEENDATE TIMESTAMP, ZCLIENTIDENTIFIER VARCHAR, ZSERVICEIDENTIFIER VARCHAR );
CREATE TABLE ZIRSTATISTICSMO ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZLASTMILOLSLITEMS INTEGER, ZLASTMILOMODELS INTEGER, ZLASTMILOQUALITY INTEGER, ZLASTMILOQUALITYREASONBITMAP INTEGER, ZNUMBEROFCONTEXTCHANGES INTEGER, ZNUMBEROFCORRECTPICKERCHOICEEVENTS INTEGER, ZNUMBEROFMILOPREDICTIONS INTEGER, ZNUMBEROFMILOPREDICTIONSINUPDATESMODE INTEGER, ZNUMBEROFPICKERCHOICEEVENTS INTEGER, ZTIMEINUPDATESMODEINSECONDS INTEGER, ZSERVICE INTEGER, ZLASTCLEARDATE TIMESTAMP );
"""
ROUTING_ENTITIES = {"IRAVOutputDeviceMO": 2, "IRCandidateMO": 3, "IRCandidatesContainerMO": 4, "IRNodeMO": 15, "IRServiceMO": 21, "IRStatisticsMO": 22}


def write_routing(w: World) -> None:
    rng = w.rng
    path = lib.daemon_container(w.root, "com.apple.intelligentroutingd", rng) / "com.apple.intelligentroutingd" / "intelligentRouting.sqlite"
    partner = w.p.person("partner")
    # name, model identifier, type / subtype codes (guess), found on the local network,
    # first seen (days ago), last seen (hours ago), last used (hours ago or None)
    targets = [
        ("Living Room", "AudioAccessory6,1", 1, 12, True, 430.0, 1.2, 26.0),
        ("Lounge TV", "AppleTV14,1", 2, 13, True, 512.0, 1.2, 47.5),
        ("Kitchen", "AudioAccessory5,1", 1, 12, True, 388.0, 1.3, 170.0),
        ("Robin's AirPods Pro", "AirPodsPro1,2", 3, 0, False, 240.0, 3.4, 3.4),
        (f"{partner.given}'s MacBook Air", "Mac14,2", 2, 16, True, 290.0, 14.0, None),
        ("Kōwhai — Tūī Room", "AppleTV11,1", 2, 13, True, 471.0, 20.5, 212.0),
        ("Kōwhai — Kākā Room", "AppleTV11,1", 2, 13, True, 471.0, 20.5, None),
        ("Mum & Dad's TV", "AirPlay TV", 2, 11, True, 72.3, 72.0 * 24, None),
    ]
    with lib.sqlite_db(path, ROUTING_DDL) as con:
        for index, (name, model, kind, subtype, infra, first, last, used) in enumerate(targets, start=1):
            identifier = w.uuid()
            con.execute("INSERT INTO ZIRCANDIDATEMO VALUES (?, 3, ?, 1, ?, ?, ?, ?)",
                        (index, rng.randint(3, 400), lib.cocoa(w.clock.ago(days=first)), lib.cocoa(w.clock.ago(hours=last)),
                         lib.cocoa(w.clock.ago(hours=used)) if used is not None else None, identifier))
            con.execute("INSERT INTO ZIRNODEMO VALUES (?, 15, 1, 0, ?, ?, NULL, ?, NULL, NULL)", (index, index, index, identifier))
            con.execute("INSERT INTO ZIRAVOUTPUTDEVICEMO VALUES (?, 2, 1, ?, ?, ?, 0, 1, ?, ?, ?, ?)",
                        (index, subtype, kind, 1 if infra else 0, index, identifier, name, model))
        con.execute("INSERT INTO ZIRCANDIDATESCONTAINERMO VALUES (1, 4, 1, NULL, 1)")
        con.execute("INSERT INTO ZIRSERVICEMO VALUES (1, 21, 1, 0, 1, NULL, NULL, NULL, 1, ?, 'com.apple.mediaremoted', ?)",
                    (lib.cocoa(w.clock.ago(minutes=11)), w.uuid()))
        con.execute("INSERT INTO ZIRSTATISTICSMO VALUES (1, 22, ?, 14, 2, 3, 0, ?, ?, ?, ?, ?, ?, 1, ?)",
                    (rng.randint(500, 4000), 1843, 61, 3962, 418, 74, 151_200, lib.cocoa(w.clock.ago(days=212))))
        ensure_coredata(con, ROUTING_ENTITIES, rng)


# ----------------------------------------------------------------------------------------
# Actions: linkd App Intents transcript
# ----------------------------------------------------------------------------------------

def ln_value(value: Any) -> lib.ArchiveObject:
    return A("LNValue", {"value": value, "valueType": None, "displayRepresentation": None, "exportedContent": None})


def ln_property(identifier: str, value: Any) -> lib.ArchiveObject:
    return A("LNProperty", {"identifier": identifier, "value": None if value is None else ln_value(value), "deferred": False})


def ln_entity(type_identifier: str, instance: str, properties: list[tuple[str, Any]]) -> lib.ArchiveObject:
    return A("LNEntity", {
        "identifier": A("LNEntityIdentifier", {"typeIdentifier": type_identifier, "instanceIdentifier": instance,
                                               "bundleIdentifier": None, "stableIdentifier": None, "auditToken": None}),
        "properties": [ln_property(name, value) for name, value in properties],
        "protocolProperties": {}, "managedAccountIdentifier": None, "modelRepresentations": None,
        "prototypeMangledTypeName": None, "persistentFileIdentifiable": False, "transient": False,
    })


def ln_person(person) -> lib.ArchiveObject:
    return A("INPerson", {
        "displayName": person.full_name, "contactIdentifier": person.contact_id, "customIdentifier": None,
        "personHandle": A("INPersonHandle", {"value": person.handle, "type": 2 if person.phone else 1, "label": None,
                                             "emergencyType": 0, "faceTimeType": 0, "suggested": False}),
        "nameComponents": None, "image": None, "relationship": None, "aliases": [], "scoredAlternatives": None, "_userInput": None,
        "contactSuggestion": False, "isMe": False, "searchProvider": 0, "suggestionType": 0,
    })


def transcript_record(w: World, bundle: str, when: datetime.datetime, identifier: str, mangled: str, parameters: list[tuple[str, Any]],
                      protocols: list[str], source: int, open_app: bool) -> tuple[bytes, bytes, list[str]]:
    """(archived LNTranscriptActionRecord, execution UUID bytes, parameter names)."""
    execution = lib.uuid_obj(w.rng)
    action = A("LNAction", {
        "identifier": identifier, "mangledTypeName": mangled, "metadata": None, "url": None, "loopConfiguration": None,
        "explicitAuthenticationPolicy": None, "outputFlags": 0, "outputType": None, "openAppWhenRun": open_app,
        "parameters": [ln_property(name, value) for name, value in parameters],
        "systemProtocols": [A("LNSystemProtocol", {"identifier": "com.apple.link.systemProtocol." + name, "parameters": {}}) for name in protocols],
    })
    record = A("LNTranscriptActionRecord", {
        "bundleIdentifier": bundle, "clientLabel": None, "executionDate": when, "executionUUID": execution,
        "resolvedAction": action, "originalAction": None, "actionOutput": None, "policy": None, "predictions": [],
        "source": source, "duplicateActionData": False,
    })
    return lib.keyed_archive(record), execution.bytes, [name for name, _ in parameters]


#: System Settings panes: title and the pane's extension identifier (public, the same on every Mac).
SETTINGS_PANES = [
    ("Wi-Fi", "com.apple.wifi-settings-extension", 9), ("Bluetooth", "com.apple.BluetoothSettings", 8),
    ("Network", "com.apple.Network-Settings.extension", 4), ("Notifications", "com.apple.Notifications-Settings.extension", 5),
    ("Sound", "com.apple.Sound-Settings.extension", 6), ("Focus", "com.apple.Focus-Settings.extension", 5),
    ("Screen Time", "com.apple.Screen-Time-Settings.extension", 2), ("General", "com.apple.systempreferences.GeneralSettings", 6),
    ("Appearance", "com.apple.Appearance-Settings.extension", 2), ("Displays", "com.apple.Displays-Settings.extension", 7),
    ("Battery", "com.apple.Battery-Settings.extension", 4), ("Privacy & Security", "com.apple.settings.PrivacySecurity.extension", 7),
    ("Passwords", "com.apple.Passwords-Settings.extension", 3), ("Touch ID & Password", "com.apple.Touch-ID-Settings.extension", 2),
    ("Software Update", "com.apple.Software-Update-Settings.extension", 4), ("Storage", "com.apple.settings.Storage", 3),
    ("Keyboard", "com.apple.Keyboard-Settings.extension", 3), ("Trackpad", "com.apple.Trackpad-Settings.extension", 2),
    ("Printers & Scanners", "com.apple.Print-Scan-Settings.extension", 2), ("Wallpaper", "com.apple.Wallpaper-Settings.extension", 2),
    ("Lock Screen", "com.apple.Lock-Screen-Settings.extension", 2), ("Sharing", "com.apple.Sharing-Settings.extension", 2),
    ("Location Services", "com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices", 3),
    ("VPN", "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension", 2),
]


def write_actions_transcript(w: World) -> None:
    rng, p = w.rng, w.p
    person = p.person
    records: dict[str, list] = {}
    biome_copy = []

    def add(bundle: str, when: datetime.datetime, identifier: str, mangled: str, parameters: list[tuple[str, Any]],
            protocols: list[str], source: int = 1, open_app: bool = False) -> None:
        if when >= w.now:
            return
        payload, execution, names = transcript_record(w, bundle, when, identifier, mangled, parameters, protocols, source, open_app)
        records.setdefault(bundle, []).append((when, payload))
        records.setdefault("System", []).append((when, payload))
        # App.Intents.Transcript — 1 bundle id, 2 source, 3 execution UUID bytes, 4 Unix
        # date, 6 resolved action { 1 identifier, 7 parameters { 1 name } }.
        biome_copy.append((when, pb.message([(1, bundle), (2, source), (3, execution), (4, lib.unix(when)),
                                              (6, [(1, identifier)] + [(7, [(1, name)]) for name in names])])))

    # System Settings: every pane navigated to.
    for when in w.working_moments(135, 100):
        title, pane, _weight = rng.choices(SETTINGS_PANES, weights=[x[2] for x in SETTINGS_PANES])[0]
        link = "settings-navigation://" + pane
        target = ln_entity("SettingsNavigationLocationEntity", link, [
            ("settingsHostApplicationBundleIdentifier", "com.apple.systempreferences"),
            ("icon", None),
            ("title", A("INFile", {"data": json.dumps({"key": title, "table": "Localizable", "bundle": "com.apple.systempreferences"}).encode("utf-8"),
                                   "filename": "title.json", "fileURL": None, "typeIdentifier": None, "_bookmarkData": None,
                                   "_itemProviderRequestMetadata": None, "removedOnCompletion": None})),
            ("navigationPathComponents", [title]),
            ("navigationLink", lib.ArchiveURL(link)),
            ("associatedApplicationBundleIdentifier", None),
        ])
        add("com.apple.systempreferences", when, "SettingsNavigationEventDonationIntent", "8Settings0A29NavigationEventDonationIntentV",
            [("target", target)], ["OpenEntity", "URLRepresentable"], open_app=True)

    # Calendar: events opened and edited.
    events = [
        ("Design review", "Work", 60, [person("aroha"), person("lucas")]), ("1:1 with Aroha", "Work", 30, [person("aroha")]),
        ("Sprint planning", "Work", 90, [person("oliver"), person("lucas"), person("hana")]),
        ("Usability sessions — navigation study", "Work", 120, [person("nina")]),
        ("Dentist — Dr Lee", "Personal", 45, []), ("Climbing with Priya", "Personal", 90, [person("priya")]),
        ("Dinner at Mum & Dad's", "Family", 180, [person("mother"), person("father")]),
        ("Flight WLG → ZQN", "Personal", 110, []), ("Tenancy inspection", "Home", 30, [person("landlord")]),
        ("Jamie's birthday", "Family", 240, [person("sister")]), ("Coffee with Tom", "Personal", 45, [person("tom")]),
        ("Payroll cut-off", "Work", 15, []), ("Te Papa — exhibition opening", "Personal", 120, [person("partner")]),
    ]

    def event_entity(when: datetime.datetime) -> lib.ArchiveObject:
        title, calendar, minutes, attendees = rng.choice(events)
        start = (when + datetime.timedelta(hours=rng.randint(2, 96))).replace(minute=rng.choice([0, 0, 30]), second=0, microsecond=0)
        return ln_entity("EventEntity", w.uuid(), [
            ("title", title), ("startDate", start), ("endDate", start + datetime.timedelta(minutes=minutes)), ("isAllDay", False),
            ("recurrence", None), ("startTimeZoneID", p.time_zone), ("endTimeZoneID", p.time_zone), ("location", None),
            ("virtualLocation", None),
            ("calendar", ln_entity("CalendarEntity", w.uuid(), [("title", calendar)])),
            ("status", None), ("alarms", []), ("organizers", []),
            ("attendees", [ln_person(x) for x in attendees]),
            ("url", None), ("participantStatus", None), ("isLikelyImportant", None),
        ])

    for when in w.working_moments(70, 100):
        add("com.apple.iCal", when, "OpenEventDetailsIntent", "12CalendarLink22OpenEventDetailsIntentV",
            [("title", None), ("caption", None), ("target", event_entity(when))],
            ["AssistantIntent", "AssistantInvocableIntent", "OpenEntity"], open_app=True)
    for when in w.working_moments(18, 100):
        add("com.apple.iCal", when, "EditEventIntent", "12CalendarLink15EditEventIntentV",
            [("event", event_entity(when)), ("title", None), ("startDate", None), ("endDate", None), ("isAllDay", None), ("calendar", None),
             ("location", None), ("note", None)],
            ["AssistantIntent", "Undoable", "AssistantInvocableIntent", "RequiresMDMChecks"])

    # Mail: drafts sent, with recipients and subject.
    drafts = [
        ("Re: Tenancy renewal — Aro Street", [person("landlord")], "iCloud"), ("Navigation study — findings draft", [person("aroha"), person("nina")], "Work"),
        ("Re: Design review notes", [person("lucas")], "Work"), ("Leave request, 14–17", [person("aroha")], "Work"),
        ("Re: Dental appointment", [person("drlee")], "iCloud"), ("Queenstown photos", [person("mother"), person("sister")], "iCloud"),
        ("Fwd: Flight itinerary WLG–ZQN", [person("partner")], "iCloud"), ("Re: Salary review", [person("oliver")], "Work"),
        ("Invoice query — power account", [person("landlord")], "iCloud"), ("Re: Saturday climb?", [person("priya"), person("tom")], "iCloud"),
    ]
    for when in w.working_moments(46, 100):
        subject, to, account = rng.choice(drafts)
        target = ln_entity("DraftMessageEntity", w.uuid(), [
            ("to", [x.email for x in to]), ("cc", []), ("bcc", []), ("subject", subject), ("body", None), ("attachments", None),
            ("account", ln_entity("AccountEntity", w.uuid(), [("name", account)])), ("thread", None),
        ])
        add("com.apple.mail", when, "SendDraftIntent", "7MailApp15SendDraftIntentV", [("sendLaterDate", None), ("target", target)],
            ["AssistantIntent", "AssistantInvocableIntent"], open_app=True)

    # Calls answered and ended on the Mac.
    for when in w.working_moments(26, 100):
        caller = p.weighted_person(rng)
        call = ln_entity("LiveCall", w.uuid(), [
            ("status", "active"), ("remoteParticipants", [ln_person(caller)]),
            ("provider", ln_entity("CallProvider", "com.apple.coretelephony", [("name", "FaceTime Audio" if rng.random() < 0.4 else "iPhone")])),
            ("audioVisualMode", "audio"),
        ])
        add("com.apple.calls.PhoneAppIntentsExtension", when, "AnswerCallIntent", "15PhoneAppIntents16AnswerCallIntentV", [("call", call)],
            ["AssistantIntent", "AudioStarting", "AudioRecording"])
        add("com.apple.calls.PhoneAppIntentsExtension", when + datetime.timedelta(seconds=rng.randint(40, 1500)), "EndCallIntent",
            "15PhoneAppIntents13EndCallIntentV", [("call", call)], ["AssistantIntent"])

    # Focus filters: each app is told whenever a Focus with a filter switches on or off.
    for start, end, identifier, _cause, still_on in w.focus_sessions:
        if identifier != MODE_WORK or (w.now - start).days > 45:
            continue
        for when, enabled in ((start, True), (end, False)):
            if not enabled and still_on:
                continue
            stamp = when + datetime.timedelta(seconds=rng.uniform(0.2, 2.5))
            add("com.apple.MobileSMS.MessagesActionExtension", stamp, "ConversationListFocusFilterAction",
                "23MessagesActionExtension027ConversationListFocusFilterB0V", [("enableFocusFiltering", enabled)], ["FocusConfiguration"], source=0)
            add("com.apple.mail", stamp, "MailFocusConfigurationAction", "7MailApp0A24FocusConfigurationActionV",
                [("accounts", ["Work"] if enabled else None)], ["FocusConfiguration"], source=0)
            add("com.apple.calendar.CalendarIntentsExtension", stamp, "SetCalendarFocusConfiguration", "12CalendarLink03SetA18FocusConfigurationV",
                [("calendars", ["Work"] if enabled else None)], ["FocusConfiguration"], source=0)
            add("com.apple.Safari.SafariLinkExtension", stamp, "OpenTabGroupForFocus", "11SafariSwift29OpenProfileOrTabGroupForFocusV",
                [("type", "tabGroup" if enabled else "none"), ("openLinksInTabGroup", enabled), ("profileEntity", None),
                 ("tabGroupEntity", ln_entity("TabGroupEntity", w.uuid(), [("title", "Kōwhai Labs")]) if enabled else None)],
                ["FocusConfiguration"], source=0)

    base = lib.daemon_container(w.root, "com.apple.linkd", rng) / "ActionTranscript"
    for directory, items in records.items():
        lib.write_stream(base / directory, items)
    stream(w, "App.Intents.Transcript", biome_copy)


# ----------------------------------------------------------------------------------------
# Actions: Biome streams
# ----------------------------------------------------------------------------------------

MENUS = {
    "com.apple.Safari": (10, [["File", "New Private Window"], ["File", "New Tab"], ["History", "Reopen Last Closed Tab"], ["Bookmarks", "Add Bookmark…"],
                              ["View", "Show Reader"], ["File", "Export as PDF…"], ["Edit", "Find", "Find…"], ["History", "Clear History…"],
                              ["Develop", "Show Web Inspector"], ["File", "Share", "Mail"]]),
    "com.apple.mail": (8, [["Message", "Reply"], ["Message", "Forward"], ["Mailbox", "Get All New Mail"], ["Message", "Flag", "Red"],
                           ["File", "Save Attachments…"], ["Message", "Move to", "Archive"], ["View", "Sort By", "Date"], ["Message", "Mark", "As Unread"]]),
    "com.apple.finder": (7, [["File", "New Folder"], ["File", "Get Info"], ["Go", "Downloads"], ["Go", "Connect to Server…"], ["View", "as List"],
                             ["Finder", "Empty Trash…"], ["File", "Compress"], ["File", "Move to Trash"], ["Go", "Go to Folder…"]]),
    "com.figma.Desktop": (9, [["Object", "Group Selection"], ["Object", "Add Auto Layout"], ["File", "Export Frames to PDF…"], ["View", "Pixel Grid"],
                              ["Edit", "Paste to Replace"], ["Text", "Bold"], ["Object", "Create Component"], ["File", "Save Local Copy…"]]),
    "com.apple.Notes": (4, [["Format", "Checklist"], ["File", "New Note"], ["File", "Lock Note"], ["Format", "Title"], ["File", "Export as PDF…"]]),
    "com.apple.Preview": (4, [["Tools", "Adjust Size…"], ["File", "Export…"], ["Tools", "Annotate", "Signature", "Manage Signatures…"],
                              ["Tools", "Rotate Left"], ["Tools", "Redact"], ["File", "Print…"]]),
    "com.apple.Terminal": (3, [["Shell", "New Tab", "Basic"], ["Edit", "Clear to Start"], ["Shell", "New Remote Connection…"]]),
    "com.apple.dt.Xcode": (2, [["Product", "Build"], ["Product", "Run"], ["Editor", "Structure", "Re-Indent"]]),
    "com.apple.iCal": (3, [["File", "New Event"], ["View", "Go to Today"], ["File", "New Calendar Subscription…"], ["Edit", "Find"]]),
    "com.apple.Photos": (2, [["File", "Export", "Export Unmodified Original…"], ["Image", "Adjust Date and Time…"], ["Image", "Location", "Hide Location"]]),
    "com.apple.Passwords": (1, [["File", "Export All Passwords to File…"], ["File", "New Password"], ["Edit", "Copy Verification Code"]]),
    "com.apple.Music": (2, [["Controls", "Shuffle", "On"], ["Song", "Add to Playlist", "Focus"], ["File", "Library", "Update Cloud Library"]]),
    "com.apple.Maps": (1, [["File", "Share", "Send to iPhone"], ["View", "Show Traffic"], ["File", "Export as PDF…"]]),
}

#: path below the home folder, content type, opening app (bundle id, location), weight
DOCUMENTS = [
    ("Documents/Kōwhai Labs/Onboarding flow v3.fig", "com.figma.document", "com.figma.Desktop", "/Applications/Figma.app/", 14),
    ("Documents/Kōwhai Labs/Q4 roadmap.key", "com.apple.iwork.keynote.sffkey", "com.apple.iWork.Keynote", "/Applications/Keynote.app/", 6),
    ("Documents/Kōwhai Labs/Navigation study — synthesis.pages", "com.apple.iwork.pages.sffpages", "com.apple.iWork.Pages", "/Applications/Pages.app/", 7),
    ("Documents/Kōwhai Labs/Usability test notes.md", "net.daringfireball.markdown", "com.microsoft.VSCode", "/Applications/Visual Studio Code.app/", 8),
    ("Documents/Kōwhai Labs/Salary review notes.pages", "com.apple.iwork.pages.sffpages", "com.apple.iWork.Pages", "/Applications/Pages.app/", 2),
    ("Documents/Home/Tenancy agreement — Aro Street.pdf", "com.adobe.pdf", "com.apple.Preview", "/System/Applications/Preview.app/", 3),
    ("Documents/Home/Power account — latest bill.pdf", "com.adobe.pdf", "com.apple.Preview", "/System/Applications/Preview.app/", 3),
    ("Documents/Tax/IR3 summary.pdf", "com.adobe.pdf", "com.apple.Preview", "/System/Applications/Preview.app/", 2),
    ("Documents/Health/Dental treatment plan.pdf", "com.adobe.pdf", "com.apple.Preview", "/System/Applications/Preview.app/", 2),
    ("Documents/Identity/Passport scan.pdf", "com.adobe.pdf", "com.apple.Preview", "/System/Applications/Preview.app/", 2),
    ("Downloads/Boarding pass WLG–ZQN.pdf", "com.adobe.pdf", "com.apple.Preview", "/System/Applications/Preview.app/", 2),
    ("Downloads/Queenstown itinerary.pdf", "com.adobe.pdf", "com.apple.Preview", "/System/Applications/Preview.app/", 3),
    ("Downloads/Payslip {month}.pdf", "com.adobe.pdf", "com.apple.Preview", "/System/Applications/Preview.app/", 3),
    ("Downloads/Lakeside Lodge — booking confirmation.pdf", "com.adobe.pdf", "com.apple.Preview", "/System/Applications/Preview.app/", 2),
    ("Desktop/Tararua packing list.txt", "public.plain-text", "com.apple.TextEdit", "/System/Applications/TextEdit.app/", 3),
    ("Pictures/Exports/Mount Victoria sunrise.jpg", "public.jpeg", "com.apple.Preview", "/System/Applications/Preview.app/", 4),
    ("Pictures/Exports/Zealandia kākā.heic", "public.heic", "com.apple.Preview", "/System/Applications/Preview.app/", 3),
    ("Projects/prototype/index.html", "public.html", "com.microsoft.VSCode", "/Applications/Visual Studio Code.app/", 6),
    ("Projects/prototype/README.md", "net.daringfireball.markdown", "com.microsoft.VSCode", "/Applications/Visual Studio Code.app/", 4),
    ("Movies/Climbing — Te Aro.mov", "com.apple.quicktime-movie", "com.apple.QuickTimePlayerX", "/System/Applications/QuickTime Player.app/", 2),
    ("Documents/Recipes/Feijoa loaf.pdf", "com.adobe.pdf", "com.apple.Preview", "/System/Applications/Preview.app/", 2),
    ("Documents/Kōwhai Labs/Design review — recording.mp4", "public.mpeg-4", "com.apple.QuickTimePlayerX", "/System/Applications/QuickTime Player.app/", 2),
]

#: presenting process, requesting client (bundle id, tool or authorization right), weight
AUTH_DIALOGS = [
    ("com.apple.Safari", "com.apple.Safari", 10), ("com.apple.Passwords", "com.apple.Passwords", 7),
    ("com.apple.SecurityAgent", "system.preferences", 5), ("com.apple.SecurityAgent", "system.install.apple-software", 2),
    ("com.apple.Terminal", "sudo", 6), ("com.apple.Notes", "com.apple.Notes", 3), ("com.apple.AppStore", "com.apple.AppStore", 3),
    ("com.apple.systempreferences", "system.preferences.security", 2), ("com.apple.Safari", "com.apple.PassKit.payment", 2),
    ("com.apple.loginwindow", "system.login.screensaver", 4),
]

MAIL_QUERIES = ["boarding pass", "payslip", "tenancy", "invoice", "aroha", "verification code", "queenstown booking", "dentist",
                "password reset", "flight itinerary", "navigation study", "lakeside lodge", "power bill", "receipt", "leave request",
                "from:helen", "ir3", "design review", "insurance renewal", "climbing gym membership", "one-time code 482913",
                "delivery tracking", "has:attachment salary"]
SETTINGS_QUERIES = ["bluetooth", "vpn", "night shift", "printer", "focus", "airdrop", "battery", "keyboard shortcuts", "time machine",
                    "screen time", "location services", "wifi password", "passwords", "hot corners", "default browser", "airplay",
                    "screen recording", "login items", "dictation", "touch id"]


def write_action_streams(w: World) -> None:
    rng, p = w.rng, w.p
    home = USER_HOME + "/"

    # App.MenuItem — 1 bundle id, 3 menu path components.
    bundles = list(MENUS)
    records = []
    for when in w.working_moments(1500, 60):
        bundle = rng.choices(bundles, weights=[MENUS[b][0] for b in bundles])[0]
        paths = MENUS[bundle][1]
        path = paths[min(len(paths) - 1, int(rng.random() ** 1.6 * len(paths)))]
        records.append((when, pb.message([(1, bundle)] + [(3, part) for part in path])))
    stream(w, "App.MenuItem", records)

    # App.DocumentInteraction — 1 interaction type, 2 { 1 path }, 3 content type, 4 { 1 app, 2 app URL }.
    month = (w.local(w.now).replace(day=1) - datetime.timedelta(days=1)).strftime("%B %Y")
    records = []
    for when in w.working_moments(300, 90):
        relative, content_type, bundle, location, _weight = rng.choices(DOCUMENTS, weights=[d[4] for d in DOCUMENTS])[0]
        path = home + relative.format(month=month)
        records.append((when, pb.message([(1, rng.choice([1, 1, 1, 4])), (2, [(1, path)]), (3, content_type),
                                          (4, [(1, bundle), (2, "file://" + location.replace(" ", "%20"))])])))
    stream(w, "App.DocumentInteraction", records)

    # Screenshots.Screenshot — 1 { 1 / 2 / 6 codes, 4 { 1 file path, 3 content hash } }.
    records = []
    for when in w.working_moments(78, 90):
        local = w.local(when)
        hour = local.hour % 12 or 12
        name = f"Screenshot {local:%Y-%m-%d} at {hour}.{local:%M.%S} {'AM' if local.hour < 12 else 'PM'}.png"
        folder = "Desktop/" if rng.random() < 0.8 else "Documents/Kōwhai Labs/Screenshots/"
        records.append((when, pb.message([(1, [(1, rng.choice([1, 1, 2])), (2, 2), (4, [(1, home + folder + name), (3, w.blob(32))]),
                                               (6, rng.choice([1, 2, 3]))])])))
    stream(w, "Screenshots.Screenshot", records)

    # LocalAuthentication.UI.Dialogs — 1 presenting process, 2 requesting client, 3 dialog
    # number, 4 (repeated) / 5 / 6 / 8 codes.
    records = []
    for number, when in enumerate(w.working_moments(96, 100), start=1):
        presenter, requester, _weight = rng.choices(AUTH_DIALOGS, weights=[d[2] for d in AUTH_DIALOGS])[0]
        codes = [(4, 1)] + ([(4, 3)] if rng.random() < 0.6 else [])
        records.append((when, pb.message([(1, presenter), (2, requester), (3, 1000 + number * rng.randint(1, 3)), *codes,
                                          (5, rng.choice([1, 2, 3])), (6, 3), (8, 0)])))
    stream(w, "LocalAuthentication.UI.Dialogs", records)

    # Mail.Search.Query / SystemSettings.SearchTerms — 1 query text, remaining fields flags.
    records = []
    for when in w.working_moments(74, 90):
        query = MAIL_QUERIES[min(len(MAIL_QUERIES) - 1, int(rng.random() ** 1.3 * len(MAIL_QUERIES)))]
        records.append((when, pb.message([(1, query), (2, 0), (3, rng.choice([0, 1])), (4, 0), (5, 1), (6, rng.choice([1, 2])), (7, 0)])))
    stream(w, "Mail.Search.Query", records)
    records = [(when, pb.message([(1, SETTINGS_QUERIES[min(len(SETTINGS_QUERIES) - 1, int(rng.random() ** 1.3 * len(SETTINGS_QUERIES)))])]))
               for when in w.working_moments(44, 100)]
    stream(w, "SystemSettings.SearchTerms", records)

    # App.Intent — 1 Cocoa date, 2 bundle id, 3 source, 4 intent class, 5 verb, 6 / 7 / 10 /
    # 11 codes, 8 archived INInteraction (class layout around the intent is a guess),
    # 9 interaction UUID, 12 item id / handle.
    def donation(when: datetime.datetime, bundle: str, cls: str, verb: str, item: str) -> tuple[datetime.datetime, bytes]:
        identifier = w.uuid()
        interaction = lib.keyed_archive(A("INInteraction", {
            "intent": A("INIntent", {"identifier": w.uuid(), "backingStore": A("INCodable", {"bytes": pb.message([(1, verb), (2, item)])})}),
            "identifier": identifier, "direction": 1, "intentHandlingStatus": 3,
            "dateInterval": A("NSDateInterval", {"NS.startDate": when, "NS.duration": 0.0}),
        }))
        return when, pb.message([(1, lib.cocoa(when)), (2, bundle), (3, "intents"), (4, cls), (5, verb), (6, 1), (7, rng.choice([1, 1, 4])),
                                 (8, interaction), (9, identifier), (10, 0), (11, rng.choice([1, 3])), (12, item)])

    def media() -> str:
        if rng.random() < 0.3:
            show, episode = rng.choice(p.podcasts)
            return f"{show} — {episode}"
        track = rng.choice(p.tracks)
        return f"{track.title} — {track.artist}"

    local, phone, watch = [], [], []
    for when in w.working_moments(240, 75):
        roll = rng.random()
        if roll < 0.55:
            local.append(donation(when, "com.apple.MobileSMS", "INSendMessageIntent", "SendMessage", p.weighted_person(rng).handle))
        elif roll < 0.72:
            local.append(donation(when, rng.choice(["com.apple.Music", "com.apple.podcasts", "com.spotify.client"]), "INPlayMediaIntent", "PlayMedia", media()))
        elif roll < 0.84:
            local.append(donation(when, "com.apple.FaceTime", "INStartCallIntent", "StartCall", p.weighted_person(rng).handle))
        elif roll < 0.93:
            local.append(donation(when, "com.apple.reminders", "INAddTasksIntent", "AddTasks",
                                  rng.choice(["Renew passport", "Book WOF for the car", "Feijoas from the market", "Reply to Chris re: lease", "Chalk + tape"])))
        else:
            local.append(donation(when, "com.apple.Notes", "INCreateNoteIntent", "CreateNote",
                                  rng.choice(["Navigation study — themes", "Queenstown packing", "Gift ideas for Jamie", "Flat inspection checklist"])))
    for when in w.clock.spread(rng, 420, 75, hours=(7, 23), recent_bias=1.2):
        roll = rng.random()
        if roll < 0.45:
            phone.append(donation(when, "com.apple.MobileSMS", "INSendMessageIntent", "SendMessage", p.weighted_person(rng).handle))
        elif roll < 0.63:
            phone.append(donation(when, "net.whatsapp.WhatsApp", "INSendMessageIntent", "SendMessage", p.weighted_person(rng).handle))
        elif roll < 0.76:
            others = [x for x in p.others if x.phone]
            phone.append(donation(when, "com.apple.mobilephone", "INStartCallIntent", "StartCall", rng.choices(others, weights=[x.closeness for x in others])[0].phone))
        elif roll < 0.95:
            phone.append(donation(when, rng.choice(["com.apple.Music", "com.apple.podcasts", "com.spotify.client"]), "INPlayMediaIntent", "PlayMedia", media()))
        else:
            phone.append(donation(when, "org.whispersystems.signal", "INSendMessageIntent", "SendMessage", p.person("partner").handle))
    for start, end, identifier, _cause, _on in w.focus_sessions:
        if identifier == MODE_CLIMBING and (w.now - start).days <= 75:
            watch.append(donation(start + datetime.timedelta(minutes=rng.randint(4, 12)), "com.apple.SessionTrackerApp", "INStartWorkoutIntent", "StartWorkout", "Climbing"))
            watch.append(donation(end - datetime.timedelta(minutes=rng.randint(2, 9)), "com.apple.SessionTrackerApp", "INEndWorkoutIntent", "EndWorkout", "Climbing"))
    stream(w, "App.Intent", local)
    stream(w, "App.Intent", phone, device=w.iphone.identifier)
    stream(w, "App.Intent", [r for r in watch if r[0] < w.now], device=w.watch.identifier)


# ----------------------------------------------------------------------------------------
# Notifications and feature signals
# ----------------------------------------------------------------------------------------

#: bundle id, weight, only during office hours
MAC_NOTIFIERS = [
    ("com.tinyspeck.slackmacgap", 30, True), ("com.apple.MobileSMS", 19, False), ("com.apple.mail", 16, False), ("com.apple.iCal", 8, True),
    ("net.whatsapp.WhatsApp", 9, False), ("com.figma.Desktop", 5, True), ("notion.id", 3, True), ("com.apple.reminders", 3, False),
    ("us.zoom.xos", 2, True), ("com.apple.FaceTime", 1.5, False), ("com.apple.Music", 1, False), ("com.apple.Passwords", 0.6, False),
    ("_SYSTEM_CENTER_:com.apple.SoftwareUpdateNotificationManager", 0.5, False), ("com.apple.findmy", 0.4, False),
]
PHONE_NOTIFIERS = [
    ("com.apple.MobileSMS", 22), ("net.whatsapp.WhatsApp", 15), ("com.apple.mobilemail", 12), ("com.tinyspeck.chatlyio", 10),
    ("com.burbn.instagram", 8), ("com.apple.mobilecal", 5), ("org.whispersystems.signal", 4), ("com.google.ios.youtube", 3),
    ("com.apple.reminders", 3), ("com.apple.Fitness", 2), ("com.apple.Passbook", 1.5), ("com.apple.podcasts", 1.5), ("com.apple.Health", 1),
]

#: signal identifier, context (the app it came from), weight. Identifiers are invented in
#: the reverse-DNS style the stream uses.
SIGNALS = [
    ("com.apple.spotlight.search-performed", "com.apple.Spotlight", 14), ("com.apple.screenshot.taken", "com.apple.screencaptureui", 6),
    ("com.apple.window-tiling.used", "com.apple.dock", 12), ("com.apple.finder.quicklook-used", "com.apple.finder", 11),
    ("com.apple.Safari.reader-shown", "com.apple.Safari", 7), ("com.apple.Safari.private-window-opened", "com.apple.Safari", 5),
    ("com.apple.passwords.autofill-used", "com.apple.Safari", 9), ("com.apple.mail.undo-send-used", "com.apple.mail", 2),
    ("com.apple.mail.remind-me-set", "com.apple.mail", 2), ("com.apple.messages.tapback-sent", "com.apple.MobileSMS", 8),
    ("com.apple.focus.mode-activated", "com.apple.controlcenter", 7), ("com.apple.notes.checklist-created", "com.apple.Notes", 3),
    ("com.apple.continuity.universal-clipboard-pasted", "com.apple.finder", 6), ("com.apple.continuity.iphone-mirroring-started", "com.apple.ScreenContinuity", 3),
    ("com.apple.airdrop.item-received", "com.apple.finder", 2), ("com.apple.Maps.guide-saved", "com.apple.Maps", 1),
    ("com.apple.dictation.started", "com.apple.Notes", 2), ("com.apple.stage-manager.enabled", "com.apple.controlcenter", 1),
    ("com.apple.photos.memory-viewed", "com.apple.Photos", 2), ("com.apple.writing-tools.proofread-used", "com.apple.mail", 3),
]


def write_signals(w: World) -> None:
    rng = w.rng
    usage, delivery, phone = [], [], []
    names = [n for n, _, _ in MAC_NOTIFIERS]
    for d in range(75, -1, -1):
        weekday = w.weekday(d)
        travelling = TRIP_LAST <= d <= TRIP_FIRST
        count = rng.randint(12, 26) if weekday >= 5 or travelling else rng.randint(38, 68)
        for _ in range(count):
            minute = rng.triangular(7 * 60, 23 * 60, 11 * 60 if weekday < 5 else 15 * 60)
            office_hours = weekday < 5 and not travelling and 9 * 60 <= minute <= 17 * 60 + 30
            weights = [weight * (1.0 if not office_only else (1.6 if office_hours else 0.06)) for _, weight, office_only in MAC_NOTIFIERS]
            bundle = rng.choices(names, weights=weights)[0]
            when = w.at(d, minute) + datetime.timedelta(seconds=rng.random() * 60)
            if when >= w.now:
                continue
            identifier = w.uuid()
            # Notification.Usage — 2 Cocoa date, 3 usage type, 4 bundle id, 5 notification UUID.
            delivered = rng.random() < 0.88
            if rng.random() < 0.94:
                usage.append((when, pb.message([(2, lib.cocoa(when)), (3, 1), (4, bundle), (5, identifier)])))
            else:
                delivered = True   # only the delivery was logged
            # Notification.Delivery — 1 notification identifier, 2 bundle id, 3 Unix date.
            if delivered:
                stamp = when + datetime.timedelta(seconds=rng.uniform(-0.4, 1.8))
                delivery.append((stamp, pb.message([(1, identifier), (2, bundle), (3, lib.unix(stamp))])))
    for when in w.clock.spread(rng, 1500, 60, hours=(7, 23), recent_bias=1.1):
        bundle = rng.choices([n for n, _ in PHONE_NOTIFIERS], weights=[x for _, x in PHONE_NOTIFIERS])[0]
        phone.append((when, pb.message([(2, lib.cocoa(when)), (3, 1), (4, bundle), (5, w.uuid())])))
    stream(w, "Notification.Usage", usage)
    stream(w, "Notification.Usage", phone, device=w.iphone.identifier)
    stream(w, "Notification.Delivery", delivery)

    # Discoverability.Signals — 1 signal identifier, 2 context, 3 OS build.
    records = []
    for when in w.working_moments(1150, 90, ("home", "work", "cafe")):
        identifier, context, _weight = rng.choices(SIGNALS, weights=[s[2] for s in SIGNALS])[0]
        records.append((when, pb.message([(1, identifier), (2, context), (3, w.mac.os_build)])))
    stream(w, "Discoverability.Signals", records)


# ----------------------------------------------------------------------------------------

def generate(root: pathlib.Path, persona: Persona, rng: random.Random, now: datetime.datetime) -> None:
    """Create this module's stores below `root` (`lib.library(root, …)`, `lib.system(root, …)`)."""
    w = World(root, persona, rng, now)
    accessories, sessions = bluetooth_sessions(w)
    write_focus(w)
    write_wifi_streams(w)
    write_known_networks(w)
    write_place_stores(w)
    write_bluetooth_streams(w, accessories, sessions)
    write_knowledge(w, accessories, sessions)
    write_milo(w, accessories)
    write_sync(w)
    write_routing(w)
    write_actions_transcript(w)
    write_action_streams(w)
    write_signals(w)
