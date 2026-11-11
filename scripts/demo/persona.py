"""The invented person all demo generators describe.

"Robin Sample" lives in Wellington, New Zealand and works at the invented company
"Kōwhai Labs". Every name is made up; e-mail addresses use example.com / example.org /
example.net; phone numbers use the range reserved for fiction (+1 202 555 01xx); places are
well-known public landmarks, invented cafés and public streets in Wellington with
approximate public coordinates (private places carry no house number); device and record identifiers are random.

    persona = build(seed)            # make-demo-data.py does this once and passes it on
    persona.owner.full_name          # "Robin Sample"
    persona.person("partner")        # by relationship key or id
    persona.people_with("colleague") # list
    persona.place("home")            # by key
    persona.device("iphone").identifier
    persona.app("com.apple.MobileSMS").name

Identifiers are derived from the seed only, so every generator sees the same ones and two
runs with the same seed agree on everything except dates (which follow the clock).

Do not add anything here that was read from a real store.
"""

from __future__ import annotations

import random
import re
import uuid
from dataclasses import dataclass, field
from typing import Optional

SEED_DEFAULT = 20260101


def _uuid(rng: random.Random) -> str:
    return str(uuid.UUID(int=rng.getrandbits(128), version=4)).upper()


@dataclass(frozen=True)
class Person:
    key: str                    # stable short id: "robin", "alex", …
    given: str
    family: str
    relationship: str           # owner / partner / mother / father / sister / friend / colleague / manager / service
    relationship_label: str     # as Contacts stores it: "_$!<Partner>!$_", "" when none
    emails: tuple[str, ...]
    phones: tuple[str, ...]     # E.164, reserved fictional range
    contact_id: str             # CNContact identifier ("<UUID>:ABPerson")
    graph_id: int               # knowledge-graph node id (md:<n>)
    nickname: str = ""
    birthday: Optional[tuple[int, int, int]] = None   # (year, month, day), invented
    organization: str = ""
    job_title: str = ""
    favourite: bool = False
    closeness: float = 0.5      # 0…1: how much the owner interacts with them

    @property
    def full_name(self) -> str:
        return f"{self.given} {self.family}".strip()

    @property
    def email(self) -> str:
        return self.emails[0] if self.emails else ""

    @property
    def phone(self) -> str:
        return self.phones[0] if self.phones else ""

    @property
    def handle(self) -> str:
        """The handle messaging stores would use: phone if there is one, else e-mail."""
        return self.phone or self.email

    @property
    def initials(self) -> str:
        return (self.given[:1] + self.family[:1]).upper()


@dataclass(frozen=True)
class Place:
    key: str                    # "home", "work", "te_papa", …
    name: str
    kind: str                   # home / work / cafe / landmark / park / transit / gym / shop / travel
    street: str
    city: str
    region: str
    postal_code: str
    country: str
    country_code: str
    latitude: float             # approximate, public
    longitude: float
    graph_id: int
    label: str = ""             # personal label as the system stores it ("_$!<Home>!$_")
    visits_per_month: int = 0   # rough frequency for generators

    @property
    def coordinate(self) -> tuple[float, float]:
        return (self.latitude, self.longitude)

    @property
    def address(self) -> str:
        return ", ".join(p for p in (self.street, self.city, self.postal_code, self.country) if p)

    def jitter(self, rng: random.Random, metres: float = 25.0) -> tuple[float, float]:
        """A coordinate near the place (for visit / photo records)."""
        d = metres / 111_000.0
        return (self.latitude + rng.uniform(-d, d), self.longitude + rng.uniform(-d, d) * 1.3)


@dataclass(frozen=True)
class Device:
    key: str                    # "mac", "iphone", "watch", "ipad"
    name: str                   # user-assigned device name
    kind: str                   # Mac / iPhone / Apple Watch / iPad
    platform: int               # Biome sync.db platform code: 2 iPhone/iPad, 3 Mac, 4 Apple Watch
    model: str                  # hardware model identifier (generic)
    os_name: str
    os_version: str
    os_build: str               # what sync.db calls "model"
    identifier: str             # Biome device identifier (directory name under remote/)
    ids_identifier: str
    is_me: bool = False         # the Mac the data set pretends to be read on


@dataclass(frozen=True)
class App:
    bundle_id: str
    name: str
    category: str               # productivity / communication / browser / media / social / utility / travel / health / developer / finance
    platforms: tuple[str, ...]  # subset of ("mac", "iphone", "ipad", "watch")
    weight: float = 1.0         # relative usage


@dataclass(frozen=True)
class Track:
    title: str
    artist: str
    album: str
    seconds: int
    genre: str


@dataclass(frozen=True)
class Topic:
    name: str
    qid: str                    # Wikidata id, best effort — check against the app's compiled topic table
    weight: float = 1.0


@dataclass(frozen=True)
class Network:
    ssid: str
    place: str                  # Place.key
    security: str


@dataclass
class Persona:
    seed: int
    people: list[Person]
    places: list[Place]
    devices: list[Device]
    apps: list[App]
    tracks: list[Track]
    podcasts: list[tuple[str, str]]          # (show, episode)
    topics: list[Topic]
    web_domains: list[tuple[str, str]]       # (domain, page title)
    networks: list[Network]
    company: str = "Kōwhai Labs"
    company_domain: str = "example.org"
    locale: str = "en_NZ"
    language: str = "en"
    region: str = "NZ"
    time_zone: str = "Pacific/Auckland"
    tz_offset_hours: float = 13.0            # NZDT; fixed so output does not depend on tzdata
    family_group_graph_id: int = 0
    company_graph_id: int = 0
    languages: tuple[str, ...] = ("en", "mi")
    _people: dict = field(default_factory=dict, repr=False)

    # -- lookups ------------------------------------------------------------------------
    @property
    def owner(self) -> Person:
        return self.people[0]

    @property
    def others(self) -> list[Person]:
        return self.people[1:]

    def person(self, key: str) -> Person:
        """By key ("alex") or by relationship ("partner"; the first match)."""
        for p in self.people:
            if p.key == key:
                return p
        for p in self.people:
            if p.relationship == key:
                return p
        raise KeyError(key)

    def people_with(self, relationship: str) -> list[Person]:
        return [p for p in self.people if p.relationship == relationship]

    @property
    def family(self) -> list[Person]:
        return [p for p in self.people if p.relationship in ("partner", "mother", "father", "sister")]

    def place(self, key: str) -> Place:
        for p in self.places:
            if p.key == key:
                return p
        raise KeyError(key)

    def device(self, key: str) -> Device:
        for d in self.devices:
            if d.key == key:
                return d
        raise KeyError(key)

    @property
    def this_mac(self) -> Device:
        return next(d for d in self.devices if d.is_me)

    @property
    def remote_devices(self) -> list[Device]:
        return [d for d in self.devices if not d.is_me]

    def app(self, bundle_id: str) -> App:
        for a in self.apps:
            if a.bundle_id == bundle_id:
                return a
        raise KeyError(bundle_id)

    def apps_on(self, platform: str) -> list[App]:
        return [a for a in self.apps if platform in a.platforms]

    def weighted_person(self, rng: random.Random) -> Person:
        """Someone other than the owner, close contacts more often."""
        others = self.others
        return rng.choices(others, weights=[max(0.02, p.closeness) for p in others])[0]

    def weighted_app(self, rng: random.Random, platform: str = "mac") -> App:
        apps = self.apps_on(platform)
        return rng.choices(apps, weights=[a.weight for a in apps])[0]


# ----------------------------------------------------------------------------------------
# Content (all invented)
# ----------------------------------------------------------------------------------------

_PEOPLE = [
    # key, given, family, relationship, label, email local parts/domains, nickname, birthday, organization, title, favourite, closeness
    ("robin", "Robin", "Sample", "owner", "", ("robin@example.com", "robin.sample@example.org"), "Rob", (1991, 3, 14), "Kōwhai Labs", "Product Designer", False, 1.0),
    ("alex", "Alex", "Marlowe", "partner", "_$!<Partner>!$_", ("alex.marlowe@example.com",), "", (1990, 8, 2), "", "", True, 0.95),
    ("helen", "Helen", "Sample", "mother", "_$!<Mother>!$_", ("helen.sample@example.net",), "Mum", (1962, 11, 23), "", "", True, 0.7),
    ("david", "David", "Sample", "father", "_$!<Father>!$_", ("david.sample@example.net",), "Dad", (1960, 5, 9), "", "", False, 0.5),
    ("jamie", "Jamie", "Sample", "sister", "_$!<Sister>!$_", ("jamie.sample@example.com",), "", (1994, 1, 30), "", "", True, 0.75),
    ("priya", "Priya", "Raman", "friend", "_$!<Friend>!$_", ("priya.raman@example.com",), "", (1991, 6, 18), "", "", False, 0.65),
    ("tom", "Tom", "Okafor", "friend", "", ("tom.okafor@example.net",), "", None, "", "", False, 0.55),
    ("mei", "Mei", "Tanaka", "friend", "", ("mei.tanaka@example.com",), "", (1992, 9, 5), "", "", False, 0.45),
    ("sam", "Sam", "Whitford", "friend", "", ("sam.whitford@example.net",), "", None, "", "", False, 0.3),
    ("aroha", "Aroha", "Ngata", "manager", "_$!<Manager>!$_", ("aroha.ngata@example.org",), "", None, "Kōwhai Labs", "Head of Product", False, 0.6),
    ("lucas", "Lucas", "Bennett", "colleague", "", ("lucas.bennett@example.org",), "", None, "Kōwhai Labs", "Software Engineer", False, 0.6),
    ("nina", "Nina", "Petrov", "colleague", "", ("nina.petrov@example.org",), "", None, "Kōwhai Labs", "Researcher", False, 0.5),
    ("oliver", "Oliver", "Grant", "colleague", "", ("oliver.grant@example.org",), "", None, "Kōwhai Labs", "Engineering Manager", False, 0.35),
    ("hana", "Hana", "Kimura", "colleague", "", ("hana.kimura@example.org",), "", None, "Kōwhai Labs", "Data Analyst", False, 0.3),
    ("drlee", "Morgan", "Lee", "service", "", ("reception@example.net",), "", None, "Harbour Street Dental", "Dentist", False, 0.08),
    ("landlord", "Chris", "Aldous", "service", "", ("chris.aldous@example.net",), "", None, "", "", False, 0.1),
]

_PLACES = [
    # key, name, kind, street, postal, lat, lon, label, visits per month — Wellington, approximate public coordinates
    ("home", "Home", "home", "Aro Street", "6021", -41.2957, 174.7672, "_$!<Home>!$_", 60),
    ("work", "Kōwhai Labs", "work", "Lambton Quay", "6011", -41.2823, 174.7757, "_$!<Work>!$_", 20),
    ("cafe", "Tūī & Fern Café", "cafe", "Cuba Street", "6011", -41.2935, 174.7757, "", 9),
    ("coffee", "Harbour Light Coffee", "cafe", "Queens Wharf", "6011", -41.2852, 174.7790, "", 5),
    ("te_papa", "Te Papa Tongarewa", "landmark", "55 Cable Street", "6011", -41.2905, 174.7821, "", 1),
    ("botanic", "Wellington Botanic Garden", "park", "101 Glenmore Street", "6012", -41.2829, 174.7669, "", 3),
    ("mt_vic", "Mount Victoria Lookout", "landmark", "Lookout Road", "6011", -41.2960, 174.7943, "", 2),
    ("cable_car", "Wellington Cable Car", "landmark", "280 Lambton Quay", "6011", -41.2850, 174.7749, "", 1),
    ("zealandia", "Zealandia", "park", "53 Waiapu Road", "6012", -41.2903, 174.7533, "", 1),
    ("oriental", "Oriental Bay", "park", "Oriental Parade", "6011", -41.2912, 174.7940, "", 4),
    ("station", "Wellington Railway Station", "transit", "Bunny Street", "6011", -41.2790, 174.7805, "", 6),
    ("airport", "Wellington Airport", "transit", "Stewart Duff Drive", "6022", -41.3272, 174.8053, "", 1),
    ("gym", "Te Aro Climbing Gym", "gym", "Taranaki Street", "6011", -41.2948, 174.7748, "_$!<Gym>!$_", 8),
    ("market", "Harbourside Market", "shop", "Barnett Street", "6011", -41.2917, 174.7836, "", 3),
    ("parents", "Helen & David", "home", "Marine Parade", "5032", -40.9146, 174.9820, "", 1),
]

_TRAVEL = [
    # key, name, city, region, postal, lat, lon
    ("auckland", "Sky Tower", "Auckland", "Auckland", "1010", -36.8485, 174.7622),
    ("queenstown", "Queenstown Gardens", "Queenstown", "Otago", "9300", -45.0370, 168.6600),
    ("rotorua", "Government Gardens", "Rotorua", "Bay of Plenty", "3010", -38.1357, 176.2590),
]

_DEVICES = [
    # key, name, kind, platform, model, os name, version, build, is_me
    ("mac", "Robin's MacBook Pro", "Mac", 3, "Mac15,6", "macOS", "27.2", "27C52", True),
    ("iphone", "Robin's iPhone", "iPhone", 2, "iPhone16,2", "iOS", "27.2", "25C50", False),
    ("watch", "Robin's Apple Watch", "Apple Watch", 4, "Watch7,3", "watchOS", "27.2", "25S48", False),
    ("ipad", "Robin's iPad", "iPad", 2, "iPad14,3", "iPadOS", "27.1", "25B61", False),
]

_APPS = [
    ("com.apple.Safari", "Safari", "browser", ("mac",), 9),
    ("com.apple.mobilesafari", "Safari", "browser", ("iphone", "ipad"), 9),
    ("com.apple.mail", "Mail", "communication", ("mac",), 7),
    ("com.apple.mobilemail", "Mail", "communication", ("iphone", "ipad"), 5),
    ("com.apple.MobileSMS", "Messages", "communication", ("mac", "iphone", "ipad", "watch"), 8),
    ("com.apple.iCal", "Calendar", "productivity", ("mac",), 3),
    ("com.apple.mobilecal", "Calendar", "productivity", ("iphone", "ipad"), 2),
    ("com.apple.Notes", "Notes", "productivity", ("mac",), 4),
    ("com.apple.mobilenotes", "Notes", "productivity", ("iphone", "ipad"), 3),
    ("com.apple.reminders", "Reminders", "productivity", ("mac", "iphone"), 2),
    ("com.apple.Music", "Music", "media", ("mac", "iphone", "watch"), 5),
    ("com.apple.podcasts", "Podcasts", "media", ("mac", "iphone"), 3),
    ("com.apple.Photos", "Photos", "media", ("mac",), 3),
    ("com.apple.mobileslideshow", "Photos", "media", ("iphone", "ipad"), 3),
    ("com.apple.camera", "Camera", "media", ("iphone",), 3),
    ("com.apple.Maps", "Maps", "travel", ("mac", "iphone", "watch"), 3),
    ("com.apple.finder", "Finder", "utility", ("mac",), 4),
    ("com.apple.Terminal", "Terminal", "developer", ("mac",), 3),
    ("com.apple.dt.Xcode", "Xcode", "developer", ("mac",), 2),
    ("com.apple.Preview", "Preview", "utility", ("mac",), 2),
    ("com.apple.systempreferences", "System Settings", "utility", ("mac",), 1),
    ("com.apple.Preferences", "Settings", "utility", ("iphone", "ipad"), 1),
    ("com.apple.FaceTime", "FaceTime", "communication", ("mac",), 1),
    ("com.apple.facetime", "FaceTime", "communication", ("iphone", "ipad"), 1),
    ("com.apple.mobilephone", "Phone", "communication", ("iphone",), 2),
    ("com.apple.weather", "Weather", "utility", ("mac", "iphone", "watch"), 2),
    ("com.apple.Fitness", "Fitness", "health", ("iphone",), 1),
    ("com.apple.SessionTrackerApp", "Workout", "health", ("watch",), 2),
    ("com.apple.Health", "Health", "health", ("iphone",), 1),
    ("com.apple.iBooksX", "Books", "media", ("mac",), 1),
    ("com.apple.iBooks", "Books", "media", ("iphone", "ipad"), 2),
    ("com.apple.Passbook", "Wallet", "finance", ("iphone", "watch"), 1),
    ("com.apple.freeform", "Freeform", "productivity", ("mac", "ipad"), 1),
    ("com.apple.shortcuts", "Shortcuts", "utility", ("mac", "iphone"), 1),
    # Very widely used third-party apps (names come from the app's own table, not from this Mac).
    ("com.tinyspeck.slackmacgap", "Slack", "communication", ("mac",), 7),
    ("com.tinyspeck.chatlyio", "Slack", "communication", ("iphone",), 3),
    ("us.zoom.xos", "Zoom", "communication", ("mac",), 2),
    ("us.zoom.videomeetings", "Zoom", "communication", ("iphone",), 1),
    ("net.whatsapp.WhatsApp", "WhatsApp", "communication", ("mac", "iphone"), 5),
    ("org.whispersystems.signal", "Signal", "communication", ("iphone",), 2),
    ("com.spotify.client", "Spotify", "media", ("mac", "iphone"), 4),
    ("com.google.ios.youtube", "YouTube", "media", ("iphone", "ipad"), 3),
    ("com.burbn.instagram", "Instagram", "social", ("iphone",), 3),
    ("com.figma.Desktop", "Figma", "productivity", ("mac",), 6),
    ("com.microsoft.VSCode", "Visual Studio Code", "developer", ("mac",), 3),
    ("notion.id", "Notion", "productivity", ("mac",), 3),
    ("com.google.Maps", "Google Maps", "travel", ("iphone",), 1),
    ("com.github.stormbreaker.prod", "GitHub", "developer", ("iphone",), 1),
]

# Public-domain classical works and invented performers.
_TRACKS = [
    ("Clair de lune", "Wellington Harbour Ensemble", "Suite bergamasque", 302, "Classical"),
    ("Gymnopédie No. 1", "Tess Aldridge", "Quiet Piano", 198, "Classical"),
    ("The Four Seasons: Spring, I. Allegro", "Southern Strings", "Vivaldi: The Four Seasons", 205, "Classical"),
    ("Cello Suite No. 1 in G major: Prélude", "Ines Marchetti", "Bach: Cello Suites", 152, "Classical"),
    ("Nocturne in E-flat major, Op. 9 No. 2", "Tess Aldridge", "Quiet Piano", 270, "Classical"),
    ("Canon in D", "Southern Strings", "Baroque Favourites", 318, "Classical"),
    ("Morning Mood", "Wellington Harbour Ensemble", "Peer Gynt Suites", 241, "Classical"),
    ("Pōneke Sunrise", "The Paper Kites Club", "Windy City", 214, "Indie"),
    ("Ferry to Days Bay", "The Paper Kites Club", "Windy City", 187, "Indie"),
    ("Southerly", "Kererū", "Low Cloud", 233, "Electronic"),
    ("Low Cloud", "Kererū", "Low Cloud", 256, "Electronic"),
    ("Blue Note for Cuba Street", "Marlow Quartet", "Late Set", 344, "Jazz"),
    ("Late Set", "Marlow Quartet", "Late Set", 291, "Jazz"),
    ("Tide Tables", "Anna Fairlie", "Small Hours", 223, "Folk"),
    ("Small Hours", "Anna Fairlie", "Small Hours", 247, "Folk"),
    ("Runway 34", "Glasshouse", "Departures", 201, "Pop"),
]

_PODCASTS = [
    ("The Design Detail Hour", "Episode 112: Naming things"),
    ("Slow News Weekly", "The week in review"),
    ("Trail Notes", "Tararua Southern Crossing"),
    ("Birdsong Aotearoa", "Kākā in the city"),
    ("Everyday Science", "How tides work"),
]

_TOPICS = [
    ("Wellington", "Q23661", 3), ("New Zealand", "Q664", 3), ("coffee", "Q8486", 2.5), ("photography", "Q11633", 2.5),
    ("hiking", "Q12014035", 2), ("cycling", "Q53121", 1.5), ("rock climbing", "Q1154336", 2), ("jazz", "Q8341", 1.5),
    ("typography", "Q164806", 2), ("graphic design", "Q185925", 2.5), ("bird", "Q5113", 1.5), ("astronomy", "Q333", 1),
    ("cooking", "Q38695", 1.5), ("rugby union", "Q5849", 1), ("sailing", "Q14085739", 1), ("machine learning", "Q2539", 1),
    ("classical music", "Q9730", 1.5), ("book", "Q571", 1), ("film", "Q11424", 1), ("travel", "Q61509", 1.5),
    ("tea", "Q6097", 1), ("gardening", "Q124946", 1),
]

_WEB = [
    ("wikipedia.org", "Wikipedia"), ("github.com", "GitHub"), ("youtube.com", "YouTube"), ("metservice.com", "MetService"),
    ("doc.govt.nz", "Department of Conservation"), ("bbc.com", "BBC"), ("stackoverflow.com", "Stack Overflow"),
    ("developer.apple.com", "Apple Developer"), ("openstreetmap.org", "OpenStreetMap"), ("example.com", "Example Domain"),
    ("example.org", "Kōwhai Labs Intranet"), ("archive.org", "Internet Archive"),
]

_NETWORKS = [
    ("Sample-Home", "home", "WPA3 Personal"),
    ("KowhaiLabs", "work", "WPA2 Enterprise"),
    ("TuiAndFern-Guest", "cafe", "WPA2 Personal"),
    ("Airport-Free-WiFi", "airport", "Open"),
    ("Robin's iPhone", "home", "WPA3 Personal"),
]


def build(seed: int = SEED_DEFAULT) -> Persona:
    """The persona for a seed. Only identifiers depend on the seed; names never do."""
    rng = random.Random(f"dossier-demo-persona-{seed}")

    # Knowledge-graph node ids are 18-digit positive integers.
    graph_ids = iter(sorted({rng.randrange(10 ** 17, 10 ** 18) for _ in range(400)}, key=lambda _: rng.random()))

    people: list[Person] = []
    for index, (key, given, family, relationship, label, emails, nick, birthday, org, title, fav, closeness) in enumerate(_PEOPLE):
        phones: tuple[str, ...] = (f"+1202555{100 + index:04d}",)   # +1 202 555 01xx: reserved for fiction
        if key in ("tom", "hana"):
            phones = ()
        people.append(Person(
            key=key, given=given, family=family, relationship=relationship, relationship_label=label,
            emails=tuple(emails), phones=phones, contact_id=_uuid(rng) + ":ABPerson", graph_id=next(graph_ids),
            nickname=nick, birthday=birthday, organization=org, job_title=title, favourite=fav, closeness=closeness))

    places: list[Place] = []
    for key, name, kind, street, postal, lat, lon, label, visits in _PLACES:
        city = "Paraparaumu" if key == "parents" else "Wellington"
        places.append(Place(key=key, name=name, kind=kind, street=street, city=city, region="Wellington",
                            postal_code=postal, country="New Zealand", country_code="NZ", latitude=lat, longitude=lon,
                            graph_id=next(graph_ids), label=label, visits_per_month=visits))
    for key, name, city, region, postal, lat, lon in _TRAVEL:
        places.append(Place(key=key, name=name, kind="travel", street="", city=city, region=region, postal_code=postal,
                            country="New Zealand", country_code="NZ", latitude=lat, longitude=lon,
                            graph_id=next(graph_ids), label="", visits_per_month=0))

    devices = [Device(key=key, name=name, kind=kind, platform=platform, model=model, os_name=os_name,
                      os_version=version, os_build=build_id, identifier=_uuid(rng), ids_identifier=_uuid(rng), is_me=me)
               for key, name, kind, platform, model, os_name, version, build_id, me in _DEVICES]

    persona = Persona(
        seed=seed, people=people, places=places, devices=devices,
        apps=[App(b, n, c, tuple(p), float(w)) for b, n, c, p, w in _APPS],
        tracks=[Track(*t) for t in _TRACKS],
        podcasts=list(_PODCASTS),
        topics=[Topic(n, q, float(w)) for n, q, w in _TOPICS],
        web_domains=list(_WEB),
        networks=[Network(*n) for n in _NETWORKS],
    )
    persona.family_group_graph_id = next(graph_ids)
    persona.company_graph_id = next(graph_ids)
    return persona


def audit(persona: Persona) -> list[str]:
    """Problems with the persona's own rules (reserved domains / numbers). Empty = fine."""
    problems: list[str] = []
    allowed = ("example.com", "example.org", "example.net")
    for p in persona.people:
        for e in p.emails:
            if e.rsplit("@", 1)[-1] not in allowed:
                problems.append(f"{p.key}: e-mail domain not reserved: {e}")
        for n in p.phones:
            if not re.fullmatch(r"\+1\d{3}55501\d{2}", n):
                problems.append(f"{p.key}: phone outside the fictional range +1 xxx 555 01xx: {n}")
    ids = [p.graph_id for p in persona.people] + [p.graph_id for p in persona.places]
    if len(set(ids)) != len(ids):
        problems.append("duplicate graph ids")
    if len({d.identifier for d in persona.devices}) != len(persona.devices):
        problems.append("duplicate device identifiers")
    if sum(1 for d in persona.devices if d.is_me) != 1:
        problems.append("exactly one device must be 'me'")
    return problems
