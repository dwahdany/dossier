"""Demo data for the Interest Profile module (`profile`).

Everything the module's seven sections read, about the invented persona only:

* `~/Library/PersonalizationPortrait`
    - `PPSQLDatabase.db` — `sources`, `tp_records` (topics), `ne_records` (named entities),
      `loc_records` (+ areas of interest, contextual entities), `cn_handles`,
      `cn_handles_sources`, `significant_contacts`;
    - `Topics/ScoreCache` (the "lazy plist" with the cached topic ranking);
    - `Contacts/me_card.pb`, `Contacts/name_records/*.pb`;
    - `streams/rankedSocialHighlights` (SEGB, "Shared with You").
* `~/Library/Suggestions` — `entities.db` (pseudo-contacts, events, wallet passes incl. the
  embedded `.pkpass`, links, e-mail metadata), `snippets.db`, the two `*-to-name.kvcache` files.
* `~/Library/DuetExpertCenter/caches/familyCircleCache` (NSKeyedArchiver, `FAFamilyCircle`).
* `~/Library/Assistant` — speech profiles, `SpeechMaintenance/ncbvqprofile`, `CustomVocabulary`;
  `~/Library/Preferences/com.apple.assistant.backedup.plist` (Siri data-sharing history).
* `~/Library/KeyboardServices/TextReplacements.db`, `~/Library/LanguageModeling/*-dynamic.lm`,
  `~/Library/Spelling/dynamic-counts.dat`.
* `~/Library/Trial/v7/Database/triald.db`.
* `~/Library/IntelligencePlatform/Artifacts/firstPartyTopics/*.db`.
* Biome streams `Siri.AnalyticsIdentifiers.*` (local + the persona's iPhone) and an empty
  `Siri.ODDI.SegmentsCohorts`.
* Stand-ins for two generic assets that ship with macOS (not personal data), under
  `<root>/System/Library/PrivateFrameworks/PersonalizationPortraitInternals.framework/…/assets_demo`:
  a small `PhotosTopicMap.plist` and `AugmentedGazetteerMetadata.db`.

Shared file: `~/Library/Biome/sync/sync.db` is created through `lib.write_biome_sync_db` only
when no earlier module wrote it (the identifiers table names the remote device with it).

Formats follow the readers in Sources/ProfileModule and the table definitions of the real
stores (DDL, enum codes and key names only). All content is invented. Where a real value
set is not known, the invented value is marked "invented" below.
"""

from __future__ import annotations

import base64
import datetime
import io
import json
import math
import os
import pathlib
import random
import struct
import zipfile
import zlib

from . import lib
from .lib import pb
from .persona import Persona, Person

UTC = datetime.timezone.utc
DAY = datetime.timedelta(days=1)

# ----------------------------------------------------------------------------------------
# Vocabulary
# ----------------------------------------------------------------------------------------

#: Wikidata ids of generic concepts, as listed in the app's compiled topic vocabulary
#: (Sources/ProfileModule/TopicVocabulary.swift) — public ids, not personal data.
T = {
    "design": "Q82604", "graphic design": "Q185925", "user interface": "Q47146", "web design": "Q190637",
    "software": "Q7397", "productivity software": "Q7247856", "mobile app": "Q620615", "startup company": "Q129238",
    "technology": "Q11016", "industrial design": "Q243606", "privacy": "Q188728", "iOS": "Q48493",
    "rock climbing": "Q1154336", "climbing": "Q22857", "physical exercise": "Q219067", "physical fitness": "Q309252",
    "yoga": "Q9350", "hiking": "Q12014035", "national park": "Q46169", "camping": "Q455550", "mountain": "Q8502",
    "weather": "Q11663", "weather forecasting": "Q182868", "adventure travel": "Q782762", "wildlife": "Q241741",
    "coffee": "Q8486", "café": "Q30022", "cooking": "Q38695", "recipe": "Q219239", "restaurant": "Q11707",
    "bakery": "Q274393", "baking": "Q720398", "food": "Q2095", "wine": "Q282", "photography": "Q11633",
    "camera": "Q15328", "lens": "Q768575", "art museum": "Q207694", "contemporary art": "Q186030",
    "architecture": "Q12271", "jazz": "Q8341", "classical music": "Q9730", "music": "Q638", "piano": "Q5994",
    "podcast": "Q20899", "music festival": "Q868557", "travel": "Q61509", "gardening": "Q124946", "pet": "Q39201",
    "airline": "Q46970", "lake": "Q23397", "skiing": "Q130949", "bird": "Q5113", "bird migration": "Q216507",
    "astronomy": "Q333", "science": "Q336", "machine learning": "Q2539", "artificial intelligence": "Q11660",
    "cycling": "Q53121", "rugby": "Q5378", "mountain biking": "Q520611", "bicycle": "Q11442", "sport": "Q349",
    "dentistry": "Q12128", "personal finance": "Q253613", "health": "Q12147", "insurance": "Q43183", "tax": "Q8161",
    "online shopping": "Q212930", "real property": "Q684740", "film": "Q11424", "literature": "Q8242",
    "science fiction": "Q24925", "film festival": "Q220505", "documentary film": "Q93204", "board game": "Q131436",
    "dog": "Q144", "surfing": "Q159992", "whale": "Q1865281",
}

#: Photos scene label → Wikidata id, the shape of the OS asset `PhotosTopicMap.plist`
#: (generic; a hand-picked handful of well-known public ids).
PHOTO_SCENES = {
    "beach": "Q40080", "seashore": "Q40080", "mountain": "Q8502", "peak": "Q8502", "lake": "Q23397",
    "cat": "Q146", "dog": "Q144", "flower": "Q506", "blossom": "Q506", "tree": "Q10884", "river": "Q4022",
    "bridge": "Q12280", "bird": "Q5113", "coffee": "Q8486", "food": "Q2095", "meal": "Q2095",
    "bicycle": "Q11442", "sky": "Q527", "snow": "Q7561", "waterfall": "Q34038",
}

#: Name gazetteer stand-in: (lower-cased name, numeric qid, category id, canonical alias).
#: Public figures / landmarks; the matcher's hits in running text are often coincidental.
GAZETTEER = [
    ("all blacks", "55801", 5, "All Blacks"), ("the all blacks", "55801", 5, "All Blacks"),
    ("eiffel tower", "243", 6, "Eiffel Tower"), ("david bowie", "5383", 2, "David Bowie"), ("bowie", "5383", 2, "David Bowie"),
    ("statue of liberty", "9202", 6, "Statue of Liberty"), ("roger federer", "1426", 4, "Roger Federer"),
    ("federer", "1426", 4, "Roger Federer"),
]

LANGUAGE_QID = {"en": "Q1860", "mi": "Q36451"}
#: Ids the local sources cannot name (shown with their "seen with" context instead).
UNNAMED = {"wellington": "Q23661", "new zealand": "Q664"}

# Group ids: invented, carrying the markers PortraitLabels.origin() looks for.
G_PHOTOS = "com.apple.proactive.PersonalizationPortrait.PhotosGraphDonation"
G_COLLECTIONS = "com.apple.Maps.Collections"
G_PINNED = "com.apple.Maps.PinnedPlaces"
G_VIEWED = "com.apple.proactive.HVSearchableUserActivity"
G_PAGE = "com.apple.proactive.PageContentDonation"
G_INTERACTION = "com.apple.proactive.HVInteraction"

MAIL, MESSAGES, SAFARI, NOTES, CALENDAR = "com.apple.mail", "com.apple.MobileSMS", "com.apple.Safari", "com.apple.Notes", "com.apple.iCal"
REMINDERS, MAPS, PHOTOS, PODCASTS, MUSIC = "com.apple.reminders", "com.apple.Maps", "com.apple.Photos", "com.apple.podcasts", "com.apple.Music"
SLACK = "com.tinyspeck.chatlyio"      # the id the app's built-in name table knows

# Entity categories (PortraitLabels.entityCategories).
PERSON, ORG, LOCATION, RESTAURANT, ACTIVITY, MEDIA, ARTIST, STREET, CITY, STATE, COUNTRY = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
FULL_ADDRESS, ATTRACTION, EVENT, TEAM, MUSICIAN = 12, 13, 14, 15, 17

#: Themes of the persona's life: (key, weight, topics, entities (name, category), people, place keys).
THEMES = [
    ("work", 17, ["design", "graphic design", "user interface", "web design", "software", "productivity software",
                  "mobile app", "startup company", "technology", "industrial design", "privacy", "iOS"],
     [("Kōwhai Labs", ORG), ("Design Review", EVENT), ("Sprint Planning", EVENT), ("Lambton Quay", LOCATION),
      ("Design Systems Meetup", EVENT), ("Research Readout", EVENT), ("Onboarding Flow", EVENT)],
     ["aroha", "lucas", "nina", "oliver", "hana"], ["work"]),
    ("climbing", 9, ["rock climbing", "climbing", "physical exercise", "physical fitness", "yoga"],
     [("Te Aro Climbing Gym", ACTIVITY), ("Taranaki Street", STREET), ("Te Aro", LOCATION)],
     ["alex", "tom", "priya"], ["gym"]),
    ("outdoors", 10, ["hiking", "national park", "camping", "mountain", "weather", "weather forecasting",
                      "adventure travel", "wildlife"],
     [("Tararua Range", LOCATION), ("Department of Conservation", ORG), ("MetService", ORG), ("Zealandia", ACTIVITY),
      ("Mount Victoria Lookout", ATTRACTION), ("Trail Notes", MEDIA), ("Wellington Botanic Garden", ACTIVITY),
      ("Red Rocks", LOCATION)],
     ["alex", "jamie", "sam", "priya"], ["zealandia", "mt_vic", "botanic"]),
    ("food", 10, ["coffee", "café", "cooking", "recipe", "restaurant", "bakery", "baking", "food", "wine"],
     [("Tūī & Fern Café", RESTAURANT), ("Harbour Light Coffee", RESTAURANT), ("Cuba Street", LOCATION),
      ("Harbourside Market", ORG), ("Queens Wharf", LOCATION)],
     ["alex", "priya", "mei"], ["cafe", "coffee", "market"]),
    ("photo", 7, ["photography", "camera", "lens", "art museum", "contemporary art", "architecture"],
     [("Te Papa Tongarewa", ATTRACTION), ("Oriental Bay", LOCATION), ("Wellington Cable Car", ATTRACTION),
      ("Wellington Waterfront", LOCATION)],
     ["mei", "jamie"], ["te_papa", "oriental", "cable_car"]),
    ("music", 6, ["jazz", "classical music", "music", "piano", "podcast", "music festival"],
     [("Marlow Quartet", ARTIST), ("Tess Aldridge", MUSICIAN), ("The Paper Kites Club", ARTIST), ("Kererū", ARTIST),
      ("Southern Strings", ARTIST), ("The Design Detail Hour", MEDIA), ("Slow News Weekly", MEDIA)],
     ["tom", "alex"], []),
    ("family", 9, ["travel", "gardening", "cooking", "pet", "board game"],
     [("Paraparaumu", CITY), ("Marine Parade", STREET), ("Jamie's Birthday", EVENT), ("Mum", PERSON), ("Dad", PERSON),
      ("Sunday Lunch", EVENT), ("Kāpiti Coast", LOCATION)],
     ["helen", "david", "jamie", "alex"], ["parents"]),
    ("travel", 7, ["travel", "airline", "adventure travel", "lake", "skiing", "surfing"],
     [("Auckland", CITY), ("Queenstown", CITY), ("Rotorua", CITY), ("Otago", STATE), ("Bay of Plenty", STATE),
      ("Kea Air", ORG), ("Sky Tower", ATTRACTION), ("Wellington Airport", LOCATION), ("New Zealand", COUNTRY),
      ("Australia", COUNTRY), ("Lakefront Lodge", ORG), ("Milford Sound", ATTRACTION)],
     ["alex", "jamie"], ["airport", "auckland", "queenstown", "rotorua"]),
    ("nature", 5, ["bird", "bird migration", "astronomy", "science", "machine learning", "artificial intelligence", "whale"],
     [("Birdsong Aotearoa", MEDIA), ("Everyday Science", MEDIA), ("Zealandia", ACTIVITY), ("Kaikōura", CITY)],
     ["nina", "sam"], ["zealandia"]),
    ("sport", 5, ["cycling", "rugby", "mountain biking", "bicycle", "sport"],
     [("All Blacks", TEAM), ("Hurricanes", TEAM), ("Pōneke Bikes", ORG), ("Makara Peak", LOCATION)],
     ["tom", "sam", "david"], []),
    ("admin", 6, ["personal finance", "online shopping", "health", "insurance", "real property", "tax", "dentistry"],
     [("Harbour Street Dental", ORG), ("Example Bank", ORG), ("Wellington City Council", ORG), ("Aro Street", STREET),
      ("Northerly Power", ORG), ("Kōtare Internet", ORG), ("Greenstone Property Management", ORG)],
     ["drlee", "landlord"], []),
    ("culture", 4, ["film", "literature", "science fiction", "film festival", "documentary film"],
     [("Kererū Books", ORG), ("Wellington Film Society", ORG), ("Book Club", EVENT)],
     ["mei", "priya", "jamie"], []),
]

#: Names that tend to appear in text with a negative tone.
GRUMBLES = {"Harbour Street Dental", "Example Bank", "Northerly Power", "Kōtare Internet", "Greenstone Property Management",
            "Wellington City Council", "MetService", "Wellington Airport", "Chris", "Morgan"}

#: Capitalised words the tagger files under "Person" although they are not people.
FALSE_PERSONS = ["Hey", "Thanks", "Cheers", "Kia Ora", "Regards", "Hi", "Ngā Mihi"]

#: Extra public places for photos taken on trips: (name, city, region, postal, lat, lon, loc category, scenes).
TRIP_PLACES = [
    ("Days Bay", "Lower Hutt", "Wellington", "5013", -41.2817, 174.9073, 3, ["beach", "sky"]),
    ("Red Rocks Coastal Walk", "Wellington", "Wellington", "6023", -41.3530, 174.7250, 3, ["seashore", "sky"]),
    ("Paraparaumu Beach", "Paraparaumu", "Wellington", "5032", -40.8935, 174.9790, 3, ["beach", "dog"]),
    ("Castlepoint Lighthouse", "Castlepoint", "Wellington", "5889", -40.9010, 176.2310, 4, ["seashore", "sky"]),
    ("Martinborough Square", "Martinborough", "Wellington", "5711", -41.2190, 175.4590, 0, ["food", "tree"]),
    ("Tongariro Alpine Crossing", "Tongariro National Park", "Manawatū-Whanganui", "3989", -39.1447, 175.5810, 4, ["mountain", "snow", "lake"]),
    ("Lake Taupō", "Taupō", "Waikato", "3330", -38.6857, 176.0702, 3, ["lake", "sky"]),
    ("Redwoods Whakarewarewa Forest", "Rotorua", "Bay of Plenty", "3010", -38.1560, 176.2730, 3, ["tree", "bicycle"]),
    ("Auckland Domain", "Auckland", "Auckland", "1010", -36.8590, 174.7755, 3, ["tree", "flower"]),
    ("Mission Bay", "Auckland", "Auckland", "1071", -36.8480, 174.8300, 3, ["beach", "food"]),
    ("Picton Ferry Terminal", "Picton", "Marlborough", "7220", -41.2860, 174.0050, 0, ["sky", "bridge"]),
    ("Nelson", "Nelson", "Nelson", "7010", -41.2706, 173.2840, 0, ["coffee", "tree"]),
    ("Kaikōura", "Kaikōura", "Canterbury", "7300", -42.4008, 173.6814, 4, ["seashore", "bird"]),
    ("Christchurch Botanic Gardens", "Christchurch", "Canterbury", "8013", -43.5306, 172.6200, 3, ["flower", "tree", "river"]),
    ("Lake Tekapo", "Lake Tekapo", "Canterbury", "7999", -44.0047, 170.4772, 4, ["lake", "sky", "mountain"]),
    ("Wānaka", "Wānaka", "Otago", "9305", -44.7032, 169.1321, 4, ["lake", "tree", "mountain"]),
    ("Arrowtown", "Arrowtown", "Otago", "9302", -44.9383, 168.8340, 0, ["tree", "river"]),
    ("Milford Sound", "Fiordland", "Southland", "9679", -44.6414, 167.8974, 4, ["waterfall", "mountain", "sky"]),
]

#: Trips: (days ago the trip started, length in days, place names) — photo dates cluster in them.
TRIPS = [
    (395, 9, ["Picton Ferry Terminal", "Nelson", "Kaikōura", "Christchurch Botanic Gardens", "Lake Tekapo", "Wānaka", "Milford Sound"]),
    (318, 3, ["Government Gardens", "Redwoods Whakarewarewa Forest", "Lake Taupō"]),
    (214, 5, ["Queenstown Gardens", "Arrowtown", "Wānaka"]),
    (141, 2, ["Tongariro Alpine Crossing", "Lake Taupō"]),
    (86, 3, ["Sky Tower", "Auckland Domain", "Mission Bay"]),
    (37, 1, ["Castlepoint Lighthouse", "Martinborough Square"]),
]

#: People and businesses that write to the persona but are not in the address book:
#: (key, name, organisation, e-mail, has phone, address line or "").
SENDERS = [
    ("kea", "Kea Air Bookings", "Kea Air", "bookings@keaair.example.net", True, "Wellington Airport, Stewart Duff Drive, Wellington 6022"),
    ("lodge", "Lakefront Lodge", "Lakefront Lodge", "stay@lakefrontlodge.example.com", True, "Lake Esplanade, Queenstown 9300"),
    ("rental", "Tussock Car Rentals", "Tussock Car Rentals", "hello@tussockrentals.example.com", True, "Queenstown Airport, Frankton 9300"),
    ("dental", "Harbour Street Dental", "Harbour Street Dental", "reception@example.net", True, "Lambton Quay, Wellington 6011"),
    ("bank", "Example Bank", "Example Bank", "no-reply@bank.example.com", False, ""),
    ("isp", "Kōtare Internet", "Kōtare Internet", "billing@kotare.example.net", True, ""),
    ("power", "Northerly Power", "Northerly Power", "accounts@northerly.example.org", False, ""),
    ("gym", "Te Aro Climbing Gym", "Te Aro Climbing Gym", "desk@tearoclimbing.example.com", True, "Taranaki Street, Te Aro, Wellington 6011"),
    ("meetup", "Design Systems Meetup", "Design Systems Meetup", "organisers@dsmeetup.example.org", False, ""),
    ("books", "Kererū Books", "Kererū Books", "orders@kererubooks.example.com", True, "Cuba Street, Te Aro, Wellington 6011"),
    ("bikes", "Pōneke Bikes", "Pōneke Bikes", "workshop@ponekebikes.example.net", True, "Vivian Street, Te Aro, Wellington 6011"),
    ("property", "Greenstone Property Management", "Greenstone Property Management", "tenancies@greenstone.example.com", True, "The Terrace, Wellington 6011"),
    ("news", "Slow News Weekly", "Slow News Weekly", "editors@slownews.example.org", False, ""),
    ("weather", "Windy City Weather Digest", "Windy City Weather Digest", "digest@windycity.example.net", False, ""),
    ("filmsoc", "Wellington Film Society", "Wellington Film Society", "members@filmsociety.example.org", False, ""),
    ("council", "Wellington City Council", "Wellington City Council", "rates@council.example.org", False, ""),
    ("accounts", "Example Accounts", "Example Accounts", "security@accounts.example.net", False, ""),
    ("venue", "The Blue Note Room", "The Blue Note Room", "tickets@bluenoteroom.example.com", True, "Cuba Street, Te Aro, Wellington 6011"),
    ("ferry", "Strait Crossing Ferries", "Strait Crossing Ferries", "bookings@straitcrossing.example.net", True, "Waterloo Quay, Wellington 6011"),
]

PSEUDO_GIVEN = ["Dana", "Ravi", "Sione", "Emma", "Liam", "Ngaio", "Tessa", "Hemi", "Olivia", "Marcus", "Ana", "Felix", "Greta",
                "Ihaia", "Kate", "Leon", "Moana", "Noel", "Petra", "Quinn", "Rosa", "Stefan", "Talia", "Uma", "Vikram",
                "Wiremu", "Yuki", "Zoe", "Bianca", "Callum", "Deepa", "Elias", "Freya", "Gareth", "Holly", "Ivan", "Juno", "Kiri",
                "Lachlan", "Mereana"]
PSEUDO_FAMILY = ["Whitcombe", "Harcourt", "Tuilagi", "Fairweather", "Ashby", "Parata", "Lindqvist", "Moreau", "Castellan",
                 "Hargreave", "Okonkwo", "Delacroix", "Stonefield", "Winterbourne", "Thistlewood", "Marchetti", "Rangihuna",
                 "Abernethy", "Nakamura", "Villiers", "Brannigan", "Covington", "Dunmore", "Eastlake", "Fitzwarren", "Galbraith",
                 "Holloway", "Inglewood", "Jessop", "Kirkbride", "Lovelace", "Mapplethorpe", "Northcote", "Oakhurst", "Penhallow",
                 "Quarrington", "Ravensworth", "Selwyn", "Tattersall", "Underhill"]
PSEUDO_ROLES = [
    ("Plumber", "Whitcombe Plumbing"), ("Account Manager", "Kōtare Internet"), ("Property Manager", "Greenstone Property Management"),
    ("Recruiter", "Harbour Talent"), ("Physiotherapist", "Te Aro Physio"), ("Workshop Lead", "Pōneke Bikes"),
    ("Events Coordinator", "Design Systems Meetup"), ("Freelance Illustrator", ""), ("Print Specialist", "Windy City Print Co."),
    ("Front Desk", "Lakefront Lodge"), ("Trip Leader", "Tararua Tramping Club"), ("Bookseller", "Kererū Books"),
    ("Researcher", "Victoria Design Lab"), ("Accountant", "Ledger & Fern"), ("Barista", "Harbour Light Coffee"),
    ("Coach", "Te Aro Climbing Gym"), ("Editor", "Slow News Weekly"), ("Vet", "Aro Valley Vets"),
]

MAORI_WORDS = ["kia", "ora", "whānau", "aroha", "kai", "mahi", "koha", "mōrena", "ngā", "mihi", "tēnā", "koe", "koutou", "ka", "pai",
               "āe", "kāo", "wai", "maunga", "moana", "awa", "whenua", "tamariki", "kaumātua", "hui", "karakia", "waiata", "haka",
               "marae", "iwi", "hapū", "mana", "tapu", "noa", "tangata", "wāhine", "tāne", "kōrero", "reo", "māori", "pōneke",
               "aotearoa", "haere", "mai", "rā", "pō", "ata", "mārie", "nau", "hoki", "tino", "nui", "iti", "roa", "poto",
               "whare", "kura", "tamaiti", "matua", "whaea", "kererū", "tūī", "kākā", "kiwi", "pūkeko", "kōwhai", "rimu", "tōtara"]

COMMON_WORDS = """the be to of and a in that have I it for not on with he as you do at this but his by from they we say her she or an
will my one all would there their what so up out if about who get which go me when make can like time no just him know take people
into year your good some could them see other than then now look only come its over think also back after use two how our work first
well way even new want because any these give day most us great where through much before right too mean old same tell call still
try ask need feel leave put keep let begin seem help talk turn start show hear play run move live believe hold bring happen write
sit stand lose pay meet include continue set learn change lead understand watch follow stop create speak read allow add spend grow
open walk win offer remember love consider appear buy wait serve send expect build stay fall cut reach remain suggest raise pass
sell require report decide pull morning tonight tomorrow today yesterday weekend week month thanks thank please sorry yes okay sure
maybe really pretty very quite always never often sometimes already almost soon later early late here home office street train bus
ferry flight coffee lunch dinner breakfast meeting review design feedback prototype version draft file link photo photos picture
email message call phone number address ticket booking order invoice receipt password code account update schedule calendar
reminder note notes list plan plans idea ideas question answer problem issue fix team project product customer research user users
interface layout colour font icon button screen page site app mobile desktop release launch sprint deadline budget report data
chart table number count total cost price free cheap expensive quick slow easy hard simple clear nice great lovely awesome fine
happy glad excited tired busy ready done finished sounds looks feels going coming leaving arriving running walking climbing hiking
cycling swimming cooking baking reading watching listening playing music song album concert movie film book chapter story weather
rain wind sunny cloudy cold warm hot storm forecast harbour beach hill mountain track trail bush garden park lake river coast island
north south east west city town village country road bridge station airport hotel room table seat window door kitchen bedroom
family mum dad sister brother partner friend friends everyone someone anyone nobody birthday party present gift holiday trip travel
visit weekend summer winter autumn spring monday tuesday wednesday thursday friday saturday sunday january february march april may
june july august september october november december minute minutes hour hours days weeks months years long short big small little
large high low next last best better worse least more less many few several both each every another such own while during until
since against between without within along among around behind beside beyond inside outside under above below near far away""".split()

LEARNED_WORDS = ["Kōwhai", "Figma", "standup", "wireframe", "wireframes", "Pōneke", "kererū", "Aro", "Zealandia", "Tararua",
                 "MetService", "omw", "tbh", "lol", "haha", "nah", "yep", "chur", "hmm", "ugh", "woohoo", "brb", "imo", "fyi",
                 "eta", "wfh", "Lambton", "Paraparaumu", "Kāpiti", "Marlowe", "Okafor", "Raman", "Tanaka", "Whitford", "Ngata",
                 "Petrov", "Kimura", "Aldous", "Aroha", "Priya", "Mei", "Hana", "Nina", "Jamie", "sourdough", "flat white",
                 "oat", "bouldering", "belay", "crimp", "sloper", "redpoint", "beta", "tramp", "tramping", "hut", "gaiters",
                 "merino", "togs", "jandals", "dairy", "bach", "arvo", "keen", "stoked", "munted", "rego", "wof", "eftpos",
                 "kerning", "ligature", "moodboard", "handoff", "changelog", "roadmap", "retro", "backlog", "onboarding",
                 "microcopy", "tokens", "breakpoint", "viewport", "figjam", "notion", "slack", "zoom", "emoji", "gif",
                 "Queenstown", "Wānaka", "Tekapo", "Kaikōura", "Rotorua", "Taupō", "Tongariro", "Castlepoint", "Martinborough",
                 "Te Papa", "Oriental", "Cuba", "Taranaki", "Harbourside", "Tūī", "Kākā", "pūkeko", "pōhutukawa", "rimu",
                 "Robin's", "Alex's", "Mum's", "Dad's", "Kōwhai's", "pls", "thx", "cya", "gonna", "wanna", "kinda", "dunno"]


# ----------------------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------------------

def _touch(path: pathlib.Path, when: datetime.datetime) -> None:
    """Sets a file's modification time (several views show "updated …" from it)."""
    stamp = lib.unix(when)
    os.utime(str(path), (stamp, stamp))


def _moment(clock: lib.Clock, rng: random.Random, days: float, *, bias: float = 1.2, weekend: float = 1.0,
            hours: tuple[int, int] = (7, 23), newest: float = 0.0) -> datetime.datetime:
    """A time within the last `days` days (not before `newest` days ago … i.e. at least that
    old), at local waking hours. `weekend` < 1 thins out Saturdays and Sundays, > 1 weekdays."""
    stamp = clock.now
    for _ in range(40):
        back = newest + (rng.random() ** bias) * (days - newest)
        stamp = clock.at(int(back), rng.randrange(hours[0], hours[1]), rng.randrange(60), rng.randrange(60))
        is_weekend = stamp.astimezone(clock.tz).weekday() >= 5
        if is_weekend and weekend < 1 and rng.random() > weekend:
            continue
        if not is_weekend and weekend > 1 and rng.random() > 1 / weekend:
            continue
        break
    return stamp


def _pick(rng: random.Random, items: list, low: int, high: int) -> list:
    count = min(len(items), rng.randint(low, high))
    return rng.sample(items, count) if count > 0 else []


def _fiction_phone(index: int) -> str:
    """Numbers in the range reserved for fiction (555-0100 … 555-0199), other area codes
    than the persona's contacts so that nothing collides."""
    area = ("212", "415", "312", "617")[index // 100 % 4]
    return f"+1{area}55501{index % 100:02d}"


def _pretty_phone(e164: str) -> str:
    digits = e164[-10:]
    return f"+1 ({digits[:3]}) {digits[3:6]}-{digits[6:]}"


def _slug(text: str) -> str:
    table = str.maketrans("āēīōūĀĒĪŌŪ", "aeiouAEIOU")
    out = "".join(ch if ch.isalnum() else "-" for ch in text.translate(table).lower())
    while "--" in out:
        out = out.replace("--", "-")
    return out.strip("-")


def _png(width: int, height: int, colour: tuple[int, int, int], accent: tuple[int, int, int]) -> bytes:
    """A tiny valid PNG (a disc on a plain field) for pass logos — drawn here, no image file."""
    rows = bytearray()
    cx, cy, radius = width / 2, height / 2, min(width, height) * 0.34
    for y in range(height):
        rows.append(0)
        for x in range(width):
            inside = (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2
            rows += bytes(accent if inside else colour)

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")


class _Place:
    """A place as `loc_records` describes it."""

    @property
    def entity_category(self) -> int:
        """The named-entity class for the place's name (location category → entity category)."""
        return {1: 2, 2: 4, 3: 5, 4: 13, 6: 2}.get(self.category, 3)

    def __init__(self, name: str, street: str, number: str, city: str, region: str, postal: str, lat: float, lon: float,
                 category: int, scenes: list[str], private: bool = False):
        self.name, self.street, self.number, self.city, self.region, self.postal = name, street, number, city, region, postal
        self.lat, self.lon, self.category, self.scenes, self.private = lat, lon, category, scenes, private

    @property
    def description(self) -> str:
        street = " ".join(p for p in (self.number, self.street) if p)
        parts = [street, self.city] if self.private else [self.name, street, self.city]
        return ", ".join(p for p in parts if p).lower()


def _places(persona: Persona) -> dict[str, _Place]:
    category = {"home": 5, "work": 6, "cafe": 2, "landmark": 4, "park": 3, "gym": 3, "transit": 0, "shop": 1, "travel": 4}
    scenes = {"home": ["cat", "food", "flower"], "work": ["coffee"], "cafe": ["coffee", "food"], "landmark": ["sky", "bridge"],
              "park": ["tree", "flower", "bird"], "gym": [], "transit": ["sky"], "shop": ["food", "flower"], "travel": ["sky", "tree"]}
    out: dict[str, _Place] = {}
    for p in persona.places:
        number, street = "", p.street
        first = p.street.split(" ", 1)
        if len(first) == 2 and first[0].isdigit():
            number, street = first
        private = p.kind == "home"
        out[p.key] = _Place(p.name, street, number, p.city, p.region, p.postal_code, p.latitude, p.longitude,
                            category[p.kind], scenes[p.kind], private)
    for name, city, region, postal, lat, lon, cat, place_scenes in TRIP_PLACES:
        out[name] = _Place(name, "", "", city, region, postal, lat, lon, cat, place_scenes)
    return out


# ----------------------------------------------------------------------------------------
# Generic OS assets (stand-ins)
# ----------------------------------------------------------------------------------------

GAZETTEER_DDL = """
CREATE TABLE "metadata" (
    name TEXT NOT NULL,
    qid TEXT NOT NULL,
    category_id INTEGER NOT NULL,
    isLocation INTEGER NOT NULL,
    gazetteerDomain INTEGER NOT NULL,
    alias TEXT,
    threshold INTEGER NOT NULL,
    PRIMARY KEY (name, qid, category_id)
) WITHOUT ROWID;
"""


def _system_assets(root: pathlib.Path) -> None:
    assets = lib.system(root, "/System/Library/PrivateFrameworks/PersonalizationPortraitInternals.framework/Versions/A/Resources/assets_demo")
    lib.write_plist(assets / "PhotosTopicMap.plist", dict(PHOTO_SCENES), binary=True)
    lib.create_db(assets / "AugmentedGazetteerMetadata.db", GAZETTEER_DDL, {
        "metadata": [(name, qid, category, 1 if category == 6 else 0, 1, alias if alias.lower() != name else None, 3)
                     for name, qid, category, alias in GAZETTEER],
    })


# ----------------------------------------------------------------------------------------
# PersonalizationPortrait
# ----------------------------------------------------------------------------------------

PORTRAIT_DDL = """
CREATE TABLE integrityCheck (inconsequential STRING);
CREATE TABLE sources (    id INTEGER PRIMARY KEY AUTOINCREMENT,     ref_count INTEGER NOT NULL,     bundle_id TEXT NOT NULL,     group_id TEXT,     doc_id TEXT NOT NULL,     seconds_from_1970 REAL NOT NULL,     sha256 BLOB UNIQUE NOT NULL, donation_count INTEGER NOT NULL DEFAULT 1, dwell_time_seconds INTEGER NOT NULL DEFAULT 0, length_seconds INTEGER NOT NULL DEFAULT 0, length_characters INTEGER NOT NULL DEFAULT 0, flags INTEGER NOT NULL DEFAULT 0, relevance_seconds_from_1970 REAL DEFAULT NULL, language TEXT DEFAULT NULL, user_created INTEGER, contact_handle_count INTEGER NOT NULL DEFAULT 0);
CREATE TABLE ne_records (    id INTEGER PRIMARY KEY AUTOINCREMENT,     name TEXT NOT NULL,     lc_name TEXT NOT NULL,     category INTEGER NOT NULL,     language TEXT NOT NULL,     algorithm INTEGER NOT NULL,     initial_score REAL NOT NULL,     decay_rate REAL NOT NULL,     extraction_os_build TEXT,     extraction_asset_version INTEGER,     source_id INTEGER NOT NULL REFERENCES sources (id),     is_remote INTEGER NOT NULL,     dk_event_id BLOB, is_sync_eligible INTEGER NOT NULL DEFAULT 0, sentiment_score REAL NOT NULL DEFAULT 0, impression_count INTEGER NOT NULL DEFAULT 1, occurrences_in_source INTEGER NOT NULL DEFAULT 1, dynamic_category TEXT);
CREATE TABLE kv_blobs (    id INTEGER PRIMARY KEY AUTOINCREMENT,     key TEXT UNIQUE NOT NULL,     value BLOB NOT NULL);
CREATE TABLE tp_records (    id INTEGER PRIMARY KEY AUTOINCREMENT,     topic_id TEXT NOT NULL,     algorithm INTEGER NOT NULL,     initial_score REAL NOT NULL,     decay_rate REAL NOT NULL,     sentiment_score REAL NOT NULL,     extraction_os_build TEXT,     extraction_asset_version INTEGER,     source_id INTEGER NOT NULL REFERENCES sources (id),     is_remote INTEGER NOT NULL,     is_sync_eligible INTEGER NOT NULL,     dk_event_id BLOB, impression_count INTEGER NOT NULL DEFAULT 1, occurrences_in_source INTEGER NOT NULL DEFAULT 1, algorithm_result_position INTEGER NOT NULL DEFAULT 0, algorithm_result_count INTEGER NOT NULL DEFAULT 0, exact_match_in_source_text INTEGER NOT NULL DEFAULT 0);
CREATE TABLE "loc_records" (     id INTEGER PRIMARY KEY AUTOINCREMENT,     clp_location BLOB,     cll_latitude_degrees REAL,     cll_longitude_degrees REAL,     clp_name TEXT,     clp_thoroughfare TEXT,     clp_subThoroughfare TEXT,     clp_locality TEXT,     clp_subLocality TEXT,     clp_administrativeArea TEXT,     clp_subAdministrativeArea TEXT,     clp_postalCode TEXT,     clp_ISOcountryCode TEXT,     clp_country TEXT,     clp_inlandWater TEXT,     clp_ocean TEXT,     uuid BLOB NOT NULL,     category INTEGER NOT NULL,     algorithm INTEGER NOT NULL,     initial_score REAL NOT NULL,     decay_rate REAL NOT NULL,     sentiment_score REAL NOT NULL,     extraction_os_build TEXT,     extraction_asset_version INTEGER,     source_id INTEGER NOT NULL REFERENCES sources (id),     is_remote INTEGER NOT NULL,     is_sync_eligible INTEGER NOT NULL,     dk_event_id BLOB,     lc_description TEXT NOT NULL);
CREATE TABLE "loc_records_clp_areasOfInterest" (    id INTEGER PRIMARY KEY AUTOINCREMENT,     loc_id INTEGER NOT NULL REFERENCES "loc_records" (id),     name TEXT NOT NULL);
CREATE TABLE "loc_records_contextual_ne" (    id INTEGER PRIMARY KEY AUTOINCREMENT,     loc_id INTEGER NOT NULL REFERENCES "loc_records" (id),     name TEXT NOT NULL);
CREATE TABLE cn_handles (    id INTEGER PRIMARY KEY AUTOINCREMENT,     value TEXT NOT NULL);
CREATE TABLE cn_handles_sources (    cn_handle_id INTEGER NOT NULL REFERENCES cn_handles (id),     source_id INTEGER NOT NULL REFERENCES sources (id));
CREATE TABLE cn_history_tokens (    client_identifier TEXT PRIMARY KEY,     token BLOB);
CREATE TABLE tp_records_fb_pseudocounts (     id INTEGER PRIMARY KEY AUTOINCREMENT,     item_string TEXT NOT NULL,     feedback_type INTEGER NOT NULL,     last_update_seconds_from_1970 REAL NOT NULL,     pseudocount REAL NOT NULL DEFAULT 1.0,     UNIQUE(item_string, feedback_type));
CREATE TABLE ne_records_fb_pseudocounts (     id INTEGER PRIMARY KEY AUTOINCREMENT,     item_string TEXT NOT NULL,     feedback_type INTEGER NOT NULL,     last_update_seconds_from_1970 REAL NOT NULL,     pseudocount REAL NOT NULL DEFAULT 1.0,     UNIQUE(item_string, feedback_type));
CREATE TABLE loc_records_fb_pseudocounts (     id INTEGER PRIMARY KEY AUTOINCREMENT,     item_string TEXT NOT NULL,     feedback_type INTEGER NOT NULL,     last_update_seconds_from_1970 REAL NOT NULL,     pseudocount REAL NOT NULL DEFAULT 1.0,     UNIQUE(item_string, feedback_type));
CREATE TABLE significant_contacts ( handle TEXT NOT NULL );
CREATE INDEX demo_tp_source ON tp_records (source_id);
CREATE INDEX demo_tp_topic ON tp_records (topic_id);
CREATE INDEX demo_ne_source ON ne_records (source_id);
CREATE INDEX demo_ne_name ON ne_records (lc_name, category);
CREATE INDEX demo_loc_source ON loc_records (source_id);
CREATE INDEX demo_loc_description ON loc_records (lc_description);
CREATE INDEX demo_cn_handle ON cn_handles_sources (cn_handle_id);
CREATE INDEX demo_cn_source ON cn_handles_sources (source_id);
CREATE INDEX demo_sources_time ON sources (seconds_from_1970);
"""


class _Portrait:
    """Accumulates the rows of PPSQLDatabase.db."""

    def __init__(self, persona: Persona, rng: random.Random, clock: lib.Clock):
        self.persona, self.rng, self.clock = persona, rng, clock
        self.build = persona.this_mac.os_build
        self.sources: list[dict] = []
        self.topics: list[dict] = []
        self.entities: list[dict] = []
        self.locations: list[dict] = []
        self.areas: list[tuple[int, str]] = []
        self.contextual: list[tuple[int, str]] = []
        self.handles: dict[str, int] = {}
        self.links: list[tuple[int, int]] = []
        self._linked: set[tuple[int, int]] = set()
        self._seen: set[tuple[int, str, int]] = set()

    def source(self, bundle: str, group, doc_id: str, when: datetime.datetime, language: str = "en",
               characters: int = 0, user_created=None, dwell: int = 0) -> int:
        sid = len(self.sources) + 1
        self.sources.append({
            "id": sid, "ref_count": 0, "bundle_id": bundle, "group_id": group, "doc_id": doc_id,
            "seconds_from_1970": round(lib.unix(when), 3), "sha256": self.rng.getrandbits(256).to_bytes(32, "big"),
            "donation_count": 1 if self.rng.random() < 0.8 else self.rng.randint(2, 5), "dwell_time_seconds": dwell,
            "length_seconds": 0, "length_characters": characters, "flags": 0,
            "relevance_seconds_from_1970": round(lib.unix(when), 3), "language": language, "user_created": user_created,
            "contact_handle_count": 0,
        })
        return sid

    def _ref(self, sid: int) -> None:
        self.sources[sid - 1]["ref_count"] += 1

    def topic(self, sid: int, qid: str, algorithm: int, score: float = None, sentiment: float = None, position: int = 0, of: int = 1) -> None:
        rng = self.rng
        if (sid, qid, -algorithm) in self._seen:
            return
        self._seen.add((sid, qid, -algorithm))
        self._ref(sid)
        self.topics.append({
            "topic_id": qid, "algorithm": algorithm,
            "initial_score": round(score if score is not None else rng.uniform(0.25, 0.98), 4),
            "decay_rate": 0.0 if algorithm in (5, 11) else rng.choice([0.0077, 0.0077, 0.0154, 0.0231]),
            "sentiment_score": round(sentiment if sentiment is not None else (rng.uniform(-0.25, 0.7) if rng.random() < 0.35 else 0.0), 3),
            "extraction_os_build": self.build, "extraction_asset_version": 109, "source_id": sid, "is_remote": 0,
            "is_sync_eligible": 1 if algorithm in (1, 6) else 0, "impression_count": 1,
            "occurrences_in_source": rng.choice([1, 1, 1, 2, 3]), "algorithm_result_position": position,
            "algorithm_result_count": of, "exact_match_in_source_text": 1 if algorithm in (4, 10) else 0,
        })

    def entity(self, sid: int, name: str, category: int, algorithm: int, score: float = None, sentiment: float = None,
               occurrences: int = None, language: str = "en") -> None:
        rng = self.rng
        key = (sid, name.lower(), category)
        if key in self._seen:
            return
        self._seen.add(key)
        self._ref(sid)
        if sentiment is None and name in GRUMBLES and rng.random() < 0.55:
            sentiment = rng.uniform(-0.75, -0.05)      # bills, reminders and the dentist read less cheerfully
        self.entities.append({
            "name": name, "lc_name": name.lower(), "category": category, "language": language, "algorithm": algorithm,
            "initial_score": round(score if score is not None else rng.uniform(0.3, 1.0), 4),
            "decay_rate": rng.choice([0.0077, 0.0154, 0.0231]), "extraction_os_build": self.build,
            "extraction_asset_version": 109, "source_id": sid, "is_remote": 0, "is_sync_eligible": 0,
            "sentiment_score": round(sentiment if sentiment is not None else (rng.uniform(-0.3, 0.8) if rng.random() < 0.3 else 0.0), 3),
            "impression_count": 1, "occurrences_in_source": occurrences or rng.choice([1, 1, 1, 2, 2, 3, 4]),
        })

    def place(self, sid: int, place: _Place, algorithm: int, *, coordinates: bool = True, jitter: float = 30.0,
              named: bool = True, category: int = None, description: str = None, mentioned: list[str] = ()) -> None:
        rng = self.rng
        self._ref(sid)
        lat = lon = None
        if coordinates:
            delta = jitter / 111_000.0
            lat = round(place.lat + rng.uniform(-delta, delta), 6)
            lon = round(place.lon + rng.uniform(-delta, delta) * 1.3, 6)
        structured = True      # an address found in text still gets its parts, just no name and no coordinate
        loc_id = len(self.locations) + 1
        self.locations.append({
            "id": loc_id, "cll_latitude_degrees": lat, "cll_longitude_degrees": lon,
            "clp_name": place.name if (named or coordinates) and not place.private else None,
            "clp_thoroughfare": (place.street or None) if structured else None,
            "clp_subThoroughfare": (place.number or None) if structured else None,
            "clp_locality": place.city if structured else None,
            "clp_subLocality": ("Te Aro" if place.city == "Wellington" and place.postal == "6011" else None) if structured else None,
            "clp_administrativeArea": place.region if structured else None,
            "clp_postalCode": place.postal if structured else None,
            "clp_ISOcountryCode": "NZ" if structured else None, "clp_country": "New Zealand" if structured else None,
            "clp_ocean": "Tasman Sea" if place.name == "Milford Sound" and structured else None,
            "uuid": lib.uuid_obj(rng).bytes, "category": place.category if category is None else category,
            "algorithm": algorithm, "initial_score": round(rng.uniform(0.4, 1.0), 4), "decay_rate": 0.0077,
            "sentiment_score": 0.0, "extraction_os_build": self.build, "extraction_asset_version": 109,
            "source_id": sid, "is_remote": 0, "is_sync_eligible": 0,
            "lc_description": description or place.description,
        })
        if (named or coordinates) and place.name and not place.private and rng.random() < 0.5:
            self.areas.append((loc_id, place.name))
            if place.city == "Wellington" and rng.random() < 0.4:
                self.areas.append((loc_id, "Wellington Waterfront" if place.lon > 174.777 else "Te Aro"))
        for name in mentioned:
            self.contextual.append((loc_id, name))

    def handle(self, sid: int, value: str) -> None:
        if not value:
            return
        hid = self.handles.setdefault(value, len(self.handles) + 1)
        if (hid, sid) not in self._linked:
            self._linked.add((hid, sid))
            self.links.append((hid, sid))
            self.sources[sid - 1]["contact_handle_count"] += 1


def _portrait(root: pathlib.Path, persona: Persona, rng: random.Random, clock: lib.Clock,
              places: dict[str, _Place], senders: dict[str, dict]) -> dict:
    db = _Portrait(persona, rng, clock)
    span = 540
    themes = {t[0]: t for t in THEMES}
    weights = [t[1] for t in THEMES]
    owner = persona.owner

    def theme_for(preferred: list[str] = None) -> tuple:
        if preferred and rng.random() < 0.8:
            return themes[rng.choice(preferred)]
        return rng.choices(THEMES, weights=weights)[0]

    def people_of(theme: tuple, low: int, high: int) -> list[Person]:
        return [persona.person(k) for k in _pick(rng, theme[4], low, high)]

    def add_topics(sid: int, theme: tuple, low: int, high: int, algorithms: list[int]) -> None:
        names = theme[2]
        # The first topics of a theme are its core: picked far more often than the tail.
        chosen = []
        for _ in range(rng.randint(low, high)):
            chosen.append(names[min(len(names) - 1, int(rng.expovariate(0.55)))])
        chosen = list(dict.fromkeys(chosen))
        for position, name in enumerate(chosen):
            db.topic(sid, T[name], rng.choice(algorithms), position=position, of=len(chosen))

    def add_entities(sid: int, theme: tuple, low: int, high: int, algorithm: int) -> None:
        pool = theme[3]
        for _ in range(rng.randint(low, high)):
            name, category = pool[min(len(pool) - 1, int(rng.expovariate(0.5)))]
            db.entity(sid, name, category, algorithm)

    def add_people(sid: int, people: list[Person], algorithm: int, handles: bool) -> None:
        for person in people:
            label = person.given
            if person.nickname and person.relationship in ("mother", "father") and rng.random() < 0.6:
                label = person.nickname
            elif rng.random() < 0.18:
                label = person.full_name
            db.entity(sid, label, PERSON, algorithm, sentiment=rng.uniform(0.1, 0.8) if rng.random() < 0.4 else 0.0)
            if handles:
                db.handle(sid, person.email if (algorithm != 2 or rng.random() < 0.5 or not person.phone) else person.phone)

    def knowledge_topics(sid: int, theme_key: str) -> None:
        if theme_key in ("travel", "family", "outdoors", "photo") and rng.random() < 0.07:
            db.topic(sid, UNNAMED["wellington"], 11, score=rng.uniform(0.5, 0.9))
            db.entity(sid, "Wellington", CITY, 17)
        if theme_key == "travel" and rng.random() < 0.12:
            db.topic(sid, UNNAMED["new zealand"], 11, score=rng.uniform(0.4, 0.8))
            db.entity(sid, "New Zealand", COUNTRY, 17)

    # --- Mail -------------------------------------------------------------------------
    sender_keys = list(senders)
    for _ in range(780):
        when = _moment(clock, rng, span, weekend=0.35)
        language = "mi" if rng.random() < 0.02 else "en"
        sid = db.source(MAIL, None, lib.uuid_string(rng), when, language, characters=rng.randint(180, 6200), user_created=0)
        business = rng.random() < 0.36      # mail from a non-contact sender
        if business:
            sender = senders[rng.choice(sender_keys)]
            theme = themes[sender["theme"]]
            db.handle(sid, sender["email"])
            db.entity(sid, sender["org"], ORG, 2)
            people: list[Person] = []
        else:
            theme = theme_for(["work", "work", "work", "family", "outdoors", "food", "climbing", "photo", "culture"])
            people = people_of(theme, 1, 3)
        db.handle(sid, owner.emails[1] if theme[0] == "work" else owner.email)
        if not business or rng.random() < 0.55:
            add_topics(sid, theme, 1, 1 if business else 3, [6, 6, 6, 4, 3])
        add_entities(sid, theme, 0 if business else 1, 2 if business else 4, 2)
        add_people(sid, people, 2, handles=True)
        if rng.random() < 0.2:
            db.entity(sid, owner.given, PERSON, 2)
        if rng.random() < 0.22:
            db.entity(sid, rng.choice(FALSE_PERSONS), PERSON, 2, sentiment=0.0)
        if rng.random() < 0.05 or language != "en":
            db.topic(sid, LANGUAGE_QID[language], 12, score=rng.uniform(0.85, 1.0), sentiment=0.0)
        if rng.random() < 0.025:
            db.topic(sid, "Q" + rng.choice(GAZETTEER)[1], 10, score=rng.uniform(0.2, 0.5))
        knowledge_topics(sid, theme[0])
        if rng.random() < 0.11 and theme[5]:      # an address detected in the text: no coordinates
            place = places[rng.choice(theme[5])]
            if not place.private and place.street:
                full = ", ".join(p for p in (" ".join(q for q in (place.number, place.street) if q), place.city + " " + place.postal) if p)
                db.place(sid, place, 4, coordinates=False, named=False, category=0, description=full.lower(),
                         mentioned=[p.given for p in people[:2]])
                db.entity(sid, full, FULL_ADDRESS, 4)

    # --- Messages ---------------------------------------------------------------------
    for _ in range(560):
        when = _moment(clock, rng, span, weekend=1.0, hours=(7, 24))
        language = "mi" if rng.random() < 0.03 else "en"
        sid = db.source(MESSAGES, None, "iMessage;-;" + lib.uuid_string(rng), when, language, characters=rng.randint(20, 900))
        person = persona.weighted_person(rng)
        theme = theme_for([t[0] for t in THEMES if person.key in t[4]] or None)
        db.handle(sid, person.handle)
        add_people(sid, [person], 2, handles=False)
        if rng.random() < 0.6:
            add_topics(sid, theme, 1, 2, [6, 6, 4])
        add_entities(sid, theme, 0, 2, 2)
        if rng.random() < 0.1:
            db.entity(sid, rng.choice(FALSE_PERSONS), PERSON, 2, sentiment=0.0)
        if rng.random() < 0.04 or language != "en":
            db.topic(sid, LANGUAGE_QID[language], 12, score=rng.uniform(0.8, 1.0), sentiment=0.0)
        knowledge_topics(sid, theme[0])

    # --- Safari (page content) ----------------------------------------------------------
    pages = [("en.wikipedia.org", "wiki"), ("www.example.org", "handbook"), ("blog.example.com", "posts"),
             ("www.example.net", "guides"), ("docs.example.org", "articles")]
    for _ in range(420):
        when = _moment(clock, rng, span, weekend=0.8)
        theme = theme_for()
        host, section = rng.choice(pages)
        topic_word = rng.choice(theme[2])
        url = f"https://{host}/{section}/{_slug(topic_word).replace('-', '_').capitalize() if host.startswith('en.') else _slug(topic_word)}"
        if not host.startswith("en."):
            url += f"-{rng.randint(2, 480)}"
        sid = db.source(SAFARI, G_PAGE, url, when, "en", characters=rng.randint(1500, 42000), dwell=rng.randint(8, 900))
        add_topics(sid, theme, 2, 4, [1, 1, 6])
        db.topic(sid, T[topic_word], 1, score=rng.uniform(0.6, 1.0))
        add_entities(sid, theme, 1, 3, 15)
        if rng.random() < 0.05:
            db.topic(sid, "Q" + rng.choice(GAZETTEER)[1], 10, score=rng.uniform(0.2, 0.6))
        knowledge_topics(sid, theme[0])

    # --- Notes, Reminders, Slack ----------------------------------------------------------
    for _ in range(150):
        when = _moment(clock, rng, span, weekend=0.7)
        theme = theme_for(["work", "outdoors", "food", "travel", "culture", "admin"])
        sid = db.source(NOTES, None, "x-coredata://" + lib.uuid_string(rng) + "/ICNote/p" + str(rng.randint(12, 640)), when, "en",
                        characters=rng.randint(60, 5200), user_created=1)
        add_topics(sid, theme, 1, 3, [6, 6, 4])
        add_entities(sid, theme, 1, 3, 2)
        add_people(sid, people_of(theme, 0, 1), 2, handles=False)
    for _ in range(50):
        when = _moment(clock, rng, span, weekend=0.9)
        theme = theme_for(["admin", "food", "family", "outdoors"])
        sid = db.source(REMINDERS, None, lib.uuid_string(rng), when, "en", characters=rng.randint(12, 90), user_created=1)
        add_topics(sid, theme, 1, 1, [2])
        add_entities(sid, theme, 0, 1, 2)
    for _ in range(34):
        when = _moment(clock, rng, 200, weekend=0.1, hours=(9, 18))
        theme = themes["work"]
        sid = db.source(SLACK, G_INTERACTION, lib.uuid_string(rng), when, "en", characters=rng.randint(30, 700))
        add_topics(sid, theme, 1, 2, [2, 6])
        add_people(sid, people_of(theme, 1, 2), 2, handles=False)
        add_entities(sid, theme, 0, 2, 2)

    # --- Calendar -------------------------------------------------------------------------
    for _ in range(160):
        when = _moment(clock, rng, span, weekend=0.3, hours=(8, 19))
        theme = theme_for(["work", "work", "work", "climbing", "family", "admin", "culture"])
        sid = db.source(CALENDAR, None, lib.uuid_string(rng) + ":" + lib.uuid_string(rng)[:8], when, "en", characters=rng.randint(10, 400))
        events = [e for e in theme[3] if e[1] == EVENT] or [("Catch-up", EVENT)]
        db.entity(sid, rng.choice(events)[0], EVENT, 10, score=rng.uniform(0.6, 1.0))
        people = people_of(theme, 0, 3)
        add_people(sid, people, 10, handles=True)
        if rng.random() < 0.3:
            add_topics(sid, theme, 1, 1, [4])
        if theme[5] and rng.random() < 0.6:
            place = places[theme[5][0]]
            db.place(sid, place, 9 if rng.random() < 0.7 else 5, jitter=4, mentioned=[p.given for p in people[:2]])
            if not place.private:
                db.entity(sid, place.name, place.entity_category, 10)

    # --- Photos (knowledge graph donations) ---------------------------------------------------
    companions = [persona.person(k) for k in ("alex", "alex", "alex", "jamie", "helen", "david", "priya", "mei", "tom")]
    photo_bias = {"home": 1.0, "work": 0.15, "transit": 0.2, "gym": 0.5, "cafe": 1.3, "shop": 1.2, "park": 5.0, "landmark": 7.0}
    home_base = [(p.key, max(1, p.visits_per_month) * photo_bias[p.kind] ** 2) for p in persona.places if p.kind != "travel"]

    def photo(place: _Place, when: datetime.datetime) -> None:
        sid = db.source(PHOTOS, G_PHOTOS, lib.uuid_string(rng) + "/L0/001", when, None)
        with_people = [c for c in _pick(rng, companions, 0, 2)] if rng.random() < 0.45 else []
        db.place(sid, place, 10, jitter=45 if place.category in (3, 4) else 18, mentioned=list(dict.fromkeys(p.given for p in with_people)))
        for scene in _pick(rng, place.scenes, 0, 2):
            db.topic(sid, PHOTO_SCENES[scene], 5, score=rng.uniform(0.5, 1.0), sentiment=0.0)
        if not place.private:
            db.entity(sid, place.name, place.entity_category, 11)
        if place.city and rng.random() < 0.5:
            db.entity(sid, place.city, CITY, 11)
        for person in with_people:
            db.entity(sid, person.given, PERSON, 11)

    for _ in range(250):
        key = rng.choices([k for k, _ in home_base], weights=[math.sqrt(w) for _, w in home_base])[0]
        photo(places[key], _moment(clock, rng, span, weekend=1.6, hours=(8, 22)))
    for started, length, names in TRIPS:
        for name in names:
            place = next((p for p in places.values() if p.name == name), None)
            if place is None:
                continue
            for _ in range(rng.randint(4, 11)):
                day = started - rng.randrange(0, max(1, length))
                photo(place, clock.at(day, rng.randrange(8, 21), rng.randrange(60), rng.randrange(60)))

    # --- Maps: guides, pinned places, looked-up places ----------------------------------------------
    guide_keys = ["cafe", "coffee", "te_papa", "botanic", "mt_vic", "zealandia", "oriental", "market", "cable_car",
                  "Days Bay", "Red Rocks Coastal Walk", "Tongariro Alpine Crossing", "Milford Sound", "Kaikōura", "Wānaka", "Lake Tekapo"]
    for key in guide_keys:
        place = places[key]
        for _ in range(rng.randint(1, 3)):
            sid = db.source(MAPS, G_COLLECTIONS, lib.uuid_string(rng), _moment(clock, rng, span, bias=0.9), None)
            db.place(sid, place, 7, jitter=3)
            db.entity(sid, place.name, place.entity_category, 7)
    pinned_labels = {"home": "Home", "work": persona.company, "gym": "Te Aro Climbing Gym", "parents": "Helen & David"}
    for key, label in pinned_labels.items():
        place = places[key]
        pinned = _Place(label, place.street, place.number, place.city, place.region, place.postal, place.lat, place.lon, place.category, [])
        for _ in range(2 if key in ("home", "work") else 1):
            sid = db.source(MAPS, G_PINNED, lib.uuid_string(rng), _moment(clock, rng, span, bias=0.6, newest=120), None)
            db.place(sid, pinned, 6 if key in ("home", "work") else 7, jitter=2, description=(label + ", " + place.city).lower())
    lookups = [k for k in places if not places[k].private]
    lookup_weights = [3.0 if places[k].city == "Wellington" else 1.0 for k in lookups]
    for _ in range(96):
        place = places[rng.choices(lookups, weights=lookup_weights)[0]]
        sid = db.source(MAPS, G_VIEWED + "." + MAPS, lib.uuid_string(rng), _moment(clock, rng, span), None, dwell=rng.randint(5, 240))
        db.place(sid, place, 7, jitter=2)
        db.entity(sid, place.name, place.entity_category, 7)
        if rng.random() < 0.3:
            db.topic(sid, T["travel" if place.city != "Wellington" else rng.choice(["café", "restaurant", "hiking"])], 2)

    # --- Podcasts and Music ---------------------------------------------------------------------------
    show_topics = {"The Design Detail Hour": ["design", "user interface", "graphic design"], "Slow News Weekly": ["podcast"],
                   "Trail Notes": ["hiking", "camping", "national park"], "Birdsong Aotearoa": ["bird", "wildlife", "bird migration"],
                   "Everyday Science": ["science", "astronomy", "machine learning"]}
    for _ in range(54):
        show, episode = rng.choice(persona.podcasts)
        sid = db.source(PODCASTS, None, lib.uuid_string(rng), _moment(clock, rng, 400, hours=(7, 22)), "en", dwell=rng.randint(300, 3200))
        db.entity(sid, show, MEDIA, 13, score=rng.uniform(0.6, 1.0))
        for name in _pick(rng, show_topics.get(show, ["podcast"]), 1, 2):
            db.topic(sid, T[name], 8)
        db.topic(sid, T["podcast"], 8, score=rng.uniform(0.3, 0.6))
    for _ in range(40):
        track = rng.choice(persona.tracks)
        sid = db.source(MUSIC, None, lib.uuid_string(rng), _moment(clock, rng, 300, hours=(7, 23)), None, dwell=track.seconds)
        db.entity(sid, track.artist, ARTIST, 8, score=rng.uniform(0.5, 1.0))
        if rng.random() < 0.5:
            db.entity(sid, track.album, MEDIA, 8)

    # --- Significant contacts ---------------------------------------------------------------------------
    significant: list[str] = []
    for person in persona.others:
        if person.closeness >= 0.6:
            significant.append(person.handle)
            if person.closeness >= 0.7 and person.email and person.email != person.handle:
                significant.append(person.email)
    for value in significant:      # every significant handle is also a known handle
        db.handles.setdefault(value, len(db.handles) + 1)

    path = lib.library(root, "PersonalizationPortrait/PPSQLDatabase.db")
    with lib.sqlite_db(path, PORTRAIT_DDL) as con:
        lib.insert(con, "sources", db.sources)
        lib.insert(con, "tp_records", db.topics)
        lib.insert(con, "ne_records", db.entities)
        lib.insert(con, "loc_records", db.locations)
        con.executemany('INSERT INTO "loc_records_clp_areasOfInterest" (loc_id, name) VALUES (?, ?)', db.areas)
        con.executemany('INSERT INTO "loc_records_contextual_ne" (loc_id, name) VALUES (?, ?)', db.contextual)
        con.executemany("INSERT INTO cn_handles (id, value) VALUES (?, ?)", [(hid, value) for value, hid in db.handles.items()])
        con.executemany("INSERT INTO cn_handles_sources VALUES (?, ?)", db.links)
        con.executemany("INSERT INTO significant_contacts VALUES (?)", [(v,) for v in significant])
        con.execute("INSERT INTO integrityCheck VALUES ('ok')")

    # Topics/ScoreCache: the system's own decayed ranking, 0…1.
    now_unix = lib.unix(clock.now)
    when_of = {s["id"]: s["seconds_from_1970"] for s in db.sources}
    raw: dict[str, float] = {}
    for record in db.topics:
        age = (now_unix - when_of[record["source_id"]]) / 86_400
        raw[record["topic_id"]] = raw.get(record["topic_id"], 0.0) + record["initial_score"] * math.exp(-age / 150)
    top = max(raw.values())
    cached = {qid: round(0.97 * (value / top) ** 0.6, 6) for qid, value in sorted(raw.items(), key=lambda kv: -kv[1])
              if value / top > 0.004}
    cache_path = lib.write_bytes(lib.library(root, "PersonalizationPortrait/Topics/ScoreCache"), _score_cache(cached))
    _touch(cache_path, clock.ago(hours=5))
    return {"topics": cached}


def _score_cache(scores: dict[str, float]) -> bytes:
    """`Topics/ScoreCache`: the layout ScoreCacheFile.read documents — magic `PLP\\x01`,
    three u32 offsets, NUL-terminated keys, little-endian doubles, a table of tagged u32
    references (0xA string, 0x4 double, 0xC dictionary) and the root reference last."""
    body = bytearray(b"PLP\x01" + b"\0" * 12)
    strings_at = len(body)
    key_refs = []
    for key in scores:
        key_refs.append(0xA000_0000 | len(body))
        body += key.encode("utf-8") + b"\0"
    while len(body) % 8:
        body += b"\0"
    doubles_at = len(body)
    value_refs = []
    for value in scores.values():
        value_refs.append(0x4000_0000 | len(body))
        body += struct.pack("<d", value)
    table_at = len(body)
    body += struct.pack("<I", len(scores))
    body += b"".join(struct.pack("<I", ref) for ref in key_refs + value_refs)
    body += struct.pack("<I", 0xC000_0000 | table_at)
    struct.pack_into("<III", body, 4, strings_at, doubles_at, table_at)
    return bytes(body)


def _portrait_contacts(root: pathlib.Path, persona: Persona, rng: random.Random, clock: lib.Clock) -> None:
    """me_card.pb, name_records and the "Shared with You" stream."""
    owner = persona.owner
    base = lib.library(root, "PersonalizationPortrait")
    # Fields per PortraitStore.meCard: 1 contact identifier, 2 given name, 16 display name,
    # 18 modification time (Cocoa seconds, varint).
    lib.write_bytes(base / "Contacts/me_card.pb", pb.message([
        (1, owner.contact_id), (2, owner.given), (16, owner.full_name), (18, int(lib.cocoa(clock.ago(days=23, hours=4)))),
    ]))
    # name_records: repeated field 1 = record {1 identifier, 2 score (double), 5 identifier, 6… name parts}.
    records = []
    for person in persona.people:
        score = 1.0 if person is owner else round(0.25 + 0.7 * person.closeness + rng.uniform(-0.04, 0.04), 4)
        records.append((1, [(1, person.contact_id), (2, pb.double(score)), (5, lib.uuid_string(rng)), (6, person.given), (9, person.family)]))
        if person.nickname:
            records.append((1, [(1, person.contact_id), (2, pb.double(round(score * 0.8, 4))), (5, lib.uuid_string(rng)), (6, person.nickname)]))
    lib.write_bytes(base / "Contacts/name_records/contacts.pb", pb.message(records))

    # rankedSocialHighlights. Fields per PortraitStore.socialHighlights: 1 id, 5 source app,
    # 7 URL, 8.4 sender handle, 12 kind, 13 content date (Cocoa), 20 rank score, 32 group name.
    # The kind strings are invented (the real value set was not looked at).
    shared = [
        ("alex", "https://en.wikipedia.org/wiki/Tongariro_Alpine_Crossing", "link"),
        ("alex", "https://www.example.com/recipes/slow-roast-lamb-shoulder", "link"),
        ("alex", "https://stay.example.com/queenstown/lakefront-lodge", "link"),
        ("jamie", "https://photos.example.com/albums/mum-and-dad-anniversary", "photos"),
        ("jamie", "https://www.example.org/events/book-club-november", "link"),
        ("priya", "https://www.example.net/guides/tararua-southern-crossing", "link"),
        ("priya", "https://podcasts.example.com/trail-notes/tararua-southern-crossing", "podcast"),
        ("tom", "https://music.example.com/album/late-set-marlow-quartet", "music"),
        ("tom", "https://tickets.example.com/hurricanes-home-game", "link"),
        ("mei", "https://www.example.org/exhibitions/harbour-light-photography", "link"),
        ("mei", "https://en.wikipedia.org/wiki/Kererū", "link"),
        ("helen", "https://www.example.net/garden/planting-calendar-spring", "link"),
        ("lucas", "https://design.example.org/articles/empty-states-that-teach", "link"),
        ("nina", "https://research.example.org/notes/interview-synthesis-templates", "link"),
        ("sam", "https://www.example.com/tracks/makara-peak-loop", "link"),
        ("alex", "https://music.example.com/album/small-hours-anna-fairlie", "music"),
        ("jamie", "https://en.wikipedia.org/wiki/Zealandia_(wildlife_sanctuary)", "link"),
        ("priya", "https://www.example.com/recipes/sourdough-starter-basics", "link"),
        ("alex", "https://www.example.net/guides/wanaka-day-walks", "link"),
        ("alex", "https://photos.example.com/albums/queenstown-trip", "photos"),
        ("tom", "https://podcasts.example.com/slow-news-weekly/the-week-in-review", "podcast"),
        ("mei", "https://photos.example.com/albums/oriental-bay-roll", "photos"),
        ("jamie", "https://kererubooks.example.com/staff-picks", "link"),
        ("lucas", "https://design.example.org/articles/type-scales-for-small-screens", "link"),
        ("aroha", "https://dsmeetup.example.org/programme", "link"),
        ("helen", "https://www.example.com/recipes/pavlova-for-a-crowd", "link"),
        ("sam", "https://ponekebikes.example.net/workshop/hardtail-setup", "link"),
        ("priya", "https://windycity.example.net/forecast/tararua-range", "link"),
        ("alex", "https://music.example.com/album/windy-city-the-paper-kites-club", "music"),
        ("david", "https://www.example.net/timetables/kapiti-line", "link"),
    ]
    records = []
    for person_key, url, kind in shared:
        person = persona.person(person_key)
        content = _moment(clock, rng, 75, hours=(8, 23))
        identifier = lib.uuid_string(rng)
        group = "Whānau" if person_key in ("jamie", "helen") and rng.random() < 0.6 else person.full_name
        for ranking in range(rng.randint(1, 6)):
            ranked = min(clock.ago(minutes=rng.randint(3, 600)), content + datetime.timedelta(hours=rng.uniform(0.2, 24 * 9) * (ranking + 1) / 2))
            payload = pb.message([
                (1, identifier), (5, MESSAGES), (7, url), (8, [(4, person.handle)]), (12, kind),
                (13, pb.double(lib.cocoa(content))), (20, pb.double(round(rng.uniform(0.18, 0.97), 4))), (32, group),
            ])
            records.append((ranked, payload))
    lib.write_stream(base / "streams/rankedSocialHighlights", records)


# ----------------------------------------------------------------------------------------
# Suggestions
# ----------------------------------------------------------------------------------------

SUGGESTIONS_DDL = """
CREATE TABLE entity (id INTEGER PRIMARY KEY AUTOINCREMENT,entityKey TEXT NOT NULL,entityType INTEGER NOT NULL,author TEXT,content TEXT,contentRangeOfInterest TEXT,title TEXT COLLATE NOCASE,timeRangeStart REAL,timeRangeEnd REAL,floatingRange INTEGER,timeRangeStartUTCOffsetSeconds INTEGER,timeRangeEndUTCOffsetSeconds INTEGER,creationTimestamp REAL,updateTimestamp REAL,indexTimestamp REAL,lastSeenTimestamp REAL,tags TEXT,structuredData BLOB,quality REAL,locations BLOB,masterEntityId INTEGER DEFAULT -1,groupId INTEGER DEFAULT -1,state INTEGER DEFAULT 0,contentHash TEXT,downloadState INTEGER DEFAULT 0, contentHashBlob BLOB, pendingGeocode BOOLEAN DEFAULT false, harvestedOnBuild TEXT, curatedDupe BOOLEAN DEFAULT false);
CREATE TABLE entityTags (tag TEXT,entityKey TEXT,entityType INTEGER,parentKey TEXT,duplicateKeyHash TEXT NOT NULL, duplicateKeyHashBlob BLOB);
CREATE TABLE entityReferences (id INTEGER PRIMARY KEY AUTOINCREMENT,bundleIdentifier TEXT,uniqueIdentifier TEXT,entityId INTEGER,domainIdentifier TEXT);
CREATE TABLE metadata (key TEXT NOT NULL, value);
CREATE TABLE emailMetadata (id INTEGER PRIMARY KEY AUTOINCREMENT,key TEXT NOT NULL,type INTEGER NOT NULL,sourceKey TEXT,author TEXT,creationTimestamp REAL,updateTimestamp REAL,indexTimestamp REAL,lastSeenTimestamp REAL,tags TEXT,state INTEGER DEFAULT 0,downloadState INTEGER DEFAULT 0,harvestedOnBuild TEXT, pendingVerification INTEGER DEFAULT 0);
CREATE TABLE emailTags (key TEXT NOT NULL,type INTEGER NOT NULL,tag TEXT NOT NULL);
CREATE TABLE urls (id INTEGER PRIMARY KEY AUTOINCREMENT,url TEXT NOT NULL,received_from_handle TEXT,bundle_id TEXT NOT NULL,group_id TEXT,doc_id TEXT NOT NULL,seconds_from_1970 REAL NOT NULL, title TEXT, document_title TEXT, document_seconds_from_1970 REAL, document_time_interval REAL NOT NULL DEFAULT 0, flags INTEGER NOT NULL DEFAULT 0);
CREATE TABLE extractionInfos (id INTEGER PRIMARY KEY AUTOINCREMENT,extractionType INTEGER NOT NULL,modelVersion NUM NOT NULL,confidence NUM NOT NULL);
CREATE TABLE contactDetails (id INTEGER PRIMARY KEY AUTOINCREMENT,value TEXT NOT NULL,type INTEGER NOT NULL,label TEXT,entityId INTEGER NOT NULL,duplicateKey TEXT NOT NULL,sourceKey TEXT,extractionInfoId INTEGER NOT NULL,FOREIGN KEY(entityId) REFERENCES entity(id) ON DELETE NO ACTION,FOREIGN KEY(extractionInfoId) REFERENCES extractionInfos(id) ON DELETE RESTRICT);
CREATE TABLE "locations" (id INTEGER PRIMARY KEY AUTOINCREMENT,locationType INTEGER NOT NULL,label TEXT,address TEXT,airportCode TEXT,latitude REAL,longitude REAL,accuracy REAL,quality REAL,handle BLOB, eventId INTEGER);
CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT,entityId INTEGER NOT NULL,duplicateKey TEXT NOT NULL,sourceKey TEXT,title TEXT,content TEXT,creationTimestamp INTEGER,lastModifiedTimestamp INTEGER,whenRange TEXT,structuredData BLOB,state INTEGER,curated INTEGER);
CREATE TABLE eventTags (id INTEGER PRIMARY KEY AUTOINCREMENT,eventId INTEGER NOT NULL,name TEXT);
CREATE TABLE statsCounters (key TEXT NOT NULL,value REAL NOT NULL);
CREATE TABLE integrityCheck (inconsequential STRING);
CREATE INDEX demo_entity_type ON entity (entityType);
CREATE INDEX demo_entity_tags ON entityTags (entityKey, entityType);
CREATE INDEX demo_event_tags ON eventTags (eventId);
CREATE INDEX demo_details ON contactDetails (entityId);
CREATE INDEX demo_email_tags ON emailTags (key);
"""

SNIPPETS_DDL = """
CREATE TABLE snippets (id INTEGER PRIMARY KEY AUTOINCREMENT,entityId INTEGER,title TEXT,content TEXT,contentRangeOfInterest TEXT);
CREATE TABLE emailSnippets (id INTEGER PRIMARY KEY AUTOINCREMENT,emailId INTEGER,title TEXT,content TEXT);
CREATE TABLE integrityCheck (inconsequential STRING);
"""

#: Mail the persona receives: (sender key — persona person or SENDERS key, weight, subject, body).
#: `{…}` placeholders are filled per message. All invented.
MAIL_TEMPLATES = [
    ("aroha", 5, "Design review moved to Thursday", "Hi Robin, can we move the design review to Thursday at 2 pm? Nina's research readout is on before it and I'd like the team to hear that first. Same room on Lambton Quay."),
    ("aroha", 3, "Roadmap for next quarter", "Thanks for the onboarding concepts. I've added them to the roadmap draft; could you sanity-check the sizing before Monday's planning?"),
    ("lucas", 5, "Re: Onboarding flow prototype", "The new empty states look great. Two questions about the Figma file: are the spacing tokens final, and should the progress bar animate between steps?"),
    ("lucas", 2, "Build 4{n} is on TestFlight", "Build 4{n} has the settings redesign behind a flag. Shout if the type scale looks off on the small phones."),
    ("nina", 4, "Research readout: notes and recordings", "Notes from the six interviews are in the shared folder. The strongest theme: people don't trust the default privacy settings and go looking for them on day one."),
    ("nina", 2, "Participants for round two", "I have five people confirmed for next week. Could you send me the prototype link by Wednesday so I can test the script?"),
    ("oliver", 3, "Sprint planning agenda", "Agenda for Monday: carry-over from the last sprint, the settings redesign, and a first look at the dashboard. Please add anything that needs engineering time."),
    ("hana", 3, "Dashboard numbers for the quarterly review", "Activation is up four points since the new onboarding shipped. I've put the cohort charts in the deck — let me know which you want to keep."),
    ("helen", 4, "Sunday lunch?", "Dad is doing a roast on Sunday. Can you and Alex make the 11:44 train to Paraparaumu? We'll pick you up from the station. Bring your togs if it's warm."),
    ("helen", 2, "Photos from the garden", "The kōwhai is finally flowering and the tūī are back. I've sent you a few pictures. Your father says the tomatoes are his, not mine."),
    ("david", 2, "Train times", "The 11:44 gets in at 12:38. If you miss it the next one is an hour later. Mum says don't forget the pavlova tin."),
    ("jamie", 4, "Birthday plans", "Thinking dinner at Tūī & Fern on the Saturday, then drinks on Cuba Street. Can you book for eight? Mum and Dad are coming down on the train."),
    ("jamie", 2, "Book club pick", "It's my turn to choose. I'm tempted by the big science fiction one everyone keeps recommending — veto now or forever hold your peace."),
    ("priya", 3, "Tararua trip gear list", "Forecast looks like a southerly on Saturday night, so bring the warm sleeping bag. I've booked the hut; we still need a second stove and someone with gaiters to spare."),
    ("tom", 3, "Hurricanes tickets", "I've got four tickets for the home game. You and Alex in? Meet at the station at six and we'll walk over."),
    ("mei", 3, "Photos from Oriental Bay", "The light on Saturday was unreal. I've uploaded the roll — the one of you two on the wharf is a keeper. Print swap next week?"),
    ("sam", 2, "Makara Peak on Sunday?", "Trails should be dry by Sunday. I can lend you the hardtail if yours is still in the workshop."),
    ("alex", 4, "Flights booked!", "Booked us on the morning flight to Auckland. Your boarding pass should be in your inbox. I'll sort the airport shuttle."),
    ("alex", 3, "Queenstown itinerary", "Three nights at the lodge, rental car from the airport, and I've pencilled in a day at Wānaka. Can you check the booking references match?"),
    ("landlord", 2, "Flat inspection", "The six-monthly inspection is due. Would the morning of the 14th suit? It takes about twenty minutes and you don't need to be home."),
    ("drlee", 2, "Appointment reminder", "This is a reminder of your check-up with Dr Morgan Lee at Harbour Street Dental. Please call reception if you need to reschedule."),
    ("kea", 5, "Your booking confirmation {ref} — Wellington to Auckland", "Thank you for flying Kea Air. Booking reference {ref}. Robin Sample, flight KEA 412, seat 14C. Your mobile boarding pass is attached; bag drop closes 30 minutes before departure."),
    ("kea", 2, "Check in now for KEA 419", "Online check-in is open for your return flight from Auckland to Wellington. Booking reference {ref}."),
    ("lodge", 3, "Reservation confirmed: 3 nights in Queenstown", "We look forward to welcoming you to Lakefront Lodge. Confirmation {ref}, lake-view king room, check-in from 2 pm. The door code will be sent on the day of arrival."),
    ("rental", 2, "Your rental pick-up details", "Your compact SUV is reserved at Queenstown Airport. Reservation {ref}. Please bring your driver licence and the card used for the booking."),
    ("dental", 3, "Appointment reminder: Dr Morgan Lee", "You have a dental check-up with Dr Morgan Lee. Reply C to confirm. Harbour Street Dental, Lambton Quay."),
    ("bank", 6, "Your verification code", "Your Example Bank verification code is {otp}. It expires in 10 minutes. We will never ask you for this code by phone or e-mail."),
    ("bank", 3, "Your statement is ready", "Your monthly statement for the account ending 4821 is ready to view in online banking."),
    ("isp", 3, "Your invoice is ready", "Your Kōtare Internet invoice for the fibre plan is ready. It will be paid by direct debit on the 20th."),
    ("power", 3, "Your power bill", "Your Northerly Power bill is ready. You used 11% less than the same month last year."),
    ("gym", 3, "Membership renewed", "Your 10-visit concession at Te Aro Climbing Gym has been renewed. New setting on the lead wall this week."),
    ("meetup", 3, "You're in! Design Systems Meetup", "Your ticket for the next Design Systems Meetup is attached. Doors open at 5:30 pm; the talks start at six."),
    ("books", 3, "Your order {ref} has shipped", "Good news — your order {ref} from Kererū Books is on its way. Track it with the link below."),
    ("bikes", 2, "Your bike is ready", "The service on your bike is done: new chain, brake pads and a wheel true. Pick it up from the workshop any time this week."),
    ("property", 2, "Rent review notice", "Please find attached the outcome of the annual rent review for the flat on Aro Street."),
    ("news", 2, "Slow News Weekly #{n}: the week in review", "This week: the harbour ferry timetable changes, a long read on kākā in the city, and why the wind is not actually getting worse."),
    ("news", 2, "Slow News Weekly #{n}: small-town libraries", "This week: how three small-town libraries stayed open, the case for slower trains, and a recipe that takes all Sunday."),
    ("news", 2, "Slow News Weekly #{n}: the long way round", "This week: walking the length of a river, what a tide table can tell you, and letters from readers about bread."),
    ("weather", 2, "Windy City Weather Digest: southerly on the way", "A southerly change arrives on Friday afternoon. Gusts of 90 km/h in exposed places; settled and clear for the weekend."),
    ("weather", 2, "Windy City Weather Digest: a settled week", "High pressure sits over the country until Thursday. Light northerlies, cool mornings, and a good weekend for the hills."),
    ("weather", 1, "Windy City Weather Digest: heavy rain watch", "A front moves up the island overnight. Heavy rain for the ranges from midnight, easing by lunchtime; rivers will rise quickly."),
    ("filmsoc", 3, "This month at the Film Society", "Four screenings this month, including a restored silent classic with a live score."),
    ("council", 2, "Your rates instalment is due", "Your next rates instalment is due at the end of the month. You can pay online with the link below."),
    ("accounts", 4, "Reset your password", "We received a request to reset the password for robin@example.com. The link below is valid for one hour. If this wasn't you, ignore this message."),
    ("accounts", 3, "New sign-in to your account", "Your account was signed in to from a new Mac in Wellington. If this was you, there is nothing to do."),
    ("venue", 3, "Your tickets: Marlow Quartet — Late Set", "Two tickets for the Marlow Quartet at The Blue Note Room. Add them to Wallet with the attached pass. Doors 7:30 pm."),
    ("ferry", 2, "Booking confirmed: Wellington to Picton", "Your sailing is confirmed. Reference {ref}. Vehicle check-in closes one hour before departure."),
]

#: Mail the persona sends: (from address index, subject, body).
SENT_TEMPLATES = [
    (1, "Re: Design review moved to Thursday", "Thursday at two works for me. I'll bring the revised onboarding flow and the open questions from research."),
    (1, "Onboarding flow prototype", "Here's the latest prototype. The empty states are new — I'd love a critical eye on the copy."),
    (1, "Re: Sprint planning agenda", "Could we add twenty minutes for the settings redesign? I have three options to walk through."),
    (1, "Notes from the research readout", "My takeaways from Nina's readout, and what I think they mean for the settings page."),
    (0, "Re: Sunday lunch?", "We'll be on the 11:44. Alex is bringing dessert, I'm bringing the pavlova tin."),
    (0, "Re: Birthday plans", "Booked for eight at Tūī & Fern, 7 pm on the Saturday. I'll sort a cake."),
    (0, "Re: Tararua trip gear list", "I have spare gaiters and the second stove. Will check the forecast again on Thursday."),
    (0, "Re: Flat inspection", "The morning of the 14th is fine. The spare key is with the neighbour."),
    (0, "Re: Queenstown itinerary", "References match. I've added the car pick-up time to the calendar."),
    (0, "Print swap", "Bringing the Oriental Bay prints on Wednesday — do you want the wharf one framed?"),
    (0, "Re: Hurricanes tickets", "We're in. See you at the station at six — I'll bring the scarves."),
    (0, "Re: Makara Peak on Sunday?", "Yes please to the hardtail. Mine is at Pōneke Bikes until Tuesday."),
    (0, "Re: Book club pick", "No veto from me, as long as it's under five hundred pages this time."),
    (0, "Hut booking for the Tararuas", "I've paid for two bunks on Saturday night. Confirmation is in the shared note with the gear list."),
    (0, "Re: Appointment reminder", "Confirming my check-up with Dr Lee. Could I have the 8:30 slot rather than 9:10?"),
    (1, "Research plan, round two", "Draft plan for the second round of interviews. Five participants, forty-five minutes each, same prototype with the new settings page."),
    (1, "Re: Roadmap for next quarter", "Sizing looks right to me except the dashboard — I'd call that a large, not a medium. Notes inline."),
    (1, "Re: Dashboard numbers for the quarterly review", "Let's keep the activation cohort chart and the retention curve. The funnel one needs a clearer title."),
    (1, "Design Systems Meetup: speaker notes", "Outline for my ten minutes on empty states. Would love a dry run with the team on Friday."),
]


def _author(name: str, address: str) -> str:
    return f"|{name}|{address}|0"


def _suggestions(root: pathlib.Path, persona: Persona, rng: random.Random, clock: lib.Clock,
                 senders: dict[str, dict], pseudo: list[dict], places: dict[str, _Place]) -> None:
    owner = persona.owner
    build = persona.this_mac.os_build
    entities: list[dict] = []
    tags: list[tuple] = []
    references: list[tuple] = []
    infos: list[tuple] = []
    details: list[tuple] = []
    events: list[dict] = []
    event_tags: list[tuple] = []
    locations: list[tuple] = []
    emails: list[dict] = []
    email_tags: list[tuple] = []
    urls: list[tuple] = []
    entity_snippets: list[tuple] = []
    mail_snippets: list[tuple] = []

    def hash_hex() -> str:
        return lib.hex_string(rng, 40)

    def add_entity(kind: int, title: str, created: datetime.datetime, *, start=None, end=None, author: str = None,
                   last_seen: datetime.datetime = None, content: str = None) -> dict:
        entity = {
            "id": len(entities) + 1, "entityKey": f"{kind}|{lib.uuid_string(rng)}", "entityType": kind, "author": author,
            "content": content, "title": title, "timeRangeStart": lib.unix(start) if start else None,
            "timeRangeEnd": lib.unix(end) if end else None, "floatingRange": 0,
            "timeRangeStartUTCOffsetSeconds": int(persona.tz_offset_hours * 3600) if start else None,
            "timeRangeEndUTCOffsetSeconds": int(persona.tz_offset_hours * 3600) if end else None,
            "creationTimestamp": round(lib.unix(created), 3), "updateTimestamp": round(lib.unix(created), 3),
            "indexTimestamp": round(lib.unix(created) + rng.uniform(1, 240), 3),
            "lastSeenTimestamp": round(lib.unix(last_seen or created), 3), "quality": round(rng.uniform(0.6, 1.0), 3),
            "state": 0, "contentHash": hash_hex(), "harvestedOnBuild": build,
        }
        entities.append(entity)
        return entity

    def tag(entity: dict, value: str) -> None:
        tags.append((value, entity["entityKey"], entity["entityType"], None, hash_hex(), None))

    def message_ref() -> str:
        return str(rng.randint(20_000, 99_999))

    # --- E-mail metadata, own addresses, mail snippets ---------------------------------------
    def add_email(author: str, when: datetime.datetime, sent: bool, subject: str, body: str, snippet: bool) -> int:
        key = f"5|{lib.uuid_string(rng)}"
        email_id = len(emails) + 1
        stamp = round(lib.unix(when), 3)
        emails.append({"id": email_id, "key": key, "type": 5, "sourceKey": None, "author": author, "creationTimestamp": stamp,
                       "updateTimestamp": stamp, "indexTimestamp": stamp + 30, "lastSeenTimestamp": stamp, "state": 0,
                       "harvestedOnBuild": build})
        email_tags.append((key, 5, "fullyDissected"))
        if sent:
            email_tags.append((key, 5, "isSent"))
        if author.endswith("|1"):
            email_tags.append((key, 5, "inhuman"))
        if snippet:
            mail_snippets.append((email_id, subject, body))
        return email_id

    template_weights = [t[1] for t in MAIL_TEMPLATES]
    mail_items: list[tuple] = []      # (when, author, sent, subject, body, template)
    for _ in range(330):
        index = rng.choices(range(len(MAIL_TEMPLATES)), weights=template_weights)[0]
        key, _, subject, body = MAIL_TEMPLATES[index]
        if key in senders:
            sender = senders[key]
            author = f"|{sender['name']}|{sender['email']}|1"
            when = _moment(clock, rng, 420, weekend=0.7)
        else:
            person = persona.person(key)
            author = _author(person.full_name, person.email)
            when = _moment(clock, rng, 420, weekend=0.5 if person.organization == persona.company else 1.0)
        weeks_ago = int((clock.now - when).total_seconds() // (7 * 86_400))
        values = {"ref": "".join(rng.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(6)),
                  "otp": f"{rng.randint(100, 999)} {rng.randint(100, 999)}", "n": 288 - weeks_ago}
        subject, body = subject.format(**values), body.format(**values)
        mail_items.append((when, author, False, subject, body, index))
    for address, count in ((0, 96), (1, 61)):
        choices = [(i, t) for i, t in enumerate(SENT_TEMPLATES) if t[0] == address]
        for _ in range(count):
            index, (_, subject, body) = rng.choice(choices)
            when = _moment(clock, rng, 420, weekend=0.4 if address else 1.0)
            mail_items.append((when, _author(owner.full_name, owner.emails[address]), True, subject, body, 1000 + index))
    mail_items.sort(key=lambda item: item[0])
    # A summary excerpt is kept for the most recent few messages of each kind.
    kept: dict[int, int] = {}
    with_snippet: set[int] = set()
    for position in range(len(mail_items) - 1, -1, -1):
        template = mail_items[position][5]
        if kept.get(template, 0) < 3:
            kept[template] = kept.get(template, 0) + 1
            with_snippet.add(position)
    for position, (when, author, sent, subject, body, _) in enumerate(mail_items):
        add_email(author, when, sent, subject, body, position in with_snippet)

    # --- Pseudo-contacts -------------------------------------------------------------------------
    def add_contact(name: str, values: list[tuple[str, str]], created: datetime.datetime, last_seen: datetime.datetime,
                    signature: str, domain: str) -> None:
        entity = add_entity(4, name, created, last_seen=last_seen)
        for value, label in values:
            infos.append((len(infos) + 1, rng.choice([0, 2]), 3, round(rng.uniform(0.62, 0.99), 2)))
            # type: 2 for e-mail addresses, 0 otherwise (the two codes the real table uses; the
            # assignment is a guess).
            details.append((len(details) + 1, value, 2 if "@" in value else 0, label, entity["id"], hash_hex(), None, len(infos)))
        for _ in range(rng.randint(1, 3)):
            references.append((len(references) + 1, MAIL, message_ref(), entity["id"], None))
        tag(entity, "AMSG:" + message_ref())
        tag(entity, "MBOX:INBOX")
        tag(entity, "ID:" + hash_hex()[:16])
        for value, _ in values:
            tag(entity, "CD:" + value)
        if signature and rng.random() < 0.8:
            entity_snippets.append((entity["id"], name, signature))

    for index, contact in enumerate(pseudo):
        created = _moment(clock, rng, 400)
        last = min(clock.ago(minutes=rng.randint(40, 6000), seconds=rng.randrange(60)), created + datetime.timedelta(days=rng.uniform(0, 160)))
        values = [(contact["email"], "work" if contact["org"] else "home")]
        if contact["phone"]:
            values.append((_pretty_phone(contact["phone"]), "mobile" if not contact["org"] else "work"))
        if contact["address"]:
            values.append((contact["address"], "work"))
        lines = [rng.choice(["Cheers,", "Ngā mihi,", "Kind regards,", "Thanks,", "All the best,"]), contact["name"]]
        if contact["role"]:
            lines.append(contact["role"] + (", " + contact["org"] if contact["org"] else ""))
        if contact["phone"]:
            lines.append(_pretty_phone(contact["phone"]))
        lines.append(contact["email"])
        if contact["address"]:
            lines.append(contact["address"])
        add_contact(contact["name"], values, created, last, "\n".join(lines), contact["email"].split("@")[1])

    # --- Events ------------------------------------------------------------------------------------
    tz = datetime.timezone(datetime.timedelta(hours=persona.tz_offset_hours))

    def local(days_from_now: float, hour: int, minute: int = 0) -> datetime.datetime:
        day = (clock.now.astimezone(tz) + datetime.timedelta(days=days_from_now)).replace(hour=hour, minute=minute, second=0, microsecond=0)
        return day.astimezone(UTC)

    def iso_local(value: datetime.datetime) -> str:
        return value.astimezone(tz).replace(microsecond=0).isoformat()

    def add_event(title: str, start: datetime.datetime, end: datetime.datetime, category: str, *, sender_key: str = None,
                  schema: dict = None, where: list[tuple] = (), content: str = None, flags: list[str] = (),
                  app: str = None, ics_from: Person = None, extracted_days_before: float = None) -> None:
        lead = extracted_days_before if extracted_days_before is not None else rng.uniform(3, 40)
        created = min(clock.ago(minutes=rng.randint(30, 4000)), start - datetime.timedelta(days=lead))
        entity = add_entity(2, title, created, start=start, end=end, content=content)
        event_id = len(events) + 1
        events.append({"id": event_id, "entityId": entity["id"], "duplicateKey": hash_hex(), "sourceKey": None, "title": title,
                       "content": content, "creationTimestamp": int(lib.unix(created)), "lastModifiedTimestamp": int(lib.unix(created)),
                       "whenRange": f"{int(lib.unix(start))}-{int(lib.unix(end))}", "state": 1, "curated": 0})
        names = ["EX:" + category, "EHSH:" + hash_hex()[:24], "EVNTC:1"]
        if sender_key:
            names += ["DOM:" + senders[sender_key]["email"].split("@")[1], "AMSG:" + message_ref(), "MBOX:INBOX",
                      "TMPN:" + category + "." + _slug(senders[sender_key]["org"])]
        if app:
            names += ["IBID:" + app, "ITID:0000000000", "IUID:" + lib.uuid_string(rng), "fromInteraction"]
        names += list(flags)
        if schema:
            names.append("SO:" + json.dumps([schema], ensure_ascii=False, separators=(",", ":")))
            # Extraction metadata: the key spelling follows the reader (SGEventMetadata…Key);
            # which keys exist is invented.
            names.append("EM:" + json.dumps({"SGEventMetadataCategoryKey": category, "SGEventMetadataConfidenceKey": round(rng.uniform(0.81, 0.99), 2),
                                             "SGEventMetadataTemplateKey": _slug(senders[sender_key]["org"]) if sender_key else "generic"},
                                            ensure_ascii=False, separators=(",", ":")))
        if ics_from is not None:
            uid = lib.uuid_string(rng)
            ics = "\r\n".join([
                "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example Calendar//EN", "METHOD:REQUEST", "BEGIN:VEVENT",
                "UID:" + uid, "SUMMARY:" + title, "DTSTART:" + start.strftime("%Y%m%dT%H%M%SZ"), "DTEND:" + end.strftime("%Y%m%dT%H%M%SZ"),
                f"ORGANIZER;CN={ics_from.full_name}:mailto:{ics_from.email}",
                f"ATTENDEE;CN={owner.full_name};PARTSTAT=NEEDS-ACTION:mailto:{owner.emails[1]}",
                "LOCATION:" + (where[0][0] if where else ""), "STATUS:" + ("CANCELLED" if "cancel" in flags else "CONFIRMED"),
                "END:VEVENT", "END:VCALENDAR", ""])
            names += ["ics", "ICSD:" + base64.b64encode(ics.encode("utf-8")).decode("ascii"), "DOM:" + ics_from.email.split("@")[1]]
        for name in names:
            event_tags.append((len(event_tags) + 1, event_id, name))
        for label, address, airport, lat, lon in where:
            locations.append((len(locations) + 1, 0, label, address, airport, lat, lon, 50.0, 0.9, None, event_id))
        if content and rng.random() < 0.7:
            entity_snippets.append((entity["id"], title, content))

    def person_ref(name: str) -> dict:
        return {"@type": "Person", "name": name}

    wlg = places["airport"]
    airport_wlg = ("Wellington Airport", "Stewart Duff Drive, Wellington 6022", "WLG", wlg.lat, wlg.lon)
    airport_akl = ("Auckland Airport", "Ray Emery Drive, Māngere, Auckland 2022", "AKL", -37.0082, 174.7850)
    airport_zqn = ("Queenstown Airport", "Sir Henry Wigley Drive, Frankton 9300", "ZQN", -45.0211, 168.7392)

    def flight(title: str, number: str, origin: tuple, destination: tuple, depart: datetime.datetime, minutes: int, ref: str,
               seat: str, flags: list[str] = ()) -> None:
        arrive = depart + datetime.timedelta(minutes=minutes)
        schema = {"@context": "http://schema.org", "@type": "FlightReservation", "reservationId": ref,
                  "reservationStatus": "http://schema.org/" + ("ReservationCancelled" if "cancel" in flags else "ReservationConfirmed"),
                  "underName": person_ref(owner.full_name),
                  "reservationFor": {"@type": "Flight", "flightNumber": number, "airline": {"@type": "Airline", "name": "Kea Air", "iataCode": "KEA"},
                                     "departureAirport": {"@type": "Airport", "name": origin[0], "iataCode": origin[2]},
                                     "arrivalAirport": {"@type": "Airport", "name": destination[0], "iataCode": destination[2]},
                                     "departureTime": iso_local(depart), "arrivalTime": iso_local(arrive)},
                  "airplaneSeat": seat, "airplaneSeatClass": {"@type": "AirplaneSeatClass", "name": "Economy"}, "boardingGroup": "B"}
        add_event(title, depart, arrive, "flight", sender_key="kea", schema=schema, where=[origin, destination], flags=flags,
                  content=f"Booking reference {ref}. {owner.full_name}, flight KEA {number}, seat {seat}. Bag drop closes 30 minutes before departure.")

    flight("Flight KEA 412 to Auckland", "412", airport_wlg, airport_akl, local(-86, 7, 10), 65, "KEA7QX", "14C")
    flight("Flight KEA 419 to Wellington", "419", airport_akl, airport_wlg, local(-83, 18, 40), 65, "KEA7QX", "9A")
    flight("Flight KEA 271 to Queenstown", "271", airport_wlg, airport_zqn, local(-214, 9, 25), 95, "KEA3MN", "21F")
    flight("Flight KEA 278 to Wellington", "278", airport_zqn, airport_wlg, local(-209, 15, 5), 95, "KEA3MN", "17D")
    flight("Flight KEA 412 to Auckland", "412", airport_wlg, airport_akl, local(19, 7, 10), 65, "KEA9RT", "12A")
    flight("Flight KEA 425 to Wellington", "425", airport_akl, airport_wlg, local(21, 19, 55), 65, "KEA9RT", "12B")
    flight("Flight KEA 530 to Christchurch", "530", airport_wlg, ("Christchurch Airport", "Memorial Avenue, Harewood, Christchurch 8053", "CHC", -43.4864, 172.5369),
           local(-130, 6, 45), 55, "KEA5PL", "4C", flags=["cancel"])

    lodge = {"@context": "http://schema.org", "@type": "LodgingReservation", "reservationId": "LL-204817", "reservationStatus": "http://schema.org/ReservationConfirmed",
             "underName": person_ref(owner.full_name), "checkinTime": iso_local(local(-214, 14)), "checkoutTime": iso_local(local(-211, 10)),
             "reservationFor": {"@type": "LodgingBusiness", "name": "Lakefront Lodge", "telephone": _pretty_phone(senders["lodge"]["phone"]),
                                "address": {"@type": "PostalAddress", "streetAddress": "Lake Esplanade", "addressLocality": "Queenstown", "postalCode": "9300", "addressCountry": "NZ"}},
             "lodgingUnitDescription": "Lake-view king room", "numAdults": 2}
    add_event("Stay at Lakefront Lodge", local(-214, 14), local(-211, 10), "hotel", sender_key="lodge", schema=lodge, flags=["allDay"],
              where=[("Lakefront Lodge", "Lake Esplanade, Queenstown 9300", None, -45.0336, 168.6535)],
              content="Confirmation LL-204817, lake-view king room, three nights. Check-in from 2 pm. The door code will be sent on the day of arrival.")
    car = {"@context": "http://schema.org", "@type": "RentalCarReservation", "reservationId": "TCR-88213", "reservationStatus": "http://schema.org/ReservationConfirmed",
           "underName": person_ref(owner.full_name), "pickupTime": iso_local(local(-214, 11, 30)), "dropoffTime": iso_local(local(-209, 13, 30)),
           "reservationFor": {"@type": "RentalCar", "name": "Compact SUV", "rentalCompany": {"@type": "Organization", "name": "Tussock Car Rentals"}},
           "pickupLocation": {"@type": "Place", "name": "Queenstown Airport"}, "dropoffLocation": {"@type": "Place", "name": "Queenstown Airport"}}
    add_event("Car rental: Tussock Car Rentals", local(-214, 11, 30), local(-209, 13, 30), "carRental", sender_key="rental", schema=car,
              where=[("Pick-up: Queenstown Airport", "Sir Henry Wigley Drive, Frankton 9300", None, airport_zqn[3], airport_zqn[4])],
              content="Reservation TCR-88213. Compact SUV, pick-up at Queenstown Airport. Please bring your driver licence and the card used for the booking.")
    cafe = places["cafe"]
    for offset, people, name in ((-52, 8, "Jamie's birthday dinner"), (12, 2, "Dinner at Tūī & Fern Café"), (-163, 4, "Dinner at Tūī & Fern Café")):
        start = local(offset, 19)
        schema = {"@context": "http://schema.org", "@type": "FoodEstablishmentReservation", "reservationId": f"TF-{rng.randint(1000, 9999)}",
                  "reservationStatus": "http://schema.org/ReservationConfirmed", "underName": person_ref(owner.full_name), "startTime": iso_local(start), "partySize": people,
                  "reservationFor": {"@type": "FoodEstablishment", "name": "Tūī & Fern Café",
                                     "address": {"@type": "PostalAddress", "streetAddress": "Cuba Street", "addressLocality": "Wellington", "postalCode": "6011", "addressCountry": "NZ"}}}
        add_event(name, start, start + datetime.timedelta(hours=2), "restaurant", schema=schema, app="com.apple.mobilesafari",
                  where=[("Tūī & Fern Café", "Cuba Street, Te Aro, Wellington 6011", None, cafe.lat, cafe.lon)],
                  content=f"Table for {people} at Tūī & Fern Café. We hold tables for 15 minutes.")
    work = places["work"]
    for offset in (-171, 9):
        start = local(offset, 8, 30)
        add_event("Dental check-up: Dr Morgan Lee", start, start + datetime.timedelta(minutes=40), "appointment", sender_key="dental",
                  where=[("Harbour Street Dental", "Lambton Quay, Wellington 6011", None, work.lat - 0.0011, work.lon + 0.0004)],
                  content="Check-up with Dr Morgan Lee at Harbour Street Dental. Reply C to confirm or call reception to reschedule.")
    concert = local(-24, 20)
    ticket = {"@context": "http://schema.org", "@type": "EventReservation", "reservationId": "BNR-55102", "reservationStatus": "http://schema.org/ReservationConfirmed",
              "underName": person_ref(owner.full_name), "numSeats": 2,
              "reservationFor": {"@type": "MusicEvent", "name": "Marlow Quartet — Late Set", "startDate": iso_local(concert),
                                 "location": {"@type": "Place", "name": "The Blue Note Room",
                                              "address": {"@type": "PostalAddress", "streetAddress": "Cuba Street", "addressLocality": "Wellington", "addressCountry": "NZ"}}},
              "reservedTicket": {"@type": "Ticket", "ticketNumber": "BNR-55102-1", "ticketedSeat": {"@type": "Seat", "seatSection": "Floor", "seatRow": "C", "seatNumber": "7"}}}
    add_event("Marlow Quartet — Late Set", concert, concert + datetime.timedelta(hours=2, minutes=30), "ticket", sender_key="venue", schema=ticket,
              where=[("The Blue Note Room", "Cuba Street, Te Aro, Wellington 6011", None, cafe.lat + 0.0013, cafe.lon - 0.0002)],
              content="Two tickets, floor row C seats 7 and 8. Doors 7:30 pm. Add the attached pass to Wallet.")
    meetup = local(6, 17, 30)
    add_event("Design Systems Meetup", meetup, meetup + datetime.timedelta(hours=3), "ticket", sender_key="meetup",
              where=[("Kōwhai Labs", "Lambton Quay, Wellington 6011", None, work.lat, work.lon)],
              content="Your ticket for the Design Systems Meetup. Doors open at 5:30 pm; the talks start at six.")
    sailing = local(-395, 8, 45)
    ferry = {"@context": "http://schema.org", "@type": "BoatReservation", "reservationId": "SC-730914", "reservationStatus": "http://schema.org/ReservationConfirmed",
             "underName": person_ref(owner.full_name),
             "reservationFor": {"@type": "BoatTrip", "name": "Wellington to Picton", "departureTime": iso_local(sailing), "arrivalTime": iso_local(sailing + datetime.timedelta(hours=3, minutes=30)),
                                "departureBoatTerminal": {"@type": "BoatTerminal", "name": "Wellington Ferry Terminal"}, "arrivalBoatTerminal": {"@type": "BoatTerminal", "name": "Picton Ferry Terminal"}}}
    add_event("Ferry: Wellington to Picton", sailing, sailing + datetime.timedelta(hours=3, minutes=30), "boat", sender_key="ferry", schema=ferry,
              where=[("Wellington Ferry Terminal", "Waterloo Quay, Wellington 6011", None, -41.2793, 174.7836), ("Picton Ferry Terminal", "Auckland Street, Picton 7220", None, -41.2860, 174.0050)],
              content="Reference SC-730914. One vehicle, two adults. Vehicle check-in closes one hour before departure.")
    hut = local(-141, 15)
    add_event("Hut booking: Tararua Forest Park", hut, hut + datetime.timedelta(hours=19), "hotel", app="com.apple.mobilesafari", flags=["fromSync"],
              content="Two bunks booked for Saturday night. Carry out what you carry in.")
    film = local(-9, 18, 15)
    add_event("Film Society screening", film, film + datetime.timedelta(hours=2), "movie", sender_key="filmsoc", flags=["fromSync"],
              content="A restored silent classic with a live score. Members free; doors at 6 pm.")
    train = local(3, 11, 44)
    add_event("Train to Paraparaumu", train, train + datetime.timedelta(minutes=54), "train", app="com.apple.Maps",
              where=[("Wellington Railway Station", "Bunny Street, Wellington 6011", None, places["station"].lat, places["station"].lon)])
    # Calendar invitations from colleagues.
    invitations = [("Design Review", "aroha", 60), ("Sprint Planning", "oliver", 60), ("Research Readout", "nina", 45),
                   ("Onboarding Flow: critique", "lucas", 45), ("Quarterly Review", "hana", 90), ("1:1 Aroha / Robin", "aroha", 30)]
    for index in range(22):
        title, organiser, minutes = invitations[index % len(invitations)]
        offset = rng.randint(-150, 13)
        start = local(offset, rng.choice([9, 10, 11, 13, 14, 15, 16]), rng.choice([0, 30]))
        if start.astimezone(tz).weekday() >= 5:
            start += 2 * DAY
        add_event(title, start, start + datetime.timedelta(minutes=minutes), "calendar", ics_from=persona.person(organiser),
                  where=[("Kōwhai Labs", "Lambton Quay, Wellington 6011", None, work.lat, work.lon)],
                  flags=["cancel"] if index in (5, 14) else [], extracted_days_before=rng.uniform(1, 9))

    # --- Wallet passes ---------------------------------------------------------------------------------
    def add_pass(title: str, created: datetime.datetime, sender_key: str, pass_json: dict, state: str, colours: tuple) -> None:
        entity = add_entity(26, title, created)
        archive = io.BytesIO()
        stamp = created.astimezone(UTC)
        zip_time = (stamp.year, stamp.month, stamp.day, stamp.hour, stamp.minute, stamp.second - stamp.second % 2)
        logo = _png(58, 58, colours[0], colours[1])
        files = {
            "pass.json": json.dumps(pass_json, ensure_ascii=False, indent=1).encode("utf-8"),
            "logo.png": logo, "logo@2x.png": _png(116, 116, colours[0], colours[1]), "icon.png": _png(29, 29, colours[0], colours[1]),
        }
        manifest = {name: lib.hex_string(rng, 40) for name in files}
        files["manifest.json"] = json.dumps(manifest, indent=1).encode("utf-8")
        files["signature"] = b"DEMO SIGNATURE - not a real PKCS#7 signature\n" + rng.getrandbits(8 * 1536).to_bytes(1536, "big")
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
            for name, data in files.items():
                info = zipfile.ZipInfo(name, date_time=zip_time)
                info.compress_type = zipfile.ZIP_STORED if name == "signature" else zipfile.ZIP_DEFLATED
                info.external_attr = 0o644 << 16
                bundle.writestr(info, data)
        # WPDD summary keys per SuggestionsStore.passes; the passState suffixes are invented.
        summary = {"name": title, "organization": pass_json["organizationName"], "description": pass_json["description"],
                   "passState": "SGRealtimeWalletPassState" + state, "serial": pass_json["serialNumber"],
                   "url": f"https://{senders[sender_key]['email'].split('@')[1]}/passes/{pass_json['serialNumber']}.pkpass"}
        tag(entity, "WPDD:" + json.dumps(summary, ensure_ascii=False, separators=(",", ":")))
        tag(entity, "WPD:" + base64.b64encode(archive.getvalue()).decode("ascii"))
        tag(entity, "AMSG:" + message_ref())
        tag(entity, "MBOX:INBOX")
        references.append((len(references) + 1, MAIL, message_ref(), entity["id"], None))

    def pass_base(sender_key: str, type_suffix: str, serial: str, description: str, background: str, foreground: str, label: str) -> dict:
        return {"formatVersion": 1, "passTypeIdentifier": "pass.example." + type_suffix, "serialNumber": serial, "teamIdentifier": "DEMO0TEAM1",
                "organizationName": senders[sender_key]["org"], "description": description, "logoText": senders[sender_key]["org"],
                "backgroundColor": background, "foregroundColor": foreground, "labelColor": label,
                "webServiceURL": f"https://{senders[sender_key]['email'].split('@')[1]}/wallet/v1",
                "authenticationToken": lib.hex_string(rng, 32)}

    def boarding(number: str, origin: tuple, destination: tuple, depart: datetime.datetime, ref: str, seat: str, sequence: int) -> dict:
        body = pass_base("kea", "keaair.boarding", f"KEA-{ref}-{number}", f"Kea Air boarding pass {origin[2]}–{destination[2]}", "rgb(0, 92, 84)", "rgb(255, 255, 255)", "rgb(186, 230, 220)")
        body.update({
            "relevantDate": iso_local(depart), "expirationDate": iso_local(depart + DAY),
            "boardingPass": {"transitType": "PKTransitTypeAir",
                             "headerFields": [{"key": "gate", "label": "GATE", "value": str(rng.randint(12, 31))}, {"key": "flight", "label": "FLIGHT", "value": "KEA " + number}],
                             "primaryFields": [{"key": "origin", "label": origin[0].replace(" Airport", ""), "value": origin[2]},
                                               {"key": "destination", "label": destination[0].replace(" Airport", ""), "value": destination[2]}],
                             "secondaryFields": [{"key": "passenger", "label": "PASSENGER", "value": owner.full_name.upper()},
                                                 {"key": "boards", "label": "BOARDS", "value": (depart - datetime.timedelta(minutes=30)).astimezone(tz).strftime("%H:%M")}],
                             "auxiliaryFields": [{"key": "seat", "label": "SEAT", "value": seat}, {"key": "group", "label": "GROUP", "value": "B"},
                                                 {"key": "class", "label": "CLASS", "value": "Economy"}, {"key": "sequence", "label": "SEQ", "value": f"{sequence:03d}"}],
                             "backFields": [{"key": "ref", "label": "Booking reference", "value": ref},
                                            {"key": "ffn", "label": "Frequent flyer", "value": "KEA Flock 4410 2287 31"},
                                            {"key": "terms", "label": "Conditions", "value": "Bag drop closes 30 minutes before departure. Photo ID is required."}]},
            "barcodes": [{"format": "PKBarcodeFormatAztec", "messageEncoding": "iso-8859-1",
                          "message": f"M1{owner.family.upper()}/{owner.given.upper():<14}E{ref} {origin[2]}{destination[2]}KEA {int(number):04d} {depart.astimezone(tz).timetuple().tm_yday:03d}Y{seat:>04}{sequence:04d} 100"}],
            "locations": [{"latitude": origin[3], "longitude": origin[4], "relevantText": f"Flight KEA {number} departs from {origin[0]}"}],
        })
        return body

    add_pass("Kea Air — WLG to AKL", local(-87, 16, 12), "kea", boarding("412", airport_wlg, airport_akl, local(-86, 7, 10), "KEA7QX", "14C", 41), "Expired", ((0, 92, 84), (255, 255, 255)))
    add_pass("Kea Air — AKL to WLG", local(-84, 18, 44), "kea", boarding("419", airport_akl, airport_wlg, local(-83, 18, 40), "KEA7QX", "9A", 87), "Expired", ((0, 92, 84), (255, 255, 255)))
    add_pass("Kea Air — WLG to ZQN", local(-215, 9, 31), "kea", boarding("271", airport_wlg, airport_zqn, local(-214, 9, 25), "KEA3MN", "21F", 63), "Expired", ((0, 92, 84), (255, 255, 255)))
    add_pass("Kea Air — WLG to AKL", clock.at(2, 16, 12, 41), "kea", boarding("412", airport_wlg, airport_akl, local(19, 7, 10), "KEA9RT", "12A", 12), "Active", ((0, 92, 84), (255, 255, 255)))

    body = pass_base("venue", "bluenoteroom.ticket", "BNR-55102-1", "Marlow Quartet — Late Set", "rgb(24, 28, 58)", "rgb(255, 255, 255)", "rgb(255, 200, 92)")
    body.update({"relevantDate": iso_local(concert), "eventTicket": {
        "headerFields": [{"key": "doors", "label": "DOORS", "value": "19:30"}],
        "primaryFields": [{"key": "event", "label": "THE BLUE NOTE ROOM", "value": "Marlow Quartet"}],
        "secondaryFields": [{"key": "name", "label": "NAME", "value": owner.full_name}, {"key": "section", "label": "SECTION", "value": "Floor"}],
        "auxiliaryFields": [{"key": "row", "label": "ROW", "value": "C"}, {"key": "seat", "label": "SEAT", "value": "7"}],
        "backFields": [{"key": "order", "label": "Order", "value": "BNR-55102"}, {"key": "terms", "label": "Conditions", "value": "No re-entry after the second set."}]},
        "barcodes": [{"format": "PKBarcodeFormatQR", "messageEncoding": "iso-8859-1", "message": "BNR|55102|1|C7|" + lib.hex_string(rng, 16)}],
        "locations": [{"latitude": cafe.lat + 0.0013, "longitude": cafe.lon - 0.0002, "relevantText": "The Blue Note Room"}]})
    add_pass("Marlow Quartet — Late Set", local(-31, 12, 5), "venue", body, "Expired", ((24, 28, 58), (255, 200, 92)))

    body = pass_base("gym", "tearoclimbing.membership", "TACG-204417", "Te Aro Climbing Gym concession card", "rgb(214, 86, 43)", "rgb(255, 255, 255)", "rgb(255, 226, 205)")
    body.update({"storeCard": {
        "headerFields": [{"key": "visits", "label": "VISITS LEFT", "value": 7}],
        "primaryFields": [{"key": "member", "label": "MEMBER", "value": owner.full_name}],
        "secondaryFields": [{"key": "type", "label": "CARD", "value": "10-visit concession"}, {"key": "number", "label": "NUMBER", "value": "204417"}],
        "backFields": [{"key": "waiver", "label": "Waiver", "value": "Signed"}, {"key": "contact", "label": "Front desk", "value": _pretty_phone(senders["gym"]["phone"])}]},
        "barcodes": [{"format": "PKBarcodeFormatCode128", "messageEncoding": "iso-8859-1", "message": "TACG204417"}],
        "locations": [{"latitude": places["gym"].lat, "longitude": places["gym"].lon, "relevantText": "Te Aro Climbing Gym"}]})
    add_pass("Te Aro Climbing Gym", local(-118, 17, 40), "gym", body, "Active", ((214, 86, 43), (255, 255, 255)))

    body = pass_base("meetup", "dsmeetup.ticket", "DSM-" + lib.hex_string(rng, 8).upper(), "Design Systems Meetup ticket", "rgb(250, 248, 240)", "rgb(30, 30, 30)", "rgb(120, 110, 90)")
    body.update({"relevantDate": iso_local(meetup), "eventTicket": {
        "primaryFields": [{"key": "event", "label": "MEETUP", "value": "Design Systems Meetup"}],
        "secondaryFields": [{"key": "name", "label": "ATTENDEE", "value": owner.full_name}, {"key": "org", "label": "COMPANY", "value": persona.company}],
        "auxiliaryFields": [{"key": "doors", "label": "DOORS", "value": "17:30"}, {"key": "type", "label": "TICKET", "value": "General"}],
        "backFields": [{"key": "host", "label": "Hosted by", "value": persona.company + ", Lambton Quay"}]},
        "barcodes": [{"format": "PKBarcodeFormatQR", "messageEncoding": "iso-8859-1", "message": "https://dsmeetup.example.org/checkin?ticket=" + lib.hex_string(rng, 20)}]})
    add_pass("Design Systems Meetup", clock.at(4, 10, 3, 27), "meetup", body, "Active", ((250, 248, 240), (60, 60, 60)))

    body = pass_base("books", "kererubooks.coupon", "KB-SPRING-" + lib.hex_string(rng, 6).upper(), "Kererū Books 15% off voucher", "rgb(64, 110, 72)", "rgb(255, 255, 255)", "rgb(214, 236, 214)")
    body.update({"expirationDate": iso_local(local(40, 23, 59)), "coupon": {
        "primaryFields": [{"key": "offer", "label": "ANY PAPERBACK", "value": "15% off"}],
        "secondaryFields": [{"key": "expires", "label": "EXPIRES", "value": local(40, 23, 59).astimezone(tz).strftime("%d %b %Y")}],
        "backFields": [{"key": "terms", "label": "Terms", "value": "One voucher per customer. Not valid with other offers."}]},
        "barcodes": [{"format": "PKBarcodeFormatPDF417", "messageEncoding": "iso-8859-1", "message": "KB15-" + lib.hex_string(rng, 12).upper()}]})
    add_pass("Kererū Books voucher", clock.at(16, 13, 48, 9), "books", body, "Active", ((64, 110, 72), (255, 255, 255)))

    # --- Links -------------------------------------------------------------------------------------------
    def token(length: int = 32) -> str:
        return lib.hex_string(rng, length)

    def add_url(url: str, title: str, when: datetime.datetime, bundle: str, handle: str, document: str, flags: int) -> None:
        stamp = round(lib.unix(when), 3)
        urls.append((len(urls) + 1, url, handle or None, bundle, None, lib.uuid_string(rng), stamp, title, document, stamp, 0, flags))

    plain_links = [
        ("https://en.wikipedia.org/wiki/Tongariro_Alpine_Crossing", "Tongariro Alpine Crossing - Wikipedia"),
        ("https://en.wikipedia.org/wiki/Kererū", "Kererū - Wikipedia"), ("https://en.wikipedia.org/wiki/Typography", "Typography - Wikipedia"),
        ("https://en.wikipedia.org/wiki/Sourdough", "Sourdough - Wikipedia"), ("https://en.wikipedia.org/wiki/Milford_Sound", "Milford Sound - Wikipedia"),
        ("https://en.wikipedia.org/wiki/Wellington_Cable_Car", "Wellington Cable Car - Wikipedia"),
        ("https://www.example.com/recipes/slow-roast-lamb-shoulder", "Slow-roast lamb shoulder"),
        ("https://www.example.com/recipes/sourdough-starter-basics", "Sourdough starter basics"),
        ("https://www.example.net/guides/tararua-southern-crossing", "Tararua Southern Crossing: a two-day guide"),
        ("https://www.example.com/tracks/makara-peak-loop", "Makara Peak loop"), ("https://www.example.org/events/book-club-november", "Book club — November"),
        ("https://design.example.org/articles/empty-states-that-teach", "Empty states that teach"),
        ("https://research.example.org/notes/interview-synthesis-templates", "Interview synthesis templates"),
        ("https://music.example.com/album/late-set-marlow-quartet", "Late Set — Marlow Quartet"),
        ("https://www.example.org/exhibitions/harbour-light-photography", "Harbour Light: photographs of Wellington"),
        ("https://tickets.example.com/hurricanes-home-game", "Hurricanes home game tickets"),
        ("https://stay.example.com/queenstown/lakefront-lodge", "Lakefront Lodge, Queenstown"),
        ("https://www.example.net/garden/planting-calendar-spring", "Spring planting calendar"),
        ("https://windycity.example.net/forecast/wellington/weekend", "Weekend forecast for Wellington"),
        ("https://kererubooks.example.com/staff-picks", "Staff picks — Kererū Books"),
    ]
    for _ in range(150):
        url, title = rng.choice(plain_links)
        person = persona.weighted_person(rng)
        add_url(url, title, _moment(clock, rng, 330, hours=(7, 24)), MESSAGES, person.handle, None, 16)
    mail_links = [
        ("news", "https://slownews.example.org/issues/{n}", "Slow News Weekly #{n}", "Slow News Weekly: the week in review"),
        ("news", "https://slownews.example.org/unsubscribe?token={t}", "Unsubscribe", "Slow News Weekly: the week in review"),
        ("weather", "https://windycity.example.net/digest/{n}", "Read the full forecast", "Windy City Weather Digest"),
        ("books", "https://kererubooks.example.com/track/{T}", "Track your parcel", "Your order has shipped"),
        ("kea", "https://keaair.example.net/manage?ref={T}&code={t8}", "Manage your booking", "Your booking confirmation"),
        ("kea", "https://keaair.example.net/checkin/{T}", "Check in online", "Check in now"),
        ("lodge", "https://lakefrontlodge.example.com/reservations/{n}?confirmation={t8}", "View your reservation", "Reservation confirmed: 3 nights in Queenstown"),
        ("accounts", "https://accounts.example.net/reset?token={t}", "Reset your password", "Reset your password"),
        ("accounts", "https://accounts.example.net/login#access_token={t}", "Sign in with this link", "Your sign-in link"),
        ("bank", "https://bank.example.com/statements/latest", "View your statement", "Your statement is ready"),
        ("meetup", "https://dsmeetup.example.org/checkin?ticket={t}", "Your ticket", "You're in! Design Systems Meetup"),
        ("isp", "https://kotare.example.net/invoices/{n}.pdf?sig={t}", "Download invoice (PDF)", "Your invoice is ready"),
        ("power", "https://northerly.example.org/bills/{n}", "View your bill", "Your power bill"),
        ("council", "https://council.example.org/pay?invoice={n}", "Pay online", "Your rates instalment is due"),
        ("filmsoc", "https://filmsociety.example.org/programme", "This month's programme", "This month at the Film Society"),
        ("venue", "https://bluenoteroom.example.com/orders/{n}?auth={t8}", "View your order", "Your tickets: Marlow Quartet — Late Set"),
        ("gym", "https://tearoclimbing.example.com/account/visits", "Your visits", "Membership renewed"),
    ]
    link_weights = [0.35 if any(mark in url for mark in ("{t}", "{t8}")) else 1.0 for _, url, _, _ in mail_links]
    for _ in range(110):
        key, url, title, subject = rng.choices(mail_links, weights=link_weights)[0]
        values = {"n": rng.randint(1200, 98000), "t": token(), "t8": token(10), "T": token(8).upper()}
        add_url(url.format(**values), title.format(**values), _moment(clock, rng, 330, weekend=0.6), MAIL, senders[key]["email"], subject, 17)
    meeting_people = persona.people_with("colleague") + persona.people_with("manager")
    for _ in range(14):
        person = rng.choice(meeting_people)
        title = rng.choice(["Design Review", "Sprint Planning", "Research Readout", "1:1", "Quarterly Review"])
        url = f"https://meet.example.org/j/{rng.randint(10**9, 10**10 - 1)}?pwd={token(22)}"
        add_url(url, "Join video meeting", _moment(clock, rng, 200, weekend=0.1, hours=(8, 18)), CALENDAR, person.email, title, 32)
    for _ in range(6):
        person = rng.choice(meeting_people)
        url = f"https://docs.example.org/d/{token(24)}/edit?authkey={token(16)}"
        add_url(url, rng.choice(["Onboarding flow — critique notes", "Roadmap draft", "Research plan, round two"]),
                _moment(clock, rng, 200, weekend=0.2), MAIL, person.email, "Shared document", 17)

    path = lib.library(root, "Suggestions/entities.db")
    with lib.sqlite_db(path, SUGGESTIONS_DDL) as con:
        lib.insert(con, "entity", entities)
        con.executemany("INSERT INTO entityTags VALUES (?, ?, ?, ?, ?, ?)", tags)
        con.executemany("INSERT INTO entityReferences VALUES (?, ?, ?, ?, ?)", references)
        con.executemany("INSERT INTO extractionInfos VALUES (?, ?, ?, ?)", infos)
        con.executemany("INSERT INTO contactDetails VALUES (?, ?, ?, ?, ?, ?, ?, ?)", details)
        lib.insert(con, "events", events)
        con.executemany("INSERT INTO eventTags VALUES (?, ?, ?)", event_tags)
        con.executemany("INSERT INTO locations VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", locations)
        lib.insert(con, "emailMetadata", emails)
        con.executemany("INSERT INTO emailTags VALUES (?, ?, ?)", email_tags)
        con.executemany("INSERT INTO urls VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", urls)
        con.execute("INSERT INTO metadata VALUES ('schemaVersion', 190)")
        con.execute("INSERT INTO integrityCheck VALUES ('ok')")
    with lib.sqlite_db(lib.library(root, "Suggestions/snippets.db"), SNIPPETS_DDL) as con:
        con.executemany("INSERT INTO snippets (entityId, title, content) VALUES (?, ?, ?)", entity_snippets)
        con.executemany("INSERT INTO emailSnippets (emailId, title, content) VALUES (?, ?, ?)", mail_snippets)
        con.execute("INSERT INTO integrityCheck VALUES ('ok')")

    # Name caches: 8-byte header, then `u16 key length, u16 value length, u32 0, key, value`.
    def kvcache(pairs: list[tuple[str, str]]) -> bytes:
        out = bytearray(b"KVC1" + struct.pack("<I", len(pairs)))
        for key, value in pairs:
            k, v = key.encode("utf-8"), value.encode("utf-8")
            out += struct.pack("<HHI", len(k), len(v), 0) + k + v
        return bytes(out)

    by_mail = [(p.email, p.full_name) for p in persona.others if p.email and p.key != "drlee"]
    by_mail += [(s["email"], s["name"]) for s in senders.values()] + [(c["email"], c["name"]) for c in pseudo]
    by_phone = [(p.phone, p.full_name) for p in persona.others if p.phone]
    by_phone += [(c["phone"], c["name"]) for c in pseudo if c["phone"]] + [(s["phone"], s["name"]) for s in senders.values() if s["phone"]]
    lib.write_bytes(lib.library(root, "Suggestions/email-to-name.kvcache"), kvcache(sorted(dict(by_mail).items())))
    lib.write_bytes(lib.library(root, "Suggestions/phone-to-name.kvcache"), kvcache(sorted(dict(by_phone).items())))


# ----------------------------------------------------------------------------------------
# Family Sharing cache
# ----------------------------------------------------------------------------------------

def _family(root: pathlib.Path, persona: Persona, rng: random.Random, clock: lib.Clock) -> None:
    owner, partner, sister, mother = persona.owner, persona.person("partner"), persona.person("sister"), persona.person("mother")
    today = clock.now.astimezone(datetime.timezone(datetime.timedelta(hours=persona.tz_offset_hours))).date()

    def member(person: Person, order: int, joined: datetime.datetime, organizer: bool = False) -> dict:
        y, m, d = person.birthday
        age = today.year - y - ((today.month, today.day) < (m, d))
        dsid = rng.randint(10_000_000_000, 19_999_999_999)
        return {
            "member-first-name": person.given, "member-last-name": person.family, "member-apple-id": person.email,
            "member-appleID-aliases": list(person.emails[1:]), "member-phone-numbers": _pretty_phone(person.phone) if person.phone else "",
            "member-date-of-birth": int(datetime.datetime(y, m, d, tzinfo=UTC).timestamp() * 1000), "member-age": age,
            "member-join-date-epoch": lib.unix_ms(joined), "member-type": "ADULT", "member-type-enum": 1,
            "member-display-label": "Organiser" if organizer else "Adult", "member-status": "Accepted",
            "is-me": person is owner, "member-is-organizer": organizer, "member-is-parent-account": organizer,
            "member-is-child-account": False, "family-purchase-sharing-enabled": person is not sister,
            "is-ask-to-buy-enabled": False, "linked-itunes-account-appleid": person.email, "linked-itunes-account-dsid": dsid,
            "is-itunes-linked": True, "can-remove-self": not organizer, "member-sort-order": order, "member-dsid": dsid,
            "member-altDSID": f"{rng.randint(0, 999999):06d}-{rng.randint(0, 99):02d}-{lib.uuid_string(rng, upper=False)}",
            "member-dsid-hash": lib.hex_string(rng, 40),
        }

    started = clock.at(1163, 20, 14)
    dictionaries = [member(owner, 0, started, organizer=True), member(partner, 1, started + datetime.timedelta(hours=1, minutes=7)),
                    member(sister, 2, clock.at(402, 12, 31))]
    pending = [{"member-first-name": mother.given, "member-last-name": mother.family, "member-invite-email": mother.email,
                "member-type": "ADULT", "member-status": "Pending", "member-display-label": "Invited"}]
    circle = lib.ArchiveObject("FAFamilyCircle", {
        "_members": [lib.ArchiveObject("FAFamilyMember", {"_dictionary": d}) for d in dictionaries],
        "_familyID": str(rng.randint(10_000_000_000, 99_999_999_999)), "_ageCategory": 3, "_canAddMembers": True,
        "_showAddMemberButton": True, "_sharedPayementEnabled": True, "_shouldShowInvites": True, "_childCutOffAge": "13",
        "__serverResponse": {"family-members": dictionaries, "pending-members": pending, "status": 0},
    })
    path = lib.write_bytes(lib.library(root, "DuetExpertCenter/caches/familyCircleCache"), lib.keyed_archive(circle, mutable_collections=True))
    _touch(path, clock.ago(hours=19, minutes=12))


# ----------------------------------------------------------------------------------------
# Speech profile, custom vocabulary, text replacements, keyboard
# ----------------------------------------------------------------------------------------

def _speech(root: pathlib.Path, persona: Persona, rng: random.Random, clock: lib.Clock) -> None:
    """`SpeechProfile` per dictation language. Only the symbol-table entries the reader scans
    for are meaningful (`u32 length | "<word>\\<class>" | u64 id`, spaces as `_`); the bytes
    around them are filler, not a real "Bqsr" container."""
    given = sorted({p.given for p in persona.people} | {p.nickname for p in persona.people if p.nickname})
    family = sorted({p.family for p in persona.people})
    apps = sorted({a.name for a in persona.apps_on("mac")})
    companies = sorted({p.organization for p in persona.people if p.organization} | {"Te Aro Climbing Gym", "Tūī & Fern Café"})
    symbols = ([(w, "contact-first") for w in given] + [(w, "contact-last") for w in family]
               + [(w + "'s", "contact-first-derived") for w in given[:9]] + [(w, "app-first") for w in apps]
               + [(w, "company-first") for w in companies]
               + [(w, "house-first") for w in ["Aro Street"]]
               + [(w, "room-first") for w in ["Living Room", "Bedroom", "Kitchen", "Study", "Hallway"]]
               + [(w, "zone-first") for w in ["Upstairs", "Downstairs"]]
               + [(w, "scene-first") for w in ["Good Morning", "Good Night", "Movie Time", "Leaving Home", "Arriving Home"]]
               + [(w, "device-first") for w in ["Desk Lamp", "Reading Light", "Heat Pump", "Front Door", "Kitchen Speaker", "Hallway Sensor"]])
    base = lib.library(root, "Assistant/SiriVocabulary/Modules/CESR/Default/demo-user")
    for locale, hours in (("en_NZ", 7), ("en_AU", 31)):
        body = bytearray(b"Bqsr" + struct.pack("<II", 1, len(symbols)) + bytes(52))
        for index, (word, category) in enumerate(symbols):
            text = (word.replace(" ", "_") + "\\" + category).encode("utf-8")
            body += struct.pack("<I", len(text)) + text + struct.pack("<Q", 0x4000 + index)
        # Filler standing in for the acoustic data (high bit set: never mistaken for a symbol).
        body += bytes(b | 0x80 for b in rng.getrandbits(8 * 300_000).to_bytes(300_000, "big"))
        path = lib.write_bytes(base / locale / "SpeechProfile", bytes(body))
        _touch(path, clock.ago(hours=hours))
    # Entities with an acoustic embedding (only the keys are read).
    names = [p.full_name for p in persona.others if p.closeness >= 0.45] + [persona.company]
    profile = {"version": 2, "entityToEmbedding": {name: [round(rng.uniform(-1, 1), 4) for _ in range(12)] for name in names}}
    lib.write_text(lib.library(root, "Assistant/SpeechMaintenance/ncbvqprofile"), json.dumps(profile, ensure_ascii=False))

    # Phrases apps registered with Siri.
    vocabulary = lib.library(root, "Assistant/CustomVocabulary")
    registered = [
        ("com.apple.shortcuts", "VoiceCommandNameType", 9,
         ["Start Focus Time", "Morning Briefing", "Text Alex I'm On My Way", "Log a Climb", "Coffee Order", "Next Train to Paraparaumu",
          "Resize Screenshots", "Standup Notes", "Hut Booking Checklist", "Wind Check"]),
        ("net.whatsapp.WhatsApp", "ContactGroupNameType", 3, ["Sample Whānau", "Tararua Crew", "Flat Aro Street", "Climbing Thursdays", "Book Club"]),
        (SLACK, "ContactGroupNameType", 26, ["design-team", "product", "research-readouts", "random"]),
    ]
    for bundle, slot, days, phrases in registered:
        path = lib.write_plist(vocabulary / bundle / "demo-user" / slot / "LatestVocabulary.plist", {
            "appBundleID": bundle, "intentSlot": slot,
            "vocabularyItems": [{"string": phrase, "vocabularyIdentifier": lib.uuid_string(rng)} for phrase in phrases],
        })
        _touch(path, clock.ago(days=days, hours=rng.randint(1, 9)))

    # Siri data-sharing history (key names per IdentifierStore; the reasons are invented).
    lib.write_plist(lib.library(root, "Preferences/com.apple.assistant.backedup.plist"), {
        "Siri Data Sharing Opt-In Status History": [
            {"Date": clock.at(1163, 19, 40), "New Opt-In Status": "optedIn", "Previous Opt-In Status": "unspecified", "Reason": "SetupAssistant",
             "Source": "siri", "Schema Version": "1.0"},
            {"Date": clock.at(212, 21, 5), "New Opt-In Status": "optedOut", "Previous Opt-In Status": "optedIn", "Reason": "SettingsToggle",
             "Source": "siri", "Schema Version": "1.0"},
        ],
    })


def _text_replacements(root: pathlib.Path, persona: Persona, rng: random.Random, clock: lib.Clock) -> None:
    owner, home = persona.owner, persona.place("home")
    entries = [
        ("omw", "On my way!", 1100, 0), ("@@", owner.email, 930, 0), ("@w", owner.emails[1], 900, 0),
        ("addr", f"{home.street}, Aro Valley, {home.city} {home.postal_code}", 610, 0), ("kl", persona.company, 580, 0),
        ("shrug", "¯\\_(ツ)_/¯", 420, 0), ("ty", "Thank you!", 300, 0), ("brb", "Be right back", 260, 0),
        ("nga", "Ngā mihi,\n" + owner.given, 190, 0), ("sig", f"{owner.full_name}\n{owner.job_title}, {persona.company}", 150, 0),
        ("ph", _pretty_phone(owner.phone), 96, 0), ("zm", "https://meet.example.org/j/8125550142", 41, 1),
    ]
    ddl = ("CREATE TABLE ZTEXTREPLACEMENTENTRY ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZNEEDSSAVETOCLOUD INTEGER, "
           "ZWASDELETED INTEGER, ZTIMESTAMP TIMESTAMP, ZPHRASE VARCHAR, ZSHORTCUT VARCHAR, ZUNIQUENAME VARCHAR, ZREMOTERECORDINFO BLOB );\n"
           "CREATE TABLE ZTRCLOUDKITSYNCSTATE ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDIDPULLONCE INTEGER, ZFETCHCHANGETOKEN BLOB );\n")
    with lib.sqlite_db(lib.library(root, "KeyboardServices/TextReplacements.db"), ddl) as con:
        lib.coredata_tables(con, {"TextReplacementEntry": 1, "TRCloudKitSyncState": 2}, rng, {"TextReplacementEntry": len(entries), "TRCloudKitSyncState": 1})
        for index, (shortcut, phrase, days, deleted) in enumerate(entries, 1):
            con.execute("INSERT INTO ZTEXTREPLACEMENTENTRY VALUES (?, 1, 1, 0, ?, ?, ?, ?, ?, NULL)",
                        (index, deleted, lib.cocoa(clock.at(days, rng.randrange(8, 22), rng.randrange(60))), phrase, shortcut, lib.uuid_string(rng)))
        con.execute("INSERT INTO ZTRCLOUDKITSYNCSTATE VALUES (1, 2, 1, 1, NULL)")


def _lexicon_bytes(words: list[tuple[str, int, int, float]]) -> bytes:
    """`dynamic-lexicon.dat` as KeyboardLexicon.parse reads it: ASCII magic + NUL, big-endian
    word count, then per word a token id and a usage count (1 byte < 0x80, 2 bytes with the
    top bits `10`, otherwise a marker byte and 3 bytes), 3 reserved bytes, a big-endian
    float32 Cocoa timestamp (0 for built-in vocabulary) and the NUL-terminated word."""
    def number(value: int, force_wide: bool = False) -> bytes:
        if not force_wide and value < 0x80:
            return bytes([value])
        if not force_wide and value < 0x4000:
            return bytes([0x80 | (value >> 8), value & 0xFF])
        return bytes([0xC0, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF])

    out = bytearray(b"DynamicDictionary-9\0" + struct.pack(">I", len(words)))
    for word, token_id, count, stamp in words:
        out += number(token_id, force_wide=token_id >= 0x4000) + number(count) + b"\0\0\0"
        out += struct.pack(">f", stamp) if stamp else b"\0\0\0\0"
        out += word.encode("utf-8") + b"\0"
    return bytes(out)


def _keyboard(root: pathlib.Path, persona: Persona, rng: random.Random, clock: lib.Clock) -> None:
    base = lib.library(root, "LanguageModeling")
    now_cocoa = lib.cocoa(clock.now)

    def learned_stamp(days: float) -> float:
        # float32 holds Cocoa seconds to about a minute; keep the rounded value in the past.
        value = struct.unpack(">f", struct.pack(">f", now_cocoa - days * 86_400))[0]
        while value > now_cocoa - 120:
            value = struct.unpack(">f", struct.pack(">f", value - 128))[0]
        return value

    def build(language: str, builtin: list[str], learned: list[str], typed: int, modified_hours: float) -> None:
        words: list[tuple[str, int, int, float]] = []
        builtin = list(dict.fromkeys(builtin))
        for rank, word in enumerate(builtin):
            count = max(1, int(typed * 0.045 / (rank + 1.6) ** 0.92 * rng.uniform(0.75, 1.3)))
            token_id = 0x90 + rank * 7 + rng.randrange(7) if rank < 400 else 0x4000 + rank * 37 + rng.randrange(30)
            words.append((word, token_id, count, 0.0))
        for index, word in enumerate(dict.fromkeys(learned)):
            count = max(2, int(rng.paretovariate(1.15) * 3))
            words.append((word, 0xC0_0000 + index * 3 + rng.randrange(3), min(count, 900), learned_stamp(rng.uniform(0.3, 500) ** 1.0)))
        rng.shuffle(words)
        folder = base / f"{language}-dynamic.lm"
        path = lib.write_bytes(folder / "dynamic-lexicon.dat", _lexicon_bytes(words))
        _touch(path, clock.ago(hours=modified_hours))
        lib.write_plist(folder / "meta.dat", {"numberOfTokensTyped": typed, "version": 9, "locale": language})

    people_words = [p.given for p in persona.others] + [p.family for p in persona.others if p.family != persona.owner.family]
    build("en", COMMON_WORDS, LEARNED_WORDS + people_words, 412_806, 0.6)
    build("mi", MAORI_WORDS, ["Pōneke", "Kōwhai", "Ngata", "Aroha", "whānau katoa", "ngā mihi nui"], 9_420, 52)
    lib.write_plist(lib.library(root, "Spelling/dynamic-counts.dat"), {"total": 618_244, "en": 604_117, "mi": 14_127})


# ----------------------------------------------------------------------------------------
# Identifiers, Trial, first-party topics
# ----------------------------------------------------------------------------------------

def _identifiers(root: pathlib.Path, persona: Persona, rng: random.Random, clock: lib.Clock) -> None:
    """`Siri.AnalyticsIdentifiers.*`: record fields per IdentifierStore — 1 = 16-byte UUID,
    2 = effective from (Unix seconds), 3 = validity in days, 4 = created, 5 = retired at,
    6 = retired flag. Rotation periods are invented."""
    sync_db = lib.library(root, "Biome/sync/sync.db")
    if not sync_db.exists():
        lib.write_biome_sync_db(root, persona.devices, clock.now, rng)
    iphone = persona.device("iphone")
    streams = [("Siri.AnalyticsIdentifiers.UserSeed", 365, 760), ("Siri.AnalyticsIdentifiers.UserAggregationId", 15, 190),
               ("Siri.AnalyticsIdentifiers.UserSamplingId", 30, 250), ("Siri.AnalyticsIdentifiers.HomeSeed", 365, 610)]
    for name, validity, history in streams:
        for device in (None, iphone.identifier):
            if device and name.endswith("HomeSeed"):
                continue
            records = []
            start = history - rng.randint(0, min(validity, 40) - 1)
            while start > 0:
                created = clock.at(int(start), rng.randrange(1, 5), rng.randrange(60), rng.randrange(60))
                retired = start - validity > 0
                ended = clock.at(int(start - validity), rng.randrange(1, 5), rng.randrange(60)) if retired else None
                fields = [(1, lib.uuid_obj(rng).bytes), (2, pb.double(float(int(lib.unix(created))))), (3, validity),
                          (4, pb.double(float(int(lib.unix(created)))))]
                if retired:
                    fields += [(5, pb.double(float(int(lib.unix(ended))))), (6, True)]
                records.append((created, pb.message(fields)))
                start -= validity
            lib.write_stream(lib.biome_stream_dir(root, name), records, device=device)
    # The user-segment stream exists but holds no records (its record layout is not known).
    lib.write_stream(lib.biome_stream_dir(root, "Siri.ODDI.SegmentsCohorts"), [])


TRIAL_DDL = """
CREATE TABLE integrityCheck (inconsequential STRING);
CREATE TABLE experiments (     rowid INTEGER PRIMARY KEY AUTOINCREMENT,     experimentId TEXT NOT NULL,     deploymentId INTEGER NOT NULL,     type INTEGER NOT NULL,     status INTEGER NOT NULL,     startSecondsFromEpoch REAL,     endSecondsFromEpoch REAL,     treatmentId TEXT,     artifact BLOB NOT NULL, deploymentEnvironment INTEGER NOT NULL DEFAULT 0, isManuallyTargeted INTEGER NOT NULL DEFAULT 0, factorPackSetId TEXT, experimentType INTEGER NOT NULL DEFAULT 0, encryptionStatus INTEGER NOT NULL DEFAULT 0,     UNIQUE (experimentId, deploymentId),     CHECK (startSecondsFromEpoch IS NULL         OR endSecondsFromEpoch IS NULL         OR startSecondsFromEpoch < endSecondsFromEpoch) );
CREATE TABLE namespaces (     rowid INTEGER PRIMARY KEY AUTOINCREMENT,     experiments_rowid INTEGER NOT NULL,     name TEXT NOT NULL,     compatibilityVersion INTEGER NOT NULL,     treatmentPath TEXT,     UNIQUE (experiments_rowid, name),     FOREIGN KEY (experiments_rowid) REFERENCES experiments (rowid) );
CREATE TABLE kvstore (     key TEXT PRIMARY KEY,     bytes BLOB NOT NULL ) WITHOUT ROWID;
CREATE TABLE experimentHistory (     rowid INTEGER PRIMARY KEY AUTOINCREMENT,     eventSecondsFromEpoch REAL NOT NULL,     eventType INTEGER NOT NULL,     deploymentEnvironment INTEGER NOT NULL,     experimentId TEXT NOT NULL,     deploymentId INTEGER NOT NULL,     treatmentId TEXT NOT NULL , errorOrDeactivationReason TEXT);
CREATE TABLE activationEvents (     experimentId TEXT NOT NULL,     treatmentId TEXT NOT NULL,     deploymentId INTEGER NOT NULL,     osBuild TEXT NOT NULL,     languageCode TEXT NOT NULL,     regionCode TEXT NOT NULL, carrierBundleId TEXT NOT NULL DEFAULT '', carrierCountryCode TEXT NOT NULL DEFAULT '', diagnosticsUsageEnabled INTEGER NOT NULL DEFAULT 0, hasAne INTEGER NOT NULL DEFAULT 0, aneVersion TEXT NOT NULL DEFAULT '', osRestoreVersion TEXT NOT NULL DEFAULT '',     UNIQUE (experimentId, treatmentId, deploymentId) );
CREATE TABLE rolloutsV2 (     rowid INTEGER PRIMARY KEY AUTOINCREMENT,     rolloutId TEXT NOT NULL,     deploymentId INTEGER NOT NULL,     status INTEGER NOT NULL,     activeFactorPackSetId TEXT,     targetedFactorPackSetId TEXT,     artifact BLOB NOT NULL, rampId TEXT, activeTargetingRuleIndex INTEGER, targetedTargetingRuleIndex INTEGER, respectRefCount INTEGER NOT NULL DEFAULT 1, encryptionStatus INTEGER NOT NULL DEFAULT 0,     UNIQUE (rolloutId, deploymentId) );
CREATE TABLE rolloutV2Namespaces (     rowid INTEGER PRIMARY KEY AUTOINCREMENT,     rolloutsV2_rowid INTEGER NOT NULL,     name TEXT NOT NULL,     UNIQUE (rolloutsV2_rowid, name),     FOREIGN KEY (rolloutsV2_rowid) REFERENCES rolloutsV2 (rowid) );
CREATE TABLE rolloutHistory (     rowid INTEGER PRIMARY KEY AUTOINCREMENT,     eventLogTime REAL NOT NULL,     eventType INTEGER NOT NULL,     rolloutId TEXT NOT NULL,     deploymentId INTEGER,     rampId TEXT,     factorPackSetId TEXT );
"""

#: Feature namespaces and projects: invented in the style of Trial's naming (the real list
#: of a Mac was not copied).
TRIAL_EXPERIMENTS = [
    (["SIRI_UNDERSTANDING_SUGGESTION_RANKING"], "Siri Suggestions Ranking"),
    (["SPOTLIGHT_RESULT_BLENDING", "SPOTLIGHT_TOP_HIT_THRESHOLDS"], "Spotlight Ranking"),
    (["KEYBOARD_AUTOCORRECTION_MODEL"], "Keyboard Language Models"),
    (["MAIL_MESSAGE_CATEGORISATION"], "Mail Intelligence"),
    (["PHOTOS_MEMORIES_CURATION"], "Photos Curation"),
    (["PROACTIVE_APP_PREDICTION_WIDGETS"], "Proactive Predictions"),
]
TRIAL_ROLLOUTS = [
    ["SIRI_DICTATION_ASSETS"], ["SIRI_TEXT_TO_SPEECH_VOICES"], ["SIRI_UNDERSTANDING_NL_OVERRIDES"], ["SPOTLIGHT_KNOWLEDGE_UPDATES"],
    ["PERSONALIZATION_PORTRAIT_TOPIC_MODEL"], ["PERSONALIZATION_PORTRAIT_GAZETTEER"], ["KEYBOARD_EMOJI_PREDICTION"],
    ["MAIL_SMART_REPLY_MODEL"], ["PHOTOS_SCENE_TAXONOMY", "PHOTOS_SEARCH_RANKING"], ["SAFARI_HIGHLIGHTS_EXTRACTION"],
    ["MAPS_PLACE_SUGGESTIONS"], ["NOTES_HANDWRITING_RECOGNITION"], ["TRANSLATION_LANGUAGE_PACKS"], ["WEATHER_SEVERE_ALERT_CONFIG"],
    ["FOCUS_MODE_SUGGESTIONS"], ["VISUAL_LOOK_UP_DOMAINS"], ["LIVE_TEXT_LANGUAGE_MODELS"], ["APP_INTENTS_RELEVANCE_MODEL"],
    ["FITNESS_WORKOUT_DETECTION"], ["WALLET_PASS_CLASSIFIER"],
]


def _trial(root: pathlib.Path, persona: Persona, rng: random.Random, clock: lib.Clock) -> None:
    mac = persona.this_mac
    with lib.sqlite_db(lib.library(root, "Trial/v7/Database/triald.db"), TRIAL_DDL) as con:
        for index, (namespaces, project) in enumerate(TRIAL_EXPERIMENTS, 1):
            experiment = lib.hex_string(rng, 24)
            treatment = lib.uuid_string(rng, upper=False)
            deployment = rng.randint(1, 6)
            started = clock.at(rng.randint(8, 150), rng.randrange(0, 24), rng.randrange(60))
            ends = started + datetime.timedelta(days=rng.choice([28, 42, 56, 90]))
            # Artifact: 9 = experiment definition, 9.9 = project name (TrialStore); the rest is filler.
            artifact = pb.message([(1, experiment), (2, deployment), (9, [(1, experiment), (9, project), (11, len(namespaces))])])
            con.execute("INSERT INTO experiments (rowid, experimentId, deploymentId, type, status, startSecondsFromEpoch, endSecondsFromEpoch, treatmentId, artifact, "
                        "deploymentEnvironment, factorPackSetId) VALUES (?, ?, ?, 1, 4, ?, ?, ?, ?, ?, ?)",
                        (index, experiment, deployment, lib.unix(started), lib.unix(ends), treatment, artifact, rng.choice([0, 0, 2]), lib.uuid_string(rng, upper=False)))
            for name in namespaces:
                con.execute("INSERT INTO namespaces (experiments_rowid, name, compatibilityVersion, treatmentPath) VALUES (?, ?, ?, NULL)", (index, name, rng.randint(1, 4)))
            for offset, event in ((-340, 12), (0, 5)) + (((ends - started).total_seconds() + 60, 13),) * (1 if ends < clock.now else 0):
                con.execute("INSERT INTO experimentHistory (eventSecondsFromEpoch, eventType, deploymentEnvironment, experimentId, deploymentId, treatmentId, errorOrDeactivationReason) "
                            "VALUES (?, ?, 0, ?, ?, ?, NULL)", (lib.unix(started) + offset, event, experiment, deployment, treatment))
            con.execute("INSERT INTO activationEvents (experimentId, treatmentId, deploymentId, osBuild, languageCode, regionCode, diagnosticsUsageEnabled, hasAne, aneVersion) "
                        "VALUES (?, ?, ?, ?, ?, ?, 0, 1, 'M3')", (experiment, treatment, deployment, mac.os_build, persona.language, persona.region))
        for index, namespaces in enumerate(TRIAL_ROLLOUTS, 1):
            rollout = lib.hex_string(rng, 24)
            deployment = rng.randint(1, 9)
            pack = lib.uuid_string(rng, upper=False)
            con.execute("INSERT INTO rolloutsV2 (rowid, rolloutId, deploymentId, status, activeFactorPackSetId, targetedFactorPackSetId, artifact, rampId) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                        (index, rollout, deployment, 3 if index % 7 == 0 else 1, pack, pack, pb.message([(1, rollout), (2, deployment)]), "ramp-" + lib.hex_string(rng, 8)))
            for name in namespaces:
                con.execute("INSERT INTO rolloutV2Namespaces (rolloutsV2_rowid, name) VALUES (?, ?)", (index, name))
            first = clock.at(rng.randint(4, 420), rng.randrange(0, 24), rng.randrange(60))
            for step, event in enumerate(rng.choice([[1, 2, 3], [1, 2, 3, 4], [1, 2, 11, 2, 3]])):
                con.execute("INSERT INTO rolloutHistory (eventLogTime, eventType, rolloutId, deploymentId, rampId, factorPackSetId) VALUES (?, ?, ?, ?, NULL, ?)",
                            (lib.unix(first) + step * rng.randint(40, 5400), event, rollout, deployment, pack))
        # Targeting values Trial persists (key names from the store's own vocabulary; values invented).
        for key, value in (("com.apple.triald.persisted.Maps.BucketId", lib.keyed_archive(rng.randint(0, 99))),
                           ("com.apple.triald.persisted.Maps.DeviceCountryCode", lib.keyed_archive(persona.region)),
                           ("com.apple.triald.persisted.userSettingsIsSiriEnabled", b"\x01"),
                           ("com.apple.triald.optout.experiment", b"\x00")):
            con.execute("INSERT INTO kvstore VALUES (?, ?)", (key, value))
        con.execute("INSERT INTO integrityCheck VALUES ('ok')")


def _first_party_topics(root: pathlib.Path, persona: Persona, rng: random.Random, cached: dict[str, float]) -> None:
    """IntelligencePlatform's topic scores. Mostly empty on a Mac; here they carry the
    persona's leading interests so the view has something to show. Only the table layout
    is known: that `topicId` is a Wikidata id and the shape of `most_recent_documentId`
    are guesses."""
    ddl = 'CREATE TABLE "topics" ("topicId" TEXT, "score" DOUBLE, "most_recent_documentId" TEXT, PRIMARY KEY ("topicId") ON CONFLICT REPLACE);'
    folder = lib.library(root, "IntelligencePlatform/Artifacts/firstPartyTopics")
    ranked = [qid for qid in cached if qid not in UNNAMED.values()]
    for name, take, scale in (("scoredTopicsFirstPartyLongTerm", 34, 1.0), ("scoredTopicsFirstPartyShortTerm", 11, 0.6)):
        chosen = ranked[:take] if scale == 1.0 else rng.sample(ranked[:30], take)
        rows = [(qid, round(max(0.02, cached[qid] * scale * rng.uniform(0.7, 1.1)), 5),
                 rng.choice(["com.apple.podcasts", "com.apple.news", "com.apple.Music"]) + ":" + lib.uuid_string(rng)) for qid in chosen]
        lib.create_db(folder / f"{name}.db", ddl, {"topics": rows})
        lib.create_db(folder / f"{name}-fullRebuild.db", ddl, {"topics": []})


# ----------------------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------------------

def _cast(persona: Persona, rng: random.Random) -> tuple[dict[str, dict], list[dict]]:
    """Business senders and "pseudo-contacts": people who write to the persona without being
    in the address book. Invented; addresses on example.* domains, phones in 555-01xx."""
    theme_of = {"kea": "travel", "lodge": "travel", "rental": "travel", "dental": "admin", "bank": "admin", "isp": "admin",
                "power": "admin", "gym": "climbing", "meetup": "work", "books": "culture", "bikes": "sport", "property": "admin",
                "news": "culture", "weather": "outdoors", "filmsoc": "culture", "council": "admin", "accounts": "admin",
                "venue": "music", "ferry": "travel"}
    senders: dict[str, dict] = {}
    for index, (key, name, org, email, has_phone, address) in enumerate(SENDERS):
        senders[key] = {"name": name, "org": org, "email": email, "phone": _fiction_phone(index) if has_phone else "",
                        "address": address, "theme": theme_of[key]}
    pseudo: list[dict] = []
    givens, families = rng.sample(PSEUDO_GIVEN, len(PSEUDO_GIVEN)), rng.sample(PSEUDO_FAMILY, len(PSEUDO_FAMILY))
    domains = ["example.com", "example.net", "example.org"]
    for index in range(38):
        given, family = givens[index], families[index]
        role, org = PSEUDO_ROLES[index % len(PSEUDO_ROLES)]
        known = next((s["email"].split("@")[1] for s in senders.values() if s["org"] == org and not s["email"].endswith("@example.net")), None)
        host = known or (_slug(org).replace("-", "") + "." if org else "") + domains[index % 3]
        pseudo.append({"name": f"{given} {family}", "role": role, "org": org, "email": f"{given.lower()}.{_slug(family)}@{host}" if not org else f"{given.lower()}@{host}",
                       "phone": _fiction_phone(30 + index) if index % 4 != 3 else "",
                       "address": "" if index % 5 else rng.choice(["Cuba Street, Te Aro, Wellington 6011", "Lambton Quay, Wellington 6011",
                                                                    "The Terrace, Wellington 6011", "Riddiford Street, Newtown, Wellington 6021"])})
    for key in ("dental", "lodge", "bikes", "property", "gym"):      # businesses whose signature was harvested, too
        s = senders[key]
        pseudo.append({"name": s["name"], "role": "", "org": "", "email": s["email"], "phone": s["phone"], "address": s["address"]})
    return senders, pseudo


def generate(root: pathlib.Path, persona: Persona, rng: random.Random, now: datetime.datetime) -> None:
    """Create this module's stores below `root`."""
    clock = lib.Clock(now, persona.tz_offset_hours)
    places = _places(persona)
    senders, pseudo = _cast(persona, rng)
    _system_assets(root)
    portrait = _portrait(root, persona, rng, clock, places, senders)
    _portrait_contacts(root, persona, rng, clock)
    _suggestions(root, persona, rng, clock, senders, pseudo, places)
    _family(root, persona, rng, clock)
    _speech(root, persona, rng, clock)
    _text_replacements(root, persona, rng, clock)
    _keyboard(root, persona, rng, clock)
    _identifiers(root, persona, rng, clock)
    _trial(root, persona, rng, clock)
    _first_party_topics(root, persona, rng, portrait["topics"])
