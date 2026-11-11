"""Demo data for the Streams & System Log module (`biome`).

Writes, below the demo root:

* `~/Library/Biome/streams/restricted/<Stream>/{local,remote/<device>}` — SEGB streams of
  every family the catalogue documents (app focus, media, notifications, Siri Remembers,
  harvesting, Apple Intelligence telemetry, Lighthouse ledger, …) plus a number of
  deliberately empty streams,
* `~/Library/DuetExpertCenter/streams/<name>/local` — the proactive-suggestion streams,
* the linkd daemon container `Data/ActionTranscript/<bundle id | System>/local`,
* `~/Library/Application Support/Knowledge/knowledgeC.db`,
* `~/Library/Biome/sync/sync.db` (CRDT locations, atoms, merge log, sessions).

Shared stores are filled idempotently and never clobbered: a stream directory, an
ActionTranscript folder, a knowledgeC stream name or a non-empty sync.db table that an
earlier module already wrote keeps its rows; only what is missing is added, and it agrees
with what is there (atoms and day markers are derived from the segments on disk, merged
events hang on the existing sessions). One repair is made to foreign rows: `CRDTLocation.day`
values that are plain day numbers are converted to the store's unit (Cocoa seconds at
midnight UTC), because the Device Sync section would otherwise date them to 2001.
`knowledgeC.db` and `sync.db` are appended to with `sqlite3` directly, since
`lib.sqlite_db` always starts a new file.

Everything here is invented: the people, places, devices and apps come from `persona.py`,
all other text (mail subjects, codes, booking references, merchants, model and task names)
is made up for the demo. Field numbers and table layouts follow the readers in
`Sources/BiomeModule` and the schema (DDL only) of the real stores.
"""

from __future__ import annotations

import bisect
import datetime
import json
import pathlib
import random
import sqlite3
import struct
from typing import Any, Iterable, Optional

from . import lib
from .lib import pb
from .persona import Persona, Person

HISTORY = 120          # days of history in the long-lived streams
DAY = 86_400


def generate(root: pathlib.Path, persona: Persona, rng: random.Random, now: datetime.datetime) -> None:
    """Create this module's stores below `root`."""
    g = _Generator(root, persona, rng, now)
    g.build_world()
    g.app_streams()
    g.media_streams()
    g.web_streams()
    g.notification_streams()
    g.device_streams()
    g.siri_streams()
    g.harvesting_streams()
    g.misc_streams()
    g.intelligence_streams()
    g.ledger_streams()
    g.empty_streams()
    g.duet_expert_streams()
    g.linkd_transcripts()
    g.knowledge_db()
    g.sync_db()


# ----------------------------------------------------------------------------------------
# Invented content
# ----------------------------------------------------------------------------------------

_IOS_LAUNCH_REASONS = [
    ("com.apple.SpringBoard.transitionReason.homescreen", 10),
    ("com.apple.SpringBoard.transitionReason.appSwitcher", 4),
    ("com.apple.SpringBoard.transitionReason.notification", 3),
    ("com.apple.SpringBoard.transitionReason.spotlight", 1),
    ("com.apple.SpringBoard.transitionReason.siri", 0.5),
    ("com.apple.SpringBoard.transitionReason.widget", 1),
]

_WEB_PATHS = {
    "wikipedia.org": ("en.wikipedia.org", ["/wiki/Kākā", "/wiki/Wellington_Cable_Car", "/wiki/Typography", "/wiki/Tararua_Range",
                                             "/wiki/Sourdough", "/wiki/Tide"]),
    "github.com": ("github.com", ["/notifications", "/pulls", "/explore", "/issues"]),
    "youtube.com": ("www.youtube.com", ["/results?search_query=sourdough+starter", "/results?search_query=figma+auto+layout",
                                        "/feed/subscriptions"]),
    "metservice.com": ("www.metservice.com", ["/towns-cities/locations/wellington", "/marine/regions/wellington"]),
    "doc.govt.nz": ("www.doc.govt.nz", ["/parks-and-recreation/places-to-go/wellington-kapiti/", "/parks-and-recreation/things-to-do/walking-and-tramping/"]),
    "bbc.com": ("www.bbc.com", ["/news", "/news/science_and_environment", "/sport"]),
    "stackoverflow.com": ("stackoverflow.com", ["/questions/tagged/swiftui", "/questions/tagged/css-grid"]),
    "developer.apple.com": ("developer.apple.com", ["/documentation/swiftui", "/design/human-interface-guidelines/typography"]),
    "openstreetmap.org": ("www.openstreetmap.org", ["/#map=14/-41.2900/174.7800", "/directions"]),
    "example.com": ("www.example.com", ["/", "/pricing"]),
    "example.org": ("intranet.example.org", ["/handbook", "/design-system/components", "/people/leave", "/roadmap/q1"]),
    "archive.org": ("archive.org", ["/details/texts", "/details/audio"]),
}

_MENU_ITEMS = {
    "com.figma.Desktop": ["Export Frames to PDF…", "Paste Over Selection", "Zoom to Fit", "Show Layout Grids", "Create Component"],
    "com.apple.Safari": ["New Private Window", "Add Bookmark…", "Show Reader", "Reopen Last Closed Tab", "Find…"],
    "com.apple.mail": ["Archive", "Move to Junk", "Flag", "New Message", "Get All New Mail"],
    "com.apple.finder": ["New Folder", "Get Info", "Compress", "Show Path Bar", "Move to Bin"],
    "com.apple.Notes": ["New Note", "Add Checklist", "Pin Note", "Lock Note"],
    "com.apple.Preview": ["Export as PDF…", "Rotate Left", "Adjust Size…", "Show Markup Toolbar"],
    "com.tinyspeck.slackmacgap": ["Mark All as Read", "Pause Notifications", "Jump to…"],
    "com.microsoft.VSCode": ["Format Document", "Toggle Terminal", "Go to File…"],
    "com.apple.Terminal": ["New Tab", "Clear to Start", "Export Text As…"],
    "com.apple.iCal": ["New Event", "Go to Today", "Find Events"],
    "com.apple.Photos": ["Export Unmodified Original…", "Add to Album", "Hide Photo"],
}

_DOCUMENTS = [
    ("Documents/Kōwhai Labs/Design review notes.pdf", "com.adobe.pdf", "com.apple.Preview"),
    ("Documents/Kōwhai Labs/Onboarding flow — research synthesis.pdf", "com.adobe.pdf", "com.apple.Preview"),
    ("Documents/Kōwhai Labs/user-interviews-round-2.csv", "public.comma-separated-values-text", "com.microsoft.VSCode"),
    ("Documents/Home/Lease renewal — Aro Street.pdf", "com.adobe.pdf", "com.apple.Preview"),
    ("Documents/Home/Payslip October.pdf", "com.adobe.pdf", "com.apple.Preview"),
    ("Documents/Travel/Boarding pass WLG-ZQN.pdf", "com.adobe.pdf", "com.apple.Preview"),
    ("Documents/Travel/Queenstown itinerary.pdf", "com.adobe.pdf", "com.apple.Preview"),
    ("Documents/Home/Dental estimate.pdf", "com.adobe.pdf", "com.apple.Preview"),
    ("Desktop/portfolio-2026/case-study-ferry-app.md", "net.daringfireball.markdown", "com.microsoft.VSCode"),
    ("Desktop/portfolio-2026/hero.png", "public.png", "com.apple.Preview"),
    ("Pictures/Exports/Mount Victoria sunrise.jpg", "public.jpeg", "com.apple.Preview"),
    ("Downloads/Te Aro Climbing Gym — membership.pdf", "com.adobe.pdf", "com.apple.Preview"),
    ("Downloads/typeface-specimen.pdf", "com.adobe.pdf", "com.apple.Preview"),
    ("Documents/Home/Tararua trip budget.csv", "public.comma-separated-values-text", "com.apple.Preview"),
]

# (bundle, action identifier, parameter names, client label)
_APP_INTENTS = [
    ("com.apple.Notes", "CreateNoteIntent", ["name", "folder", "body"], "Shortcuts"),
    ("com.apple.Notes", "OpenNoteIntent", ["target"], "Spotlight"),
    ("com.apple.reminders", "AddReminderIntent", ["title", "list", "dueDate"], "Siri"),
    ("com.apple.reminders", "CompleteReminderIntent", ["target"], "Reminders"),
    ("com.apple.shortcuts", "RunShortcutIntent", ["shortcut"], "Shortcuts"),
    ("com.apple.Music", "PlayMusicIntent", ["item", "shuffle"], "Siri"),
    ("com.apple.mail", "ComposeMailIntent", ["to", "subject"], "Shortcuts"),
    ("com.apple.finder", "OpenFolderIntent", ["folder"], "Spotlight"),
    ("com.apple.systempreferences", "SetFocusIntent", ["focus", "state"], "Control Center"),
    ("com.apple.Safari", "OpenURLIntent", ["url"], "Shortcuts"),
    ("com.apple.iCal", "CreateEventIntent", ["title", "startDate", "calendar"], "Siri"),
    ("com.apple.Photos", "SearchPhotosIntent", ["query"], "Spotlight"),
    ("com.apple.freeform", "OpenBoardIntent", ["board"], "Spotlight"),
    ("com.apple.weather", "GetForecastIntent", ["location"], "Siri"),
]

_CHAT_LINES = {
    "partner": ["Can you pick up oat milk on the way home?", "Running ten minutes late, save me a seat?", "Flight lands at 9:40, I'll text when I'm through",
                "Dinner at the Cuba Street place tonight?", "The landlord is coming on the 14th, remember", "Sent you the photos from Mount Victoria"],
    "family": ["Mum says lunch is at 12:30 on Sunday", "Did you see the southerly forecast for Saturday?", "Call when you get a minute, nothing urgent",
               "Dad found the old tramping photos", "Are you coming up to Paraparaumu for the long weekend?", "The lemon cake recipe is in your inbox"],
    "friend": ["Climbing at 6? I booked the wall", "Dinner at ours on Friday — bring the board game", "The ferry was cancelled again, taking the bus",
               "Tararua trip is on if the weather holds", "Coffee at the wharf tomorrow?", "The door code for the bach is 2468 (changed for the demo)"],
    "work": ["Happy to look at the deck after lunch", "Thanks for the feedback on the onboarding flow", "Crit moved to 2 pm, room Kākā",
             "Can you share the research synthesis?", "Stand-up is async today", "The prototype link is in the channel"],
    "service": ["Your appointment is confirmed for Thursday 8:15 am", "The heat pump technician can come on Tuesday", "Please reply C to confirm"],
}


def _chat_line(rng: random.Random, person: Person) -> str:
    group = {"partner": "partner", "mother": "family", "father": "family", "sister": "family", "friend": "friend",
             "colleague": "work", "manager": "work", "service": "service"}.get(person.relationship, "friend")
    return rng.choice(_CHAT_LINES[group])


# (sender name, sender address, subject, body) — every company and code is invented.
_SERVICE_MAILS = [
    ("Tasman Skyways", "bookings@example.net", "Your boarding pass: WLG → ZQN",
     "Booking reference M4TB9H. Passenger: Robin Sample. Flight TY 512, seat 14A, boarding 07:05 at gate 12."),
    ("Tasman Skyways", "bookings@example.net", "Itinerary receipt — Queenstown, 4 nights",
     "Thank you for booking. Total NZ$ 412.00 charged to the card ending 0000."),
    ("Example Bank", "no-reply@example.com", "Your verification code",
     "Your one-time code is 482 913. It expires in 10 minutes. Never share this code with anyone."),
    ("Example Bank", "no-reply@example.com", "Your monthly statement is ready",
     "Your statement for the account ending 0000 is available in online banking."),
    ("Harbour Street Dental", "reception@example.net", "Appointment reminder: Thursday 8:15 am",
     "This is a reminder of your check-up with Dr Morgan Lee. Reply C to confirm."),
    ("Kōwhai Labs Payroll", "payroll@example.org", "Your payslip is available",
     "Your payslip for this pay period has been published in the people portal."),
    ("Te Aro Climbing Gym", "hello@example.net", "Membership renewal receipt",
     "We received NZ$ 89.00 for your monthly membership. See you on the wall."),
    ("Parcel Tracker", "tracking@example.com", "Your parcel is out for delivery",
     "Tracking number EX 4401 7723 NZ. Estimated delivery today between 1 pm and 5 pm."),
    ("Te Aro Library", "notices@example.org", "Item due soon: A Field Guide to the Birds of Aotearoa",
     "The item on your card is due in three days. Renew online or return it to any branch."),
    ("Example Cloud", "security@example.com", "Reset your password",
     "We received a request to reset your password. The link https://www.example.com/reset?token=demo-0000 expires in one hour."),
    ("Slow News Weekly", "newsletter@example.com", "The week in review",
     "This week: harbour ferries, a new cycleway and the long-range forecast."),
    ("Tūī & Fern Café", "hello@example.net", "Your loyalty card: one coffee to go",
     "Nine stamps collected. Your tenth flat white is on us."),
]

_MONTHLY_SUBJECTS = {"Your payslip is available", "Membership renewal receipt", "Your monthly statement is ready", "Itinerary receipt — Queenstown, 4 nights",
                     "Your boarding pass: WLG → ZQN", "Reset your password"}

_PERSON_SUBJECTS = {
    "colleague": ["Design crit notes — onboarding flow", "Re: Q1 roadmap draft", "User interviews: round 2 synthesis",
                  "Offsite logistics", "Component library audit", "Re: Accessibility review findings"],
    "manager": ["1:1 agenda for Thursday", "Re: Promotion case draft", "Headcount planning — confidential"],
    "family": ["Dad's birthday lunch", "Photos from Paraparaumu", "Christmas plans", "Re: Recipe for the lemon cake", "Fwd: Old tramping photos",
               "Long weekend — who is driving?", "Re: Jamie's new flat"],
    "friend": ["Tararua Southern Crossing — gear list", "Board game night", "Re: Climbing on Thursday?", "Film festival tickets", "Re: Sourdough starter",
               "Photos from the bach", "Fwd: Ferry timetable changes"],
    "service": ["Lease renewal — Aro Street", "Re: Heat pump service visit"],
}

_NOTES = [
    ("Packing list — Queenstown", "Boots, rain shell, head torch, charger, passport just in case"),
    ("Gift ideas for Alex", "Film camera strap, pottery class voucher, the bird book"),
    ("1:1 with Aroha", "Ask about the research budget; raise the promotion timeline"),
    ("Flat inspection", "Report the bathroom fan; landlord visit on the 14th"),
    ("Sourdough log", "Starter fed 8 am, 75 % hydration, bulk four hours"),
    ("Portfolio outline", "Ferry app case study, design system, typography talk"),
]

_REMINDERS = ["Renew passport", "Book the car in for its warrant", "Call Mum", "Send Aroha the crit notes",
              "Buy oat milk", "Return library book", "Pay the power bill", "Water the ferns"]

_SIRI_QUERIES = ["Set a timer for 12 minutes", "What's the weather in Wellington tomorrow", "Text Alex I'm running late",
                 "Remind me to call Mum at six", "Play Low Cloud", "How long is the drive to Paraparaumu",
                 "Add oat milk to my shopping list", "What time is sunset"]

_SETTINGS_SEARCHES = ["bluetooth", "night shift", "focus", "printer", "display", "keyboard shortcuts", "storage", "screen time"]

_MAIL_QUERIES = ["boarding pass", "payslip", "lease", "from:aroha crit", "dentist", "receipt climbing", "verification code", "itinerary"]

_FOCUS_MODES = [
    ("com.apple.focus.work", "Work"),
    ("com.apple.sleep.sleep-mode", "Sleep"),
    ("com.apple.donotdisturb.mode.default", "Do Not Disturb"),
    ("com.apple.focus.fitness", "Fitness"),
]

_AI_USE_CASES = [
    # use case, client bundle, weight, asset adapter
    ("com.apple.WritingTools.Proofread", "com.apple.Notes", 5, "proofreading"),
    ("com.apple.WritingTools.Rewrite", "com.apple.mail", 3, "rewriting"),
    ("com.apple.WritingTools.Summarize", "com.apple.Safari", 3, "summarization"),
    ("com.apple.mail.MessageSummary", "com.apple.mail", 8, "summarization"),
    ("com.apple.mail.SmartReply", "com.apple.mail", 4, "smart_reply"),
    ("com.apple.messages.SmartReply", "com.apple.MobileSMS", 6, "smart_reply"),
    ("com.apple.notifications.Summarization", "com.apple.notificationcenterui", 9, "summarization"),
    ("com.apple.Photos.MemoryCreation", "com.apple.Photos", 1, "story_generation"),
    ("com.apple.siri.QueryUnderstanding", "com.apple.Siri", 4, "planner"),
    ("com.apple.Notes.TranscriptSummary", "com.apple.Notes", 1.5, "summarization"),
    ("com.apple.Safari.ReaderSummary", "com.apple.Safari", 2, "summarization"),
]
_AI_BASE_MODEL = "com.apple.fm.language.instruct_3b.base"
_AI_SAFETY_MODEL = "com.apple.fm.safety.guardrail.base"
_AI_PROVIDER_LOCAL = "com.apple.modelmanager.OnDeviceInferenceProvider"
_AI_PROVIDER_CLOUD = "com.apple.modelmanager.PrivateCloudComputeProvider"
_AI_ERRORS = [("ModelManagerServices.ModelManagerError", 1013), ("GenerativeFunctions.GenerationError", 3),
              ("TokenGeneration.GuardrailViolation", 2), ("ModelManagerServices.ModelManagerError", 1001)]

_LEDGER_TASKS = [
    # task, runs per week, failure rate
    ("com.apple.siri.metrics.daily-digest", 7, 0.02),
    ("com.apple.mlhost.photos.memories-personalization", 3, 0.10),
    ("com.apple.fedstats.keyboard.emoji-usage", 7, 0.04),
    ("com.apple.mlhost.mail.categorization-evaluation", 5, 0.08),
    ("com.apple.triald.rollout.maintenance", 7, 0.01),
    ("com.apple.lighthouse.safari.search-aggregation", 4, 0.05),
    ("com.apple.mlhost.spotlight.ranking-evaluation", 2, 0.15),
    ("com.apple.fedstats.health.activity-summary", 2, 0.05),
    ("com.apple.mlhost.siri.asr-personalization", 1, 0.25),
    ("com.apple.dedisco.private-upload", 7, 0.03),
]

_VIEW_NAMES = ["personEntityTagging", "topContacts", "locationFrequency", "appUsageHabits", "mediaAffinity",
               "upcomingEvents", "relationshipInference", "homeWorkLocations"]

_EMPTY_STREAMS = [
    "App.ExtensionUsage", "CarPlay.Connected", "Device.Wireless.NFCTag", "GameController.Connected", "Screen.Sharing",
    "SpringBoard.ExternalDisplay.DisplayConnected", "WindowManager.StageManager.Toggled", "Passwords.SecurityRecommendations",
    "Feedback.EvaluationResponse", "Feedback.TextToTextEvaluationData", "Feedback.TextToImageEvaluationData",
    "Feedback.TextImageToImageEvaluationData", "IntelligenceFlow.Transcript.Datastream", "ToolKit.Transcript",
    "IntelligenceFlow.PlanResolutionTelemetry", "IntelligenceFlow.JointResolverTelemetry", "IntelligenceFlow.SearchToolTelemetry",
    "IntelligenceFlow.Experimentation", "IntelligenceEngine.Interaction.Donation", "Family.AskToBuy", "Family.ScreenTime.ChildState",
    "Family.ScreenTime.Request", "FindMy.LocationChange", "Location.MicroLocationVisit", "Location.HashedCoordinates",
    "Mail.Recategorization", "Mail.CategorizationAnalytics.Recategorize", "Messages.SharedWithYou.Feedback",
    "Moments.Events.Notifications", "Photos.AutonamingSuggestions.Feedback", "ProactiveHarvesting.News.Article",
    "ProactiveHarvesting.ParsecSearch", "ProactiveHarvesting.NotificationStacks", "Siri.ODDI.ODDAssistantLLMSiriDigests",
    "Siri.SELFProcessedRemote", "WalletPaymentsCommerce.FoundIn.OrderEmail", "Accessibility.ClassicInvert",
    "Accessibility.ColorFilters", "Accessibility.SmartInvert", "Accessibility.SoundDetection", "Accessibility.VoiceControl",
    "Accessibility.VoiceOver", "Accessibility.Zoom", "Accessibility.MotionCues", "_DKEvent.Device.LowPowerMode",
    "CommApps.CallIntelligence.CallContextCardsFedStats", "AppleIntelligence.Reporting.Buddy",
]

# knowledgeC: the CoreData layout of the real store (DDL only; ZSTRUCTUREDMETADATA carries
# the subset of its optional attribute columns that the demo fills).
_KNOWLEDGE_DDL = """
CREATE TABLE ZOBJECT ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZUUIDHASH INTEGER, ZEVENT INTEGER, ZSOURCE INTEGER, ZCATEGORYTYPE INTEGER, ZINTEGERVALUE INTEGER, ZCOMPATIBILITYVERSION INTEGER, ZENDDAYOFWEEK INTEGER, ZENDSECONDOFDAY INTEGER, ZHASCUSTOMMETADATA INTEGER, ZHASSTRUCTUREDMETADATA INTEGER, ZSECONDSFROMGMT INTEGER, ZSHOULDSYNC INTEGER, ZSTARTDAYOFWEEK INTEGER, ZSTARTSECONDOFDAY INTEGER, ZVALUECLASS INTEGER, ZVALUEINTEGER INTEGER, ZVALUETYPECODE INTEGER, ZSTRUCTUREDMETADATA INTEGER, ZVALUE INTEGER, Z9_VALUE INTEGER, ZIDENTIFIERTYPE INTEGER, ZQUANTITYTYPE INTEGER, ZCREATIONDATE TIMESTAMP, ZLOCALCREATIONDATE TIMESTAMP, ZCONFIDENCE FLOAT, ZENDDATE TIMESTAMP, ZSTARTDATE TIMESTAMP, ZVALUEDOUBLE FLOAT, ZDOUBLEVALUE FLOAT, ZUUID VARCHAR, ZSTREAMNAME VARCHAR, ZVALUESTRING VARCHAR, ZSTRING VARCHAR, ZMETADATA BLOB );
CREATE TABLE ZSOURCE ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZUSERID INTEGER, ZBUNDLEID VARCHAR, ZDEVICEID VARCHAR, ZGROUPID VARCHAR, ZINTENTID VARCHAR, ZITEMID VARCHAR, ZSOURCEID VARCHAR );
CREATE TABLE ZSYNCPEER ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZLASTSEENDATE TIMESTAMP, ZCLOUDID VARCHAR, ZDEVICEID VARCHAR, ZMODEL VARCHAR, ZRAPPORTID VARCHAR, ZVERSION VARCHAR, ZUUID BLOB );
CREATE TABLE ZSTRUCTUREDMETADATA ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
 Z_CDPORTRAITMETADATAKEY__ALGORITHM INTEGER, Z_DKAPPINSTALLMETADATAKEY__ISINSTALL INTEGER,
 Z_DKAPPLICATIONACTIVITYMETADATAKEY__ISELIGIBLEFORPREDICTION INTEGER, Z_DKAPPLICATIONACTIVITYMETADATAKEY__ISPUBLICLYINDEXABLE INTEGER,
 Z_DKAUDIOMETADATAKEY__ROUTECHANGEREASON INTEGER, Z_DKBLUETOOTHMETADATAKEY__BATTERYLEVELHEADPHONECASE INTEGER,
 Z_DKBLUETOOTHMETADATAKEY__BATTERYLEVELHEADPHONELEFT INTEGER, Z_DKBLUETOOTHMETADATAKEY__BATTERYLEVELHEADPHONERIGHT INTEGER,
 Z_DKBLUETOOTHMETADATAKEY__DEVICETYPE INTEGER, Z_DKBLUETOOTHMETADATAKEY__ISAPPLEAUDIODEVICE INTEGER, Z_DKBLUETOOTHMETADATAKEY__PRODUCTID INTEGER,
 Z_DKDEVICEBATTERYPERCENTAGEMETADATAKEY__FULLYCHARGED INTEGER, Z_DKDEVICEISPLUGGEDINMETADATAKEY__ADAPTERISWIRELESS INTEGER,
 Z_DKDIGITALHEALTHMETADATAKEY__ISUSAGETRUSTED INTEGER, Z_DKDIGITALHEALTHMETADATAKEY__USAGETYPE INTEGER,
 Z_DKINTENTMETADATAKEY__DIRECTION INTEGER, Z_DKINTENTMETADATAKEY__DONATEDBYSIRI INTEGER, Z_DKINTENTMETADATAKEY__INTENTHANDLINGSTATUS INTEGER,
 Z_DKINTENTMETADATAKEY__INTENTTYPE INTEGER, Z_DKNOWPLAYINGMETADATAKEY__ISAIRPLAYVIDEO INTEGER, Z_DKNOWPLAYINGMETADATAKEY__PLAYING INTEGER,
 Z_CDPORTRAITMETADATAKEY__DECAYRATE FLOAT, Z_CDPORTRAITMETADATAKEY__SCORE FLOAT, Z_DKNOWPLAYINGMETADATAKEY__DURATION FLOAT,
 Z_DKNOWPLAYINGMETADATAKEY__ELAPSED FLOAT, Z_DKAPPLICATIONACTIVITYMETADATAKEY__EXPIRATIONDATE TIMESTAMP,
 Z_CDENTITYMETADATAKEY__NAME VARCHAR, Z_CDPORTRAITMETADATAKEY__OSBUILD VARCHAR, Z_DKAPPINSTALLMETADATAKEY__PRIMARYCATEGORY VARCHAR,
 Z_DKAPPINSTALLMETADATAKEY__TITLE VARCHAR, Z_DKAPPLICATIONACTIVITYMETADATAKEY__ACTIVITYTYPE VARCHAR,
 Z_DKAPPLICATIONACTIVITYMETADATAKEY__ITEMIDENTIFIER VARCHAR, Z_DKAPPLICATIONACTIVITYMETADATAKEY__TITLE VARCHAR,
 Z_DKAPPLICATIONACTIVITYMETADATAKEY__USERACTIVITYUUID VARCHAR, Z_DKAUDIOMETADATAKEY__IDENTIFIER VARCHAR,
 Z_DKAUDIOMETADATAKEY__PORTNAME VARCHAR, Z_DKAUDIOMETADATAKEY__PORTTYPE VARCHAR, Z_DKBLUETOOTHMETADATAKEY__ADDRESS VARCHAR,
 Z_DKBLUETOOTHMETADATAKEY__NAME VARCHAR, Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN VARCHAR,
 Z_DKINTENTMETADATAKEY__DERIVEDINTENTIDENTIFIER VARCHAR, Z_DKINTENTMETADATAKEY__INTENTCLASS VARCHAR,
 Z_DKINTENTMETADATAKEY__INTENTVERB VARCHAR, Z_DKINTENTMETADATAKEY__INTERACTIONIDENTIFIER VARCHAR,
 Z_DKNOTIFICATIONUSAGEMETADATAKEY__BUNDLEID VARCHAR, Z_DKNOTIFICATIONUSAGEMETADATAKEY__IDENTIFIER VARCHAR,
 Z_DKNOWPLAYINGMETADATAKEY__ALBUM VARCHAR, Z_DKNOWPLAYINGMETADATAKEY__ARTIST VARCHAR, Z_DKNOWPLAYINGMETADATAKEY__GENRE VARCHAR,
 Z_DKNOWPLAYINGMETADATAKEY__MEDIATYPE VARCHAR, Z_DKNOWPLAYINGMETADATAKEY__TITLE VARCHAR, Z_DKSAFARIHISTORYMETADATAKEY__TITLE VARCHAR,
 ZMETADATAHASH VARCHAR, Z_DKINTENTMETADATAKEY__SERIALIZEDINTERACTION BLOB );
CREATE INDEX ZOBJECT_ZSTREAMNAME_INDEX ON ZOBJECT (ZSTREAMNAME, ZSTARTDATE);
CREATE UNIQUE INDEX Z_Object_UNIQUE_uuid ON ZOBJECT (ZUUID COLLATE BINARY ASC);
"""
_KNOWLEDGE_ENTITIES = {
    "AdditionChangeSet": 1, "ContextualChangeRegistration": 2, "ContextualKeyPath": 3, "CustomMetadata": 4, "DeletionChangeSet": 5,
    "Histogram": 6, "HistogramValue": 7, "KeyValue": 8, "Object": 9, "Category": 10, "Event": 11, "Identifier": 12, "Quantity": 13,
    "Source": 14, "StructuredMetadata": 15, "SyncPeer": 16,
}

# Biome sync.db: tables besides DevicePeer (which lib.write_biome_sync_db creates).
_SYNC_DDL = """
CREATE TABLE IF NOT EXISTS Metadata (
 key TEXT UNIQUE PRIMARY KEY ON CONFLICT REPLACE NOT NULL,
 value
);
CREATE TABLE IF NOT EXISTS CRDTLocation (
 id INTEGER primary key,
 stream STRING NOT NULL,
 site STRING NOT NULL,
 day INTEGER NOT NULL,
 state INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS AtomBatchFiles (
 atom_batch_filename STRING UNIQUE NOT NULL,
 session_id STRING,
 message_id INTEGER,
 originating_site_identifier STRING,
 location_id INTEGER NOT NULL,
 FOREIGN KEY (location_id) REFERENCES CRDTLocation(id)
);
CREATE TABLE IF NOT EXISTS CKAtom (
 stream STRING NOT NULL,
 site BLOB NOT NULL,
 clock INTEGER NOT NULL,
 type INTEGER NOT NULL,
 location_id INTEGER NOT NULL,
 segment_name TEXT,
 segment_offset INTEGER,
 ref_type INTEGER,
 ref_site BLOB,
 ref_clock INTEGER,
 ref_location_id INTEGER,
 value_version INTEGER,
 value_data BLOB,
 on_disk BOOLEAN,
 ref_atom_batch_filename STRING,
 atom_batch_file_index INTEGER,
 CONSTRAINT "ref_type <=> (ref_site AND ref_clock)"
 CHECK ((ref_type IS NULL) == ((ref_site IS NULL) AND (ref_clock IS NULL))),
 CONSTRAINT "(ref_type, ref_site, ref_clock) != (type, site, clock)"
 CHECK (ref_type != type OR ref_site != site OR ref_clock != clock),
 CONSTRAINT "segment_name <=> segment_offset"
 CHECK ((segment_name IS NULL) == (segment_offset IS NULL)),
 CONSTRAINT "on_disk <=> segment_name"
 CHECK (CASE WHEN on_disk NOTNULL THEN segment_name NOTNULL ELSE segment_name ISNULL END),
 CONSTRAINT "on_disk OR ref_atom_batch_filename <=> !data"
 CHECK (CASE WHEN ((on_disk NOTNULL) OR (ref_atom_batch_filename NOTNULL)) THEN value_data ISNULL ELSE value_data NOTNULL END),
 FOREIGN KEY (location_id) REFERENCES CRDTLocation(id),
 FOREIGN KEY (ref_location_id) REFERENCES CRDTLocation(id),
 FOREIGN KEY (ref_atom_batch_filename) REFERENCES AtomBatchFiles(atom_batch_filename),
 UNIQUE (stream, site, type, clock),
 UNIQUE (stream, site, clock, on_disk),
 UNIQUE (stream, site, type, clock, on_disk),
 UNIQUE (stream, site, type, segment_name, segment_offset)
);
CREATE TABLE IF NOT EXISTS TombstoneBookmark (
 stream STRING NOT NULL,
 site BLOB NOT NULL,
 segment_name TEXT,
 segment_offset INTEGER
);
CREATE TABLE IF NOT EXISTS SyncSessionLog (
 session_id BLOB,
 start_timestamp INTEGER,
 end_timestamp INTEGER,
 transport INTEGER,
 reason INTEGER,
 is_reciprocal BOOL,
 time_since_previous_sync INTEGER
);
CREATE TABLE IF NOT EXISTS SyncMessageLog (
 session_id BLOB,
 message_id INTEGER,
 timestamp INTEGER,
 device_identifier STRING,
 reachable BOOL,
 is_reciprocal BOOL,
 atom_batch_bytes INTEGER
);
CREATE TABLE IF NOT EXISTS AtomMergedLog (
 session_id BLOB,
 message_id INTEGER,
 stream STRING,
 merge_result INTEGER,
 owning_site_identifier STRING,
 relayed_by_site_identifier STRING,
 synced_at INTEGER,
 event_created_at INTEGER
);
CREATE TABLE IF NOT EXISTS CKRecord (
 location_id INTEGER,
 sync_to_cloud_kit BOOL,
 record_metadata BLOB,
 record_name STRING,
 stream_identifier STRING,
 local_mergeable_value BLOB,
 deleting BOOL,
 record_type INTEGER,
 deleted_crdt BOOL,
 PRIMARY KEY (stream_identifier, record_name),
 FOREIGN KEY (location_id) REFERENCES CRDTLocation(id)
);
CREATE TABLE IF NOT EXISTS CKMergeableRecordValue (
 stream_name STRING,
 record_name STRING,
 server_mergeable_value BLOB,
 FOREIGN KEY (stream_name, record_name) REFERENCES CKRecord(stream_identifier, record_name)
);
CREATE TABLE IF NOT EXISTS CKZone (
 zone_name STRING NOT NULL,
 zone_uuid STRING NOT NULL,
 recovery_state INTEGER,
 attempted_recovery_date INTEGER
);
CREATE INDEX IF NOT EXISTS idx_ckatom_ref_clock_type ON CKAtom(stream, ref_clock, type);
CREATE INDEX IF NOT EXISTS idx_ckatom_segment_name ON CKAtom(stream, segment_name);
CREATE INDEX IF NOT EXISTS idx_ckatom_location_id ON CKAtom(location_id, clock);
CREATE INDEX IF NOT EXISTS idx_crdt_location ON CRDTLocation(stream, site, day);
CREATE INDEX IF NOT EXISTS idx_crdt_location_state ON CRDTLocation(stream, site, state, day DESC);
CREATE INDEX IF NOT EXISTS idx_tombstone_bookmark ON TombstoneBookmark(stream, site);
CREATE INDEX IF NOT EXISTS idx_syncsessionlog_start_timestamp ON SyncSessionLog(start_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_syncmessagelog_session_id ON SyncMessageLog(session_id);
CREATE INDEX IF NOT EXISTS idx_atommergedlog_session_id ON AtomMergedLog(session_id);
CREATE INDEX IF NOT EXISTS idx_atommergedlog_owning_site_identifier ON AtomMergedLog(owning_site_identifier);
CREATE INDEX IF NOT EXISTS idx_ckrecord ON CKRecord(record_name);
"""

# Biome sync addresses two streams by a short name; the others by a UUID.
_SYNC_SHORT_NAMES = {"App.InFocus": "AppLaunch", "Media.NowPlaying": "NowPlaying"}


# ----------------------------------------------------------------------------------------
# Generator
# ----------------------------------------------------------------------------------------

class _Generator:
    def __init__(self, root: pathlib.Path, persona: Persona, rng: random.Random, now: datetime.datetime):
        self.root, self.p, self.rng = root, persona, rng
        self.now = now.astimezone(datetime.timezone.utc)
        self.tz = datetime.timedelta(hours=persona.tz_offset_hours)
        local_now = self.now + self.tz
        self.local_midnight = local_now.replace(hour=0, minute=0, second=0, microsecond=0)
        self.gmt_seconds = int(persona.tz_offset_hours * 3600)

        self.restricted = lib.library(root, "Biome/streams/restricted")
        self.duet = lib.library(root, "DuetExpertCenter/streams")
        # What earlier modules already wrote is theirs: never touched, never extended.
        self.foreign = {d.name for d in self.restricted.iterdir()} if self.restricted.is_dir() else set()
        self.foreign_duet = {d.name for d in self.duet.iterdir()} if self.duet.is_dir() else set()

        self.mac = persona.this_mac
        self.iphone = persona.device("iphone")
        self.ipad = persona.device("ipad")
        self.watch = persona.device("watch")
        self.account = persona.owner.email
        self.home_dir = "/Users/" + persona.owner.given.lower()
        self.versions: dict[str, tuple[str, str]] = {}

    # -- time ----------------------------------------------------------------------------

    def t(self, day: int, hour: int = 0, minute: int = 0, second: float = 0) -> datetime.datetime:
        """Local wall-clock time `day` days ago, as UTC."""
        return self.local_midnight - datetime.timedelta(days=day) - self.tz + datetime.timedelta(hours=hour, minutes=minute, seconds=second)

    def weekday(self, day: int) -> int:
        return (self.local_midnight - datetime.timedelta(days=day)).weekday()

    def past(self, when: datetime.datetime) -> bool:
        return when <= self.now - datetime.timedelta(seconds=45)

    def day_of(self, when: datetime.datetime) -> int:
        return (self.local_midnight - (when + self.tz).replace(hour=0, minute=0, second=0, microsecond=0)).days

    def plus(self, when: datetime.datetime, seconds: float) -> datetime.datetime:
        return when + datetime.timedelta(seconds=seconds)

    def uuid(self) -> str:
        return lib.uuid_string(self.rng)

    def mac_address(self) -> str:
        # Locally administered address: cannot be a manufacturer-assigned (real) one.
        return ":".join(["02"] + [f"{self.rng.randrange(256):02X}" for _ in range(5)])

    # -- output --------------------------------------------------------------------------

    def emit(self, name: str, records: Iterable[Any], device: Optional[Any] = None, deleted: float = 0.0) -> None:
        """Writes one device's records of a restricted Biome stream unless the stream
        belongs to an earlier module. `deleted`: share of records written as deleted."""
        if name in self.foreign:
            return
        out = []
        for when, payload in records:
            if not self.past(when):
                continue
            out.append(lib.SEGBRecord(when, payload, deleted=deleted > 0 and self.rng.random() < deleted))
        stream_dir = lib.biome_stream_dir(self.root, name)
        lib.ensure_dir(stream_dir / "local")
        if out:
            lib.write_stream(stream_dir, out, device=None if device is None else device.identifier, max_records=2500)

    def emit_duet(self, name: str, records: Iterable[Any]) -> None:
        if name in self.foreign_duet:
            return
        out = [(w, p) for w, p in records if self.past(w)]
        lib.ensure_dir(self.duet / name / "local")
        if out:
            lib.write_stream(self.duet / name, out, max_records=2500)

    def version(self, bundle: str) -> tuple[str, str]:
        if bundle not in self.versions:
            r = self.rng
            self.versions[bundle] = (f"{r.randint(1, 27)}.{r.randint(0, 6)}", f"{r.randint(100, 9999)}.{r.randint(1, 9)}.{r.randint(1, 30)}")
        return self.versions[bundle]

    # -- the simulated weeks ---------------------------------------------------------------

    def build_world(self) -> None:
        p, rng = self.p, self.rng
        self.trip = set(range(37, 41))                       # a long weekend in Queenstown: the Mac stays home
        self.days_off = {d for d in range(HISTORY) if self.weekday(d) < 5 and rng.random() < 0.05} - self.trip

        def chooser(apps, boost):
            weights = [a.weight * boost.get(a.category, 1.0) for a in apps]
            return lambda: rng.choices(apps, weights=weights)[0].bundle_id

        mac_apps = p.apps_on("mac")
        work = chooser(mac_apps, {"productivity": 1.6, "developer": 1.1, "communication": 1.3, "media": 0.25, "utility": 0.6})
        leisure = chooser(mac_apps, {"productivity": 0.3, "developer": 0.3, "communication": 0.8, "media": 1.7, "browser": 1.6})
        phone = chooser(p.apps_on("iphone"), {"social": 1.6, "communication": 1.3})
        pad = chooser(p.apps_on("ipad"), {"media": 2.0, "browser": 1.3})
        wrist = chooser([a for a in p.apps_on("watch") if a.bundle_id != "com.apple.SessionTrackerApp"], {})

        sessions: dict[str, list[tuple[datetime.datetime, int, str]]] = {"mac": [], "iphone": [], "ipad": [], "watch": []}
        self.work_blocks: list[tuple[datetime.datetime, datetime.datetime, str]] = []   # Mac awake periods (start, end, place key)

        def fill(key, day, start, end, choose, mu):
            out = sessions[key]
            cursor = start + rng.randint(0, 420)
            first = cursor
            while cursor < end:
                length = int(min(2700, max(6, rng.lognormvariate(mu, 0.95))))
                out.append((self.t(day, 0, 0, cursor), length, choose()))
                cursor += length + (rng.randint(180, 900) if rng.random() < 0.1 else rng.randint(0, 3))
            return self.t(day, 0, 0, first), self.t(day, 0, 0, cursor)

        hour_weights = [0, 0, 0, 0, 0, 0, 0.4, 1.5, 2.0, 1.0, 0.9, 1.0, 2.0, 1.3, 0.9, 0.9, 1.1, 2.0, 2.0, 2.2, 2.3, 2.2, 1.6, 0.5]
        for day in range(HISTORY, -1, -1):
            weekday = self.weekday(day)
            working = weekday < 5 and day not in self.days_off and day not in self.trip
            if day not in self.trip:
                if working:
                    place = "home" if weekday == 4 and rng.random() < 0.6 else "work"     # some Fridays from home
                    a = fill("mac", day, 8 * 3600 + 35 * 60, 12 * 3600 + 20 * 60, work, 5.5)
                    b = fill("mac", day, 13 * 3600 + 10 * 60, 17 * 3600 + 35 * 60, work, 5.5)
                    self.work_blocks += [(a[0], a[1], place), (b[0], b[1], place)]
                    if rng.random() < 0.55:
                        c = fill("mac", day, 20 * 3600, 21 * 3600 + 40 * 60, leisure, 5.2)
                        self.work_blocks.append((c[0], c[1], "home"))
                else:
                    for start, end, chance in ((10 * 3600, 11 * 3600 + 30 * 60, 0.65), (15 * 3600 + 30 * 60, 17 * 3600, 0.45), (20 * 3600, 21 * 3600 + 30 * 60, 0.5)):
                        if rng.random() < chance:
                            c = fill("mac", day, start, end, leisure, 5.3)
                            self.work_blocks.append((c[0], c[1], "cafe" if start < 12 * 3600 and rng.random() < 0.3 else "home"))
            # iPhone: many short sessions through the waking day.
            starts = sorted(rng.choices(range(24), weights=hour_weights)[0] * 3600 + rng.randrange(3600)
                            for _ in range(rng.randint(45, 80) + (18 if day in self.trip else 0)))
            cursor = 0
            for start in starts:
                start = max(start, cursor + rng.randint(4, 90))
                length = int(min(1500, max(5, rng.lognormvariate(4.0, 1.0))))
                sessions["iphone"].append((self.t(day, 0, 0, start), length, phone()))
                cursor = start + length
            if rng.random() < 0.45:
                fill("ipad", day, 20 * 3600 + 15 * 60, 21 * 3600 + 50 * 60, pad, 5.7)
            for _ in range(rng.randint(4, 11)):
                sessions["watch"].append((self.t(day, rng.randint(7, 21), rng.randrange(60), rng.randrange(60)), rng.randint(4, 40), wrist()))
            if weekday in (1, 3) and day not in self.trip:                               # climbing evenings
                sessions["watch"].append((self.t(day, 18, rng.randint(2, 12)), rng.randint(2700, 3900), "com.apple.SessionTrackerApp"))
        self.sessions = {k: sorted(s for s in v if self.past(self.plus(s[0], s[1]))) for k, v in sessions.items()}
        self.work_blocks = sorted(b for b in self.work_blocks if self.past(b[1]))

        # Listening: (when, device key, app, title, artist, album, seconds, media type, route, state)
        plays: list[tuple] = []
        self.headphone_periods: list[tuple[datetime.datetime, datetime.datetime, str]] = []
        airpods = p.owner.given + "'s AirPods Pro"

        def listen(device, day, start_seconds, app, items, route):
            when = self.t(day, 0, 0, start_seconds)
            begin = when
            for title, artist, album, seconds, kind in items:
                plays.append((when, device, app, title, artist, album, seconds, kind, route, 1))
                if rng.random() < 0.12:
                    pause = self.plus(when, seconds * rng.uniform(0.2, 0.8))
                    plays.append((pause, device, app, title, artist, album, seconds, kind, route, 2))
                    plays.append((self.plus(pause, rng.randint(20, 400)), device, app, title, artist, album, seconds, kind, route, 1))
                    when = self.plus(when, rng.randint(20, 400))
                when = self.plus(when, seconds + rng.randint(0, 3))
            plays.append((when, device, app, items[-1][0], items[-1][1], items[-1][2], items[-1][3], items[-1][4], route, 2 if rng.random() < 0.7 else 3))
            if route == airpods:
                self.headphone_periods.append((self.plus(begin, -rng.randint(5, 40)), self.plus(when, rng.randint(5, 120)), device))

        def tracks(n):
            first = rng.randrange(len(p.tracks))
            picked = [p.tracks[(first + i * rng.choice((1, 1, 2, 3))) % len(p.tracks)] for i in range(n)]
            return [(t.title, t.artist, t.album, t.seconds, "Music") for t in picked]

        def podcast():
            show, episode = rng.choice(p.podcasts)
            return [(episode, show, show, rng.randint(1500, 3100), "Podcast")]

        for day in range(HISTORY, -1, -1):
            weekday = self.weekday(day)
            working = weekday < 5 and day not in self.days_off and day not in self.trip
            if working:
                if rng.random() < 0.6:
                    listen("mac", day, rng.randint(9 * 3600 + 20 * 60, 15 * 3600), rng.choice(("com.apple.Music", "com.apple.Music", "com.spotify.client")),
                           tracks(rng.randint(5, 13)), airpods if rng.random() < 0.8 else "MacBook Pro Speakers")
                if rng.random() < 0.6:
                    listen("iphone", day, 8 * 3600 + rng.randint(0, 600), "com.apple.podcasts", podcast(), airpods)
                if rng.random() < 0.4:
                    listen("iphone", day, 17 * 3600 + 45 * 60 + rng.randint(0, 600), rng.choice(("com.apple.Music", "com.spotify.client")), tracks(rng.randint(4, 7)), airpods)
            elif rng.random() < 0.5:
                listen("iphone", day, rng.randint(9 * 3600, 16 * 3600), "com.apple.Music", tracks(rng.randint(5, 10)),
                       rng.choice((airpods, "Kitchen Speaker", "iPhone")))
            if weekday in (1, 3) and day not in self.trip:
                listen("watch", day, 18 * 3600 + rng.randint(300, 800), "com.apple.Music", tracks(rng.randint(8, 11)), airpods)
        self.plays = sorted(x for x in plays if self.past(x[0]))
        self.airpods = airpods
        self.accessories = [
            # name, address, vendor, product, device type, is Apple audio
            (airpods, self.mac_address(), 76, 8228, 20, 1),
            ("Magic Keyboard", self.mac_address(), 76, 668, 3, 0),
            ("Magic Trackpad", self.mac_address(), 76, 613, 4, 0),
            ("Kitchen Speaker", self.mac_address(), 1452, 4660, 17, 0),
        ]

        # Messages and calls Siri remembers: (when, person, app, direction 1 in / 2 out, device key)
        msgs, calls = [], []
        for day in range(HISTORY, -1, -1):
            for _ in range(rng.randint(5, 17)):
                person = p.weighted_person(rng)
                device = "iphone" if rng.random() < 0.62 else "mac"
                app = rng.choices(["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "org.whispersystems.signal"], weights=[70, 22, 8])[0]
                if person.relationship in ("colleague", "manager", "service") or (device == "mac" and app.startswith("org.")):
                    app = "com.apple.MobileSMS"
                msgs.append((self.t(day, rng.randint(7, 22), rng.randrange(60), rng.randrange(60)), person, app, 1 if rng.random() < 0.55 else 2, device))
            for _ in range(rng.choices([0, 1, 2, 3], weights=[30, 40, 20, 10])[0]):
                person = p.weighted_person(rng)
                kind = rng.choices(["phone", "facetime", "whatsapp"], weights=[60, 25, 15])[0]
                device = "mac" if kind == "facetime" and rng.random() < 0.4 else "iphone"
                app = {"phone": "com.apple.mobilephone", "whatsapp": "net.whatsapp.WhatsApp",
                       "facetime": "com.apple.FaceTime" if device == "mac" else "com.apple.facetime"}[kind]
                missed = rng.random() < 0.15
                calls.append((self.t(day, rng.randint(8, 21), rng.randrange(60), rng.randrange(60)), person, app,
                              1 if rng.random() < 0.5 else 2, device, 0 if missed else int(min(3600, max(12, rng.lognormvariate(5.3, 0.9))))))
        self.msgs = sorted((m for m in msgs if self.past(m[0])), key=lambda m: m[0])
        self.calls = sorted((c for c in calls if self.past(c[0])), key=lambda c: c[0])

        # Mail the harvesting pipeline has seen: (when, sender name, address, subject, body, message id)
        mails = []
        last_sent: dict[str, int] = {}
        for day in range(90, -1, -1):
            for _ in range(rng.randint(1, 5)):
                when = self.t(day, rng.randint(7, 21), rng.randrange(60), rng.randrange(60))
                due = [m for m in _SERVICE_MAILS if m[0] != "Tasman Skyways" and last_sent.get(m[2], 999) - day >= (28 if m[2] in _MONTHLY_SUBJECTS else 11)]
                if due and rng.random() < 0.42:
                    name, address, subject, body = rng.choice(due)
                    last_sent[subject] = day
                else:
                    person = p.weighted_person(rng)
                    group = person.relationship if person.relationship in _PERSON_SUBJECTS else ("family" if person in p.family else "friend")
                    subject = rng.choice(_PERSON_SUBJECTS[group])
                    name, address = person.full_name, person.email
                    body = f"Hi {p.owner.given} — {_chat_line(rng, person)}. {person.given}"
                mails.append((when, name, address, subject, body, f"<{lib.hex_string(rng, 16)}@{address.rsplit('@', 1)[-1]}>"))
        # The trip: booked three weeks ahead, boarding passes on the mornings of the flights.
        airline = [m for m in _SERVICE_MAILS if m[0] == "Tasman Skyways"]
        for day, hour, (name, address, subject, body) in ((62, 20, airline[1]), (41, 16, airline[0]),
                                                          (38, 9, (airline[0][0], airline[0][1], "Your boarding pass: ZQN → WLG",
                                                                   "Booking reference M4TB9H. Passenger: Robin Sample. Flight TY 517, seat 9C, boarding 15:40 at gate 3."))):
            mails.append((self.t(day, hour, rng.randrange(60)), name, address, subject, body, f"<{lib.hex_string(rng, 16)}@example.net>"))
        self.mails = sorted((m for m in mails if self.past(m[0])), key=lambda m: m[0])

        # Web pages opened in Safari on the Mac: (when, seconds, url, domain, title)
        visits = []
        for start, length, bundle in self.sessions["mac"]:
            if bundle != "com.apple.Safari" or self.day_of(start) > 60:
                continue
            cursor = 0
            for _ in range(rng.randint(1, 4)):
                domain, title = rng.choice(p.web_domains)
                host, paths = _WEB_PATHS.get(domain, (domain, ["/"]))
                stay = max(4, int(length / 3 * rng.uniform(0.4, 1.2)))
                visits.append((self.plus(start, cursor), stay, f"https://{host}{rng.choice(paths)}", domain, title))
                cursor += stay
                if cursor >= length:
                    break
        self.visits = visits

    # -- App.* -----------------------------------------------------------------------------

    def app_streams(self) -> None:
        rng = self.rng
        reasons = [r for r, _ in _IOS_LAUNCH_REASONS]
        reason_weights = [w for _, w in _IOS_LAUNCH_REASONS]

        for key, device in (("mac", None), ("iphone", self.iphone), ("ipad", self.ipad), ("watch", self.watch)):
            focus, usage = [], []
            for start, length, bundle in self.sessions[key]:
                version, build = self.version(bundle)
                reason = None if key in ("mac", "watch") else rng.choices(reasons, weights=reason_weights)[0]
                end = self.plus(start, length)
                for when, on in ((start, True), (end, False)):
                    focus.append((when, pb.message([(1, reason if on else None), (2, 1 if on else 2), (3, on), (4, lib.cocoa(when)), (6, bundle),
                                                    (9, version), (10, build)])))
                if self.day_of(start) <= 35 and key in ("mac", "iphone", "ipad"):
                    usage.append((start, pb.message([(1, True), (2, lib.unix(start)), (3, bundle)])))
                    usage.append((end, pb.message([(1, False), (2, lib.unix(end)), (3, bundle)])))
            self.emit("App.InFocus", focus, device)
            self.emit("ScreenTime.AppUsage", usage, device)

        # Media usage follows the listening sessions.
        for key, device in (("mac", None), ("iphone", self.iphone)):
            records, session, last = [], None, None
            for play in [x for x in self.plays if x[1] == key]:
                when, app, state = play[0], play[2], play[9]
                if session is None or (last is not None and (when - last).total_seconds() > 3600):
                    session = self.uuid()
                    records.append((when, pb.message([(1, True), (2, app), (6, lib.unix(when)), (8, session)])))
                elif state in (2, 3) and rng.random() < 0.5:
                    records.append((when, pb.message([(1, False), (2, app), (6, lib.unix(when)), (8, session)])))
                    session = None
                last = when
            self.emit("App.MediaUsage", records, device)

        menu, documents, activities, pasteboard, language = [], [], [], [], []
        activity_types = {"com.apple.Safari": ("NSUserActivityTypeBrowsingWeb", None), "com.apple.mail": ("com.apple.mail.message", "Reading a message"),
                          "com.apple.Notes": ("com.apple.notes.activity.edit-note", None), "com.apple.iCal": ("com.apple.calendar.continuity.event_selection", "Viewing an event"),
                          "com.apple.Maps": ("com.apple.Maps", "Directions")}
        for start, length, bundle in self.sessions["mac"]:
            day = self.day_of(start)
            if bundle in _MENU_ITEMS and day <= 45 and rng.random() < 0.22:
                menu.append((self.plus(start, length * rng.random()), pb.message([(1, bundle), (3, rng.choice(_MENU_ITEMS[bundle]))])))
            if bundle in ("com.apple.Preview", "com.microsoft.VSCode", "com.apple.finder") and day <= 60 and rng.random() < 0.35:
                path, uti, opener = rng.choice([d for d in _DOCUMENTS if bundle == "com.apple.finder" or d[2] == bundle])
                documents.append((self.plus(start, 2), pb.message([(1, rng.choice((1, 1, 2))), (2, [(1, f"{self.home_dir}/{path}"), (2, self.blob(rng.randint(500, 900)))]),
                                                                  (3, uti), (4, [(1, opener)])])))
            if bundle in activity_types and day <= 30 and rng.random() < 0.3:
                kind, title = activity_types[bundle]
                if bundle == "com.apple.Notes":
                    title = rng.choice(_NOTES)[0]
                elif bundle == "com.apple.Safari":
                    title = rng.choice(self.p.web_domains)[1]
                activities.append((self.plus(start, 3), pb.message([(1, bundle), (2, kind), (3, title), (4, lib.cocoa(start)), (5, self.uuid())])))
            if day <= 21 and rng.random() < 0.08:
                pasteboard.append((self.plus(start, length * rng.random()), pb.message([(1, bundle), (2, lib.cocoa(start)), (3, rng.choice(("public.utf8-plain-text", "public.url", "public.png")))])))
            if day <= 30 and rng.random() < 0.03:
                language.append((self.plus(start, 5), pb.message([(1, bundle), (2, rng.choices(self.p.languages, weights=[12, 1])[0]), (3, rng.randint(40, 4000))])))
        self.emit("App.MenuItem", menu)
        self.emit("App.DocumentInteraction", documents)
        self.emit("App.Activity", activities)
        self.emit("Pasteboard.Change", pasteboard)
        self.emit("App.LanguageConsumption", language)

        # Intents donated by apps (mostly the phone): the messages and calls of the last weeks.
        for key, device in (("iphone", self.iphone), ("mac", None)):
            records = []
            for when, person, app, direction, dev in self.msgs:
                if dev == key and self.day_of(when) <= 45:
                    records.append((when, self.intent_record(when, app, "INSendMessageIntent", "Send", 3 - direction, person, app + ":" + person.handle)))
            for when, person, app, direction, dev, seconds in self.calls:
                if dev == key and self.day_of(when) <= 45:
                    records.append((when, self.intent_record(when, app, "INStartCallIntent", "Start", 3 - direction, person, None)))
            for play in self.plays:
                if play[1] == key and play[9] == 1 and self.day_of(play[0]) <= 45 and rng.random() < 0.25:
                    records.append((play[0], self.intent_record(play[0], play[2], "INPlayMediaIntent", "Play", 0, None, None, title=play[3])))
            self.emit("App.Intent", records, device)

        # App Intents executions; the same executions are mirrored into linkd's transcripts.
        self.executions = []
        for start, length, bundle in self.sessions["mac"]:
            if self.day_of(start) <= 40 and rng.random() < 0.06:
                app, action, parameters, label = rng.choice(_APP_INTENTS)
                self.executions.append((self.plus(start, length * rng.random()), app, action, parameters, label, lib.uuid_obj(rng)))
        self.emit("App.Intents.Transcript", [
            (when, pb.message([(1, app), (3, ident.bytes), (4, lib.unix(when)), (5, [(1, action)] if rng.random() < 0.2 else None),
                               (6, [(1, action)] + [(7, [(1, name)]) for name in parameters])]))
            for when, app, action, parameters, label, ident in self.executions])

        shortcuts = []
        for day in range(30, -1, -2):
            app, action, parameters, label = rng.choice(_APP_INTENTS)
            archive = lib.keyed_archive(lib.ArchiveObject("INRelevantShortcut", {
                "shortcut": lib.ArchiveObject("INShortcut", {"intentIdentifier": action, "title": action.replace("Intent", "")}),
                "widgetKind": "", "shortcutRole": 0}))
            shortcuts.append((self.t(day, 7, rng.randrange(60)), pb.message([(1, app), (3, archive)])))
        self.emit("App.RelevantShortcuts", shortcuts)

    def blob(self, size: int) -> bytes:
        return bytes(self.rng.getrandbits(8) for _ in range(size))

    def intent_record(self, when, app, intent_class, verb, direction, person: Optional[Person], group, title: Optional[str] = None) -> bytes:
        fields: dict[str, Any] = {"intentClass": intent_class, "dateInterval": when}
        if person is not None:
            fields["person"] = lib.ArchiveObject("INPerson", {"displayName": person.full_name, "handle": person.handle,
                                                              "contactIdentifier": person.contact_id})
        if title:
            fields["mediaItem"] = lib.ArchiveObject("INMediaItem", {"title": title})
        return pb.message([(1, lib.cocoa(when)), (2, app), (3, "intents"), (4, intent_class), (5, verb), (7, 3), (8, lib.keyed_archive(lib.ArchiveObject("INInteraction", fields))),
                           (9, self.uuid()), (11, direction), (12, group)])

    # -- Media -----------------------------------------------------------------------------

    def media_streams(self) -> None:
        for key, device in (("mac", None), ("iphone", self.iphone), ("watch", self.watch)):
            records = []
            for when, dev, app, title, artist, album, seconds, kind, route, state in self.plays:
                if dev == key:
                    records.append((when, pb.message([(2, lib.cocoa(when)), (3, state), (4, album), (5, artist), (6, seconds), (8, title),
                                                      (10, kind), (14, [(3, route)]), (15, app)])))
            self.emit("Media.NowPlaying", records, device)

        routes = []
        for start, end, dev in self.headphone_periods:
            if dev == "mac":
                routes.append((start, pb.message([(1, self.airpods), (2, "BluetoothA2DPOutput"), (3, True)])))
                routes.append((end, pb.message([(1, "MacBook Pro Speakers"), (2, "BuiltInSpeaker"), (3, True)])))
        self.emit("Audio.Route", routes)

    # -- Web -------------------------------------------------------------------------------

    def web_streams(self) -> None:
        rng = self.rng
        usage, navigations, loads, pageviews = [], [], [], []
        for when, stay, url, domain, title in self.visits:
            view = self.uuid()
            usage.append((when, pb.message([(1, view), (2, lib.cocoa(when)), (3, 1), (4, url), (5, domain), (6, "com.apple.Safari")])))
            usage.append((self.plus(when, stay), pb.message([(1, view), (2, lib.cocoa(self.plus(when, stay))), (3, 2), (4, url), (5, domain), (6, "com.apple.Safari")])))
            bucket = float(int(lib.unix(when)) // 3600 * 3600)
            navigations.append((when, pb.message([(1, domain), (2, bucket), (5, self.p.region), (8, url)])))
            loads.append((when, pb.message([(1, domain), (2, rng.randint(180, 2400)), (3, rng.choice((0, 0, 0, 1)))])))
            if self.day_of(when) <= 30 and rng.random() < 0.5:
                pageviews.append((when, pb.message([(1, title), (2, url), (3, "com.apple.Safari"), (4, lib.cocoa(when)), (5, self.uuid())])))
        self.emit("App.WebUsage", usage, deleted=0.02)
        self.emit("Safari.Navigations", navigations, deleted=0.03)
        self.emit("Safari.PageLoad", loads)
        self.emit("ProactiveHarvesting.Safari.PageView", pageviews)
        # The phone and the tablet browse too.
        for key, device in (("iphone", self.iphone), ("ipad", self.ipad)):
            records = []
            for start, length, bundle in self.sessions[key]:
                if bundle == "com.apple.mobilesafari" and self.day_of(start) <= 60:
                    domain, _ = rng.choice(self.p.web_domains)
                    host, paths = _WEB_PATHS.get(domain, (domain, ["/"]))
                    records.append((start, pb.message([(1, domain), (2, float(int(lib.unix(start)) // 3600 * 3600)), (5, self.p.region), (8, f"https://{host}{rng.choice(paths)}")])))
            self.emit("Safari.Navigations", records, device)
        self.emit("Safari.SearchEngine", [(self.t(day, 9, 5), pb.message([(1, "DuckDuckGo")])) for day in (88, 41, 6)])

    # -- Notifications ---------------------------------------------------------------------

    def notification_streams(self) -> None:
        rng, p = self.rng, self.p
        self.notifications: list[tuple] = []      # (when, device key, bundle, identifier, usage type)
        senders = {
            "mac": ["com.apple.MobileSMS", "com.apple.mail", "com.tinyspeck.slackmacgap", "com.apple.iCal", "com.apple.reminders", "net.whatsapp.WhatsApp"],
            "iphone": ["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "com.apple.mobilemail", "com.tinyspeck.chatlyio", "com.burbn.instagram",
                       "com.apple.mobilecal", "com.apple.reminders", "com.apple.weather", "org.whispersystems.signal", "com.apple.Passbook"],
        }
        weights = {"mac": [5, 4, 8, 2, 1, 2], "iphone": [9, 6, 4, 5, 4, 1, 1, 1, 2, 0.5]}
        for key, device, per_day in (("mac", None, (6, 16)), ("iphone", self.iphone, (18, 38))):
            delivery, usage = [], []
            for day in range(30, -1, -1):
                working = self.weekday(day) < 5
                for _ in range(rng.randint(*per_day) if working or key == "iphone" else rng.randint(1, 5)):
                    when = self.t(day, rng.randint(7, 22), rng.randrange(60), rng.randrange(60))
                    bundle = rng.choices(senders[key], weights=weights[key])[0]
                    ident = self.uuid()
                    delivery.append((when, pb.message([(1, ident), (2, bundle), (3, lib.unix(when))])))
                    usage.append((when, pb.message([(2, lib.cocoa(when)), (3, 1), (4, bundle), (5, ident)])))
                    self.notifications.append((when, key, bundle, ident, "Receive"))
                    follow = rng.random()
                    if follow < 0.75:
                        kind, label = rng.choices([(3, "DefaultAction"), (5, "Dismiss"), (6, "Hide"), (4, "IndirectClear")], weights=[30, 35, 20, 15])[0]
                        later = self.plus(when, rng.randint(3, 2400))
                        usage.append((later, pb.message([(2, lib.cocoa(later)), (3, kind), (4, bundle), (5, ident)])))
                        self.notifications.append((later, key, bundle, ident, label))
            self.emit("Notification.Delivery", delivery, device)
            self.emit("Notification.Usage", usage, device)

        harvested = []
        for when, key, bundle, ident, label in self.notifications:
            if key == "iphone" and label == "Receive" and self.day_of(when) <= 14 and bundle in ("com.apple.MobileSMS", "net.whatsapp.WhatsApp", "com.apple.mobilecal", "com.apple.Passbook"):
                person = p.weighted_person(rng)
                if bundle == "com.apple.mobilecal":
                    title, body = "Design crit", "In 15 minutes · " + p.place("work").name
                elif bundle == "com.apple.Passbook":
                    title, body = "Tasman Skyways", "Boarding pass updated: gate 12, seat 14A"
                else:
                    title, body = person.full_name, _chat_line(rng, person)
                harvested.append((when, pb.message([(1, title), (2, body), (3, bundle), (4, lib.cocoa(when)), (5, ident)])))
        self.emit("ProactiveHarvesting.Notifications", harvested, self.iphone)

    # -- Device & system -------------------------------------------------------------------

    def device_streams(self) -> None:
        rng, p = self.rng, self.p
        networks = {n.place: n.ssid for n in p.networks if n.ssid != p.networks[-1].ssid}
        wifi, legacy, nearby, auth, discover, bluetooth = [], [], [], [], [], []
        self.wifi_periods: list[tuple[datetime.datetime, datetime.datetime, str]] = []
        phone_token, watch_token = self.uuid(), self.uuid()
        keyboard, trackpad = self.accessories[1], self.accessories[2]
        self.bluetooth_periods: list[tuple[datetime.datetime, datetime.datetime, tuple]] = []
        for start, end, place in self.work_blocks:
            ssid = networks.get(place, networks["home"])
            a, b = self.plus(start, -rng.randint(20, 90)), self.plus(end, rng.randint(30, 600))
            self.wifi_periods.append((a, b, ssid))
            wifi += [(a, pb.message([(1, ssid), (2, True)])), (b, pb.message([(1, ssid), (2, False)]))]
            legacy.append((b, pb.message([(1, [(1, "/wifi/connection")]), (2, lib.cocoa(a)), (3, lib.cocoa(b)), (4, [(3, ssid)]), (5, self.uuid()),
                                          (8, lib.cocoa(b)), (10, self.gmt_seconds)])))
            for token in (phone_token, watch_token):
                nearby += [(self.plus(a, rng.randint(1, 30)), pb.message([(1, True), (2, token)])), (self.plus(b, rng.randint(1, 60)), pb.message([(1, False), (2, token)]))]
            if place == "home":
                for accessory in (keyboard, trackpad):
                    self.bluetooth_periods.append((self.plus(a, rng.randint(2, 20)), self.plus(b, -rng.randint(1, 20)), accessory))
            if rng.random() < 0.5:
                auth.append((self.plus(a, rng.randint(40, 400)), pb.message([(1, "com.apple.LocalAuthentication.ui"),
                                                                           (2, rng.choice(("com.apple.Safari", "com.apple.Passwords", "com.apple.systempreferences", "com.apple.loginwindow")))])))
        for start, end, dev in self.headphone_periods:
            if dev == "mac":
                self.bluetooth_periods.append((start, end, self.accessories[0]))
        for start, end, (name, address, vendor, product, kind, apple_audio) in self.bluetooth_periods:
            levels = [(6, rng.randint(35, 100)), (7, rng.randint(35, 100)), (8, rng.randint(20, 100))] if apple_audio else []
            bluetooth.append((start, pb.message([(1, address), (2, name), (3, product), (4, True), (5, kind), (11, vendor)] + levels)))
            bluetooth.append((end, pb.message([(1, address), (2, name), (3, product), (4, False), (5, kind), (11, vendor)])))
        self.emit("Device.Wireless.WiFi", wifi)
        self.emit("_DKEvent.Wifi.Connection", legacy)
        self.emit("Device.Wireless.BluetoothNearbyDevice", nearby)
        self.emit("Device.Wireless.Bluetooth", bluetooth)
        self.emit("LocalAuthentication.UI.Dialogs", auth)

        signals = ["com.apple.finder.quick-look.used", "com.apple.dock.stage-manager.eligible", "com.apple.screenshot.markup.used",
                   "com.apple.spotlight.calculation.performed", "com.apple.window-tiling.edge-drag", "com.apple.focus.schedule.suggested"]
        for day in range(60, -1, -1):
            for _ in range(rng.choice((0, 0, 1, 1, 2))):
                signal = rng.choice(signals)
                discover.append((self.t(day, rng.randint(9, 20), rng.randrange(60)), pb.message([(1, signal), (2, signal.split(".")[2]), (3, self.mac.os_build)])))
        self.emit("Discoverability.Signals", discover)

        # Focus: Work on working days, Sleep every night (set on the phone, mirrored here).
        for device in (None, self.iphone):
            computed = []
            for day in range(75, -1, -1):
                if self.weekday(day) < 5 and day not in self.days_off and day not in self.trip:
                    computed += self.focus_pair(self.t(day, 9, rng.randint(0, 8)), self.t(day, 17, rng.randint(20, 40)), _FOCUS_MODES[0])
                computed += self.focus_pair(self.t(day, 22, rng.randint(30, 55)), self.t(day - 1, 6, rng.randint(40, 55)), _FOCUS_MODES[1])
                if rng.random() < 0.12:
                    begin = self.t(day, rng.randint(13, 19), rng.randrange(60))
                    computed += self.focus_pair(begin, self.plus(begin, rng.randint(1800, 7200)), _FOCUS_MODES[2])
            self.emit("UserFocus.ComputedMode", computed, device)
        inferred = []
        for day in range(45, -1, -1):
            if self.weekday(day) in (1, 3) and day not in self.trip:
                begin = self.t(day, 18, rng.randint(5, 15))
                for when, on in ((begin, True), (self.plus(begin, rng.randint(2700, 3900)), False)):
                    inferred.append((when, pb.message([(1, lib.cocoa(when)), (2, _FOCUS_MODES[3][0]), (3, 4), (6, on), (7, self.uuid()),
                                                       (10, round(rng.uniform(0.72, 0.98), 3)), (12, 2), (14, "Exercise")])))
            if self.weekday(day) < 5 and day not in self.days_off and day not in self.trip and rng.random() < 0.7:
                begin = self.t(day, 9, rng.randint(0, 30))
                for when, on in ((begin, True), (self.plus(begin, rng.randint(6000, 12000)), False)):
                    inferred.append((when, pb.message([(1, lib.cocoa(when)), (2, _FOCUS_MODES[0][0]), (3, 2), (6, on), (7, self.uuid()),
                                                       (10, round(rng.uniform(0.55, 0.95), 3)), (12, 1), (14, "Work")])))
        self.emit("UserFocus.InferredMode", inferred, self.iphone)
        self.emit("UserFocus.StatusChange", [(self.t(day, 9, rng.randint(1, 9)), pb.message([(1, True), (2, _FOCUS_MODES[0][0])]))
                                             for day in range(30, -1, -1) if self.weekday(day) < 5 and day not in self.days_off and day not in self.trip])

        # Phone-only system state.
        low_power, airplane, alarms = [], [], []
        for day in range(HISTORY, -1, -1):
            if rng.random() < 0.18:
                begin = self.t(day, rng.randint(17, 22), rng.randrange(60))
                low_power += [(begin, pb.message([(1, True)])), (self.plus(begin, rng.randint(1800, 9000)), pb.message([(1, False)]))]
            if self.weekday(day) < 5 and day <= 60 and day not in self.trip:
                when = self.t(day, 6, 45)
                alarms.append((when, pb.message([(1, self.alarm_id), (2, "Weekdays"), (3, 1), (4, lib.cocoa(when))])))
        for day in (40, 37):                                                            # the two flights of the trip
            begin = self.t(day, 7 if day == 40 else 16, 20)
            airplane += [(begin, pb.message([(1, True)])), (self.plus(begin, 5700), pb.message([(1, False)]))]
        self.emit("Device.Power.LowPowerMode", low_power, self.iphone)
        self.emit("Device.Wireless.AirplaneMode", airplane, self.iphone)
        self.emit("Clock.Alarm", alarms, self.iphone)
        self.emit("Accessibility.ReduceMotion", [(self.t(96, 20, 14), pb.message([(1, True)])), (self.t(95, 8, 51), pb.message([(1, False)]))])
        self.emit("Accessibility.ReduceTransparency", [(self.t(96, 20, 15), pb.message([(1, True)]))])
        self.emit("Accessibility.Contrast", [(self.t(71, 11, 2), pb.message([(1, False)]))])

        screenshots, searches = [], []
        for start, length, bundle in self.sessions["mac"]:
            day = self.day_of(start)
            if day <= 60 and rng.random() < 0.012:
                when = self.plus(start, length * rng.random())
                local = when + self.tz
                hour = local.hour % 12 or 12
                name = f"Screenshot {local:%Y-%m-%d} at {hour}.{local:%M.%S} {'AM' if local.hour < 12 else 'PM'}.png"
                screenshots.append((when, pb.message([(1, [(4, [(1, f"{self.home_dir}/Desktop/{name}"), (2, self.blob(rng.randint(600, 900))), (3, self.blob(32))])])])))
            if bundle == "com.apple.systempreferences" and day <= 60 and rng.random() < 0.5:
                searches.append((self.plus(start, 4), pb.message([(1, rng.choice(_SETTINGS_SEARCHES)), (2, lib.cocoa(start))])))
        self.emit("Screenshots.Screenshot", screenshots)
        self.emit("SystemSettings.SearchTerms", searches)
        self.emit("SpringBoard.WindowManagement.StageManagerMode", [(self.t(52, 10, 3), pb.message([(1, False)]))])

    @property
    def alarm_id(self) -> str:
        if not hasattr(self, "_alarm_id"):
            self._alarm_id = self.uuid()
        return self._alarm_id

    def focus_pair(self, begin, end, mode) -> list:
        ident, name = mode
        return [(begin, pb.message([(1, ident), (2, True), (6, name)])), (end, pb.message([(1, ident), (2, False), (6, name)]))]

    # -- Siri ------------------------------------------------------------------------------

    def remembers(self, when, app, intent, domain, direction, role, entities, seconds=None, conversation=None, metadata=None) -> bytes:
        interaction = [(1, self.uuid()), (2, intent), (3, domain), (4, app), (6, direction), (8, lib.unix(when)), (9, seconds),
                       (11, json.dumps(metadata, ensure_ascii=False) if metadata else None), (12, conversation), (13, self.uuid())]
        group = [(1, role)] + [(2, [(1, ident), (2, kind), (4, json.dumps(body, ensure_ascii=False))]) for ident, kind, body in entities]
        return pb.message([(1, interaction), (2, group)])

    def person_entity(self, person: Person):
        return (person.handle, "person", {"name": person.full_name, "handle": person.handle, "contactIdentifier": person.contact_id})

    def siri_streams(self) -> None:
        rng, p = self.rng, self.p
        for key, device in (("mac", None), ("iphone", self.iphone)):
            messages, calls, audio = [], [], []
            for when, person, app, direction, dev in self.msgs:
                if dev == key:
                    service = "iMessage" if app == "com.apple.MobileSMS" else app.rsplit(".", 1)[-1]
                    messages.append((when, self.remembers(when, app, "INSendMessageIntent", "Messages", direction,
                                                          "senderHandle" if direction == 1 else "recipientHandles", [self.person_entity(person)],
                                                          conversation=f"{service};-;{person.handle}", metadata={"service": service})))
            for when, person, app, direction, dev, seconds in self.calls:
                if dev == key:
                    calls.append((when, self.remembers(when, app, "INStartCallIntent", "Calls", direction, "callParticipants", [self.person_entity(person)],
                                                       seconds=seconds or None, metadata={"callType": "video" if "ace" in app else "audio", "missed": seconds == 0})))
            for when, dev, app, title, artist, album, seconds, kind, route, state in self.plays:
                if dev == key and state == 1 and rng.random() < 0.3:
                    audio.append((when, self.remembers(when, app, "INPlayMediaIntent", "Media", 0, "mediaItems",
                                                       [(lib.hex_string(rng, 12), kind.lower(), {"title": title, "artist": artist, "album": album})])))
            self.emit("Siri.Remembers.MessageHistory", messages, device)
            self.emit("Siri.Remembers.CallHistory", calls, device)
            self.emit("Siri.Remembers.AudioHistory", audio, device)

        interactions, suggestions, queries, engagement = [], [], [], []
        for when, app, action, parameters, label, ident in self.executions:
            interactions.append((when, self.remembers(when, app, action, "AppIntents", 0, "items", [(self.uuid(), "appEntity", {"name": action.replace("Intent", "")})])))
        for day in range(60, -1, -1):
            if rng.random() < 0.5:
                note = rng.choice(_NOTES)[0]
                when = self.t(day, rng.randint(8, 21), rng.randrange(60))
                interactions.append((when, self.remembers(when, "com.apple.Notes", "CreateNoteIntent", "Notes", 0, "items", [(self.uuid(), "note", {"name": note})])))
            for _ in range(rng.choice((0, 1, 1, 2))):
                person = p.weighted_person(rng)
                when = self.t(day, rng.randint(7, 21), rng.randrange(60))
                text = rng.choice((f"Call {person.full_name}", f"Message {person.full_name}", "Turn on Work Focus", "Play " + rng.choice(p.tracks).title,
                                   "Directions to " + rng.choice(p.places[:14]).name))
                suggestions.append((when, self.remembers(when, "com.apple.Siri", "SuggestedAction", "Suggestions", 0, "suggestions",
                                                         [(self.uuid(), "suggestion", {"name": text, "engaged": rng.random() < 0.3})])))
            if rng.random() < 0.6:
                when = self.t(day, rng.randint(7, 21), rng.randrange(60))
                query = rng.choice(_SIRI_QUERIES)
                queries.append((when, pb.message([(1, query), (2, p.locale), (3, lib.cocoa(when)), (4, self.uuid())])))
                engagement.append((self.plus(when, rng.randint(2, 40)), pb.message([(1, rng.choice(("com.apple.MobileSMS", "com.apple.Music", "com.apple.weather", "com.apple.reminders"))),
                                                                                   (2, rng.randint(1, 3)), (3, self.uuid())])))
        self.emit("Siri.Remembers.InteractionHistory", interactions)
        self.emit("Siri.Remembers.AssistantSuggestions", suggestions, self.iphone)
        self.emit("ProactiveHarvesting.Siri.Query", queries, self.iphone)
        self.emit("Siri.PostSiriEngagement", engagement, self.iphone)

        for name, period in (("UserSeed", 7), ("UserAggregationId", 7), ("UserSamplingId", 90), ("HomeSeed", 14)):
            records = []
            for day in range(HISTORY - 3, -1, -period):
                when = self.t(day, 3, rng.randrange(60))
                records.append((when, pb.message([(1, lib.uuid_obj(rng).bytes), (2, lib.unix(when)), (3, period), (4, lib.unix(when)), (5, lib.unix(when))])))
            self.emit("Siri.AnalyticsIdentifiers." + name, records)
        self.emit("Siri.SELFProcessedEvent", [(self.t(day, rng.randint(8, 21), rng.randrange(60)), pb.message([(1, lib.uuid_obj(rng).bytes), (2, rng.randint(1, 40)), (3, self.blob(rng.randint(40, 180)))]))
                                              for day in range(20, -1, -1) for _ in range(rng.randint(2, 9))])
        self.emit("Siri.ODDI.ScorecardMetrics", [(self.t(day, 4, 10), pb.message([(1, "daily"), (2, rng.randint(0, 9)), (3, round(rng.random(), 3))])) for day in range(30, -1, -1)])
        self.emit("Siri.ODDI.SegmentsCohorts", [(self.t(day, 4, 12), pb.message([(1, "cohort-" + rng.choice("ABCD")), (2, p.locale)])) for day in range(28, -1, -7)])

    # -- Harvesting, text understanding, mail ------------------------------------------------

    def harvesting_streams(self) -> None:
        rng, p = self.rng, self.p
        harvested, documents, events, links, deletions, categories = [], [], [], [], [], []
        for when, name, address, subject, body, message_id in self.mails:
            seen = self.plus(when, rng.randint(5, 600))
            html = f"<html><body><p>{body}</p></body></html>"
            harvested.append((seen, pb.message([(1, message_id), (3, lib.cocoa(when))] + [(10, [(1, h)]) for h in ("from", "to", "subject", "date", "message-id")]
                                               + [(11, subject), (14, html), (17, self.account), (19, "INBOX"), (23, [(1, name), (2, address)])])))
            documents.append((self.plus(seen, rng.randint(1, 90)), pb.message([(1, [(1, "com.apple.mail"), (3, message_id)]), (2, lib.cocoa(seen)), (3, lib.cocoa(when)),
                                                                               (12, subject), (17, body), (18, [(1, name), (2, address)]), (25, self.account)])))
            categories.append((seen, pb.message([(1, message_id), (2, rng.choices([0, 1, 2, 3], weights=[55, 20, 15, 10])[0]), (3, round(rng.uniform(0.5, 0.99), 3))])))
            if "boarding" in subject.lower() or "Appointment" in subject:
                events.append((self.plus(seen, 30), pb.message([(1, message_id), (2, subject), (3, lib.cocoa(self.plus(when, 3 * DAY))), (4, "com.apple.mail")])))
            if "http" in body:
                links.append((self.plus(seen, 30), pb.message([(1, message_id), (2, "https://www.example.com/reset?token=demo-0000"), (3, "com.apple.mail")])))
            if rng.random() < 0.04:
                deletions.append((self.plus(seen, rng.randint(DAY, 9 * DAY)), pb.message([(1, "com.apple.mail"), (3, message_id), (4, lib.cocoa(seen))])))
        messages = []
        for when, person, app, direction, dev in self.msgs:
            if self.day_of(when) <= 30 and app == "com.apple.MobileSMS" and rng.random() < 0.5:
                text = _chat_line(rng, person if direction == 1 else p.weighted_person(rng))
                sender = person if direction == 1 else p.owner
                ident = self.uuid()
                messages.append((when, pb.message([(1, sender.full_name), (2, text), (3, sender.handle), (4, app), (5, lib.cocoa(when)), (6, ident)])))
                documents.append((self.plus(when, 20), pb.message([(1, [(1, app), (3, ident)]), (2, lib.cocoa(when)), (3, lib.cocoa(when)), (12, person.full_name), (17, text),
                                                                   (18, [(1, sender.full_name), (2, sender.handle)])])))
        for day in (33, 12, 3):                                                          # one-time codes arrive by text as well
            when = self.t(day, rng.randint(9, 20), rng.randrange(60))
            code = f"{rng.randint(100, 999)} {rng.randint(100, 999)}"
            messages.append((when, pb.message([(1, "Example Bank"), (2, f"Example Bank: your one-time code is {code}. Never share it."), (3, "8300"),
                                               (4, "com.apple.MobileSMS"), (5, lib.cocoa(when)), (6, self.uuid())])))
        self.emit("ProactiveHarvesting.Mail", harvested, deleted=0.03)
        self.emit("TextUnderstanding.Output.Document", documents, deleted=0.03)
        self.emit("TextUnderstanding.Output.Event", events)
        self.emit("TextUnderstanding.Output.Link", links)
        self.emit("TextUnderstanding.Deletions.Document", deletions)
        self.emit("ProactiveHarvesting.Messages", messages)
        self.emit("Mail.Categorization", categories)
        self.emit("Mail.CategorizationAnalytics.Receive", [(w, pb.message([(1, rng.randint(0, 3)), (2, rng.randint(1, 4))])) for w, _ in categories[-120:]])
        self.emit("Mail.CategorizationAnalytics.Read", [(self.plus(w, rng.randint(60, 7200)), pb.message([(1, rng.randint(0, 3)), (2, rng.randint(2, 90))])) for w, _ in categories[-80:]])

        notes, reminders, third, queries, ui, ranker = [], [], [], [], [], []
        for day in range(60, -1, -1):
            if rng.random() < 0.35:
                title, text = rng.choice(_NOTES)
                when = self.t(day, rng.randint(8, 22), rng.randrange(60))
                notes.append((when, pb.message([(1, title), (2, text), (3, "com.apple.Notes"), (4, lib.cocoa(when)), (5, self.uuid())])))
            if rng.random() < 0.3:
                when = self.t(day, rng.randint(8, 22), rng.randrange(60))
                reminders.append((when, pb.message([(1, rng.choice(_REMINDERS)), (2, rng.choice(("Home", "Work", "Shopping"))), (3, lib.cocoa(when)), (4, self.uuid())])))
            if self.weekday(day) < 5 and day not in self.trip and day <= 30:
                for _ in range(rng.randint(1, 4)):
                    when = self.t(day, rng.randint(9, 17), rng.randrange(60))
                    channel = rng.choice(("#design-crit", "#product", "#random", "#wellington-office"))
                    bundle, title = rng.choice((("com.tinyspeck.slackmacgap", channel), ("notion.id", rng.choice(("Roadmap Q1", "Research repository", "Design principles"))),
                                                ("com.figma.Desktop", rng.choice(("Onboarding flow v3", "Component library", "Ferry app — prototype")))))
                    third.append((when, pb.message([(1, title), (2, bundle), (3, lib.cocoa(when)), (4, self.uuid())])))
            if rng.random() < 0.3 and day <= 45:
                when = self.t(day, rng.randint(9, 20), rng.randrange(60))
                session = self.uuid()
                queries.append((when, pb.message([(1, rng.choice(_MAIL_QUERIES))])))
                ui += [(self.plus(when, i * 2), pb.message([(1, session), (2, kind)])) for i, kind in enumerate((1, 2, rng.choice((3, 4))))]
                ranker.append((self.plus(when, 1), pb.message([(1, session), (4, [(7, [(1, m[5])]) for m in rng.sample(self.mails, min(5, len(self.mails)))])])))
        self.emit("ProactiveHarvesting.Notes", notes)
        self.emit("ProactiveHarvesting.Reminders", reminders)
        self.emit("ProactiveHarvesting.ThirdPartyApp", third)
        self.emit("Mail.Search.Query", queries)
        self.emit("Mail.Search.UIEvent", ui)
        self.emit("Mail.Search.RankerEvent", ranker)
        self.emit("Unilog.MailSearch.Processed", [(self.plus(w, 600), pb.message([(1, self.uuid()), (2, 1)])) for w, _ in queries])
        self.emit("WalletPaymentsCommerce.FoundIn.ReceiptEmail", [
            (self.plus(when, 120), pb.message([(1, message_id), (2, name), (3, "NZD"), (4, 89.0 if "Gym" in name else 412.0)]))
            for when, name, address, subject, body, message_id in self.mails if "receipt" in subject.lower()])

    # -- Places, wallet, home, photos (mostly from the phone) ---------------------------------

    def misc_streams(self) -> None:
        rng, p = self.rng, self.p
        semantic, poi, wallet, home, read, deleted_photos, media_analysis = [], [], [], [], [], [], []
        categories = {"cafe": "Cafe", "landmark": "Landmark", "park": "Park", "transit": "PublicTransport", "gym": "FitnessCenter", "shop": "Market"}
        merchants = [(p.place("cafe").name, 5.5, 14.0), (p.place("coffee").name, 5.0, 9.5), (p.place("market").name, 12.0, 60.0),
                     (p.place("gym").name, 22.0, 22.0), (p.place("cable_car").name, 6.0, 12.0), ("Te Aro Grocer", 18.0, 140.0), ("Bus fare", 2.5, 5.2)]
        for day in range(90, -1, -1):
            working = self.weekday(day) < 5 and day not in self.days_off and day not in self.trip
            if day in self.trip:
                stops = [(8, p.place("queenstown")), (19, p.place("queenstown"))]
            elif working:
                stops = [(7, p.place("home")), (9, p.place("work")), (18, p.place("gym") if self.weekday(day) in (1, 3) else p.place("home")), (20, p.place("home"))]
                if rng.random() < 0.4:
                    stops.insert(2, (12, p.place(rng.choice(("cafe", "coffee")))))
            else:
                stops = [(8, p.place("home")), (rng.randint(10, 15), rng.choice(p.places[2:14])), (18, p.place("home"))]
            for hour, place in stops:
                when = self.t(day, hour, rng.randrange(50))
                label = {"home": "Home", "work": "Work", "gym": "Gym"}.get(place.key, "")
                semantic.append((when, pb.message([(1, lib.cocoa(when)), (2, label or place.kind.capitalize()), (3, place.name), (4, True)])))
                if place.kind in categories:
                    poi.append((when, pb.message([(1, categories[place.kind]), (2, lib.cocoa(when))])))
            for _ in range(rng.choice((0, 1, 1, 2, 3))):
                name, low, high = rng.choices(merchants, weights=[5, 3, 2, 0.4, 0.3, 3, 4])[0]
                when = self.t(day, rng.randint(8, 20), rng.randrange(60))
                wallet.append((when, pb.message([(1, name), (2, round(rng.uniform(low, high), 2)), (3, "NZD"), (4, "Apple Pay"), (5, lib.cocoa(when)), (6, self.uuid())])))
            if day not in self.trip:
                for hour, accessory, value in ((7, "Heat Pump", "On"), (22, "Living Room Lamp", "Off"), (19, "Living Room Lamp", "On")):
                    if rng.random() < 0.55:
                        when = self.t(day, hour, rng.randrange(60))
                        home.append((when, pb.message([(1, accessory), (2, "Living Room"), (3, value), (4, "com.apple.Home"), (5, lib.cocoa(when))])))
            if rng.random() < 0.15:
                when = self.t(day, rng.randint(19, 22), rng.randrange(60))
                deleted_photos.append((when, pb.message([(1, self.uuid() + "/L0/001"), (2, lib.cocoa(when))])))
            if day <= 30:
                when = self.t(day, 2, rng.randrange(60))
                media_analysis.append((when, pb.message([(1, rng.randint(0, 40)), (2, rng.randint(0, 6)), (3, round(rng.uniform(0.5, 30), 2))])))
        for when, person, app, direction, dev in self.msgs:
            if dev == "iphone" and direction == 1 and self.day_of(when) <= 30 and rng.random() < 0.6:
                later = self.plus(when, rng.randint(5, 3600))
                read.append((later, pb.message([(1, person.handle), (2, app), (3, lib.cocoa(later))])))
        self.emit("Location.Semantic", semantic, self.iphone)
        self.emit("Location.PointOfInterest.Category", poi, self.iphone)
        self.emit("Wallet.Transaction", wallet, self.iphone)
        self.emit("HomeKit.Client.AccessoryControl", home, self.iphone)
        self.emit("Messages.Read", read, self.iphone)
        self.emit("Photos.Delete", deleted_photos)
        self.emit("MediaAnalysis.VisualSearch.Processing", media_analysis)
        self.emit("MediaAnalysis.PEC.Processing", [(self.plus(w, 300), pb.message([(1, rng.randint(0, 12)), (2, rng.randint(0, 3))])) for w, _ in media_analysis])
        self.emit("MediaAnalysis.TextUnderstanding.ProcessingResults", [(self.plus(w, 600), pb.message([(1, rng.randint(0, 25)), (2, p.language)])) for w, _ in media_analysis])
        self.emit("ProactiveHarvesting.Photos.View", [(self.plus(s, 3), pb.message([(1, self.uuid() + "/L0/001"), (2, lib.cocoa(s))]))
                                                      for s, _, b in self.sessions["mac"] if b == "com.apple.Photos" and self.day_of(s) <= 30])
        self.emit("ProactiveHarvesting.Photos.KnowledgeGraphEnrichment", [(self.t(day, 3, 20), pb.message([(1, rng.randint(1, 30)), (2, "personInference")])) for day in range(28, -1, -1)])

        views, inference = [], []
        for day in range(45, -1, -1):
            for _ in range(rng.randint(3, 9)):
                views.append((self.t(day, rng.randint(0, 23), rng.randrange(60)), pb.message([(1, rng.choice(_VIEW_NAMES))])))
            if day % 3 == 0:
                for person in p.others:
                    if rng.random() < 0.5 + person.closeness / 2:
                        tag = {"partner": 3, "mother": 5, "father": 5, "sister": 5, "friend": 8, "colleague": 11, "manager": 12}.get(person.relationship, 20)
                        inference.append((self.t(day, 3, 30, rng.random() * 50), pb.message([(1, person.graph_id), (2, tag), (3, round(min(0.99, person.closeness + rng.uniform(-0.1, 0.1)), 3))])))
        self.emit("IntelligencePlatform.Views.Updated", views)
        self.emit("IntelligencePlatform.EntityTagging.PersonInference", inference)

        for name, every in (("Unilog.HealthTelemetry", 1), ("Unilog.HealthAggregatedSummary", 7), ("Unilog.SafariSearch.Stage", 1),
                            ("Unilog.SafariSearch.Aggregation", 7), ("Unilog.SafariFeature.Stage", 2), ("Unilog.SafariFeature.Aggregation", 7),
                            ("Unilog.SafariSearch.LongTermAggregationId", 30)):
            self.emit(name, [(self.t(day, 4, rng.randrange(60)), pb.message([(1, lib.uuid_obj(rng).bytes), (2, rng.randint(1, 60)), (3, self.mac.os_build)]))
                             for day in range(56, -1, -every)])

    # -- Apple Intelligence ----------------------------------------------------------------

    def intelligence_streams(self) -> None:
        rng, p = self.rng, self.p
        weights = [w for _, _, w, _ in _AI_USE_CASES]
        records, transparency, usage, safety, request_telemetry = [], [], [], [], []
        for day in range(75, -1, -1):
            working = self.weekday(day) < 5 and day not in self.days_off
            if day in self.trip:
                continue
            for _ in range(rng.randint(14, 34) if working else rng.randint(3, 12)):
                use_case, client, _, adapter = rng.choices(_AI_USE_CASES, weights=weights)[0]
                when = self.t(day, rng.randint(8, 21), rng.randrange(60), rng.random() * 60)
                cloud = use_case.endswith("Rewrite") and rng.random() < 0.3
                trace = lib.uuid_obj(rng).bytes
                assets = [(_AI_BASE_MODEL, "1.4.203"), (f"com.apple.fm.language.instruct_3b.{adapter}", "1.4.118"), (_AI_SAFETY_MODEL, "1.2.57")]
                context = [(3, client), (8, use_case), (13, _AI_PROVIDER_CLOUD if cloud else _AI_PROVIDER_LOCAL)] + ([] if cloud else [(10, [(1, a), (2, v)]) for a, v in assets[:2]])
                failed = rng.random() < 0.045
                steps = ["RequestStarted"]
                if not cloud and rng.random() < 0.18:
                    steps += ["AssetLoadStarted", "AssetLoadCompleted"]
                steps += ["PromptRendered", "SafetyCheckCompleted"]
                steps += ["RequestFailed"] if failed else ["FirstTokenGenerated", "InferenceCompleted", "RequestCompleted"]
                cursor = when
                for step in steps:
                    fields: list = [(3, "GenerativeFunctions." + step), (6, [(1, trace)]), (8, lib.unix(cursor)), (10, context)]
                    if step == "AssetLoadCompleted":
                        fields.append((4, [(3, [(7, [(1, a)]) for a, _ in assets])]))
                    if step == "RequestFailed":
                        domain, code = rng.choice(_AI_ERRORS)
                        fields.append((11, [(1, [(1, domain), (2, code)])]))
                    records.append((cursor, pb.message(fields)))
                    cursor = self.plus(cursor, rng.uniform(0.02, 2.5))
                if day <= 30:
                    usage.append((when, pb.message([(1, use_case), (2, client), (3, 1)])))
                    request_telemetry.append((when, pb.message([(1, trace), (2, use_case), (3, round((cursor - when).total_seconds(), 3)), (4, not failed)])))
                    if rng.random() < 0.3:
                        safety.append((cursor, pb.message([(1, trace), (2, "guardrail.input"), (3, 0), (4, round(rng.random() * 0.2, 4))])))
        self.emit("GenerativeModels.GenerativeFunctions.Instrumentation", records)
        self.emit("Intelligence.Usage", usage)
        self.emit("IntelligenceFlow.IFRequestTelemetry", request_telemetry)
        self.emit("IntelligenceFlow.Telemetry", [(w, pb.message([(1, "requestCompleted"), (2, lib.unix(w))])) for w, _ in request_telemetry[::3]])
        self.emit("PrivateMLClient.SafetyMetrics", safety)
        planner = [(w, payload) for w, payload in request_telemetry if b"QueryUnderstanding" in payload]
        self.emit("IntelligenceFlow.PlanGenerationTelemetry", [(self.plus(w, 0.4), pb.message([(1, "planGenerated"), (2, rng.randint(1, 4))])) for w, _ in planner])
        self.emit("IntelligenceFlow.ExecutorTelemetry", [(self.plus(w, 0.9), pb.message([(1, "toolExecuted"), (2, rng.choice(("createReminder", "sendMessage", "getWeather")))])) for w, _ in planner])
        self.emit("IntelligenceFlow.ResponseGeneration", [(self.plus(w, 1.4), pb.message([(1, "responseGenerated"), (2, rng.randint(8, 60))])) for w, _ in planner])
        self.emit("IntelligenceFlow.QueryDecorationTelemetry", [(self.plus(w, 0.2), pb.message([(1, "queryDecorated"), (2, rng.randint(0, 5))])) for w, _ in planner])

        # The transparency log keeps the text that went in and came out.
        exchanges = [
            ("com.apple.WritingTools.Proofread", "com.apple.Notes", "Proofread: Ask about the reserch budget; raise the promotion timline",
             "Ask about the research budget; raise the promotion timeline."),
            ("com.apple.mail.MessageSummary", "com.apple.mail", "Summarise this message: Hi Robin, the crit moved to Thursday 2 pm, room Kākā. Bring the onboarding prototype.",
             "The design crit is now Thursday at 2 pm in room Kākā; bring the onboarding prototype."),
            ("com.apple.WritingTools.Rewrite", "com.apple.mail", "Make this friendlier: I can't make Friday. Send the lease by email.",
             "Unfortunately I can't make Friday — could you email me the lease instead? Thanks so much!"),
            ("com.apple.messages.SmartReply", "com.apple.MobileSMS", "Suggest a reply to: Climbing at 6? I booked the wall", "Sounds great, see you at 6!"),
            ("com.apple.notifications.Summarization", "com.apple.notificationcenterui", "Summarise 4 notifications from Alex Marlowe",
             "Alex is running late and asks you to pick up oat milk."),
            ("com.apple.Safari.ReaderSummary", "com.apple.Safari", "Summarise the article: How tides work", "Tides are caused by the gravitational pull of the Moon and the Sun."),
        ]
        for day in range(34, -1, -3):
            use_case, client, prompt, response = rng.choice(exchanges)
            when = self.t(day, rng.randint(9, 20), rng.randrange(60))
            transparency.append((when, pb.message([(1, client), (2, use_case), (3, prompt), (4, response), (5, _AI_BASE_MODEL), (6, lib.unix(when)), (7, self.uuid())])))
        self.emit("GenerativeExperiences.TransparencyLog", transparency)

        availability = []
        flags = [(1, 1, 0, 0, 0), (1, 1, 1, 1, 0), (1, 1, 1, 1, 1), (1, 1, 1, 1, 1), (1, 0, 1, 1, 0), (1, 1, 1, 1, 1)]
        for index, day in enumerate((74, 74, 73, 52, 21, 20)):
            a, b, c, d, e = flags[index]
            availability.append((self.t(day, 10 + index, 7 * index), pb.message([(1, [(1, a)]), (2, [(1, b)]), (3, c), (6, p.locale), (6, "en_AU"), (8, [(1, d), (2, e), (3, 1)])])))
        self.emit("AppleIntelligence.Availability", availability)

        subscribers = ["com.apple.modelcatalog.daemon", "com.apple.writingtoolsd", "com.apple.mail.intelligence", "com.apple.siri.inference",
                       "com.apple.photos.memories", "com.apple.notifications.intelligence"]
        for suffix, every in (("ModelCatalog", 1), ("Availability", 3), ("UnifiedAssetFramework", 2), ("SoftwareUpdateController", 14)):
            rows = []
            for day in range(60, -1, -every):
                for _ in range(rng.randint(1, 3)):
                    use_case, _, _, adapter = rng.choice(_AI_USE_CASES)
                    when = self.t(day, rng.randint(1, 23), rng.randrange(60))
                    rows.append((when, pb.message([(1, [(1, lib.unix(when)), (3, [(1, use_case)]), (4, _AI_BASE_MODEL), (4, f"com.apple.fm.language.instruct_3b.{adapter}"),
                                                        (5, "LanguageModel"), (5, "Adapter"), (7, self.mac.os_build), (8, f"{use_case}.default"), (9, rng.choice(subscribers))])])))
            self.emit("AppleIntelligence.Reporting.AssetDeliveryLog." + suffix, rows)
        self.emit("ModelCatalog.Subscriptions.Decisions", [
            (self.t(day, rng.randint(1, 23), rng.randrange(60)), pb.message([(1, rng.choice(("boot", "assetUpdate", "settingsChange", "periodic"))),
                                                                            (2, [(1, [(1, u)]) for u, _, _, _ in rng.sample(_AI_USE_CASES, rng.randint(2, 5))])]))
            for day in range(60, -1, -2)])

    # -- Lighthouse ledger -----------------------------------------------------------------

    def ledger_streams(self) -> None:
        rng = self.rng
        status, errors, custom, telemetry, device, trial, runtime, plugin, dedisco = [], [], [], [], [], [], [], [], []
        for day in range(60, -1, -1):
            for task, per_week, failure in _LEDGER_TASKS:
                if rng.random() >= per_week / 7:
                    continue
                when = self.t(day, rng.choice((1, 2, 3, 4, 13, 23)), rng.randrange(60))
                run = self.uuid()
                trigger = rng.choice(("Scheduled", "Scheduled", "Push"))
                status.append((when, pb.message([(1, run), (2, task), (3, "Started"), (4, trigger)])))
                custom.append((self.plus(when, 2), pb.message([(1, run), (2, task), (3, "Begin")])))
                finish = self.plus(when, rng.randint(4, 240))
                outcome = "Failed" if rng.random() < failure else ("Deferred" if rng.random() < 0.06 else "Completed")
                status.append((finish, pb.message([(1, run), (2, task), (3, outcome), (4, trigger)])))
                custom.append((finish, pb.message([(1, run), (2, task), (3, "End")])))
                if outcome == "Failed":
                    errors.append((finish, pb.message([(1, run), (2, task), (3, rng.choice(("Recipe download timed out", "Insufficient battery", "Asset not available", "Deadline exceeded")))])))
                telemetry.append((finish, pb.message([(1, run), (2, lib.unix(when)), (3, lib.unix(finish)), (4, task), (5, outcome), (6, lib.unix(finish))])))
                if "mlhost" in task:
                    runtime.append((finish, pb.message([(1, task), (2, round((finish - when).total_seconds(), 1)), (3, rng.randint(20, 400))])))
                    plugin.append((when, pb.message([(1, task), (2, "pluginLoaded")])))
                if "dedisco" in task or "fedstats" in task:
                    dedisco.append((finish, pb.message([(1, task), (2, rng.randint(1, 30)), (3, round(rng.uniform(0.5, 8), 2))])))
            begin = self.t(day, 0, 0)
            device.append((self.t(day, 23, 58), pb.message([(1, self.uuid()), (2, lib.unix(begin)), (3, lib.unix(self.plus(begin, DAY)))])))
            if day % 2 == 0:
                trial.append((self.t(day, 5, rng.randrange(60)), pb.message([(1, rng.choice(("rolloutActivated", "experimentAllocated", "factorPackUpdated"))), (2, "NS-" + lib.hex_string(rng, 6).upper())])))
        self.emit("Lighthouse.Ledger.TaskStatus", status)
        self.emit("Lighthouse.Ledger.TaskError", errors)
        self.emit("Lighthouse.Ledger.TaskCustomEvent", custom)
        self.emit("Lighthouse.Ledger.TaskTelemetry", telemetry)
        self.emit("Lighthouse.Ledger.DeviceTelemetry", device)
        self.emit("Lighthouse.Ledger.TrialdEvent", trial)
        self.emit("Lighthouse.Ledger.MlruntimedEvent", runtime)
        self.emit("Lighthouse.Ledger.LighthousePluginEvent", plugin)
        self.emit("Lighthouse.Ledger.DediscoPrivacyEvent", dedisco)

    def empty_streams(self) -> None:
        for name in _EMPTY_STREAMS:
            if name not in self.foreign:
                lib.ensure_dir(lib.biome_stream_dir(self.root, name) / "local")

    # -- Duet Expert (proactive suggestions) -------------------------------------------------

    def duet_expert_streams(self) -> None:
        rng, p = self.rng, self.p
        models = ["appPredictions", "actionPredictions", "shortcutPredictions", "contactPredictions", "heroAppPredictions"]
        surfaces = ["blendingHomeScreen", "blendingSpotlight", "blendingUIHomeScreen", "blendingUISpotlight"]
        client, cache, context, feedback, erm, spotlight, launches, heuristics, notifications, suggestion, location = ([] for _ in range(11))
        blending: dict[str, list] = {s: [] for s in surfaces}
        for day in range(28, -1, -1):
            for hour in range(7, 23, 2):
                when = self.t(day, hour, rng.randrange(60))
                apps = [p.weighted_app(rng, "mac").bundle_id for _ in range(4)]
                model = rng.choice(models)
                client.append((when, pb.message([(1, model), (2, lib.cocoa(when))] + [(3, [(1, a), (2, round(rng.random(), 4))]) for a in apps])))
                cache.append((when, pb.message([(1, model), (2, lib.cocoa(when)), (3, len(apps))])))
                context.append((when, pb.message([(1, lib.cocoa(when)), (2, self.weekday(day)), (3, hour), (4, apps[0]), (5, rng.random() < 0.6)])))
                for surface in surfaces:
                    if rng.random() < (0.9 if "UI" not in surface else 0.4):
                        blending[surface].append((self.plus(when, 1), pb.message([(1, self.uuid()), (2, lib.cocoa(when))] + [(3, [(1, a), (2, model)]) for a in apps[:3]])))
                if rng.random() < 0.35:
                    feedback.append((self.plus(when, 30), pb.message([(1, apps[0]), (2, rng.choice(("shown", "engaged", "dismissed"))), (3, self.uuid())])))
                    erm.append((self.plus(when, 31), pb.message([(1, apps[0]), (2, rng.choice((1, 1, 2, 3))), (3, lib.cocoa(when))])))
            for _ in range(rng.randint(1, 5)):
                when = self.t(day, rng.randint(8, 21), rng.randrange(60))
                spotlight.append((when, pb.message([(1, p.weighted_app(rng, "mac").bundle_id), (2, rng.randint(1, 8)), (3, lib.cocoa(when)), (4, self.uuid())])))
            if self.weekday(day) in (1, 3):
                when = self.t(day, 18, 6)
                heuristics.append((when, pb.message([(1, "headphonesConnected"), (2, "com.apple.Music"), (3, lib.cocoa(when))])))
            when = self.t(day, 8, rng.randrange(60))
            location.append((when, pb.message([(1, lib.cocoa(when)), (2, "home" if self.weekday(day) > 4 else "work"), (3, round(rng.uniform(20, 120), 1))])))
        for start, length, bundle in self.sessions["mac"]:
            if self.day_of(start) <= 14:
                launches.append((start, pb.message([(1, bundle), (2, lib.cocoa(start)), (3, "work" if 9 <= (start + self.tz).hour < 18 and self.weekday(self.day_of(start)) < 5 else "personal")])))
        for when, key, bundle, ident, label in self.notifications:
            if key == "mac" and self.day_of(when) <= 14:
                notifications.append((when, pb.message([(1, bundle), (2, ident), (3, label), (4, lib.cocoa(when))])))
                if label == "Dismiss" and rng.random() < 0.1:
                    suggestion.append((self.plus(when, 5), pb.message([(1, bundle), (2, rng.choice(("sendToDigest", "muteThread", "turnOffNotifications")))])))
        for name, rows in (("clientModel", client), ("lightweightClientModelCacheUpdates", cache), ("predictionContext", context),
                           ("proactiveSuggestionUIFeedbackResults", feedback), ("ERM", erm), ("spotlightUI", spotlight), ("appLaunchInferredMode", launches),
                           ("contextHeuristics", heuristics), ("userNotificationEvents", notifications), ("notificationSuggestion", suggestion), ("location", location)):
            self.emit_duet(name, rows)
        for surface, rows in blending.items():
            self.emit_duet(surface, rows)

    # -- linkd App Intents transcripts ---------------------------------------------------------

    def linkd_transcripts(self) -> None:
        data = lib.daemon_container(self.root, "com.apple.linkd", self.rng)
        transcripts = data / "ActionTranscript"
        if transcripts.exists():
            return                                             # another module's
        samples = {"name": "Packing list — Queenstown", "folder": "Notes", "title": "Call Mum", "list": "Home", "shortcut": "Morning briefing",
                   "item": "Low Cloud", "to": self.p.person("partner").email, "subject": "Friday", "focus": "Work", "state": True,
                   "url": "https://www.example.org/", "calendar": "Home", "query": "Mount Victoria", "board": "Ferry app — ideas",
                   "location": self.p.place("home").city, "target": "Flat inspection", "shuffle": False}
        per_app: dict[str, list] = {}
        for when, app, action, parameters, label, ident in self.executions:
            record = lib.ArchiveObject("LNTranscriptActionRecord", {
                "bundleIdentifier": app, "clientLabel": label, "executionDate": when, "executionUUID": ident, "source": 2,
                "resolvedAction": lib.ArchiveObject("LNAction", {
                    "identifier": action,
                    "parameters": [lib.ArchiveObject("LNProperty", {"identifier": name, "value": samples.get(name, "")}) for name in parameters],
                }),
            })
            per_app.setdefault(app, []).append((when, lib.keyed_archive(record)))
        everything = sorted((r for rows in per_app.values() for r in rows), key=lambda r: r[0])
        for app, rows in per_app.items():
            lib.write_stream(transcripts / app, rows)
        if everything:
            lib.write_stream(transcripts / "System", everything)

    # -- knowledgeC ------------------------------------------------------------------------

    def knowledge_db(self) -> None:
        rng, p = self.rng, self.p
        events: list[dict] = []     # stream, start, end, value / integer, bundle, device, meta

        def add(stream, start, end, value=None, integer=None, bundle=None, device=None, meta=None):
            if self.past(end):
                events.append({"stream": stream, "start": start, "end": end, "value": value, "integer": integer, "bundle": bundle,
                               "device": device.identifier if device is not None else None, "meta": meta})

        trusted = {"Z_DKDIGITALHEALTHMETADATAKEY__ISUSAGETRUSTED": 1, "Z_DKDIGITALHEALTHMETADATAKEY__USAGETYPE": 0}
        for key, device, window in (("mac", None, 30), ("iphone", self.iphone, 14)):
            for start, length, bundle in self.sessions[key]:
                if self.day_of(start) <= window:
                    add("/app/usage", start, self.plus(start, length), value=bundle, bundle=None, device=device, meta=trusted)
        for when, stay, url, domain, title in self.visits:
            if self.day_of(when) <= 30:
                add("/app/webUsage", when, self.plus(when, stay), value="com.apple.Safari", meta={**trusted, "Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN": domain})
                add("/safari/history", when, when, value=url, bundle="com.apple.Safari", meta={"Z_DKSAFARIHISTORYMETADATAKEY__TITLE": title})
        for when, dev, app, title, artist, album, seconds, kind, route, state in self.plays:
            if self.day_of(when) <= 30 and dev in ("mac", "iphone"):
                device = None if dev == "mac" else self.iphone
                add("/media/nowPlaying", when, self.plus(when, seconds if state == 1 else 1), value=title, bundle=app, device=device, meta={
                    "Z_DKNOWPLAYINGMETADATAKEY__TITLE": title, "Z_DKNOWPLAYINGMETADATAKEY__ARTIST": artist, "Z_DKNOWPLAYINGMETADATAKEY__ALBUM": album,
                    "Z_DKNOWPLAYINGMETADATAKEY__GENRE": next((t.genre for t in p.tracks if t.title == title), "Podcast"),
                    "Z_DKNOWPLAYINGMETADATAKEY__MEDIATYPE": kind, "Z_DKNOWPLAYINGMETADATAKEY__DURATION": float(seconds),
                    "Z_DKNOWPLAYINGMETADATAKEY__PLAYING": 1 if state == 1 else 0, "Z_DKNOWPLAYINGMETADATAKEY__ISAIRPLAYVIDEO": 0})
                if state == 1 and rng.random() < 0.2:
                    add("/app/mediaUsage", when, self.plus(when, seconds), value=app, device=device, meta=trusted)
        for when, key, bundle, ident, label in self.notifications:
            if self.day_of(when) <= 21:
                add("/notification/usage", when, when, value=label, bundle=bundle, device=None if key == "mac" else self.iphone,
                    meta={"Z_DKNOTIFICATIONUSAGEMETADATAKEY__BUNDLEID": bundle, "Z_DKNOTIFICATIONUSAGEMETADATAKEY__IDENTIFIER": ident})
        for when, person, app, direction, dev in self.msgs:
            if self.day_of(when) <= 30 and dev == "iphone":
                add("/app/intents", when, when, value="INSendMessageIntent", bundle=app, device=self.iphone, meta=self.intent_meta(when, "INSendMessageIntent", "Send", direction, person))
        for when, person, app, direction, dev, seconds in self.calls:
            if self.day_of(when) <= 30 and dev == "iphone":
                add("/app/intents", when, self.plus(when, seconds), value="INStartCallIntent", bundle=app, device=self.iphone, meta=self.intent_meta(when, "INStartCallIntent", "Start", direction, person))
        for start, end, (name, address, vendor, product, kind, apple_audio) in self.bluetooth_periods:
            if self.day_of(start) <= 30:
                add("/bluetooth/isConnected", start, end, integer=1, meta={
                    "Z_DKBLUETOOTHMETADATAKEY__NAME": name, "Z_DKBLUETOOTHMETADATAKEY__ADDRESS": address, "Z_DKBLUETOOTHMETADATAKEY__DEVICETYPE": kind,
                    "Z_DKBLUETOOTHMETADATAKEY__PRODUCTID": product, "Z_DKBLUETOOTHMETADATAKEY__ISAPPLEAUDIODEVICE": apple_audio})
                if apple_audio:
                    add("/audio/outputRoute", start, end, value="Bluetooth", meta={"Z_DKAUDIOMETADATAKEY__PORTNAME": name, "Z_DKAUDIOMETADATAKEY__PORTTYPE": "BluetoothA2DPOutput",
                                                                                 "Z_DKAUDIOMETADATAKEY__IDENTIFIER": address + "-tacl", "Z_DKAUDIOMETADATAKEY__ROUTECHANGEREASON": 1})
        for start, end, ssid in self.wifi_periods:
            if self.day_of(start) <= 30:
                add("/wifi/connection", start, end, value=ssid)
        level = 82
        for start, end, place in self.work_blocks:
            if self.day_of(start) > 30:
                continue
            add("/display/isBacklit", start, end, integer=1)
            plugged = place != "cafe"
            add("/device/isPluggedIn", start, end, integer=1 if plugged else 0, meta={"Z_DKDEVICEISPLUGGEDINMETADATAKEY__ADAPTERISWIRELESS": 0} if plugged else None)
            cursor = start
            while cursor < end:
                level = min(100, level + rng.randint(2, 7)) if plugged else max(9, level - rng.randint(2, 6))
                add("/device/batteryPercentage", cursor, self.plus(cursor, 900), integer=level,
                    meta={"Z_DKDEVICEBATTERYPERCENTAGEMETADATAKEY__FULLYCHARGED": 1 if level == 100 else 0})
                cursor = self.plus(cursor, 900)
        for day in range(30, 0, -1):
            add("/user/isSleeping", self.t(day, 23, rng.randint(0, 40)), self.t(day - 1, 6, rng.randint(30, 55)), integer=1, device=self.iphone)
        for start, length, bundle in self.sessions["mac"]:
            if self.day_of(start) <= 30 and bundle in ("com.apple.Notes", "com.apple.iCal", "com.apple.Maps", "com.apple.mail") and rng.random() < 0.25:
                title = rng.choice(_NOTES)[0] if bundle == "com.apple.Notes" else {"com.apple.iCal": "Design crit", "com.apple.Maps": p.place("te_papa").name}.get(bundle, "Inbox")
                add("/app/activity", start, start, value=bundle, bundle=bundle, meta={
                    "Z_DKAPPLICATIONACTIVITYMETADATAKEY__ACTIVITYTYPE": bundle + ".activity", "Z_DKAPPLICATIONACTIVITYMETADATAKEY__TITLE": title,
                    "Z_DKAPPLICATIONACTIVITYMETADATAKEY__USERACTIVITYUUID": self.uuid(), "Z_DKAPPLICATIONACTIVITYMETADATAKEY__ISELIGIBLEFORPREDICTION": 1,
                    "Z_DKAPPLICATIONACTIVITYMETADATAKEY__ISPUBLICLYINDEXABLE": 0, "Z_DKAPPLICATIONACTIVITYMETADATAKEY__EXPIRATIONDATE": lib.cocoa(self.plus(start, 28 * DAY))})
        for day, bundle in ((112, "com.figma.Desktop"), (97, "notion.id"), (64, "us.zoom.xos"), (23, "com.spotify.client")):
            app = p.app(bundle)
            add("/app/install", self.t(day, 19, 12), self.t(day, 19, 12), value=bundle, meta={
                "Z_DKAPPINSTALLMETADATAKEY__ISINSTALL": 1, "Z_DKAPPINSTALLMETADATAKEY__TITLE": app.name, "Z_DKAPPINSTALLMETADATAKEY__PRIMARYCATEGORY": app.category.capitalize()})
        for topic in p.topics:
            for _ in range(int(2 + topic.weight * 4)):
                when = self.t(rng.randint(0, 80), rng.randint(8, 22), rng.randrange(60))
                add("/portrait/topic", when, when, value=topic.name, bundle=rng.choice(("com.apple.Safari", "com.apple.mail", "com.apple.Notes")), meta={
                    "Z_CDPORTRAITMETADATAKEY__SCORE": round(rng.uniform(0.2, 1.0) * topic.weight / 3, 4), "Z_CDPORTRAITMETADATAKEY__DECAYRATE": 0.05,
                    "Z_CDPORTRAITMETADATAKEY__ALGORITHM": rng.choice((1, 3, 7)), "Z_CDPORTRAITMETADATAKEY__OSBUILD": self.mac.os_build})
        for device in p.remote_devices:                       # sync bookkeeping, one pair of streams per peer
            for stream in ("/knowledge-sync-addition-window/", "/knowledge-sync-deletion-bookmark/"):
                for day in range(6, -1, -1):
                    add(stream + device.identifier, self.t(day, 3, 0), self.t(day, 3, 0), integer=0)
        self.write_knowledge(events)

    def intent_meta(self, when, intent_class, verb, direction, person: Person) -> dict:
        interaction = lib.keyed_archive(lib.ArchiveObject("INInteraction", {
            "intentClass": intent_class, "dateInterval": when,
            "person": lib.ArchiveObject("INPerson", {"displayName": person.full_name, "handle": person.handle, "contactIdentifier": person.contact_id})}))
        return {"Z_DKINTENTMETADATAKEY__INTENTCLASS": intent_class, "Z_DKINTENTMETADATAKEY__INTENTVERB": verb,
                "Z_DKINTENTMETADATAKEY__DIRECTION": 3 - direction, "Z_DKINTENTMETADATAKEY__INTENTHANDLINGSTATUS": 3,
                "Z_DKINTENTMETADATAKEY__INTENTTYPE": 2 if "Call" in intent_class else 1, "Z_DKINTENTMETADATAKEY__DONATEDBYSIRI": 0,
                "Z_DKINTENTMETADATAKEY__INTERACTIONIDENTIFIER": self.uuid(), "Z_DKINTENTMETADATAKEY__SERIALIZEDINTERACTION": interaction}

    def write_knowledge(self, events: list[dict]) -> None:
        rng, p = self.rng, self.p
        path = lib.library(self.root, "Application Support/Knowledge/knowledgeC.db")
        fresh = not path.exists()
        if fresh:
            with lib.sqlite_db(path, _KNOWLEDGE_DDL) as con:
                lib.coredata_tables(con, _KNOWLEDGE_ENTITIES, rng)
                con.execute("UPDATE Z_PRIMARYKEY SET Z_SUPER = 9 WHERE Z_ENT BETWEEN 10 AND 13")
        con = sqlite3.connect(str(path), isolation_level=None)
        try:
            con.execute("PRAGMA journal_mode=DELETE")
            con.execute("BEGIN")
            tables = {row[0] for row in con.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
            if "ZOBJECT" not in tables:
                con.execute("ROLLBACK")
                return

            def columns(table):
                return {row[1] for row in con.execute(f"PRAGMA table_info({table})")} if table in tables else set()

            def next_pk(table):
                return (con.execute(f"SELECT max(Z_PK) FROM {table}").fetchone()[0] or 0) + 1

            def put(table, available, row):
                row = {k: v for k, v in row.items() if k in available}
                names = ", ".join(row)
                con.execute(f"INSERT INTO {table} ({names}) VALUES ({', '.join('?' for _ in row)})", list(row.values()))

            object_cols, source_cols, meta_cols, peer_cols = columns("ZOBJECT"), columns("ZSOURCE"), columns("ZSTRUCTUREDMETADATA"), columns("ZSYNCPEER")
            present = {row[0] for row in con.execute("SELECT DISTINCT ZSTREAMNAME FROM ZOBJECT")}
            events = [e for e in events if e["stream"] not in present]      # streams an earlier module wrote stay theirs
            events.sort(key=lambda e: e["start"])

            object_pk, source_pk, meta_pk = next_pk("ZOBJECT"), (next_pk("ZSOURCE") if source_cols else 1), (next_pk("ZSTRUCTUREDMETADATA") if meta_cols else 1)
            sources: dict[tuple, int] = {}
            metas: dict[tuple, int] = {}
            for event in events:
                source_id = None
                if source_cols and (event["bundle"] or event["device"]):
                    key = (event["bundle"], event["device"])
                    if key not in sources:
                        sources[key] = source_pk
                        put("ZSOURCE", source_cols, {"Z_PK": source_pk, "Z_ENT": 14, "Z_OPT": 1, "ZUSERID": 501, "ZBUNDLEID": event["bundle"],
                                                     "ZDEVICEID": event["device"], "ZSOURCEID": "intents" if event["stream"] == "/app/intents" else None})
                        source_pk += 1
                    source_id = sources[key]
                meta_id = None
                if meta_cols and event["meta"]:
                    usable = {k: v for k, v in event["meta"].items() if k in meta_cols}
                    key = tuple(sorted((k, repr(v)) for k, v in usable.items()))
                    if usable and key not in metas:
                        metas[key] = meta_pk
                        put("ZSTRUCTUREDMETADATA", meta_cols, {"Z_PK": meta_pk, "Z_ENT": 15, "Z_OPT": 1, "ZMETADATAHASH": lib.hex_string(rng, 32), **usable})
                        meta_pk += 1
                    meta_id = metas.get(key)
                start, end = event["start"], event["end"]
                local_start, local_end = start + self.tz, end + self.tz
                created = lib.cocoa(self.plus(end, rng.uniform(0.1, 30)))
                put("ZOBJECT", object_cols, {
                    "Z_PK": object_pk, "Z_ENT": 11, "Z_OPT": 1, "ZUUIDHASH": rng.getrandbits(62), "ZSOURCE": source_id, "ZCOMPATIBILITYVERSION": 0,
                    "ZENDDAYOFWEEK": (local_end.weekday() + 1) % 7 + 1, "ZENDSECONDOFDAY": local_end.hour * 3600 + local_end.minute * 60 + local_end.second,
                    "ZHASCUSTOMMETADATA": 0, "ZHASSTRUCTUREDMETADATA": 1 if meta_id else 0, "ZSECONDSFROMGMT": self.gmt_seconds,
                    "ZSHOULDSYNC": 1 if event["device"] else 0, "ZSTARTDAYOFWEEK": (local_start.weekday() + 1) % 7 + 1,
                    "ZSTARTSECONDOFDAY": local_start.hour * 3600 + local_start.minute * 60 + local_start.second,
                    "ZVALUECLASS": 1 if event["value"] is not None else 0, "ZVALUEINTEGER": event["integer"] if event["integer"] is not None else 0,
                    "ZVALUETYPECODE": rng.getrandbits(48), "ZSTRUCTUREDMETADATA": meta_id, "ZCREATIONDATE": created, "ZLOCALCREATIONDATE": created,
                    "ZCONFIDENCE": 1.0, "ZENDDATE": lib.cocoa(end), "ZSTARTDATE": lib.cocoa(start), "ZVALUEDOUBLE": float(event["integer"] or 0),
                    "ZUUID": self.uuid(), "ZSTREAMNAME": event["stream"], "ZVALUESTRING": event["value"]})
                object_pk += 1
            if peer_cols and not con.execute("SELECT count(*) FROM ZSYNCPEER").fetchone()[0]:
                for index, device in enumerate(p.remote_devices, start=1):
                    put("ZSYNCPEER", peer_cols, {"Z_PK": index, "Z_ENT": 16, "Z_OPT": 3, "ZLASTSEENDATE": lib.cocoa(self.plus(self.now, -rng.randint(300, 9000))),
                                                 "ZDEVICEID": device.identifier, "ZMODEL": device.model, "ZVERSION": device.os_version, "ZUUID": lib.uuid_obj(rng).bytes})
            if "Z_PRIMARYKEY" in tables:
                for name, table in (("Object", "ZOBJECT"), ("Event", "ZOBJECT"), ("Source", "ZSOURCE"), ("StructuredMetadata", "ZSTRUCTUREDMETADATA"), ("SyncPeer", "ZSYNCPEER")):
                    if table in tables:
                        con.execute(f"UPDATE Z_PRIMARYKEY SET Z_MAX = (SELECT ifnull(max(Z_PK), 0) FROM {table}) WHERE Z_NAME = ?", (name,))
            con.execute("COMMIT")
        finally:
            con.close()

    # -- Biome sync.db ---------------------------------------------------------------------

    def sync_db(self) -> None:
        """Fills sync.db table by table: a table that already has rows (another module's)
        keeps them, and what is added agrees with them (same sessions, same stream names)."""
        rng, p = self.rng, self.p
        path = lib.library(self.root, "Biome/sync/sync.db")
        self.sync_is_mine = not path.exists()
        if self.sync_is_mine:
            lib.write_biome_sync_db(self.root, p.devices, self.now, rng)
        con = sqlite3.connect(str(path), isolation_level=None)
        try:
            con.execute("PRAGMA journal_mode=DELETE")
            con.execute("BEGIN")
            for statement in lib.split_sql(_SYNC_DDL):
                con.execute(statement)
            if not con.execute("SELECT count(*) FROM CKAtom").fetchone()[0]:      # otherwise this generator already ran
                self.fill_sync(con)
            con.execute("COMMIT")
        except BaseException:
            if con.in_transaction:
                con.execute("ROLLBACK")
            raise
        finally:
            con.close()

    def fill_sync(self, con: sqlite3.Connection) -> None:
        rng, p = self.rng, self.p
        known = {d.identifier: d for d in p.devices}
        now = lib.cocoa(self.now)
        atom_cutoff = now - 45 * DAY
        merge_cutoff = now - 21 * DAY
        peers = list(p.remote_devices)

        def empty(table: str) -> bool:
            return con.execute(f"SELECT count(*) FROM {table}").fetchone()[0] == 0

        # Sessions of the last three weeks: a few per waking hour while a device is around.
        sessions = []            # (start cocoa, end cocoa, id, peer or None)
        if empty("SyncSessionLog"):
            cursor, previous = merge_cutoff, None
            while True:
                cursor += rng.randint(900, 9000)
                if cursor >= now - 120:
                    break
                hour = ((cursor + lib.COCOA_EPOCH + self.gmt_seconds) % DAY) // 3600
                if hour < 7 and rng.random() < 0.85:
                    continue
                peer = rng.choices(peers, weights=[8 if d.key == "iphone" else 2 for d in peers])[0]
                session = (cursor, cursor + rng.uniform(0.2, 6.5), self.uuid(), peer)
                sessions.append(session)
                con.execute("INSERT INTO SyncSessionLog VALUES (?, ?, ?, ?, ?, ?, ?)",
                            (session[2], session[0], session[1], rng.choice((2, 2, 3)), rng.choice((1, 2, 2, 3, 6)), rng.random() < 0.5,
                             None if previous is None else cursor - previous))
                previous = cursor
            own_sessions = True
        else:
            sessions = [(start, end if end is not None else start, ident, None) for ident, start, end in
                        con.execute("SELECT session_id, start_timestamp, end_timestamp FROM SyncSessionLog WHERE start_timestamp IS NOT NULL ORDER BY start_timestamp")]
            own_sessions = False
        starts = [s[0] for s in sessions]
        session_bytes: dict[Any, int] = {}

        # CRDTLocation.day is Cocoa seconds at midnight UTC. Rows that carry a plain day
        # number instead (days since 1970) are brought to that unit, or they would date to 2001.
        con.execute("UPDATE CRDTLocation SET day = day * 86400 - ? WHERE day BETWEEN 10000 AND 100000", (lib.COCOA_EPOCH,))
        locations = {(stream, site, day): ident for ident, stream, site, day in con.execute("SELECT id, stream, site, day FROM CRDTLocation")}
        location_id = max(locations.values(), default=0)
        add_records = empty("CKRecord")
        add_merged = empty("AtomMergedLog")

        # What is on disk decides what syncs: every stream with a remote folder.
        merged = []
        stream_ids: list[tuple[str, str]] = []
        for stream_dir in sorted(d for d in self.restricted.iterdir() if (d / "remote").is_dir()):
            sync_id = _SYNC_SHORT_NAMES.get(stream_dir.name) or self.uuid()
            stream_ids.append((stream_dir.name, sync_id))
            folders = [(self.mac.identifier, stream_dir / "local")] + [(d.name, d) for d in sorted((stream_dir / "remote").iterdir()) if d.is_dir()]
            for site, folder in folders:
                if not folder.is_dir():
                    continue
                clock = 0
                for segment in sorted(f for f in folder.iterdir() if f.is_file() and not f.name.startswith(".")):
                    for stamp, state, offset in _segment_index(segment.read_bytes()):
                        if stamp > now or stamp <= 0:
                            continue
                        day = int(stamp + lib.COCOA_EPOCH) // DAY * DAY - lib.COCOA_EPOCH
                        key = (sync_id, site, day)
                        if key not in locations:
                            location_id += 1
                            locations[key] = location_id
                            con.execute("INSERT INTO CRDTLocation VALUES (?, ?, ?, ?, ?)", (location_id, sync_id, site, day, 4 if stamp < atom_cutoff else 2))
                            if add_records and stamp >= atom_cutoff:
                                con.execute("INSERT INTO CKRecord VALUES (?, 1, ?, ?, ?, NULL, 0, ?, 0)",
                                            (location_id, self.blob(48), f"{site}-{day}", sync_id, rng.choice((1, 1, 2, 3))))
                        if stamp < atom_cutoff:
                            continue
                        clock += 1
                        con.execute("INSERT INTO CKAtom VALUES (?, ?, ?, 0, ?, ?, ?, NULL, NULL, NULL, NULL, 0, NULL, 1, NULL, NULL)",
                                    (sync_id, site, clock, locations[key], segment.name, offset))
                        if state != lib.SEGB_STATE_WRITTEN:
                            clock += 1
                            con.execute("INSERT INTO CKAtom VALUES (?, ?, ?, 2, ?, NULL, NULL, 0, ?, ?, ?, 0, ?, NULL, NULL, NULL)",
                                        (sync_id, site, clock, locations[key], site, clock - 1, locations[key], self.blob(8)))
                        if add_merged and site != self.mac.identifier and stamp >= merge_cutoff and starts:
                            index = bisect.bisect_left(starts, stamp)
                            if index < len(sessions):
                                session = sessions[index]
                                relay = self.iphone.identifier if known.get(site) is self.watch else site
                                merged.append((session[2], sync_id, 1 if rng.random() < 0.97 else 3, site, relay, session[1], stamp))
                                session_bytes[session[2]] = session_bytes.get(session[2], 0) + rng.randint(60, 420)
        merged.sort(key=lambda row: row[5])
        for session_id, sync_id, result, site, relay, synced_at, created in merged:
            con.execute("INSERT INTO AtomMergedLog VALUES (?, ?, ?, ?, ?, ?, ?, ?)", (session_id, 1, sync_id, result, site, relay, synced_at, created))
        if own_sessions and empty("SyncMessageLog"):
            for start, end, session_id, peer in sessions:
                total = session_bytes.get(session_id, 0)
                count = rng.randint(1, 3) + (1 if total > 4000 else 0)
                for index in range(count):
                    con.execute("INSERT INTO SyncMessageLog VALUES (?, ?, ?, ?, 1, ?, ?)",
                                (session_id, index + 1, start + (end - start) * (index + 1) / (count + 1), peer.identifier,
                                 index % 2 == 1, (total // count if total else rng.randint(0, 96))))
        if self.sync_is_mine and own_sessions:                  # peers last synced in their last session (Unix seconds)
            for peer in peers:
                ends = [end for _, end, _, who in sessions if who is peer]
                if ends:
                    con.execute("UPDATE DevicePeer SET last_sync_date = ? WHERE device_identifier = ?", (int(ends[-1] + lib.COCOA_EPOCH), peer.identifier))

        last = sessions[-1][1] if sessions else now - 600
        metadata = {"LastSyncDate": last, "LastSyncAttemptDate": last, "LastCloudKitSyncDate": now - rng.randint(1800, 20000),
                    "LastCloudKitAttemptDate": now - rng.randint(600, 1700), "LastVacuumDate": now - rng.randint(2, 6) * DAY,
                    "CKRecordBackfillCompleted_AppLaunch": 1}
        for name, sync_id in stream_ids:
            metadata[f"HighestPostedEventTimestamp_{self.mac.identifier}_{sync_id}"] = now - rng.randint(30, 4000)
        present = {row[0] for row in con.execute("SELECT key FROM Metadata")}
        for key, value in metadata.items():
            if key not in present:
                con.execute("INSERT INTO Metadata VALUES (?, ?)", (key, value))
        if empty("CKZone"):
            con.execute("INSERT INTO CKZone VALUES (?, ?, 0, NULL)", ("BiomeSync", self.uuid()))


def _segment_index(data: bytes) -> list[tuple[float, int, int]]:
    """(Cocoa timestamp, state, record offset) of every record of a SEGB v2 segment."""
    if data[:4] != b"SEGB" or len(data) < 32:
        return []
    count = struct.unpack_from("<I", data, 4)[0]
    out = []
    previous_end = 0
    for index in range(count):
        end, state, stamp = struct.unpack_from("<Iid", data, len(data) - 16 * (index + 1))
        out.append((stamp, state, 32 + ((previous_end + 3) & ~3)))
        previous_end = end
    return out
