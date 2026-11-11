"""Demo data for the Photos Intelligence module (`photos`).

Writes an invented Photos library below `<root>/Home/Pictures/Photos Library.photoslibrary`:

    database/Photos.sqlite                                   assets, faces, people, moments, highlights, memories,
                                                             suggestions, shares, the "Leo" search lexicon, the embedded
                                                             caption graph, per-asset reverse-geocode archives
    database/search/psi.sqlite                               the legacy search index (stops some months before now)
    private/com.apple.photoanalysisd/caches/graph/PhotosGraph/photosgraph.kgdb
                                                             the PhotosGraph knowledge graph (sparse-bitmap labels)
    private/com.apple.mediaanalysisd/MediaAnalysis/MediaAnalysis.sqlite
                                                             machine captions and audio / safety analysis rows

One simulation drives all four stores, so they agree with each other: the persona's days are
turned into "moments" (who, where, when, what kind of occasion), moments into assets, and assets
into faces, scene labels, captions, recognised text, index terms and graph edges.

Schema (tables, columns, code values, archive class and key names, identifier shapes) follows the
real stores; every value is invented or comes from `persona.py`. Places that are not in the
persona (two trips abroad, a few businesses) are public landmarks or made-up names.
No file is shared with another module.
"""

from __future__ import annotations

import datetime
import math
import pathlib
import random
import struct
from dataclasses import dataclass, field
from typing import Any, Iterable, Optional

from . import lib
from .persona import Persona

# ----------------------------------------------------------------------------------------
# Tunables
# ----------------------------------------------------------------------------------------

SPAN_DAYS = 2340            # how far back the library reaches (about six and a half years)
OLD_HOME_UNTIL = 1560       # days ago until which the persona lived at the previous flat
SHARED_LIBRARY_SINCE = 760  # days ago the shared library with the partner was set up
PSI_STOPS = 210             # the legacy index was last updated this many days ago

LOCAL_ID_ASSET = "/L0/001"
LOCAL_ID_MOMENT = "/L0/060"
LOCAL_ID_PERSON = "/L0/070"
LOCAL_ID_HIGHLIGHT = "/L0/100"

# ----------------------------------------------------------------------------------------
# Places
# ----------------------------------------------------------------------------------------


@dataclass
class Spot:
    key: str
    name: str                 # public name ("" for private places)
    street: str
    suburb: str
    city: str
    region: str
    postal: str
    country: str
    cc: str
    lat: float
    lon: float
    context: str              # which scene / caption pool its photos use
    water: str = ""
    poi: tuple = ()           # graph POI classes
    roi: str = ""             # graph ROI class
    business: Optional[tuple] = None   # (name, (categories…), capacity or 0)
    landmark: str = ""
    spread: float = 40.0      # metres of scatter for photo coordinates
    private: str = ""         # "home" / "work" / "" — personal label of the place

    @property
    def street_name(self) -> str:
        """The street without a leading house number ("55 Cable Street" -> "Cable Street")."""
        head, _, tail = self.street.partition(" ")
        return tail if head.isdigit() and tail else self.street


# persona place key -> (suburb, context, water, poi classes, roi, business, landmark)
_WELLINGTON = {
    "home": ("Aro Valley", "home", "", (), "Urban", None, ""),
    "work": ("Wellington Central", "work", "", (), "Urban", None, ""),
    "cafe": ("Te Aro", "cafe", "", ("Restaurant",), "Urban", ("Cafe", "Coffee Shop", "Bakery"), ""),
    "coffee": ("Wellington Central", "cafe", "Wellington Harbour", ("Restaurant",), "Water", ("Coffee Shop", "Cafe"), ""),
    "te_papa": ("Te Aro", "museum", "Wellington Harbour", ("Museum", "Culture"), "Urban", ("Museum", "Landmark", "Cultural Center"), "Te Papa Tongarewa"),
    "botanic": ("Kelburn", "park", "", ("Park",), "Nature", ("Park", "Landmark"), "Wellington Botanic Garden"),
    "mt_vic": ("Mount Victoria", "lookout", "", ("Park", "Hiking"), "Mountain", None, "Mount Victoria Lookout"),
    "cable_car": ("Wellington Central", "transit", "", ("Travel", "Culture"), "Urban", ("Tourist Experience", "Landmark"), "Wellington Cable Car"),
    "zealandia": ("Karori", "park", "", ("Park", "Hiking"), "Nature", ("Park", "Tourist Experience"), "Zealandia"),
    "oriental": ("Oriental Bay", "beach", "Wellington Harbour", ("Park",), "Beach", None, ""),
    "station": ("Pipitea", "transit", "", ("Travel",), "Urban", None, "Wellington Railway Station"),
    "airport": ("Rongotai", "airport", "Cook Strait", ("Travel",), "Urban", None, ""),
    "gym": ("Te Aro", "gym", "", ("Activity",), "Urban", ("Fitness Center", "Sports Complex"), ""),
    "market": ("Te Aro", "market", "Wellington Harbour", ("Activity",), "Urban", ("Food Mart", "Shopping"), ""),
    "parents": ("Paraparaumu Beach", "family", "Tasman Sea", (), "Beach", None, ""),
    "auckland": ("Auckland CBD", "city", "Waitematā Harbour", ("Travel", "Culture"), "Urban", ("Landmark", "Tourist Experience"), "Sky Tower"),
    "queenstown": ("Queenstown", "alpine", "Lake Wakatipu", ("Park", "Hiking"), "Mountain", ("Park", "Landmark"), ""),
    "rotorua": ("Rotorua", "geothermal", "Lake Rotorua", ("Park", "Culture"), "Nature", ("Park", "Landmark"), ""),
}

# Further places, all invented names or public landmarks with approximate public coordinates.
# key, name, street, suburb, city, region, postal, country, cc, lat, lon, context, water, poi, roi, business, landmark, spread, private
_EXTRA = [
    ("old_home", "", "Riddiford Street", "Newtown", "Wellington", "Wellington", "6021", "New Zealand", "NZ", -41.3135, 174.7790, "home", "", (), "Urban", None, "", 25, "home"),
    ("noodles", "Left Bank Noodle House", "Cuba Street", "Te Aro", "Wellington", "Wellington", "6011", "New Zealand", "NZ", -41.2928, 174.7762, "dinner", "", ("Restaurant",), "Urban", ("Left Bank Noodle House", ("Noodle Restaurant", "Asian Cuisine", "Restaurant"), 0), "", 15, ""),
    ("brewery", "Hop & Harbour Brewing", "Taranaki Street", "Te Aro", "Wellington", "Wellington", "6011", "New Zealand", "NZ", -41.2932, 174.7755, "dinner", "", ("Nightlife", "Restaurant"), "Urban", ("Hop & Harbour Brewing", ("Brewery", "Bar", "Pub Food"), 0), "", 15, ""),
    ("cinema", "Courtenay Lane Cinema", "Courtenay Place", "Te Aro", "Wellington", "Wellington", "6011", "New Zealand", "NZ", -41.2936, 174.7810, "dinner", "", ("Entertainment",), "Urban", ("Courtenay Lane Cinema", ("Movie Theater", "Arts"), 420), "", 15, ""),
    ("hall", "Harbour Hall", "Wakefield Street", "Te Aro", "Wellington", "Wellington", "6011", "New Zealand", "NZ", -41.2890, 174.7790, "concert", "", ("Entertainment", "Nightlife"), "Urban", ("Harbour Hall", ("Music Venue", "Event Venue", "Performing Arts Center"), 1800), "", 20, ""),
    ("dental", "Harbour Street Dental", "Featherston Street", "Wellington Central", "Wellington", "Wellington", "6011", "New Zealand", "NZ", -41.2815, 174.7770, "clinic", "", ("Hospital",), "Urban", None, "", 10, ""),
    ("clinic", "Wellington Regional Hospital", "Riddiford Street", "Newtown", "Wellington", "Wellington", "6021", "New Zealand", "NZ", -41.3085, 174.7790, "clinic", "", ("Hospital",), "Urban", None, "", 30, ""),
    ("akl_viaduct", "Viaduct Harbour", "Quay Street", "Auckland CBD", "Auckland", "Auckland", "1010", "New Zealand", "NZ", -36.8430, 174.7590, "city", "Waitematā Harbour", ("Restaurant", "Travel"), "Water", ("Viaduct Oyster Room", ("Seafood Restaurant", "Restaurant", "Bar"), 0), "", 120, ""),
    ("akl_arena", "Wynyard Arena", "Halsey Street", "Wynyard Quarter", "Auckland", "Auckland", "1010", "New Zealand", "NZ", -36.8418, 174.7560, "concert", "Waitematā Harbour", ("Entertainment", "Stadium"), "Urban", ("Wynyard Arena", ("Music Venue", "Event Venue"), 6500), "", 30, ""),
    ("zqn_lake", "Lake Wakatipu", "Marine Parade", "Queenstown", "Queenstown", "Otago", "9300", "New Zealand", "NZ", -45.0335, 168.6585, "alpine", "Lake Wakatipu", ("Park", "Travel"), "Water", ("Lakefront Pizza Co.", ("Pizza Restaurant", "Restaurant", "Italian Cuisine"), 0), "", 350, ""),
    ("zqn_track", "Queenstown Hill Track", "Belfast Terrace", "Queenstown", "Queenstown", "Otago", "9300", "New Zealand", "NZ", -45.0235, 168.6710, "alpine", "Lake Wakatipu", ("Hiking", "Park"), "Mountain", None, "", 600, ""),
    ("rot_lake", "Lake Rotorua", "Lakefront Drive", "Rotorua", "Rotorua", "Bay of Plenty", "3010", "New Zealand", "NZ", -38.1300, 176.2520, "geothermal", "Lake Rotorua", ("Park", "Travel"), "Water", ("Steam & Stone Kitchen", ("Restaurant", "Dining", "European Cuisine"), 0), "", 300, ""),
    ("syd_opera", "Sydney Opera House", "Bennelong Point", "Sydney", "Sydney", "New South Wales", "2000", "Australia", "AU", -33.8568, 151.2153, "city", "Sydney Harbour", ("Culture", "Travel"), "Water", ("Sydney Opera House", ("Performing Arts Center", "Landmark", "Theater"), 5700), "Sydney Opera House", 200, ""),
    ("syd_bondi", "Bondi Beach", "Campbell Parade", "Bondi Beach", "Sydney", "New South Wales", "2026", "Australia", "AU", -33.8915, 151.2767, "beach", "Tasman Sea", ("Park", "Travel"), "Beach", ("Parade Gelato Bar", ("Ice Cream Shop", "Dessert Shop"), 0), "", 250, ""),
    ("syd_rocks", "The Rocks", "George Street", "The Rocks", "Sydney", "New South Wales", "2000", "Australia", "AU", -33.8599, 151.2090, "city", "Sydney Harbour", ("Culture", "Restaurant"), "Urban", ("Quay Lane Dumplings", ("Asian Cuisine", "Restaurant"), 0), "", 150, ""),
    ("fj_denarau", "Denarau Marina", "Denarau Island Road", "Denarau Island", "Nadi", "Western Division", "", "Fiji", "FJ", -17.7730, 177.3800, "tropics", "Nadi Bay", ("Travel", "Restaurant"), "Beach", ("Reef & Palm Grill", ("Seafood Restaurant", "Restaurant", "Bar"), 0), "", 300, ""),
    ("fj_temple", "Sri Siva Subramaniya Temple", "Queens Road", "Nadi Town", "Nadi", "Western Division", "", "Fiji", "FJ", -17.8087, 177.4102, "tropics", "", ("Culture", "Travel"), "Urban", ("Nadi Town Roti House", ("Indian Cuisine", "Restaurant", "Street Food"), 0), "Sri Siva Subramaniya Temple", 150, ""),
    ("fj_garden", "Garden of the Sleeping Giant", "Wailoko Road", "Sabeto", "Nadi", "Western Division", "", "Fiji", "FJ", -17.7030, 177.4480, "tropics", "", ("Park", "Hiking"), "Nature", None, "Garden of the Sleeping Giant", 250, ""),
]

_CONTINENT = {"NZ": ("Oceania", "Australia and New Zealand"), "AU": ("Oceania", "Australia and New Zealand"), "FJ": ("Oceania", "Melanesia")}
_LANGUAGES = {"NZ": ("en_NZ", "mi_NZ"), "AU": ("en_AU",), "FJ": ("en_FJ", "fj_FJ", "hif_FJ")}


def _spots(persona: Persona) -> dict[str, Spot]:
    out: dict[str, Spot] = {}
    for place in persona.places:
        suburb, context, water, poi, roi, categories, landmark = _WELLINGTON[place.key]
        private = "home" if place.key == "home" else ("work" if place.key == "work" else "")
        public_name = "" if place.key in ("home", "parents") else place.name
        business = (public_name, categories, 0) if categories else None
        out[place.key] = Spot(place.key, public_name, place.street, suburb, place.city, place.region, place.postal_code,
                              place.country, place.country_code, place.latitude, place.longitude, context, water, poi, roi,
                              business, landmark, 500.0 if place.kind == "travel" else (25.0 if place.kind in ("home", "work", "cafe", "gym") else 120.0), private)
    for row in _EXTRA:
        key = row[0]
        out[key] = Spot(*row[:12], water=row[12], poi=row[13], roi=row[14], business=row[15], landmark=row[16], spread=float(row[17]), private=row[18])
    # Street names for the travel places the persona leaves blank (public streets next to the landmark).
    for key, street in (("auckland", "Victoria Street West"), ("queenstown", "Park Street"), ("rotorua", "Queens Drive")):
        out[key].street = street
    return out


# ----------------------------------------------------------------------------------------
# Vocabulary: scenes, captions, recognised text (all invented)
# ----------------------------------------------------------------------------------------

_SCENES = {
    "home": ["Cat", "Sofa", "Houseplant", "Kitchen", "Food", "Book", "Window", "Laptop", "Mug", "Blanket", "Dinner", "Candle"],
    "work": ["Whiteboard", "Office", "Computer", "Desk", "Document", "Diagram", "Sticky Note", "Conference Room", "Monitor"],
    "cafe": ["Coffee", "Cup", "Cafe", "Pastry", "Table", "Food", "Latte Art", "Menu", "Cake"],
    "dinner": ["Restaurant", "Food", "Drink", "Table", "Noodle", "Beer", "Night", "People", "Candle"],
    "gym": ["Climbing", "Climbing Wall", "Rope", "Sport", "Chalk", "Gym", "People"],
    "market": ["Vegetable", "Fruit", "Market", "Crowd", "Flower", "Bread", "Stall", "Harbour"],
    "park": ["Tree", "Garden", "Flower", "Path", "Bird", "Fern", "Forest", "Grass", "Bench", "Sky", "Parrot"],
    "lookout": ["Cityscape", "Sunset", "Sky", "Harbour", "Hill", "Cloud", "Skyline", "Sunrise", "Path"],
    "beach": ["Beach", "Sea", "Sand", "Boat", "Sunset", "Water", "Pier", "Swimming", "Sky"],
    "museum": ["Museum", "Sculpture", "Art", "Exhibit", "Building", "Interior", "Signage"],
    "transit": ["Train", "Station", "Cable Car", "Signage", "Building", "Platform", "Cityscape"],
    "airport": ["Airport", "Airplane", "Suitcase", "Signage", "Runway", "Window", "Sky"],
    "family": ["People", "Dinner", "Cake", "Garden", "Barbecue", "Table", "Beach", "Dog", "Flower", "Christmas Tree"],
    "city": ["Skyscraper", "Tower", "Street", "Bridge", "Crowd", "Food", "Harbour", "Night", "Building", "Neon Sign"],
    "alpine": ["Mountain", "Lake", "Snow", "Hiking", "Trail", "Boat", "Sky", "Forest", "Sunset", "Rock"],
    "geothermal": ["Geyser", "Steam", "Lake", "Forest", "Hot Spring", "Path", "Signage", "Tree"],
    "tropics": ["Palm Tree", "Beach", "Sea", "Boat", "Orchid", "Temple", "Fruit", "Sunset", "Coral Reef", "Sand", "Market", "Swimming"],
    "concert": ["Concert", "Stage", "Crowd", "Musician", "Night", "Stage Light"],
    "clinic": ["Document", "Interior", "Signage", "Waiting Room"],
    "screenshot": ["Screenshot", "Text", "Document", "Map", "Chart", "Receipt"],
    "saved": ["Text", "Illustration", "Poster", "Food", "Cat", "Furniture", "Typography"],
}

_CAPTIONS = {
    "home": ["A cat sleeping on a grey sofa next to a window", "A bowl of pasta on a wooden table", "A houseplant on a windowsill in the afternoon sun",
             "A laptop and a mug of tea on a desk", "A person reading a book on a sofa", "A cat sitting in a cardboard box",
             "A loaf of bread cooling on a kitchen bench", "Two people cooking together in a small kitchen", "A stack of books next to a lit candle"],
    "work": ["A whiteboard covered in handwritten notes and sticky notes", "A group of people sitting around a meeting table", "A computer monitor showing a design layout",
             "A printed wireframe pinned to a wall", "Three people standing in front of a whiteboard", "A desk with a laptop, a notebook and a coffee cup"],
    "cafe": ["A flat white with latte art on a wooden table", "A cheese scone on a plate next to a cup of coffee", "Two people sitting at a cafe table by the window",
             "A chalkboard menu on the wall of a cafe", "A slice of cake and two coffees on a table", "A person holding a takeaway coffee cup"],
    "dinner": ["A bowl of noodles with chopsticks on a table", "A group of friends raising their glasses in a restaurant", "A tasting paddle of beers on a wooden bar",
               "Two people smiling at a restaurant table at night", "A cinema ticket held up in front of a foyer"],
    "gym": ["A person climbing an indoor climbing wall", "Two people in harnesses standing in front of a climbing wall", "A chalk bag and climbing shoes on a bench",
            "A person hanging from an overhang on a bouldering wall"],
    "market": ["Crates of vegetables at an outdoor market", "A person holding a bunch of flowers at a market stall", "Loaves of bread on a market table",
               "A crowd walking between market stalls near the water"],
    "park": ["A tūī perched on a flax flower", "A path winding through tree ferns", "A person standing in a rose garden", "A kākā sitting on a wooden railing",
             "Two people walking on a forest track", "A bench under a large pōhutukawa tree", "A close-up of a fern frond"],
    "lookout": ["A view over a harbour city at sunset", "Two people sitting on a hilltop looking at the sea", "A panorama of a city and harbour under clouds",
                "A person taking a selfie at a lookout", "City lights around a harbour at dusk"],
    "beach": ["A person standing on a beach at sunset", "A sailboat on a calm bay", "Two people eating ice cream on a seawall", "A person in swimwear standing on a beach",
              "Footprints on wet sand", "People swimming near a floating pontoon"],
    "museum": ["A large sculpture in a museum hall", "A person looking at an exhibit behind glass", "The exterior of a museum on a waterfront", "A carved wooden meeting house inside a museum"],
    "transit": ["A red cable car climbing a hill above a city", "A train waiting at a station platform", "A departure board in a railway station", "The front of a brick railway station"],
    "airport": ["An airplane wing seen through a window", "A suitcase next to a row of airport seats", "A boarding pass held in a hand", "A plane parked at a gate at sunrise"],
    "family": ["A family sitting around a dinner table", "An older couple standing in a garden", "A birthday cake with lit candles", "Four people on a beach in the wind",
               "A barbecue on a deck with people in the background", "A decorated Christmas tree in a living room", "Two women laughing on a sofa"],
    "city": ["A tall tower above a city skyline", "A busy pedestrian crossing at night", "A harbour bridge seen from a ferry", "Two people in front of a famous opera house",
             "A plate of dumplings on a restaurant table", "Neon signs above a narrow street"],
    "alpine": ["A lake surrounded by snow-capped mountains", "Two people on a hiking trail above a lake", "A steamship on a mountain lake", "A person standing on a rocky summit",
               "A jetty on a still lake at sunrise", "A pizza on a table with a lake in the background"],
    "geothermal": ["Steam rising from a geothermal pool", "A geyser erupting behind a fence", "A group of friends standing on a boardwalk", "A lake at dusk with black swans"],
    "tropics": ["Palm trees along a white sand beach", "A wooden boat on turquoise water", "An orchid in a tropical garden", "A market stall piled with tropical fruit",
                "Two people snorkelling above a coral reef", "A brightly painted temple under a blue sky", "A coconut with a straw on a wooden table", "A sunset behind moored yachts"],
    "concert": ["A band performing on a stage under blue lights", "A crowd with raised hands at a concert", "A saxophone player in a spotlight", "A blurry stage seen from the back of a hall"],
    "clinic": ["An appointment card held in a hand", "A waiting room with empty chairs", "A hospital wristband on a wrist", "A plaster on a finger"],
    "screenshot": ["A screenshot of a chat with green and grey message bubbles", "A screenshot of a map with a route", "A screenshot of a calendar", "A screenshot of an article in a web browser"],
    "saved": ["An illustration of a bird on a branch", "A poster with large typography", "A photo of a mid-century armchair", "A meme of a cat looking at a laptop"],
}

_VIDEO_CAPTIONS = {
    "home": ["A cat chases a toy across a living room floor", "A person stirs a pot on a stove"],
    "park": ["A bird sings on a branch while the camera moves closer", "Two people walk along a forest track"],
    "lookout": ["The camera pans across a harbour city from a hilltop", "Clouds move quickly over a city at sunset"],
    "beach": ["Waves roll onto a beach while people walk past", "A person jumps off a pontoon into the sea"],
    "family": ["A group sings happy birthday around a cake", "A dog runs along a beach towards the camera"],
    "alpine": ["A boat crosses a lake below mountains", "A person walks up a rocky trail in the wind"],
    "city": ["Crowds cross a large intersection at night", "A ferry passes under a bridge"],
    "tropics": ["Fish swim over a coral reef in clear water", "Palm trees sway in the wind above a beach"],
    "concert": ["A band plays on stage while the crowd cheers", "A saxophone solo under a spotlight"],
    "geothermal": ["A geyser erupts and steam drifts across a boardwalk"],
    "gym": ["A person climbs an indoor wall and reaches the top hold"],
    "market": ["The camera moves past market stalls full of vegetables"],
    "screenshot": ["A screen recording of scrolling through a design prototype"],
}

_LANDMARK_VLU = {
    "park": ["Tūī", "Kākā", "Silver fern", "Pōhutukawa", "Kōwhai", "Takahē", "Kererū", "Rose"],
    "home": ["Domestic cat", "Monstera deliciosa", "Peace lily"],
    "alpine": ["Kea", "Southern beech", "Lupin"],
    "geothermal": ["Black swan", "Mānuka"],
    "beach": ["Red-billed gull", "Pōhutukawa"],
    "tropics": ["Orchid", "Coconut palm", "Hibiscus"],
}

_HUMAN_ACTIONS = {"gym": "Climbing", "park": "Walking", "alpine": "Hiking", "lookout": "Walking", "beach": "Swimming", "family": "Hugging",
                  "concert": "Dancing", "dinner": "Eating", "cafe": "Eating", "city": "Walking", "tropics": "Swimming"}

_AUDIO = {"home": ["Speech", "Cat"], "park": ["Bird", "Wind"], "lookout": ["Wind", "Speech"], "beach": ["Water", "Speech", "Laughter"],
          "family": ["Speech", "Laughter", "Singing"], "alpine": ["Wind", "Water"], "city": ["Crowd", "Speech"], "tropics": ["Water", "Wind", "Speech"],
          "concert": ["Music", "Cheering", "Applause"], "geothermal": ["Water", "Speech"], "gym": ["Speech"], "market": ["Crowd", "Speech"],
          "screenshot": []}


def _ocr_documents(persona: Persona) -> dict[str, list[tuple[str, str, str]]]:
    """context -> [(document class, utility class, text)]. Everything is invented; the "sensitive
    looking" ones exist because retaining such text is exactly what the store does."""
    owner, partner = persona.owner, persona.person("partner")
    landlord, dentist = persona.person("landlord"), persona.person("drlee")
    home = persona.place("home")
    cafe = persona.place("cafe")
    colleagues = [p.given for p in persona.people_with("colleague")]
    guest = next(n.ssid for n in persona.networks if n.place == "cafe")
    return {
        "work": [
            ("", "Whiteboard", f"Sprint 14 goals Onboarding redesign Research readout Thursday {colleagues[0]} {colleagues[1]} {colleagues[3]} Ship beta by end of month"),
            ("", "Whiteboard", "How might we reduce sign-up drop-off Ideas progressive profile magic link fewer fields Dot vote Friday"),
            ("", "Whiteboard", f"Retro Went well design reviews Puzzles handover timing Action {colleagues[2]} to book usability lab"),
            ("", "Handwriting", "User journey Discover Compare Decide Onboard Pain point pricing page unclear"),
            ("Business Card", "Document", f"{owner.full_name} {owner.job_title} {persona.company} {owner.emails[1]}"),
            ("", "Document", f"{persona.company} Payslip Employee {owner.full_name} Pay period ending Gross 3,480.00 PAYE 742.10 KiwiSaver 104.40 Net 2,633.50 Tax code M"),
            ("", "Document", f"Conference badge {owner.full_name} {persona.company} Speaker Design Systems Day"),
        ],
        "cafe": [
            ("Receipt", "Receipt", f"{cafe.name} {cafe.street} Wellington {{drink}} {{amount}} {{food}} {{amount}} Total {{amount}} EFTPOS Approved {{date}} {{time}} Thank you"),
            ("Menu", "Menu", "Menu Flat white Long black Mocha Chai latte Cheese scone Date scone Toasted sandwich Soup of the day"),
            ("", "Signage", f"Guest Wi-Fi Network {guest} Password flatwhite-and-fern"),
            ("Receipt", "Receipt", "Harbour Light Coffee Queens Wharf {drink} {amount} {food} {amount} Total {amount} Contactless {time}"),
        ],
        "dinner": [
            ("Menu", "Menu", "Dan dan noodles 19 Pork and chive dumplings 14 Smashed cucumber 9 Jasmine tea 5"),
            ("Receipt", "Receipt", "Left Bank Noodle House Table {n} 2 x Dan dan noodles 38.00 Dumplings {amount} {drink} {amount} Total {amount} Split 2 ways {amount}"),
            ("Ticket", "Ticket", "Courtenay Lane Cinema Admit one Screen {n} Row F Seat {n} {time} pm {date}"),
            ("", "Signage", "Hop & Harbour Brewing Tasting paddle Pale ale Hazy IPA Stout Pilsner"),
        ],
        "airport": [
            ("Boarding Pass", "Ticket", f"Boarding pass Kōtare Air {owner.family.upper()}/{owner.given.upper()} Wellington WLG to Queenstown ZQN Flight {{flight}} Gate {{n}} Seat {{seat}} Boarding {{time}} Booking ref {{ref}}"),
            ("Boarding Pass", "Ticket", f"Boarding pass Kōtare Air {partner.family.upper()}/{partner.given.upper()} Wellington WLG to Queenstown ZQN Flight {{flight}} Gate {{n}} Seat {{seat}} Boarding {{time}} Booking ref {{ref}}"),
            ("", "Signage", "Departures {flight} Queenstown {time} Gate {n} Boarding {flight} Auckland {time} Gate {n} Go to gate {flight} Christchurch {time} Delayed"),
            ("", "Document", f"Baggage tag WLG ZQN KA 214 {owner.family.upper()}/R 0 042 771234"),
        ],
        "transit": [
            ("", "Signage", "Platform {n} Kāpiti Line Waikanae {time} Stopping all stations On time Next service {time}"),
            ("Ticket", "Ticket", "Wellington Cable Car Adult return Lambton Quay to Kelburn Valid today"),
            ("", "Signage", "Kelburn Lookout Botanic Garden Space Place Cable Car Museum"),
        ],
        "museum": [
            ("", "Signage", "Te Papa Tongarewa Level 4 Mana Whenua Te Marae Open daily 10 am to 6 pm Free entry"),
            ("", "Signage", "Please do not touch the taonga Photography without flash is welcome"),
        ],
        "park": [
            ("", "Signage", "Zealandia Te Māra a Tāne Valley View Track 45 min Please stay on the track Kākā feeding station ahead"),
            ("", "Signage", "Wellington Botanic Garden Lady Norwood Rose Garden Begonia House Cable Car 10 min"),
        ],
        "home": [
            ("", "Document", f"To {owner.full_name} {home.street} Aro Valley Wellington {home.postal_code} Tracking DEMO {{code}} Signature required"),
            ("", "Document", f"Residential Tenancy Agreement Landlord {landlord.full_name} Tenants {owner.full_name} {partner.full_name} Weekly rent 720.00 Bond 2,880.00"),
            ("", "Document", f"Pharmacy label {owner.full_name} Ibuprofen 200 mg Take 1 to 2 tablets with food up to three times daily"),
            ("", "Handwriting", "Shopping list oat milk eggs sourdough coriander limes cat food dishwasher tablets"),
            ("", "Document", f"Dear {owner.given} thank you for your application We are pleased to confirm your contents insurance policy DEMO {{code}} for the property at {home.street} "
                             f"Sum insured 40,000 Excess 400 Annual premium {{amount}} Cover begins {{date}} Please keep this letter for your records"),
            ("", "Document", "Recipe Lemon and courgette pasta 400 g spaghetti 2 courgettes zest of one lemon parmesan chilli flakes"),
            ("", "Document", f"Power account {owner.full_name} Amount due {{amount}} Due date {{date}} Customer number DEMO {{code}}"),
        ],
        "clinic": [
            ("", "Document", f"{dentist.organization} Dr {dentist.full_name} Appointment for {owner.full_name} {{day}} {{time}} am Please arrive 10 minutes early"),
            ("", "Document", f"Wellington Regional Hospital Outpatients {owner.full_name} Fracture clinic Thursday 2:15 pm Bring this letter"),
        ],
        "family": [
            ("", "Handwriting", f"Happy birthday {owner.nickname} lots of love Mum and Dad"),
            ("", "Signage", "Paraparaumu Beach Kāpiti Island ferry Check in 30 minutes before departure"),
        ],
        "city": [
            ("Ticket", "Ticket", "Sky Tower Observation deck Adult General admission Valid any time today"),
            ("", "Signage", "Circular Quay Wharf 3 Manly ferry Next departure 14:20"),
            ("Receipt", "Receipt", "Quay Lane Dumplings Xiao long bao {amount} Greens {amount} Tea 4.00 Total {amount}"),
        ],
        "alpine": [
            ("", "Signage", "Queenstown Hill Time Walk Summit 1.5 hr return Steep in places Dress for alpine weather"),
            ("Receipt", "Receipt", "Lakefront Pizza Co. Margherita {amount} Lake salad {amount} 2 x Ginger beer 12.00 Total {amount} Table {n}"),
            ("Ticket", "Ticket", "Lake cruise Adult Departs Steamer Wharf 2:00 pm Seat unreserved"),
        ],
        "geothermal": [
            ("", "Signage", "Caution geothermal area Stay on the path Ground may be hot and unstable"),
            ("Receipt", "Receipt", "Steam & Stone Kitchen Hāngī plate {amount} Kūmara fries 9.00 Total {amount} {time}"),
        ],
        "tropics": [
            ("Ticket", "Ticket", "Island day cruise Adult Departs Denarau Marina {time} am Includes lunch and snorkel gear Booking {ref}"),
            ("Receipt", "Receipt", "Reef & Palm Grill Kokoda {amount} Grilled fish {amount} 2 x Lime soda 14.00 Total {amount} FJD"),
            ("", "Signage", "Garden of the Sleeping Giant Orchid walk Lily pond Lookout track 20 min Please keep to the boardwalk"),
        ],
        "concert": [
            ("Ticket", "Ticket", "Harbour Hall Marlow Quartet Late Set Tour General admission standing Doors 7:30 pm Ticket DEMO {code}"),
        ],
        "screenshot": [
            ("", "Screenshot", "Messages Kōwhai Bank Your one-time code is {code} It expires in 10 minutes Do not share this code with anyone"),
            ("", "Screenshot", f"{partner.full_name} Running late see you at {cafe.name} at 6 Want me to order for you Yes please flat white"),
            ("", "Screenshot", "Maps Aro Street to Wellington Airport 18 min 8.4 km Fastest route via Adelaide Road"),
            ("", "Screenshot", f"Calendar Design review 10:00 to 11:00 {persona.company} Level 3 {colleagues[0]} {colleagues[1]} Accepted"),
            ("", "Screenshot", "Your order has shipped Estimated delivery {day} Track parcel DEMO {code}"),
            ("", "Screenshot", "Weather Wellington Southerly {n} km/h gusting 80 Showers easing High 1{n} Low {n} {day}"),
            ("", "Screenshot", f"Booking confirmed Kōtare Air WLG to ZQN {owner.full_name} {partner.full_name} Booking ref {{ref}} 2 passengers 1 checked bag each Total {{amount}}"),
            ("", "Screenshot", "Guest network KowhaiLabs-Guest Password kowhai-guest-demo Valid today only"),
            ("", "Screenshot", "Settings Screen Time Daily average {n} h 4{n} min Most used Messages Safari Slack Pickups 8{n}"),
            ("", "Screenshot", f"{persona.person('sister').given} Did you see the photos Mum sent Dinner at theirs on Sunday Bring the good cheese"),
            ("", "Screenshot", "Climbing log {date} Grade 1{n} flashed Grade 2{n} two attempts Project the orange overhang"),
            ("", "Screenshot", "Typography scale 12 14 16 20 24 32 48 Line height 1.5 Tracking 0"),
            ("", "Screenshot", "Notes Trip packing list passport charger rain jacket merino layers sunscreen camera spare battery tramping boots first aid kit head torch snacks "
                               "water bottle togs towel book earplugs power bank sunglasses"),
            ("", "Screenshot", f"Mail From {persona.person('manager').full_name} Subject Offsite agenda Hi team here is the plan for {{day}} 9:00 coffee 9:30 roadmap review 11:00 customer "
                               f"interviews recap 12:30 lunch at the market 2:00 prioritisation workshop 4:00 wrap up Please bring laptops and chargers See you there"),
            ("", "Screenshot", f"Kōwhai Bank Everyday account Available {{amount}} {{date}} {cafe.name} {{amount}} {{date}} Te Aro Climbing Gym {{amount}} {{date}} Harbourside Market {{amount}} "
                               f"{{date}} Rent {landlord.full_name} 720.00 {{date}} Salary {persona.company} 2,633.50"),
        ],
        "saved": [
            ("", "Illustration", "Good design is as little design as possible"),
            ("", "Poster", "Design Systems Day Wellington Talks workshops and a very long lunch"),
            ("", "Illustration", "Birds of Aotearoa tūī kākā kererū pīwakawaka ruru"),
        ],
    }


_DRINKS = ["Flat white", "Long black", "Mocha", "Chai latte", "Oat latte", "Hot chocolate", "Ginger beer", "Kombucha", "Pale ale", "Jasmine tea"]
_FOODS = ["Cheese scone", "Date scone", "Almond croissant", "Toasted sandwich", "Banana bread", "Soup of the day", "Lamington", "Carrot cake", "Bagel"]


def _fill(text: str, rng: random.Random, partial: bool) -> str:
    """Replaces the {placeholders} of a text template with invented values; `partial` keeps
    only the first part of the words, as when the recogniser reads half a page."""
    def value(name: str) -> str:
        if name == "amount":
            return f"{rng.randint(4, 96)}.{rng.choice(['00', '50', '90', '20'])}"
        if name == "time":
            return f"{rng.randint(6, 12)}:{rng.choice(['00', '05', '15', '20', '30', '45', '50'])}"
        if name == "code":
            return f"{rng.randrange(100, 1000)} {rng.randrange(100, 1000)}"
        if name == "ref":
            return "".join(rng.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(6))
        if name == "n":
            return str(rng.randint(2, 9))
        if name == "seat":
            return f"{rng.randint(3, 29)}{rng.choice('ABCDEF')}"
        if name == "flight":
            return f"KA {rng.randrange(100, 900)}"
        if name == "day":
            return rng.choice(_WEEKDAYS)
        if name == "date":
            return f"{rng.randint(1, 28)} {rng.choice(_MONTHS)[:3]}"
        if name == "drink":
            return rng.choice(_DRINKS)
        if name == "food":
            return rng.choice(_FOODS)
        return name
    out = []
    for piece in text.split("{"):
        if "}" in piece and out:
            name, _, rest = piece.partition("}")
            out.append(value(name) + rest)
        else:
            out.append(piece)
    words = "".join(out).split()
    if len(words) > 8 and rng.random() < (0.55 if partial else 0.75 if len(words) > 30 else 0.3):
        words = words[:rng.randint(max(6, int(len(words) * 0.45)), len(words) - 1)]
    return " ".join(words)


# ----------------------------------------------------------------------------------------
# The simulated library
# ----------------------------------------------------------------------------------------


@dataclass
class Moment:
    index: int
    spot: Spot
    start: datetime.datetime
    end: datetime.datetime
    people: list              # persona person keys present (never the owner)
    context: str
    meaning: str = ""         # graph meaning class
    pet: bool = False
    trip: Optional[int] = None
    holiday: str = ""
    birthday_of: str = ""
    event: Optional[int] = None       # index into the public events list
    taboo: str = ""
    kind: str = "camera"      # camera / screenshot / saved
    assets: list = field(default_factory=list)
    uuid: str = ""
    days_ago: int = 0


@dataclass
class Asset:
    pk: int
    uuid: str
    moment: Moment
    when: datetime.datetime
    kind: int                 # 0 photo, 1 video
    subtype: int
    lat: float
    lon: float
    located: bool
    camera: Optional[tuple]   # (make, model)
    source: Optional[tuple]   # (bundle id, display name)
    width: int
    height: int
    duration: float
    favorite: bool
    hidden: bool
    trashed: bool
    shared: bool              # in the shared library
    contributor: str          # "owner" or "partner"
    faces: list = field(default_factory=list)       # person keys, "pet", or "?<cluster>" / "?"
    scenes: list = field(default_factory=list)
    caption: str = ""
    ocr: Optional[tuple] = None                     # (document class, utility class, text)
    description: str = ""
    selfie: bool = False
    views: int = 0
    plays: int = 0
    shares: int = 0
    original_name: str = ""
    uti: str = "public.heic"
    vlu: str = ""
    analysed: bool = True


@dataclass
class Trip:
    index: int
    name: str
    start_day: int            # days ago of the first day
    days: int
    spots: list
    companions: list
    long: bool
    uuid: str = ""
    moments: list = field(default_factory=list)


_TRIPS = [
    # name, start (days ago), days, spot keys, companions, long
    ("Queenstown", 96, 6, ["queenstown", "zqn_lake", "zqn_track"], ["alex"], True),
    ("Rotorua", 214, 2, ["rotorua", "rot_lake"], ["priya", "tom", "mei"], False),
    ("Auckland", 338, 3, ["auckland", "akl_viaduct", "akl_arena"], ["lucas", "aroha"], False),
    ("Fiji", 571, 10, ["fj_denarau", "fj_temple", "fj_garden"], ["alex"], True),
    ("Queenstown", 823, 5, ["queenstown", "zqn_lake", "zqn_track"], ["alex", "jamie"], True),
    ("Sydney", 1168, 7, ["syd_opera", "syd_bondi", "syd_rocks"], ["alex"], True),
    ("Auckland", 1512, 2, ["auckland", "akl_viaduct"], ["jamie"], False),
    ("Rotorua", 1904, 3, ["rotorua", "rot_lake"], ["helen", "david", "jamie"], False),
    ("Sydney", 2207, 4, ["syd_opera", "syd_rocks", "syd_bondi"], ["sam"], False),
]

# name, performer, subcategory, spot key, days ago (None = during the Auckland trip)
_EVENTS = [
    ("Marlow Quartet: Late Set Tour", "Marlow Quartet", "Jazz", "hall", 131),
    ("Kererū: Low Cloud Live", "Kererū", "Electronic", "hall", 486),
    ("Glasshouse: Departures Tour", "Glasshouse", "Pop", "akl_arena", 337),
    ("Anna Fairlie: Small Hours", "Anna Fairlie", "Singer/Songwriter", "hall", 1012),
]

_HOLIDAYS = {(12, 25): "Christmas Day", (1, 1): "New Year's Day", (2, 6): "Waitangi Day", (10, 31): "Halloween"}

_CAMERAS = {
    "phone_old": ("Apple", "iPhone 11 Pro"), "phone_mid": ("Apple", "iPhone 14 Pro"), "phone_new": ("Apple", "iPhone 15 Pro Max"),
    "partner": ("Apple", "iPhone 15"), "camera": ("FUJIFILM", "X-T30 II"), "ipad": ("Apple", "iPad Pro (12.9-inch) (6th generation)"),
}

_SOURCES = {
    "camera": ("com.apple.camera", "Camera"), "whatsapp": ("net.whatsapp.WhatsApp", "WhatsApp"), "messages": ("com.apple.MobileSMS", "Messages"),
    "safari": ("com.apple.mobilesafari", "Safari"), "instagram": ("com.burbn.instagram", "Instagram"), "screenshot": ("com.apple.screencaptureui", "Screenshot"),
    "mail": ("com.apple.mobilemail", "Mail"), "slack": ("com.tinyspeck.chatlyio", "Slack"),
}


class Library:
    """The invented library: moments, assets, people — the single source for all four stores."""

    def __init__(self, persona: Persona, rng: random.Random, now: datetime.datetime):
        self.persona = persona
        self.rng = rng
        self.now = now
        self.clock = lib.Clock(now, persona.tz_offset_hours)
        self.spots = _spots(persona)
        self.docs = _ocr_documents(persona)
        self.moments: list[Moment] = []
        self.assets: list[Asset] = []
        self.trips = [Trip(i, *row) for i, row in enumerate(_TRIPS)]
        self.trip_days: dict[int, Trip] = {}
        for trip in self.trips:
            trip.uuid = lib.uuid_string(rng)
            for offset in range(trip.days):
                self.trip_days[trip.start_day - offset] = trip
        self.simulate()
        self.finish_assets()

    # -- helpers -------------------------------------------------------------------------
    def local(self, when: datetime.datetime) -> datetime.datetime:
        return when.astimezone(self.clock.tz)

    def chance(self, p: float) -> bool:
        return self.rng.random() < p

    def pick_people(self, options: list[tuple[float, list[str]]]) -> list[str]:
        out: list[str] = []
        for p, keys in options:
            if self.chance(p):
                for key in keys:
                    if key not in out:
                        out.append(key)
        return out

    def add_moment(self, day: int, hour: int, spot_key: str, people: list[str], count: int, *, context: str = "", minutes: int = 0,
                   kind: str = "camera", **extra: Any) -> Optional[Moment]:
        rng = self.rng
        start = self.clock.at(day, hour, rng.randrange(60) if not minutes else minutes, rng.randrange(60))
        if start > self.now - datetime.timedelta(minutes=30):
            return None
        length = rng.randint(4, 25) * 60 + count * rng.randint(40, 300)
        end = min(start + datetime.timedelta(seconds=length), self.now - datetime.timedelta(minutes=5))
        spot = self.spots[spot_key]
        moment = Moment(len(self.moments), spot, start, end, list(people), context or spot.context, kind=kind, uuid=lib.uuid_string(rng), days_ago=day, **extra)
        moment.assets = [None] * max(1, count)     # filled in finish_assets()
        self.moments.append(moment)
        return moment

    # -- the persona's days ----------------------------------------------------------------
    def simulate(self) -> None:
        rng, persona = self.rng, self.persona
        friends = [p.key for p in persona.people_with("friend")]
        colleagues = [p.key for p in persona.people_with("colleague")] + ["aroha"]
        birthdays = {(p.birthday[1], p.birthday[2]): p.key for p in persona.people if p.birthday and p.closeness >= 0.6}
        events_by_day = {day: i for i, (_, _, _, _, day) in enumerate(_EVENTS)}
        weights = {p.key: p.visits_per_month for p in persona.places}

        for day in range(SPAN_DAYS, -1, -1):
            date = self.local(self.clock.at(day, 12))
            weekend = date.weekday() >= 5
            summer = date.month in (11, 12, 1, 2, 3)
            growth = 0.5 + 0.5 * (1 - day / SPAN_DAYS)
            home_key = "old_home" if day > OLD_HOME_UNTIL else "home"
            has_alex = day < 2050                      # the partner appears in the library from then on
            alex = ["alex"] if has_alex else []

            # Screenshots and images saved from apps happen wherever the persona is.
            if self.chance(0.17 * growth + 0.03):
                self.add_moment(day, rng.randrange(8, 23), home_key, [], rng.choice([1, 1, 1, 2, 3]), context="screenshot", kind="screenshot")
            if self.chance(0.10 * growth):
                self.add_moment(day, rng.randrange(9, 23), home_key, [], rng.choice([1, 1, 2, 4]), context="saved", kind="saved")

            trip = self.trip_days.get(day)
            if trip is not None:
                self.trip_day(trip, day)
                continue

            holiday = _HOLIDAYS.get((date.month, date.day), "")
            birthday = birthdays.get((date.month, date.day), "")
            if birthday == "alex" and not has_alex:
                birthday = ""
            event = events_by_day.get(day)

            if holiday == "Christmas Day":
                m = self.add_moment(day, 12, "parents", ["helen", "david", "jamie"] + alex, rng.randint(14, 26), meaning="HolidayEvent", holiday=holiday)
                continue
            if holiday == "New Year's Day":
                self.add_moment(day, 0, "oriental", alex + rng.sample(friends, 2), rng.randint(6, 12), meaning="NightOut", holiday=holiday, minutes=4)
            elif holiday == "Waitangi Day":
                self.add_moment(day, 11, rng.choice(["oriental", "botanic", "zealandia"]), alex + rng.sample(friends, 1), rng.randint(6, 14), meaning="Activity", holiday=holiday)
            elif holiday == "Halloween" and self.chance(0.6):
                self.add_moment(day, 19, home_key, rng.sample(friends, 3) + alex, rng.randint(5, 11), meaning="Gathering", holiday=holiday)

            if birthday:
                if birthday in ("helen", "jamie", "robin") and self.chance(0.75):
                    self.add_moment(day, 18, "parents" if birthday == "helen" else home_key, ["helen", "david", "jamie"] + alex, rng.randint(8, 16),
                                    context="family", meaning="Birthday", birthday_of=birthday)
                else:
                    self.add_moment(day, 19, rng.choice(["noodles", "brewery"]), ([birthday] if birthday != "robin" else alex) + rng.sample(friends, 2),
                                    rng.randint(6, 12), meaning="Birthday", birthday_of=birthday)
            if event is not None:
                spot_key = _EVENTS[event][3]
                self.add_moment(day, 20, spot_key, alex + rng.sample(friends, 1), rng.randint(8, 15), meaning="Concert", event=event)

            # Home.
            if self.chance(0.20 * growth + 0.05):
                people = self.pick_people([(0.5 if has_alex else 0.0, ["alex"])])
                dinner_party = self.chance(0.05)
                if dinner_party:
                    people += rng.sample(friends, rng.randint(2, 3))
                self.add_moment(day, rng.choice([8, 9, 13, 17, 18, 19, 20, 21]) if not weekend else rng.randrange(9, 22), home_key, people,
                                rng.randint(4, 9) if dinner_party else rng.choice([1, 1, 2, 2, 3, 4]),
                                meaning="Gathering" if dinner_party else ("Dinner" if self.chance(0.12) else ""), pet=day < 1400 and self.chance(0.45))
            # Work (weekdays only).
            if not weekend and self.chance(0.055 * growth + 0.01):
                self.add_moment(day, rng.choice([10, 11, 14, 15, 16]), "work", rng.sample(colleagues, rng.choice([0, 1, 2, 3])), rng.choice([1, 1, 2, 3]))
            # Cafés.
            if self.chance(0.045 * growth + 0.012):
                key = "coffee" if (not weekend and self.chance(0.45)) else "cafe"
                people = self.pick_people([(0.35 if has_alex else 0, ["alex"]), (0.25, [rng.choice(friends)]), (0.2 if key == "coffee" else 0.0, [rng.choice(colleagues)])])
                hour = rng.choice([8, 9, 10, 10, 11, 12, 13, 15])
                self.add_moment(day, hour, key, people, rng.choice([1, 1, 2, 3, 4]), meaning="Lunch" if hour in (12, 13) and people else ("Restaurant" if self.chance(0.3) else ""))
            # Evenings out.
            if self.chance((0.028 if weekend else 0.012) * (growth + 0.3)):
                people = self.pick_people([(0.6 if has_alex else 0, ["alex"]), (0.7, rng.sample(friends, 2)), (0.12, [rng.choice(colleagues)])])
                self.add_moment(day, rng.choice([18, 19, 19, 20, 21]), rng.choice(["noodles", "brewery", "noodles", "cinema"]), people, rng.randint(2, 8),
                                meaning="NightOut" if len(people) >= 2 and self.chance(0.5) else "Dinner")
            # Climbing.
            if day < 1700 and self.chance(0.03 * growth + 0.008):
                self.add_moment(day, rng.choice([7, 18, 19]) if not weekend else rng.randrange(10, 16), "gym", self.pick_people([(0.45, ["tom"]), (0.35, ["priya"])]),
                                rng.randint(1, 6), meaning="Activity")
            # Outdoors and landmarks: mostly weekends, mostly in summer.
            outing = (0.26 if weekend else 0.035) * (1.35 if summer else 0.75) * (growth + 0.25)
            if self.chance(outing):
                key = rng.choices(["botanic", "mt_vic", "oriental", "zealandia", "market", "te_papa", "cable_car"],
                                  weights=[weights["botanic"], weights["mt_vic"], weights["oriental"] * (1.5 if summer else 0.6), weights["zealandia"] * 1.5,
                                           weights["market"] if weekend else 0.2, weights["te_papa"] * 1.6, weights["cable_car"] * 1.4])[0]
                visitors = key in ("te_papa", "cable_car") and self.chance(0.5)
                people = (rng.choice([["helen", "david"], ["jamie"], ["mei"], ["sam", "priya"]]) if visitors
                          else self.pick_people([(0.55 if has_alex else 0, ["alex"]), (0.25, [rng.choice(friends)]), (0.14, ["jamie"])]))
                meaning = {"botanic": "Activity", "mt_vic": "Hiking", "oriental": "Beaching" if summer else "Activity", "zealandia": "Hiking",
                           "market": "", "te_papa": "Museum", "cable_car": "Activity"}[key]
                hour = 9 if key == "market" else (rng.choice([6, 19, 20]) if key == "mt_vic" and self.chance(0.5) else rng.randrange(10, 18))
                self.add_moment(day, hour, key, people, rng.randint(3, 14), meaning=meaning if self.chance(0.8) else "")
            # Family at the coast.
            if weekend and self.chance(0.05 * (growth + 0.4)):
                people = ["helen", "david"] + self.pick_people([(0.5, ["jamie"]), (0.6 if has_alex else 0, ["alex"])])
                self.add_moment(day, rng.randrange(11, 17), "parents", people, rng.randint(4, 16), meaning="Gathering" if self.chance(0.7) else "Lunch")
            # Station and airport in passing.
            if self.chance(0.012 * growth):
                self.add_moment(day, rng.choice([7, 8, 17, 18]), "station", [], rng.choice([1, 1, 2]))

        # One-off occasions.
        self.add_moment(948, 15, "botanic", ["mei", "priya", "tom", "sam", "alex"], 28, context="family", meaning="Wedding")
        self.add_moment(262, 10, "dental", [], 2, taboo="Hospital")
        self.add_moment(905, 10, "dental", [], 1, taboo="Hospital")
        self.add_moment(1296, 14, "clinic", [], 3, taboo="Hospital")
        self.add_moment(1297, 9, "old_home" if 1297 > OLD_HOME_UNTIL else "home", [], 2, context="clinic", taboo="Blood")
        self.moments.sort(key=lambda m: m.start)
        for index, moment in enumerate(self.moments):
            moment.index = index
        for trip in self.trips:
            trip.moments = [m for m in self.moments if m.trip == trip.index]

    def trip_day(self, trip: Trip, day: int) -> None:
        rng = self.rng
        offset = trip.start_day - day
        if offset == 0:
            self.add_moment(day, 7, "airport", list(trip.companions[:1]), rng.randint(2, 5), trip=trip.index)
        hours = sorted(rng.sample(range(9, 21), rng.randint(2, 4)))
        for hour in hours:
            key = rng.choice(trip.spots)
            spot = self.spots[key]
            people = [k for k in trip.companions if self.chance(0.8)]
            event = None
            meaning = ""
            if spot.context == "concert":
                if trip.index != 2 or offset != 1 or hour < 17:
                    key = trip.spots[0]
                    spot = self.spots[key]
                else:
                    event, meaning = 2, "Concert"
            if not meaning:
                if hour >= 18 and spot.business and self.chance(0.6):
                    meaning = "Dinner"
                elif 12 <= hour <= 13 and spot.business and self.chance(0.5):
                    meaning = "Lunch"
                elif "Hiking" in spot.poi and self.chance(0.7):
                    meaning = "Hiking"
                elif spot.context == "beach" and self.chance(0.7):
                    meaning = "Beaching"
                elif "Culture" in spot.poi and self.chance(0.4):
                    meaning = "Museum" if spot.context == "city" and self.chance(0.3) else "Activity"
            self.add_moment(day, hour, key, people, rng.randint(5, 26), trip=trip.index, meaning=meaning, event=event)

    # -- assets -----------------------------------------------------------------------------
    def camera_for(self, moment: Moment) -> str:
        if moment.days_ago > 1500:
            return "phone_old"
        return "phone_mid" if moment.days_ago > 600 else "phone_new"

    def finish_assets(self) -> None:
        rng, persona = self.rng, self.persona
        owner = persona.owner
        named = {p.key for p in persona.people}
        img_number = 1000 + rng.randrange(400)
        strangers = list(range(70))
        stranger_weights = [1 / (i + 1.5) for i in strangers]
        for moment in self.moments:
            count = len(moment.assets)
            moment.assets = []
            span = max(60.0, (moment.end - moment.start).total_seconds())
            offsets = sorted(rng.random() * span for _ in range(count))
            spot = moment.spot
            with_camera = moment.trip is not None and moment.days_ago < 1300 and self.chance(0.3)
            from_partner = "alex" in moment.people and moment.days_ago < SHARED_LIBRARY_SINCE and self.chance(0.45)
            shared_moment = moment.days_ago < SHARED_LIBRARY_SINCE and moment.kind == "camera" and (
                "alex" in moment.people or (spot.private == "home" and self.chance(0.35)) or (moment.trip is not None and "alex" in self.trips[moment.trip].companions))
            docs = self.docs.get(moment.context, [])
            for i in range(count):
                when = moment.start + datetime.timedelta(seconds=offsets[i])
                pk = len(self.assets) + 1
                uuid = lib.uuid_string(rng)
                kind, subtype, duration = 0, 0, 0.0
                camera: Optional[tuple] = None
                source: Optional[tuple] = None
                located = False
                lat = lon = -180.0
                width, height = 4032, 3024
                uti = "public.heic"
                contributor = "owner"
                if moment.kind == "screenshot":
                    subtype, width, height, uti = 10, 1179, 2556, "public.png"
                    if self.chance(0.06):
                        kind, subtype, duration, uti = 1, 103, rng.uniform(6, 50), "public.mpeg-4"
                    if self.chance(0.3):
                        source, width, height = _SOURCES["screenshot"], 3024, 1964
                elif moment.kind == "saved":
                    source = _SOURCES[rng.choices(["whatsapp", "messages", "safari", "instagram", "mail", "slack"], weights=[5, 4, 3, 2, 1, 1])[0]]
                    width, height, uti = rng.choice([(1600, 1200), (1080, 1350), (2048, 1536), (1200, 1600)]) + ("public.jpeg",)
                    if self.chance(0.08):
                        kind, duration, uti, subtype = 1, rng.uniform(4, 40), "public.mpeg-4", 0
                else:
                    source = _SOURCES["camera"]
                    camera = _CAMERAS[self.camera_for(moment)]
                    located = not self.chance(0.035)
                    if with_camera and self.chance(0.7):
                        camera, source, located, width, height, uti = _CAMERAS["camera"], None, False, 6240, 4160, "public.jpeg"
                    elif from_partner and self.chance(0.6):
                        camera, contributor = _CAMERAS["partner"], "partner"
                    elif spot.private == "home" and self.chance(0.04):
                        camera, width, height = _CAMERAS["ipad"], 4032, 3024
                    roll = rng.random()
                    if camera is not _CAMERAS["camera"]:
                        if roll < 0.075:
                            kind, subtype, duration, uti, width, height = 1, 0, rng.uniform(3, 75), "com.apple.quicktime-movie", 1920, 1080
                            sub = rng.random()
                            if sub < 0.07:
                                subtype = 101
                            elif sub < 0.12:
                                subtype = 102
                        elif roll < 0.40:
                            subtype = 2
                        elif roll < 0.415 and moment.context in ("lookout", "alpine", "beach", "city", "park"):
                            subtype, width, height = 1, 12600, 3600
                    if located:
                        d = spot.spread / 111_000.0
                        lat = spot.lat + rng.gauss(0, d / 2)
                        lon = spot.lon + rng.gauss(0, d / 2) / max(0.2, math.cos(math.radians(spot.lat)))
                asset = Asset(pk, uuid, moment, when, kind, subtype, lat, lon, located, camera, source, width, height, duration,
                              favorite=False, hidden=False, trashed=False, shared=shared_moment and moment.kind == "camera", contributor=contributor, uti=uti)
                ext = {"public.heic": "HEIC", "public.png": "PNG", "public.jpeg": "JPG", "public.mpeg-4": "MP4", "com.apple.quicktime-movie": "MOV"}[uti]
                if camera is _CAMERAS["camera"]:
                    asset.original_name = f"DSCF{rng.randrange(1000, 9999)}.{ext}"
                elif moment.kind == "camera":
                    img_number += rng.randint(1, 3)
                    asset.original_name = f"IMG_{img_number % 10000:04d}.{ext}"
                else:
                    asset.original_name = f"{lib.uuid_string(rng)}.{ext.lower()}"
                # Who is in the picture.
                if moment.kind == "camera" and kind == 0 and moment.context not in ("clinic",):
                    for key in moment.people:
                        if key in named and self.chance(0.5):
                            asset.faces.append(key)
                    if self.chance(0.16 if moment.people else 0.05):
                        asset.faces.append(owner.key)
                        asset.selfie = self.chance(0.6)
                    if moment.pet and self.chance(0.6):
                        asset.faces.append("pet")
                    crowd = {"market": 0.3, "city": 0.3, "tropics": 0.25, "concert": 0.5, "dinner": 0.2, "family": 0.08, "cafe": 0.12, "transit": 0.2,
                             "beach": 0.15, "museum": 0.2, "airport": 0.2, "gym": 0.15, "alpine": 0.08, "park": 0.06}.get(moment.context, 0.02)
                    if self.chance(crowd):
                        for _ in range(rng.choice([1, 1, 2, 3])):
                            asset.faces.append("?" if self.chance(0.3) else "?%d" % rng.choices(strangers, weights=stranger_weights)[0])
                # What is in the picture.
                pool = _SCENES[moment.context]
                asset.scenes = rng.sample(pool, min(len(pool), rng.randint(2, 4)))
                if asset.faces and "People" not in asset.scenes and self.chance(0.6):
                    asset.scenes.append("People")
                if moment.holiday == "New Year's Day" and self.chance(0.7):
                    asset.scenes.append("Fireworks")
                if moment.birthday_of and self.chance(0.4) and "Cake" not in asset.scenes:
                    asset.scenes.append("Cake")
                if kind == 0:
                    captions = _CAPTIONS[moment.context]
                    asset.caption = rng.choice(captions)
                else:
                    asset.caption = rng.choice(_VIDEO_CAPTIONS.get(moment.context, _VIDEO_CAPTIONS["home"]))
                vlu = _LANDMARK_VLU.get(moment.context)
                if vlu and kind == 0 and self.chance(0.22):
                    asset.vlu = rng.choice(vlu)
                # Text in the picture.
                if kind == 0 and docs:
                    p = {"screenshot": 0.93, "work": 0.55, "airport": 0.35, "clinic": 0.7, "saved": 0.4, "cafe": 0.14, "dinner": 0.14, "museum": 0.22,
                         "transit": 0.3, "home": 0.045, "concert": 0.1}.get(moment.context, 0.07)
                    if self.chance(p):
                        doc_class, utility, template = rng.choice(docs)
                        asset.ocr = (doc_class, utility, _fill(template, rng, partial=moment.kind == "camera"))
                        if moment.kind == "camera" and asset.ocr[1] in ("Receipt", "Document", "Ticket", "Whiteboard", "Menu", "Handwriting"):
                            asset.faces = [f for f in asset.faces if f == "pet"][:0]
                            asset.caption = {"Receipt": "A paper receipt on a table", "Document": "A printed document with text", "Ticket": "A ticket held in a hand",
                                             "Whiteboard": "A whiteboard covered in handwritten notes", "Menu": "A printed menu on a table",
                                             "Handwriting": "A handwritten note on paper"}[asset.ocr[1]]
                # Engagement.
                r = rng.random()
                boost = 1.0 if moment.days_ago > 30 else 0.6
                if r < 0.42:
                    asset.views = 0
                elif r < 0.63:
                    asset.views = 1
                elif r < 0.80:
                    asset.views = rng.randint(2, 3)
                elif r < 0.94:
                    asset.views = rng.randint(4, 10)
                elif r < 0.99:
                    asset.views = rng.randint(11, 30)
                else:
                    asset.views = rng.randint(31, 140)
                asset.views = int(asset.views * boost)
                if kind == 1 or subtype == 2:
                    asset.plays = rng.choice([0, 0, 0, 1, 1, 2, 3, 6]) if asset.views else 0
                if asset.views and self.chance(0.07):
                    asset.shares = rng.choice([1, 1, 1, 2, 3])
                asset.favorite = moment.kind == "camera" and bool(asset.faces or moment.trip is not None) and self.chance(0.07)
                asset.hidden = self.chance(0.003)
                asset.trashed = moment.days_ago < 28 and self.chance(0.05)
                asset.analysed = when < self.now - datetime.timedelta(hours=20) or self.chance(0.3)
                moment.assets.append(asset)
                self.assets.append(asset)

        # A few typed descriptions.
        partner = persona.person("partner")
        described = [a for a in self.assets if a.moment.kind == "camera" and a.kind == 0 and (a.favorite or a.moment.trip is not None)]
        templates = {
            "alpine": ["Summit of Queenstown Hill, windy but worth it", f"{partner.given} on the jetty before breakfast", "Lake Wakatipu from the track"],
            "city": ["First evening in the city", "View from the observation deck", f"Ferry ride with {partner.given}"],
            "tropics": ["First swim, ten minutes after landing", "Orchids everywhere", "Best kokoda of the trip"],
            "family": ["Mum and Dad in the garden", "Sunday lunch at the coast", "Everyone in one photo for once"],
            "lookout": ["Sunset from Mount Victoria", "The harbour on a still evening"],
            "beach": ["First swim of the summer", "Oriental Bay after work"],
            "park": ["Kākā at the feeding station", "Rose garden in full bloom"],
            "geothermal": ["Steam everywhere", "Boardwalk selfie attempt number three"],
            "home": ["Miso has claimed the box", "Sourdough attempt, finally a good one"],
            "concert": ["Front row for the second set"],
        }
        for asset in rng.sample(described, min(len(described), 64)):
            options = templates.get(asset.moment.context)
            if options:
                asset.description = rng.choice(options)


# ----------------------------------------------------------------------------------------
# People as Photos sees them
# ----------------------------------------------------------------------------------------

PET_NAME = "Miso"   # an invented cat; the only cast member that is not in persona.py

# person key -> (gender code, age code, favourite)
_PERSON_CODES = {
    "robin": (1, 5, False), "alex": (2, 5, True), "helen": (2, 4, True), "david": (1, 4, False), "jamie": (2, 3, True), "priya": (2, 5, False),
    "tom": (1, 5, False), "mei": (2, 3, False), "sam": (1, 5, False), "aroha": (2, 5, False), "lucas": (1, 3, False), "nina": (2, 5, False),
    "oliver": (1, 5, False), "hana": (2, 3, False),
}


@dataclass
class PersonRow:
    pk: int
    key: str                  # persona key, "pet", "?<n>" for an unnamed cluster, "merged…", "empty…"
    uuid: str
    full_name: str = ""
    display_name: str = ""
    type: int = 0
    verified: int = 0
    detection: int = 1
    age: int = 0
    gender: int = 0
    uri: str = ""
    mdid: str = ""
    me_confidence: float = 0.0
    merge_target: Optional[int] = None
    faces: int = 0
    profile: dict = field(default_factory=dict)


def _people(library: Library) -> tuple[list[PersonRow], dict[str, PersonRow]]:
    rng, persona = library.rng, library.persona
    used = {key for asset in library.assets for key in asset.faces}
    rows: list[PersonRow] = []
    by_key: dict[str, PersonRow] = {}

    def add(row: PersonRow) -> PersonRow:
        rows.append(row)
        by_key[row.key] = row
        return row

    order = [p for p in persona.people if p.key in used]
    rng.shuffle(order)
    slots = order + ["pet"] + sorted((k for k in used if k.startswith("?") and len(k) > 1), key=lambda k: int(k[1:]))
    rng.shuffle(slots)
    for slot in slots:
        pk = len(rows) + 1
        if slot == "pet":
            add(PersonRow(pk, "pet", lib.uuid_string(rng), PET_NAME, PET_NAME, type=1, verified=1, detection=4))
        elif isinstance(slot, str):
            add(PersonRow(pk, slot, lib.uuid_string(rng), type=-1 if rng.random() < 0.04 else 0, detection=1,
                          gender=rng.choice([0, 1, 2]), age=rng.choice([0, 0, 3, 5])))
        else:
            gender, age, favourite = _PERSON_CODES[slot.key]
            row = add(PersonRow(pk, slot.key, lib.uuid_string(rng), slot.full_name, slot.given, type=1 if favourite else 0,
                                verified=2 if slot.key in ("nina", "sam") else 1, age=age, gender=gender, uri=slot.contact_id, mdid=f"md:{slot.graph_id}",
                                me_confidence=0.97 if slot.key == persona.owner.key else round(rng.uniform(0.0, 0.06), 4)))
            row.profile = {
                "ZAGETYPE": age, "ZGENDERTYPE": gender, "ZETHNICITYTYPE": rng.randint(1, 5), "ZSKINTONETYPE": rng.randint(1, 6),
                "ZHAIRCOLORTYPE": rng.randint(1, 6), "ZFACIALHAIRTYPE": 1 if gender == 2 or rng.random() < 0.5 else rng.randint(2, 5),
                "ZGLASSESTYPE": 1 if slot.key in ("david", "nina", "lucas", "robin") else 3,
            }
    # Duplicates merged into a named person keep their row and name; clusters without a face exist too.
    for key in ("alex", "helen", "priya", "robin"):
        if key in by_key:
            target = by_key[key]
            add(PersonRow(len(rows) + 1, "merged-" + key, lib.uuid_string(rng), target.full_name, target.display_name, verified=-2, merge_target=target.pk,
                          age=target.age, gender=target.gender))
    for i in range(7):
        target = rng.choice([r for r in rows if r.key.startswith("?")])
        add(PersonRow(len(rows) + 1, f"merged-{i}", lib.uuid_string(rng), verified=-2, merge_target=target.pk))
    for i in range(6):
        add(PersonRow(len(rows) + 1, f"empty-{i}", lib.uuid_string(rng)))
    return rows, by_key


# ----------------------------------------------------------------------------------------
# Photos.sqlite
# ----------------------------------------------------------------------------------------

# Entity numbers as Core Data assigns them for this model: (number, name, super entity).
_ENTITIES = [
    (1, "AdditionalAssetAttributes", 0), (2, "AlbumList", 0), (3, "Asset", 0), (4, "AssetAnalysisState", 0), (5, "AssetContributor", 0), (6, "AssetDescription", 0),
    (11, "CharacterRecognitionAttributes", 0), (15, "CloudMaster", 0), (19, "CloudSharedComment", 0), (21, "ComputedAssetAttributes", 0), (24, "DetectedFace", 0),
    (25, "DetectedFaceGroup", 0), (29, "ExtendedAttributes", 0), (33, "GenericAlbum", 0), (34, "Album", 33), (35, "CloudSharedAlbum", 34), (36, "DuplicateAlbum", 34),
    (41, "FetchingAlbum", 33), (42, "Folder", 33), (43, "ImportSession", 33), (44, "GlobalKeyValue", 0), (45, "GraphEdge", 0), (48, "GraphLabel", 0), (49, "GraphNode", 0),
    (51, "GraphNodeValue", 0), (53, "Keyword", 0), (55, "LeoItem", 0), (56, "LeoLexeme", 0), (58, "MediaAnalysisAssetAttributes", 0), (59, "Memory", 0), (61, "Moment", 0),
    (62, "Person", 0), (66, "PhotosHighlight", 0), (68, "SceneClassification", 0), (71, "Share", 0), (72, "CollectionShare", 71), (73, "LibraryScope", 71),
    (74, "MomentShare", 71), (75, "ShareParticipant", 0), (77, "Suggestion", 0), (81, "VisualSearchAttributes", 0),
]
_ENT = {name: number for number, name, _ in _ENTITIES}

_PHOTOS_DDL = """
CREATE TABLE ZASSET ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZAVALANCHEPICKTYPE INTEGER, ZBUNDLESCOPE INTEGER, ZCLOUDLOCALSTATE INTEGER, ZCOMPLETE INTEGER,
  ZFAVORITE INTEGER, ZHEIGHT INTEGER, ZHIDDEN INTEGER, ZISDETECTEDSCREENSHOT INTEGER, ZKIND INTEGER, ZKINDSUBTYPE INTEGER, ZLIBRARYSCOPESHARESTATE INTEGER, ZORIENTATION INTEGER,
  ZPLAYBACKSTYLE INTEGER, ZSAVEDASSETTYPE INTEGER, ZSYNDICATIONSTATE INTEGER, ZTRASHEDSTATE INTEGER, ZVISIBILITYSTATE INTEGER, ZWIDTH INTEGER, ZADDITIONALATTRIBUTES INTEGER,
  ZCOMPUTEDATTRIBUTES INTEGER, ZDAYGROUPHIGHLIGHTBEINGASSETS INTEGER, ZEXTENDEDATTRIBUTES INTEGER, ZHIGHLIGHTBEINGASSETS INTEGER, ZLIBRARYSCOPE INTEGER,
  ZMEDIAANALYSISATTRIBUTES INTEGER, ZMOMENT INTEGER, ZADDEDDATE TIMESTAMP, ZCURATIONSCORE FLOAT, ZDATECREATED TIMESTAMP, ZDURATION FLOAT, ZLATITUDE FLOAT, ZLONGITUDE FLOAT,
  ZMODIFICATIONDATE TIMESTAMP, ZOVERALLAESTHETICSCORE FLOAT, ZPROMOTIONSCORE FLOAT, ZTRASHEDDATE TIMESTAMP, ZDIRECTORY VARCHAR, ZFILENAME VARCHAR,
  ZUNIFORMTYPEIDENTIFIER VARCHAR, ZUUID VARCHAR );
CREATE INDEX Z_Asset_dateCreated ON ZASSET (ZDATECREATED);
CREATE INDEX Z_Asset_moment ON ZASSET (ZMOMENT);
CREATE TABLE ZADDITIONALASSETATTRIBUTES ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZALLOWEDFORANALYSIS INTEGER, ZFACEANALYSISVERSION INTEGER, ZIMPORTEDBY INTEGER,
  ZINFERREDTIMEZONEOFFSET INTEGER, ZORIGINALFILESIZE INTEGER, ZORIGINALHEIGHT INTEGER, ZORIGINALWIDTH INTEGER, ZPLAYCOUNT INTEGER, ZREVERSELOCATIONDATAISVALID INTEGER,
  ZSCENEANALYSISVERSION INTEGER, ZSHARECOUNT INTEGER, ZTIMEZONEOFFSET INTEGER, ZVIEWCOUNT INTEGER, ZASSET INTEGER, ZASSETDESCRIPTION INTEGER, ZLASTVIEWEDDATE TIMESTAMP,
  ZSCENEANALYSISTIMESTAMP TIMESTAMP, ZEXIFTIMESTAMPSTRING VARCHAR, ZIMPORTEDBYBUNDLEIDENTIFIER VARCHAR, ZIMPORTEDBYDISPLAYNAME VARCHAR, ZORIGINALFILENAME VARCHAR,
  ZTIMEZONENAME VARCHAR, ZTITLE VARCHAR, ZREVERSELOCATIONDATA BLOB );
CREATE INDEX Z_AdditionalAssetAttributes_asset ON ZADDITIONALASSETATTRIBUTES (ZASSET);
CREATE TABLE ZEXTENDEDATTRIBUTES ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZFLASHFIRED INTEGER, ZISO INTEGER, ZASSET INTEGER, ZAPERTURE FLOAT, ZDATECREATED TIMESTAMP,
  ZDURATION FLOAT, ZFOCALLENGTH FLOAT, ZLATITUDE FLOAT, ZLONGITUDE FLOAT, ZSHUTTERSPEED FLOAT, ZCAMERAMAKE VARCHAR, ZCAMERAMODEL VARCHAR, ZLENSMODEL VARCHAR, ZTIMEZONENAME VARCHAR );
CREATE TABLE ZMEDIAANALYSISASSETATTRIBUTES ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZCHARACTERRECOGNITIONVERSION INTEGER, ZFACECOUNT INTEGER,
  ZIMAGECAPTIONVERSION INTEGER, ZIMAGEEMBEDDINGVERSION INTEGER, ZMEDIAANALYSISVERSION INTEGER, ZVIDEOCAPTIONVERSION INTEGER, ZVISUALSEARCHVERSION INTEGER, ZASSET INTEGER,
  ZCHARACTERRECOGNITIONATTRIBUTES INTEGER, ZACTIVITYSCORE FLOAT, ZBLURRINESSSCORE FLOAT, ZEXPOSURESCORE FLOAT, ZMEDIAANALYSISTIMESTAMP TIMESTAMP, ZWALLPAPERSCORE FLOAT );
CREATE TABLE ZCHARACTERRECOGNITIONATTRIBUTES ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZALGORITHMVERSION INTEGER, ZMEDIAANALYSISASSETATTRIBUTES INTEGER,
  ZADJUSTMENTVERSION TIMESTAMP, ZCHARACTERRECOGNITIONDATA BLOB, ZMACHINEREADABLECODEDATA BLOB, ZTEXTUNDERSTANDINGDATA BLOB );
CREATE TABLE ZCOMPUTEDASSETATTRIBUTES ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZASSET INTEGER, ZFAILURESCORE FLOAT, ZHARMONIOUSCOLORSCORE FLOAT,
  ZIMMERSIVENESSSCORE FLOAT, ZINTERESTINGSUBJECTSCORE FLOAT, ZLIVELYCOLORSCORE FLOAT, ZNOISESCORE FLOAT, ZPLEASANTCOMPOSITIONSCORE FLOAT, ZPLEASANTLIGHTINGSCORE FLOAT,
  ZSHARPLYFOCUSEDSUBJECTSCORE FLOAT, ZWELLFRAMEDSUBJECTSCORE FLOAT, ZWELLTIMEDSHOTSCORE FLOAT );
CREATE TABLE ZASSETDESCRIPTION ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZASSETATTRIBUTES INTEGER, ZLONGDESCRIPTION VARCHAR );
CREATE TABLE ZSCENECLASSIFICATION ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZCLASSIFICATIONTYPE INTEGER, ZPACKEDBOUNDINGBOXRECT INTEGER, ZSCENEIDENTIFIER INTEGER,
  ZASSETATTRIBUTES INTEGER, ZASSETATTRIBUTESFORTEMPORALSCENECLASSIFICATIONS INTEGER, ZCONFIDENCE FLOAT, ZDURATION FLOAT, ZSTARTTIME FLOAT, ZTHUMBNAILIDENTIFIER VARCHAR );
CREATE TABLE ZPERSON ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZAGETYPE INTEGER, ZCLOUDVERIFIEDTYPE INTEGER, ZDETECTIONTYPE INTEGER, ZFACECOUNT INTEGER,
  ZGENDERTYPE INTEGER, ZINPERSONNAMINGMODEL INTEGER, ZMANUALORDER INTEGER, ZTYPE INTEGER, ZVERIFIEDTYPE INTEGER, ZKEYFACE INTEGER, ZMERGETARGETPERSON INTEGER,
  ZSHAREPARTICIPANT INTEGER, ZISMECONFIDENCE FLOAT, ZMERGECANDIDATECONFIDENCE FLOAT, ZDISPLAYNAME VARCHAR, ZFULLNAME VARCHAR, ZMDID VARCHAR, ZPERSONUUID VARCHAR,
  ZPERSONURI VARCHAR, ZCONTACTMATCHINGDICTIONARY BLOB );
CREATE TABLE ZDETECTEDFACE ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZAGETYPE INTEGER, ZASSETVISIBLE INTEGER, ZDETECTIONTYPE INTEGER, ZETHNICITYTYPE INTEGER,
  ZEYEMAKEUPTYPE INTEGER, ZEYESSTATE INTEGER, ZFACEALGORITHMVERSION INTEGER, ZFACEEXPRESSIONTYPE INTEGER, ZFACIALHAIRTYPE INTEGER, ZGAZETYPE INTEGER, ZGENDERTYPE INTEGER,
  ZGLASSESTYPE INTEGER, ZHAIRCOLORTYPE INTEGER, ZHAIRTYPE INTEGER, ZHASFACEMASK INTEGER, ZHASSMILE INTEGER, ZHEADGEARTYPE INTEGER, ZHIDDEN INTEGER, ZISLEFTEYECLOSED INTEGER,
  ZISRIGHTEYECLOSED INTEGER, ZLIPMAKEUPTYPE INTEGER, ZMANUAL INTEGER, ZNAMESOURCE INTEGER, ZPOSETYPE INTEGER, ZQUALITYMEASURE INTEGER, ZSKINTONETYPE INTEGER, ZSMILETYPE INTEGER,
  ZSOURCEHEIGHT INTEGER, ZSOURCEWIDTH INTEGER, ZASSETFORFACE INTEGER, ZPERSONFORFACE INTEGER, ZBLURSCORE FLOAT, ZCENTERX FLOAT, ZCENTERY FLOAT, ZQUALITY FLOAT, ZROLL FLOAT,
  ZSIZE FLOAT, ZUUID VARCHAR );
CREATE INDEX Z_DetectedFace_personForFace ON ZDETECTEDFACE (ZPERSONFORFACE);
CREATE INDEX Z_DetectedFace_assetForFace ON ZDETECTEDFACE (ZASSETFORFACE);
CREATE TABLE ZMOMENT ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZCACHEDCOUNT INTEGER, ZCACHEDPHOTOSCOUNT INTEGER, ZCACHEDVIDEOSCOUNT INTEGER, ZPROCESSEDLOCATION INTEGER,
  ZTIMEZONEOFFSET INTEGER, ZTRASHEDSTATE INTEGER, ZHIGHLIGHT INTEGER, ZAGGREGATIONSCORE FLOAT, ZAPPROXIMATELATITUDE FLOAT, ZAPPROXIMATELONGITUDE FLOAT, ZENDDATE TIMESTAMP,
  ZMODIFICATIONDATE TIMESTAMP, ZREPRESENTATIVEDATE TIMESTAMP, ZSTARTDATE TIMESTAMP, ZSUBTITLE VARCHAR, ZTITLE VARCHAR, ZUUID VARCHAR );
CREATE TABLE ZPHOTOSHIGHLIGHT ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZASSETSCOUNT INTEGER, ZCATEGORY INTEGER, ZDAYGROUPASSETSCOUNT INTEGER, ZENDTIMEZONEOFFSET INTEGER,
  ZENRICHMENTSTATE INTEGER, ZENRICHMENTVERSION INTEGER, ZHIGHLIGHTVERSION INTEGER, ZKIND INTEGER, ZMOOD INTEGER, ZSTARTTIMEZONEOFFSET INTEGER, ZSUMMARYCOUNT INTEGER, ZTYPE INTEGER,
  ZVISIBILITYSTATE INTEGER, ZPARENTDAYGROUPPHOTOSHIGHLIGHT INTEGER, ZPARENTPHOTOSHIGHLIGHT INTEGER, ZENDDATE TIMESTAMP, ZLASTENRICHMENTDATE TIMESTAMP, ZPROMOTIONSCORE FLOAT,
  ZSTARTDATE TIMESTAMP, ZSUBTITLE VARCHAR, ZTITLE VARCHAR, ZUUID VARCHAR, ZVERBOSESMARTDESCRIPTION VARCHAR );
CREATE INDEX Z_PhotosHighlight_parentDayGroup ON ZPHOTOSHIGHLIGHT (ZPARENTDAYGROUPPHOTOSHIGHLIGHT);
CREATE TABLE ZMEMORY ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZCATEGORY INTEGER, ZCREATIONTYPE INTEGER, ZFAVORITE INTEGER, ZFEATUREDSTATE INTEGER,
  ZNOTIFICATIONSTATE INTEGER, ZPENDINGSTATE INTEGER, ZPHOTOSGRAPHVERSION INTEGER, ZPLAYCOUNT INTEGER, ZREJECTED INTEGER, ZSHARECOUNT INTEGER, ZSUBCATEGORY INTEGER,
  ZVIEWCOUNT INTEGER, ZKEYASSET INTEGER, ZCREATIONDATE TIMESTAMP, ZENDDATE TIMESTAMP, ZLASTMOVIEPLAYEDDATE TIMESTAMP, ZLASTVIEWEDDATE TIMESTAMP, ZSCORE FLOAT,
  ZSTARTDATE TIMESTAMP, ZGRAPHMEMORYIDENTIFIER VARCHAR, ZSUBTITLE VARCHAR, ZTITLE VARCHAR, ZUUID VARCHAR, ZPHOTOSGRAPHDATA BLOB );
CREATE TABLE ZSUGGESTION ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZCACHEDCOUNT INTEGER, ZCACHEDPHOTOSCOUNT INTEGER, ZCACHEDVIDEOSCOUNT INTEGER, ZFEATUREDSTATE INTEGER,
  ZNOTIFICATIONSTATE INTEGER, ZSTATE INTEGER, ZSUBTYPE INTEGER, ZTYPE INTEGER, ZVERSION INTEGER, ZACTIVATIONDATE TIMESTAMP, ZCREATIONDATE TIMESTAMP, ZENDDATE TIMESTAMP,
  ZRELEVANTUNTILDATE TIMESTAMP, ZSTARTDATE TIMESTAMP, ZSUBTITLE VARCHAR, ZTITLE VARCHAR, ZUUID VARCHAR );
CREATE TABLE ZSHARE ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZASSETCOUNT INTEGER, ZCLOUDPHOTOCOUNT INTEGER, ZCLOUDVIDEOCOUNT INTEGER, ZCURRENTPARTICIPANTROLE INTEGER,
  ZPHOTOSCOUNT INTEGER, ZSCOPETYPE INTEGER, ZSTATUS INTEGER, ZTRASHEDSTATE INTEGER, ZVIDEOSCOUNT INTEGER, ZCOLLECTIONSHAREKIND INTEGER, ZAUTOSHAREPOLICY INTEGER,
  ZCREATIONDATE TIMESTAMP, ZENDDATE TIMESTAMP, ZSTARTDATE TIMESTAMP, ZSCOPEIDENTIFIER VARCHAR, ZTITLE VARCHAR, ZUUID VARCHAR );
CREATE TABLE ZSHAREPARTICIPANT ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZACCEPTANCESTATUS INTEGER, ZCONTRIBUTEDASSETSCOUNT INTEGER, ZISCURRENTUSER INTEGER,
  ZPARTICIPANTKIND INTEGER, ZPARTICIPANTROLE INTEGER, ZPERSON INTEGER, ZSHARE INTEGER, Z71_SHARE INTEGER, ZSUBSCRIPTIONDATE TIMESTAMP, ZEMAILADDRESS VARCHAR,
  ZPARTICIPANTID VARCHAR, ZPHONENUMBER VARCHAR, ZUSERIDENTIFIER VARCHAR, ZUUID VARCHAR, ZNAMECOMPONENTS BLOB );
CREATE TABLE ZGENERICALBUM ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZCACHEDCOUNT INTEGER, ZCACHEDPHOTOSCOUNT INTEGER, ZCACHEDVIDEOSCOUNT INTEGER, ZKIND INTEGER,
  ZTRASHEDSTATE INTEGER, ZPARENTFOLDER INTEGER, ZCREATIONDATE TIMESTAMP, ZENDDATE TIMESTAMP, ZSTARTDATE TIMESTAMP, ZIMPORTEDBYBUNDLEIDENTIFIER VARCHAR, ZTITLE VARCHAR,
  ZUUID VARCHAR );
CREATE TABLE ZCLOUDSHAREDCOMMENT ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZISBATCHCOMMENT INTEGER, ZISCAPTION INTEGER, ZISDELETABLE INTEGER, ZISLIKE INTEGER,
  ZISMYCOMMENT INTEGER, ZCOMMENTEDASSET INTEGER, ZLIKEDASSET INTEGER, ZSHAREPARTICIPANT INTEGER, ZCOMMENTDATE TIMESTAMP, ZCLOUDGUID VARCHAR, ZCOMMENTTEXT VARCHAR,
  ZCOMMENTTYPE VARCHAR );
CREATE TABLE ZLEOLEXEME ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZCATEGORY INTEGER, ZLEXEMEID INTEGER, ZLEXEMETYPE INTEGER, ZSCORE FLOAT, ZCONTENT VARCHAR,
  ZIDENTIFIER VARCHAR );
CREATE INDEX Z_LeoLexeme_category ON ZLEOLEXEME (ZCATEGORY);
CREATE TABLE ZLEOITEM ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZITEMTYPE INTEGER, ZDATECREATED TIMESTAMP, ZIDENTIFIER VARCHAR, ZLEXEMEIDSDATA BLOB );
CREATE TABLE ZGRAPHLABEL ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZCODE INTEGER, ZALIAS VARCHAR, ZEDGEEXTERNALIDENTIFIERDATAHAVINGLABEL BLOB,
  ZNODEEXTERNALIDENTIFIERDATAHAVINGLABEL BLOB );
CREATE TABLE ZGRAPHNODE ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZCLOUDLOCALSTATE INTEGER, ZEXTERNALIDENTIFIER INTEGER, ZPRIMARYLABELCODE INTEGER,
  ZACTINGASSET INTEGER, ZACTINGMOMENT INTEGER, ZACTINGPERSON INTEGER, ZPRIMARYLABEL INTEGER, ZUUID VARCHAR );
CREATE TABLE ZGRAPHNODEVALUE ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZBOOLVALUE INTEGER, ZINTEGERVALUE INTEGER, ZNAMECODE INTEGER, ZNODE INTEGER,
  ZDATEVALUE TIMESTAMP, ZDOUBLEVALUE FLOAT, ZOBSOLETED_VALUENAME VARCHAR, ZSTRINGVALUE VARCHAR );
CREATE INDEX Z_GraphNodeValue_node ON ZGRAPHNODEVALUE (ZNODE);
CREATE INDEX Z_GraphNodeValue_nameCode ON ZGRAPHNODEVALUE (ZNAMECODE);
CREATE TABLE ZGRAPHEDGE ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZEXTERNALIDENTIFIER INTEGER, ZPRIMARYLABEL INTEGER, ZSOURCEASSET INTEGER, ZSOURCEMOMENT INTEGER,
  ZSOURCENODE INTEGER, ZSOURCEPERSON INTEGER, ZTARGETASSET INTEGER, ZTARGETMOMENT INTEGER, ZTARGETNODE INTEGER, ZTARGETPERSON INTEGER );
CREATE INDEX Z_GraphEdge_targetNode ON ZGRAPHEDGE (ZTARGETNODE);
"""


def _dict_rows(con, table: str, rows: Iterable[dict]) -> int:
    """executemany for rows that share one key set (much faster than row-at-a-time inserts)."""
    rows = list(rows)
    if not rows:
        return 0
    columns = list(rows[0].keys())
    sql = f'INSERT INTO {table} ({", ".join(columns)}) VALUES ({", ".join("?" for _ in columns)})'
    con.executemany(sql, [[row.get(c) for c in columns] for row in rows])
    return len(rows)


def _revgeo_archive(spot: Spot, is_home: bool) -> bytes:
    """A PLRevGeoLocationInfo keyed archive as Photos stores it per asset."""
    street = spot.street
    lines = [street, spot.suburb, f"{spot.city} {spot.postal}".strip(), spot.country]
    postal = lib.ArchiveObject("CNPostalAddress", {
        "_street": street, "_subLocality": spot.suburb, "_city": spot.city, "_subAdministrativeArea": spot.city, "_state": spot.region,
        "_postalCode": spot.postal, "_country": spot.country, "_ISOCountryCode": spot.cc.lower(), "_formattedAddress": None,
    })

    def place(name: str, level: int, area: float) -> lib.ArchiveObject:
        return lib.ArchiveObject("PLRevGeoMapItemAdditionalPlaceInfo", {"name": name, "placeType": level, "area": float(area), "dominantOrderType": 0})

    infos = []
    if spot.name and not spot.private:
        infos.append(place(spot.name, 12, 0.0 if not spot.landmark else 48_000.0))
    infos.append(place(spot.street_name, 11, 0.0))
    infos.append(place(spot.suburb, 9, 2.1e6))
    if spot.water:
        infos.append(place(spot.water, 8, 8.4e7))
    infos.append(place(spot.city, 6, 2.9e8 if spot.cc == "NZ" else 1.2e9))
    if spot.region != spot.city:
        infos.append(place(spot.region, 2, 8.1e9 if spot.cc == "NZ" else 8.0e11))
    infos.append(place(spot.country, 1, {"NZ": 2.68e11, "AU": 7.69e12, "FJ": 1.83e10}[spot.cc]))
    item = lib.ArchiveObject("PLRevGeoMapItem", {"sortedPlaceInfos": infos, "finalPlaceInfos": infos[:3], "backupPlaceInfos": []})
    root = lib.ArchiveObject("PLRevGeoLocationInfo", {
        "isHome": bool(is_home), "addressString": "\n".join(p for p in lines if p), "countryCode": spot.cc, "version": 16, "geoServiceProvider": "7618",
        "compoundNames": None, "compoundSecondaryNames": None, "postalAddress": postal, "mapItem": item,
    })
    return lib.keyed_archive(root, mutable_collections=True)


def _name_components(given: str, family: str) -> bytes:
    data = lib.ArchiveObject("_NSPersonNameComponentsData", {
        "NS.givenName": given, "NS.familyName": family, "NS.middleName": None, "NS.namePrefix": None, "NS.nameSuffix": None, "NS.nickname": None,
        "NS.phoneticRepresentation": None})
    return lib.keyed_archive(lib.ArchiveObject("NSPersonNameComponents", {"NS.nameComponentsPrivate": data}))


_SEASONS = {12: "Summer", 1: "Summer", 2: "Summer", 3: "Autumn", 4: "Autumn", 5: "Autumn", 6: "Winter", 7: "Winter", 8: "Winter", 9: "Spring", 10: "Spring", 11: "Spring"}
_MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
_WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]


def _part_of_day(hour: int) -> str:
    return "Night" if hour < 6 or hour >= 22 else ("Morning" if hour < 12 else ("Afternoon" if hour < 18 else "Evening"))


class Lexicon:
    """The Leo search lexicon: (category, term) -> lexeme id; synonyms share the id of their term."""

    def __init__(self, rng: random.Random):
        self.rng = rng
        self.ids: dict[tuple[int, str], int] = {}
        self.rows: list[tuple[int, int, int, str, str]] = []     # category, lexeme id, type, content, identifier
        self.next_id = 1

    def term(self, category: int, content: str, identifier: str = "", synonyms: tuple = ()) -> int:
        key = (category, content)
        found = self.ids.get(key)
        if found is not None:
            return found
        lexeme = self.next_id
        self.next_id += 1
        self.ids[key] = lexeme
        self.rows.append((category, lexeme, 1, content, identifier))
        for synonym in synonyms:
            self.rows.append((category, lexeme, 2, synonym, identifier))
        return lexeme


_SYNONYMS = {
    (1040, "Summer"): ("Summertime",), (1040, "Winter"): ("Wintertime",), (1040, "Autumn"): ("Fall",), (1040, "Spring"): ("Springtime",),
    (1050, "Evening"): ("Dusk", "Sunset"), (1050, "Morning"): ("Dawn", "Sunrise"), (1050, "Night"): ("Nighttime",), (1060, "Weekend"): ("Weekends",),
    (1030, "Christmas Day"): ("Christmas", "Xmas"), (1030, "New Year's Day"): ("New Year",), (2010, "Home"): ("House", "My home"), (2170, "NZ"): ("Aotearoa",),
    (4000, "Cat"): ("Kitten", "Feline"), (4000, "Coffee"): ("Espresso", "Latte"), (4000, "Sea"): ("Ocean",), (4000, "Mountain"): ("Peak", "Alps"),
    (4000, "Food"): ("Meal", "Dish"), (4000, "Sunset"): ("Dusk",), (4000, "Forest"): ("Woods", "Bush"), (4000, "Beach"): ("Shore", "Seaside"),
    (4000, "Bird"): ("Birds",), (4000, "Whiteboard"): ("Dry-erase board",), (4000, "Cityscape"): ("Skyline",), (4000, "Concert"): ("Gig", "Live music"),
    (4090, "Hiking"): ("Hike", "Trek", "Tramping"), (4090, "Birthday"): ("Birthday party",), (4090, "Dinner"): ("Supper",), (4090, "Night Out"): ("Party",),
    (4090, "Wedding"): ("Marriage",), (4090, "Beaching"): ("Beach day",), (4100, "Trip"): ("Vacation", "Holiday", "Travel"), (8000, "Favourite"): ("Favorite", "Favorites"),
    (4050, "Music"): ("Song",), (4060, "Hiking"): ("Tramping",), (4130, "Receipt"): ("Bill", "Invoice"), (3010, PET_NAME): ("Cat",),
    (7030, "Family"): ("Shared album",), (2260, "Music Concerts"): ("Concerts", "Gigs"),
}

# Leo category -> psi category (terms) / psi category of its synonyms.
_PSI = {
    1010: (1100, None), 1020: (1101, None), 1030: (1103, 0), 1040: (1104, 1105), 1050: (1106, 1108), 1060: (1107, 1109), 2010: (1000, None), 2020: (1001, None),
    2050: (2, None), 2060: (1, None), 2070: (3, None), 2080: (4, None), 2090: (5, None), 2140: (10, None), 2160: (12, None), 2210: (14, None), 2220: (1700, None),
    2230: (1701, None), 2240: (1800, None), 2250: (1801, None), 2260: (1802, 1803), 3000: (1300, None), 3010: (1330, 1331), 3020: (1320, 1321), 4000: (1500, 1501),
    4010: (1510, None), 4020: (1520, None), 4050: (2500, 2501), 4060: (2600, 2601), 4080: (2800, None), 4090: (1600, 1601), 4100: (1610, 1611), 4110: (1205, None),
    4120: (1203, None), 5000: (1900, None), 5010: (1901, None), 5060: (1902, None), 5070: (1903, None), 5080: (1905, None), 5090: (1906, None), 5050: (1907, None),
    5150: (1908, None), 6000: (2300, None), 7000: (1201, None), 7010: (1400, None), 7020: (1401, None), 8000: (2000, None), 8030: (2401, None), 8040: (2400, None),
    8050: (2100, None), 8060: (2200, None), 8080: (1202, None),
}

_MEANING_NAMES = {"NightOut": "Night Out", "HolidayEvent": "Holiday Event", "SportEvent": "Sport Event"}


def _write_photos(path: pathlib.Path, library: Library, people: list[PersonRow], by_key: dict[str, PersonRow]) -> dict:
    rng, persona, clock = library.rng, library.persona, library.clock
    now = library.now
    owner, partner = persona.owner, persona.person("partner")
    cocoa = lib.cocoa
    tz_seconds = int(persona.tz_offset_hours * 3600)
    assets, moments = library.assets, library.moments
    out: dict[str, Any] = {}

    with lib.sqlite_db(path, _PHOTOS_DDL) as con:
        # ---- scene identifiers -------------------------------------------------------------
        scene_names = sorted({s for pool in _SCENES.values() for s in pool} | {"People", "Fireworks"})
        scene_ids = {name: 100 + 7 * i + rng.randrange(5) for i, name in enumerate(scene_names)}
        out["scene_ids"] = scene_ids

        # ---- highlights: days, months, years and the trips' day groups ---------------------
        highlights: list[dict] = []

        def highlight(**values: Any) -> int:
            row = {"Z_PK": len(highlights) + 1, "Z_ENT": _ENT["PhotosHighlight"], "Z_OPT": 1, "ZASSETSCOUNT": 0, "ZCATEGORY": 0, "ZDAYGROUPASSETSCOUNT": 0,
                   "ZENDTIMEZONEOFFSET": tz_seconds, "ZENRICHMENTSTATE": 4, "ZENRICHMENTVERSION": 41, "ZHIGHLIGHTVERSION": 42, "ZKIND": 0, "ZMOOD": 0,
                   "ZSTARTTIMEZONEOFFSET": tz_seconds, "ZSUMMARYCOUNT": 0, "ZTYPE": 0, "ZVISIBILITYSTATE": 1, "ZPARENTDAYGROUPPHOTOSHIGHLIGHT": None,
                   "ZPARENTPHOTOSHIGHLIGHT": None, "ZENDDATE": None, "ZLASTENRICHMENTDATE": None, "ZPROMOTIONSCORE": 0.0, "ZSTARTDATE": None, "ZSUBTITLE": None,
                   "ZTITLE": None, "ZUUID": lib.uuid_string(rng), "ZVERBOSESMARTDESCRIPTION": None}
            row.update(values)
            highlights.append(row)
            return row["Z_PK"]

        def date_text(when: datetime.datetime) -> str:
            local = library.local(when)
            return f"{local.day} {_MONTHS[local.month - 1][:3]} {local.year}"

        trip_highlight: dict[int, int] = {}
        for trip in library.trips:
            if not trip.moments:
                continue
            first, last = trip.moments[0].start, trip.moments[-1].end
            a, b = library.local(first), library.local(last)
            span = f"{a.day}–{b.day} {_MONTHS[b.month - 1][:3]} {b.year}" if a.month == b.month else f"{a.day} {_MONTHS[a.month - 1][:3]} – {b.day} {_MONTHS[b.month - 1][:3]} {b.year}"
            companions = [persona.person(k).given for k in trip.companions]
            trip_highlight[trip.index] = highlight(
                ZKIND=3, ZTYPE=1 if trip.long else 2, ZSTARTDATE=cocoa(first), ZENDDATE=cocoa(last), ZTITLE=span, ZSUBTITLE=trip.name, ZUUID=trip.uuid,
                ZASSETSCOUNT=sum(len(m.assets) for m in trip.moments), ZDAYGROUPASSETSCOUNT=sum(len(m.assets) for m in trip.moments),
                ZPROMOTIONSCORE=round(rng.uniform(0.6, 0.95), 3), ZVISIBILITYSTATE=3,
                ZVERBOSESMARTDESCRIPTION=f"{'A long' if trip.long else 'A short'} trip to {trip.name} with {' and '.join(companions)}",
                ZLASTENRICHMENTDATE=cocoa(min(now, last + datetime.timedelta(days=2))))
        by_day: dict[tuple, list[Moment]] = {}
        for moment in moments:
            local = library.local(moment.start)
            by_day.setdefault((local.year, local.month, local.day), []).append(moment)
        moment_highlight: dict[int, int] = {}
        months: dict[tuple, list] = {}
        for day_key in sorted(by_day):
            group = by_day[day_key]
            main = max(group, key=lambda m: (m.kind == "camera", len(m.assets)))
            count = sum(len(m.assets) for m in group)
            trip_index = next((m.trip for m in group if m.trip is not None), None)
            title = main.spot.suburb if main.kind == "camera" else ("Screenshots" if main.kind == "screenshot" else "Saved images")
            names = [persona.person(k).given for k in main.people[:3]]
            what = _MEANING_NAMES.get(main.meaning, main.meaning) or {"home": "At home", "work": "At work"}.get(main.context, "A day out" if main.kind == "camera" else "")
            smart = (f"{what} in {main.spot.suburb}" + (f" with {', '.join(names)}" if names else "")) if what and main.kind == "camera" else None
            interesting = main.kind == "camera" and (count >= 6 or bool(main.meaning))
            pk = highlight(ZKIND=0, ZTYPE=5 if trip_index is not None else 0, ZCATEGORY=0 if interesting or trip_index is not None else 1, ZSTARTDATE=cocoa(group[0].start),
                           ZENDDATE=cocoa(group[-1].end), ZTITLE=date_text(group[0].start), ZSUBTITLE=title, ZASSETSCOUNT=count, ZSUMMARYCOUNT=min(count, 12),
                           ZPROMOTIONSCORE=round(min(0.99, 0.12 + 0.03 * count + (0.3 if main.meaning else 0) + rng.uniform(0, 0.2)), 3),
                           ZVISIBILITYSTATE=rng.choice([1, 2, 3]) if interesting else rng.choice([0, 0, 1]), ZENRICHMENTSTATE=4 if group[-1].end < now - datetime.timedelta(days=2) else rng.choice([0, 2]),
                           ZPARENTDAYGROUPPHOTOSHIGHLIGHT=trip_highlight.get(trip_index) if trip_index is not None else None, ZVERBOSESMARTDESCRIPTION=smart,
                           ZLASTENRICHMENTDATE=cocoa(min(now, group[-1].end + datetime.timedelta(hours=30))))
            for m in group:
                moment_highlight[m.index] = pk
            months.setdefault(day_key[:2], []).append((pk, count, group[0].start, group[-1].end))
        years: dict[int, list] = {}
        for month_key in sorted(months):
            rows_ = months[month_key]
            total = sum(r[1] for r in rows_)
            pk = highlight(ZKIND=1, ZSTARTDATE=cocoa(rows_[0][2]), ZENDDATE=cocoa(rows_[-1][3]), ZTITLE=f"{_MONTHS[month_key[1] - 1]} {month_key[0]}", ZSUBTITLE=None,
                           ZASSETSCOUNT=total, ZPROMOTIONSCORE=round(rng.uniform(0.2, 0.8), 3), ZVISIBILITYSTATE=2)
            for child_pk, *_ in rows_:
                highlights[child_pk - 1]["ZPARENTPHOTOSHIGHLIGHT"] = pk
            years.setdefault(month_key[0], []).append((total, rows_[0][2], rows_[-1][3]))
        for year in sorted(years):
            rows_ = years[year]
            highlight(ZKIND=2, ZSTARTDATE=cocoa(rows_[0][1]), ZENDDATE=cocoa(rows_[-1][2]), ZTITLE=str(year), ZASSETSCOUNT=sum(r[0] for r in rows_),
                      ZPROMOTIONSCORE=round(rng.uniform(0.4, 0.9), 3), ZVISIBILITYSTATE=2)
        _dict_rows(con, "ZPHOTOSHIGHLIGHT", highlights)
        out["trip_highlight"] = trip_highlight

        # ---- moments -----------------------------------------------------------------------
        _dict_rows(con, "ZMOMENT", ({
            "Z_PK": m.index + 1, "Z_ENT": _ENT["Moment"], "Z_OPT": 2, "ZCACHEDCOUNT": len(m.assets), "ZCACHEDPHOTOSCOUNT": sum(1 for a in m.assets if a.kind == 0),
            "ZCACHEDVIDEOSCOUNT": sum(1 for a in m.assets if a.kind == 1), "ZPROCESSEDLOCATION": 5 if m.kind == "camera" else 0, "ZTIMEZONEOFFSET": tz_seconds, "ZTRASHEDSTATE": 0,
            "ZHIGHLIGHT": moment_highlight[m.index], "ZAGGREGATIONSCORE": round(rng.uniform(0.1, 0.9), 3),
            "ZAPPROXIMATELATITUDE": m.spot.lat if m.kind == "camera" else None, "ZAPPROXIMATELONGITUDE": m.spot.lon if m.kind == "camera" else None,
            "ZENDDATE": cocoa(m.assets[-1].when), "ZMODIFICATIONDATE": cocoa(min(now, m.end + datetime.timedelta(hours=3))), "ZREPRESENTATIVEDATE": cocoa(m.start),
            "ZSTARTDATE": cocoa(m.assets[0].when), "ZSUBTITLE": m.spot.city if m.kind == "camera" else None,
            "ZTITLE": (m.spot.name or m.spot.suburb) if m.kind == "camera" else None, "ZUUID": m.uuid,
        } for m in moments))

        # ---- people and shares ---------------------------------------------------------------
        face_counts: dict[str, int] = {}
        for asset in assets:
            for key in asset.faces:
                face_counts[key] = face_counts.get(key, 0) + 1
        for row in people:
            row.faces = face_counts.get(row.key, 0)
        participant_of = {owner.key: 1, partner.key: 2}
        _dict_rows(con, "ZPERSON", ({
            "Z_PK": p.pk, "Z_ENT": _ENT["Person"], "Z_OPT": 3, "ZAGETYPE": p.age, "ZCLOUDVERIFIEDTYPE": max(p.verified, 0), "ZDETECTIONTYPE": p.detection,
            "ZFACECOUNT": p.faces if (p.full_name or rng.random() < 0.15) else 0, "ZGENDERTYPE": p.gender, "ZINPERSONNAMINGMODEL": 1 if p.full_name else 0,
            "ZMANUALORDER": p.pk, "ZTYPE": p.type, "ZVERIFIEDTYPE": p.verified, "ZKEYFACE": None, "ZMERGETARGETPERSON": p.merge_target,
            "ZSHAREPARTICIPANT": participant_of.get(p.key), "ZISMECONFIDENCE": p.me_confidence, "ZMERGECANDIDATECONFIDENCE": 0.0,
            "ZDISPLAYNAME": p.display_name or None, "ZFULLNAME": p.full_name or None, "ZMDID": p.mdid or None, "ZPERSONUUID": p.uuid, "ZPERSONURI": p.uri or None,
            "ZCONTACTMATCHINGDICTIONARY": None,
        } for p in people))

        shared_assets = [a for a in assets if a.shared]
        album_defs = [("Queenstown with Alex", ["alex"], 96, lambda a: a.moment.trip == 0),
                      ("Rotorua weekend", ["priya", "tom", "mei"], 212, lambda a: a.moment.trip == 1),
                      ("Family Christmas", ["helen", "david", "jamie", "alex"], 300, lambda a: a.moment.holiday == "Christmas Day")]
        shares: list[dict] = []
        participants: list[dict] = []

        def participant(share_pk: int, share_ent: int, person, current: bool, role: int, contributed: int, since: datetime.datetime) -> int:
            pk = len(participants) + 1
            participants.append({
                "Z_PK": pk, "Z_ENT": _ENT["ShareParticipant"], "Z_OPT": 1, "ZACCEPTANCESTATUS": 2, "ZCONTRIBUTEDASSETSCOUNT": contributed, "ZISCURRENTUSER": int(current),
                "ZPARTICIPANTKIND": 0 if share_ent == _ENT["LibraryScope"] else 1, "ZPARTICIPANTROLE": role, "ZPERSON": by_key[person.key].pk if person.key in by_key else None,
                "ZSHARE": share_pk, "Z71_SHARE": share_ent, "ZSUBSCRIPTIONDATE": cocoa(since), "ZEMAILADDRESS": person.email, "ZPARTICIPANTID": lib.uuid_string(rng),
                "ZPHONENUMBER": person.phone or None, "ZUSERIDENTIFIER": "_" + lib.hex_string(rng, 32), "ZUUID": lib.uuid_string(rng),
                "ZNAMECOMPONENTS": _name_components(person.given, person.family)})
            return pk

        library_since = clock.at(SHARED_LIBRARY_SINCE, 20)
        shares.append({"Z_PK": 1, "Z_ENT": _ENT["LibraryScope"], "Z_OPT": 4, "ZASSETCOUNT": len(shared_assets), "ZCLOUDPHOTOCOUNT": sum(1 for a in shared_assets if a.kind == 0),
                       "ZCLOUDVIDEOCOUNT": sum(1 for a in shared_assets if a.kind == 1), "ZCURRENTPARTICIPANTROLE": 1, "ZPHOTOSCOUNT": sum(1 for a in shared_assets if a.kind == 0),
                       "ZSCOPETYPE": 4, "ZSTATUS": 1, "ZTRASHEDSTATE": 0, "ZVIDEOSCOUNT": sum(1 for a in shared_assets if a.kind == 1), "ZCOLLECTIONSHAREKIND": None,
                       "ZAUTOSHAREPOLICY": 1, "ZCREATIONDATE": cocoa(library_since), "ZENDDATE": None, "ZSTARTDATE": cocoa(library_since),
                       "ZSCOPEIDENTIFIER": "SharedSync-" + lib.uuid_string(rng), "ZTITLE": None, "ZUUID": lib.uuid_string(rng)})
        participant(1, _ENT["LibraryScope"], owner, True, 1, sum(1 for a in shared_assets if a.contributor == "owner"), library_since)
        participant(1, _ENT["LibraryScope"], partner, False, 2, sum(1 for a in shared_assets if a.contributor == "partner"), library_since + datetime.timedelta(hours=3))
        album_assets: dict[int, list[Asset]] = {}
        for title, members, days_ago, predicate in album_defs:
            chosen = [a for a in assets if predicate(a) and a.kind == 0 and a.moment.kind == "camera"]
            chosen = rng.sample(chosen, min(len(chosen), rng.randint(24, 60)))
            pk = len(shares) + 1
            created = clock.at(max(1, days_ago - 4), 19)
            album_assets[pk] = chosen
            shares.append({"Z_PK": pk, "Z_ENT": _ENT["CollectionShare"], "Z_OPT": 2, "ZASSETCOUNT": len(chosen), "ZCLOUDPHOTOCOUNT": len(chosen), "ZCLOUDVIDEOCOUNT": 0,
                           "ZCURRENTPARTICIPANTROLE": 1, "ZPHOTOSCOUNT": len(chosen), "ZSCOPETYPE": 0, "ZSTATUS": 3 if title == "Family Christmas" else 1, "ZTRASHEDSTATE": 0,
                           "ZVIDEOSCOUNT": 0, "ZCOLLECTIONSHAREKIND": 2, "ZAUTOSHAREPOLICY": 0, "ZCREATIONDATE": cocoa(created), "ZENDDATE": None, "ZSTARTDATE": cocoa(created),
                           "ZSCOPEIDENTIFIER": "CollectionShare-" + lib.uuid_string(rng), "ZTITLE": title, "ZUUID": lib.uuid_string(rng)})
            given = [rng.randint(2, max(3, len(chosen) // 4)) for _ in members]
            participant(pk, _ENT["CollectionShare"], owner, True, 5, max(1, len(chosen) - sum(given)), created)
            for member, n in zip(members, given):
                participant(pk, _ENT["CollectionShare"], persona.person(member), False, 6, n if rng.random() < 0.75 else 0, created + datetime.timedelta(hours=rng.randint(1, 60)))
        _dict_rows(con, "ZSHARE", shares)
        _dict_rows(con, "ZSHAREPARTICIPANT", participants)

        comments: list[dict] = []
        remarks = ["Love this one!", "What a view", "Can you send me the full size?", "Haha, the wind", "Best trip", "Frame this", "Mum will want a print",
                   "That pizza though", "Look at Dad's face", "So good to see everyone", "Next year again?", "The light here is unreal"]
        for share_pk, chosen in album_assets.items():
            members = [p for p in participants if p["ZSHARE"] == share_pk]
            for asset in rng.sample(chosen, min(len(chosen), rng.randint(20, 30))) * 2:
                who = rng.choice(members)
                like = rng.random() < 0.62
                comments.append({"Z_PK": len(comments) + 1, "Z_ENT": _ENT["CloudSharedComment"], "Z_OPT": 1, "ZISBATCHCOMMENT": 0, "ZISCAPTION": 0, "ZISDELETABLE": who["ZISCURRENTUSER"],
                                 "ZISLIKE": int(like), "ZISMYCOMMENT": who["ZISCURRENTUSER"], "ZCOMMENTEDASSET": None if like else asset.pk, "ZLIKEDASSET": asset.pk if like else None,
                                 "ZSHAREPARTICIPANT": who["Z_PK"], "ZCOMMENTDATE": cocoa(min(now, asset.when + datetime.timedelta(days=rng.uniform(1, 9)))),
                                 "ZCLOUDGUID": lib.uuid_string(rng), "ZCOMMENTTEXT": None if like else rng.choice(remarks), "ZCOMMENTTYPE": "like" if like else "comment"})
        _dict_rows(con, "ZCLOUDSHAREDCOMMENT", comments)

        # ---- albums ------------------------------------------------------------------------
        albums: list[dict] = []

        def album(ent: str, kind: int, title: Optional[str], count: int, created: Optional[datetime.datetime], **extra: Any) -> int:
            row = {"Z_PK": len(albums) + 1, "Z_ENT": _ENT[ent], "Z_OPT": 1, "ZCACHEDCOUNT": count, "ZCACHEDPHOTOSCOUNT": int(count * 0.93), "ZCACHEDVIDEOSCOUNT": count - int(count * 0.93),
                   "ZKIND": kind, "ZTRASHEDSTATE": 0, "ZPARENTFOLDER": None, "ZCREATIONDATE": cocoa(created) if created else None, "ZENDDATE": None, "ZSTARTDATE": None,
                   "ZIMPORTEDBYBUNDLEIDENTIFIER": None, "ZTITLE": title, "ZUUID": lib.uuid_string(rng)}
            row.update(extra)
            albums.append(row)
            return row["Z_PK"]

        root_folder = album("Folder", 3999, None, 0, clock.at(SPAN_DAYS, 9))
        trips_folder = album("Folder", 4000, "Trips", 0, clock.at(1100, 20), ZPARENTFOLDER=root_folder)
        user_albums = [("Queenstown", lambda a: a.moment.trip in (0, 4), trips_folder, 90), ("Fiji", lambda a: a.moment.trip == 3, trips_folder, 560),
                       ("Sydney", lambda a: a.moment.trip in (5, 8), trips_folder, 1150), (PET_NAME, lambda a: "pet" in a.faces, root_folder, 1300),
                       ("Climbing", lambda a: a.moment.context == "gym", root_folder, 1500), ("Whiteboards", lambda a: a.ocr is not None and a.ocr[1] == "Whiteboard", root_folder, 700),
                       ("Receipts", lambda a: a.ocr is not None and a.ocr[1] == "Receipt", root_folder, 420), ("Design inspiration", lambda a: a.moment.kind == "saved", root_folder, 1900),
                       ("Family", lambda a: a.moment.context == "family", root_folder, 2000), ("Birds", lambda a: a.vlu in ("Tūī", "Kākā", "Kererū", "Takahē", "Kea"), root_folder, 800)]
        album_members: dict[str, list[Asset]] = {}
        for title, predicate, parent, days_ago in user_albums:
            members_ = [a for a in assets if predicate(a)]
            members_ = members_ if len(members_) < 40 else rng.sample(members_, int(len(members_) * rng.uniform(0.35, 0.8)))
            album_members[title] = members_
            album("Album", 2, title, len(members_), clock.at(days_ago, 21), ZPARENTFOLDER=parent)
        for kind in list(range(1600, 1629)) + [1630, 1631, 1632, 1634, 1636, 1637, 1639, 1640, 1641, 1642]:
            album("FetchingAlbum", kind, None, 0, None)
        album("FetchingAlbum", 1552, None, 0, None)
        import_days = sorted(rng.sample(range(5, SPAN_DAYS), 46), reverse=True)
        for d in import_days:
            album("ImportSession", 1506, None, rng.randint(1, 140), clock.at(d, rng.randrange(8, 23)), ZIMPORTEDBYBUNDLEIDENTIFIER=rng.choice(["com.apple.camera", "com.apple.Photos", None]))
        for _ in range(9):
            album("DuplicateAlbum", 1510, None, rng.randint(2, 4), clock.at(rng.randrange(20, 900), 3))
        album("CloudSharedAlbum", 1505, "Family", 86, clock.at(1420, 18))
        album("CloudSharedAlbum", 1505, "Flat hunting", 31, clock.at(OLD_HOME_UNTIL + 40, 18))
        _dict_rows(con, "ZGENERICALBUM", albums)

        # ---- the search lexicon ----------------------------------------------------------------
        lexicon = Lexicon(rng)

        def term(category: int, content: str, identifier: str = "") -> int:
            return lexicon.term(category, content, identifier, _SYNONYMS.get((category, content), ()))

        # Fixed vocabulary first, as the real lexicon starts with the generic terms.
        for name in ("Photo", "Live Photo", "Video", "Screenshot"):
            term({"Photo": 5000, "Live Photo": 5060, "Video": 5010, "Screenshot": 5070}[name], name)
        for month in _MONTHS:
            term(1010, month)
        for i, day_name in enumerate(_WEEKDAYS):
            term(1070, day_name, str(i + 1))
        for i, season in enumerate(("Summer", "Autumn", "Winter", "Spring")):
            term(1040, season, f"season/{i + 1}")

        tokens_of: dict[str, list[str]] = {}
        item_rows: list[tuple] = []
        asset_terms: dict[int, list[int]] = {}
        memory_titles: dict[int, list[int]] = {}
        revgeo_cache: dict[tuple, bytes] = {}
        additional: list[dict] = []
        extended: list[dict] = []
        media_rows: list[dict] = []
        ocr_rows: list[dict] = []
        computed: list[dict] = []
        descriptions: list[dict] = []
        scene_rows: list[tuple] = []
        face_rows: list[dict] = []
        asset_rows: list[dict] = []
        album_of: dict[int, list[str]] = {}
        for title, members_ in album_members.items():
            for a in members_:
                album_of.setdefault(a.pk, []).append(title)
        shared_album_of: dict[int, str] = {}
        for share_pk, chosen in album_assets.items():
            for a in chosen:
                shared_album_of[a.pk] = shares[share_pk - 1]["ZTITLE"]
        events = _EVENTS
        ocr_placeholder = lib.keyed_archive({"documentVersion": 3, "note": "demo placeholder for a compressed recognition document"})

        for asset in assets:
            m = asset.moment
            spot = m.spot
            local = library.local(asset.when)
            is_home = asset.located and spot.private == "home"
            created = cocoa(asset.when)
            pk = asset.pk
            day_pk = moment_highlight[m.index]
            analysed = asset.analysed
            last_viewed = min(now, asset.when + datetime.timedelta(days=rng.uniform(0, min(400, max(0.02, m.days_ago))))) if asset.views else None
            if asset.trashed:
                asset.views = min(asset.views, 1)
            asset_rows.append({
                "Z_PK": pk, "Z_ENT": _ENT["Asset"], "Z_OPT": rng.randint(4, 40), "ZAVALANCHEPICKTYPE": 0, "ZBUNDLESCOPE": 0, "ZCLOUDLOCALSTATE": 1, "ZCOMPLETE": 1,
                "ZFAVORITE": int(asset.favorite), "ZHEIGHT": asset.height, "ZHIDDEN": int(asset.hidden), "ZISDETECTEDSCREENSHOT": int(asset.subtype == 10),
                "ZKIND": asset.kind, "ZKINDSUBTYPE": asset.subtype if asset.kind == 0 else (asset.subtype or 100 if asset.duration else 0),
                "ZLIBRARYSCOPESHARESTATE": 2 if asset.shared else 0, "ZORIENTATION": 1, "ZPLAYBACKSTYLE": 4 if asset.kind == 1 else (3 if asset.subtype == 2 else 1),
                "ZSAVEDASSETTYPE": 6 if m.kind == "camera" else 4, "ZSYNDICATIONSTATE": 0, "ZTRASHEDSTATE": int(asset.trashed), "ZVISIBILITYSTATE": 0, "ZWIDTH": asset.width,
                "ZADDITIONALATTRIBUTES": pk, "ZCOMPUTEDATTRIBUTES": pk if analysed else None, "ZDAYGROUPHIGHLIGHTBEINGASSETS": trip_highlight.get(m.trip) if m.trip is not None else None,
                "ZEXTENDEDATTRIBUTES": pk, "ZHIGHLIGHTBEINGASSETS": day_pk, "ZLIBRARYSCOPE": 1 if asset.shared else None, "ZMEDIAANALYSISATTRIBUTES": pk, "ZMOMENT": m.index + 1,
                "ZADDEDDATE": cocoa(asset.when + datetime.timedelta(seconds=rng.randint(1, 30) if m.kind == "camera" else 0)), "ZCURATIONSCORE": round(rng.choice([0.25, 0.5, 0.5, 0.75, 1.0]), 2),
                "ZDATECREATED": created, "ZDURATION": round(asset.duration, 3), "ZLATITUDE": asset.lat, "ZLONGITUDE": asset.lon,
                "ZMODIFICATIONDATE": cocoa(min(now, asset.when + datetime.timedelta(hours=rng.uniform(0.2, 30)))), "ZOVERALLAESTHETICSCORE": round(rng.betavariate(4, 4), 4),
                "ZPROMOTIONSCORE": round(rng.random() * 0.6, 3), "ZTRASHEDDATE": cocoa(min(now, asset.when + datetime.timedelta(days=rng.uniform(0.1, 6)))) if asset.trashed else None,
                "ZDIRECTORY": asset.uuid[0], "ZFILENAME": f"{asset.uuid}.{asset.original_name.rsplit('.', 1)[-1].lower()}", "ZUNIFORMTYPEIDENTIFIER": asset.uti, "ZUUID": asset.uuid})
            blob = None
            if asset.located:
                key = (spot.key, is_home)
                blob = revgeo_cache.get(key)
                if blob is None:
                    blob = revgeo_cache[key] = _revgeo_archive(spot, is_home)
                if not analysed:
                    blob = None
            additional.append({
                "Z_PK": pk, "Z_ENT": _ENT["AdditionalAssetAttributes"], "Z_OPT": 6, "ZALLOWEDFORANALYSIS": 1, "ZFACEANALYSISVERSION": 15 if analysed else 0,
                "ZIMPORTEDBY": {"camera": 1, "screenshot": 8, "saved": 3}[m.kind] if asset.source or m.kind != "camera" else 0, "ZINFERREDTIMEZONEOFFSET": tz_seconds,
                "ZORIGINALFILESIZE": int(asset.width * asset.height * rng.uniform(0.12, 0.3)) if asset.kind == 0 else int(asset.duration * rng.uniform(1.2e6, 2.4e6)),
                "ZORIGINALHEIGHT": asset.height, "ZORIGINALWIDTH": asset.width, "ZPLAYCOUNT": asset.plays, "ZREVERSELOCATIONDATAISVALID": 1 if blob is not None else 0,
                "ZSCENEANALYSISVERSION": 101 if analysed else 0, "ZSHARECOUNT": asset.shares, "ZTIMEZONEOFFSET": tz_seconds, "ZVIEWCOUNT": asset.views, "ZASSET": pk,
                "ZASSETDESCRIPTION": None, "ZLASTVIEWEDDATE": cocoa(last_viewed) if last_viewed else None,
                "ZSCENEANALYSISTIMESTAMP": cocoa(min(now, asset.when + datetime.timedelta(hours=rng.uniform(1, 20)))) if analysed else None,
                "ZEXIFTIMESTAMPSTRING": local.strftime("%Y:%m:%d %H:%M:%S") if m.kind == "camera" else None, "ZIMPORTEDBYBUNDLEIDENTIFIER": asset.source[0] if asset.source else None,
                "ZIMPORTEDBYDISPLAYNAME": asset.source[1] if asset.source else None, "ZORIGINALFILENAME": asset.original_name, "ZTIMEZONENAME": persona.time_zone,
                "ZTITLE": None, "ZREVERSELOCATIONDATA": blob})
            extended.append({
                "Z_PK": pk, "Z_ENT": _ENT["ExtendedAttributes"], "Z_OPT": 1, "ZFLASHFIRED": int(asset.camera is not None and local.hour >= 20 and rng.random() < 0.2),
                "ZISO": rng.choice([32, 50, 64, 100, 200, 400, 800, 1600]) if asset.camera else None, "ZASSET": pk, "ZAPERTURE": rng.choice([1.78, 1.78, 2.2, 2.8]) if asset.camera else None,
                "ZDATECREATED": created, "ZDURATION": round(asset.duration, 3) if asset.kind == 1 else None, "ZFOCALLENGTH": rng.choice([6.86, 2.22, 15.66, 23.0]) if asset.camera else None,
                "ZLATITUDE": asset.lat if asset.located else None, "ZLONGITUDE": asset.lon if asset.located else None,
                "ZSHUTTERSPEED": round(rng.choice([1 / 30, 1 / 60, 1 / 120, 1 / 500, 1 / 2000]), 6) if asset.camera else None,
                "ZCAMERAMAKE": asset.camera[0] if asset.camera else None, "ZCAMERAMODEL": asset.camera[1] if asset.camera else None,
                "ZLENSMODEL": (asset.camera[1] + " back triple camera 6.86mm f/1.78") if asset.camera and asset.camera[0] == "Apple" else ("XF18-55mmF2.8-4 R LM OIS" if asset.camera else None),
                "ZTIMEZONENAME": persona.time_zone if m.kind == "camera" else None})
            has_text = asset.ocr is not None
            captioned = analysed and rng.random() < 0.9
            media_rows.append({
                "Z_PK": pk, "Z_ENT": _ENT["MediaAnalysisAssetAttributes"], "Z_OPT": 3, "ZCHARACTERRECOGNITIONVERSION": 9 if analysed and asset.kind == 0 else 0,
                "ZFACECOUNT": len(asset.faces), "ZIMAGECAPTIONVERSION": 77 if captioned and asset.kind == 0 else 0, "ZIMAGEEMBEDDINGVERSION": 77 if analysed and rng.random() < 0.96 else 0,
                "ZMEDIAANALYSISVERSION": 77 if analysed else 0, "ZVIDEOCAPTIONVERSION": 77 if captioned and asset.kind == 1 else 0,
                "ZVISUALSEARCHVERSION": 317 if analysed and asset.kind == 0 and rng.random() < 0.93 else 0, "ZASSET": pk,
                "ZCHARACTERRECOGNITIONATTRIBUTES": len(ocr_rows) + 1 if has_text and analysed else None, "ZACTIVITYSCORE": round(rng.random(), 3) if asset.kind == 1 else None,
                "ZBLURRINESSSCORE": round(rng.betavariate(6, 2), 3), "ZEXPOSURESCORE": round(rng.betavariate(5, 3), 3),
                "ZMEDIAANALYSISTIMESTAMP": cocoa(min(now, asset.when + datetime.timedelta(hours=rng.uniform(2, 40)))) if analysed else None, "ZWALLPAPERSCORE": round(rng.random() * 0.5, 3)})
            if not captioned:
                asset.caption = ""
            if has_text and analysed:
                ocr_rows.append({"Z_PK": len(ocr_rows) + 1, "Z_ENT": _ENT["CharacterRecognitionAttributes"], "Z_OPT": 1, "ZALGORITHMVERSION": 9, "ZMEDIAANALYSISASSETATTRIBUTES": pk,
                                 "ZADJUSTMENTVERSION": None, "ZCHARACTERRECOGNITIONDATA": ocr_placeholder, "ZMACHINEREADABLECODEDATA": None, "ZTEXTUNDERSTANDINGDATA": None})
            elif has_text:
                asset.ocr = None
            if analysed:
                computed.append({"Z_PK": pk, "Z_ENT": _ENT["ComputedAssetAttributes"], "Z_OPT": 1, "ZASSET": pk, **{column: round(rng.betavariate(3, 3), 4) for column in (
                    "ZFAILURESCORE", "ZHARMONIOUSCOLORSCORE", "ZIMMERSIVENESSSCORE", "ZINTERESTINGSUBJECTSCORE", "ZLIVELYCOLORSCORE", "ZNOISESCORE", "ZPLEASANTCOMPOSITIONSCORE",
                    "ZPLEASANTLIGHTINGSCORE", "ZSHARPLYFOCUSEDSUBJECTSCORE", "ZWELLFRAMEDSUBJECTSCORE", "ZWELLTIMEDSHOTSCORE")}})
                for scene in asset.scenes:
                    scene_rows.append((len(scene_rows) + 1, _ENT["SceneClassification"], 1, rng.choice([0, 0, 0, 2, 3, 4, 5, 8]), None, scene_ids[scene], pk, None,
                                       round(rng.uniform(0.32, 0.99), 4), None, None, None))
            if asset.description:
                descriptions.append({"Z_PK": len(descriptions) + 1, "Z_ENT": _ENT["AssetDescription"], "Z_OPT": 1, "ZASSETATTRIBUTES": pk, "ZLONGDESCRIPTION": asset.description})
                additional[-1]["ZASSETDESCRIPTION"] = len(descriptions)
            # Faces with the classifiers' verdicts.
            if analysed:
                for key in asset.faces:
                    person = by_key.get(key)
                    profile = person.profile if person is not None else {}
                    pet = key == "pet"
                    classified = not pet and rng.random() < 0.93

                    def code(column: str, top: int, default: Optional[int] = None) -> int:
                        if not classified:
                            return 0
                        base = profile.get(column, default)
                        if base is None or rng.random() < 0.12:
                            return rng.randint(1, top)
                        return base

                    smile = int(classified and rng.random() < 0.62)
                    eyes = 0 if not classified else (1 if rng.random() < 0.06 else 2)
                    stranger = person is None or not person.full_name
                    outdoors = m.context in ("beach", "alpine", "lookout", "park", "city", "tropics", "geothermal")
                    glasses = code("ZGLASSESTYPE", 3, 3)
                    if classified and outdoors and rng.random() < 0.14:
                        glasses = 2
                    face_rows.append({
                        "Z_PK": len(face_rows) + 1, "Z_ENT": _ENT["DetectedFace"], "Z_OPT": 2,
                        "ZAGETYPE": code("ZAGETYPE", 5, rng.choice([3, 5, 5, 5, 4, 2]) if stranger else None), "ZASSETVISIBLE": 1, "ZDETECTIONTYPE": 4 if pet else 1,
                        "ZETHNICITYTYPE": code("ZETHNICITYTYPE", 5), "ZEYEMAKEUPTYPE": 0, "ZEYESSTATE": eyes, "ZFACEALGORITHMVERSION": 15,
                        "ZFACEEXPRESSIONTYPE": 0 if not classified else rng.choices([1, 2, 3, 4, 5, 6], weights=[30, 38, 12, 9, 7, 4])[0], "ZFACIALHAIRTYPE": code("ZFACIALHAIRTYPE", 5, 1),
                        "ZGAZETYPE": 0 if not classified else rng.choices([1, 2, 3, 4, 5], weights=[52, 16, 14, 10, 8])[0], "ZGENDERTYPE": code("ZGENDERTYPE", 2),
                        "ZGLASSESTYPE": glasses, "ZHAIRCOLORTYPE": code("ZHAIRCOLORTYPE", 6), "ZHAIRTYPE": 0, "ZHASFACEMASK": int(classified and rng.random() < (0.09 if m.days_ago > 1700 else 0.006)),
                        "ZHASSMILE": smile, "ZHEADGEARTYPE": 0 if not classified else rng.choices([1, 2, 3, 4, 5], weights=[80, 8, 6, 4, 2] if not outdoors else [58, 18, 12, 8, 4])[0],
                        "ZHIDDEN": 0, "ZISLEFTEYECLOSED": int(eyes == 1), "ZISRIGHTEYECLOSED": int(eyes == 1), "ZLIPMAKEUPTYPE": 0, "ZMANUAL": 0,
                        "ZNAMESOURCE": 0 if stranger else rng.choices([1, 2, 5, 6], weights=[14, 6, 62, 18])[0],
                        "ZPOSETYPE": 0 if not classified else rng.choices([1, 2, 3, 4, 5], weights=[55, 16, 14, 9, 6])[0], "ZQUALITYMEASURE": rng.randint(20, 100),
                        "ZSKINTONETYPE": code("ZSKINTONETYPE", 6), "ZSMILETYPE": 0 if not classified else (rng.choice([1, 2]) if smile else 1), "ZSOURCEHEIGHT": asset.height,
                        "ZSOURCEWIDTH": asset.width, "ZASSETFORFACE": pk, "ZPERSONFORFACE": person.pk if person is not None else None, "ZBLURSCORE": round(rng.random() * 0.4, 3),
                        "ZCENTERX": round(rng.uniform(0.15, 0.85), 4), "ZCENTERY": round(rng.uniform(0.25, 0.75), 4), "ZQUALITY": round(rng.betavariate(5, 2), 4) if not pet else round(rng.uniform(0.3, 0.9), 4),
                        "ZROLL": round(rng.gauss(0, 0.15), 4), "ZSIZE": round(rng.uniform(0.04, 0.32), 4), "ZUUID": lib.uuid_string(rng)})

            # Index terms.
            ids: list[int] = [term(8110, asset.uuid, asset.uuid)]
            ids.append(term(1000, local.strftime("%Y%m%d"), local.strftime("%Y%m%d")))
            ids += [term(1010, _MONTHS[local.month - 1]), term(1020, str(local.year)), term(1040, _SEASONS[local.month]), term(1050, _part_of_day(local.hour)),
                    term(1060, "Weekend" if local.weekday() >= 5 else "Weekday"), term(1070, _WEEKDAYS[local.weekday()])]
            if m.holiday:
                ids.append(term(1030, m.holiday))
            if asset.located and analysed:
                if spot.private == "home":
                    ids.append(term(2010, "Home"))
                if spot.private == "work":
                    ids.append(term(2020, "Work"))
                ids += [term(2050, spot.street_name), term(2070, spot.suburb), term(2090, spot.city), term(2140, spot.region), term(2160, spot.country),
                        term(2170, spot.cc), term(2190, _CONTINENT[spot.cc][0]), term(2180, _CONTINENT[spot.cc][1])]
                if spot.name:
                    ids.append(term(2060 if not spot.landmark else 2080, spot.name))
                if spot.water:
                    ids.append(term(2210, spot.water))
                if spot.business and (m.meaning or rng.random() < 0.6):
                    ids.append(term(2220, spot.business[0]))
                    ids += [term(2230, c) for c in spot.business[1][:2]]
                if spot.poi:
                    ids.append(term(2030, spot.poi[0]))
                if spot.landmark and rng.random() < 0.45:
                    ids.append(term(4020, spot.landmark, f"landmark/{1000000 + scene_ids.get('Building', 7) * 311 + len(spot.landmark)}"))
            if m.event is not None:
                ids += [term(2240, events[m.event][0]), term(2250, events[m.event][1]), term(2260, "Music Concerts")]
            if analysed:
                for key in asset.faces:
                    person = by_key.get(key)
                    if person is not None and person.full_name:
                        ids.append(term(3010 if key == "pet" else 3000, person.full_name, person.uuid))
                ids += [term(4000, scene, f"scene/{scene_ids[scene]}") for scene in asset.scenes]
                if asset.vlu:
                    ids.append(term(4010, asset.vlu, f"visuallookup/{2000000 + sum(map(ord, asset.vlu)) * 13}"))
                if m.meaning:
                    ids.append(term(4090, _MEANING_NAMES.get(m.meaning, m.meaning), f"meaning/{sorted(_MEANING_NAMES).index(m.meaning) + 20 if m.meaning in _MEANING_NAMES else len(m.meaning)}"))
                if asset.faces and m.context in _HUMAN_ACTIONS and rng.random() < 0.3:
                    ids.append(term(4060, _HUMAN_ACTIONS[m.context], f"humanaction/{10 + len(_HUMAN_ACTIONS[m.context])}"))
                if asset.kind == 1:
                    ids += [term(4050, sound, f"audio/{len(sound)}") for sound in _AUDIO.get(m.context, []) if rng.random() < 0.7]
                if asset.ocr:
                    doc_class, utility, text = asset.ocr
                    ids.append(term(4110, "Text"))
                    ids.append(term(4080, utility, f"utility/{len(utility)}"))
                    if doc_class:
                        ids.append(term(4130, doc_class, f"document/{len(doc_class)}"))
                    words = tokens_of.get(text)
                    if words is None:
                        words = tokens_of[text] = text.split()
                    ids += [term(4120, word) for word in words]
            if m.trip is not None:
                ids.append(term(4100, "Trip"))
            ids.append(term(5000 if asset.kind == 0 else 5010, "Photo" if asset.kind == 0 else "Video"))
            special = {2: (5060, "Live Photo"), 10: (5070, "Screenshot"), 1: (5080, "Panorama"), 101: (5050, "Slo-mo"), 102: (5090, "Time-lapse"), 103: (5100, "Screen Recording")}.get(asset.subtype)
            if special:
                ids.append(term(*special))
            if asset.selfie:
                ids.append(term(5150, "Selfie"))
            if asset.camera:
                ids.append(term(6000, asset.camera[1]))
                if extended[-1]["ZFLASHFIRED"]:
                    ids.append(term(6060, "Flash"))
            for title in album_of.get(pk, ()):
                ids.append(term(7010, title, by_album_uuid(albums, title)))
            if pk in shared_album_of:
                ids.append(term(7030, shared_album_of[pk]))
            if m.trip is not None:
                ids.append(term(7020, library.trips[m.trip].name))
            if asset.favorite:
                ids.append(term(8000, "Favourite"))
            ids.append(term(8040 if asset.shared else 8030, "Shared Library" if asset.shared else "Personal Library"))
            if asset.shared:
                ids.append(term(3020, partner.full_name if asset.contributor == "partner" else owner.full_name, "contributor/" + participants[1 if asset.contributor == "partner" else 0]["ZUUID"]))
            ids.append(term(8050, asset.original_name))
            ids.append(term(8051, asset.original_name.rsplit(".", 1)[-1].upper(), asset.uti))
            if asset.source:
                ids.append(term(8060, asset.source[1], asset.source[0]))
            if asset.description:
                ids.append(term(8080, asset.description))
            unique = sorted(set(ids))
            asset_terms[pk] = unique
            item_rows.append((pk, _ENT["LeoItem"], 1, 1, created, asset.uuid, struct.pack(f"<{len(unique)}I", *unique)))

        _dict_rows(con, "ZASSET", asset_rows)
        _dict_rows(con, "ZADDITIONALASSETATTRIBUTES", additional)
        _dict_rows(con, "ZEXTENDEDATTRIBUTES", extended)
        _dict_rows(con, "ZMEDIAANALYSISASSETATTRIBUTES", media_rows)
        _dict_rows(con, "ZCHARACTERRECOGNITIONATTRIBUTES", ocr_rows)
        _dict_rows(con, "ZCOMPUTEDASSETATTRIBUTES", computed)
        _dict_rows(con, "ZASSETDESCRIPTION", descriptions)
        con.executemany("INSERT INTO ZSCENECLASSIFICATION VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", scene_rows)
        _dict_rows(con, "ZDETECTEDFACE", face_rows)

        # ---- memories ------------------------------------------------------------------------
        memories = _memories(library, people, by_key, trip_highlight, highlights)
        _dict_rows(con, "ZMEMORY", memories)
        out["memories"] = memories

        # Collections (memories, albums, trips) are index items of their own, with their title terms.
        next_item = len(item_rows) + 1
        for memory in memories:
            if memory["ZTITLE"] and memory["ZPENDINGSTATE"] == 0:
                ids = sorted({term(7020, memory["ZTITLE"])})
                item_rows.append((next_item, _ENT["LeoItem"], 1, 3, memory["ZCREATIONDATE"], memory["ZUUID"], struct.pack(f"<{len(ids)}I", *ids)))
                next_item += 1
        for row in albums:
            if row["ZTITLE"] and row["Z_ENT"] == _ENT["Album"]:
                ids = sorted({term(7010, row["ZTITLE"], row["ZUUID"])})
                item_rows.append((next_item, _ENT["LeoItem"], 1, 2, row["ZCREATIONDATE"], row["ZUUID"], struct.pack(f"<{len(ids)}I", *ids)))
                next_item += 1
        con.executemany("INSERT INTO ZLEOITEM VALUES (?,?,?,?,?,?,?)", item_rows)
        con.executemany("INSERT INTO ZLEOLEXEME VALUES (?,?,?,?,?,?,?,?,?)",
                        [(i + 1, _ENT["LeoLexeme"], 1, category, lexeme, kind, round(rng.random(), 4) if category in (4000, 4010, 4090) else 0.0, content, identifier or None)
                         for i, (category, lexeme, kind, content, identifier) in enumerate(lexicon.rows)])
        out["lexicon"] = lexicon
        out["asset_terms"] = asset_terms

        # ---- suggestions ---------------------------------------------------------------------
        suggestions: list[dict] = []
        camera_moments = [m for m in moments if m.kind == "camera" and len(m.assets) >= 3]
        for created in clock.spread(rng, 170, 420, recent_bias=1.6):
            kind = rng.choices([(3, 303), (3, 304), (4, 401), (5, 501), (5, 502), (8, 801), (8, 802), (10, 916)], weights=[20, 8, 14, 22, 10, 12, 8, 6])[0]
            older = [m for m in camera_moments if m.start < created]
            source = rng.choice(older[-400:]) if older else camera_moments[0]
            count = 1 if kind[0] in (3, 8, 10) else rng.randint(3, min(18, max(3, len(source.assets))))
            titled = kind[0] in (4, 5)
            suggestions.append({
                "Z_PK": 0, "Z_ENT": _ENT["Suggestion"], "Z_OPT": 2, "ZCACHEDCOUNT": count, "ZCACHEDPHOTOSCOUNT": count, "ZCACHEDVIDEOSCOUNT": 0,
                "ZFEATUREDSTATE": int(created > now - datetime.timedelta(days=9) and rng.random() < 0.7), "ZNOTIFICATIONSTATE": 0, "ZSTATE": 0, "ZSUBTYPE": kind[1], "ZTYPE": kind[0],
                "ZVERSION": 3, "ZACTIVATIONDATE": cocoa(created), "ZCREATIONDATE": cocoa(created), "ZENDDATE": cocoa(source.end),
                "ZRELEVANTUNTILDATE": cocoa(created + datetime.timedelta(days=rng.choice([1, 7, 30]))), "ZSTARTDATE": cocoa(source.start),
                "ZSUBTITLE": date_text(source.start) if titled else None, "ZTITLE": (source.spot.name or source.spot.suburb) if titled else None, "ZUUID": lib.uuid_string(rng)})
        suggestions.sort(key=lambda r: r["ZCREATIONDATE"])
        for i, row in enumerate(suggestions):
            row["Z_PK"] = i + 1
        _dict_rows(con, "ZSUGGESTION", suggestions)

        # ---- the embedded caption graph ----------------------------------------------------------
        label_codes = [1401, 1004, 1200, 1101, 1103, 1400, 1102, 1300, 1201, 1003, 1100, 2000, 1001, 1000]
        con.executemany("INSERT INTO ZGRAPHLABEL VALUES (?,?,?,?,?,?,?)", [(i + 1, _ENT["GraphLabel"], 1, c, None, None, None) for i, c in enumerate(label_codes)])
        caption_label = label_codes.index(1300) + 1
        nodes: list[tuple] = []
        values: list[tuple] = []
        edges: list[tuple] = []
        for asset in assets:
            if not asset.caption or asset.moment.days_ago > 900 or rng.random() < 0.08:
                continue
            for caption_type in (1, 2):
                node = len(nodes) + 1
                text = asset.caption if caption_type == 1 else _detailed_caption(asset, library)
                nodes.append((node, _ENT["GraphNode"], 1, 0, node, 1300, None, None, None, caption_label, lib.uuid_string(rng)))
                for name_code, integer, string in ((1000, caption_type, None), (1001, None, text), (1002, 77, None)):
                    values.append((len(values) + 1, _ENT["GraphNodeValue"], 1, None, integer, name_code, node, None, None, None, string))
                edges.append((len(edges) + 1, _ENT["GraphEdge"], 1, len(edges) + 1, caption_label, asset.pk, None, None, None, None, None, node, None))
        for label_code, count in ((1100, 180), (2000, 260), (1000, 40)):
            for _ in range(count):
                node = len(nodes) + 1
                nodes.append((node, _ENT["GraphNode"], 1, 0, node, label_code, None, None, None, label_codes.index(label_code) + 1, lib.uuid_string(rng)))
        con.executemany("INSERT INTO ZGRAPHNODE VALUES (?,?,?,?,?,?,?,?,?,?,?)", nodes)
        con.executemany("INSERT INTO ZGRAPHNODEVALUE VALUES (?,?,?,?,?,?,?,?,?,?,?)", values)
        con.executemany("INSERT INTO ZGRAPHEDGE VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", edges)

        # ---- Core Data bookkeeping -----------------------------------------------------------------
        maxima = {"Asset": len(assets), "AdditionalAssetAttributes": len(assets), "ExtendedAttributes": len(assets), "MediaAnalysisAssetAttributes": len(assets),
                  "Person": len(people), "DetectedFace": len(face_rows), "Moment": len(moments), "PhotosHighlight": len(highlights), "Memory": len(memories),
                  "Suggestion": len(suggestions), "Share": len(shares), "ShareParticipant": len(participants), "GenericAlbum": len(albums), "LeoItem": len(item_rows),
                  "LeoLexeme": len(lexicon.rows), "SceneClassification": len(scene_rows), "GraphNode": len(nodes), "GraphNodeValue": len(values), "GraphEdge": len(edges),
                  "ComputedAssetAttributes": len(assets), "AssetDescription": len(descriptions), "CharacterRecognitionAttributes": len(ocr_rows), "CloudSharedComment": len(comments)}
        lib.coredata_tables(con, {name: number for number, name, _ in _ENTITIES}, rng, maxima)
        con.executemany("UPDATE Z_PRIMARYKEY SET Z_SUPER = ? WHERE Z_ENT = ?", [(parent, number) for number, _, parent in _ENTITIES if parent])
    out["highlights"] = highlights
    out["participants"] = participants
    return out


def by_album_uuid(albums: list[dict], title: str) -> str:
    for row in albums:
        if row["ZTITLE"] == title and row["Z_ENT"] == _ENT["Album"]:
            return row["ZUUID"]
    return ""


def _detailed_caption(asset: Asset, library: Library) -> str:
    m = asset.moment
    local = library.local(asset.when)
    light = {"Morning": "in soft morning light", "Afternoon": "in bright daylight", "Evening": "in warm evening light", "Night": "at night under artificial light"}[_part_of_day(local.hour)]
    tail = []
    if asset.faces:
        n = len(asset.faces)
        tail.append("one person is visible" if n == 1 else f"{n} people are visible")
    if asset.ocr:
        tail.append("there is readable text in the image")
    setting = {"home": "indoors in a living space", "work": "in an office", "cafe": "inside a cafe", "dinner": "in a restaurant", "gym": "in a climbing gym",
               "market": "at an outdoor market", "park": "outdoors among trees", "lookout": "on a hilltop above a city", "beach": "by the sea", "museum": "inside a museum",
               "transit": "at a transport stop", "airport": "in an airport", "family": "at a family gathering", "city": "in a city centre", "alpine": "in the mountains",
               "geothermal": "in a geothermal park", "tropics": "on a tropical island", "concert": "at a concert", "clinic": "indoors", "screenshot": "on a phone screen",
               "saved": "in a saved image"}[m.context]
    return f"{asset.caption}, {setting} {light}" + ("; " + " and ".join(tail) if tail else "") + "."


# Memory type -> ZCATEGORY code (the store keeps integer classes; the type name comes from the graph identifier).
_MEMORY_CATEGORY = {
    "Trip": 3, "RecurrentTrip": 3, "SingleMoment": 1, "Person": 4, "EarlyMomentsWithPerson": 4, "SocialGroup": 6, "Pet": 16, "Season": 8, "YearInReview": 7,
    "Foodie": 12, "Trends": 13, "MeaningfulEvent": 9, "MeaningfulEventAggregation": 10, "CityLocation": 14, "AreaLocation": 14, "RegionLocation": 17,
    "DayInHistoryAggregation": 18, "LastMonthAtHome": 19, "RecentHighlights": 21,
}


def _memories(library: Library, people: list[PersonRow], by_key: dict[str, PersonRow], trip_highlight: dict[int, int], highlights: list[dict]) -> list[dict]:
    rng, persona, clock, now = library.rng, library.persona, library.clock, library.now
    cocoa = lib.cocoa
    out: list[dict] = []
    current_year = library.local(now).year

    def person_id(key: str) -> str:
        return by_key[key].uuid + LOCAL_ID_PERSON

    def moment_id(m: Moment) -> str:
        return m.uuid + LOCAL_ID_MOMENT

    def add(kind: str, identifier: str, title: str, subtitle: str, start: datetime.datetime, end: datetime.datetime, created_days: float, score: Optional[float] = None) -> None:
        if created_days < 1.5:
            created_days = rng.uniform(0.3, 14)
        created = clock.ago(days=created_days, hours=rng.uniform(0, 12))
        created = min(created, now - datetime.timedelta(minutes=rng.randint(30, 900)))
        if end > created - datetime.timedelta(hours=20):
            end = created - datetime.timedelta(hours=rng.uniform(20, 70))
        start = min(start, end - datetime.timedelta(hours=2))
        age = (now - created).total_seconds() / 86_400
        pending = 0 if age > 6 else rng.choice([0, 1, 1, 2])
        viewed = pending == 0 and rng.random() < 0.62
        views = rng.choice([1, 1, 2, 3, 5]) if viewed else 0
        plays = rng.choice([0, 1, 1, 2]) if viewed else 0
        out.append({
            "Z_PK": 0, "Z_ENT": _ENT["Memory"], "Z_OPT": rng.randint(2, 9), "ZCATEGORY": _MEMORY_CATEGORY.get(kind, 0), "ZCREATIONTYPE": 0,
            "ZFAVORITE": int(viewed and rng.random() < 0.12), "ZFEATUREDSTATE": int(age < 5 and pending == 0), "ZNOTIFICATIONSTATE": rng.choice([0, 0, 1, 2]),
            "ZPENDINGSTATE": pending, "ZPHOTOSGRAPHVERSION": 1281, "ZPLAYCOUNT": plays, "ZREJECTED": int(viewed and rng.random() < 0.05),
            "ZSHARECOUNT": int(plays > 0 and rng.random() < 0.15), "ZSUBCATEGORY": rng.choice([0, 0, 0, 1000, 1001]), "ZVIEWCOUNT": views, "ZKEYASSET": None,
            "ZCREATIONDATE": cocoa(created), "ZENDDATE": cocoa(end), "ZLASTMOVIEPLAYEDDATE": cocoa(min(now, created + datetime.timedelta(days=rng.uniform(0, 20)))) if plays else None,
            "ZLASTVIEWEDDATE": cocoa(min(now, created + datetime.timedelta(days=rng.uniform(0, 30)))) if views else None,
            "ZSCORE": round(score if score is not None else rng.uniform(0.25, 0.92), 4), "ZSTARTDATE": cocoa(start), "ZGRAPHMEMORYIDENTIFIER": identifier,
            "ZSUBTITLE": subtitle, "ZTITLE": title, "ZUUID": lib.uuid_string(rng), "ZPHOTOSGRAPHDATA": None})

    moments = library.moments
    first, last = moments[0].start, moments[-1].end
    camera = [m for m in moments if m.kind == "camera"]

    def month_year(when: datetime.datetime) -> str:
        local = library.local(when)
        return f"{_MONTHS[local.month - 1]} {local.year}"

    # Trips.
    for trip in library.trips:
        if not trip.moments:
            continue
        uuid = trip.uuid + LOCAL_ID_HIGHLIGHT
        add("Trip", f"Trip|PGGraphHighlightTypeNode|{'LongTrip' if trip.long else 'ShortTrip'}|PGGraphHighlightGroupNode|{uuid}|PGGraphAreaNode|{trip.name}",
            trip.name, month_year(trip.moments[0].start), trip.moments[0].start, trip.moments[-1].end, trip.start_day - trip.days - rng.uniform(2, 20), rng.uniform(0.7, 0.97))
    for name in ("Queenstown", "Sydney", "Rotorua", "Auckland"):
        group = [t for t in library.trips if t.name == name and t.moments]
        if len(group) >= 2:
            city = library.spots[group[0].spots[0]]
            ids = "".join(f"|PGGraphHighlightGroupNode|{t.uuid}{LOCAL_ID_HIGHLIGHT}" for t in group)
            add("RecurrentTrip", f"RecurrentTrip|PGGraphLocationCityNode|{city.city}{city.region}{city.cc}|{city.lat:.6f}|{city.lon:.6f}{ids}", f"{name} Over the Years",
                f"{library.local(group[-1].moments[0].start).year} – {library.local(group[0].moments[0].start).year}", group[-1].moments[0].start, group[0].moments[-1].end,
                group[0].start_day - 30 - rng.uniform(0, 30), rng.uniform(0.6, 0.9))
    # People.
    counts = {key: sum(1 for m in camera if key in m.people) for key in ("alex", "jamie", "helen", "david", "priya", "tom", "mei")}
    for key, n in counts.items():
        if n < 12 or key not in by_key:
            continue
        person = persona.person(key)
        mine = [m for m in camera if key in m.people]
        for year in sorted({library.local(m.start).year for m in mine})[-3:]:
            in_year = [m for m in mine if library.local(m.start).year == year]
            if len(in_year) < 4:
                continue
            created = max(5.0, (now - in_year[-1].end).days - rng.uniform(10, 90))
            add("Person", f"Person|PGGraphPersonNode|{person_id(key)}|PGGraphCalendarUnitNode|Year|{year}", person.given, str(year), in_year[0].start, in_year[-1].end, created)
        add("EarlyMomentsWithPerson", f"EarlyMomentsWithPerson|PGGraphPersonNode|{person_id(key)}", f"Early Moments with {person.given}", "Over the Years", mine[0].start,
            mine[min(len(mine) - 1, 12)].end, rng.uniform(100, 700))
    for year in (current_year - 1, current_year):
        add("Person", f"Person|PGGraphMeNode|{person_id(persona.owner.key)}|PGGraphCalendarUnitNode|Year|{year}", "Portraits", str(year),
            clock.ago(days=min(SPAN_DAYS, 365 * (current_year - year + 1))), clock.ago(days=365 * (current_year - year) + 3), rng.uniform(15, 300) + 300 * (current_year - year))
    groups = [(["alex", "jamie", "helen", "david"], "Family"), (["priya", "tom", "mei", "sam"], "Friends"), (["alex", "priya", "tom"], "Together")]
    for i, (members, title) in enumerate(groups):
        members = [k for k in members if k in by_key]
        ids = "".join(f"|PGGraphPersonNode|{person_id(k)}" for k in members)
        add("SocialGroup", f"SocialGroup|PGGraphSocialGroupNode|-{rng.randrange(10 ** 18, 9 * 10 ** 18)}{ids}|PGGraphOverTheYearsNode|OverTheYears", title, "Over the Years",
            first, last, rng.uniform(40, 500))
    pet_moments = [m for m in moments if m.pet]
    if pet_moments and "pet" in by_key:
        for year in sorted({library.local(m.start).year for m in pet_moments})[-3:]:
            in_year = [m for m in pet_moments if library.local(m.start).year == year]
            add("Pet", f"Pet|PGGraphPetNode|{person_id('pet')}|PGGraphCalendarUnitNode|Year|{year}", PET_NAME, str(year), in_year[0].start, in_year[-1].end,
                max(8.0, (now - in_year[-1].end).days - rng.uniform(5, 60)))
    # Time.
    for year in range(current_year - 3, current_year):
        add("YearInReview", f"YearInReview|PGGraphCalendarUnitNode|Year|{year}", f"{year}: The Year in Review", "Best of the Year",
            clock.ago(days=365 * (current_year - year) + 300), clock.ago(days=365 * (current_year - year - 1) + 300), 365 * (current_year - year - 1) + rng.uniform(250, 300), rng.uniform(0.7, 0.95))
    seasons_seen: dict[tuple, list[Moment]] = {}
    for m in camera:
        local = library.local(m.start)
        season = _SEASONS[local.month]
        seasons_seen.setdefault((local.year if not (season == "Summer" and local.month == 12) else local.year + 1, season), []).append(m)
    for (year, season), group in sorted(seasons_seen.items())[-9:-1]:
        if len(group) < 8:
            continue
        add("Season", f"Season|PGGraphSeasonNode|{season}|PGGraphCalendarUnitNode|Year|{year}", f"{season} {year}", month_year(group[0].start), group[0].start, group[-1].end,
            max(4.0, (now - group[-1].end).days - rng.uniform(3, 40)))
    for month_day, title in ((1225, "Christmas Day"), (101, "New Year's Day"), (206, "Waitangi Day")):
        add("DayInHistoryAggregation", f"DayInHistoryAggregation|PGGraphOverTheYearsNode|OverTheYears|PGGraphCalendarUnitNode|MonthDay|{month_day}", "On This Day", title,
            first, last, rng.uniform(20, 330))
    # Content and meaning.
    for year in (current_year - 1, current_year):
        add("Foodie", f"Foodie|PGGraphSceneFeatureNode|Food|PGGraphCalendarUnitNode|Year|{year}", "Delicious Moments", str(year),
            clock.ago(days=365 * (current_year - year + 1)), clock.ago(days=365 * (current_year - year) + 20), rng.uniform(20, 200) + 200 * (current_year - year))
    for feature, title in (("SunriseSunset", "Golden Hour"), ("Pet", "Furry Friends"), ("Cityscape", "City Views"), ("Forest", "Into the Bush"), ("Coffee", "Coffee Breaks")):
        add("Trends", f"Trends|PGGraphSceneFeatureNode|{feature}|PGGraphOverTheYearsNode|OverTheYears", title, "Over the Years", first, last, rng.uniform(12, 600))
    for meaning, title in (("Hiking", "Hiking Adventures"), ("Birthday", "Birthdays"), ("Concert", "Live Music"), ("Beaching", "Beach Days"), ("Gathering", "Getting Together")):
        add("MeaningfulEventAggregation", f"MeaningfulEventAggregation|PGGraphOverTheYearsNode|OverTheYears|PGGraphMeaningNode|{meaning}", title, "Over the Years", first, last,
            rng.uniform(15, 500))
    special = [m for m in camera if m.meaning in ("Birthday", "Wedding", "Concert", "HolidayEvent") and len(m.assets) >= 6]
    for m in special[-16:]:
        local = library.local(m.start)
        who = persona.person(m.birthday_of).given if m.birthday_of else ""
        title = {"Birthday": f"{who}’s Birthday" if who else "Birthday", "Wedding": "Wedding Day", "Concert": _EVENTS[m.event][1] if m.event is not None else "Concert",
                 "HolidayEvent": m.holiday or "Holiday"}[m.meaning]
        add("MeaningfulEvent", f"MeaningfulEvent|PGGraphMomentNode|{moment_id(m)}|PGGraphMeaningNode|{m.meaning}|PGGraphCalendarUnitNode|MonthDay|{local.month * 100 + local.day}",
            title, f"{local.day} {_MONTHS[local.month - 1]} {local.year}", m.start, m.end, max(2.0, m.days_ago - rng.uniform(1, 25)), rng.uniform(0.6, 0.95))
    big = [m for m in camera if len(m.assets) >= 9 and m.trip is None and not m.meaning]
    for m in rng.sample(big, min(len(big), 14)):
        local = library.local(m.start)
        add("SingleMoment", f"SingleMoment|PGGraphMomentNode|{moment_id(m)}|PGGraphCalendarUnitNode|MonthDay|{local.month * 100 + local.day}", m.spot.name or m.spot.suburb,
            f"{local.day} {_MONTHS[local.month - 1]} {local.year}", m.start, m.end, max(2.0, m.days_ago - rng.uniform(1, 40)))
    # Places.
    add("CityLocation", "CityLocation|PGGraphOverTheYearsNode|OverTheYears|PGGraphLocationCityNode|WellingtonWellingtonNZ|Wellington", "Wellington", "Over the Years", first, last, 260)
    add("CityLocation", "CityLocation|PGGraphOverTheYearsNode|OverTheYears|PGGraphLocationCityNode|ParaparaumuWellingtonNZ|Paraparaumu", "Paraparaumu", "Over the Years", first, last, 520)
    for key in ("botanic", "zealandia", "oriental"):
        spot = library.spots[key]
        add("AreaLocation", f"AreaLocation|PGGraphOverTheYearsNode|OverTheYears|PGGraphAreaNode|{spot.name}", spot.name, "Over the Years", first, last, rng.uniform(30, 600))
    for roi, title in (("Beach", "At the Beach"), ("Mountain", "In the Mountains"), ("Nature", "In Nature")):
        add("RegionLocation", f"RegionLocation|PGGraphROINode|{roi}|PGGraphOverTheYearsNode|OverTheYears", title, "Over the Years", first, last, rng.uniform(25, 500))
    home = library.spots["home"]
    add("LastMonthAtHome", f"LastMonthAtHome|PGGraphHomeWorkNode|Home|{home.lat:.6f}|{home.lon:.6f}|PGGraphMeNode|{person_id(persona.owner.key)}", "At Home", month_year(clock.ago(days=40)),
        clock.ago(days=62), clock.ago(days=32), 30)
    recent = [m for m in camera if 9 < m.days_ago < 40 and len(m.assets) >= 3][-4:]
    if len(recent) >= 2:
        add("RecentHighlights", "RecentHighlights" + "".join(f"|PGGraphMomentNode|{moment_id(m)}" for m in recent), "Recent Highlights", month_year(recent[-1].start),
            recent[0].start, recent[-1].end, 8)
    # Two the persona made by hand: no graph identifier.
    for title, days in (("Miso’s first year", 1010), ("Design Systems Day", 330)):
        add("", "", title, month_year(clock.ago(days=days)), clock.ago(days=days + 20), clock.ago(days=days), days - 4)
        out[-1]["ZCREATIONTYPE"] = 1
        out[-1]["ZGRAPHMEMORYIDENTIFIER"] = None
        out[-1]["ZPENDINGSTATE"] = 0
    out.sort(key=lambda r: r["ZCREATIONDATE"])
    for i, row in enumerate(out):
        row["Z_PK"] = i + 1
    return out


# ----------------------------------------------------------------------------------------
# psi.sqlite — the legacy search index
# ----------------------------------------------------------------------------------------

_PSI_DDL = """
CREATE TABLE groups(category INT2, owning_groupid INT, content_string TEXT, normalized_string TEXT, lookup_identifier TEXT, score REAL, token_ranges_0 INT8, token_ranges_1 INT8, UNIQUE(category, owning_groupid, content_string, lookup_identifier, token_ranges_0, token_ranges_1));
CREATE TABLE assets(uuid_0 INT, uuid_1 INT, creationDate INT, UNIQUE(uuid_0, uuid_1));
CREATE TABLE ga(groupid INT, assetid INT, PRIMARY KEY(groupid, assetid));
CREATE TABLE collections(uuid_0 INT, uuid_1 INT, startDate INT, endDate INT, title TEXT, subtitle TEXT, type INT8, keyAssetUUIDPrivate TEXT, keyAssetUUIDShared TEXT, assetsCountPrivate INT32, assetsCountShared INT32, sortDate DOUBLE, UNIQUE(uuid_0, uuid_1));
CREATE TABLE gc(groupid INT, collectionid INT, PRIMARY KEY(groupid, collectionid));
CREATE INDEX ga_assetid ON ga(assetid);
"""


def _write_psi(path: pathlib.Path, library: Library, lexicon: Lexicon, asset_terms: dict[int, list[int]]) -> None:
    import uuid as uuid_module
    cutoff = library.clock.ago(days=PSI_STOPS)
    primary = {lexeme: (category, content, identifier) for category, lexeme, kind, content, identifier in lexicon.rows if kind == 1}
    synonyms: dict[int, list[str]] = {}
    for category, lexeme, kind, content, identifier in lexicon.rows:
        if kind == 2:
            synonyms.setdefault(lexeme, []).append(content)
    group_of: dict[int, int] = {}
    groups: list[tuple] = []
    with lib.sqlite_db(path, _PSI_DDL) as con:
        asset_rows = []
        links = []
        for asset in library.assets:
            if asset.when > cutoff:
                break
            value = uuid_module.UUID(asset.uuid).int
            signed = lambda x: x - (1 << 64) if x >= (1 << 63) else x   # noqa: E731
            asset_rows.append((signed(value >> 64), signed(value & ((1 << 64) - 1)), int(lib.cocoa(asset.when))))
            asset_id = len(asset_rows)
            for lexeme in asset_terms[asset.pk]:
                category, content, identifier = primary[lexeme]
                mapped = _PSI.get(category)
                if mapped is None:
                    continue
                group = group_of.get(lexeme)
                if group is None:
                    groups.append((mapped[0], 0, content, content.lower(), identifier or "", 0.0, 0, 0))
                    group = group_of[lexeme] = len(groups)
                    if mapped[1] is not None:
                        for word in synonyms.get(lexeme, ()):
                            groups.append((mapped[1], group, word, word.lower(), identifier or "", 0.0, 0, 0))
                links.append((group, asset_id))
        con.executemany("INSERT INTO groups VALUES (?,?,?,?,?,?,?,?)", groups)
        con.executemany("INSERT INTO assets VALUES (?,?,?)", asset_rows)
        con.executemany("INSERT INTO ga VALUES (?,?)", links)


# ----------------------------------------------------------------------------------------
# MediaAnalysis.sqlite
# ----------------------------------------------------------------------------------------

_MEDIA_ENTITIES = {"ApplauseResult": 5, "Asset": 6, "BabbleResult": 9, "CheeringResult": 14, "FaceResult": 18, "HumanActionResult": 22, "HumanPoseResult": 23,
                   "ImageCaptionResult": 24, "LaughterResult": 29, "MusicResult": 36, "PetsResult": 40, "SafetyResult": 44, "VideoCaptionResult": 55,
                   "VideoSegmentCaptionResult": 58, "VoiceResult": 61}

_TIMED = "Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDURATIONTIMESCALE INTEGER, ZDURATIONTIMEVALUE INTEGER, ZSTARTTIMESCALE INTEGER, ZSTARTTIMEVALUE INTEGER, ZASSET INTEGER"

_MEDIA_DDL = f"""
CREATE TABLE ZASSET ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZANALYSISTYPES INTEGER, ZFLAGS INTEGER, ZIMAGECAPTIONVERSION INTEGER, ZSAFETYVERSION INTEGER,
  ZSTATSFLAGS INTEGER, ZVERSION INTEGER, ZVIDEOCAPTIONVERSION INTEGER, ZVIDEOSEGMENTCAPTIONVERSION INTEGER, ZIMAGECAPTIONRESULT INTEGER, ZSAFETYRESULT INTEGER,
  ZVIDEOCAPTIONRESULT INTEGER, ZDATEANALYZED TIMESTAMP, ZDATEMODIFIED TIMESTAMP, ZQUALITY FLOAT, ZLOCALIDENTIFIER VARCHAR );
CREATE INDEX Z_Asset_localIdentifier ON ZASSET (ZLOCALIDENTIFIER);
CREATE TABLE ZIMAGECAPTIONRESULT ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZISUNSAFE INTEGER, ZASSET INTEGER, ZCONFIDENCE FLOAT, ZCAPTION VARCHAR );
CREATE TABLE ZVIDEOCAPTIONRESULT ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZASSET INTEGER, ZCONFIDENCE FLOAT, ZCAPTION VARCHAR );
CREATE TABLE ZVIDEOSEGMENTCAPTIONRESULT ( {_TIMED}, ZCONFIDENCE FLOAT, ZCAPTION VARCHAR );
CREATE TABLE ZSAFETYRESULT ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDURATIONTIMESCALE INTEGER, ZDURATIONTIMEVALUE INTEGER, ZSENSITIVITY INTEGER,
  ZSTARTTIMESCALE INTEGER, ZSTARTTIMEVALUE INTEGER, ZASSET INTEGER, ZSENSITIVITYSCENERESULTS BLOB );
CREATE TABLE ZVOICERESULT ( {_TIMED}, ZCONFIDENCE FLOAT );
CREATE TABLE ZMUSICRESULT ( {_TIMED}, ZCONFIDENCE FLOAT );
CREATE TABLE ZLAUGHTERRESULT ( {_TIMED}, ZCONFIDENCE FLOAT );
CREATE TABLE ZAPPLAUSERESULT ( {_TIMED}, ZCONFIDENCE FLOAT );
CREATE TABLE ZCHEERINGRESULT ( {_TIMED}, ZCONFIDENCE FLOAT );
CREATE TABLE ZBABBLERESULT ( {_TIMED}, ZCONFIDENCE FLOAT );
CREATE TABLE ZPETSRESULT ( {_TIMED}, ZPETSBOUNDHEIGHT FLOAT, ZPETSBOUNDWIDTH FLOAT, ZPETSBOUNDX FLOAT, ZPETSBOUNDY FLOAT, ZPETSCONFIDENCE FLOAT );
CREATE TABLE ZHUMANACTIONRESULT ( {_TIMED}, ZHUMANPOSESCORE FLOAT, ZMAXABSOLUTEACTIONSCORE FLOAT, ZMAXRELATIVEACTIONSCORE FLOAT, ZFACEID VARCHAR );
CREATE TABLE ZHUMANPOSERESULT ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDURATIONTIMESCALE INTEGER, ZDURATIONTIMEVALUE INTEGER, ZFLAGS INTEGER,
  ZSTARTTIMESCALE INTEGER, ZSTARTTIMEVALUE INTEGER, ZASSET INTEGER, ZCONFIDENCE FLOAT, ZHEIGHT FLOAT, ZWIDTH FLOAT, ZX FLOAT, ZY FLOAT, ZKEYPOINTS BLOB );
CREATE TABLE ZFACERESULT ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDURATIONTIMESCALE INTEGER, ZDURATIONTIMEVALUE INTEGER, ZFACEID INTEGER, ZFLAGS INTEGER,
  ZPOSITION INTEGER, ZSTARTTIMESCALE INTEGER, ZSTARTTIMEVALUE INTEGER, ZYAW INTEGER, ZASSET INTEGER, ZHEIGHT FLOAT, ZQUALITY FLOAT, ZWIDTH FLOAT, ZX FLOAT, ZY FLOAT );
"""


def _write_media(path: pathlib.Path, library: Library) -> None:
    rng, now = library.rng, library.now
    cocoa = lib.cocoa
    tables: dict[str, list[tuple]] = {name: [] for name in ("ZVOICERESULT", "ZMUSICRESULT", "ZLAUGHTERRESULT", "ZAPPLAUSERESULT", "ZCHEERINGRESULT", "ZBABBLERESULT")}
    sound_table = {"Speech": "ZVOICERESULT", "Music": "ZMUSICRESULT", "Singing": "ZMUSICRESULT", "Laughter": "ZLAUGHTERRESULT", "Applause": "ZAPPLAUSERESULT",
                   "Cheering": "ZCHEERINGRESULT", "Crowd": "ZBABBLERESULT"}
    entity = {"ZVOICERESULT": 61, "ZMUSICRESULT": 36, "ZLAUGHTERRESULT": 29, "ZAPPLAUSERESULT": 5, "ZCHEERINGRESULT": 14, "ZBABBLERESULT": 9}
    with lib.sqlite_db(path, _MEDIA_DDL) as con:
        asset_rows, image, video, segments, safety, pets, actions, poses, faces = [], [], [], [], [], [], [], [], []
        for asset in library.assets:
            if not asset.analysed:
                continue
            m = asset.moment
            pk = len(asset_rows) + 1
            analysed_at = min(now, asset.when + datetime.timedelta(hours=rng.uniform(2, 40)))
            image_pk = video_pk = safety_pk = None
            if asset.caption and asset.kind == 0:
                unsafe = int(asset.caption.startswith("A person in swimwear") and rng.random() < 0.07)
                image.append((len(image) + 1, 24, 1, unsafe, pk, round(rng.betavariate(6, 2.2), 4), asset.caption))
                image_pk = len(image)
            if asset.kind == 1:
                seconds = max(1.0, asset.duration)
                if asset.caption:
                    video.append((len(video) + 1, 55, 1, pk, round(rng.betavariate(5, 2.5), 4), asset.caption))
                    video_pk = len(video)
                    if seconds > 12:
                        options = _VIDEO_CAPTIONS.get(m.context, _VIDEO_CAPTIONS["home"]) + [c for c in _CAPTIONS[m.context]]
                        start = 0.0
                        while start < seconds - 3:
                            length = min(seconds - start, rng.uniform(4, 11))
                            segments.append((len(segments) + 1, 58, 1, 600, int(length * 600), 600, int(start * 600), pk, round(rng.betavariate(5, 3), 4), rng.choice(options)))
                            start += length
                for sound in _AUDIO.get(m.context, ["Speech"]):
                    table = sound_table.get(sound)
                    if table and rng.random() < 0.75:
                        start = rng.uniform(0, seconds * 0.5)
                        tables[table].append((len(tables[table]) + 1, entity[table], 1, 600, int(rng.uniform(1, max(1.5, seconds - start)) * 600), 600, int(start * 600), pk,
                                              round(rng.uniform(0.5, 0.99), 4)))
                if m.pet and rng.random() < 0.8:
                    pets.append((len(pets) + 1, 40, 1, 600, int(seconds * 600 * rng.uniform(0.3, 1)), 600, 0, pk, round(rng.uniform(0.2, 0.6), 3), round(rng.uniform(0.2, 0.6), 3),
                                 round(rng.uniform(0.1, 0.4), 3), round(rng.uniform(0.1, 0.4), 3), round(rng.uniform(0.6, 0.99), 3)))
                if m.people and rng.random() < 0.8:
                    for _ in range(rng.randint(1, 3)):
                        start = rng.uniform(0, seconds * 0.8)
                        actions.append((len(actions) + 1, 22, 1, 600, int(rng.uniform(1, 4) * 600), 600, int(start * 600), pk, round(rng.random(), 3), round(rng.random(), 3),
                                        round(rng.random(), 3), None))
                        poses.append((len(poses) + 1, 23, 1, 600, int(rng.uniform(1, 4) * 600), 0, 600, int(start * 600), pk, round(rng.uniform(0.4, 0.99), 3), round(rng.uniform(0.3, 0.9), 3),
                                      round(rng.uniform(0.1, 0.5), 3), round(rng.uniform(0, 0.6), 3), round(rng.uniform(0, 0.4), 3), None))
                    faces.append((len(faces) + 1, 18, 1, 600, int(seconds * 600 * rng.uniform(0.2, 0.9)), rng.randint(1, 9), 0, 0, 600, 0, rng.choice([-1, 0, 1]), pk,
                                  round(rng.uniform(0.1, 0.4), 3), round(rng.uniform(0.3, 0.95), 3), round(rng.uniform(0.1, 0.3), 3), round(rng.uniform(0.2, 0.7), 3), round(rng.uniform(0.2, 0.6), 3)))
            if rng.random() < 0.9:
                sensitive = 2 if (m.context == "beach" and asset.faces and rng.random() < 0.05) or m.taboo == "Blood" else 0
                safety.append((len(safety) + 1, 44, 1, None, None, sensitive, None, None, pk, None))
                safety_pk = len(safety)
            asset_rows.append((pk, 6, 2, 0x3FFF if asset.kind == 1 else 0x1F3, 0, 77 if image_pk else 0, 3 if safety_pk else 0, 0, 77, 77 if video_pk else 0,
                               77 if asset.kind == 1 and asset.duration > 12 else 0, image_pk, safety_pk, video_pk, cocoa(analysed_at), cocoa(asset.when), round(rng.betavariate(5, 2), 4),
                               asset.uuid + LOCAL_ID_ASSET))
        con.executemany("INSERT INTO ZASSET VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", asset_rows)
        con.executemany("INSERT INTO ZIMAGECAPTIONRESULT VALUES (?,?,?,?,?,?,?)", image)
        con.executemany("INSERT INTO ZVIDEOCAPTIONRESULT VALUES (?,?,?,?,?,?)", video)
        con.executemany("INSERT INTO ZVIDEOSEGMENTCAPTIONRESULT VALUES (?,?,?,?,?,?,?,?,?,?)", segments)
        con.executemany("INSERT INTO ZSAFETYRESULT VALUES (?,?,?,?,?,?,?,?,?,?)", safety)
        for table, rows in tables.items():
            con.executemany(f"INSERT INTO {table} VALUES (?,?,?,?,?,?,?,?,?)", rows)
        con.executemany("INSERT INTO ZPETSRESULT VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", pets)
        con.executemany("INSERT INTO ZHUMANACTIONRESULT VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", actions)
        con.executemany("INSERT INTO ZHUMANPOSERESULT VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", poses)
        con.executemany("INSERT INTO ZFACERESULT VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", faces)
        lib.coredata_tables(con, _MEDIA_ENTITIES, rng, {"Asset": len(asset_rows), "ImageCaptionResult": len(image), "VideoCaptionResult": len(video)})


# ----------------------------------------------------------------------------------------
# photosgraph.kgdb — the PhotosGraph
# ----------------------------------------------------------------------------------------

_KG_VALUE = "(elementId integer, attributeId integer, intValue integer, realValue real, stringValue text, dataType integer, primary key (elementId, attributeId))"

_KG_DDL = f"""
CREATE TABLE Label (identifier integer primary key autoincrement, name text, nodeIds blob, edgeIds blob);
CREATE TABLE GraphMetadata (metadataKey integer primary key autoincrement, value text);
CREATE TABLE Node (identifier integer primary key autoincrement, labels blob, edgesIn blob, edgesOut blob);
CREATE TABLE Edge (identifier integer primary key autoincrement, labels blob, sourceNodeId integer, targetNodeId integer);
CREATE INDEX Edge_source_idx on Edge (sourceNodeId);
CREATE INDEX Edge_target_idx on Edge (targetNodeId);
CREATE TABLE Attribute (identifier integer primary key autoincrement, name text);
CREATE TABLE NodeValue {_KG_VALUE};
CREATE INDEX NodeValue_intValue on NodeValue (attributeId, intValue) where intValue not null;
CREATE INDEX NodeValue_realValue on NodeValue (attributeId, realValue) where realValue not null;
CREATE INDEX NodeValue_stringValue on NodeValue (attributeId, stringValue) where stringValue not null;
CREATE TABLE EdgeValue {_KG_VALUE};
CREATE INDEX EdgeValue_intValue on EdgeValue (attributeId, intValue) where intValue not null;
CREATE INDEX EdgeValue_realValue on EdgeValue (attributeId, realValue) where realValue not null;
CREATE INDEX EdgeValue_stringValue on EdgeValue (attributeId, stringValue) where stringValue not null;
CREATE TABLE TransactionLog (identifier integer primary key autoincrement, nodeIdsInserted blob, edgeIdsInserted blob, nodeIdsUpdated blob, edgeIdsUpdated blob, nodeIdsDeleted blob, edgeIdsDeleted blob);
CREATE TABLE ClientLog (clientId integer primary key, transactionId integer);
CREATE TABLE TombstoneNode (identifier integer primary key autoincrement, labels blob, edgesIn blob, edgesOut blob);
CREATE TABLE TombstoneEdge (identifier integer primary key autoincrement, labels blob, sourceNodeId integer, targetNodeId integer);
CREATE TABLE TombstoneNodeValue {_KG_VALUE};
CREATE TABLE TombstoneEdgeValue {_KG_VALUE};
"""


def bitmap(bits: Iterable[int]) -> bytes:
    """The graph engine's sparse bitmap: u32 version (7), u32 chunk count, then per chunk
    u32 reserved, u32 population count, u64 first bit, 128 bytes (1024 bits, LSB first)."""
    chunks: dict[int, bytearray] = {}
    for bit in bits:
        chunk = chunks.get(bit >> 10)
        if chunk is None:
            chunk = chunks[bit >> 10] = bytearray(128)
        offset = bit & 1023
        chunk[offset >> 3] |= 1 << (offset & 7)
    out = bytearray(struct.pack("<II", 7, len(chunks)))
    for index in sorted(chunks):
        data = chunks[index]
        out += struct.pack("<IIQ", 0, sum(bin(b).count("1") for b in data), index << 10) + data
    return bytes(out)


class Graph:
    """Collects nodes, edges, labels and values; `write` turns them into the kgdb tables."""

    def __init__(self) -> None:
        self.labels: dict[str, int] = {}
        self.label_nodes: dict[int, list[int]] = {}
        self.label_edges: dict[int, list[int]] = {}
        self.node_labels: list[tuple[int, int]] = [(0, 0)]          # per node id: (domain label, kind label)
        self.edges: list[tuple[int, int, int, int]] = [(0, 0, 0, 0)]  # per edge id: (source, target, domain label, relation label)
        self.attributes: dict[str, int] = {}
        self.node_values: list[tuple] = []
        self.edge_values: list[tuple] = []
        self.unique: dict[tuple, int] = {}

    def label(self, name: str) -> int:
        found = self.labels.get(name)
        if found is None:
            found = self.labels[name] = len(self.labels) + 1
            self.label_nodes[found] = []
            self.label_edges[found] = []
        return found

    def _values(self, target: list, element: int, values: dict) -> None:
        for name, value in values.items():
            if value is None:
                continue
            attribute = self.attributes.get(name)
            if attribute is None:
                attribute = self.attributes[name] = len(self.attributes) + 1
            if isinstance(value, bool):
                target.append((element, attribute, int(value), None, None, 1))
            elif isinstance(value, int):
                target.append((element, attribute, value, None, None, 1))
            elif isinstance(value, float):
                target.append((element, attribute, None, value, None, 2))
            else:
                target.append((element, attribute, None, None, str(value), 3))

    def node(self, domain: int, kind: str, **values: Any) -> int:
        identifier = len(self.node_labels)
        d, k = self.label(f"domain_{domain}"), self.label(kind)
        self.node_labels.append((d, k))
        self.label_nodes[d].append(identifier)
        self.label_nodes[k].append(identifier)
        self._values(self.node_values, identifier, values)
        return identifier

    def one(self, domain: int, kind: str, key: Any = None, **values: Any) -> int:
        """A node that exists once per (domain, kind, key)."""
        lookup = (domain, kind, key)
        found = self.unique.get(lookup)
        if found is None:
            found = self.unique[lookup] = self.node(domain, kind, **values)
        return found

    def edge(self, relation: str, source: int, target: int, domain: int, **values: Any) -> int:
        identifier = len(self.edges)
        d, r = self.label(f"domain_{domain}"), self.label(relation)
        self.edges.append((source, target, d, r))
        self.label_edges[d].append(identifier)
        self.label_edges[r].append(identifier)
        self._values(self.edge_values, identifier, values)
        return identifier

    def write(self, path: pathlib.Path, metadata: list[str]) -> None:
        incoming: dict[int, list[int]] = {}
        outgoing: dict[int, list[int]] = {}
        for identifier, (source, target, _, _) in enumerate(self.edges):
            if identifier:
                outgoing.setdefault(source, []).append(identifier)
                incoming.setdefault(target, []).append(identifier)
        pair_cache: dict[tuple, bytes] = {}

        def pair(a: int, b: int) -> bytes:
            blob = pair_cache.get((a, b))
            if blob is None:
                blob = pair_cache[(a, b)] = bitmap((a, b))
            return blob

        empty = bitmap(())
        with lib.sqlite_db(path, _KG_DDL) as con:
            con.executemany("INSERT INTO Label VALUES (?,?,?,?)", [(identifier, name, bitmap(self.label_nodes[identifier]), bitmap(self.label_edges[identifier]))
                                                                   for name, identifier in self.labels.items()])
            con.executemany("INSERT INTO GraphMetadata (value) VALUES (?)", [(value,) for value in metadata])
            con.executemany("INSERT INTO Node VALUES (?,?,?,?)", [
                (identifier, pair(*labels), bitmap(incoming[identifier]) if identifier in incoming else empty, bitmap(outgoing[identifier]) if identifier in outgoing else empty)
                for identifier, labels in enumerate(self.node_labels) if identifier])
            con.executemany("INSERT INTO Edge VALUES (?,?,?,?)", [(identifier, pair(d, r), source, target) for identifier, (source, target, d, r) in enumerate(self.edges) if identifier])
            con.executemany("INSERT INTO Attribute VALUES (?,?)", [(identifier, name) for name, identifier in self.attributes.items()])
            con.executemany("INSERT INTO NodeValue VALUES (?,?,?,?,?,?)", self.node_values)
            con.executemany("INSERT INTO EdgeValue VALUES (?,?,?,?,?,?)", self.edge_values)
            con.execute("INSERT INTO ClientLog VALUES (1, 1)")


_MEANING_PARENT = {"Birthday": "Celebration", "Wedding": "Celebration", "HolidayEvent": "Celebration", "Concert": "Performance", "Performance": "Entertainment",
                   "Museum": "Entertainment", "NightOut": "Entertainment", "Lunch": "Restaurant", "Dinner": "Restaurant", "Hiking": "Activity", "Beaching": "Activity",
                   "SportEvent": "Activity"}
_MEANINGS = ["Activity", "Beaching", "Birthday", "Celebration", "Concert", "Dinner", "Entertainment", "Gathering", "Hiking", "HolidayEvent", "Lunch", "Museum", "NightOut",
             "Performance", "Restaurant", "SportEvent", "Wedding"]
_TABOO = [("Blood", 1), ("Funeral", 2), ("Hospital", 3), ("VehicleCrash", 4), ("War", 5)]
_FEATURES = {"cafe": "Coffee", "home": "Pet", "park": "Forest", "lookout": "SunriseSunset", "city": "Cityscape", "dinner": "Food", "market": "Food", "alpine": "Snow",
             "geothermal": "Forest", "family": "Table", "beach": "SunriseSunset", "tropics": "SunriseSunset"}


def _write_graph(path: pathlib.Path, library: Library, people: list[PersonRow], by_key: dict[str, PersonRow], photos: dict) -> None:
    rng, persona, now, clock = library.rng, library.persona, library.now, library.clock
    g = Graph()
    unix, cocoa = lib.unix, lib.cocoa
    owner = persona.owner
    scene_ids: dict[str, int] = photos["scene_ids"]
    camera_moments = [m for m in library.moments if m.kind == "camera"]

    # -- info ------------------------------------------------------------------------------
    selfies = sum(1 for a in library.assets if a.selfie)
    g.node(21, "Info", **{
        "IntelligencePlatformVersion": 6.0, "ageCategoryAlgorithmsVersion": 2, "autonamingAlgorithmsVersion": 3, "businessitemAlgorithmsVersion": 4, "canAccessContactsStore": 1,
        "canUseLocationDomain": 1, "creationDate": cocoa(clock.ago(days=41, hours=5)), "curationAlgorithmsVersion": 12, "dateOfLastIncrementalUpdateInvocation": cocoa(clock.ago(hours=7)),
        "featuredPhotoAlgorithmsVersion": 9, "frequentlocationAlgorithmsVersion": 2, "geoServiceProviderID": "7618", "holidayAlgorithmsVersion": 5,
        "languageIdentifiers": "en-NZ,mi", "localeIdentifier": persona.locale, "locationRepresentativeAssetAlgorithmsVersion": 1, "meaningAlgorithmsVersion": 14,
        "memoriesAlgorithmsVersion": 31, "memoryQualityAlgorithmsVersion": 4, "mergeCandidateConfidenceThreshold": 0.85, "numberOfBetterAssets": int(len(library.assets) * 0.31),
        "numberOfDefaultAssets": int(len(library.assets) * 0.52), "numberOfImprovedAssets": int(len(library.assets) * 0.08), "numberOfSelfies": selfies,
        "numberOfUtilityAssets": sum(1 for a in library.assets if a.moment.kind != "camera" or a.ocr), "personActivityMeaningAlgorithmsVersion": 2, "petAlgorithmsVersion": 3,
        "publiceventAlgorithmsVersion": 6, "questionsVersion": 2, "relationshipAlgorithmsVersion": 11, "routineAvailable": 1, "routineNumberOfLocationsOfInterest": 9,
        "routineNumberOfVisits": 1432, "routineNumberOfTimeMatches": 612, "routineNumberOfClosebyLocationMatches": 538, "routineNumberOfRemoteLocationMatches": 41,
        "routineNumberofMatchRequests": len(camera_moments), "routinePinningVisitsRatio": 0.43, "sharedLibraryStartAlgorithmsVersion": 1,
        "sharedLibrarySuggestionsAlgorithmsVersion": 2, "topTierAestheticScore": 0.72, "topTierAestheticScoreForTripKeyAsset": 0.64, "tripKeyAssetAlgorithmsVersion": 3,
        "wallpaperAlgorithmsVersion": 8})

    # -- people ------------------------------------------------------------------------------
    owner_row = by_key.get(owner.key)
    me = g.node(300, "Me", name=owner.full_name, id=(owner_row.uuid + LOCAL_ID_PERSON) if owner_row else None, cnid=owner.contact_id, fav=0, usercreated=0,
                sex=_PERSON_CODES[owner.key][0], agecategory=3)
    person_node: dict[str, int] = {}
    for row in people:
        if not row.full_name or row.merge_target is not None or row.key == "pet":
            continue
        p = persona.person(row.key)
        birthday = cocoa(datetime.datetime(*p.birthday, 12, tzinfo=datetime.timezone.utc)) if p.birthday else None
        person_node[row.key] = g.node(300, "People", name=p.full_name, id=row.uuid + LOCAL_ID_PERSON, cnid=p.contact_id, fav=int(row.type == 1), usercreated=0,
                                      sex=row.gender, agecategory=4 if row.age == 4 else 3, bday=birthday)
    if owner.key in person_node:
        g.edge("INFERRED_TO", me, person_node[owner.key], 300)
    unnamed = sorted(((row.faces, row) for row in people if not row.full_name and row.merge_target is None and row.faces >= 4), key=lambda t: -t[0])[:14]
    for _, row in unnamed:
        person_node[row.key] = g.node(300, "People", id=row.uuid + LOCAL_ID_PERSON, fav=0, usercreated=0, sex=row.gender, agecategory=0)

    together = {key: [m for m in camera_moments if key in m.people] for key in person_node}
    at_home = {key: sum(1 for m in ms if m.spot.private == "home") for key, ms in together.items()}

    def relation(kind: str, key: str, confidence: float, adopted: bool, **signals: Any) -> None:
        if key not in person_node or key == owner.key:
            return
        p = persona.person(key)
        base = {"relsource": 1 if p.relationship_label else 0, "relstatus": 1, "gwnummmtshome": at_home.get(key, 0), "ragediff": abs((p.birthday or (1991,))[0] - owner.birthday[0]),
                "rcal": 0.0, "rchild": 0, "rfamhol": 0.0, "rfamnam": int(p.family == owner.family), "rfrfamtrip": 0.0, "rfrndnghtout": 0.0, "rhasanniv": 0, "rlovexch": 0,
                "rold": int(len(together[key]) > 0 and together[key][0].days_ago > 1500), "rparnam": int(p.nickname in ("Mum", "Dad")), "rprtnrtrip": 0.0,
                "rtop": int(p.closeness >= 0.9), "rtop2sg": int(p.closeness >= 0.7), "rwkend": round(sum(1 for m in together[key] if library.local(m.start).weekday() >= 5) / max(1, len(together[key])), 3),
                "rwork": 0.0}
        base.update(signals)
        g.edge(kind, me, person_node[key], 300, confidence=round(confidence, 4), **base)
        if adopted:
            g.edge(kind, me, person_node[key], 306)

    relation("PARTNER", "alex", 0.94, True, rprtnrtrip=0.88, rlovexch=1, rhasanniv=1, rfrfamtrip=0.71, rfamhol=0.66, rcal=0.4)
    relation("FAMILY", "helen", 0.91, True, rfamhol=0.93, rfrfamtrip=0.42, rcal=0.2)
    relation("FAMILY", "david", 0.88, True, rfamhol=0.93, rfrfamtrip=0.42)
    relation("FAMILY", "jamie", 0.86, True, rfamhol=0.9, rfrfamtrip=0.58)
    relation("FRIEND", "jamie", 0.27, False, rfrndnghtout=0.2, rfrfamtrip=0.58)
    relation("FRIEND", "priya", 0.83, True, rfrndnghtout=0.74, rfrfamtrip=0.4)
    relation("FRIEND", "tom", 0.79, True, rfrndnghtout=0.69, rfrfamtrip=0.4)
    relation("FRIEND", "mei", 0.72, True, rfrndnghtout=0.55, rfrfamtrip=0.38)
    relation("FRIEND", "sam", 0.58, True, rfrndnghtout=0.47)
    relation("COWORKER", "aroha", 0.77, True, rwork=0.86, rcal=0.6)
    relation("COWORKER", "lucas", 0.81, True, rwork=0.9, rcal=0.5)
    relation("COWORKER", "nina", 0.69, True, rwork=0.82, rcal=0.3)
    relation("COWORKER", "oliver", 0.52, False, rwork=0.7)
    relation("COWORKER", "hana", 0.48, False, rwork=0.66)
    relation("FRIEND", "lucas", 0.24, False, rfrndnghtout=0.3, rwork=0.9)
    tags = {"helen": [("Mother", 0.92), ("Parent", 0.95), ("Family", 0.97)], "david": [("Father", 0.9), ("Parent", 0.94), ("Family", 0.96)],
            "jamie": [("Sibling", 0.84), ("Family", 0.93)], "alex": [("Partner", 0.94)], "priya": [("Friend", 0.83)], "tom": [("Friend", 0.79)], "mei": [("Friend", 0.72)],
            "sam": [("Friend", 0.58)], "aroha": [("Coworker", 0.77)], "lucas": [("Coworker", 0.81)], "nina": [("Coworker", 0.69)]}
    for key, entries in tags.items():
        if key in person_node:
            for tag, confidence in entries:
                g.edge("RELATIONSHIP_TAG", person_node[key], g.one(305, tag), 305, confidence=confidence)
    activities = {"tom": ["PersonActionClimbing"], "priya": ["PersonActionClimbing", "PersonActionHugging"], "alex": ["PersonActionHugging", "PersonActionKissing", "PersonBeachWater"],
                  "jamie": ["PersonActionHugging", "PersonActionJumpingOrLeaping"], "helen": ["PersonActionHugging"], "mei": ["PersonActionJumpingOrLeaping"]}
    for key, names in activities.items():
        if key in person_node:
            for name in names:
                g.edge("PRACTICES_ACTIVITY", person_node[key], g.one(701, name, identifier=name), 701)

    group_defs = [(["alex", "jamie", "helen", "david"], True), (["priya", "tom", "mei", "sam"], False), (["aroha", "lucas", "nina"], False), (["alex", "priya", "tom"], False),
                  (["helen", "david"], True)]
    groups: list[tuple[int, list[str]]] = []
    for members, verified in group_defs:
        members = [k for k in members if k in person_node]
        if len(members) < 2:
            continue
        node = g.node(302, "SocialGroup", id=rng.randrange(10 ** 5, 10 ** 6), importance=round(rng.uniform(0.3, 0.95), 3), isUserVerified=int(verified), persistedUUID=lib.uuid_string(rng))
        for i, key in enumerate(members):
            g.edge("BELONGSTO", person_node[key], node, 302, importance=round(max(0.15, 0.95 - 0.17 * i - rng.uniform(0, 0.1)), 3))
        groups.append((node, members))
    pet = None
    if "pet" in by_key:
        pet = g.node(304, "Pet", name=PET_NAME, anml=1, favorite=1, localIdentifier=by_key["pet"].uuid + LOCAL_ID_PERSON)
        g.edge("IS_OWNER_OF", me, pet, 304)

    # -- the address hierarchy ---------------------------------------------------------------
    def address(spot: Spot) -> int:
        found = g.unique.get((200, "Address", spot.key))
        if found is not None:
            return found
        continent, subcontinent = _CONTINENT[spot.cc]
        continent_node = g.one(200, "Continent", continent, name=continent)
        sub_node = g.one(200, "Subcontinent", subcontinent, name=subcontinent)
        country = g.unique.get((200, "Country", spot.cc))
        if country is None:
            country = g.one(200, "Country", spot.cc, name=spot.cc, id=spot.cc)
            g.edge("SUBCONTINENT", country, sub_node, 200)
            g.edge("CONTINENT", country, continent_node, 200)
            for locale in _LANGUAGES[spot.cc]:
                g.edge("POPULAR_LANGUAGE", country, g.one(205, "Language", locale, localeIdentifier=locale), 205)
        state = g.unique.get((200, "State", (spot.cc, spot.region)))
        if state is None:
            state = g.one(200, "State", (spot.cc, spot.region), name=spot.region)
            g.edge("COUNTRY", state, country, 200)
        city = g.unique.get((200, "City", (spot.region, spot.city)))
        if city is None:
            city = g.one(200, "City", (spot.region, spot.city), name=spot.city)
            g.edge("STATE", city, state, 200)
        district = g.unique.get((200, "District", (spot.city, spot.suburb)))
        if district is None:
            district = g.one(200, "District", (spot.city, spot.suburb), name=spot.suburb)
            g.edge("CITY", district, city, 200)
        street = g.unique.get((200, "Street", (spot.suburb, spot.street_name)))
        if street is None:
            street = g.one(200, "Street", (spot.suburb, spot.street_name), name=spot.street_name)
            g.edge("DISTRICT", street, district, 200)
        node = g.one(200, "Address", spot.key, lat=spot.lat, lng=spot.lon, lm=1 if spot.landmark else 0, uuid=lib.uuid_string(rng))
        g.edge("STREET", node, street, 200)
        if spot.landmark or (spot.name and not spot.business):
            g.edge("AREA", node, g.one(201, "Area", spot.landmark or spot.name, name=spot.landmark or spot.name, blocked=0, popularityScore=round(rng.uniform(0.3, 0.98), 3)), 201,
                   relevance=round(rng.uniform(0.5, 1), 3))
        return node

    spots = library.spots
    home_node = g.node(202, "Home", id=1)
    g.edge("IS_HOME_WORK", address(spots["home"]), home_node, 202)
    g.edge("IS_OWNED_BY", home_node, me, 202)
    work_node = g.node(202, "Work", id=2)
    g.edge("IS_HOME_WORK", address(spots["work"]), work_node, 202)
    g.edge("IS_OWNED_BY", work_node, me, 202)
    if "helen" in person_node:
        parents_home = g.node(202, "Home", id=3)
        g.edge("IS_HOME_WORK", address(spots["parents"]), parents_home, 202)
        g.edge("IS_OWNED_BY", parents_home, person_node["helen"], 202)
    if "alex" in person_node:
        partner_home = g.node(202, "Home", id=4)
        g.edge("IS_HOME_WORK", address(spots["home"]), partner_home, 202)
        g.edge("IS_OWNED_BY", partner_home, person_node["alex"], 202)

    # -- vocabulary nodes ----------------------------------------------------------------------
    for name in _MEANINGS:
        g.one(700, name)
    for name, parent in _MEANING_PARENT.items():
        g.edge("SUBMEANING_OF", g.one(700, name), g.one(700, parent), 700)
    for name, code in _TABOO:
        g.one(1300, name, tabooType=code)
    for name in ("Car", "Pedestrian"):
        g.one(203, name)
    for name in ("LongTrip", "ShortTrip"):
        g.one(103, name)
    over_the_years = g.one(402, "OverTheYears")
    scene_node = {name: g.node(600, name.replace(" ", "_"), localizedName=name, sceneIdentifier=identifier, level=rng.randint(1, 6), isIndexed=1,
                               localizedSynonyms=", ".join(_SYNONYMS.get((4000, name), ())) or None)
                  for name, identifier in sorted(scene_ids.items())}
    for i, name in enumerate(("Tūī", "Kākā", "Silver fern", "Pōhutukawa", "Domestic cat", "Te Papa Tongarewa", "Sky Tower", "Sydney Opera House", "Garden of the Sleeping Giant", "Lake Wakatipu")):
        g.node(603, f"Q{1000 + 9973 * (i + 3)}", localizedName=name, sceneIdentifier=2_000_000 + 37 * i, level=6, isIndexed=1)
    holiday_codes = {"Christmas Day": 1, "New Year's Day": 2, "Waitangi Day": 3, "Halloween": 4}

    # -- trips -----------------------------------------------------------------------------------
    trip_group: dict[int, int] = {}
    for trip in library.trips:
        if not trip.moments:
            continue
        node = g.node(102, "HighlightGroup", id=trip.uuid + LOCAL_ID_HIGHLIGHT, name=trip.name, sharingComposition=0, utcs=unix(trip.moments[0].start), utce=unix(trip.moments[-1].end),
                      tzs=persona.tz_offset_hours * 3600.0, tze=persona.tz_offset_hours * 3600.0)
        g.edge("HAS_TYPE", node, g.one(103, "LongTrip" if trip.long else "ShortTrip"), 103)
        g.edge("TRIP_FEATURES", node, address(spots[trip.spots[0]]), 200)
        trip_group[trip.index] = node

    # -- moments ---------------------------------------------------------------------------------
    events: dict[int, int] = {}
    business_node: dict[str, int] = {}
    frequent: dict[str, int] = {}
    visits = {}
    for m in camera_moments:
        visits[m.spot.key] = visits.get(m.spot.key, 0) + 1
    for key in ("home", "old_home", "work", "cafe", "gym", "parents", "botanic", "oriental"):
        ms = [m for m in camera_moments if m.spot.key == key]
        if len(ms) >= 8:
            frequent[key] = g.node(204, "FrequentLocation", universalStartDate=cocoa(ms[0].start), universalEndDate=cocoa(ms[-1].end))
            g.edge("AT", frequent[key], address(spots[key]), 204)
    day_nodes: dict[tuple, int] = {}
    highlight_day: dict[tuple, int] = {}
    previous = None
    moment_node: dict[int, int] = {}
    for m in camera_moments:
        spot = m.spot
        local = library.local(m.start)
        node = g.node(100, "Moment", name=m.uuid, lclid=m.uuid + LOCAL_ID_MOMENT, utcs=unix(m.start), utce=unix(m.end), tzs=persona.tz_offset_hours * 3600.0,
                      tze=persona.tz_offset_hours * 3600.0, cnt=len(m.assets), cntsc=round(rng.uniform(0.2, 1.0), 3), hasl=int(any(a.located for a in m.assets)),
                      intng=int(len(m.assets) >= 6 or bool(m.meaning)), sintng=int(len(m.assets) >= 12), sharingComposition=1 if any(a.shared for a in m.assets) else 0)
        moment_node[m.index] = node
        if previous is not None:
            g.edge("NEXT", previous, node, 101)
        previous = node
        located = [a for a in m.assets if a.located]
        if located:
            g.edge("ADDRESS", node, address(spot), 200, lat=spot.lat, lng=spot.lon, noa=len(located), relevance=round(rng.uniform(0.6, 1), 3), utcs=unix(m.start), utce=unix(m.end))
            if spot.key in frequent:
                g.edge("IN", node, frequent[spot.key], 204)
        # Dates.
        day_key = (local.year, local.month, local.day)
        date_node = day_nodes.get(day_key)
        if date_node is None:
            date_node = day_nodes[day_key] = g.node(400, "Date", name=local.strftime("%Y-%m-%d"))
            g.edge("YEAR", date_node, g.one(400, "Year", local.year, name=local.year), 400)
            g.edge("MONTH", date_node, g.one(400, "Month", local.month, name=local.month), 400)
            g.edge("DAY", date_node, g.one(400, "Day", local.day, name=local.day), 400)
            g.edge("SEASON", date_node, g.one(400, "Season", _SEASONS[local.month], name=_SEASONS[local.month]), 400)
            g.edge("DAYOFWEEK", date_node, g.one(400, "DayOfWeek", local.weekday(), name=_WEEKDAYS[local.weekday()]), 400)
            g.edge("MONTH_DAY", date_node, g.one(400, "MonthDay", (local.month, local.day), name=local.month * 100 + local.day), 400)
        g.edge("DATE", node, date_node, 400)
        g.edge("PARTOFDAY", node, g.one(400, "PartOfDay", _part_of_day(local.hour), name=_part_of_day(local.hour)), 400, ratio=round(rng.uniform(0.6, 1), 3))
        g.edge("PARTOFWEEK", node, g.one(400, "Weekend" if local.weekday() >= 5 else "Weekday"), 400)
        if m.holiday:
            holiday = g.one(401, "Holiday", m.holiday, name=m.holiday, holc=holiday_codes[m.holiday])
            g.edge("CELEBRATING", node, holiday, 401)
        # Highlights.
        day_highlight = highlight_day.get(day_key)
        if day_highlight is None:
            day_highlight = highlight_day[day_key] = g.node(102, "Highlight", id=lib.uuid_string(rng) + LOCAL_ID_HIGHLIGHT, name=spot.suburb, sharingComposition=0,
                                                            utcs=unix(m.start), utce=unix(m.end), tzs=persona.tz_offset_hours * 3600.0, tze=persona.tz_offset_hours * 3600.0)
            if m.trip is not None and m.trip in trip_group:
                g.edge("GROUP_CONTAINS", trip_group[m.trip], day_highlight, 102)
        g.edge("CONTAINS", day_highlight, node, 102)
        # People.
        present: dict[str, int] = {}
        for asset in m.assets:
            for key in asset.faces:
                present[key] = present.get(key, 0) + 1
        for key, count in present.items():
            if key == owner.key:
                g.edge("PRESENT", me, node, 300, importance=round(rng.uniform(0.3, 1), 3), numberOfAssets=count)
            elif key == "pet" and pet is not None:
                g.edge("PET_IS_PRESENT", pet, node, 304)
            elif key in person_node:
                g.edge("PRESENT", person_node[key], node, 300, importance=round(rng.uniform(0.3, 1), 3), numberOfAssets=count)
        for key in m.people:
            if key in person_node and key not in present and rng.random() < 0.5:
                g.edge("IS_AROUND", person_node[key], node, 300)
        contributors = {a.contributor for a in m.assets}
        g.edge("AUTHOR", me, node, 300)
        if "partner" in contributors and "alex" in person_node:
            g.edge("AUTHOR", person_node["alex"], node, 300)
        for group_node, members in groups:
            if sum(1 for k in members if k in present) >= max(2, len(members) - 1):
                g.edge("SOCIALGROUP", node, group_node, 302)
        if m.birthday_of and m.birthday_of in person_node:
            g.edge("BIRTHDAY", node, person_node[m.birthday_of] if m.birthday_of != owner.key else me, 301, confidence=round(rng.uniform(0.6, 0.97), 3))
        # Meaning, places of interest, businesses, events.
        if m.meaning:
            g.edge("MEANING", node, g.one(700, m.meaning), 700, confidence=round(rng.uniform(0.45, 0.98), 3), isHighPrecision=int(rng.random() < 0.55))
            parent = _MEANING_PARENT.get(m.meaning)
            if parent and rng.random() < 0.8:
                g.edge("MEANING", node, g.one(700, parent), 700, confidence=round(rng.uniform(0.4, 0.9), 3), isHighPrecision=int(rng.random() < 0.3))
        if m.taboo:
            g.edge("TABOO", node, g.one(1300, m.taboo), 1300, confidence=round(rng.uniform(0.62, 0.93), 3), numberOfTabooAssets=rng.randint(1, len(m.assets)))
        if located:
            for poi in spot.poi[:2]:
                if rng.random() < 0.85:
                    g.edge("POI", node, g.one(501, poi), 501, confidence=round(rng.uniform(0.5, 1), 3), isImproved=int(rng.random() < 0.4), isSpecial=int(bool(spot.landmark)))
            if spot.roi and rng.random() < 0.9:
                g.edge("ROI", node, g.one(502, spot.roi), 502, confidence=round(rng.uniform(0.5, 1), 3))
            if rng.random() < 0.8:
                on_foot = spot.context in ("park", "lookout", "beach", "alpine", "market", "tropics", "city") or rng.random() < 0.6
                g.edge("MOBILITY", node, g.one(203, "Pedestrian" if on_foot else "Car"), 203, confidence=round(rng.uniform(0.5, 0.99), 3))
            if spot.business and (m.meaning or rng.random() < 0.6):
                business = business_node.get(spot.key)
                if business is None:
                    name, categories, capacity = spot.business
                    business = business_node[spot.key] = g.node(503, "Business", name=name, latitude=spot.lat, longitude=spot.lon, radius=round(rng.uniform(18, 60), 1),
                                                                 muid=rng.randrange(10 ** 15, 10 ** 16), venueCapacity=capacity or None)
                    for category in categories:
                        g.edge("BUSINESSCATEGORY", business, g.one(504, category), 504)
                g.edge("BUSINESS", node, business, 503, confidence=round(rng.uniform(0.55, 0.99), 3), routine=int(visits.get(spot.key, 0) > 20),
                       universalStartDate=unix(m.start), universalEndDate=unix(m.end))
        if m.event is not None:
            name, performer, subcategory, spot_key, _ = _EVENTS[m.event]
            event = events.get(m.event)
            if event is None:
                event = events[m.event] = g.node(900, "PublicEvent", name=name, eventID=str(rng.randrange(10 ** 8, 10 ** 9)), id=str(rng.randrange(10 ** 8, 10 ** 9)),
                                                 attdc=rng.randint(600, 6000), canUseWithoutBusiness=0, supportsEventExperience=1)
                g.edge("PERFORMER", event, g.one(900, "Performer", performer, name=performer, id=str(rng.randrange(10 ** 8, 10 ** 9))), 900)
                g.edge("CATEGORY", event, g.one(901, "GEOSpatialEventLookupCategoryMusicConcerts", lcln="Music Concerts"), 901)
                g.edge("LOCALIZED_SUBCATEGORY", event, g.one(902, subcategory, lvl=0), 902)
                if spot_key in business_node:
                    g.edge("PUBLIC_EVENT_BUSINESS", event, business_node[spot_key], 900, confidence=0.9, routine=0, universalStartDate=unix(m.start), universalEndDate=unix(m.end))
            g.edge("PUBLIC_EVENT", node, event, 900)
        # Scenes: one edge per distinct label in the moment.
        tally: dict[str, int] = {}
        for asset in m.assets:
            for scene in asset.scenes:
                tally[scene] = tally.get(scene, 0) + 1
        for scene, count in tally.items():
            g.edge("SCENE", node, scene_node[scene], 600, confidence=round(rng.uniform(0.35, 0.99), 3), isReliable=int(count >= 2), numberOfAssets=count,
                   numberOfDominantSceneAssets=max(0, count - 1), numberOfHighConfidenceAssets=rng.randint(0, count), numberOfSearchConfidenceAssets=count)
        feature = _FEATURES.get(m.context)
        if feature and rng.random() < 0.35:
            g.edge("MOMENT_FEATURES", node, g.one(601, feature), 1200, rlvacnt=min(len(m.assets), rng.randint(1, 6)))
        action = {"gym": "PersonActionClimbing", "family": "PersonActionHugging", "beach": "PersonBeachWater", "alpine": "PersonActionJumpingOrLeaping"}.get(m.context)
        if action and present and rng.random() < 0.3:
            g.edge("PERSON_ACTIVITY_MEANING", node, g.one(701, action, identifier=action), 701)

    # -- memories ------------------------------------------------------------------------------------
    for memory in photos["memories"]:
        identifier = memory["ZGRAPHMEMORYIDENTIFIER"]
        if not identifier:
            continue
        kind = identifier.split("|", 1)[0]
        node = g.node(1100, kind, memid=memory["ZUUID"], subcategory=memory["ZSUBCATEGORY"], generatedWithFallbackRequirements=0)
        if "OverTheYears" in identifier:
            g.edge("MEMORY_FEATURES", node, over_the_years, 1100)
        for m in rng.sample(camera_moments, 3):
            g.edge("CONTAINS_ASSETS_FROM", node, moment_node[m.index], 1100)

    g.write(path, ["617", "1"])


# ----------------------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------------------


def generate(root: pathlib.Path, persona: Persona, rng: random.Random, now: datetime.datetime) -> None:
    """Create this module's stores below `root` (`lib.photos_library(root)`)."""
    bundle = lib.photos_library(root)
    library = Library(persona, rng, now)
    people, by_key = _people(library)
    photos = _write_photos(bundle / "database" / "Photos.sqlite", library, people, by_key)
    _write_psi(bundle / "database" / "search" / "psi.sqlite", library, photos["lexicon"], photos["asset_terms"])
    _write_media(bundle / "private" / "com.apple.mediaanalysisd" / "MediaAnalysis" / "MediaAnalysis.sqlite", library)
    _write_graph(bundle / "private" / "com.apple.photoanalysisd" / "caches" / "graph" / "PhotosGraph" / "photosgraph.kgdb", library, people, by_key, photos)
    lib.write_plist(bundle / "database" / "DataModelVersion.plist", {"LibrarySchemaVersion": 18400, "MetaSchemaVersion": 3}, binary=False)
