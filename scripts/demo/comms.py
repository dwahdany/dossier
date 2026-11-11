"""Demo data for the Communications module (`comms`).

Everything here describes the invented persona (`persona.py`); schema and formats follow the
readers in `Sources/CommsModule` and the real stores' DDL, content is made up.

Stores written (`~` is `<root>/Home`):

* `~/Library/IntelligencePlatform/Artifacts/siri/remembers/view.db` — a year of message,
  call and "other Siri memory" metadata (interactions / entities / interactionEntities);
* Biome `Siri.Remembers.{MessageHistory,CallHistory,InteractionHistory,AudioHistory,
  AssistantSuggestions}` under `~/Library/Biome/streams/restricted/…/remote/<device>/` —
  the same interactions as protobuf records (the view is "built from" them);
* `~/Library/Application Support/Knowledge/knowledgeC.db` — `/app/intents` of the last four
  weeks with the serialized `INInteraction` (retained message text, incl. invented one-time
  codes and a boarding notice). **Shared file**: created if missing, otherwise extended;
* `/private/var/db/CoreDuet/People/interactionC.db` — Mail / Calendar correspondents,
  meeting-title keywords, scheduled (future) meeting occurrences;
* `~/Library/Application Support/CallHistoryDB/CallHistory.storedata` — this Mac's call log;
* `~/Library/Containers/com.apple.corerecents.recentsd/Data/Library/Recents/Recents`;
* daemon container `com.apple.kvs` → `Data/com.apple.kvs/*.sqlite` — mail / calendar /
  FaceTime recents, VIP senders, favourites, block list. **Shared files**: as above;
* `~/Library/Biome/sync/sync.db` — only if no other generator has written it yet (device
  names for the "donated on" columns). **Shared file**: never replaced.

Invented, not looked up in a real store: every name, handle, title, text and number; the
bundle ids chosen for Find My / Contacts / Siri-suggestion memories; the `InvocationType`
values, entity ids of media items and suggestions; the `Person` entity id shape; Slack user
ids; conversation identifiers.
"""

from __future__ import annotations

import contextlib
import dataclasses
import datetime
import json
import math
import pathlib
import random
import sqlite3
from dataclasses import dataclass, field
from typing import Any, Iterator, Optional, Sequence

from . import lib
from .lib import pb
from .persona import Device, Person, Persona

SMS = "com.apple.MobileSMS"
WHATSAPP = "net.whatsapp.WhatsApp"
SIGNAL = "org.whispersystems.signal"
SLACK = "com.tinyspeck.chatlyio"
MAIL_IOS = "com.apple.mobilemail"
GITHUB = "com.github.stormbreaker.prod"
PHONE = "com.apple.mobilephone"
FACETIME_IOS = "com.apple.facetime"
MUSIC = "com.apple.Music"
PODCASTS = "com.apple.podcasts"
SPOTIFY = "com.spotify.client"

MESSAGE = "INSendMessageIntent"
CALL = "INStartCallIntent"

HISTORY_DAYS = 365          # Siri Remembers keeps about a year
INTENT_DAYS = 28            # knowledgeC keeps /app/intents for a few weeks
TRIP_DAY = 19               # days ago the persona flew to Queenstown (back four days later)
DENTIST_DAY = 23            # days ago of the dentist appointment

IN, OUT = 1, 2              # Siri Remembers direction codes (knowledgeC uses the reverse)


# ----------------------------------------------------------------------------------------
# Invented content
# ----------------------------------------------------------------------------------------
# A script is one short exchange: ("i" incoming | "o" outgoing, text). {cafe}, {gym} are
# filled from the persona's places.

_PARTNER = [
    [("i", "Are you home for dinner tonight?"), ("o", "Yes! Back by 6:30"), ("i", "Perfect, I'll get the kūmara on"), ("o", "Legend")],
    [("o", "Running late, bus is stuck on Lambton Quay"), ("i", "No rush, I'm still at the market"), ("o", "Can you grab oat milk?"), ("i", "Already in the bag")],
    [("i", "Did you book the ferry for Saturday?"), ("o", "Not yet, doing it at lunch"), ("i", "Morning sailing if you can"), ("o", "On it")],
    [("o", "Coffee at {cafe} before work?"), ("i", "Yes please. 8:15?"), ("o", "See you there")],
    [("i", "The landlord emailed about the heat pump service"), ("o", "Thursday morning works for me"), ("i", "I'll tell him")],
    [("o", "Climbing tonight, home around 9"), ("i", "Have fun, don't forget your chalk bag this time"), ("o", "Never again")],
    [("o", "Mum wants to know if we're coming up on Sunday"), ("i", "Yes, let's take the train"), ("o", "I'll tell her")],
    [("o", "Wind is wild today, the ferry got cancelled"), ("i", "Classic Wellington"), ("o", "Train instead then")],
    [("i", "Bins go out tonight"), ("o", "Already on the kerb")],
    [("o", "Home in 10"), ("i", "Ok")],
    [("i", "Pick a film for tonight"), ("o", "Something short, I'm wrecked"), ("i", "Documentary about kākāpō it is")],
    [("i", "Can you transfer me your half of the power bill?"), ("o", "Done, sent it just now"), ("i", "Thanks")],
    [("o", "Booked the table for Friday, 7pm"), ("i", "Lovely. I'll come straight from work")],
    [("i", "Left my keys on the bench, are you home?"), ("o", "Yes, till 8:30"), ("i", "Coming back for them")],
]
# Dated exchanges: (days ago, script). They fall inside the weeks knowledgeC keeps text for.
_PARTNER_SPECIAL = [
    (TRIP_DAY + 2, [("i", "Door code for the Queenstown place is 4471#, check-in after 3"), ("o", "Saved it. Can't wait")]),
    (DENTIST_DAY + 1, [("i", "Don't forget the dentist tomorrow at 9:40"), ("o", "Calendar says so too. Thanks though")]),
    (6, [("o", "The wifi password at the bach is tidepool-2290 by the way"), ("i", "Thanks, it never remembers me")]),
]
_MOTHER = [
    [("i", "Hi love, are you two still coming on Sunday?"), ("o", "Yes, 10:44 train, there by lunch"), ("i", "Lovely. Dad's doing a roast")],
    [("o", "Happy birthday Mum! Parcel should arrive today"), ("i", "It came this morning, thank you darling")],
    [("i", "Can you help me with the iPad on Sunday? It keeps asking for a password"), ("o", "Of course, don't type anything in until I'm there"), ("i", "Ok")],
    [("i", "Photo of the garden for you"), ("o", "The dahlias look amazing")],
    [("i", "Is it blowing a gale down there too?"), ("o", "Sideways rain. Staying in")],
    [("i", "Do you still have my blue casserole dish?"), ("o", "It's in our cupboard, bringing it Sunday")],
    [("i", "Your father has signed us up for a walking group"), ("o", "Brilliant. Report back")],
]
_MOTHER_SPECIAL = [
    (9, [("i", "Results came back all clear, no follow-up needed"), ("o", "That's such a relief. Call you tonight"), ("i", "Yes please")]),
    (TRIP_DAY, [("o", "Landed in Queenstown, all good"), ("i", "Glad to hear it. Send pictures")]),
]
_FATHER = [
    [("i", "Did you watch the game?"), ("o", "Second half only. What a finish"), ("i", "Told you they'd do it")],
    [("i", "Borrowing your drill on Sunday if that's ok"), ("o", "It's in the hall cupboard")],
    [("o", "What was the name of that tide app?"), ("i", "I'll send it when I find my glasses")],
    [("i", "Train times have changed, check before you come up"), ("o", "Will do, thanks Dad")],
]
_SISTER = [
    [("i", "Are you free Saturday? Brunch at {cafe}?"), ("o", "Yes! 10?"), ("i", "10:30, I'm not a morning person"), ("o", "Fine")],
    [("o", "Mum's birthday. Shall we go halves on the garden voucher?"), ("i", "Yep, I'll transfer you my half"), ("o", "Sweet")],
    [("i", "Can I borrow your tent for the long weekend?"), ("o", "Sure, it's at Mum and Dad's though"), ("i", "Even better")],
    [("i", "How was the interview panel?"), ("o", "Long. Three hours of portfolios"), ("i", "Wine tonight then")],
    [("o", "Did you get the photos from Sunday?"), ("i", "Yes, Dad has his eyes shut in all of them")],
    [("i", "Call me when you're out of work?"), ("o", "About 5:30")],
]
_FRIEND = [
    [("i", "Climbing Wednesday?"), ("o", "In. 6pm at {gym}?"), ("i", "See you there")],
    [("o", "Want to do the Southern Walkway on Sunday?"), ("i", "If the southerly stays away, yes"), ("o", "Forecast says fine till 3")],
    [("i", "That jazz night on Cuba Street is back on Thursday"), ("o", "Count me in"), ("i", "Doors at 8")],
    [("i", "Can you send me the name of that pasta place?"), ("o", "I'll dig it out tonight")],
    [("o", "Thanks for dinner last night"), ("i", "Any time. You still owe me a rematch at cards")],
    [("i", "Lost my bank card again"), ("o", "Third time this year"), ("i", "Don't.")],
    [("o", "Are you bringing the rope or am I?"), ("i", "I've got it")],
    [("i", "Happy birthday! Drinks on Friday?"), ("o", "Thank you! Oriental Bay at 5:30?"), ("i", "Done")],
    [("o", "Te Papa has the new photography show on, want to go?"), ("i", "Saturday afternoon?"), ("o", "Perfect")],
    [("i", "Is your bike pump still alive?"), ("o", "Barely. Come and get it")],
    [("o", "Market on Sunday morning?"), ("i", "Yes, I need those dumplings"), ("o", "9:30 by the fruit stall")],
    [("i", "Did you see the tūī in the Botanic Garden yesterday?"), ("o", "Three of them by the cable car"), ("i", "Jealous")],
    [("o", "Can you recommend a physio?"), ("i", "The one on Taranaki Street sorted my shoulder")],
    [("i", "Board games at ours on Saturday"), ("o", "Bringing snacks"), ("i", "And the good crackers please")],
    [("o", "How was the tramp?"), ("i", "Muddy. Brilliant. My legs are gone")],
]
_CLIMBING_GROUP = [
    [("i", "Who's in for Wednesday?"), ("i", "Me"), ("o", "Me too, 6pm"), ("i", "Running late, start without me")],
    [("i", "New routes set on the back wall"), ("o", "Finally"), ("i", "The orange one is brutal")],
    [("o", "Outdoor day this weekend if it's dry?"), ("i", "Keen"), ("i", "I can drive"), ("i", "Sunday is better for me")],
    [("i", "Left my shoes at the gym again"), ("i", "They're at the front desk")],
    [("i", "Coffee at {cafe} after?"), ("o", "Always"), ("i", "Yes")],
]
_FAMILY_GROUP = [
    [("i", "Sunday lunch at ours, 12:30"), ("o", "We'll be there"), ("i", "I'm bringing pavlova")],
    [("i", "Dad has discovered voice messages"), ("i", "I heard that"), ("o", "Please no")],
    [("o", "Photos from the weekend are in the shared album"), ("i", "Lovely ones of the beach"), ("i", "Why am I always eating in photos")],
    [("i", "Train is delayed, start without us"), ("i", "No rush")],
    [("i", "Who has the good chilly bin?"), ("o", "Not us"), ("i", "Found it, garage")],
]
_TRIP_GROUP = [
    [("o", "Flights booked. 7:35 out of Wellington"), ("i", "Amazing"), ("i", "I'll sort the rental car")],
    [("i", "Is anyone bringing a proper jacket? Forecast says 4 degrees"), ("o", "Bringing two"), ("i", "Same")],
    [("i", "Dinner booking is 7pm Saturday"), ("o", "Perfect")],
    [("i", "Gondola or lake walk on Sunday?"), ("o", "Both if the weather holds"), ("i", "Ambitious")],
]
_COLLEAGUE = [
    [("i", "Got 10 minutes to look at the onboarding flow?"), ("o", "Yes, send me the Figma link"), ("i", "Sent"), ("o", "Looking now")],
    [("o", "Is the research readout still at 2?"), ("i", "Moved to 3, room 4"), ("o", "Thanks")],
    [("i", "Can you review my PR when you get a chance?"), ("o", "After standup")],
    [("o", "Prototype is ready for the usability sessions"), ("i", "Great, I'll book participants for next week")],
    [("i", "Are you in the office tomorrow?"), ("o", "Yes, till 4"), ("i", "Coffee at 10?"), ("o", "Deal")],
    [("i", "The staging build is broken again"), ("o", "I saw. Lucas is on it")],
    [("o", "Do you have the latest interview notes?"), ("i", "In the research folder, second tab")],
    [("i", "Lunch? The dumpling place on Willis Street"), ("o", "Give me five minutes"), ("i", "Meet you at the lifts")],
    [("o", "Which build has the new settings screen?"), ("i", "Yesterday's nightly"), ("o", "Got it, thanks")],
    [("i", "Can I borrow you for the customer call at 2?"), ("o", "Sure, send the invite")],
    [("o", "Icons are exported, they're in the shared folder"), ("i", "Perfect timing")],
    [("i", "Is the colour contrast fix in this release?"), ("o", "Yes, merged this morning"), ("i", "Great")],
    [("o", "Running five minutes late to the review"), ("i", "No problem, we'll start with the metrics")],
]
_MANAGER = [
    [("i", "Can we move our 1:1 to Thursday?"), ("o", "Sure, same time?"), ("i", "Yes, 11")],
    [("i", "Great work on the review today"), ("o", "Thanks, the team did the heavy lifting")],
    [("o", "Draft roadmap is in the shared doc"), ("i", "Reading it tonight")],
    [("i", "Could you sit on the hiring panel next week?"), ("o", "Happy to. Send me the portfolios")],
]
_CHANNELS = {
    "#design": [
        [("i", "New icon set is in the library"), ("o", "Looks great. Are the 16px versions in too?"), ("i", "Tomorrow")],
        [("o", "Design review notes are posted"), ("i", "Thanks"), ("i", "Will the settings changes make this sprint?"), ("o", "Aiming for it")],
        [("i", "Does anyone have the brand colours for dark mode?"), ("o", "Pinned in this channel")],
        [("i", "Critique moved to 3pm"), ("i", "Works for me")],
    ],
    "#general": [
        [("i", "Fire drill at 10:30, meet on the Lambton Quay side")],
        [("i", "Leftover cake in the kitchen"), ("i", "Gone already"), ("o", "That was fast")],
        [("i", "All hands moved to Friday")],
        [("i", "Lift is out of order again, stairs today")],
    ],
    "#launch-tui": [
        [("i", "Release candidate is up on TestFlight"), ("o", "Installing now"), ("i", "Please log anything odd in the tracker")],
        [("o", "Final screenshots are in the folder"), ("i", "Thanks, uploading tonight")],
        [("i", "Go / no-go at 4pm"), ("i", "Go from engineering"), ("o", "Go from design")],
        [("i", "Store review came back approved"), ("o", "Brilliant")],
    ],
}

# Text messages from services: (short code, text, when). `when` is a list of days ago or
# ("every", n) for roughly every n days. `{code}` becomes an invented 6-digit number.
_SERVICE_SMS = [
    ("3456", "{code} is your Harbour Bank verification code. It expires in 10 minutes. Never share this code.", ("every", 16)),
    ("3456", "{code} is your Harbour Bank verification code. It expires in 10 minutes. Never share this code.", [2, 8, 15]),
    ("4040", "Your Pōneke Rides verification code is {code}.", [5, TRIP_DAY - 1]),
    ("4040", "Use code {code} to sign in to your Kōwhai Labs account. If this wasn't you, ignore this message.", [12, 26]),
    ("3456", "Harbour Bank: a payment of $84.20 to TE ARO CLIMBING was approved on your card ending 0142.", ("every", 30)),
    ("8222", "Kererū Air: you are checked in for KA 412 Wellington to Queenstown, departing 07:35. Seat 14A. Booking ref QX7R2M.", [TRIP_DAY + 1]),
    ("8222", "Kererū Air: gate change for KA 412, now boarding from gate 9.", [TRIP_DAY]),
    ("8222", "Kererū Air: you are checked in for KA 417 Queenstown to Wellington, departing 16:10. Seat 9C. Booking ref QX7R2M.", [TRIP_DAY - 3]),
    ("8222", "Kererū Air: you are checked in for KA 105 Wellington to Auckland, departing 06:50. Seat 21F. Booking ref MB4T9W.", [214]),
    ("2580", "Your parcel is out for delivery today between 1pm and 4pm. Track it with reference PX48201773.", ("every", 34)),
    ("2580", "We missed you. Collect your parcel from the Cuba Street depot with collection code {code}.", [11, 139, 262]),
    ("4040", "Your Pōneke Rides verification code is {code}.", ("every", 55)),
    ("4040", "Use code {code} to sign in to your Kōwhai Labs account. If this wasn't you, ignore this message.", ("every", 41)),
    ("7227", "You have used 80% of your data for this month.", ("every", 31)),
    ("7227", "Your reserved book is ready to collect at the Te Aro branch until Friday.", [3, 87, 190, 301]),
]
_DENTIST_SMS = [("i", "Reminder: your appointment at Harbour Street Dental is tomorrow at 9:40am. Reply YES to confirm."), ("o", "YES")]

# Organisations that only exist as mail senders: (name, address). Invented.
_SENDERS = {
    "air": ("Kererū Air", "bookings@example.com"),
    "gym": ("Te Aro Climbing Gym", "hello@example.net"),
    "bank": ("Harbour Bank", "statements@example.com"),
    "rides": ("Pōneke Rides", "receipts@example.net"),
    "market": ("Harbourside Market", "news@example.net"),
    "staff": ("Kōwhai Labs All Staff", "all-staff@example.org"),
    "guild": ("Design Guild", "design-guild@example.org"),
    "people": ("People & Culture", "people@example.org"),
    "helpdesk": ("IT Helpdesk", "helpdesk@example.org"),
    "type": ("Wren Typography Newsletter", "newsletter@example.com"),
    "tramping": ("Tararua Tramping Club", "club@example.net"),
}
_WORK_SUBJECTS = [
    "Design review notes: onboarding flow", "Sprint 42 planning agenda", "Usability sessions: schedule for next week",
    "Q3 roadmap draft for comments", "Research readout slides", "Updated brand guidelines", "Offsite logistics",
    "Hiring panel: portfolio review", "Accessibility audit findings", "Release checklist for 3.2",
    "Invitation: Design critique", "Notes from the customer interviews", "Settings redesign: open questions",
    "Icon library handover", "Launch plan for Tūī", "Feedback on the pricing page", "Budget for the research panel",
    "Retro actions from last sprint", "Prototype link for Thursday", "Conference talk proposal",
]
_PERSONAL_SUBJECTS = {
    "helen": ["Photos from Sunday", "Recipe for the lemon slice", "Fwd: Walking group timetable"],
    "david": ["Fwd: Tide tables for the bach", "Drill returned, thank you"],
    "jamie": ["Tent booking confirmation", "Mum's birthday plan"],
    "alex": ["Fwd: Power bill for this month", "Ferry tickets for Saturday"],
    "landlord": ["Heat pump service on Thursday", "Rent review for next year", "Gutter cleaning next week"],
    "drlee": ["Your appointment confirmation", "Invoice for your recent visit"],
}
_SERVICE_SUBJECTS = {
    "gym": ["Your membership renews next week", "New routes this month"],
    "bank": ["Your statement is ready", "Security alert: new sign-in to your account"],
    "rides": ["Your trip receipt"],
    "market": ["This Sunday at the market"],
    "staff": ["All hands: agenda for Friday", "Office closed over the holidays"],
    "people": ["Your leave request has been approved", "Reminder: complete your annual review"],
    "helpdesk": ["Your password expires in 5 days", "Laptop refresh: pick a slot"],
}
# Airline mail belongs to the two trips: (days ago, subject).
_TRIP_MAIL = [
    (TRIP_DAY + 43, "Your e-ticket: Wellington to Queenstown"), (TRIP_DAY + 1, "Check in now for your flight to Queenstown"),
    (TRIP_DAY, "Your boarding pass for KA 412"), (TRIP_DAY - 3, "Your boarding pass for KA 417"),
    (241, "Your e-ticket: Wellington to Auckland"), (214, "Your boarding pass for KA 105"),
]
_GITHUB_TITLES = [
    "Fix focus ring on onboarding buttons (#412)", "Dark mode: card shadows too strong (#398)",
    "Add haptics to the confirm sheet (#405)", "Settings screen crashes on rotate (#421)",
    "Update icon assets to new library (#417)", "Localise date formats for en-NZ (#409)",
    "Flaky snapshot test on CI (#423)", "Reduce launch time on older devices (#391)",
    "Accessibility labels missing on tab bar (#402)", "Bump design tokens to 2.4 (#426)",
    "Search field loses text when backgrounded (#414)", "Empty state illustration for inbox (#419)",
    "Onboarding: skip button overlaps on small screens (#428)", "Use system materials for the sidebar (#430)",
    "Crash when exporting an empty report (#433)", "Dynamic Type breaks the pricing table (#436)",
    "Remove deprecated colour tokens (#438)", "Sync indicator never stops spinning (#441)",
    "Add keyboard shortcuts for the review screen (#444)", "Profile photo upload fails on slow networks (#447)",
]
_UTTERANCES = [
    "Set a timer for 10 minutes", "What's the weather tomorrow?", "Remind me to water the plants at 6pm",
    "Play some jazz", "Text Alex I'm on my way", "Call Mum", "How long is my commute?",
    "Add oat milk to my shopping list", "What's on my calendar today?", "Turn on Do Not Disturb",
    "Find my iPad", "Navigate to Te Aro Climbing Gym", "Wake me up at 6:30", "What time is sunset?",
    "Play my morning playlist", "Send a message to Jamie", "Start an outdoor walk", "Show my photos from Queenstown",
]

# (title, organiser key or "robin", attendee keys, weekdays (0 = Monday), hour, minute, every n weeks, personal)
_MEETINGS = [
    ("Product standup", "aroha", ("lucas", "nina", "oliver", "hana"), (0, 2, 4), 9, 30, 1, False),
    ("Design review", "robin", ("aroha", "lucas", "nina"), (1,), 14, 0, 1, False),
    ("1:1 Aroha / Robin", "aroha", (), (3,), 11, 0, 1, False),
    ("Sprint planning", "oliver", ("aroha", "lucas", "nina", "hana"), (0,), 10, 30, 2, False),
    ("Sprint retro", "oliver", ("aroha", "lucas", "nina", "hana"), (4,), 15, 0, 2, False),
    ("Research readout", "nina", ("aroha", "lucas", "hana"), (2,), 15, 0, 4, False),
    ("All hands", "aroha", ("lucas", "nina", "oliver", "hana"), (4,), 16, 0, 4, False),
    ("Climbing night", "priya", ("mei", "sam"), (2,), 18, 0, 1, True),
    ("Family lunch", "helen", ("david", "jamie", "alex"), (6,), 12, 30, 4, True),
]
# One-off meetings: (title, organiser, attendees, days from now (negative = future), hour)
_ONE_OFFS = [
    ("Usability sessions", "nina", ("lucas",), 9, 10), ("Launch go/no-go", "aroha", ("lucas", "oliver"), 16, 16),
    ("Offsite planning", "aroha", ("oliver", "nina"), 44, 13), ("Interview panel", "aroha", ("oliver",), 23, 9),
    ("Quarterly budget review", "oliver", ("aroha",), 61, 11), ("Design critique", "robin", ("lucas", "nina", "hana"), 30, 15),
    ("Roadmap workshop", "aroha", ("lucas", "nina", "oliver", "hana"), 75, 10), ("Demo day", "oliver", ("lucas", "hana"), 5, 14),
    ("Portfolio review", "aroha", ("nina",), -6, 10), ("Launch retrospective", "oliver", ("aroha", "lucas", "nina"), -13, 14),
    ("Conference talk dry run", "robin", ("aroha", "nina"), -20, 15), ("Dinner with Priya and Tom", "priya", ("tom", "alex"), -3, 19),
]
_STOP_WORDS = {"and", "the", "with", "for", "from", "/"}


# ----------------------------------------------------------------------------------------
# Model
# ----------------------------------------------------------------------------------------

@dataclass(frozen=True)
class Party:
    """One end of a conversation as an app donates it."""
    name: str                       # "" when the handle is not a contact
    handle: str
    kind: Optional[str]             # phone / email / None (app-specific id)
    person: Optional[Person] = None
    label: Optional[str] = None


@dataclass
class Entity:
    id: str
    type: str
    fields: dict
    first: datetime.datetime
    last: datetime.datetime
    rowid: int = 0


@dataclass
class Interaction:
    id: str
    type: str
    domain: str
    bundle: str
    direction: int
    status: int
    start: datetime.datetime
    duration: float
    fields: dict
    siri: bool
    donor: int
    device: Device
    stream: str
    links: list = field(default_factory=list)            # [(parameter, Entity)]
    sender: Optional[Party] = None
    recipients: tuple = ()
    group: Optional[str] = None
    is_group: bool = False
    text: Optional[str] = None
    conversation: Optional[str] = None
    service: Optional[str] = None
    video: bool = False


@dataclass
class Channel:
    bundle: str
    people: Sequence[Person]
    scripts: list
    per_week: float                 # exchanges per week
    title: Optional[str] = None     # conversation name the app donates (None: none)
    group: bool = False
    work: bool = False
    first_day: int = HISTORY_DAYS   # days ago the conversation started
    last_day: int = 0
    specials: list = field(default_factory=list)   # [(days ago, script)] played once


def _poisson(rng: random.Random, mean: float) -> int:
    if mean <= 0:
        return 0
    limit, count, product = math.exp(-mean), 0, rng.random()
    while product > limit:
        count += 1
        product *= rng.random()
    return count


_PERSONAL_HOURS = {7: 2, 8: 5, 9: 3, 10: 2, 11: 2, 12: 5, 13: 4, 14: 2, 15: 2, 16: 3, 17: 6, 18: 8, 19: 8, 20: 7, 21: 6, 22: 3}
_WORK_HOURS = {8: 1, 9: 5, 10: 7, 11: 6, 12: 2, 13: 4, 14: 6, 15: 6, 16: 5, 17: 2}
_EVENING_HOURS = {17: 2, 18: 5, 19: 8, 20: 7, 21: 3}


class _World:
    """Builds the persona's year of interactions; the stores below are views of it."""

    def __init__(self, persona: Persona, rng: random.Random, clock: lib.Clock):
        self.persona, self.rng, self.clock = persona, rng, clock
        self.interactions: list[Interaction] = []
        self.entities: dict[tuple[str, str], Entity] = {}
        self.owner = persona.owner
        alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        self.slack_ids = {p.key: "U0" + "".join(rng.choice(alphabet) for _ in range(9)) for p in persona.people}
        self.labels = {p.key: rng.choice(["mobile", "mobile", "iPhone", None]) for p in persona.people}
        self.iphone, self.ipad, self.watch = persona.device("iphone"), persona.device("ipad"), persona.device("watch")
        self.places = {"cafe": persona.place("cafe").name, "gym": persona.place("gym").name}
        self.media_ids: dict[str, str] = {}

    # -- parties -------------------------------------------------------------------------
    def phone(self, p: Person) -> Party:
        if p.phone:
            return Party(p.full_name, p.phone, "phone", p, self.labels[p.key])
        return Party(p.full_name, p.email, "email", p)

    def mail(self, p: Person) -> Party:
        return Party(p.full_name, p.email, "email", p)

    def slack(self, p: Person) -> Party:
        return Party(p.full_name, self.slack_ids[p.key], None, p)

    def github(self, p: Person) -> Party:
        return Party(p.full_name, f"{p.given}-{p.family}".lower(), None, p)

    def party(self, p: Person, bundle: str) -> Party:
        if bundle == SLACK:
            return self.slack(p)
        if bundle == MAIL_IOS:
            return self.mail(p)
        if bundle == GITHUB:
            return self.github(p)
        return self.phone(p)

    # -- entities ------------------------------------------------------------------------
    def entity(self, identifier: str, kind: str, fields: dict, when: datetime.datetime) -> Entity:
        key = (identifier, kind)
        found = self.entities.get(key)
        if found is None:
            found = self.entities[key] = Entity(identifier, kind, fields, when, when)
        else:
            found.first, found.last = min(found.first, when), max(found.last, when)
        return found

    def handle(self, party: Party, when: datetime.datetime) -> Entity:
        fields: dict[str, Any] = {}
        if party.name:
            fields["name"] = party.name
        if party.kind:
            fields["type"] = party.kind
        if party.label:
            fields["label"] = party.label
        if party.kind == "phone" and party.handle.startswith("+"):
            fields["countryCode"] = "us"        # the fictional numbers are +1 …
        return self.entity(party.handle, "PersonHandle", fields, when)

    # -- time ----------------------------------------------------------------------------
    def moment(self, day: int, hours: dict[int, int]) -> datetime.datetime:
        hour = self.rng.choices(list(hours), weights=list(hours.values()))[0]
        return self.clock.at(day, hour, self.rng.randrange(60), self.rng.randrange(60))

    def weekday(self, day: int) -> int:
        return (self.clock.now.astimezone(self.clock.tz) - datetime.timedelta(days=day)).weekday()

    def season(self, day: int) -> float:
        """Slow variation over the year plus a quiet fortnight (a holiday)."""
        base = 1.0 + 0.22 * math.sin(day / 58.0) + 0.1 * math.sin(day / 17.0 + 1.3)
        return base * (0.45 if 148 <= day <= 161 else 1.0)

    def device_for(self, bundle: str, outgoing: bool = False) -> Device:
        roll = self.rng.random()
        if bundle in (SMS, MAIL_IOS, FACETIME_IOS) and roll < 0.09:
            return self.ipad
        if bundle in (SMS, PHONE, MUSIC) and roll > 0.955:
            return self.watch
        return self.iphone

    # -- interactions --------------------------------------------------------------------
    def add(self, interaction: Interaction) -> Interaction:
        self.interactions.append(interaction)
        return interaction

    def message(self, bundle: str, when: datetime.datetime, device: Device, incoming: bool, other: Sequence[Party],
                sender: Optional[Party], title: Optional[str], is_group: bool, text: Optional[str],
                conversation: Optional[str], service: Optional[str] = None) -> Interaction:
        rng = self.rng
        me = self.party(self.owner, bundle)
        item = Interaction(
            id=lib.uuid_string(rng), type=MESSAGE, domain="Messages", bundle=bundle, direction=IN if incoming else OUT,
            status=4 if rng.random() < 0.93 else 1, start=when, duration=0.0, fields={"isGroup": is_group}, siri=False, donor=2,
            device=device, stream="Siri.Remembers.MessageHistory", group=title, is_group=is_group, text=text,
            conversation=conversation, service=service)
        if incoming and sender is not None:
            item.sender, item.recipients = sender, (me,)
            item.links.append(("senderHandle", self.handle(sender, when)))
            item.links.append(("recipientHandles", self.handle(me, when)))
        else:
            item.recipients = tuple(other)
            for party in other:
                item.links.append(("recipientHandles", self.handle(party, when)))
        if title:
            item.links.append(("speakableGroupName", self.entity(title.lower(), "MessageGroup", {"name": title}, when)))
        return self.add(item)

    def fill(self, text: str) -> str:
        return text.format(code=self.rng.randrange(100_000, 1_000_000), **self.places)

    def play(self, channel: Channel, script: list, start: datetime.datetime, conversation: str) -> None:
        """One exchange: the script's lines a few seconds to minutes apart."""
        rng = self.rng
        when = start
        device = self.device_for(channel.bundle)
        members = [self.party(p, channel.bundle) for p in channel.people]
        service = None
        if channel.bundle == SMS:
            service = "iMessage"
        for direction, line in script:
            when = when + datetime.timedelta(seconds=rng.randint(8, 50) + rng.expovariate(1 / 70.0))
            if when >= self.clock.now:
                break
            incoming = direction == "i"
            sender = rng.choice(members) if incoming else None
            self.message(channel.bundle, when, device, incoming, members, sender, channel.title, channel.group,
                         self.fill(line), conversation, service)

    def run_channel(self, channel: Channel) -> None:
        rng = self.rng
        if channel.group:
            conversation = "chat" + str(rng.randrange(10 ** 17, 10 ** 18))
        elif channel.bundle == SLACK:
            conversation = "D0" + lib.hex_string(rng, 9).upper()
        else:
            conversation = self.party(channel.people[0], channel.bundle).handle
        if channel.bundle == SLACK and channel.group:
            conversation = "C0" + lib.hex_string(rng, 9).upper()
        hours = _WORK_HOURS if channel.work else _PERSONAL_HOURS
        deck: list = []
        last = None
        for day in range(channel.first_day, channel.last_day - 1, -1):
            weekday = self.weekday(day)
            if channel.work:
                factor = 1.25 if weekday < 5 else 0.04
            else:
                factor = 0.9 if weekday < 5 else 1.3
            for _ in range(_poisson(rng, channel.per_week / 7.0 * factor * self.season(day))):
                if not deck:        # every exchange once before any repeats
                    deck = rng.sample(channel.scripts, len(channel.scripts))
                    if deck[-1] is last and len(deck) > 1:
                        deck.reverse()
                last = deck.pop()
                self.play(channel, last, self.moment(day, hours), conversation)
        for day, script in channel.specials:
            self.play(channel, script, self.moment(day, hours), conversation)

    def call(self, bundle: str, party: Party, when: datetime.datetime, incoming: bool, seconds: float, video: bool = False,
             device: Optional[Device] = None) -> Interaction:
        rng = self.rng
        missed = seconds <= 0
        item = Interaction(
            id=lib.uuid_string(rng), type=CALL, domain="Calls", bundle=bundle, direction=IN if incoming else OUT,
            status=1 if (missed and incoming) or rng.random() < 0.05 else 4, start=when, duration=float(round(seconds, 2)),
            fields={"isGroup": False}, siri=False, donor=2, device=device or self.device_for(bundle),
            stream="Siri.Remembers.CallHistory", recipients=(party,), video=video)
        item.links.append(("contactHandles", self.handle(party, when)))
        if party.person is not None:
            identifier = party.person.contact_id.split(":")[0]
            item.links.append(("contacts", self.entity(identifier, "Person", {"name": party.name}, when)))
        return self.add(item)

    def other(self, kind: str, domain: str, bundle: str, when: datetime.datetime, stream: str, *, siri: bool = False,
              status: int = 1, donor: int = 2, fields: Optional[dict] = None, identifier: Optional[str] = None,
              device: Optional[Device] = None, duration: float = 0.0) -> Interaction:
        return self.add(Interaction(
            id=identifier or lib.uuid_string(self.rng), type=kind, domain=domain, bundle=bundle, direction=0, status=status,
            start=when, duration=duration, fields=fields or {}, siri=siri, donor=donor, device=device or self.iphone, stream=stream))

    # -- the year ------------------------------------------------------------------------
    def build(self) -> None:
        p = self.persona.person
        colleagues = [p("aroha"), p("lucas"), p("nina"), p("oliver"), p("hana")]
        channels = [
            Channel(SMS, [p("alex")], _PARTNER, 17.0, specials=_PARTNER_SPECIAL),
            Channel(SMS, [p("helen")], _MOTHER, 3.6, specials=_MOTHER_SPECIAL),
            Channel(SMS, [p("david")], _FATHER, 1.2),
            Channel(SMS, [p("jamie")], _SISTER, 4.2),
            Channel(SMS, [p("tom")], _FRIEND, 2.0),
            Channel(SMS, [p("helen"), p("david"), p("jamie")], _FAMILY_GROUP, 2.6, title="Sample whānau", group=True),
            Channel(WHATSAPP, [p("priya")], _FRIEND, 3.2, title=p("priya").full_name),
            Channel(WHATSAPP, [p("sam")], _FRIEND, 1.0, title=p("sam").full_name),
            Channel(WHATSAPP, [p("priya"), p("mei"), p("sam")], _CLIMBING_GROUP, 3.2, title="Climbing crew", group=True),
            Channel(WHATSAPP, [p("alex"), p("jamie"), p("priya")], _TRIP_GROUP, 6.0, title="Queenstown trip", group=True,
                    first_day=TRIP_DAY + 55, last_day=TRIP_DAY - 5),
            Channel(SIGNAL, [p("mei")], _FRIEND, 1.6, title=p("mei").full_name),
            Channel(SLACK, [p("aroha")], _MANAGER, 2.0, title=p("aroha").full_name, work=True),
            Channel(SLACK, [p("lucas")], _COLLEAGUE, 3.6, title=p("lucas").full_name, work=True),
            Channel(SLACK, [p("nina")], _COLLEAGUE, 2.6, title=p("nina").full_name, work=True),
            Channel(SLACK, [p("oliver")], _COLLEAGUE, 1.0, title=p("oliver").full_name, work=True),
            Channel(SLACK, [p("hana")], _COLLEAGUE, 1.0, title=p("hana").full_name, work=True, first_day=210),
            Channel(SLACK, colleagues[:4], _CHANNELS["#design"], 4.2, title="#design", group=True, work=True),
            Channel(SLACK, colleagues, _CHANNELS["#general"], 2.2, title="#general", group=True, work=True),
            Channel(SLACK, colleagues[:4], _CHANNELS["#launch-tui"], 3.4, title="#launch-tui", group=True, work=True, first_day=130),
        ]
        for channel in channels:
            self.run_channel(channel)
        self.service_texts()
        self.mail_and_tickets(colleagues)
        self.calls()
        self.other_memories()
        self.interactions.sort(key=lambda i: i.start)

    def service_texts(self) -> None:
        rng = self.rng
        for code, text, when in _SERVICE_SMS:
            party = Party("", code, "phone")
            if isinstance(when, tuple):
                period = when[1]
                days = [day + rng.randrange(-period // 4, period // 4 + 1) for day in range(rng.randrange(2, period), HISTORY_DAYS, period)]
            else:
                days = list(when)
            for day in days:
                if not 0 <= day <= HISTORY_DAYS:
                    continue
                at = self.moment(day, _PERSONAL_HOURS)
                item = self.message(SMS, at, self.iphone, True, [party], party, None, False, self.fill(text), code, "SMS")
                identifier = lib.uuid_string(rng)
                item.links.append(("sentMessages", self.entity(identifier, "Message", {"identifier": identifier}, at)))
        dentist = self.phone(self.persona.person("drlee"))
        for day in (DENTIST_DAY + 182, DENTIST_DAY + 1):
            at = self.clock.at(day, 10, 5)
            for direction, line in _DENTIST_SMS:
                at += datetime.timedelta(minutes=rng.randint(2, 40))
                self.message(SMS, at, self.iphone, direction == "i", [dentist], dentist if direction == "i" else None,
                             None, False, line, dentist.handle, "SMS")

    def mail_and_tickets(self, colleagues: list[Person]) -> None:
        rng = self.rng
        p = self.persona.person

        def mail(day: int, sender: Party, subject: str, hours: dict) -> None:
            when = self.moment(day, hours)
            self.message(MAIL_IOS, when, self.device_for(MAIL_IOS), True, [sender], sender, subject, False, None, None)
            if rng.random() < 0.14:      # a reply from the phone
                later = when + datetime.timedelta(minutes=rng.randint(4, 180))
                if later < self.clock.now:
                    self.message(MAIL_IOS, later, self.iphone, False, [sender], None, "Re: " + subject, False, None, None)

        for day in range(HISTORY_DAYS, -1, -1):
            weekday = self.weekday(day)
            if weekday < 5:
                for _ in range(_poisson(rng, 0.75 * self.season(day))):
                    subject = rng.choice(_WORK_SUBJECTS)
                    if rng.random() < 0.35:
                        subject = "Re: " + subject
                    mail(day, self.mail(rng.choice(colleagues)), subject, _WORK_HOURS)
            for _ in range(_poisson(rng, 0.16)):
                key = rng.choice(list(_PERSONAL_SUBJECTS))
                mail(day, self.mail(p(key)), rng.choice(_PERSONAL_SUBJECTS[key]), _PERSONAL_HOURS)
            for _ in range(_poisson(rng, 0.2)):
                key = rng.choice(list(_SERVICE_SUBJECTS))
                name, address = _SENDERS[key]
                mail(day, Party(name, address, "email"), rng.choice(_SERVICE_SUBJECTS[key]), _PERSONAL_HOURS)

        airline = Party(*_SENDERS["air"], "email")
        for day, subject in _TRIP_MAIL:
            mail(day, airline, subject, _PERSONAL_HOURS)

        # Issue-tracker notifications: each ticket is active for a couple of weeks.
        engineers = [p("lucas"), p("oliver"), p("nina")]
        for title in _GITHUB_TITLES:
            opened = rng.randrange(3, HISTORY_DAYS - 30)
            for _ in range(rng.randint(2, 7)):
                day = max(0, opened - rng.randrange(0, 16))
                if self.weekday(day) >= 5:
                    continue
                author = self.github(rng.choices(engineers, weights=[5, 3, 1])[0])
                self.message(GITHUB, self.moment(day, _WORK_HOURS), self.iphone, True, [author], author, title, False, None, None)

    def calls(self) -> None:
        rng = self.rng
        p = self.persona.person
        # (person key, app, calls per week, median seconds, share incoming, hours, video)
        plan = [
            ("alex", PHONE, 1.7, 110, 0.5, _PERSONAL_HOURS, False),
            ("helen", PHONE, 0.9, 1250, 0.6, _EVENING_HOURS, False),
            ("helen", FACETIME_IOS, 0.35, 1500, 0.5, _EVENING_HOURS, True),
            ("david", PHONE, 0.3, 300, 0.6, _EVENING_HOURS, False),
            ("jamie", PHONE, 0.55, 480, 0.5, _PERSONAL_HOURS, False),
            ("jamie", FACETIME_IOS, 0.3, 900, 0.5, _EVENING_HOURS, True),
            ("priya", WHATSAPP, 0.35, 420, 0.5, _PERSONAL_HOURS, False),
            ("mei", WHATSAPP, 0.15, 380, 0.5, _PERSONAL_HOURS, False),
            ("aroha", PHONE, 0.12, 240, 0.7, _WORK_HOURS, False),
            ("landlord", PHONE, 0.07, 150, 0.6, _WORK_HOURS, False),
            ("drlee", PHONE, 0.04, 95, 0.4, _WORK_HOURS, False),
        ]
        for key, bundle, per_week, median, incoming_share, hours, video in plan:
            party = self.phone(p(key))
            for day in range(HISTORY_DAYS, -1, -1):
                weekend = self.weekday(day) >= 5
                factor = (1.6 if weekend else 0.76) if hours is not _WORK_HOURS else (0.0 if weekend else 1.4)
                for _ in range(_poisson(rng, 1.35 * per_week / 7.0 * factor * self.season(day))):
                    incoming = rng.random() < incoming_share
                    connected = rng.random() > (0.2 if incoming else 0.12)
                    seconds = min(5400.0, rng.lognormvariate(math.log(median), 0.75)) if connected else 0.0
                    self.call(bundle, party, self.moment(day, hours), incoming, seconds, video)
        # Numbers that are not in Contacts: mostly missed, a few short conversations.
        strangers = [Party("", f"+1202555{number:04d}", "phone") for number in (151, 158, 163, 170, 177, 184)]
        for day in sorted(rng.sample(range(0, HISTORY_DAYS), 46)):
            answered = rng.random() < 0.3
            self.call(PHONE, rng.choice(strangers), self.moment(day, _WORK_HOURS), True, rng.uniform(15, 140) if answered else 0.0,
                      device=self.iphone)

    def media_item(self, title: str, artist: str, kind: str, when: datetime.datetime) -> Entity:
        key = f"{kind}|{title}|{artist}"
        if key not in self.media_ids:
            self.media_ids[key] = str(self.rng.randrange(10 ** 9, 10 ** 10))
        return self.entity(self.media_ids[key], "MediaItem", {"title": title, "artist": artist, "mediaType": kind}, when)

    def other_memories(self) -> None:
        rng = self.rng
        persona = self.persona
        audio, history, suggestions = "Siri.Remembers.AudioHistory", "Siri.Remembers.InteractionHistory", "Siri.Remembers.AssistantSuggestions"
        track_weights = [1.0 / (index + 1.5) for index in range(len(persona.tracks))]
        commute = {7: 3, 8: 6, 9: 2, 12: 2, 17: 5, 18: 5, 19: 3, 20: 3, 21: 2}
        for day in range(HISTORY_DAYS, -1, -1):
            for _ in range(_poisson(rng, 1.5 * self.season(day))):
                when = self.moment(day, commute)
                roll = rng.random()
                if roll < 0.22:
                    show, episode = rng.choice(persona.podcasts)
                    bundle, entity = PODCASTS, self.media_item(episode, show, "podcastEpisode", when)
                else:
                    track = rng.choices(persona.tracks, weights=track_weights)[0]
                    bundle, entity = (MUSIC if roll < 0.74 else SPOTIFY), self.media_item(track.title, track.artist, "song", when)
                item = self.other("INPlayMediaIntent", "Media", bundle, when, audio, status=4 if rng.random() < 0.6 else 1,
                                  device=self.device_for(MUSIC))
                item.links.append(("items", entity))
            if rng.random() < 0.3:
                self.other("INRunWorkflowIntent", "Workflow", "com.apple.shortcuts", self.moment(day, commute), history)
            if rng.random() < 0.15:
                self.other("INAddTasksIntent", "Notebook", "com.apple.reminders", self.moment(day, _PERSONAL_HOURS), history, siri=True, status=4)
            if rng.random() < 0.13:
                self.other("WeatherIntent", "", "com.apple.weather", self.moment(day, {7: 5, 8: 4, 17: 1}), history)
            if rng.random() < 0.04:
                self.other("LocateDeviceIntent", "", "com.apple.findmy", self.moment(day, _PERSONAL_HOURS), history)
            if rng.random() < 0.022:
                self.other("LocateIntent", "", "com.apple.findmy", self.moment(day, _PERSONAL_HOURS), history)
            if rng.random() < 0.014:
                self.other("CNUICreateContactIntent", "", "com.apple.MobileAddressBook", self.moment(day, _PERSONAL_HOURS), history)
            for _ in range(_poisson(rng, 0.42)):
                when = self.moment(day, _PERSONAL_HOURS)
                shown = rng.sample(_UTTERANCES, rng.randint(2, 3))
                item = self.other(
                    "GetSuggestions_assistantSuggestions", "", "com.apple.siri", when, suggestions, siri=True, donor=1,
                    identifier=f"{lib.uuid_string(rng)}-{lib.hex_string(rng, 16)}",
                    fields={"InvocationType": rng.choice(["voice", "typeToSiri"]),
                            "SELFConversionProcessor_NotConverted": [_slug(u) for u in shown],
                            "FeatureEngagementBiomePostConversionProcessor_NotConverted": [_slug(u) for u in shown]})
                for utterance in shown:
                    item.links.append(("SuggestionEntities", self.suggestion(utterance, when)))
                if rng.random() < 0.27:
                    later = when + datetime.timedelta(seconds=rng.randint(3, 40))
                    if later < self.clock.now:
                        used = self.other(
                            "DirectEngagement", "", "com.apple.siri", later, suggestions, siri=True, donor=1,
                            identifier=f"{lib.uuid_string(rng)}-{lib.hex_string(rng, 16)}",
                            fields={"InvocationType": "voice", "FeatureEngagementBiomePostConversionProcessor_Engaged": True})
                        used.links.append(("SuggestionEntities", self.suggestion(shown[0], later)))

    def suggestion(self, utterance: str, when: datetime.datetime) -> Entity:
        return self.entity("suggestion." + _slug(utterance), "SuggestionAction",
                           {"exampleUtterance": utterance, "address": "", "hasSpatialEventTrigger": "false"}, when)


def _slug(text: str) -> str:
    return "".join(ch if ch.isalnum() else "-" for ch in text.lower()).strip("-")


# ----------------------------------------------------------------------------------------
# Siri Remembers: view.db and the Biome streams
# ----------------------------------------------------------------------------------------

_VIEW_DDL = """
CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
CREATE TABLE "configs" ("key" TEXT PRIMARY KEY, "value" TEXT);
CREATE TABLE "processedInteractions" ("id" TEXT PRIMARY KEY, "date" DATETIME);
CREATE TABLE "interactions" ("rowid" INTEGER PRIMARY KEY AUTOINCREMENT, "id" TEXT UNIQUE, "domain" TEXT NOT NULL COLLATE NOCASE,
 "type" TEXT NOT NULL COLLATE NOCASE, "bundleId" TEXT NOT NULL COLLATE NOCASE, "isDonatedBySiri" BOOLEAN NOT NULL,
 "direction" INTEGER NOT NULL, "handlingStatus" INTEGER NOT NULL, "startDate" DATETIME NOT NULL, "durationSeconds" DOUBLE NOT NULL,
 "fields" TEXT, "contentHash" INTEGER NOT NULL, "donorStream" INTEGER NOT NULL DEFAULT 0,
 "biomeEventTimestamp" DOUBLE NOT NULL DEFAULT 0, "isLocal" BOOLEAN NOT NULL DEFAULT 1, "devicePlatform" INTEGER NOT NULL DEFAULT 0,
 "userDonatorType" INTEGER NOT NULL DEFAULT 0, "sourceStreams" TEXT NOT NULL DEFAULT '', "remoteDeviceId" TEXT);
CREATE TABLE "entities" ("rowid" INTEGER PRIMARY KEY AUTOINCREMENT, "id" TEXT NOT NULL, "type" TEXT NOT NULL COLLATE NOCASE,
 "fields" TEXT NOT NULL, "fieldsTokens" TEXT NOT NULL, "createdAt" DATETIME NOT NULL, "updatedAt" DATETIME NOT NULL, UNIQUE ("id", "type"));
CREATE TABLE "interactionEntities" ("interactionRowid" INTEGER NOT NULL REFERENCES "interactions"("rowid") ON DELETE CASCADE,
 "entityRowid" INTEGER NOT NULL REFERENCES "entities"("rowid") ON DELETE CASCADE, "parameter" TEXT NOT NULL COLLATE NOCASE,
 PRIMARY KEY ("interactionRowid", "entityRowid"));
CREATE TABLE "diff" ("interactionIdentifier" TEXT PRIMARY KEY ON CONFLICT REPLACE, "updatedTimestamp" DOUBLE);
CREATE TABLE "entityIdMapping" ("hashedIdentifier" TEXT PRIMARY KEY ON CONFLICT REPLACE, "localIdentifier" TEXT, "updatedTimestamp" DOUBLE);
CREATE INDEX "interactions_startDate" ON "interactions" ("startDate");
CREATE INDEX "interactionEntities_entity" ON "interactionEntities" ("entityRowid", "interactionRowid");
"""
_VIEW_MIGRATIONS = [
    "001: Initial Schema", "002: donorStream to Int", "003: donorStream reset to 0", "004: Add biomeEventTimestamp",
    "005: Add interactions_sourceStreams", "006: Add isLocal and devicePlatform", "007: Add userDonatorType column",
    "008: Redo source column", "009: Add diff table", "010: isLocal index", "011: biomeEventTimestamp index",
    "012: Add stats table", "013: Update the stats table", "014: Add remoteDeviceId", "015: Add persistent identifier mapping",
]
_VIEW_FTS = """
CREATE VIRTUAL TABLE "entitiesFTS" USING fts5(fieldsTokens, content='entities', content_rowid='rowid');
CREATE TRIGGER "__entitiesFTS_ai" AFTER INSERT ON "entities" BEGIN
    INSERT INTO "entitiesFTS"("rowid", "fieldsTokens") VALUES (new."rowid", new."fieldsTokens");
END;
"""


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _tokens(entity: Entity) -> str:
    words = [str(v) for v in entity.fields.values() if isinstance(v, str)] or [entity.id]
    return " ".join(words).lower()


def _sql_date(value: datetime.datetime) -> str:
    return value.astimezone(lib.UTC).strftime("%Y-%m-%d %H:%M:%S.") + f"{value.microsecond // 1000:03d}"


def _write_view(root: pathlib.Path, world: _World, rng: random.Random) -> None:
    path = lib.library(root, "IntelligencePlatform/Artifacts/siri/remembers/view.db")
    with lib.sqlite_db(path, _VIEW_DDL) as con:
        try:
            for statement in lib.split_sql(_VIEW_FTS):
                con.execute(statement)
        except sqlite3.OperationalError:
            pass                                    # this Python's SQLite has no FTS5: the readers do not need it
        lib.insert(con, "grdb_migrations", [(name,) for name in _VIEW_MIGRATIONS])
        entity_rowid = 0
        for rowid, item in enumerate(world.interactions, start=1):
            for _, entity in item.links:
                if entity.rowid == 0:
                    entity_rowid += 1
                    entity.rowid = entity_rowid
                    con.execute('INSERT INTO "entities" VALUES (?, ?, ?, ?, ?, ?, ?)',
                                (entity.rowid, entity.id, entity.type, _json(entity.fields), _tokens(entity),
                                 _sql_date(entity.first), _sql_date(entity.last)))
            start = lib.cocoa(item.start)
            con.execute(
                'INSERT INTO "interactions" VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                (rowid, item.id, item.domain, item.type, item.bundle, 1 if item.siri else 0, item.direction, item.status, start,
                 item.duration, _json(item.fields), rng.randrange(-(1 << 62), 1 << 62), item.donor, start + rng.uniform(0.2, 4.0),
                 0, item.device.platform, 3, f"^{item.stream}:remotes:{item.device.identifier}^", item.device.identifier))
            seen: set[int] = set()
            for parameter, entity in item.links:
                if entity.rowid not in seen:
                    seen.add(entity.rowid)
                    con.execute('INSERT INTO "interactionEntities" VALUES (?, ?, ?)', (rowid, entity.rowid, parameter))
            con.execute('INSERT INTO "processedInteractions" VALUES (?, ?)', (item.id, _sql_date(item.start)))


def _stream_payload(item: Interaction) -> bytes:
    """`Siri.Remembers.*` record: 1 { interaction } 2* { parameter, entities }."""
    head = [(1, item.id), (2, item.type), (3, item.domain or None), (4, item.bundle), (5, item.status), (6, item.direction),
            (8, lib.cocoa(item.start)), (9, float(item.duration)), (11, _json(item.fields))]
    groups: dict[str, list[Entity]] = {}
    for parameter, entity in item.links:
        groups.setdefault(parameter, []).append(entity)
    message: list[tuple[int, Any]] = [(1, head)]
    for parameter, entities in groups.items():
        body: list[tuple[int, Any]] = [(1, parameter)]
        for entity in entities:
            body.append((2, [(1, entity.id), (2, entity.type), (4, _json(entity.fields)), (5, _tokens(entity))]))
        message.append((2, body))
    return pb.message(message)


def _write_streams(root: pathlib.Path, world: _World, rng: random.Random) -> None:
    buckets: dict[tuple[str, str], list] = {}
    for item in world.interactions:
        records = buckets.setdefault((item.stream, item.device.identifier), [])
        payload = _stream_payload(item)
        records.append((item.start + datetime.timedelta(seconds=rng.uniform(0.2, 4.0)), payload))
        if item.type == CALL and rng.random() < 0.03:       # a call is sometimes donated twice
            records.append((item.start + datetime.timedelta(seconds=item.duration + rng.uniform(1, 5)), payload))
    for (stream, device), records in sorted(buckets.items()):
        lib.write_stream(lib.biome_stream_dir(root, stream), records, device=device, max_records=2500)


# ----------------------------------------------------------------------------------------
# Shared stores: opened without replacing what another generator wrote
# ----------------------------------------------------------------------------------------

@contextlib.contextmanager
def _shared_db(path: pathlib.Path, ddl: str) -> Iterator[sqlite3.Connection]:
    """Opens a store that several generators write (knowledgeC.db, the kvs caches), creating
    it when missing. `ddl` must be `CREATE TABLE IF NOT EXISTS …` statements: existing
    tables and rows are kept. (`lib.sqlite_db` always starts a new file.)"""
    lib.ensure_parent(path)
    con = sqlite3.connect(str(path), isolation_level=None)
    try:
        con.execute("PRAGMA journal_mode=DELETE")
        con.execute("BEGIN")
        for statement in lib.split_sql(ddl):
            con.execute(statement)
        yield con
        con.execute("COMMIT")
    except BaseException:
        if con.in_transaction:
            con.execute("ROLLBACK")
        raise
    finally:
        con.close()


def _ensure_columns(con: sqlite3.Connection, table: str, columns: dict[str, str]) -> None:
    """Adds the columns this generator fills when another generator created a narrower table."""
    present = {row[1] for row in con.execute(f'PRAGMA table_info("{table}")')}
    for name, kind in columns.items():
        if name not in present:
            con.execute(f'ALTER TABLE "{table}" ADD COLUMN "{name}" {kind}')


def _next_pk(con: sqlite3.Connection, table: str) -> int:
    return (con.execute(f'SELECT coalesce(max(Z_PK), 0) FROM "{table}"').fetchone()[0] or 0) + 1


def _coredata_shared(con: sqlite3.Connection, entities: dict[str, tuple[int, int]], tables: dict[str, str], rng: random.Random) -> None:
    """CoreData bookkeeping for a shared store: adds missing entity rows, refreshes Z_MAX."""
    con.execute("CREATE TABLE IF NOT EXISTS Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER)")
    con.execute("CREATE TABLE IF NOT EXISTS Z_METADATA (Z_VERSION INTEGER PRIMARY KEY, Z_UUID VARCHAR(255), Z_PLIST BLOB)")
    con.execute("CREATE TABLE IF NOT EXISTS Z_MODELCACHE (Z_CONTENT BLOB)")
    for name, (number, parent) in entities.items():
        con.execute("INSERT OR IGNORE INTO Z_PRIMARYKEY VALUES (?, ?, ?, 0)", (number, name, parent))
    for name, table in tables.items():
        con.execute(f'UPDATE Z_PRIMARYKEY SET Z_MAX = (SELECT coalesce(max(Z_PK), 0) FROM "{table}") WHERE Z_NAME = ?', (name,))
    if con.execute("SELECT count(*) FROM Z_METADATA").fetchone()[0] == 0:
        con.execute("INSERT INTO Z_METADATA VALUES (1, ?, ?)",
                    (lib.uuid_string(rng), lib.plist_bytes({"NSStoreType": "SQLite", "NSStoreModelVersionIdentifiers": [""]})))


# ----------------------------------------------------------------------------------------
# knowledgeC.db — /app/intents
# ----------------------------------------------------------------------------------------

# ZSTRUCTUREDMETADATA has one column per metadata key, `Z_<GROUP>__<FIELD>`. Group -> fields
# with their type (I INTEGER, F FLOAT, T TIMESTAMP, V VARCHAR, B BLOB); "" holds the columns
# without a group. Column names only — this is the store's schema.
_T = {"I": "INTEGER", "F": "FLOAT", "T": "TIMESTAMP", "V": "VARCHAR", "B": "BLOB"}
_STRUCTURED = {
    "Z_CDPORTRAITMETADATAKEY": "ALGORITHM:I ASSETVERSION:I COMPATIBILITYVERSION:I DECAYRATE:F SCORE:F SENTIMENTSCORE:F OSBUILD:V",
    "Z_CDENTITYMETADATAKEY": "BESTLANGUAGE:V NAME:V",
    "Z_DKALARMMETADATAKEY": "ISSLEEP:I ALARMID:V",
    "Z_DKAPPINSTALLMETADATAKEY": "ISINSTALL:I PRIMARYCATEGORY:V TITLE:V SUBCATEGORIES:B",
    "Z_DKAPPLICATIONACTIVITYMETADATAKEY": "BEGINNINGOFACTIVITY:I ISELIGIBLEFORPREDICTION:I ISPUBLICLYINDEXABLE:I SHORTCUTAVAILABILITY:I "
                                          "EXPIRATIONDATE:T ACTIVITYTYPE:V CONTENTDESCRIPTION:V ITEMIDENTIFIER:V ITEMRELATEDUNIQUEIDENTIFIER:V "
                                          "SUGGESTEDINVOCATIONPHRASE:V TITLE:V USERACTIVITYREQUIREDSTRING:V USERACTIVITYUUID:V ITEMRELATEDCONTENTURL:V",
    "Z_DKAPPLICATIONMETADATAKEY": "DYLDPLATFORM:I ISNATIVEARCHITECTURE:I PROCESSIDENTIFIER:I BACKBOARDSTATE:V "
                                  "EXTENSIONCONTAININGBUNDLEIDENTIFIER:V EXTENSIONHOSTIDENTIFIER:V LAUNCHREASON:V",
    "Z_DKAUDIOMETADATAKEY": "ROUTECHANGEREASON:I CHANNELS:V DATASOURCES:V IDENTIFIER:V PORTNAME:V PORTTYPE:V PREFERREDDATASOURCE:V SELECTEDDATASOURCE:V",
    "Z_DKBLUETOOTHMETADATAKEY": "BATTERYLEVELHEADPHONECASE:I BATTERYLEVELHEADPHONELEFT:I BATTERYLEVELHEADPHONERIGHT:I DEVICETYPE:I "
                                "ISAPPLEAUDIODEVICE:I ISUSERWEARING:I PRODUCTID:I ADDRESS:V NAME:V",
    "Z_DKBULLETINBOARDMETADATAKEY": "HASDATE:I FEED:V MESSAGE:V SUBTITLE:V TITLE:V",
    "Z_DKDEVICEBATTERYPERCENTAGEMETADATAKEY": "FULLYCHARGED:I",
    "Z_DKDEVICEISPLUGGEDINMETADATAKEY": "ADAPTERISWIRELESS:I ADAPTERTYPE:I",
    "Z_DKDIGITALHEALTHMETADATAKEY": "ISUSAGETRUSTED:I USAGETYPE:I SAFARIPROFILEID:V WEBDOMAIN:V WEBPAGEURL:V",
    "Z_DKDISCOVERABILITYUSAGEMETADATAKEY": "CONTENTTYPE:I INELIGIBLEREASON:I STATE:I BUNDLEID:V CONTEXT:V OSBUILD:V ANALYTICSEVENT:B ELIGIBLECONTEXT:B",
    "Z_DKDISCOVERABILITYSIGNALSMETADATAKEY": "CONTEXT:V OSBUILD:V USERINFO:B",
    "Z_DKGLANCELAUNCHMETADATA": "DEVICEIDENTIFIER:I",
    "Z_DKINTENTMETADATAKEY": "DIRECTION:I DONATEDBYSIRI:I INTENTHANDLINGSTATUS:I INTENTTYPE:I SHORTCUTAVAILABILITY:I DERIVEDINTENTIDENTIFIER:V "
                             "INTENTCLASS:V INTENTVERB:V INTERACTIONIDENTIFIER:V RELATEDCONTACTIDENTIFIERS:V SERIALIZEDINTERACTION:B",
    "Z_DKMETADATAHOMEKITACCESSORYCONTROL": "ELIGIBLEFORSUGGESTIONS:I HOMEOCCUPANCY:I ACCESSORYNAME:V ACCESSORYUUID:V CHARACTERISTICTYPE:V "
                                           "CLIENTNAME:V HOMEUUID:V SERVICENAME:V SERVICETYPE:V SERVICEUUID:V SOURCE:V ACCESSORYSTATE:B",
    "Z_DKMETADATAHOMEKITSCENE": "HOMEOCCUPANCY:I ACTIONSETNAME:V ACTIONSETTYPE:V ACTIONSETUUID:V CLIENTNAME:V HOMEUUID:V SCENENAME:V SOURCE:V "
                                "ASSOCIATEDACCESSORYUUIDS:B",
    "Z_DKMETADATAHOMEAPPVIEW": "HOMEUUID:V VIEWINFORMATION:V VIEWNAME:V VIEWUUID:V",
    "Z_DKMICROLOCATIONMETADATAKEY": "MICROLOCATIONISSTABLE:I DOMAIN:V LOCATIONDISTRIBUTION:V MICROLOCATIONDISTRIBUTION:V PROBABILITYVECTOR:B",
    "Z_DKNOWPLAYINGMETADATAKEY": "ITUNESSTOREIDENTIFIER:I ITUNESSUBSCRIPTIONIDENTIFIER:I IDENTIFIER:I ISAIRPLAYVIDEO:I PLAYING:I DURATION:F "
                                 "ELAPSED:F ALBUM:V ARTIST:V GENRE:V MEDIATYPE:V TITLE:V OUTPUTDEVICEIDS:B",
    "Z_DKSEARCHFEEDBACKMETADATAKEY": "INTERACTIONTYPE:I SUGGESTIONTYPE:I CLIENT:V CONTACTID:V",
    "Z_DKSHARESHEETFEEDBACKMETADATAKEY": "ENGAGEMENTTYPE:I ICLOUDFAMILYINVOCATION:I INDEXSELECTED:I ISADAPTEDMODELCREATED:I ISADAPTEDMODELUSED:I "
                                         "PEOPLESUGGESTIONSDISABLED:I NUMBEROFVISIBLESUGGESTIONS:F ADAPTEDMODELRECIPEID:V DERIVEDINTENTIDENTIFIER:V "
                                         "EXTENSIONCONTEXTUUID:V REASON:V REASONTYPE:V SOURCEBUNDLEID:V SUPPORTEDBUNDLEIDS:V TARGETBUNDLEID:V "
                                         "TRACKINGID:V TRANSPORTBUNDLEID:V ATTACHMENTS:B LOCATIONUUIDS:B MODELSUGGESTIONPROXIES:B PHOTOSUGGESTEDCONTACTS:B",
    "Z_DKSHARESHEETSUGGESTLESSFEEDBACKMETADATAKEY": "BUNDLEID:V CONTACTID:V CONVERSATIONIDENTIFIER:V DERIVEDINTENTIDENTIFIER:V HANDLE:V",
    "Z_DKSHARESHEETSUGGESTIONMETADATAKEY": "DERIVEDINTENTIDENTIFIER:V EXTENSIONCONTEXTUUID:V SOURCEBUNDLEID:V TARGETBUNDLEID:V",
    "Z_QPMETRICSMETADATAKEY": "QUERYENGAGED:I RESULTENGAGED:I TIMESTAMP:F QUERY:V CANDIDATELIST:B QUERYLIST:B",
    "Z_DKAPPCLIPUSAGEMETADATAKEY": "TIMESINCEDOWNLOAD:F URLHASH:V APPBUNDLEID:V CLIPBUNDLEID:V LAUNCHREASON:V REFERRERBUNDLEID:V "
                                   "WEBAPPBUNDLEID:V FULLURL:V REFERRERURL:V",
    "Z_DKAPPMEDIAUSAGEMETADATAKEY": "URL:V MEDIAURL:V",
    "Z_DKLOCATIONAPPLICATIONACTIVITYMETADATAKEY": "LATITUDE:F LONGITUDE:F URL:V CITY:V COUNTRY:V DISPLAYNAME:V FULLYFORMATTEDADDRESS:V "
                                                  "LOCATIONNAME:V POSTALCODE_V2:V STATEORPROVINCE:V SUBTHOROUGHFARE:V THOROUGHFARE:V PHONENUMBERS:B",
    "Z_DKLOCATIONMETADATAKEY": "ALTITUDE:F LATITUDE:F LONGITUDE:F IDENTIFIER:V",
    "Z_DKPERIODMETADATAKEY": "PERIODEND:T PERIODSTART:T",
    "Z_DKAIRPLAYPREDICTIONMETADATAKEY": "OUTPUTDEVICEID:V SUBTYPE:V",
    "Z_DKBATTERYSAVERMETADATAKEY": "SOURCE:V",
    "Z_DKCALENDARMETADATAKEY": "INTERACTION:V",
    "Z_DKCALLMETADATAKEY": "INTERACTION:V",
    "Z_DKDEVICEIDMETADATAKEY": "DEVICEIDENTIFIER:V",
    "Z_DKDEVICESTANDBYTIMERMETADATAKEY": "DELAY:V TIMERTYPE:V",
    "Z_DKMAPSSHAREETAFEEDBACKMETADATAKEY": "CONTACTID:V NAVIGATIONENDLOCATIONIDENTIFIER:V NAVIGATIONSTARTLOCATIONIDENTIFIER:V",
    "Z_DKNOTIFICATIONUSAGEMETADATAKEY": "BUNDLEID:V IDENTIFIER:V",
    "Z_DKPHOTOSMETADATAKEY": "IDENTIFIER:V SUBSET:V",
    "Z_DKRELEVANTSHORTCUTMETADATAKEY": "KEYIMAGEPROXYIDENTIFIER:V SERIALIZEDRELEVANTSHORTCUT:B",
    "Z_DKSAFARIHISTORYMETADATAKEY": "TITLE:V",
    "Z_DKSIRIINTENTEVENTMETADATAKEY": "EVENTTYPE:V EVENTDATA:B",
    "Z_DKSIRISERVICEMETADATAKEY": "DOMAIN:V",
    "Z_DKTIMERMETADATAKEY": "TIMERID:V",
    "Z_DKTOMBSTONEMETADATAKEY": "EVENTSOURCEDEVICEID:V EVENTSTREAMNAME:V",
    "Z_DKBEHAVIORALRULEFEATURESMETADATAKEY": "FEATUREDICT:B",
    "Z_DKFAMILYPREDICTIONMETADATAKEY": "SUGGESTIONS:B",
    "Z_DKPEOPLESUGGESTEROUTPUTFORSIRINLMETADATAKEY": "RANKEDSUGGESTIONS:B",
    "": "ZCOM_APPLE_CALENDARUIKIT_USERACTIVITY_DATE:I ZCOM_APPLE_CALENDARUIKIT_USERACTIVITY_ENDDATE:I "
        "ZCOM_APPLE_CALENDARUIKIT_USERACTIVITY_EXTERNALID:V ZKCDCSNOTIFICATIONOPTIONCLIENTIDENTIFIERKEY:V "
        "ZKCDCSNOTIFICATIONOPTIONCLIENTLAUNCHKEY:V ZKCDCSNOTIFICATIONOPTIONPERSISTENTPREDICATESTRINGKEY:V ZMETADATAHASH:V",
}


def _structured_columns() -> dict[str, str]:
    columns: dict[str, str] = {}
    for group, fields in _STRUCTURED.items():
        for item in fields.split():
            name, kind = item.split(":")
            columns[f"{group}__{name}" if group else name] = _T[kind]
    return columns


_OBJECT_COLUMNS = (
    "ZUUIDHASH INTEGER, ZEVENT INTEGER, ZSOURCE INTEGER, ZCATEGORYTYPE INTEGER, ZINTEGERVALUE INTEGER, ZCOMPATIBILITYVERSION INTEGER, "
    "ZENDDAYOFWEEK INTEGER, ZENDSECONDOFDAY INTEGER, ZHASCUSTOMMETADATA INTEGER, ZHASSTRUCTUREDMETADATA INTEGER, ZSECONDSFROMGMT INTEGER, "
    "ZSHOULDSYNC INTEGER, ZSTARTDAYOFWEEK INTEGER, ZSTARTSECONDOFDAY INTEGER, ZVALUECLASS INTEGER, ZVALUEINTEGER INTEGER, "
    "ZVALUETYPECODE INTEGER, ZSTRUCTUREDMETADATA INTEGER, ZVALUE INTEGER, Z9_VALUE INTEGER, ZIDENTIFIERTYPE INTEGER, ZQUANTITYTYPE INTEGER, "
    "ZCREATIONDATE TIMESTAMP, ZLOCALCREATIONDATE TIMESTAMP, ZCONFIDENCE FLOAT, ZENDDATE TIMESTAMP, ZSTARTDATE TIMESTAMP, "
    "ZVALUEDOUBLE FLOAT, ZDOUBLEVALUE FLOAT, ZUUID VARCHAR, ZSTREAMNAME VARCHAR, ZVALUESTRING VARCHAR, ZSTRING VARCHAR, ZMETADATA BLOB")
_SOURCE_COLUMNS = "ZUSERID INTEGER, ZBUNDLEID VARCHAR, ZDEVICEID VARCHAR, ZGROUPID VARCHAR, ZINTENTID VARCHAR, ZITEMID VARCHAR, ZSOURCEID VARCHAR"


def _columns(text: str) -> dict[str, str]:
    return dict(part.strip().split(" ", 1) for part in text.split(","))


_Z = "Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER"
_KNOWLEDGE_DDL = f"""
CREATE TABLE IF NOT EXISTS ZOBJECT ({_Z}, {_OBJECT_COLUMNS});
CREATE TABLE IF NOT EXISTS ZSOURCE ({_Z}, {_SOURCE_COLUMNS});
CREATE TABLE IF NOT EXISTS ZSTRUCTUREDMETADATA ({_Z}, {", ".join(f"{n} {t}" for n, t in _structured_columns().items())});
CREATE TABLE IF NOT EXISTS ZCUSTOMMETADATA ({_Z}, ZINTEGERVALUE INTEGER, ZOBJECT INTEGER, Z9_OBJECT INTEGER, ZDATEVALUE TIMESTAMP, ZDOUBLEVALUE FLOAT, ZNAME VARCHAR, ZSTRINGVALUE VARCHAR, ZVALUEHASH VARCHAR, ZBINARYVALUE BLOB);
CREATE TABLE IF NOT EXISTS Z_4EVENT (Z_4CUSTOMMETADATA INTEGER, Z_11EVENT INTEGER, PRIMARY KEY (Z_4CUSTOMMETADATA, Z_11EVENT));
CREATE TABLE IF NOT EXISTS ZADDITIONCHANGESET ({_Z}, ZSEQUENCENUMBER INTEGER, ZVERSION INTEGER, ZENDDATE TIMESTAMP, ZSTARTDATE TIMESTAMP, ZCKFOREIGNKEY VARCHAR, ZCKRECORDID VARCHAR, ZDEVICEIDENTIFIER VARCHAR, ZCHANGESET BLOB, ZCKRECORDSYSTEMFIELDS BLOB);
CREATE TABLE IF NOT EXISTS ZDELETIONCHANGESET ({_Z}, ZSEQUENCENUMBER INTEGER, ZVERSION INTEGER, ZENDDATE TIMESTAMP, ZSTARTDATE TIMESTAMP, ZCKFOREIGNKEY VARCHAR, ZCKRECORDID VARCHAR, ZDEVICEIDENTIFIER VARCHAR, ZCHANGESET BLOB, ZCKRECORDSYSTEMFIELDS BLOB);
CREATE TABLE IF NOT EXISTS ZCONTEXTUALCHANGEREGISTRATION ({_Z}, ZISACTIVE INTEGER, ZISMULTIDEVICEREGISTRATION INTEGER, ZCREATIONDATE TIMESTAMP, ZIDENTIFIER VARCHAR, ZPROPERTIES BLOB);
CREATE TABLE IF NOT EXISTS ZCONTEXTUALKEYPATH ({_Z}, ZDEVICEID INTEGER, ZISEPHEMERAL INTEGER, ZISUSERCENTRIC INTEGER, ZCREATIONDATE TIMESTAMP, ZLASTMODIFIEDDATE TIMESTAMP, ZDEVICEIDSTRING VARCHAR, ZKEY VARCHAR, ZVALUE BLOB);
CREATE TABLE IF NOT EXISTS ZHISTOGRAM ({_Z}, ZSTREAMTYPECODE INTEGER, ZENDDATE TIMESTAMP, ZSTARTDATE TIMESTAMP, ZCUSTOMIDENTIFIER VARCHAR, ZDEVICEIDENTIFIER VARCHAR, ZIDENTIFIER VARCHAR, ZSTREAMNAME VARCHAR);
CREATE TABLE IF NOT EXISTS ZHISTOGRAMVALUE ({_Z}, ZINTEGERVALUE INTEGER, ZHISTOGRAM INTEGER, ZCOUNT FLOAT, ZSTRINGVALUE VARCHAR);
CREATE TABLE IF NOT EXISTS ZKEYVALUE ({_Z}, ZDOMAIN VARCHAR, ZKEY VARCHAR, ZVALUE BLOB);
CREATE TABLE IF NOT EXISTS ZSYNCPEER ({_Z}, ZLASTSEENDATE TIMESTAMP, ZCLOUDID VARCHAR, ZDEVICEID VARCHAR, ZMODEL VARCHAR, ZRAPPORTID VARCHAR, ZVERSION VARCHAR, ZUUID BLOB);
"""
_KNOWLEDGE_ENTITIES = {
    "AdditionChangeSet": (1, 0), "ContextualChangeRegistration": (2, 0), "ContextualKeyPath": (3, 0), "CustomMetadata": (4, 0),
    "DeletionChangeSet": (5, 0), "Histogram": (6, 0), "HistogramValue": (7, 0), "KeyValue": (8, 0), "Object": (9, 0),
    "Category": (10, 9), "Event": (11, 9), "Identifier": (12, 9), "Quantity": (13, 9), "Source": (14, 0),
    "StructuredMetadata": (15, 0), "SyncPeer": (16, 0),
}


def _contact(party: Party) -> list:
    """`_INPBContact`: 1 { 2 contact id } 2 first 3 last 4 display 7 { 1 handle 2 type } 8 custom id."""
    person = party.person
    handle_type = {"email": 1, "phone": 2}.get(party.kind or "")
    return [(1, [(2, person.contact_id)] if person else None),
            (2, person.given if person else None), (3, person.family if person else None),
            (4, party.name or None),
            (7, [(1, party.handle), (2, handle_type)]),
            (8, party.handle if party.kind is None else None)]


def _serialized_interaction(item: Interaction, rng: random.Random) -> bytes:
    """NSKeyedArchiver { root: NSData } wrapping NSKeyedArchiver { root: INInteraction }."""
    incoming = item.direction == IN
    if item.type == MESSAGE:
        proto = pb.message([
            (1, [(2, item.bundle)]),
            (2, [(1, _contact(party)) for party in item.recipients]),
            (5, [(1, [(2, item.text)])] if item.text else None),
            (7, [(1, item.group)] if item.group else None),
            (8, item.conversation),
            (9, item.service),
            (10, [(1, _contact(item.sender))] if item.sender else None),
        ])
        metadata = lib.ArchiveObject("INSendMessageIntentDonationMetadata", {
            "businessChat": False, "mentionsCurrentUser": False, "notifyRecipientAnyway": False,
            "recipientCount": len(item.recipients), "replyToCurrentUser": False,
        }, classes=["INSendMessageIntentDonationMetadata", "INIntentDonationMetadata", "NSObject"])
        store_class = "_INPBSendMessageIntent"
    else:
        proto = pb.message([(4, 2 if item.video else 1), (5, [(1, _contact(party)) for party in item.recipients])])
        metadata = lib.ArchiveObject("INStartCallIntentDonationMetadata", {
            "callDuration": float(item.duration), "timeToEstablish": round(rng.uniform(0.8, 6.0), 3) if item.duration else 0.0,
            "communicationTrustScore": None, "disconnectedReason": None, "recentCallStatus": None,
        }, classes=["INStartCallIntentDonationMetadata", "INIntentDonationMetadata", "NSObject"])
        store_class = "_INPBStartCallIntent"
    intent = lib.ArchiveObject(item.type, {
        "identifier": item.id, "backingStore": lib.ArchiveObject(store_class, {"bytes": proto}, classes=[store_class, "PBCodable", "NSObject"]),
        "donationMetadata": metadata, "_indexingHash": rng.randrange(1 << 62), "_shouldForwardToAppOnSucccess": False,
        "audioSessionID": 0, "parameterCombinations": None, "recordDeviceIdentifier": None, "recordDeviceUID": None, "recordRoute": None,
    }, classes=[item.type, "INIntent", "NSObject"])
    interval = lib.ArchiveObject("_NSConcreteDateInterval", {
        "NS.startDate": item.start, "NS.endDate": item.start + datetime.timedelta(seconds=item.duration), "NS.duration": float(item.duration),
    }, classes=["_NSConcreteDateInterval", "NSDateInterval", "NSObject"])
    interaction = lib.ArchiveObject("INInteraction", {
        "intent": intent, "dateInterval": interval, "direction": 2 if incoming else 1, "identifier": lib.uuid_string(rng),
        "groupIdentifier": item.conversation, "intentHandlingStatus": 3, "intentResponse": None, "_donatedBySiri": False,
        "_contextExtensionUUID": None, "_snippet": None,
    })
    inner = lib.keyed_archive(interaction)
    return lib.keyed_archive(lib.ArchiveObject("NSMutableData", {"NS.data": inner}, classes=["NSMutableData", "NSData", "NSObject"]))


def _write_knowledge(root: pathlib.Path, world: _World, rng: random.Random, clock: lib.Clock) -> None:
    path = lib.library(root, "Application Support/Knowledge/knowledgeC.db")
    cutoff = clock.ago(days=INTENT_DAYS)
    offset = int(world.persona.tz_offset_hours * 3600)
    with _shared_db(path, _KNOWLEDGE_DDL) as con:
        _ensure_columns(con, "ZOBJECT", _columns(_OBJECT_COLUMNS))
        _ensure_columns(con, "ZSOURCE", _columns(_SOURCE_COLUMNS))
        _ensure_columns(con, "ZSTRUCTUREDMETADATA", {k: v for k, v in _structured_columns().items()
                                                       if k.startswith("Z_DKINTENTMETADATAKEY__") or k == "ZMETADATAHASH"})
        object_pk, source_pk, meta_pk = _next_pk(con, "ZOBJECT"), _next_pk(con, "ZSOURCE"), _next_pk(con, "ZSTRUCTUREDMETADATA")
        verbs = {MESSAGE: "SendMessage", CALL: "StartCall", "INPlayMediaIntent": "PlayMedia", "INRunWorkflowIntent": "RunWorkflow",
                 "INAddTasksIntent": "AddTasks"}
        for item in world.interactions:
            if item.start < cutoff or item.type not in verbs:
                continue
            is_comm = item.type in (MESSAGE, CALL)
            text_kept = item.text if item.bundle in (SMS, WHATSAPP, SLACK) else None
            blob = None
            if is_comm:
                kept = item if text_kept == item.text else dataclasses.replace(item, text=text_kept)
                blob = _serialized_interaction(kept, rng)
            # INInteractionDirection: 1 outgoing, 2 incoming — the reverse of Siri Remembers.
            direction = {IN: 2, OUT: 1}.get(item.direction, 0)
            lib.insert(con, "ZSTRUCTUREDMETADATA", [{
                "Z_PK": meta_pk, "Z_ENT": 15, "Z_OPT": 1,
                "Z_DKINTENTMETADATAKEY__DIRECTION": direction, "Z_DKINTENTMETADATAKEY__DONATEDBYSIRI": 1 if item.siri else 0,
                "Z_DKINTENTMETADATAKEY__INTENTHANDLINGSTATUS": 3 if item.status == 4 else 0, "Z_DKINTENTMETADATAKEY__INTENTTYPE": 1,
                "Z_DKINTENTMETADATAKEY__SHORTCUTAVAILABILITY": 0, "Z_DKINTENTMETADATAKEY__INTENTCLASS": item.type,
                "Z_DKINTENTMETADATAKEY__INTENTVERB": verbs[item.type], "Z_DKINTENTMETADATAKEY__INTERACTIONIDENTIFIER": lib.uuid_string(rng),
                "Z_DKINTENTMETADATAKEY__SERIALIZEDINTERACTION": blob, "ZMETADATAHASH": lib.hex_string(rng, 32),
            }])
            lib.insert(con, "ZSOURCE", [{
                "Z_PK": source_pk, "Z_ENT": 14, "Z_OPT": 1, "ZUSERID": 0, "ZBUNDLEID": item.bundle, "ZDEVICEID": item.device.identifier,
                "ZGROUPID": item.conversation, "ZITEMID": item.id, "ZSOURCEID": "intents",
            }])
            start, end = lib.cocoa(item.start), lib.cocoa(item.start) + item.duration
            local = item.start.astimezone(clock.tz)
            local_end = local + datetime.timedelta(seconds=item.duration)
            created = start + rng.uniform(30, 5400)          # arrives with the next sync
            lib.insert(con, "ZOBJECT", [{
                "Z_PK": object_pk, "Z_ENT": 11, "Z_OPT": 1, "ZUUIDHASH": rng.randrange(-(1 << 62), 1 << 62), "ZSOURCE": source_pk,
                "ZCOMPATIBILITYVERSION": 0, "ZHASCUSTOMMETADATA": 0, "ZHASSTRUCTUREDMETADATA": 1, "ZSECONDSFROMGMT": offset, "ZSHOULDSYNC": 0,
                "ZSTARTDAYOFWEEK": local.isoweekday() % 7 + 1, "ZSTARTSECONDOFDAY": local.hour * 3600 + local.minute * 60 + local.second,
                "ZENDDAYOFWEEK": local_end.isoweekday() % 7 + 1, "ZENDSECONDOFDAY": local_end.hour * 3600 + local_end.minute * 60 + local_end.second,
                "ZVALUECLASS": 1, "ZVALUEINTEGER": rng.randrange(-(1 << 62), 1 << 62), "ZVALUETYPECODE": rng.randrange(1 << 62),
                "ZSTRUCTUREDMETADATA": meta_pk, "ZCREATIONDATE": created, "ZLOCALCREATIONDATE": created, "ZCONFIDENCE": 1.0,
                "ZENDDATE": end, "ZSTARTDATE": start, "ZUUID": lib.uuid_string(rng), "ZSTREAMNAME": "/app/intents", "ZVALUESTRING": item.bundle,
            }])
            object_pk, source_pk, meta_pk = object_pk + 1, source_pk + 1, meta_pk + 1
        _coredata_shared(con, _KNOWLEDGE_ENTITIES, {"Object": "ZOBJECT", "Event": "ZOBJECT", "Source": "ZSOURCE",
                                                    "StructuredMetadata": "ZSTRUCTUREDMETADATA"}, rng)


# ----------------------------------------------------------------------------------------
# interactionC.db — Mail and Calendar correspondents
# ----------------------------------------------------------------------------------------

_INTERACTIONC_DDL = f"""
CREATE TABLE ZATTACHMENT ({_Z}, ZSIZEINBYTES INTEGER, ZCREATIONDATE TIMESTAMP, ZCONTENTTEXT VARCHAR, ZCONTENTTITLE VARCHAR, ZPERSONINPHOTO VARCHAR, ZPHOTOLOCALIDENTIFIER VARCHAR, ZPHOTOSCENEDESCRIPTOR VARCHAR, ZUTI VARCHAR, ZCLOUDIDENTIFIER BLOB, ZCONTENTURL VARCHAR, ZIDENTIFIER BLOB, ZCONTENTKEYWORDS BLOB);
CREATE TABLE Z_1INTERACTIONS (Z_1ATTACHMENTS INTEGER, Z_3INTERACTIONS INTEGER, PRIMARY KEY (Z_1ATTACHMENTS, Z_3INTERACTIONS));
CREATE TABLE ZCONTACTS ({_Z}, ZDISPLAYTYPE INTEGER, ZINCOMINGRECIPIENTCOUNT INTEGER, ZINCOMINGSENDERCOUNT INTEGER, ZOUTGOINGRECIPIENTCOUNT INTEGER, ZPARTICIPANTSTATUS INTEGER, ZPERSONIDTYPE INTEGER, ZTYPE INTEGER, ZCREATIONDATE TIMESTAMP, ZFIRSTINCOMINGRECIPIENTDATE TIMESTAMP, ZFIRSTINCOMINGSENDERDATE TIMESTAMP, ZFIRSTOUTGOINGRECIPIENTDATE TIMESTAMP, ZLASTINCOMINGRECIPIENTDATE TIMESTAMP, ZLASTINCOMINGSENDERDATE TIMESTAMP, ZLASTOUTGOINGRECIPIENTDATE TIMESTAMP, ZCUSTOMIDENTIFIER VARCHAR, ZDISPLAYNAME VARCHAR, ZIDENTIFIER VARCHAR, ZPERSONID VARCHAR, ZDISPLAYIMAGEURL VARCHAR);
CREATE TABLE Z_2INTERACTIONRECIPIENT (Z_2RECIPIENTS INTEGER, Z_3INTERACTIONRECIPIENT INTEGER, PRIMARY KEY (Z_2RECIPIENTS, Z_3INTERACTIONRECIPIENT));
CREATE TABLE ZINTERACTIONS ({_Z}, ZDIRECTION INTEGER, ZISRESPONSE INTEGER, ZMAILSHARESHEETDELETIONCANDIDATE INTEGER, ZMECHANISM INTEGER, ZRECIPIENTCOUNT INTEGER, ZSELFPARTICIPANTSTATUS INTEGER, ZSENDER INTEGER, ZCREATIONDATE TIMESTAMP, ZENDDATE TIMESTAMP, ZSTARTDATE TIMESTAMP, ZUPDATEDATE TIMESTAMP, ZACCOUNT VARCHAR, ZBUNDLEID VARCHAR, ZCONTENTURL VARCHAR, ZDERIVEDINTENTIDENTIFIER VARCHAR, ZDOMAINIDENTIFIER VARCHAR, ZGROUPNAME VARCHAR, ZLOCATIONUUID VARCHAR, ZNSUSERNAME VARCHAR, ZTARGETBUNDLEID VARCHAR, ZUUID VARCHAR);
CREATE TABLE Z_3KEYWORDS (Z_3INTERACTIONS1 INTEGER, Z_4KEYWORDS INTEGER, PRIMARY KEY (Z_3INTERACTIONS1, Z_4KEYWORDS));
CREATE TABLE ZKEYWORDS ({_Z}, ZCREATIONDATE TIMESTAMP, ZKEYWORD VARCHAR);
CREATE TABLE ZMETADATA ({_Z}, ZKEY VARCHAR, ZVALUE BLOB);
CREATE TABLE ZVERSION ({_Z}, ZNUMBER INTEGER, ZCREATIONDATE TIMESTAMP, ZKEY VARCHAR);
CREATE INDEX ZINTERACTIONS_ZSTARTDATE_INDEX ON ZINTERACTIONS (ZSTARTDATE);
CREATE INDEX Z_2INTERACTIONRECIPIENT_REVERSE ON Z_2INTERACTIONRECIPIENT (Z_3INTERACTIONRECIPIENT, Z_2RECIPIENTS);
CREATE INDEX Z_3KEYWORDS_REVERSE ON Z_3KEYWORDS (Z_4KEYWORDS, Z_3INTERACTIONS1);
"""


@dataclass
class _Correspondent:
    pk: int
    name: str
    identifier: str
    person: Optional[Person]
    sent: int = 0
    co: int = 0
    received: int = 0
    dates: dict = field(default_factory=dict)      # column -> (first, last)
    stamps: list = field(default_factory=list)     # every interaction time (for the recents stores)

    def note(self, kind: str, when: float) -> None:
        first, last = self.dates.get(kind, (when, when))
        self.dates[kind] = (min(first, when), max(last, when))
        self.stamps.append(when)


class _MailWorld:
    """This Mac's Mail / Calendar history: who wrote, who was written to, who was invited."""

    def __init__(self, persona: Persona, rng: random.Random, clock: lib.Clock):
        self.persona, self.rng, self.clock = persona, rng, clock
        self.contacts: dict[str, _Correspondent] = {}
        self.rows: list[dict] = []
        self.recipients: list[tuple[int, int]] = []
        self.keywords: dict[str, int] = {}
        self.keyword_links: list[tuple[int, int]] = []
        self.accounts = {"personal": lib.uuid_string(rng), "work": lib.uuid_string(rng)}
        self.sequence = {key: rng.randrange(200, 900) for key in self.accounts}
        self.now = lib.cocoa(clock.now)

    def contact(self, name: str, identifier: str, person: Optional[Person] = None) -> _Correspondent:
        found = self.contacts.get(identifier)
        if found is None:
            found = self.contacts[identifier] = _Correspondent(len(self.contacts) + 1, name, identifier, person)
        return found

    def of(self, key: str) -> _Correspondent:
        if key in _SENDERS:
            return self.contact(*_SENDERS[key])
        person = self.persona.person(key)
        return self.contact(person.full_name, person.email, person)

    def add(self, when: datetime.datetime, bundle: str, mechanism: int, outgoing: bool, sender: Optional[_Correspondent],
            recipients: Sequence[_Correspondent], account: str, *, response: bool = False, title: Optional[str] = None,
            seconds: float = 0.0, group: Optional[str] = None) -> int:
        rng = self.rng
        pk = len(self.rows) + 1
        start = lib.cocoa(when)
        self.sequence[account] += rng.randint(1, 4)
        past = start <= self.now
        created = start + rng.uniform(1, 90) if past else self.now - rng.uniform(86400, 40 * 86400)
        self.rows.append({
            "Z_PK": pk, "Z_ENT": 3, "Z_OPT": 1, "ZDIRECTION": 1 if outgoing else 0, "ZISRESPONSE": 1 if response else 0,
            "ZMAILSHARESHEETDELETIONCANDIDATE": 0, "ZMECHANISM": mechanism, "ZRECIPIENTCOUNT": len(recipients),
            "ZSELFPARTICIPANTSTATUS": 2 if (outgoing and mechanism == 5) else 0, "ZSENDER": sender.pk if sender else None,
            "ZCREATIONDATE": created, "ZENDDATE": int(start + seconds) if mechanism != 16 else start + seconds, "ZSTARTDATE": start,
            "ZUPDATEDATE": created, "ZACCOUNT": self.accounts[account] if mechanism != 16 else None, "ZBUNDLEID": bundle,
            "ZDOMAINIDENTIFIER": f"{self.accounts[account]}.{self.sequence[account]}" if mechanism != 16 else None,
            "ZGROUPNAME": group, "ZNSUSERNAME": self.persona.owner.given.lower(),
            "ZUUID": f"{rng.randrange(10 ** 19, 10 ** 20)}:{rng.randrange(100_000, 1_000_000)}",
        })
        for other in recipients:
            self.recipients.append((other.pk, pk))
        if past:        # scheduled occurrences have not been counted yet
            if outgoing:
                for other in recipients:
                    other.received += 1
                    other.note("OUTGOINGRECIPIENT", start)
            else:
                if sender:
                    sender.sent += 1
                    sender.note("INCOMINGSENDER", start)
                for other in recipients:
                    other.co += 1
                    other.note("INCOMINGRECIPIENT", start)
        if title:
            for word in title.lower().replace("/", " ").replace(":", " ").split():
                word = word.strip(".,()")
                if len(word) < 3 or word in _STOP_WORDS or len(word) > 16:
                    continue
                self.keyword_links.append((pk, self.keywords.setdefault(word, len(self.keywords) + 1)))
        return pk

    def build(self) -> None:
        rng, clock, of = self.rng, self.clock, self.of
        work = ["aroha", "lucas", "nina", "oliver", "hana"]
        work_weights = [5, 6, 4, 2, 2]
        personal = ["alex", "helen", "david", "jamie", "priya", "tom", "mei", "sam", "landlord", "drlee"]
        personal_weights = [3, 3, 1.5, 2, 1.5, 1.5, 1, 0.6, 0.8, 0.4]
        lists = ["staff", "guild", "people", "helpdesk"]
        services = ["air", "gym", "bank", "rides", "market", "type", "tramping"]
        weekday = lambda day: (clock.now.astimezone(clock.tz) - datetime.timedelta(days=day)).weekday()   # noqa: E731
        moment = lambda day, hours: clock.at(day, rng.choices(list(hours), weights=list(hours.values()))[0], rng.randrange(60), rng.randrange(60))  # noqa: E731

        # Mail.
        for day in range(HISTORY_DAYS, -1, -1):
            quiet = 0.45 if 148 <= day <= 161 else 1.0
            if weekday(day) < 5:
                for _ in range(_poisson(rng, 3.1 * quiet)):
                    key = rng.choices(work, weights=work_weights)[0]
                    others = [of(k) for k in rng.sample([k for k in work if k != key], rng.choice([0, 0, 1, 2, 3]))]
                    self.add(moment(day, _WORK_HOURS), "com.apple.mail", 1, False, of(key), others, "work", response=rng.random() < 0.4)
                for _ in range(_poisson(rng, 1.25 * quiet)):
                    keys = rng.sample(work, rng.choice([1, 1, 1, 2, 3]))
                    self.add(moment(day, _WORK_HOURS), "com.apple.mail", 1, True, None, [of(k) for k in keys], "work", response=rng.random() < 0.55)
                for _ in range(_poisson(rng, 0.5)):
                    self.add(moment(day, _WORK_HOURS), "com.apple.mail", 1, False, of(rng.choice(lists)), [], "work")
            for _ in range(_poisson(rng, 0.42)):
                key = rng.choices(personal, weights=personal_weights)[0]
                self.add(moment(day, _PERSONAL_HOURS), "com.apple.mail", 1, False, of(key), [], "personal", response=rng.random() < 0.3)
            for _ in range(_poisson(rng, 0.22)):
                key = rng.choices(personal, weights=personal_weights)[0]
                self.add(moment(day, _PERSONAL_HOURS), "com.apple.mail", 1, True, None, [of(key)], "personal", response=rng.random() < 0.6)
            for _ in range(_poisson(rng, 0.38)):
                self.add(moment(day, _PERSONAL_HOURS), "com.apple.mail", 1, False, of(rng.choice(services)), [], "personal")

        # Calendar: every occurrence of a recurring event is one interaction, also the
        # ones that have not happened yet.
        today = clock.now.astimezone(clock.tz).replace(hour=0, minute=0, second=0, microsecond=0)
        for title, organiser, attendees, weekdays, hour, minute, every, is_personal in _MEETINGS:
            horizon = 250 if not is_personal else 120
            for day in range(HISTORY_DAYS, -horizon - 1, -1):
                date = today - datetime.timedelta(days=day)
                if date.weekday() not in weekdays or (date.toordinal() // 7) % every:
                    continue
                if 148 <= day <= 161 and not is_personal:
                    continue
                when = date.replace(hour=hour, minute=minute).astimezone(lib.UTC)
                invited = [of(k) for k in attendees]
                account = "personal" if is_personal else "work"
                bundle = "com.apple.iCal" if is_personal else "com.apple.CalendarUI"
                group = title if is_personal else None
                if organiser == "robin":
                    self.add(when, bundle, 5, True, None, invited, account, title=title, seconds=1800, group=group)
                else:
                    self.add(when, bundle, 5, False, of(organiser), invited, account, title=title, seconds=1800, group=group)
        for title, organiser, attendees, day, hour in _ONE_OFFS:
            when = (today - datetime.timedelta(days=day)).replace(hour=hour).astimezone(lib.UTC)
            invited = [of(k) for k in attendees]
            if organiser == "robin":
                self.add(when, "com.apple.CalendarUI", 5, True, None, invited, "work", title=title, seconds=3600)
            else:
                self.add(when, "com.apple.CalendarUI", 5, False, of(organiser), invited, "work", title=title, seconds=3600)
        for day, title, key in ((DENTIST_DAY, "Dentist check-up", "drlee"), (TRIP_DAY, "Flight to Queenstown", "air"),
                                (-24, "Flight to Auckland", "air")):
            when = (today - datetime.timedelta(days=day)).replace(hour=9, minute=40).astimezone(lib.UTC)
            self.add(when, "com.apple.mail", 5, False, of(key), [], "personal", title=title, seconds=2400)


def _write_interactionc(root: pathlib.Path, mail: _MailWorld, calls: list[Interaction], rng: random.Random, clock: lib.Clock) -> None:
    # Calls relayed to this Mac count as interactions with the caller too.
    phone_contacts: dict[str, _Correspondent] = {}
    for item in calls:
        party = item.recipients[0]
        if party.person is None or item.duration <= 0:
            continue
        contact = phone_contacts.get(party.handle)
        if contact is None:
            contact = phone_contacts[party.handle] = mail.contact(party.name, party.handle, party.person)
        mail.add(item.start, "com.apple.InCallService", 16, item.direction == OUT, None if item.direction == OUT else contact,
                 [contact] if item.direction == OUT else [], "personal", seconds=item.duration)
    path = lib.system(root, "/private/var/db/CoreDuet/People/interactionC.db")
    with lib.sqlite_db(path, _INTERACTIONC_DDL) as con:
        lib.insert(con, "ZINTERACTIONS", mail.rows)
        lib.insert(con, "Z_2INTERACTIONRECIPIENT", sorted(set(mail.recipients)))
        created = lib.cocoa(clock.ago(days=HISTORY_DAYS + 20))
        lib.insert(con, "ZKEYWORDS", [{"Z_PK": pk, "Z_ENT": 4, "Z_OPT": 1, "ZCREATIONDATE": created, "ZKEYWORD": word}
                                      for word, pk in mail.keywords.items()])
        lib.insert(con, "Z_3KEYWORDS", sorted(set(mail.keyword_links)))
        for contact in mail.contacts.values():
            person = contact.person
            row = {
                "Z_PK": contact.pk, "Z_ENT": 2, "Z_OPT": 1, "ZDISPLAYTYPE": 0, "ZINCOMINGRECIPIENTCOUNT": contact.co,
                "ZINCOMINGSENDERCOUNT": contact.sent, "ZOUTGOINGRECIPIENTCOUNT": contact.received, "ZPARTICIPANTSTATUS": 0,
                "ZPERSONIDTYPE": 3 if person else 0, "ZTYPE": 1 if person else 2,
                "ZCREATIONDATE": min((first for first, _ in contact.dates.values()), default=created),
                "ZDISPLAYNAME": contact.name, "ZIDENTIFIER": contact.identifier, "ZPERSONID": person.contact_id if person else None,
            }
            for kind, (first, last) in contact.dates.items():
                row[f"ZFIRST{kind}DATE"], row[f"ZLAST{kind}DATE"] = first, last
            lib.insert(con, "ZCONTACTS", [row])
        lib.insert(con, "ZVERSION", [{"Z_PK": 1, "Z_ENT": 6, "Z_OPT": 1, "ZNUMBER": 1, "ZCREATIONDATE": created, "ZKEY": "store_version"}])
        lib.coredata_tables(con, {"Attachment": 1, "Contacts": 2, "Interactions": 3, "Keywords": 4, "Metadata": 5, "Version": 6}, rng,
                            max_pk={"Contacts": len(mail.contacts), "Interactions": len(mail.rows), "Keywords": len(mail.keywords), "Version": 1})


# ----------------------------------------------------------------------------------------
# CallHistory.storedata — this Mac's own call log
# ----------------------------------------------------------------------------------------

_CALL_HISTORY_DDL = f"""
CREATE TABLE ZCALLDBPROPERTIES ({_Z}, ZTIMER_ALL FLOAT, ZTIMER_INCOMING FLOAT, ZTIMER_LAST FLOAT, ZTIMER_LIFETIME FLOAT, ZTIMER_OUTGOING FLOAT);
CREATE TABLE ZCALLRECORD ({_Z}, ZANSWERED INTEGER, ZAUTOANSWEREDREASON INTEGER, ZCALLDIRECTORYIDENTITYTYPE INTEGER, ZCALL_CATEGORY INTEGER, ZCALLTYPE INTEGER, ZCOMMUNICATIONTRUSTSCORE INTEGER, ZDIDENABLETRANSLATION INTEGER, ZDISCONNECTED_CAUSE INTEGER, ZFACE_TIME_DATA INTEGER, ZFILTERED_OUT_REASON INTEGER, ZHANDLE_TYPE INTEGER, ZHASMESSAGE INTEGER, ZJUNKCONFIDENCE INTEGER, ZNEEDEDSCANNOUNCEMENT INTEGER, ZNUMBER_AVAILABILITY INTEGER, ZORIGINATED INTEGER, ZORIGINATINGUITYPE INTEGER, ZREAD INTEGER, ZSAINT_DAVIDS_1 INTEGER, ZSCREENSHARINGTYPE INTEGER, ZUSEDEMERGENCYVIDEOSTREAMING INTEGER, ZVERIFICATIONSTATUS INTEGER, ZWASEMERGENCYCALL INTEGER, ZINITIATOR INTEGER, ZDATE TIMESTAMP, ZDURATION FLOAT, ZADDRESS VARCHAR, ZBLOCKEDBYEXTENSION VARCHAR, ZBLOCKEDBYEXTENSIONNAME VARCHAR, ZIDENTITYEXTENSION VARCHAR, ZISO_COUNTRY_CODE VARCHAR, ZJUNKIDENTIFICATIONCATEGORY VARCHAR, ZLOCATION VARCHAR, ZNAME VARCHAR, ZORIGINATINGDEVICENAME VARCHAR, ZSAINT_DAVIDS_2 VARCHAR, ZSERVICE_PROVIDER VARCHAR, ZUNIQUE_ID VARCHAR, ZCONVERSATIONID BLOB, ZIMAGEURL VARCHAR, ZLOCALPARTICIPANTUUID BLOB, ZOUTGOINGLOCALPARTICIPANTUUID BLOB, ZPARTICIPANTGROUPUUID BLOB, ZREMINDERUUID BLOB);
CREATE TABLE Z_2REMOTEPARTICIPANTHANDLES (Z_2REMOTEPARTICIPANTCALLS INTEGER, Z_4REMOTEPARTICIPANTHANDLES INTEGER, PRIMARY KEY (Z_2REMOTEPARTICIPANTCALLS, Z_4REMOTEPARTICIPANTHANDLES));
CREATE TABLE ZEMERGENCYMEDIAITEM ({_Z}, ZEMERGENCYMEDIATYPE INTEGER, ZUPLOADEDFORCALL INTEGER, ZASSETID VARCHAR);
CREATE TABLE ZHANDLE ({_Z}, ZTYPE INTEGER, ZNORMALIZEDVALUE VARCHAR, ZVALUE VARCHAR);
CREATE TABLE ZSAINTDAVIDSCOUNTS ({_Z}, ZCOUNT INTEGER, ZTYPE INTEGER, ZCALL INTEGER);
"""


def _write_call_history(root: pathlib.Path, calls: list[Interaction], persona: Persona, rng: random.Random) -> list[Interaction]:
    """Phone calls relayed through the iPhone and FaceTime calls, the last five months."""
    path = lib.library(root, "Application Support/CallHistoryDB/CallHistory.storedata")
    kept = calls
    handles: dict[str, int] = {}
    with lib.sqlite_db(path, _CALL_HISTORY_DDL) as con:
        for pk, item in enumerate(kept, start=1):
            party = item.recipients[0]
            facetime = item.bundle == FACETIME_IOS
            outgoing = item.direction == OUT
            handle_pk = handles.setdefault(party.handle, len(handles) + 1)
            lib.insert(con, "ZCALLRECORD", [{
                "Z_PK": pk, "Z_ENT": 2, "Z_OPT": 2, "ZANSWERED": 1 if (not outgoing and item.duration > 0) else 0,
                "ZCALL_CATEGORY": 2 if facetime else 1, "ZCALLTYPE": 8 if facetime else 1, "ZFACE_TIME_DATA": 0 if not facetime else int(item.duration * 9000),
                "ZHANDLE_TYPE": 2, "ZJUNKCONFIDENCE": 0, "ZNUMBER_AVAILABILITY": 0, "ZORIGINATED": 1 if outgoing else 0, "ZREAD": 1,
                "ZVERIFICATIONSTATUS": 0 if facetime else 4, "ZDATE": lib.cocoa(item.start), "ZDURATION": item.duration, "ZADDRESS": party.handle,
                "ZISO_COUNTRY_CODE": persona.region.lower(), "ZNAME": party.name or None,
                "ZLOCATION": None if facetime else persona.place("home").country,
                "ZSERVICE_PROVIDER": "com.apple.FaceTime" if facetime else "com.apple.Telephony", "ZUNIQUE_ID": lib.uuid_string(rng),
                "ZORIGINATINGDEVICENAME": persona.device("iphone").name if (not facetime and rng.random() < 0.3) else None,
            }])
            con.execute("INSERT OR IGNORE INTO Z_2REMOTEPARTICIPANTHANDLES VALUES (?, ?)", (pk, handle_pk))
        lib.insert(con, "ZHANDLE", [{"Z_PK": pk, "Z_ENT": 4, "Z_OPT": 1, "ZTYPE": 2, "ZNORMALIZEDVALUE": value, "ZVALUE": value}
                                    for value, pk in handles.items()])
        incoming = sum(i.duration for i in kept if i.direction == IN)
        outgoing_total = sum(i.duration for i in kept if i.direction == OUT)
        lib.insert(con, "ZCALLDBPROPERTIES", [{"Z_PK": 1, "Z_ENT": 1, "Z_OPT": len(kept), "ZTIMER_ALL": incoming + outgoing_total,
                                               "ZTIMER_INCOMING": incoming, "ZTIMER_LAST": kept[-1].duration if kept else 0.0,
                                               "ZTIMER_LIFETIME": incoming + outgoing_total, "ZTIMER_OUTGOING": outgoing_total}])
        lib.coredata_tables(con, {"CallDBProperties": 1, "CallRecord": 2, "EmergencyMediaItem": 3, "Handle": 4, "SaintDavidsCounts": 5}, rng,
                            max_pk={"CallDBProperties": 1, "CallRecord": len(kept), "Handle": len(handles)})
    return kept


# ----------------------------------------------------------------------------------------
# CoreRecents and the iCloud key-value cache
# ----------------------------------------------------------------------------------------

_RECENTS_DDL = """
CREATE TABLE recents (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, display_name TEXT, bundle_identifier TEXT, sending_address TEXT,
 original_source TEXT, dates TEXT NOT NULL, last_date INTEGER, weight FLOAT, record_hash TEXT NOT NULL, count INTEGER, group_kind INTEGER);
CREATE TABLE contacts (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, recent_id INTEGER, display_name TEXT, kind TEXT, address TEXT,
 FOREIGN KEY (recent_id) REFERENCES recents (ROWID) ON DELETE CASCADE);
CREATE TABLE metadata (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, recent_id INTEGER, key TEXT, value,
 FOREIGN KEY (recent_id) REFERENCES recents (ROWID) ON DELETE CASCADE, UNIQUE (recent_id, key));
CREATE TABLE properties (ROWID INTEGER PRIMARY KEY, key, value, UNIQUE (key));
"""


def _recent_stamps(contact: _Correspondent, now: float, limit: int = 5) -> list[float]:
    return sorted(s for s in contact.stamps if s <= now)[-limit:]


def _write_recents(root: pathlib.Path, mail: _MailWorld, persona: Persona, rng: random.Random, clock: lib.Clock) -> None:
    path = lib.library(root, "Containers/com.apple.corerecents.recentsd/Data/Library/Recents/Recents")
    owner = persona.owner
    recents: list[dict] = []
    contacts: list[dict] = []

    def add(bundle: str, members: list[tuple[str, str, str]], stamps: list[float], *, sending: Optional[str] = None,
            source: Optional[str] = None, weight: Optional[float] = None, name: Optional[str] = None) -> None:
        if not stamps:
            return
        millis = [int((s + lib.COCOA_EPOCH) * 1000) for s in stamps]
        recents.append({"ROWID": len(recents) + 1, "display_name": name, "bundle_identifier": bundle, "sending_address": sending,
                        "original_source": source, "dates": ":".join(str(m) for m in millis), "last_date": millis[-1], "weight": weight,
                        "record_hash": lib.hex_string(rng, 32), "count": len(stamps), "group_kind": 0})
        for display, kind, address in members:
            contacts.append({"ROWID": len(contacts) + 1, "recent_id": len(recents), "display_name": display, "kind": kind, "address": address})

    people = [c for c in mail.contacts.values() if "@" in c.identifier]
    for contact in people:
        stamps = _recent_stamps(contact, mail.now)
        work = contact.identifier.endswith(persona.company_domain)
        add("com.apple.mail", [(contact.name, "email", contact.identifier)], stamps,
            sending=owner.emails[-1] if work else owner.email, source="com.apple.mail", name=contact.name)
    # Group mails: the same addressees together.
    by_key = {c.person.key: c for c in people if c.person}
    for keys in (("aroha", "lucas", "nina"), ("lucas", "oliver"), ("helen", "david", "jamie"), ("priya", "tom")):
        members = [(by_key[k].name, "email", by_key[k].identifier) for k in keys if k in by_key]
        stamps = sorted(lib.cocoa(t) for t in clock.spread(rng, rng.randint(2, 5), 120))
        add("com.apple.mail", members, stamps, sending=owner.email, source="com.apple.mail")
    for key in ("aroha", "lucas", "nina", "oliver", "hana", "priya", "helen"):
        contact = by_key[key]
        add("com.apple.calendar", [(contact.name, "email", contact.identifier)], _recent_stamps(contact, mail.now, 3),
            source="com.apple.calendar", name=contact.name)
    def near(days: float) -> list[float]:
        return [lib.cocoa(clock.ago(days=days, hours=rng.uniform(0, 9)))]

    for key, bundle, days in (("work", "com.apple.calendar", 3), ("cafe", "com.apple.calendar", 11), ("gym", "com.apple.eventkit.osx", 6),
                              ("te_papa", "com.apple.eventkit.osx", 38), ("airport", "com.apple.passbook", TRIP_DAY), ("station", "com.apple.passbook", 47)):
        place = persona.place(key)
        add(bundle, [(place.name, "map-location", place.address)], near(days), source=bundle,
            weight=round(rng.uniform(0.2, 1.0), 3) if bundle == "com.apple.passbook" else None, name=place.name)
    for key, days in (("priya", 64), ("sam", 141)):
        person = persona.person(key)
        add("com.apple.introductions.accepted", [(person.full_name, "phone", person.phone)], near(days),
            source="com.apple.introductions.accepted", name=person.full_name)
    with lib.sqlite_db(path, _RECENTS_DDL) as con:
        lib.insert(con, "recents", recents)
        lib.insert(con, "contacts", contacts)
        lib.insert(con, "properties", [(1, "version", 3)])


_KVS_DDL = f"""
CREATE TABLE IF NOT EXISTS ZSYDMANAGEDDATABASE ({_Z}, ZDIDMIGRATEFROMPLISTS INTEGER, ZFAILEDMIGRATIONCOUNT INTEGER, ZHASPERFORMEDONETIMEDATASEPARATEDLOCALDATARESET INTEGER, ZACACCOUNTIDENTIFIER VARCHAR, ZSYNCENGINEMETADATA BLOB, ZSYNCENGINESTATESERIALIZATION BLOB);
CREATE TABLE IF NOT EXISTS ZSYDMANAGEDKEYVALUE ({_Z}, ZPLISTDATALENGTH INTEGER, ZSTORE INTEGER, ZVALUEMODIFICATIONDATE TIMESTAMP, ZKEY VARCHAR, ZRECORDNAME VARCHAR, ZPLISTDATAVALUE BLOB, ZSERVERSYSTEMFIELDSRECORDDATA BLOB);
CREATE TABLE IF NOT EXISTS ZSYDMANAGEDSTORE ({_Z}, ZTOTALDATALENGTH INTEGER, ZDATABASE INTEGER, ZIDENTIFIER VARCHAR, ZSYNCANCHORSERVERSYSTEMFIELDSRECORDDATA BLOB);
"""
_KVS_ENTITIES = {"SYDManagedDatabase": (1, 0), "SYDManagedKeyValue": (2, 0), "SYDManagedStore": (3, 0)}
_KVS_TABLES = {"SYDManagedDatabase": "ZSYDMANAGEDDATABASE", "SYDManagedKeyValue": "ZSYDMANAGEDKEYVALUE", "SYDManagedStore": "ZSYDMANAGEDSTORE"}


def _kvs_put(path: pathlib.Path, stores: dict[str, list[tuple[str, Any, float]]], rng: random.Random) -> None:
    """Adds key-value stores (identifier -> [(key, plist value, modification date)]) to one
    of the kvs databases, keeping whatever other generators stored there."""
    with _shared_db(path, _KVS_DDL) as con:
        _ensure_columns(con, "ZSYDMANAGEDKEYVALUE", {"ZPLISTDATALENGTH": "INTEGER", "ZSTORE": "INTEGER", "ZVALUEMODIFICATIONDATE": "TIMESTAMP",
                                                     "ZKEY": "VARCHAR", "ZRECORDNAME": "VARCHAR", "ZPLISTDATAVALUE": "BLOB"})
        _ensure_columns(con, "ZSYDMANAGEDSTORE", {"ZTOTALDATALENGTH": "INTEGER", "ZDATABASE": "INTEGER", "ZIDENTIFIER": "VARCHAR"})
        database = con.execute("SELECT min(Z_PK) FROM ZSYDMANAGEDDATABASE").fetchone()[0]
        if database is None:
            database = 1
            lib.insert(con, "ZSYDMANAGEDDATABASE", [{"Z_PK": 1, "Z_ENT": 1, "Z_OPT": 1, "ZDIDMIGRATEFROMPLISTS": 1, "ZFAILEDMIGRATIONCOUNT": 0,
                                                     "ZACACCOUNTIDENTIFIER": lib.uuid_string(rng)}])
        for identifier, entries in stores.items():
            row = con.execute("SELECT Z_PK FROM ZSYDMANAGEDSTORE WHERE ZIDENTIFIER = ?", (identifier,)).fetchone()
            store = row[0] if row else _next_pk(con, "ZSYDMANAGEDSTORE")
            if not row:
                lib.insert(con, "ZSYDMANAGEDSTORE", [{"Z_PK": store, "Z_ENT": 3, "Z_OPT": 1, "ZTOTALDATALENGTH": 0, "ZDATABASE": database,
                                                      "ZIDENTIFIER": identifier}])
            total = 0
            for key, value, modified in entries:
                data = lib.plist_bytes(value)
                total += len(data)
                lib.insert(con, "ZSYDMANAGEDKEYVALUE", [{
                    "Z_PK": _next_pk(con, "ZSYDMANAGEDKEYVALUE"), "Z_ENT": 2, "Z_OPT": 1, "ZPLISTDATALENGTH": len(data), "ZSTORE": store,
                    "ZVALUEMODIFICATIONDATE": modified, "ZKEY": key, "ZRECORDNAME": lib.hex_string(rng, 40), "ZPLISTDATAVALUE": data}])
            con.execute("UPDATE ZSYDMANAGEDSTORE SET ZTOTALDATALENGTH = coalesce(ZTOTALDATALENGTH, 0) + ? WHERE Z_PK = ?", (total, store))
        _coredata_shared(con, _KVS_ENTITIES, _KVS_TABLES, rng)


def _write_kvs(root: pathlib.Path, mail: _MailWorld, calls: list[Interaction], persona: Persona, rng: random.Random, clock: lib.Clock) -> None:
    directory = lib.ensure_dir(lib.daemon_container(root, "com.apple.kvs", rng) / "com.apple.kvs")
    owner = persona.owner
    now = mail.now

    def recent(contact: _Correspondent, limit: int) -> Optional[tuple[str, Any, float]]:
        stamps = _recent_stamps(contact, now, limit)
        if not stamps:
            return None
        value = {"v": 1, "t": [lib.from_cocoa(s) for s in stamps], "n": contact.name, "a": contact.identifier,
                 "S": owner.emails[-1] if contact.identifier.endswith(persona.company_domain) else owner.email}
        return ("MR_" + lib.hex_string(rng, 32), value, stamps[-1])

    emails = sorted((c for c in mail.contacts.values() if "@" in c.identifier), key=lambda c: -len(c.stamps))
    by_key = {c.person.key: c for c in emails if c.person}
    mail_recents = [entry for entry in (recent(c, 5) for c in emails) if entry]
    vips = [("VIP_" + lib.uuid_string(rng), {"n": persona.person(k).full_name, "a": list(persona.person(k).emails), "v": 1},
             lib.cocoa(clock.ago(days=days))) for k, days in (("alex", 310), ("aroha", 255), ("helen", 240), ("landlord", 96))]
    _kvs_put(directory / "com.apple.KeyValueService-Production.sqlite",
             {"com.apple.mail.recents": mail_recents, "com.apple.mail.vipsenders": vips}, rng)

    calendar = [entry for entry in (recent(by_key[k], 3) for k in ("aroha", "lucas", "nina", "oliver", "hana", "priya", "helen", "jamie")) if entry]
    facetime = []
    for key in ("helen", "jamie", "alex"):
        person = persona.person(key)
        stamps = sorted(lib.cocoa(i.start) for i in calls if i.bundle == FACETIME_IOS and i.recipients[0].person is person)[-4:]
        if not stamps and key == "alex":
            stamps = [lib.cocoa(clock.ago(days=33, hours=4))]
        if stamps:
            facetime.append(("MR_" + lib.hex_string(rng, 32), {"v": 1, "t": [lib.from_cocoa(s) for s in stamps], "n": person.full_name,
                                                              "a": person.phone}, stamps[-1]))
    blocked = {
        "__kCMFBlockListStoreVersionKey": 1, "__kCMFBlockListStoreRevisionKey": 7,
        "__kCMFBlockListStoreRevisionTimestampKey": clock.ago(days=41), "__kCMFBlockListStoreTypeKey": "_CMFBlockListStoreTypeiCloud",
        "__kCMFBlockListStoreArrayKey": [
            {"__kCMFItemPhoneNumberCountryCodeKey": "us", "__kCMFItemPhoneNumberUnformattedKey": f"+1202555{number:04d}",
             "__kCMFItemTypeKey": 0, "__kCMFItemVersionKey": 1} for number in (163, 177, 191, 196)
        ] + [{"__kCMFItemEmailUnformattedKey": address, "__kCMFItemTypeKey": 1, "__kCMFItemVersionKey": 1}
             for address in ("prizes@example.net", "winner-notice@example.com")],
    }
    _kvs_put(directory / "com.apple.KeyValueService.EndToEndEncrypted-Production.sqlite", {
        "com.apple.calendar.recents": calendar, "com.apple.facetime.recents": facetime,
        "com.apple.cmfsyncagent": [("__kCMFBlockListStoreTopLevelKey", blocked, lib.cocoa(clock.ago(days=41)))],
    }, rng)

    favourites = []
    for person in [p for p in persona.others if p.favourite]:
        actions = [("AudioCallActionType", "com.apple.mobilephone", person.phone, "phoneNumbers"),
                   ("MessageActionType", "com.apple.MobileSMS", person.phone, "phoneNumbers")]
        if person.relationship in ("mother", "sister"):
            actions.append(("VideoCallActionType", "com.apple.facetime", person.phone, "phoneNumbers"))
        if person.relationship == "partner":
            actions.append(("MailActionType", "com.apple.mobilemail", person.email, "emailAddresses"))
        for action, bundle, value, prop in actions[: 3 if person.relationship != "sister" else 2]:
            favourites.append({"ActionType": action, "Label": "iPhone" if prop == "phoneNumbers" else "home", "ContactProperty": prop,
                               "EntryIdentifier": lib.uuid_string(rng), "BundleIdentifier": bundle, "Name": person.full_name, "Value": value})
    _kvs_put(directory / "com.apple.KeyValueService.EndToEndEncrypted.AllPlatforms-Production.sqlite",
             {"com.apple.contacts.favorites": [("entries", favourites, lib.cocoa(clock.ago(days=77)))]}, rng)


# ----------------------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------------------

def generate(root: pathlib.Path, persona: Persona, rng: random.Random, now: datetime.datetime) -> None:
    """Create this module's stores below `root`."""
    clock = lib.Clock(now, persona.tz_offset_hours)

    world = _World(persona, rng, clock)
    world.build()
    _write_view(root, world, rng)
    _write_streams(root, world, rng)
    _write_knowledge(root, world, rng, clock)

    # Device names for "donated on": sync.db belongs to whoever writes it first.
    if not lib.library(root, "Biome/sync/sync.db").exists():
        lib.write_biome_sync_db(root, persona.devices, now, rng)

    # This Mac's own log: phone calls relayed through the iPhone and FaceTime, five months.
    cutoff = clock.ago(days=150)
    relayed = [i for i in world.interactions if i.type == CALL and i.bundle in (PHONE, FACETIME_IOS) and i.start >= cutoff
               and i.device is world.iphone and rng.random() < 0.45]
    _write_call_history(root, relayed, persona, rng)

    mail = _MailWorld(persona, rng, clock)
    mail.build()
    _write_interactionc(root, mail, relayed, rng, clock)
    _write_recents(root, mail, persona, rng, clock)
    _write_kvs(root, mail, relayed, persona, rng, clock)
