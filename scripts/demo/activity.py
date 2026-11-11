"""Demo data for the Activity module (`activity`).

Everything here is invented and derived from one simulation of Robin Sample's days, so the
stores agree with each other the way the real ones do:

* a day plan per device (Mac work blocks, phone pick-ups, evening iPad, watch glances)
  -> Biome `App.InFocus` (local + three remote devices), `ScreenTime.AppUsage`,
     knowledgeC `/app/usage` and `/display/isBacklit`, the DuetExpert launch model;
* the Mac's Safari sessions -> knowledgeC `/app/webUsage`, Biome `App.WebUsage`,
  `Safari.Navigations`, `Safari.PageLoad`, `Safari.SearchEngine`;
* listening sittings -> Biome `Media.NowPlaying` (all devices, the watch mirroring the
  phone), `App.MediaUsage`, knowledgeC `/app/mediaUsage`;
* `~/Library/DuetExpertCenter`: `_ATXDataStore.db`, prediction caches, daily dose files,
  the inferred-mode stream; and the Biome view `Games.RecentlyPlayed`.

Shared files (created when missing, otherwise only this module's rows are replaced):
`knowledgeC.db` (streams /app/usage, /app/webUsage, /app/mediaUsage, /display/isBacklit)
and `Biome/sync/sync.db` (left alone when it exists).

Schema (tables, columns, protobuf field numbers) follows the readers in
`Sources/ActivityModule`; content is always invented.
"""

from __future__ import annotations

import datetime
import json
import math
import pathlib
import random
import shutil
import sqlite3
import struct
from typing import Optional

from . import lib
from .lib import pb
from .persona import Persona

DAY = 86_400.0
LOCK = "com.apple.loginwindow"
IOS_LOCK = "com.apple.springboard.lock-screen"
IOS_HOME = "com.apple.springboard.home-screen"
WATCH_FACE = "com.apple.carousel.clock"

MAC_DAYS = 120
PHONE_DAYS = 90
PAD_DAYS = 60
WATCH_DAYS = 45
KNOWLEDGE_DAYS = 28          # knowledgeC keeps about four weeks
SCREENTIME_DAYS = 45

KNOWLEDGE_STREAMS = ("/app/usage", "/app/webUsage", "/app/mediaUsage", "/display/isBacklit")
BIOME_STREAMS = ("App.InFocus", "ScreenTime.AppUsage", "Media.NowPlaying", "App.MediaUsage", "App.WebUsage",
                 "Safari.Navigations", "Safari.PageLoad", "Safari.SearchEngine")


# --------------------------------------------------------------------------------------
# Calendar helper (the persona's fixed UTC offset; no tzdata needed)
# --------------------------------------------------------------------------------------

class Days:
    def __init__(self, now: datetime.datetime, offset_hours: float):
        self.now = lib.unix(now)
        self.offset = offset_hours * 3600.0
        self.today = math.floor((self.now + self.offset) / DAY) * DAY - self.offset
        local_hour = (self.now - self.today) / 3600.0
        # Until late afternoon (local) the data ends last night, so that the most recent
        # day — the one the timeline opens on — always has a working day's worth of records.
        self.end = self.now if local_hour >= 16 else self.today - 50 * 60
        self.last_day = 0 if local_hour >= 16 else 1

    def start(self, days_ago: int) -> float:
        return self.today - days_ago * DAY

    def at(self, days_ago: int, hour: float) -> float:
        return self.start(days_ago) + hour * 3600.0

    def weekday(self, days_ago: int) -> int:
        """0 = Monday … 6 = Sunday (local)."""
        number = int((self.today + self.offset) // DAY) - days_ago
        return (number + 3) % 7

    def is_weekend(self, days_ago: int) -> bool:
        return self.weekday(days_ago) >= 5

    def local_hour(self, t: float) -> int:
        return int(((t + self.offset) % DAY) // 3600)

    def local_dow_sunday1(self, t: float) -> int:
        """1 = Sunday … 7 = Saturday, as Calendar / CoreDuet count."""
        number = int((t + self.offset) // DAY)
        return (number + 4) % 7 + 1

    def second_of_day(self, t: float) -> int:
        return int((t + self.offset) % DAY)


def _lognormal(rng: random.Random, median: float, sigma: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, median * math.exp(rng.gauss(0, sigma))))


# --------------------------------------------------------------------------------------
# Day simulation -> sessions (start, end, bundle) per device
# --------------------------------------------------------------------------------------

Session = tuple  # (start unix, end unix, bundle id)

#: Mac apps: (weight while working, weight in the evening / at weekends, median seconds in front per visit).
_MAC_USE = {
    "com.figma.Desktop": (7, 0.3, 300), "com.apple.Safari": (8, 9, 150), "com.tinyspeck.slackmacgap": (9, 0.5, 75),
    "com.apple.mail": (6, 3, 65), "com.microsoft.VSCode": (2.2, 0.5, 320), "com.apple.dt.Xcode": (1.3, 0.3, 340),
    "com.apple.Terminal": (2.4, 0.5, 80), "notion.id": (3.5, 0.3, 190), "us.zoom.xos": (0.3, 0.02, 1500),
    "com.apple.iCal": (2.6, 0.8, 28), "com.apple.Notes": (2.8, 2, 85), "com.apple.reminders": (0.9, 1, 22),
    "com.apple.MobileSMS": (4, 6, 45), "net.whatsapp.WhatsApp": (0.8, 4, 45), "com.apple.Music": (2, 3, 18),
    "com.spotify.client": (1.4, 2, 18), "com.apple.podcasts": (0.15, 1, 25), "com.apple.Photos": (0.3, 3, 160),
    "com.apple.Preview": (2, 1, 60), "com.apple.finder": (4, 3, 16), "com.apple.systempreferences": (0.4, 0.6, 35),
    "com.apple.FaceTime": (0.04, 0.5, 600), "com.apple.weather": (0.6, 1.2, 18), "com.apple.iBooksX": (0.04, 1.2, 600),
    "com.apple.freeform": (0.9, 0.3, 230), "com.apple.shortcuts": (0.25, 0.3, 30), "com.apple.Maps": (0.25, 1.2, 70),
}
#: "after A you usually open B": gives the transition views a recognisable structure.
_FOLLOWS = {
    "com.tinyspeck.slackmacgap": ("com.figma.Desktop", "com.apple.Safari"),
    "com.apple.mail": ("com.apple.iCal", "com.apple.Safari"),
    "com.figma.Desktop": ("com.tinyspeck.slackmacgap", "com.apple.Preview"),
    "com.apple.Terminal": ("com.microsoft.VSCode", "com.apple.Safari"),
    "com.microsoft.VSCode": ("com.apple.Terminal", "com.apple.Safari"),
    "com.apple.dt.Xcode": ("com.apple.Terminal", "com.apple.Safari"),
    "com.apple.finder": ("com.apple.Preview", "com.figma.Desktop"),
    "com.apple.iCal": ("us.zoom.xos", "com.apple.mail"),
    "notion.id": ("com.figma.Desktop", "com.tinyspeck.slackmacgap"),
    "com.apple.MobileSMS": ("com.apple.Safari", "com.apple.Photos"),
}


def _mac_blocks(days: Days, rng: random.Random, d: int, force: bool = False) -> list[tuple[float, float, bool]]:
    """(start, end, is work) blocks during which the Mac is in use on local day `d`."""
    out: list[tuple[float, float, bool]] = []
    weekday = days.weekday(d)
    if weekday < 5:
        if rng.random() < 0.06 and not force:          # a day off
            if rng.random() < 0.5:
                out.append((days.at(d, rng.uniform(19.3, 20.5)), 0, False))
                out[-1] = (out[-1][0], out[-1][0] + rng.uniform(35, 90) * 60, False)
            return out
        morning = days.at(d, rng.gauss(8.65, 0.3))
        lunch = days.at(d, rng.gauss(12.25, 0.25))
        back = lunch + rng.uniform(32, 62) * 60
        leave = days.at(d, rng.gauss(17.55 if weekday < 4 else 16.6, 0.4))
        # One or two short breaks away from the desk per half day.
        for a, b in ((morning, lunch), (back, leave)):
            cursor = a
            while b - cursor > 95 * 60 and rng.random() < 0.75:
                pause = cursor + rng.uniform(55, 90) * 60
                if pause > b - 20 * 60:
                    break
                out.append((cursor, pause, True))
                cursor = pause + rng.uniform(4, 14) * 60
            out.append((cursor, b, True))
        if rng.random() < 0.42 or force:
            evening = days.at(d, rng.gauss(20.3, 0.55))
            out.append((evening, evening + rng.uniform(30, 105) * 60, False))
    else:
        if rng.random() < 0.62 or force:
            start = days.at(d, rng.gauss(10.0, 0.8))
            out.append((start, start + rng.uniform(35, 110) * 60, False))
        if rng.random() < 0.55 or force:
            start = days.at(d, rng.gauss(19.8, 0.9))
            out.append((start, start + rng.uniform(40, 125) * 60, False))
    return [b for b in out if b[1] - b[0] > 240]


def _simulate_mac(persona: Persona, days: Days, rng: random.Random):
    apps = persona.apps_on("mac")
    sessions: list[Session] = []
    blocks: list[tuple[float, float]] = []
    for d in range(MAC_DAYS, days.last_day - 1, -1):
        for start, end, work in _mac_blocks(days, rng, d, force=d == days.last_day):
            if start >= days.end:
                continue
            end = min(end, days.end)
            if blocks and start < blocks[-1][1] + 120:
                continue
            base = [_MAC_USE.get(a.bundle_id, (a.weight * 0.5, a.weight * 0.5, 60))[0 if work else 1] for a in apps]
            t = start
            previous = ""
            while t < end - 8:
                weights = list(base)
                for i, a in enumerate(apps):
                    if a.bundle_id == previous:
                        weights[i] = 0
                    elif a.bundle_id in _FOLLOWS.get(previous, ()):
                        weights[i] *= 4.5
                app = rng.choices(apps, weights=weights)[0]
                median = _MAC_USE.get(app.bundle_id, (1, 1, 60))[2]
                if median >= 600:
                    length = _lognormal(rng, median, 0.5, 120, 3300 + rng.uniform(0, 600))
                else:
                    length = _lognormal(rng, median, 1.0, 2.5, 1500 + rng.uniform(0, 1500))
                stop = min(end, t + length)
                if stop - t >= 2:
                    sessions.append((t, stop, app.bundle_id))
                previous = app.bundle_id
                t = stop + (rng.uniform(0.2, 1.8) if rng.random() < 0.15 else 0.0)
            blocks.append((start, end))
    return sessions, blocks


_PHONE_HOURS = [0.1, 0.05, 0.02, 0.02, 0.03, 0.1, 0.8, 2.6, 2.4, 1.2, 1.1, 1.3, 2.6, 2.0, 1.1, 1.2, 1.4, 2.5, 2.7, 2.3, 2.6, 2.9, 2.2, 0.7]
_PHONE_BOOST = {"com.apple.MobileSMS": 1.6, "net.whatsapp.WhatsApp": 1.4, "com.burbn.instagram": 1.5, "com.apple.camera": 0.8,
                "com.apple.Preferences": 0.6, "com.apple.Passbook": 0.7, "com.apple.Health": 0.7, "us.zoom.videomeetings": 0.12,
                "com.apple.iBooks": 0.45, "com.google.ios.youtube": 0.8}
_PHONE_LONG = {"com.google.ios.youtube": 240, "com.burbn.instagram": 170, "com.apple.mobilesafari": 120, "com.apple.iBooks": 420,
               "com.apple.podcasts": 40, "com.apple.Music": 30, "com.spotify.client": 35, "com.apple.mobilephone": 150,
               "us.zoom.videomeetings": 700, "com.apple.Maps": 110, "com.google.Maps": 100, "com.apple.camera": 35}


def _simulate_phone(persona: Persona, days: Days, rng: random.Random, end: float):
    apps = persona.apps_on("iphone")
    weights = [a.weight * _PHONE_BOOST.get(a.bundle_id, 1.0) for a in apps]
    sessions: list[Session] = []
    for d in range(PHONE_DAYS, days.last_day - 1, -1):
        weekend = days.is_weekend(d)
        pickups = int(rng.gauss(64 if weekend else 56, 9))
        hours = list(_PHONE_HOURS)
        if weekend:
            hours[6] *= 0.2; hours[7] *= 0.4; hours[9] *= 1.6; hours[10] *= 1.7; hours[14] *= 1.6; hours[15] *= 1.6
        times = sorted(days.at(d, h + rng.random()) for h in rng.choices(range(24), weights=hours, k=max(10, pickups)))
        cursor = sessions[-1][1] if sessions else times[0] - 600
        for t in times:
            if t >= end:
                break
            t = max(t, cursor + 20)
            if cursor < t:
                sessions.append((cursor, t, IOS_LOCK))
            if rng.random() < 0.55:
                glance = rng.uniform(1.5, 7)
                sessions.append((t, t + glance, IOS_HOME))
                t += glance
            previous = ""
            for _ in range(rng.choices((1, 2, 3, 4), weights=(52, 30, 13, 5))[0]):
                app = rng.choices(apps, weights=weights)[0]
                if app.bundle_id == previous:
                    continue
                length = _lognormal(rng, _PHONE_LONG.get(app.bundle_id, 38), 0.95, 2.5, 1500 + rng.uniform(0, 1200))
                sessions.append((t, t + length, app.bundle_id))
                t += length
                previous = app.bundle_id
                if rng.random() < 0.3:
                    hop = rng.uniform(1, 4)
                    sessions.append((t, t + hop, IOS_HOME))
                    t += hop
            cursor = t
    return [s for s in sessions if s[1] <= end]


def _simulate_pad(persona: Persona, days: Days, rng: random.Random, end: float):
    apps = persona.apps_on("ipad")
    boost = {"com.apple.iBooks": 3.0, "com.google.ios.youtube": 2.2, "com.apple.freeform": 2.0, "com.apple.mobilesafari": 0.8,
             "com.apple.mobilemail": 0.4, "com.apple.Preferences": 0.4}
    weights = [a.weight * boost.get(a.bundle_id, 1.0) for a in apps]
    sessions: list[Session] = []
    for d in range(PAD_DAYS, days.last_day - 1, -1):
        weekend = days.is_weekend(d)
        sittings = []
        if rng.random() < (0.7 if weekend else 0.5):
            sittings.append(days.at(d, rng.gauss(20.9, 0.6)))
        if weekend and rng.random() < 0.5:
            sittings.append(days.at(d, rng.gauss(14.5, 1.2)))
        for start in sorted(sittings):
            if sessions and start < sessions[-1][1] + 600:
                continue
            stop = start + rng.uniform(14, 55) * 60
            if stop >= end:
                continue
            sessions.append((start - rng.uniform(2, 6), start, IOS_HOME))
            t = start
            previous = ""
            while t < stop:
                app = rng.choices(apps, weights=weights)[0]
                if app.bundle_id == previous:
                    continue
                length = _lognormal(rng, 330 if app.category == "media" else 150, 0.9, 6, 1500 + rng.uniform(0, 1200))
                sessions.append((t, min(stop, t + length), app.bundle_id))
                t = min(stop, t + length)
                previous = app.bundle_id
                if t < stop and rng.random() < 0.4:
                    hop = rng.uniform(1.5, 5)
                    sessions.append((t, t + hop, IOS_HOME))
                    t += hop
    return sessions


def _simulate_watch(persona: Persona, days: Days, rng: random.Random, end: float):
    apps = [a for a in persona.apps_on("watch") if a.bundle_id != "com.apple.SessionTrackerApp"]
    weights = [a.weight for a in apps]
    sessions: list[Session] = []
    workouts: list[tuple[float, float]] = []
    for d in range(WATCH_DAYS, days.last_day - 1, -1):
        weekday = days.weekday(d)
        day: list[Session] = []
        if weekday in (1, 3) and rng.random() < 0.85:       # climbing after work
            start = days.at(d, rng.gauss(18.2, 0.25))
            day.append((start, start + rng.uniform(48, 75) * 60, "com.apple.SessionTrackerApp"))
        elif weekday == 5 and rng.random() < 0.8:            # Saturday walk or run
            start = days.at(d, rng.gauss(9.1, 0.5))
            day.append((start, start + rng.uniform(35, 95) * 60, "com.apple.SessionTrackerApp"))
        workouts += [(s, e) for s, e, _ in day]
        for _ in range(int(rng.gauss(17, 4))):
            t = days.at(d, rng.choices(range(24), weights=_PHONE_HOURS)[0] + rng.random())
            app = rng.choices(apps, weights=weights)[0]
            day.append((t, t + _lognormal(rng, 11, 0.7, 3, 95), app.bundle_id))
        day.sort()
        cursor = sessions[-1][1] if sessions else 0.0
        for s, e, b in day:
            if s < cursor + 5 or e >= end:
                continue
            glance = rng.uniform(1.5, 4)
            sessions.append((s - glance, s, WATCH_FACE))
            sessions.append((s, e, b))
            cursor = e
    return sessions, workouts


# --------------------------------------------------------------------------------------
# App.InFocus / ScreenTime.AppUsage
# --------------------------------------------------------------------------------------

def _versions(bundles, rng: random.Random) -> dict:
    out = {}
    for b in sorted(set(bundles)):
        major = rng.randint(1, 18)
        out[b] = (f"{major}.{rng.randint(0, 6)}", f"{rng.randint(100, 9999)}.{rng.randint(1, 30)}.{rng.randint(1, 20)}")
    return out


def _focus_records(sessions, versions, rng: random.Random, lock_between: Optional[str], tail_lock: Optional[float]):
    """Start / stop records for consecutive sessions. With `lock_between`, the gaps between
    sessions (more than 30 s) are filled with that lock surface, as the Mac's login window
    does; a few stop records are left out, as in real streams (the next start implies them)."""
    records = []

    def emit(t: float, bundle: str, starting: bool) -> None:
        short, build = versions.get(bundle, ("", ""))
        system = bundle in (LOCK, IOS_LOCK, IOS_HOME, WATCH_FACE)
        records.append((t, pb.message([
            (2, 3 if bundle.startswith("com.apple.springboard") or bundle.startswith("com.apple.carousel") else 1),
            (3, starting), (4, pb.double(lib.cocoa(t))), (6, bundle),
            (9, None if system else short), (10, None if system else build), (13, 0),
        ])))

    previous_end: Optional[float] = None
    previous_bundle = ""
    for start, end, bundle in sessions:
        if previous_end is not None:
            gap = start - previous_end
            if lock_between and gap > 30:
                emit(previous_end, lock_between, True)
                emit(start, lock_between, False)
            elif gap <= 0.01 and previous_bundle and rng.random() < 0.03:
                records.pop()      # the previous stop got lost; this start implies it
        emit(start, bundle, True)
        emit(end, bundle, False)
        previous_end, previous_bundle = end, bundle
    if lock_between and previous_end is not None and tail_lock is not None:
        emit(previous_end, lock_between, True)       # locked since the last block, still locked
    return records


def _screentime_records(sessions, blocks_end: list[float]):
    records = []
    ends = set(blocks_end)
    for start, end, bundle in sessions:
        for t, starting in ((start, True), (end, False)):
            records.append((t, pb.message([(1, starting), (2, pb.double(t)), (3, bundle), (5, 0)])))
        if end in ends:
            records.append((end, pb.message([(1, True), (2, pb.double(end)), (3, LOCK), (5, 0)])))
    return records


# --------------------------------------------------------------------------------------
# Web pages (Safari on the Mac)
# --------------------------------------------------------------------------------------

def _pages(rng: random.Random, days: Days) -> list[tuple[str, str, str, float, float]]:
    """(host, registrable domain, url, weight, median seconds). Public sites with generic
    paths; everything personal-looking lives on the reserved example.* domains."""
    month = datetime.datetime.fromtimestamp(days.end - 20 * DAY, lib.UTC).strftime("%Y-%m")
    video = lambda: "".join(rng.choice("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789-_") for _ in range(11))
    question = lambda slug: f"https://stackoverflow.com/questions/{rng.randint(1_000_000, 79_000_000)}/{slug}"
    rows = [
        ("en.wikipedia.org", "wikipedia.org", "https://en.wikipedia.org/wiki/Wellington", 2.0, 80),
        ("en.wikipedia.org", "wikipedia.org", "https://en.wikipedia.org/wiki/New_Zealand_kaka", 1.2, 110),
        ("en.wikipedia.org", "wikipedia.org", "https://en.wikipedia.org/wiki/Typography", 1.5, 140),
        ("en.wikipedia.org", "wikipedia.org", "https://en.wikipedia.org/wiki/Golden_ratio", 0.8, 90),
        ("en.wikipedia.org", "wikipedia.org", "https://en.wikipedia.org/wiki/Tararua_Range", 1.0, 120),
        ("en.wikipedia.org", "wikipedia.org", "https://en.wikipedia.org/wiki/Claude_Debussy", 0.6, 100),
        ("en.wikipedia.org", "wikipedia.org", "https://en.wikipedia.org/wiki/Bouldering", 0.9, 100),
        ("github.com", "github.com", "https://github.com/notifications", 2.4, 45),
        ("github.com", "github.com", "https://github.com/pulls", 2.0, 70),
        ("github.com", "github.com", "https://github.com/issues/assigned", 1.2, 60),
        ("github.com", "github.com", "https://github.com/search?q=design+tokens&type=repositories", 0.8, 90),
        ("www.youtube.com", "youtube.com", "https://www.youtube.com/", 1.5, 60),
        ("www.youtube.com", "youtube.com", "https://www.youtube.com/results?search_query=figma+auto+layout", 0.8, 50),
        ("www.youtube.com", "youtube.com", f"https://www.youtube.com/watch?v={video()}", 1.6, 420),
        ("www.youtube.com", "youtube.com", f"https://www.youtube.com/watch?v={video()}", 1.2, 520),
        ("www.youtube.com", "youtube.com", f"https://www.youtube.com/watch?v={video()}", 0.9, 300),
        ("www.metservice.com", "metservice.com", "https://www.metservice.com/towns-cities/locations/wellington", 2.6, 35),
        ("www.metservice.com", "metservice.com", "https://www.metservice.com/marine/regions/wellington", 0.7, 40),
        ("www.doc.govt.nz", "doc.govt.nz", "https://www.doc.govt.nz/parks-and-recreation/places-to-go/wellington-kapiti/", 1.0, 120),
        ("www.doc.govt.nz", "doc.govt.nz", "https://www.doc.govt.nz/parks-and-recreation/things-to-do/huts/", 0.7, 140),
        ("www.bbc.com", "bbc.com", "https://www.bbc.com/news", 2.0, 90),
        ("www.bbc.com", "bbc.com", "https://www.bbc.com/news/science_and_environment", 0.9, 150),
        ("www.bbc.com", "bbc.com", "https://www.bbc.com/sport/rugby-union", 0.7, 100),
        ("stackoverflow.com", "stackoverflow.com", question("swiftui-list-row-separator-inset"), 0.9, 130),
        ("stackoverflow.com", "stackoverflow.com", question("css-grid-auto-fit-vs-auto-fill"), 0.9, 110),
        ("stackoverflow.com", "stackoverflow.com", question("git-rebase-onto-explained"), 0.6, 150),
        ("developer.apple.com", "apple.com", "https://developer.apple.com/design/human-interface-guidelines/", 1.6, 200),
        ("developer.apple.com", "apple.com", "https://developer.apple.com/documentation/swiftui", 1.0, 170),
        ("www.openstreetmap.org", "openstreetmap.org", "https://www.openstreetmap.org/#map=15/-41.2900/174.7770", 0.8, 70),
        ("archive.org", "archive.org", "https://archive.org/details/texts", 0.5, 120),
        # Kōwhai Labs intranet (reserved domain).
        ("intranet.example.org", "example.org", "https://intranet.example.org/home", 2.2, 40),
        ("intranet.example.org", "example.org", "https://intranet.example.org/people/aroha-ngata", 0.6, 45),
        ("intranet.example.org", "example.org", "https://intranet.example.org/leave/request?type=annual", 0.5, 120),
        ("intranet.example.org", "example.org", f"https://intranet.example.org/payroll/payslips/{month}", 0.5, 70),
        ("intranet.example.org", "example.org", "https://intranet.example.org/roadmap/design-system", 1.4, 210),
        ("mail.example.com", "example.com", "https://mail.example.com/inbox", 1.8, 95),
        # Things one would not expect to be kept — all invented, all on reserved domains.
        ("bank.example.com", "example.com", "https://bank.example.com/accounts/everyday/transactions", 0.9, 85),
        ("accounts.example.com", "example.com", "https://accounts.example.com/verify?code=482913", 0.25, 20),
        ("fly.example.com", "example.com", "https://fly.example.com/boarding-pass?pnr=K7QX2M&flight=XZ412&from=WLG&to=ZQN", 0.3, 60),
        ("shop.example.com", "example.com", "https://shop.example.com/orders/NZ-48213/track", 0.5, 40),
        ("www.example.com", "example.com", "https://www.example.com/search?q=lower+back+pain+desk+job", 0.45, 30),
        ("www.example.com", "example.com", "https://www.example.com/search?q=how+to+ask+for+a+pay+rise", 0.35, 30),
        ("health.example.net", "example.net", "https://health.example.net/patient-portal/results", 0.35, 100),
        ("booking.example.net", "example.net", "https://booking.example.net/harbour-street-dental/appointments/confirm?ref=HSD-48213", 0.3, 50),
        ("homes.example.net", "example.net", "https://homes.example.net/listing/aro-valley-two-bedroom-villa", 0.6, 160),
        ("homes.example.net", "example.net", "https://homes.example.net/mortgage-calculator?deposit=80000", 0.3, 120),
    ]
    return rows


def _web_visits(sessions, pages, rng: random.Random):
    """Splits each Safari session into page visits: (start, end, tab uuid, page)."""
    weights = [p[3] for p in pages]
    visits = []
    for start, end, bundle in sessions:
        if bundle != "com.apple.Safari" or end - start < 8:
            continue
        tab = lib.uuid_string(rng)
        t = start
        while t < end - 4:
            page = rng.choices(pages, weights=weights)[0]
            stop = min(end, t + _lognormal(rng, page[4], 0.8, 5, 2400))
            if end - stop < 6:
                stop = end
            visits.append((t, stop, tab, page))
            t = stop
            if rng.random() < 0.3:
                tab = lib.uuid_string(rng)
    return visits


# --------------------------------------------------------------------------------------
# Media
# --------------------------------------------------------------------------------------

AUDIO = "kMRMediaRemoteNowPlayingInfoTypeAudio"
VIDEO = "kMRMediaRemoteNowPlayingInfoTypeVideo"
PODCAST = "MRMediaRemoteMediaTypePodcast"

#: Extra invented episodes for the persona's (invented) podcast shows.
_EPISODES = {
    "The Design Detail Hour": ["Episode 113: Tokens all the way down", "Episode 114: Critique without tears", "Episode 115: The grid is a lie"],
    "Slow News Weekly": ["Long read: the ferry timetable", "What happened to the weekend paper"],
    "Trail Notes": ["Kapiti Island day trip", "Packing light for three days"],
    "Birdsong Aotearoa": ["Tūī at dawn", "Counting kererū"],
    "Everyday Science": ["Why the wind never stops in Wellington", "How noise-cancelling works"],
}
#: Page / clip titles that browsers and video apps publish as "now playing" (all invented).
_CLIPS = [
    "Figma auto layout in 12 minutes", "Kākā feeding at Zealandia (4K)", "Lower back pain: 10 minute desk routine",
    "How to ask for a pay rise — a designer's guide", "First home buyers: what a deposit really needs to be",
    "Tararua Southern Crossing in one day", "Sourdough for people with no patience", "Variable fonts explained",
    "Wellington to Picton ferry, full crossing timelapse", "Bouldering technique: heel hooks", "Slow TV: rain on a tin roof, 3 hours",
    "Design systems at small companies — conference talk", "How tides work (animated)", "Queenstown in winter: a weekend itinerary",
    "Te Reo Māori for beginners: lesson 4", "Why your sleep tracker is probably wrong",
]


def _media_catalogue(persona: Persona, rng: random.Random):
    tracks = list(persona.tracks)
    favourites = {"Tess Aldridge": 2.6, "Kererū": 2.1, "The Paper Kites Club": 1.6, "Marlow Quartet": 1.3}
    track_weights = [favourites.get(t.artist, 0.8) * rng.uniform(0.7, 1.3) for t in tracks]
    episodes = []
    for show, episode in persona.podcasts:
        for title in [episode] + _EPISODES.get(show, []):
            episodes.append((show, title, rng.randint(22, 58) * 60 + rng.randint(0, 59)))
    return tracks, track_weights, episodes


class MediaWriter:
    """Collects Media.NowPlaying records per device and remembers what was played."""

    def __init__(self, rng: random.Random):
        self.rng = rng
        self.records: dict[Optional[str], list] = {}
        self.plays: list[dict] = []
        self.sittings: list[dict] = []

    def emit(self, device: Optional[str], t: float, state: int, item: dict, route: Optional[tuple]) -> None:
        self.records.setdefault(device, []).append((t, pb.message([
            (2, pb.double(lib.cocoa(t))), (3, state), (4, item.get("album") or None), (5, item.get("artist") or None),
            (6, int(item["duration"]) if item.get("duration") else None), (7, item.get("genre") or None),
            (8, item.get("title") or None), (10, item.get("type") or None), (13, 0),
            (14, [(1, route[0]), (2, route[1]), (3, route[2])] if route else None), (15, item["bundle"]),
            (20, 0), (21, 1 if state == 1 else 0),
        ])))

    def sitting(self, device: Optional[str], start: float, items: list[dict], route: Optional[tuple], limit: float,
                listen_through: float = 0.92) -> float:
        """Plays `items` back to back from `start`; returns the end time."""
        rng = self.rng
        t = start
        first = t
        played = []
        for item in items:
            if t >= limit:
                break
            length = float(item.get("duration") or rng.uniform(40, 400))
            heard = length if rng.random() < listen_through else length * rng.uniform(0.08, 0.7)
            self.emit(device, t, 1, item, route)
            self.plays.append({"device": device, "start": t, "item": item, "route": route})
            played.append(item)
            if heard > 60 and rng.random() < 0.1:              # paused for a moment
                pause = t + heard * rng.uniform(0.2, 0.8)
                resume = pause + rng.uniform(8, 150)
                self.emit(device, pause, 2, item, route)
                self.emit(device, resume, 1, item, route)
                heard += resume - pause
            t += heard
        if played:
            self.emit(device, t, 3 if rng.random() < 0.6 else 2, played[-1], route)
            self.sittings.append({"device": device, "start": first, "end": t, "bundle": played[-1]["bundle"], "items": played, "route": route})
        return t


def _generate_media(persona: Persona, days: Days, rng: random.Random, mac_blocks, phone_end: float, pad_end: float,
                    watch_end: float, workouts) -> MediaWriter:
    tracks, track_weights, episodes = _media_catalogue(persona, rng)
    writer = MediaWriter(rng)
    phone = persona.device("iphone").identifier
    pad = persona.device("ipad").identifier
    watch = persona.device("watch").identifier

    def address() -> str:
        return ":".join(f"{rng.randrange(256):02X}" for _ in range(6))

    headphones = (2, 3, address() + "-tacl")           # Bluetooth A2DP
    car = (2, 4, address() + "-tsco")                  # hands-free
    speaker = (1, 1, "Speaker")
    home_speaker = (4, 12, address())                  # AirPlay receiver in the living room

    def track_item(track, bundle: str) -> dict:
        return {"title": track.title, "artist": track.artist, "album": track.album, "genre": track.genre,
                "duration": track.seconds, "type": AUDIO, "bundle": bundle}

    def music(count: int, bundle: str) -> list[dict]:
        if rng.random() < 0.35:       # an album, in order
            album = rng.choices(tracks, weights=track_weights)[0].album
            chosen = [t for t in tracks if t.album == album]
            while len(chosen) < count:
                chosen.append(rng.choices(tracks, weights=track_weights)[0])
        else:
            chosen = rng.choices(tracks, weights=track_weights, k=count)
        out = []
        for t in chosen[:count]:
            if not out or out[-1]["title"] != t.title:
                out.append(track_item(t, bundle))
        return out

    def episode_item(bundle: str = "com.apple.podcasts") -> dict:
        show, title, seconds = rng.choice(episodes)
        return {"title": title, "artist": show, "album": show, "genre": "Podcast", "duration": seconds, "type": PODCAST, "bundle": bundle}

    def clip_item(bundle: str) -> dict:
        title = rng.choice(_CLIPS)
        if bundle == "com.apple.Safari":
            return {"title": title + " - YouTube", "duration": rng.randint(180, 1500), "type": VIDEO, "bundle": bundle}
        return {"title": title, "artist": "", "duration": rng.randint(120, 1500), "type": VIDEO, "bundle": bundle}

    long_episode = {"title": "Episode 116: Live from Wellington — show notes and the full reading list at https://example.org/designdetail/116 #design #typography",
                    "artist": "The Design Detail Hour", "album": "The Design Detail Hour", "genre": "Podcast",
                    "duration": 3127, "type": PODCAST, "bundle": "com.apple.podcasts"}
    people = [persona.person("partner"), persona.person("sister"), persona.person("priya"), persona.person("mother")]

    def voice_item() -> dict:
        who = rng.choice(people)
        return {"title": f"Voice message from {who.full_name}", "duration": 0, "bundle": "net.whatsapp.WhatsApp"}

    audio_message = {"title": "Audio Message", "duration": 0, "bundle": "com.apple.MobileSMS"}
    recording = {"title": "Kōwhai Labs all-hands — recording (internal)", "duration": 2940, "type": VIDEO, "bundle": "us.zoom.xos"}

    # --- Mac: music while working, the odd video in Safari in the evening.
    for start, end in mac_blocks:
        d_len = end - start
        if d_len < 20 * 60:
            continue
        local = days.local_hour(start)
        if local < 18 and rng.random() < 0.34:
            bundle = "com.apple.Music" if rng.random() < 0.62 else "com.spotify.client"
            begin = start + rng.uniform(2, 15) * 60
            writer.sitting(None, begin, music(rng.randint(5, 13), bundle), headphones if rng.random() < 0.72 else speaker, end - 60)
        elif local >= 18 and rng.random() < 0.45:
            begin = start + rng.uniform(3, 20) * 60
            if rng.random() < 0.6:
                writer.sitting(None, begin, [clip_item("com.apple.Safari") for _ in range(rng.randint(1, 3))], speaker, end - 60, 0.6)
            else:
                writer.sitting(None, begin, music(rng.randint(4, 9), "com.apple.Music"), home_speaker, end - 60)
        elif local < 12 and rng.random() < 0.035:
            writer.sitting(None, start + 600, [recording], headphones, end - 60, 0.5)

    # --- iPhone: podcasts and music on the way to and from work, clips at night.
    for d in range(PHONE_DAYS, days.last_day - 1, -1):
        weekend = days.is_weekend(d)
        slots = []
        if not weekend:
            if rng.random() < 0.78:
                slots.append((days.at(d, rng.gauss(8.0, 0.2)), "commute"))
            if rng.random() < 0.7:
                slots.append((days.at(d, rng.gauss(17.85, 0.3)), "commute"))
            if rng.random() < 0.18:
                slots.append((days.at(d, rng.gauss(12.6, 0.2)), "voice"))
        else:
            if rng.random() < 0.55:
                slots.append((days.at(d, rng.gauss(10.8, 1.0)), "walk"))
        if rng.random() < 0.5:
            slots.append((days.at(d, rng.gauss(21.6, 0.5)), "clips"))
        if rng.random() < 0.16:
            slots.append((days.at(d, rng.gauss(19.2, 0.6)), "voice"))
        for begin, kind in sorted(slots):
            if begin >= phone_end - 1800:
                continue
            limit = min(phone_end, begin + (36 if kind == "commute" else 70) * 60)
            if kind == "commute":
                roll = rng.random()
                if roll < 0.45:
                    items = [long_episode if rng.random() < 0.04 else episode_item()]
                elif roll < 0.8:
                    items = music(rng.randint(6, 10), "com.apple.Music")
                else:
                    items = music(rng.randint(6, 10), "com.spotify.client")
                writer.sitting(phone, begin, items, headphones, limit)
            elif kind == "walk":
                items = [episode_item()] if rng.random() < 0.5 else music(rng.randint(8, 14), "com.apple.Music")
                writer.sitting(phone, begin, items, headphones if rng.random() < 0.8 else car, limit)
            elif kind == "clips":
                bundle = "com.google.ios.youtube" if rng.random() < 0.7 else "com.burbn.instagram"
                count = rng.randint(1, 4)
                if bundle == "com.burbn.instagram":
                    items = [{"title": "Reel by " + rng.choice(["wellington.walks", "tiny.type.club", "kaka.cam", "slowbrew.nz"]),
                              "duration": 0, "bundle": bundle} for _ in range(count)]
                else:
                    items = [clip_item(bundle) for _ in range(count)]
                writer.sitting(phone, begin, items, speaker, limit, 0.55)
            else:
                writer.sitting(phone, begin, [voice_item() if rng.random() < 0.75 else audio_message], speaker, limit, 1.0)

    # --- iPad: video on the sofa.
    for d in range(PAD_DAYS, days.last_day - 1, -1):
        if rng.random() < 0.3:
            begin = days.at(d, rng.gauss(21.0, 0.5))
            if begin < pad_end - 3600:
                writer.sitting(pad, begin, [clip_item("com.google.ios.youtube") for _ in range(rng.randint(1, 3))], speaker, begin + 3600, 0.7)

    # --- Watch: mirrors what the phone plays (same item, phone app's bundle id), and
    #     plays its own music during a workout.
    first_watch = days.start(WATCH_DAYS)
    for play in list(writer.plays):
        if play["device"] != phone or play["start"] < first_watch or play["start"] > watch_end - 600:
            continue
        item = play["item"]
        if item.get("type") in (AUDIO, PODCAST) and rng.random() < 0.55:
            t = play["start"] + rng.uniform(2, 40)
            writer.emit(watch, t, 1, item, None)
            writer.plays.append({"device": watch, "start": t, "item": item, "route": None, "mirror": True})
            if rng.random() < 0.5:
                writer.emit(watch, t + float(item.get("duration") or 60) * rng.uniform(0.5, 1.0), 2, item, None)
    for start, end in workouts:
        if rng.random() < 0.6 and end < watch_end:
            writer.sitting(watch, start + rng.uniform(60, 300), music(rng.randint(8, 14), "com.apple.Music"), headphones, end)
    return writer


# --------------------------------------------------------------------------------------
# knowledgeC.db (shared with other modules)
# --------------------------------------------------------------------------------------

KNOWLEDGE_DDL = """
CREATE TABLE IF NOT EXISTS ZOBJECT ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZUUIDHASH INTEGER, ZEVENT INTEGER, ZSOURCE INTEGER, ZCATEGORYTYPE INTEGER, ZINTEGERVALUE INTEGER, ZCOMPATIBILITYVERSION INTEGER, ZENDDAYOFWEEK INTEGER, ZENDSECONDOFDAY INTEGER, ZHASCUSTOMMETADATA INTEGER, ZHASSTRUCTUREDMETADATA INTEGER, ZSECONDSFROMGMT INTEGER, ZSHOULDSYNC INTEGER, ZSTARTDAYOFWEEK INTEGER, ZSTARTSECONDOFDAY INTEGER, ZVALUECLASS INTEGER, ZVALUEINTEGER INTEGER, ZVALUETYPECODE INTEGER, ZSTRUCTUREDMETADATA INTEGER, ZVALUE INTEGER, Z9_VALUE INTEGER, ZIDENTIFIERTYPE INTEGER, ZQUANTITYTYPE INTEGER, ZCREATIONDATE TIMESTAMP, ZLOCALCREATIONDATE TIMESTAMP, ZCONFIDENCE FLOAT, ZENDDATE TIMESTAMP, ZSTARTDATE TIMESTAMP, ZVALUEDOUBLE FLOAT, ZDOUBLEVALUE FLOAT, ZUUID VARCHAR, ZSTREAMNAME VARCHAR, ZVALUESTRING VARCHAR, ZSTRING VARCHAR, ZMETADATA BLOB );
CREATE TABLE IF NOT EXISTS ZSOURCE ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZUSERID INTEGER, ZBUNDLEID VARCHAR, ZDEVICEID VARCHAR, ZGROUPID VARCHAR, ZINTENTID VARCHAR, ZITEMID VARCHAR, ZSOURCEID VARCHAR );
CREATE TABLE IF NOT EXISTS ZSTRUCTUREDMETADATA ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, Z_DKDIGITALHEALTHMETADATAKEY__ISUSAGETRUSTED INTEGER, Z_DKDIGITALHEALTHMETADATAKEY__USAGETYPE INTEGER, Z_DKDIGITALHEALTHMETADATAKEY__SAFARIPROFILEID VARCHAR, Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN VARCHAR, ZMETADATAHASH VARCHAR, Z_DKAPPMEDIAUSAGEMETADATAKEY__URL VARCHAR, Z_DKAPPMEDIAUSAGEMETADATAKEY__MEDIAURL VARCHAR, Z_DKDIGITALHEALTHMETADATAKEY__WEBPAGEURL VARCHAR );
CREATE TABLE IF NOT EXISTS Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
CREATE TABLE IF NOT EXISTS Z_METADATA (Z_VERSION INTEGER PRIMARY KEY, Z_UUID VARCHAR(255), Z_PLIST BLOB);
CREATE INDEX IF NOT EXISTS ZOBJECT_ZSTREAMNAME_INDEX ON ZOBJECT (ZSTREAMNAME, ZSTARTDATE);
"""
_KNOWLEDGE_ENTITIES = [(1, "AdditionChangeSet", 0), (2, "ContextualChangeRegistration", 0), (3, "ContextualKeyPath", 0),
                       (4, "CustomMetadata", 0), (5, "DeletionChangeSet", 0), (6, "Histogram", 0), (7, "HistogramValue", 0),
                       (8, "KeyValue", 0), (9, "Object", 0), (10, "Category", 9), (11, "Event", 9), (12, "Identifier", 9),
                       (13, "Quantity", 9), (14, "Source", 0), (15, "StructuredMetadata", 0), (16, "SyncPeer", 0)]


def _ensure_columns(con: sqlite3.Connection, ddl: str) -> None:
    """Creates the tables of `ddl` when missing and adds any column of `ddl` that an
    existing table (written by another module with a narrower schema) does not have yet."""
    for statement in lib.split_sql(ddl):
        con.execute(statement)
        if not statement.upper().startswith("CREATE TABLE"):
            continue
        table = statement.split("(", 1)[0].split()[-1]
        have = {row[1].lower() for row in con.execute(f'PRAGMA table_info("{table}")')}
        body = statement.split("(", 1)[1].rsplit(")", 1)[0]
        for column in body.split(","):
            parts = column.split()
            if len(parts) >= 2 and parts[0].lower() not in have and "PRIMARY" not in column.upper():
                con.execute(f'ALTER TABLE "{table}" ADD COLUMN {parts[0]} {parts[1]}')


def _write_knowledge(root: pathlib.Path, persona: Persona, days: Days, rng: random.Random, mac_sessions, mac_blocks, visits,
                     media_usage) -> None:
    path = lib.library(root, "Application Support/Knowledge/knowledgeC.db")
    if not path.exists():
        with lib.sqlite_db(path, KNOWLEDGE_DDL) as con:
            lib.insert(con, "Z_PRIMARYKEY", [(ent, name, parent, 0) for ent, name, parent in _KNOWLEDGE_ENTITIES])
            lib.insert(con, "Z_METADATA", [(1, lib.uuid_string(rng), lib.plist_bytes({"NSStoreType": "SQLite", "NSStoreModelVersionIdentifiers": [""]}))])
    con = sqlite3.connect(str(path), isolation_level=None)
    try:
        con.execute("PRAGMA journal_mode=DELETE")
        con.execute("BEGIN")
        _ensure_columns(con, KNOWLEDGE_DDL)
        marks = ",".join("?" for _ in KNOWLEDGE_STREAMS)
        con.execute(f"DELETE FROM ZSTRUCTUREDMETADATA WHERE Z_PK IN (SELECT ZSTRUCTUREDMETADATA FROM ZOBJECT WHERE ZSTREAMNAME IN ({marks}))", KNOWLEDGE_STREAMS)
        con.execute(f"DELETE FROM ZOBJECT WHERE ZSTREAMNAME IN ({marks})", KNOWLEDGE_STREAMS)
        next_object = (con.execute("SELECT max(Z_PK) FROM ZOBJECT").fetchone()[0] or 0) + 1
        next_meta = (con.execute("SELECT max(Z_PK) FROM ZSTRUCTUREDMETADATA").fetchone()[0] or 0) + 1
        seconds_from_gmt = int(persona.tz_offset_hours * 3600)
        # Value type codes are opaque constants per value class; invented here.
        string_code = rng.getrandbits(62)
        integer_code = -rng.getrandbits(62)
        since = days.end - KNOWLEDGE_DAYS * DAY
        meta_ids: dict[tuple, int] = {}

        def metadata(**columns) -> int:
            nonlocal next_meta
            key = tuple(sorted(columns.items()))
            if key not in meta_ids:
                row = {"Z_PK": next_meta, "Z_ENT": 15, "Z_OPT": 1, "ZMETADATAHASH": lib.hex_string(rng, 32)}
                row.update(columns)
                lib.insert(con, "ZSTRUCTUREDMETADATA", [row])
                meta_ids[key] = next_meta
                next_meta += 1
            return meta_ids[key]

        def event(stream: str, start: float, end: float, string: Optional[str] = None, integer: Optional[int] = None,
                  meta: Optional[int] = None) -> None:
            nonlocal next_object
            created = end + rng.uniform(0.2, 4)
            con.execute(
                "INSERT INTO ZOBJECT (Z_PK, Z_ENT, Z_OPT, ZUUIDHASH, ZCOMPATIBILITYVERSION, ZENDDAYOFWEEK, ZENDSECONDOFDAY,"
                " ZHASCUSTOMMETADATA, ZHASSTRUCTUREDMETADATA, ZSECONDSFROMGMT, ZSHOULDSYNC, ZSTARTDAYOFWEEK, ZSTARTSECONDOFDAY,"
                " ZVALUECLASS, ZVALUEINTEGER, ZVALUETYPECODE, ZSTRUCTUREDMETADATA, ZCREATIONDATE, ZLOCALCREATIONDATE, ZENDDATE,"
                " ZSTARTDATE, ZVALUEDOUBLE, ZUUID, ZSTREAMNAME, ZVALUESTRING) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (next_object, 11, 1, rng.getrandbits(62), 0, days.local_dow_sunday1(end), days.second_of_day(end), 0,
                 1 if meta else 0, seconds_from_gmt, 0, days.local_dow_sunday1(start), days.second_of_day(start),
                 1 if string is not None else 2, integer if integer is not None else 0,
                 string_code if string is not None else integer_code, meta, lib.cocoa(created), lib.cocoa(created),
                 lib.cocoa(end), lib.cocoa(start), float(integer or 0), lib.uuid_string(rng), stream, string))
            next_object += 1

        usage_meta = metadata(Z_DKDIGITALHEALTHMETADATAKEY__ISUSAGETRUSTED=1, Z_DKDIGITALHEALTHMETADATAKEY__USAGETYPE=0)
        for start, end, bundle in mac_sessions:
            if end > since:
                event("/app/usage", max(start, since), end, string=bundle, meta=usage_meta)
        previous_end: Optional[float] = None
        for start, end in mac_blocks:
            if end <= since:
                previous_end = end
                continue
            if previous_end is not None and previous_end > since:
                event("/app/usage", previous_end, start, string=LOCK, meta=usage_meta)
                event("/display/isBacklit", previous_end + 45, start - 2, integer=0)
            event("/display/isBacklit", max(start, since) - 2, end + 45, integer=1)
            previous_end = end
        for start, end, _tab, page in visits:
            if end > since:
                meta = metadata(Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN=page[0], Z_DKDIGITALHEALTHMETADATAKEY__WEBPAGEURL=page[2],
                                Z_DKDIGITALHEALTHMETADATAKEY__USAGETYPE=0)
                event("/app/webUsage", max(start, since), end, string="com.apple.Safari", meta=meta)
        for start, end, bundle, url in media_usage:
            if end > since:
                meta = metadata(Z_DKAPPMEDIAUSAGEMETADATAKEY__URL=url) if url else None
                event("/app/mediaUsage", max(start, since), end, string=bundle, meta=meta)

        if con.execute("SELECT count(*) FROM Z_PRIMARYKEY").fetchone()[0]:
            con.execute("UPDATE Z_PRIMARYKEY SET Z_MAX = ? WHERE Z_NAME IN ('Object', 'Event')", (next_object - 1,))
            con.execute("UPDATE Z_PRIMARYKEY SET Z_MAX = ? WHERE Z_NAME = 'StructuredMetadata'", (next_meta - 1,))
        con.execute("COMMIT")
    finally:
        con.close()


# --------------------------------------------------------------------------------------
# DuetExpertCenter
# --------------------------------------------------------------------------------------

ATX_DDL = """
CREATE TABLE appInfo (bundleId TEXT PRIMARY KEY, installDate INT, lastLaunchDate INT, lastSpotlightLaunchDate INT, subsequentLaunchCounts BLOB, genreId INT, subGenreIds BLOB, isExtension INTEGER, app2VecCluster INT, averageSecondsBetweenLaunches INT, medianSecondsBetweenLaunches INT, subsequentAppActionLaunchCounts BLOB, isEnterpriseApp INTEGER, remoteAppUUID TEXT) WITHOUT ROWID;
CREATE TABLE histograms (histogramType INT PRIMARY KEY, histogramData BLOB NOT NULL);
CREATE TABLE categoricalHistograms (histogramType INT PRIMARY KEY, histogramData BLOB NOT NULL);
CREATE TABLE appLaunchSequence (launchDate INT PRIMARY KEY, bundleId TEXT);
CREATE TABLE alogBundleId (id INTEGER PRIMARY KEY, bundleId TEXT UNIQUE NOT NULL);
CREATE TABLE alogAction (id INTEGER PRIMARY KEY, actionType TEXT UNIQUE NOT NULL);
CREATE TABLE alog (id INTEGER PRIMARY KEY, bundleId INT NOT NULL, actionType INT NOT NULL, slots BLOB, date INT NOT NULL, timeOfDay INT NOT NULL, dayOfWeek INT NOT NULL, location BLOB, weight REAL, actionUUID BLOB, prevLocation BLOB, motionType INT NOT NULL, appSessionStartDate INT, appSessionEndDate INT, creationDateInMilliseconds INT, geohash INT NOT NULL, coarseGeohash INT NOT NULL);
CREATE TABLE anchorModelTrainingData (id INTEGER PRIMARY KEY, anchorType TEXT NOT NULL, anchorDate INTEGER NOT NULL, candidateType TEXT NOT NULL, candidateId TEXT NOT NULL, candidateOccurrencesInLast12Hours INTEGER, candidateOccurrencesInLast24Hours INTEGER, candidateOccurrencesInLast48Hours INTEGER, candidateOccurrencesInLast7Days INTEGER, candidateOccurrencesInLast14Days INTEGER, candidateOccurrencesInLast28Days INTEGER, candidatePerformed INTEGER NOT NULL, candidateEngaged INTEGER NOT NULL, secondsSinceAnchor INTEGER NOT NULL, candidateLocation TEXT, candidateOccurrenceId INTEGER);
CREATE TABLE anchorOccurrence (anchorType TEXT NOT NULL, anchorDate INTEGER NOT NULL, anchorLocalHour INTEGER NOT NULL, anchorLocalDoW INTEGER NOT NULL, anchorLocalIsWeekend INTEGER NOT NULL, anchorLocation TEXT, anchorEventIdentifier TEXT, PRIMARY KEY ( anchorType, anchorDate ) );
CREATE TABLE anchorType (name TEXT PRIMARY KEY, description TEXT NOT NULL);
"""

#: Anchor names are system vocabulary (the module keys its symbols on them).
_ANCHORS = [
    ("ChargerConnectedAnchor", "Charger was connected."),
    ("LOIEntranceAnchor", "The user entered a known LOI."),
    ("LOIExitAnchor", "The user exited a known LOI."),
    ("BluetoothConnectedAnchor", "Bluetooth device is connected."),
    ("BluetoothDisconnectedAnchor", "Bluetooth device is disconnected."),
    ("IdleTimeBeginAnchor", "The user hasn't used their device for a prolonged period of time. Likely after waking up in the morning."),
]

#: Menu commands per app: the path from the top-level menu to the command (generic menus).
_MENUS = {
    "com.apple.Safari": [("History", "Reopen Last Closed Tab"), ("File", "New Private Window"), ("View", "Show Reader"),
                         ("Bookmarks", "Add Bookmark…"), ("File", "Export as PDF…"), ("History", "Clear History…")],
    "com.apple.mail": [("Mailbox", "Get All New Mail"), ("Message", "Archive"), ("View", "Sort By", "Date"),
                       ("Message", "Flag", "Red"), ("Message", "Forward as Attachment")],
    "com.apple.finder": [("Go", "Downloads"), ("File", "New Folder"), ("View", "as List"), ("File", "Compress"), ("Go", "Connect to Server…")],
    "com.apple.Notes": [("Format", "Checklist"), ("File", "Lock Note"), ("Format", "Table")],
    "com.apple.Preview": [("Tools", "Adjust Size…"), ("File", "Export…"), ("Tools", "Annotate", "Signature"), ("Tools", "Redact")],
    "com.apple.iCal": [("View", "Go to Today"), ("File", "New Event"), ("View", "Show Declined Events")],
    "com.apple.dt.Xcode": [("Product", "Clean Build Folder…"), ("Editor", "Structure", "Re-Indent"), ("Product", "Archive")],
    "com.apple.Terminal": [("Shell", "New Tab"), ("Edit", "Clear to Start"), ("Shell", "Export Text As…")],
    "com.figma.Desktop": [("Object", "Frame Selection"), ("File", "Export Frames to PDF…"), ("Text", "Bold"), ("Object", "Create Component"),
                          ("View", "Pixel Grid")],
    "com.apple.Photos": [("Image", "Adjust Date and Time…"), ("File", "Export", "Export Unmodified Original…"), ("Image", "Hide Photo")],
    "com.apple.MobileSMS": [("Conversation", "Delete Conversation…"), ("View", "Show Recently Deleted")],
    "notion.id": [("File", "Export…"), ("View", "Toggle Sidebar")],
}
_GENRES = {"productivity": 6007, "developer": 6026, "browser": 6002, "communication": 6005, "utility": 6002, "media": 6011,
           "travel": 6003, "health": 6013, "finance": 6015, "social": 6005}


def _action_proto(bundle: str, path: tuple) -> bytes:
    return pb.message([(1, bundle), (6, path[-1])] + [(20, component) for component in path])


def _action_slots(bundle: str, path: tuple, rng: random.Random) -> bytes:
    """`alog.slots`: 4-byte hash, version, u16 length, pad, then the archive without its
    8-byte magic, then a 32-byte key suffix (layout from DuetStore.swift)."""
    archive = lib.keyed_archive(lib.ArchiveObject("ATXAction", {"protobufData": _action_proto(bundle, path)}))
    body = archive[8:]
    return struct.pack("<IBHB", rng.getrandbits(32), 1, len(body), 0) + body + bytes(rng.getrandbits(8) for _ in range(32))


def _write_duet(root: pathlib.Path, persona: Persona, days: Days, rng: random.Random, mac_sessions, mac_blocks, media: MediaWriter) -> None:
    base = lib.ensure_dir(lib.library(root, "DuetExpertCenter"))
    apps = persona.apps_on("mac")
    by_bundle = {a.bundle_id: a for a in apps}

    # Launch statistics from the simulation.
    launches: dict[str, list[float]] = {}
    follow: dict[str, dict[str, float]] = {}
    previous: Optional[tuple] = None
    for start, end, bundle in mac_sessions:
        launches.setdefault(bundle, []).append(start)
        if previous and previous[2] != bundle and start - previous[1] <= 60:
            decay = 0.5 ** ((days.end - start) / (14 * DAY))
            follow.setdefault(previous[2], {})[bundle] = follow.get(previous[2], {}).get(bundle, 0.0) + decay
        previous = (start, end, bundle)

    never_launched = ["com.apple.Chess", "com.apple.Stickies", "com.apple.FontBook", "com.apple.Automator", "com.apple.ScriptEditor2",
                      "com.apple.DigitalColorMeter", "com.apple.grapher", "com.apple.VoiceOverUtility"]
    rows = []
    for a in apps:
        times = launches.get(a.bundle_id, [])
        gaps = sorted(b - c for b, c in zip(times[1:], times))
        counts = {k: round(v, 3) for k, v in sorted(follow.get(a.bundle_id, {}).items(), key=lambda kv: -kv[1])[:12]}
        actions = {}
        for path in _MENUS.get(a.bundle_id, [])[:2]:
            actions[f"{a.bundle_id}:RunIntelligenceCommand"] = round(rng.uniform(0.4, 6.0), 3)
        rows.append({
            "bundleId": a.bundle_id,
            "installDate": int(lib.cocoa(days.end - rng.uniform(200, 900) * DAY)),
            "lastLaunchDate": int(lib.cocoa(times[-1])) if times else None,
            "lastSpotlightLaunchDate": int(lib.cocoa(rng.choice(times[-12:]))) if times and rng.random() < 0.6 else None,
            "subsequentLaunchCounts": lib.keyed_archive(counts, mutable_collections=True) if counts else None,
            "genreId": _GENRES.get(a.category, 6002), "isExtension": 0, "app2VecCluster": rng.randint(0, 24),
            "averageSecondsBetweenLaunches": int(sum(gaps) / len(gaps)) if gaps else None,
            "medianSecondsBetweenLaunches": int(gaps[len(gaps) // 2]) if gaps else None,
            "subsequentAppActionLaunchCounts": lib.keyed_archive(actions, mutable_collections=True) if actions else None,
            "isEnterpriseApp": 0,
        })
    for bundle in never_launched:
        rows.append({"bundleId": bundle, "installDate": int(lib.cocoa(days.end - rng.uniform(300, 900) * DAY)),
                     "genreId": 6002, "isExtension": 0, "app2VecCluster": rng.randint(0, 24), "isEnterpriseApp": 0})

    # Anchors: what happened, and what the user did in the minutes after.
    occurrences: dict[str, list[float]] = {name: [] for name, _ in _ANCHORS}
    day_first: dict[int, float] = {}
    day_last: dict[int, float] = {}
    for start, end in mac_blocks:
        key = int((start + days.offset) // DAY)
        day_first.setdefault(key, start)
        day_last[key] = end
    for key, first in day_first.items():
        occurrences["IdleTimeBeginAnchor"].append(first - rng.uniform(5, 40))
        if rng.random() < 0.8:
            occurrences["ChargerConnectedAnchor"].append(first + rng.uniform(20, 400))
        weekday = (key + 3) % 7
        if weekday < 5 and rng.random() < 0.85:
            occurrences["LOIEntranceAnchor"].append(first - rng.uniform(60, 420))
            occurrences["LOIExitAnchor"].append(day_last[key] + rng.uniform(120, 900) if rng.random() < 0.6 else first + rng.uniform(3.4, 3.8) * 3600)
        if rng.random() < 0.25:
            occurrences["ChargerConnectedAnchor"].append(day_last[key] - rng.uniform(600, 3000))
    for sitting in media.sittings:
        if sitting["device"] is None and sitting["route"] and sitting["route"][2].endswith("-tacl"):
            occurrences["BluetoothConnectedAnchor"].append(sitting["start"] - rng.uniform(4, 30))
            if rng.random() < 0.9:
                occurrences["BluetoothDisconnectedAnchor"].append(sitting["end"] + rng.uniform(5, 240))

    candidates = {
        "ChargerConnectedAnchor": [("app", "com.apple.mail", 0.62), ("app", "com.tinyspeck.slackmacgap", 0.55), ("app", "com.apple.Safari", 0.5),
                                   ("app", "com.apple.iCal", 0.3), ("action", "com.apple.mail:RunIntelligenceCommand:%d", 0.18),
                                   ("app", "com.apple.Notes", 0.12)],
        "LOIEntranceAnchor": [("app", "com.tinyspeck.slackmacgap", 0.74), ("app", "com.figma.Desktop", 0.6), ("app", "com.apple.iCal", 0.46),
                              ("app", "com.apple.mail", 0.4), ("mode", "%s:2", 0.3), ("app", "notion.id", 0.22), ("app", "us.zoom.xos", 0.15)],
        "LOIExitAnchor": [("app", "com.apple.Music", 0.4), ("app", "com.apple.MobileSMS", 0.36), ("app", "com.apple.Maps", 0.14),
                          ("mode", "%s:0", 0.12)],
        "BluetoothConnectedAnchor": [("app", "com.apple.Music", 0.78), ("app", "com.spotify.client", 0.42), ("app", "us.zoom.xos", 0.2),
                                     ("app", "com.apple.podcasts", 0.1), ("action", "com.apple.Music:RunIntelligenceCommand:%d", 0.08)],
        "BluetoothDisconnectedAnchor": [("app", "com.tinyspeck.slackmacgap", 0.38), ("app", "com.apple.MobileSMS", 0.25), ("app", "com.apple.Safari", 0.3)],
        "IdleTimeBeginAnchor": [("app", "com.apple.mail", 0.7), ("app", "com.apple.Safari", 0.6), ("app", "com.tinyspeck.slackmacgap", 0.52),
                                ("app", "com.apple.weather", 0.3), ("app", "com.apple.iCal", 0.34),
                                ("action", "com.apple.Safari:RunIntelligenceCommand:%d", 0.1), ("mode", "%s:5", 0.16)],
    }
    mode_uuid = lib.uuid_string(rng)
    action_hash = {name: rng.randint(10 ** 8, 10 ** 10) for name in candidates}
    work_loi = lib.uuid_string(rng)
    occurrence_rows = []
    training_rows = []
    training_id = 1
    seen_keys = set()
    for name, _ in _ANCHORS:
        for t in sorted(occurrences[name]):
            stamp = int(t)
            if t >= days.end or (name, stamp) in seen_keys:
                continue
            seen_keys.add((name, stamp))
            weekend = days.local_dow_sunday1(t) in (1, 7)
            occurrence_rows.append((name, stamp, days.local_hour(t), days.local_dow_sunday1(t), 1 if weekend else 0,
                                    work_loi if name.startswith("LOI") else None, lib.uuid_string(rng)))
            if t < days.end - 75 * DAY:
                continue
            for kind, candidate, probability in candidates[name]:
                if "%d" in candidate:
                    candidate = candidate % action_hash[name]
                elif "%s" in candidate:
                    candidate = candidate % mode_uuid
                if rng.random() > 0.9:
                    continue
                performed = rng.random() < probability * (0.5 if weekend else 1.0)
                recent = rng.randint(0, 6)
                training_rows.append((training_id, name, stamp, kind, candidate, recent, recent + rng.randint(0, 6),
                                      recent * 2 + rng.randint(0, 9), recent * 6 + rng.randint(0, 20), recent * 12 + rng.randint(0, 40),
                                      recent * 24 + rng.randint(0, 80), 1 if performed else 0,
                                      1 if performed and rng.random() < 0.35 else 0,
                                      int(_lognormal(rng, 95 if performed else 260, 0.9, 4, 1800)), None, None))
                training_id += 1

    # alog: menu commands the user actually ran.
    menu_apps = [b for b in _MENUS if b in by_bundle]
    usable = [s for s in mac_sessions if s[2] in _MENUS and s[1] > days.end - 40 * DAY and s[1] - s[0] > 20]
    alog_rows = []
    bundle_ids = {b: i + 1 for i, b in enumerate(menu_apps)}
    for i, (start, end, bundle) in enumerate(sorted(rng.sample(usable, min(420, len(usable))))):
        commands = _MENUS[bundle]
        path = commands[min(len(commands) - 1, int(abs(rng.gauss(0, 1.3))))]
        when = rng.uniform(start + 2, end - 2)
        alog_rows.append((i + 1, bundle_ids[bundle], 1, _action_slots(bundle, path, rng), int(lib.cocoa(when)),
                          days.second_of_day(when), days.local_dow_sunday1(when) - 1, None, 1.0,
                          lib.uuid_obj(rng).bytes, None, 0, int(lib.cocoa(start)), int(lib.cocoa(end)), int(when * 1000), 0, 0))

    sequence = {}
    for start, _end, bundle in mac_sessions[-60:]:
        sequence[int(lib.cocoa(start))] = bundle

    lib.create_db(base / "_ATXDataStore.db", ATX_DDL, {
        "appInfo": rows,
        "appLaunchSequence": list(sequence.items()),
        "anchorType": _ANCHORS,
        "anchorOccurrence": occurrence_rows,
        "anchorModelTrainingData": training_rows,
        "alogBundleId": [(i, b) for b, i in bundle_ids.items()],
        "alogAction": [(1, "RunIntelligenceCommand")],
        "alog": alog_rows,
        "histograms": [(i, bytes(rng.getrandbits(8) for _ in range(rng.randint(96, 640)))) for i in range(1, 39)],
        "categoricalHistograms": [(i, bytes(rng.getrandbits(8) for _ in range(rng.randint(96, 420)))) for i in range(1, 15)],
    })

    # --- Prediction caches -------------------------------------------------------------
    last_hour = days.local_hour(days.end)
    recent_start = days.end - 10 * DAY
    score: dict[str, float] = {}
    for start, end, bundle in mac_sessions:
        if start < recent_start:
            continue
        near = 1.0 + 1.5 * max(0.0, 1 - abs(days.local_hour(start) - last_hour) / 3.0)
        score[bundle] = score.get(bundle, 0.0) + near * 0.5 ** ((days.end - start) / (4 * DAY))
    ranked = sorted(score.items(), key=lambda kv: -kv[1])
    top = ranked[0][1] if ranked else 1.0

    def predictions(kind: str, jitter: float, count: int) -> bytes:
        entries = sorted(((b, 9.2 * (v / top) ** 0.55 * rng.uniform(1 - jitter, 1 + jitter)) for b, v in ranked), key=lambda kv: -kv[1])
        entries += [(b, -rng.uniform(0.5, 3.0)) for b in never_launched[:3]]
        fields = [(1, lib.uuid_string(rng))]
        for bundle, value in entries[:count]:
            fields.append((2, [(1, lib.uuid_string(rng)), (2, [(1, "apps")]), (3, [(1, bundle), (2, 1)]),
                               (4, [(1, 1), (3, "Suggested from your recent app launches at this time of day")]),
                               (5, [(1, pb.double(round(value, 4))), (2, 3 if value > 6 else 2 if value > 2.5 else 1)])]))
        return pb.message(fields)

    caches = lib.ensure_dir(base / "ClientModelCaches")
    shared = predictions("homescreen", 0.0, 26)
    lib.write_bytes(caches / "atx_app_predictions_homescreen", shared)
    lib.write_bytes(caches / "atx_app_predictions_app_library", shared)
    lib.write_bytes(caches / "atx_app_predictions_spotlight", predictions("spotlight", 0.3, 22))

    home = "file:///Users/robin"
    documents = [
        (f"{home}/Documents/K%C5%8Dwhai%20Labs/Design%20System/Tokens%20v3.fig", 0.94, 1),
        (f"{home}/Documents/K%C5%8Dwhai%20Labs/Roadmap%20Q4%20%E2%80%94%20draft.key", 0.88, 1),
        (f"{home}/Documents/K%C5%8Dwhai%20Labs/Performance%20review%20%E2%80%94%20self%20assessment.pages", 0.81, 1),
        (f"{home}/Downloads/Boarding%20pass%20WLG-ZQN%20K7QX2M.pdf", 0.77, 2),
        (f"{home}/Documents/Home/Tenancy%20agreement%20Aro%20Street.pdf", 0.71, 1),
        (f"{home}/Downloads/Payslip%20{datetime.datetime.fromtimestamp(days.end - 20 * DAY, lib.UTC).strftime('%Y-%m')}.pdf", 0.66, 2),
        (f"{home}/Documents/Home/Budget%202026.numbers", 0.6, 1),
        (f"{home}/Desktop/Screenshot%20onboarding%20flow.png", 0.52, 2),
        (f"{home}/Documents/Climbing/Training%20plan.numbers", 0.45, 1),
        (f"{home}/Documents/Travel/Queenstown%20itinerary.pages", 0.41, 1),
        (f"{home}/Downloads/Harbour%20Street%20Dental%20%E2%80%94%20invoice%2048213.pdf", 0.33, 2),
        (f"{home}/Documents/K%C5%8Dwhai%20Labs/Interview%20notes%20%E2%80%94%20candidate%20B.txt", 0.27, 1),
    ]
    lib.write_bytes(lib.ensure_dir(base / "caches") / "ATXDocumentPredictorScores-DocumentSpotlight", lib.keyed_archive(
        lib.ArchiveObject("ATXDocumentPredictorCache", {
            "associatedAppBundleID": "com.apple.Spotlight",
            "predictedDocuments": [lib.ArchiveObject("ATXDocumentPrediction", {
                "documentURL": lib.ArchiveURL(url), "predictionScore": round(value * rng.uniform(0.93, 1.0) * 10, 3), "predictionType": kind,
            }) for url, value, kind in documents],
        })))

    menu_items = []
    for bundle in menu_apps:
        weight = score.get(bundle, 0.0) / top
        for rank, path in enumerate(_MENUS[bundle]):
            value = min(0.97, (0.25 + 0.75 * weight) * (0.82 ** rank) * rng.uniform(0.6, 1.0))
            if rng.random() < 0.06:
                value = -1.0
            menu_items.append(lib.ArchiveObject("ATXMenuItemPrediction", {
                "predictedItem": lib.ArchiveObject("ATXAction", {"protobufData": _action_proto(bundle, path)}), "score": float(round(value, 4))}))
    lib.write_bytes(base / "caches" / "ATXCacheFile-MenuItemPredictions", lib.keyed_archive(menu_items))
    lib.write_bytes(base / "caches" / "anchorModelSchedulerCurrentPredictions", lib.keyed_archive({
        "ChargerConnectedAnchor": ["com.apple.mail", "com.tinyspeck.slackmacgap"],
        "LOIEntranceAnchor": ["com.tinyspeck.slackmacgap", "com.figma.Desktop", "com.apple.iCal"],
        "LOIExitAnchor": [],
        "BluetoothConnectedAnchor": ["com.apple.Music"],
        "BluetoothDisconnectedAnchor": [],
        "IdleTimeBeginAnchor": ["com.apple.mail", "com.apple.Safari"],
    }))

    # --- Daily dose --------------------------------------------------------------------
    per_day: dict[int, dict[str, float]] = {}
    for start, end, bundle in mac_sessions:
        per_day.setdefault(int((start + days.offset) // DAY), {})
        per_day[int((start + days.offset) // DAY)][bundle] = per_day[int((start + days.offset) // DAY)].get(bundle, 0.0) + end - start
    keys = sorted(per_day)
    today = per_day[keys[-1]] if keys else {}
    history: dict[str, list[float]] = {}
    for key in keys[:-1][-42:]:
        for bundle, seconds in per_day[key].items():
            history.setdefault(bundle, []).append(seconds)
    locked = sum(max(0.0, b[0] - a[1]) for a, b in zip(mac_blocks[-4:], mac_blocks[-3:]))
    doses = {b: round(v, 2) for b, v in sorted(today.items(), key=lambda kv: -kv[1])}
    doses[LOCK] = round(locked, 2)
    next_midnight = days.start(days.last_day) + DAY
    lib.write_text(base / "_ATXAppDailyDose_CurrentDose", json.dumps({"version": 1, "expires": int(lib.cocoa(next_midnight)), "doses": doses}))
    averages = {}
    for bundle, values in history.items():
        mean = sum(values) / len(values)
        error = sum(abs(v - mean) for v in values) / len(values)
        averages[bundle] = lib.ArchiveObject("_ATXMovingAverage", {"avgDuration": float(round(mean, 2)), "count": len(values), "avgError": float(round(error, 2))})
    averages[LOCK] = lib.ArchiveObject("_ATXMovingAverage", {"avgDuration": 51_800.0, "count": 42, "avgError": 6_400.0})
    lib.write_bytes(base / "_ATXAppDailyDose_HistoricalDose", lib.keyed_archive({
        "duetHistoryTimestamp": datetime.datetime.fromtimestamp(days.start(days.last_day), lib.UTC),
        "appAverageDurationMapKey": averages,
        "version": 1,
    }, mutable_collections=True))

    # --- Inferred modes ------------------------------------------------------------------
    stream = base / "streams" / "appLaunchInferredMode"
    shutil.rmtree(stream, ignore_errors=True)
    records = []
    for start, end in mac_blocks:
        if end < days.end - 21 * DAY or end - start < 25 * 60:
            continue
        work = days.local_hour(start) < 18 and days.local_dow_sunday1(start) not in (1, 7)
        mode = 2 if work else rng.choice((0, 5, 5, 8))
        a = start + rng.uniform(3, 12) * 60
        b = min(end, a + rng.uniform(20, 80) * 60)
        payload = pb.message([(1, pb.double(lib.cocoa(a))), (2, pb.double(lib.cocoa(b))), (3, mode), (4, "appLaunchInferredMode"),
                              (5, pb.double(round(rng.uniform(0.52, 0.97), 3)))])
        records.append((b, payload))
        if rng.random() < 0.3:
            records.append((b + rng.uniform(30, 300), payload))     # the stream re-emits unchanged periods
    lib.write_stream(stream, records)


def _write_games(root: pathlib.Path, days: Days, mac_sessions, rng: random.Random) -> None:
    last: dict[str, float] = {}
    for _start, end, bundle in mac_sessions:
        last[bundle] = end
    last[LOCK] = days.end
    ddl = """
    CREATE TABLE appsrecentlyfocused_bookmark (pKey INTEGER PRIMARY KEY, serializedBookmark BLOB NOT NULL);
    CREATE TABLE appsrecentlyfocused_keyedAggregationMetadataTableName ("max(eventtimestamp)_max" REAL, "group_by_key_bundleid" TEXT);
    CREATE TABLE AppsRecentlyFocused("bundleID" TEXT, "maxEventTimestamp" REAL);
    CREATE INDEX appsrecentlyfocused_index ON appsrecentlyfocused ( "bundleid", "maxeventtimestamp" );
    """
    rows = sorted(last.items(), key=lambda kv: -kv[1])
    lib.create_db(lib.library(root, "Biome/databases/Games.RecentlyPlayed/Games.RecentlyPlayed.sqlite3"), ddl, {
        "AppsRecentlyFocused": rows,
        "appsrecentlyfocused_keyedAggregationMetadataTableName": [(t, b) for b, t in rows],
        "appsrecentlyfocused_bookmark": [(1, bytes(rng.getrandbits(8) for _ in range(48)))],
    })


# --------------------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------------------

def generate(root: pathlib.Path, persona: Persona, rng: random.Random, now: datetime.datetime) -> None:
    """Create this module's stores below `root`."""
    days = Days(now, persona.tz_offset_hours)
    phone = persona.device("iphone")
    pad = persona.device("ipad")
    watch = persona.device("watch")

    # sync.db names the remote devices; whoever comes first creates it.
    if not lib.library(root, "Biome/sync/sync.db").exists():
        lib.write_biome_sync_db(root, persona.devices, now, rng)

    # This module owns these streams: start clean so a second run does not double them.
    for name in BIOME_STREAMS:
        shutil.rmtree(lib.biome_stream_dir(root, name), ignore_errors=True)

    # --- Simulate -----------------------------------------------------------------------
    mac_sessions, mac_blocks = _simulate_mac(persona, days, rng)
    phone_end = days.end - rng.uniform(9, 28) * 60            # last sync of each device
    watch_end = days.end - rng.uniform(40, 95) * 60
    pad_end = days.end - rng.uniform(3, 9) * 3600
    phone_sessions = _simulate_phone(persona, days, rng, phone_end)
    pad_sessions = _simulate_pad(persona, days, rng, pad_end)
    watch_sessions, workouts = _simulate_watch(persona, days, rng, watch_end)

    # --- App.InFocus ----------------------------------------------------------------------
    versions = _versions([s[2] for s in mac_sessions + phone_sessions + pad_sessions + watch_sessions], rng)
    focus = lib.biome_stream_dir(root, "App.InFocus")
    lib.write_stream(focus, _focus_records(mac_sessions, versions, rng, LOCK, days.end))
    lib.write_stream(focus, _focus_records(phone_sessions, versions, rng, None, None), device=phone.identifier)
    lib.write_stream(focus, _focus_records(pad_sessions, versions, rng, None, None), device=pad.identifier)
    lib.write_stream(focus, _focus_records(watch_sessions, versions, rng, None, None), device=watch.identifier)

    # --- ScreenTime.AppUsage (this Mac, Unix timestamps) ------------------------------------
    since = days.end - SCREENTIME_DAYS * DAY
    block_ends = [b[1] for b in mac_blocks]
    lib.write_stream(lib.biome_stream_dir(root, "ScreenTime.AppUsage"),
                     _screentime_records([s for s in mac_sessions if s[0] >= since], block_ends))

    # --- Web ------------------------------------------------------------------------------
    pages = _pages(rng, days)
    visits = _web_visits([s for s in mac_sessions if s[0] >= days.end - 60 * DAY], pages, rng)
    web_records = []
    for index, (start, end, tab, page) in enumerate(visits):
        if start < days.end - 35 * DAY:
            continue
        state = 2 if rng.random() < 0.85 else 3
        web_records.append((start, pb.message([(1, tab), (2, pb.double(lib.cocoa(start))), (3, state), (4, page[2]), (5, page[0]),
                                               (6, "com.apple.Safari"), (8, 0)])))
        following = visits[index + 1] if index + 1 < len(visits) else None
        if following is None or following[2] != tab or following[0] - end > 1:
            web_records.append((end, pb.message([(1, tab), (2, pb.double(lib.cocoa(end))), (3, 1), (4, page[2]), (5, page[0]),
                                                 (6, "com.apple.Safari"), (8, 0)])))
    lib.write_stream(lib.biome_stream_dir(root, "App.WebUsage"), web_records)
    navigations = []
    for start, _end, _tab, page in visits:
        if start >= days.end - 21 * DAY:
            coarse = math.floor(start / 900) * 900.0
            navigations.append((start, pb.message([(1, page[1]), (2, pb.double(coarse)), (3, 1), (4, 1), (5, persona.region), (6, 0),
                                                   (7, 0), (8, page[2]), (10, 0)])))
    lib.write_stream(lib.biome_stream_dir(root, "Safari.Navigations"), navigations)
    lib.write_stream(lib.biome_stream_dir(root, "Safari.PageLoad"),
                     [(start + 0.4, pb.message([(1, pb.double(lib.cocoa(start))), (2, rng.randint(180, 4200))]))
                      for start, _e, _t, _p in visits if start >= days.end - 21 * DAY])
    lib.write_stream(lib.biome_stream_dir(root, "Safari.SearchEngine"),
                     [(days.end - 96 * DAY, pb.message([(1, "com.google.www")]))])

    # --- Media ----------------------------------------------------------------------------
    media = _generate_media(persona, days, rng, mac_blocks, phone_end, pad_end, watch_end, workouts)
    now_playing = lib.biome_stream_dir(root, "Media.NowPlaying")
    for device, records in media.records.items():
        lib.write_stream(now_playing, [r for r in records if r[0] < days.end], device=device)
    media_usage = []
    usage_records = []
    clip_pages = [p[2] for p in pages if "watch?v=" in p[2]]
    for sitting in media.sittings:
        if sitting["device"] is not None or sitting["start"] < days.end - 40 * DAY or sitting["end"] >= days.end:
            continue
        url = rng.choice(clip_pages) if sitting["bundle"] == "com.apple.Safari" else ""
        media_usage.append((sitting["start"], sitting["end"], sitting["bundle"], url))
        session = lib.uuid_string(rng)
        for t, starting in ((sitting["start"], True), (sitting["end"], False)):
            usage_records.append((t, pb.message([(1, starting), (2, sitting["bundle"]), (3, url or None), (5, 1),
                                                 (6, pb.double(t)), (8, session)])))
    lib.write_stream(lib.biome_stream_dir(root, "App.MediaUsage"), usage_records)

    # --- knowledgeC, DuetExpert, Games view ---------------------------------------------------
    _write_knowledge(root, persona, days, rng, mac_sessions, mac_blocks, visits, media_usage)
    _write_duet(root, persona, days, rng, mac_sessions, mac_blocks, media)
    _write_games(root, days, mac_sessions, rng)
