"""Demo data for the Mail & Search Index module (`mailsearch`): the derived copies and
indexes of the persona's mail that `Sources/MailSearchModule` reads.

One invented mail corpus (about six and a half years of work threads at Kōwhai Labs,
family and friends, newsletters, bills, orders, travel, sign-in codes) is built once in
memory and then written into every store the way the system would have derived it:

* `~/Library/Biome/sets/Default/…/Database/Set.db` — the Cascade sets: mail message and
  attachment entities, the plain-text body cache, `Mail.ImportedAttachment` and its
  extracted text; reminders, contacts, Safari, Music, Find My and HomeKit entities;
  installed apps, shortcut phrases, and the (empty, as on a real Mac) extraction sets;
* `~/Library/Daemon Containers/<hybridsearchd>/Data/Library/HybridSearch` — the Kuzu
  file of the semantic index (`index/C/index.db` + `.wal`) and the collection bookmarks;
* `~/Library/Metadata/CoreSpotlight` — `DocumentProcessing/PipelineStorage/StateStore.db`
  and `CachedResultStore.db`, the completeness JSON, the knowledge graph
  (`SpotlightKnowledge/index.V2/KG/kg`), loose state files and opaque index files;
* `~/Library/Biome/streams/restricted` — `ProactiveHarvesting.Mail`,
  `TextUnderstanding.Output.Document`, `TextUnderstanding.Output.Event`,
  `TextUnderstanding.Deletions.Document`, `Mail.Search.Query`;
* `~/Library/Daemon Containers/<kvs>/Data/com.apple.kvs/*.sqlite` — the iCloud
  key-value cache.

Shared with other modules: the `com.apple.kvs` container (also read by `comms` and
`environment`). Its databases are created only if missing, and a store identifier that
already has keys in any of them is left alone — whoever runs first owns a store (`comms`
runs earlier and owns mail / calendar recents, VIPs, favourites and the block list; the
VIPs and block list here repeat its choices for a run with `--only mailsearch`;
`environment` runs later and replaces the Wi-Fi network keys with its own). The five
streams are written here first; `biome` leaves existing streams alone and adds the other
ProactiveHarvesting / TextUnderstanding / Mail.Search streams, `environment` appends its
own queries to `Mail.Search.Query`. Every other path above belongs to this generator.

Times: mail is scheduled with the persona's fixed UTC offset (`lib.Clock`); dates quoted
inside texts and the start of events use the real zone through `zoneinfo` when the system
has it, so that they agree with what the app displays in any season.

Format notes (from the readers in Sources/MailSearchModule and from the DDL / field
numbers / key names of the real stores, never from rows):

* Set.db: `content` (payload, de-duplicated by hash), `metacontent` (identifier protobuf),
  `metacontent_provenance` (the log tying both together; `deleted_run_length` 0 = live,
  dates in µs since 1970). Entity and text sets prefix every blob with `0x01` + LZFSE.
  The same `source_item_id_hash` links a message to its cached body text.
* The Kuzu file cannot be generated as a database. Like the reader, this generator only
  cares about the JSON payload each indexed item carries in the string pages: they are
  laid out between filler pages, and some are cut short the way a page boundary cuts them.
* LZFSE: `libcompression` (part of macOS, loaded through `ctypes`) when available, else
  the uncompressed-block stream of `lib.lzfse_stored`.

Invented where only the structure of the real value is known to this generator: the
`mailbox.*` / `imap://` mailbox strings, the entity identifier format, the prefix of the
body-text related id, `mailCategory` values, the attachment payload keys of the semantic
index (mirrored from the mail payload), the extraction kinds of extracted events, the
classification / rank words of the completeness report, all key-value store contents
beyond the documented envelopes, the framing between payloads in the Kuzu file, and
every number. All senders other than the persona's people are invented organisations on
example.com / .org / .net subdomains; IP addresses come from the documentation ranges.
"""

from __future__ import annotations

import datetime
import email.utils
import json
import pathlib
import random
import sqlite3
import struct
import uuid
from dataclasses import dataclass, field
from typing import Callable, Optional

from . import lib
from .lib import pb
from .persona import Persona, Person

UTC = datetime.timezone.utc
MONTH = 30.44                # days
SPAN_MONTHS = 78             # how far back the mail goes
WORK_MONTHS = 38             # since Robin joined Kōwhai Labs
HOME_MONTHS = 52             # since the move to the current flat

# ----------------------------------------------------------------------------------------
# DDL (copied from the stores' sqlite_master; schema only)
# ----------------------------------------------------------------------------------------

SET_DDL = """
CREATE TABLE "device" ("device_row_id" integer PRIMARY KEY, "device_uuid" blob NOT NULL, "ids_device_id" varchar NULLABLE, "device_platform" integer NOT NULL, "options" integer NOT NULL, "resource_generation" integer NOT NULL, "attestation_generation" integer NOT NULL, "delta_generation" integer NOT NULL, "expiration_date" integer NULLABLE);
CREATE INDEX "idx_device_options" ON "device" ("options","expiration_date");
CREATE INDEX "idx_device_uuid" ON "device" ("device_uuid","attestation_generation");
CREATE TABLE "content_provenance" ("device_row_id" integer NOT NULL, "content_hash" integer NULLABLE, "sequence_number" integer NOT NULL, "deleted_run_length" integer NOT NULL, "deleted_date" integer NULLABLE, FOREIGN KEY ("device_row_id") REFERENCES "device" ("device_row_id") ON UPDATE CASCADE ON DELETE CASCADE );
CREATE INDEX "idx_cp_content_hash" ON "content_provenance" ("content_hash","deleted_run_length","device_row_id");
CREATE INDEX "idx_cp_present_sequence_number" ON "content_provenance" ("device_row_id",("deleted_run_length" != 0),"sequence_number","deleted_run_length","content_hash");
CREATE TABLE "metacontent_provenance" ("device_row_id" integer NOT NULL, "source_item_id_hash" integer NULLABLE, "instance_hash" integer NULLABLE, "content_hash" integer NULLABLE, "sequence_number" integer NOT NULL, "deleted_run_length" integer NOT NULL, "written_date" integer NULLABLE, "deleted_date" integer NULLABLE, FOREIGN KEY ("device_row_id") REFERENCES "device" ("device_row_id") ON UPDATE CASCADE ON DELETE CASCADE );
CREATE INDEX "idx_mp_source_item_id_hash" ON "metacontent_provenance" ("source_item_id_hash","deleted_run_length");
CREATE INDEX "idx_mp_instance_hash" ON "metacontent_provenance" ("instance_hash","deleted_run_length");
CREATE INDEX "idx_mp_content_hash" ON "metacontent_provenance" ("content_hash","deleted_run_length");
CREATE INDEX "idx_mp_present_sequence_number" ON "metacontent_provenance" (("deleted_run_length" != 0),"sequence_number","deleted_run_length","content_hash");
CREATE INDEX "idx_mp_written_date" ON "metacontent_provenance" ("written_date","deleted_run_length" DESC);
CREATE TABLE "content" ("content_hash" integer NOT NULL, "content" blob NOT NULL, PRIMARY KEY ("content_hash") );
CREATE TABLE "metacontent" ("instance_hash" integer NOT NULL, "metacontent" blob NOT NULL, PRIMARY KEY ("instance_hash") );
CREATE TABLE "keyvalue" ("key" varchar PRIMARY KEY, "string_value" varchar NULLABLE, "integer_value" integer NULLABLE, "data_value" blob NULLABLE, CHECK ((CASE WHEN "string_value" IS NULL THEN 0 ELSE 1 END + CASE WHEN "integer_value" IS NULL THEN 0 ELSE 1 END + CASE WHEN "data_value" IS NULL THEN 0 ELSE 1 END) = 1));
CREATE TABLE "tombstone_count_bucket" ("device_row_id" integer NOT NULL REFERENCES "device"("device_row_id") ON DELETE CASCADE, "bucket_start" integer NOT NULL, "bucket_size" integer NOT NULL, "tombstone_count" integer NOT NULL, PRIMARY KEY ("device_row_id", "bucket_start", "bucket_size")) WITHOUT ROWID;
CREATE TABLE "metacontent_field" ("instance_hash" integer NOT NULL, "FB9FC" varchar NULLABLE, "FB9FD" real NULLABLE, "FB9FE" varchar NULLABLE, FOREIGN KEY ("instance_hash") REFERENCES "metacontent" ("instance_hash") ON UPDATE CASCADE ON DELETE CASCADE );
CREATE INDEX "idx_fieldinstance_hash" ON "metacontent_field" ("instance_hash");
"""

STATE_DDL = """
CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
CREATE TABLE "pipeline" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL UNIQUE, "currentProcessorVersion" INTEGER);
CREATE TABLE "item" ("identityID" BLOB PRIMARY KEY NOT NULL, "lookupID" BLOB NOT NULL UNIQUE, "source" INTEGER NOT NULL, "textContentHash" INTEGER, "priorityDate" INTEGER) WITHOUT ROWID;
CREATE TABLE "pipeline_item" ("pipeline" INTEGER NOT NULL REFERENCES "pipeline"("id"), "identityID" BLOB NOT NULL, "processedVersion" INTEGER, "hasResult" BOOLEAN, "itemHash" INTEGER NOT NULL, "errorDomain" TEXT, "errorCode" INTEGER, "processingTier" INTEGER NOT NULL DEFAULT 0, "deleteStatus" INTEGER, "processedDestinationId" INTEGER, "processedDestinationCookie" INTEGER, "priorityDate" INTEGER, "source" INTEGER, "errorCount" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ("pipeline", "identityID"), FOREIGN KEY ("identityID") REFERENCES "item"("identityID") ON DELETE CASCADE) WITHOUT ROWID;
CREATE TABLE "bookmark" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "source" INTEGER NOT NULL UNIQUE, "bookmark" BLOB NOT NULL, "needsReindex" INTEGER NOT NULL DEFAULT 0);
CREATE TABLE "rehydration" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "identityID" BLOB NOT NULL UNIQUE, "rehydrateRetryTime" INTEGER, "rehydrateTimes" INTEGER NOT NULL DEFAULT 0, "rehydrateStatus" INTEGER NOT NULL DEFAULT 0, FOREIGN KEY ("identityID") REFERENCES "item"("identityID") ON DELETE CASCADE);
CREATE TABLE "external_claim" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "identityID" BLOB NOT NULL UNIQUE, FOREIGN KEY ("identityID") REFERENCES "item"("identityID") ON DELETE CASCADE);
CREATE TABLE "metadata" ("key" TEXT PRIMARY KEY NOT NULL, "value" BLOB NOT NULL) WITHOUT ROWID;
CREATE INDEX "pipeline_item_identityID" ON "pipeline_item"("identityID", "deleteStatus");
CREATE TABLE "document_store_cache" ("lookupID" BLOB PRIMARY KEY NOT NULL, "instanceIdentifier" BLOB NOT NULL UNIQUE) WITHOUT ROWID;
CREATE TABLE "destination" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "pipeline" INTEGER NOT NULL REFERENCES "pipeline"("id"), "name" TEXT NOT NULL, "kind" TEXT NOT NULL, "currentCookie" INTEGER NOT NULL, UNIQUE ("pipeline", "name"));
CREATE INDEX "idx_pipeline_item_processedDestinationId" ON "pipeline_item"("processedDestinationId");
CREATE INDEX "idx_item_priorityDate" ON "item"("priorityDate");
CREATE INDEX "idx_pipeline_item_pipeline_deleteStatus_source" ON "pipeline_item"("pipeline", "deleteStatus", "source");
CREATE TABLE "redonation" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "identityID" BLOB NOT NULL UNIQUE, "retryTime" INTEGER, "attempts" INTEGER NOT NULL DEFAULT 0, "status" INTEGER NOT NULL DEFAULT 0, FOREIGN KEY ("identityID") REFERENCES "item"("identityID") ON DELETE CASCADE);
CREATE INDEX idx_redonation_retry ON redonation (retryTime, attempts);
"""

CACHE_DDL = """
CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
CREATE TABLE "pipeline" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL UNIQUE, "count" INTEGER NOT NULL DEFAULT 0);
CREATE TABLE "cached_result" ("pipeline" INTEGER NOT NULL REFERENCES "pipeline"("id"), "itemHash" INTEGER NOT NULL, "pipelineVersion" INTEGER NOT NULL, "hasResult" INTEGER NOT NULL, "lastAccessTime" INTEGER NOT NULL, PRIMARY KEY ("pipeline", "itemHash")) WITHOUT ROWID;
CREATE TABLE "cached_result_data" ("pipeline" INTEGER NOT NULL, "itemHash" INTEGER NOT NULL, "data" BLOB NOT NULL, PRIMARY KEY ("pipeline", "itemHash"), FOREIGN KEY ("pipeline", "itemHash") REFERENCES "cached_result"("pipeline", "itemHash") ON DELETE CASCADE) WITHOUT ROWID;
CREATE INDEX "cached_result_eviction" ON "cached_result"("pipeline", "lastAccessTime");
"""

KG_DDL = """
CREATE TABLE Label (identifier integer primary key autoincrement, name text, nodeIds blob, edgeIds blob);
CREATE TABLE GraphMetadata (metadataKey integer primary key autoincrement, value text);
CREATE TABLE Node (identifier integer primary key autoincrement, labels blob, edgesIn blob, edgesOut blob);
CREATE TABLE Edge (identifier integer primary key autoincrement, labels blob, sourceNodeId integer, targetNodeId integer);
CREATE INDEX Edge_source_idx on Edge (sourceNodeId);
CREATE INDEX Edge_target_idx on Edge (targetNodeId);
CREATE TABLE Attribute (identifier integer primary key autoincrement, name text);
CREATE TABLE NodeValue (elementId integer, attributeId integer, intValue integer, realValue real, stringValue text, dataType integer, primary key (elementId, attributeId));
CREATE INDEX NodeValue_intValue on NodeValue (attributeId, intValue) where intValue not null;
CREATE INDEX NodeValue_realValue on NodeValue (attributeId, realValue) where realValue not null;
CREATE INDEX NodeValue_stringValue on NodeValue (attributeId, stringValue) where stringValue not null;
CREATE TABLE EdgeValue (elementId integer, attributeId integer, intValue integer, realValue real, stringValue text, dataType integer, primary key (elementId, attributeId));
CREATE INDEX EdgeValue_intValue on EdgeValue (attributeId, intValue) where intValue not null;
CREATE INDEX EdgeValue_realValue on EdgeValue (attributeId, realValue) where realValue not null;
CREATE INDEX EdgeValue_stringValue on EdgeValue (attributeId, stringValue) where stringValue not null;
CREATE TABLE TransactionLog (identifier integer primary key autoincrement, nodeIdsInserted blob, edgeIdsInserted blob, nodeIdsUpdated blob, edgeIdsUpdated blob, nodeIdsDeleted blob, edgeIdsDeleted blob);
CREATE TABLE ClientLog (clientId integer primary key, transactionId integer);
CREATE TABLE TombstoneNode (identifier integer primary key autoincrement, labels blob, edgesIn blob, edgesOut blob);
CREATE TABLE TombstoneEdge (identifier integer primary key autoincrement, labels blob, sourceNodeId integer, targetNodeId integer);
CREATE TABLE TombstoneNodeValue (elementId integer, attributeId integer, intValue integer, realValue real, stringValue text, dataType integer, primary key (elementId, attributeId));
CREATE TABLE TombstoneEdgeValue (elementId integer, attributeId integer, intValue integer, realValue real, stringValue text, dataType integer, primary key (elementId, attributeId));
"""

# CoreData store of the key-value daemon. The real file also has triggers that call
# CoreData-internal SQL functions; they cannot exist outside CoreData and are left out.
KVS_DDL = """
CREATE TABLE ZSYDMANAGEDDATABASE ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDIDMIGRATEFROMPLISTS INTEGER, ZFAILEDMIGRATIONCOUNT INTEGER, ZHASPERFORMEDONETIMEDATASEPARATEDLOCALDATARESET INTEGER, ZACACCOUNTIDENTIFIER VARCHAR, ZSYNCENGINEMETADATA BLOB, ZSYNCENGINESTATESERIALIZATION BLOB );
CREATE TABLE ZSYDMANAGEDKEYVALUE ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZPLISTDATALENGTH INTEGER, ZSTORE INTEGER, ZVALUEMODIFICATIONDATE TIMESTAMP, ZKEY VARCHAR, ZRECORDNAME VARCHAR, ZPLISTDATAVALUE BLOB, ZSERVERSYSTEMFIELDSRECORDDATA BLOB );
CREATE TABLE ZSYDMANAGEDSTORE ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZTOTALDATALENGTH INTEGER, ZDATABASE INTEGER, ZIDENTIFIER VARCHAR, ZSYNCANCHORSERVERSYSTEMFIELDSRECORDDATA BLOB );
CREATE INDEX ZSYDMANAGEDKEYVALUE_ZSTORE_INDEX ON ZSYDMANAGEDKEYVALUE (ZSTORE);
CREATE INDEX Z_SYDManagedKeyValue_key ON ZSYDMANAGEDKEYVALUE (ZKEY COLLATE BINARY ASC);
CREATE INDEX Z_SYDManagedKeyValue_recordName ON ZSYDMANAGEDKEYVALUE (ZRECORDNAME COLLATE BINARY ASC);
CREATE INDEX ZSYDMANAGEDSTORE_ZDATABASE_INDEX ON ZSYDMANAGEDSTORE (ZDATABASE);
CREATE INDEX Z_SYDManagedStore_identifier ON ZSYDMANAGEDSTORE (ZIDENTIFIER COLLATE BINARY ASC);
"""

PIPELINES = [  # name, currentProcessorVersion — the pipelines the system defines
    ("Embedding", None), ("FullEmbedding", None), ("GLPEmbedding", 655362), ("GLPIndexing", 2),
    ("GLPMailAttachments", 655362), ("Keyphrase", None), ("LSSR5EventsandordersBackground", None),
    ("LSSR5EventsandordersUrgent", 1), ("LSSR5IdentificationdocumentsBackground", 2),
    ("LSSR5SmartrepliesBackground", 1), ("LSSR5CarkeydataBackground", 1), ("Migration", None),
]

COLLECTIONS = [  # collection bookmarks of the hybrid search index
    "Contacts", "DocumentProcessingTest", "GLPTest", "Mail", "MailAttachment", "SiriTranscript",
    "SiriTranscriptConversation", "TextUnderstandingDeliveryTracking", "TextUnderstandingEvent",
    "TextUnderstandingFlight", "TextUnderstandingHotelReservation", "TextUnderstandingIdentificationDocument",
    "TextUnderstandingRestaurantReservation", "WritingAssistantProfiles",
]

EMPTY_SETS = [
    "Calendar.Event", "Siri.Transcript.Conversation", "TextUnderstanding.Extracted.DeliveryTracking",
    "TextUnderstanding.Extracted.Event", "TextUnderstanding.Extracted.Flight",
    "TextUnderstanding.Extracted.HotelReservation", "TextUnderstanding.Extracted.IdentificationDocument",
    "TextUnderstanding.Extracted.Location", "TextUnderstanding.Extracted.RestaurantReservation",
]

UTI = {
    "pdf": "com.adobe.pdf", "jpeg": "public.jpeg", "png": "public.png", "heic": "public.heic",
    "ics": "com.apple.ical.ics", "docx": "org.openxmlformats.wordprocessingml.document",
    "pptx": "org.openxmlformats.presentationml.presentation", "xlsx": "org.openxmlformats.spreadsheetml.sheet",
    "csv": "public.comma-separated-values-text", "zip": "public.zip-archive", "txt": "public.plain-text",
}

# ----------------------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------------------


def _lzfse_encoder() -> Callable[[bytes], bytes]:
    """LZFSE through the system's libcompression when it can be loaded (compressed blobs
    like the real stores have), otherwise the stored-block stream of `lib.lzfse_stored`."""
    try:
        import ctypes
        dylib = ctypes.CDLL("/usr/lib/libcompression.dylib")
        encode = dylib.compression_encode_buffer
        encode.restype = ctypes.c_size_t
        encode.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int]
    except (ImportError, OSError, AttributeError):
        return lib.lzfse_stored

    def compress(data: bytes) -> bytes:
        capacity = len(data) + 4096
        out = ctypes.create_string_buffer(capacity)
        written = encode(out, capacity, data, len(data), None, 0x801)      # COMPRESSION_LZFSE
        return out.raw[:written] if written else lib.lzfse_stored(data)

    return compress


_LZFSE = _lzfse_encoder()


def _blob(data: bytes) -> bytes:
    """A compressed Cascade content blob: flag byte 0x01 + LZFSE stream."""
    return b"\x01" + _LZFSE(data if data else b" ")


def _h64(rng: random.Random) -> int:
    return rng.getrandbits(64) - (1 << 63)


def _micros(when: datetime.datetime) -> int:
    return int(lib.unix(when) * 1_000_000)


def _opaque16(rng: random.Random) -> bytes:
    """16 identifier bytes that are not valid UTF-8 (so they never read as text)."""
    while True:
        data = lib.uuid_obj(rng).bytes
        try:
            data.decode("utf-8")
        except UnicodeDecodeError:
            return data


def _slug(text: str) -> str:
    table = str.maketrans("āēīōūĀĒĪŌŪé", "aeiouAEIOUe")
    return "".join(c for c in text.translate(table).lower() if c.isalnum())


def _money(value: float) -> str:
    return f"NZ${value:,.2f}"


@dataclass
class Account:
    key: str
    uuid: str
    address: str
    kind: str = "imap"


@dataclass
class Attachment:
    name: str
    text: str = ""             # extracted text ("" = none: images, archives)
    att_id: int = 0
    source_hash: int = 0

    @property
    def uti(self) -> str:
        return UTI.get(self.name.rsplit(".", 1)[-1].lower(), "public.data")


@dataclass
class Message:
    account: Account
    date: datetime.datetime
    subject: str
    sender: tuple                       # (name, address)
    to: list                            # [(name, address)]
    body: str
    kind: str                           # work / personal / newsletter / promo / bill / order / code / travel / notify / invite
    cc: list = field(default_factory=list)
    mailbox: str = "INBOX"
    reply_to: Optional["Message"] = None
    list_id: str = ""
    attachments: list = field(default_factory=list)
    two_factor: bool = False
    flagged: bool = False
    replied: bool = False
    read: bool = True
    event: Optional[dict] = None        # an event the text-understanding pipeline would find
    # assigned once the corpus is complete
    rowid: int = 0
    message_id: str = ""
    source_hash: int = 0
    instance_uuid: str = ""
    live: bool = True
    has_text: bool = True
    seq: int = 0

    @property
    def domain(self) -> str:
        return f"{self.account.uuid}.{ {'INBOX': 1, 'Sent': 4, 'Archive': 7}.get(self.mailbox, 1) }"

    @property
    def category(self) -> str:
        return {"work": "primary", "personal": "primary", "invite": "primary", "bill": "transactions", "order": "transactions",
                "travel": "transactions", "code": "transactions", "notify": "updates", "newsletter": "updates",
                "promo": "promotions"}.get(self.kind, "none")

    @property
    def mailboxes(self) -> list:
        name = {"INBOX": "INBOX", "Sent": "Sent%20Messages", "Archive": "Archive"}[self.mailbox]
        return [f"mailbox.{self.mailbox.lower()}", f"imap://{self.account.uuid}/{name}"]


class World:
    """Everything the writers share: persona, clock, the two mail accounts."""

    def __init__(self, persona: Persona, rng: random.Random, clock: lib.Clock):
        self.p = persona
        self.rng = rng
        self.clock = clock
        self.now = clock.now
        me = persona.owner
        self.me = me
        self.personal = Account("personal", lib.uuid_string(rng), me.emails[0])
        self.work = Account("work", lib.uuid_string(rng), me.emails[-1])
        self.zone: datetime.tzinfo = clock.tz
        try:
            import zoneinfo
            self.zone = zoneinfo.ZoneInfo(persona.time_zone)
        except Exception:                    # no zoneinfo / tzdata: the persona's fixed offset
            pass
        try:
            self.device_uuid = uuid.UUID(persona.this_mac.identifier).bytes
        except ValueError:
            self.device_uuid = lib.uuid_obj(rng).bytes

    def sub(self) -> random.Random:
        """An independent stream for one writer, so writers do not disturb each other."""
        return random.Random(self.rng.getrandbits(64))

    def local(self, when: datetime.datetime) -> datetime.datetime:
        return when.astimezone(self.zone)

    def awake(self, when: datetime.datetime, rng: random.Random, work: bool = False) -> datetime.datetime:
        """Moves a time that fell into the night (or, for work mail, outside office days)
        to the next sensible hour."""
        local = self.local(when)
        first, last = (8, 19) if work else (7, 23)
        if local.hour >= last:
            local = (local + datetime.timedelta(days=1)).replace(hour=first, minute=rng.randrange(60))
        elif local.hour < first:
            local = local.replace(hour=first, minute=rng.randrange(60))
        while work and local.weekday() >= 5:
            local += datetime.timedelta(days=1)
        return local.astimezone(UTC)

    def day(self, when: datetime.datetime) -> str:
        local = self.local(when)
        return f"{local.strftime('%A')} {local.day} {local.strftime('%B')}"

    def month(self, when: datetime.datetime) -> str:
        return self.local(when).strftime("%B %Y")

    def at(self, rng: random.Random, days_ago: float, hours: tuple = (7, 22), weekdays: bool = False) -> datetime.datetime:
        days = max(0, int(days_ago))
        if weekdays:
            while (self.local(self.now) - datetime.timedelta(days=days)).weekday() >= 5:
                days += 1
        return self.clock.at(days, rng.randrange(hours[0], hours[1]), rng.randrange(60), rng.randrange(60))


# ----------------------------------------------------------------------------------------
# The mail corpus (all text invented)
# ----------------------------------------------------------------------------------------

PROJECTS = ["Onboarding flow", "Settings redesign", "Design system 2.0", "Checkout revamp", "Accessibility audit",
            "Notification preferences", "Dark mode", "Billing page", "Search results", "Pōneke transit app",
            "Icon refresh", "Empty states", "Research synthesis", "Mobile navigation"]

WORK_SUBJECTS = [
    "{p}: design review notes", "{p} — feedback by {weekday}?", "Figma link for {p}", "{p}: usability test findings",
    "Agenda for the {p} sync", "{p}: handoff checklist", "Draft copy for {p}", "{p} — open questions",
    "Estimates for {p}", "{p}: prototype ready", "Sprint {n} retro notes", "Sprint {n} planning",
    "Notes from our 1:1", "All-hands slides — {month}", "Team lunch at {cafe}", "Interview panel on {weekday}",
    "Quarterly roadmap draft", "Research participants needed", "{p}: copy review", "{p} — analytics after launch",
    "Workshop outline: {p}", "Leave on {weekday}",
]

WORK_SENTENCES = [
    "I've added comments to the Figma file, mostly about spacing in the second step.",
    "Can we get this in front of users before the end of the sprint?",
    "The prototype is linked in the doc; let me know if the flows make sense.",
    "{colleague} raised a good point about the empty state, so I've reworked it.",
    "Engineering estimate is roughly three days, assuming no API changes.",
    "I'll bring printouts to the review on {weekday}.",
    "Five of six participants completed the task without help.",
    "The main confusion was the label on the primary button.",
    "Let's keep the old behaviour behind a flag until we have the numbers.",
    "I've moved the open questions to the top of the doc.",
    "Happy to pair on this tomorrow morning if that helps.",
    "Contrast on the secondary text fails AA, so I've darkened it slightly.",
    "Could you double-check the copy with {colleague} before we ship?",
    "I've booked the big meeting room for 2 pm.",
    "Thanks for turning this around so quickly.",
    "Next step is a short write-up for {manager}.",
    "We agreed to cut the tooltip and revisit it after launch.",
    "The recording and my notes are in the shared folder.",
    "I think the second option is clearer, but I'm not attached to it.",
    "Completion went from 61% to 74% in the test group.",
    "The component is now in the library under Forms.",
    "Shall we walk through it at stand-up?",
    "I've split the ticket in two so the first half can ship this week.",
    "Legal is fine with the wording as long as we keep the link to the policy.",
    "One thing to watch: the layout breaks below 360 points.",
    "I'm out on Friday, so please send feedback by Thursday.",
]

WORK_REPLIES = [
    "Looks good to me. Two small comments in the file.", "Thanks, this is really clear.",
    "Agreed. I'll update the ticket.", "Can we talk it through at stand-up? I have a couple of concerns about scope.",
    "Done. The new version is in the same file, page 3.", "Nice work. Let's ship it behind the flag.",
    "I'd rather not change the label this late, but I see the point.", "Yes, Thursday works for me.",
    "Added to the agenda.", "I've left a note for {colleague} as well.", "Good catch. Fixed.",
    "Could you share the raw numbers too?", "Works for me. I'll book the room.", "Kia ora, thanks for the update.",
]

PERSONAL_TOPICS = [
    ("Dinner on Saturday?", ["Are you two free on Saturday night? I was thinking {cafe} around seven.",
                             "I can book a table for four.", "Jamie might join if she's back from Auckland in time."]),
    ("Photos from {park}", ["I finally sorted the photos from {park}. The kākā ones came out really well.",
                            "The best twenty are in a shared album.", "Tell me which ones you'd like printed."]),
    ("Mum's birthday", ["Mum's birthday is coming up on the 23rd.", "Shall we do lunch in Paraparaumu and get her the garden bench?",
                        "I can drive up on the Saturday morning.", "Dad says not to mention the cake."]),
    ("Tramping this weekend?", ["The forecast looks decent for the Southern Crossing.", "I can bring the stove and the big tent.",
                                "We'd need to leave Wellington by 6:30.", "Bring the warm sleeping bag; the hut is at 1,400 metres."]),
    ("Climbing on Thursday?", ["Anyone keen for a session at {gym} on Thursday?", "They've reset the overhang wall.",
                               "I can lend you shoes if yours are still at your parents' place."]),
    ("Recipe you asked for", ["Here's the kūmara and coconut soup recipe.", "Roast the kūmara first; it makes all the difference.",
                              "It freezes well, so make a double batch."]),
    ("Queenstown trip plan", ["I've pencilled in four nights in Queenstown.", "Flights are cheapest on the Thursday morning.",
                              "Lakeview Lodge still has rooms with a kitchen.", "We could do the Ben Lomond track if the weather holds."]),
    ("Book recommendation", ["You'd love the one I just finished. It's set on the Kāpiti coast in the seventies.",
                             "I'll drop it round on Sunday.", "No rush giving it back."]),
    ("Ferry tickets", ["I've booked us on the 9 am sailing.", "We need to check in forty-five minutes before.",
                       "I'll forward the confirmation once it arrives."]),
    ("Housewarming next month", ["We're finally having a housewarming on the first Saturday of next month.",
                                 "Come any time after three.", "Bring a plate if you like, but there'll be plenty."]),
    ("Can you pick up the parcel?", ["There's a card in the letterbox for a parcel at the depot.",
                                     "Could you pick it up on your way home? You'll need photo ID.", "It's the new climbing rope, I think."]),
    ("Christmas plans", ["Are we doing Christmas at Mum and Dad's again?", "I can bring the pavlova and the folding chairs.",
                         "Alex has to work on the 27th, so we'd head back on Boxing Day."]),
    ("Car WOF is due", ["The warrant runs out at the end of the month.", "I've booked it in for Tuesday at 8.",
                        "Can you drop me at the station that morning?"]),
    ("Sunday market run", ["I'm going to {market} on Sunday morning. Need anything?", "The cheese stall is back.",
                           "I'll be there about nine if you want to come along."]),
    ("Concert tickets", ["{artist} are playing at the Opera House next month.", "Tickets go on sale on Friday at 9.",
                         "Shall I get four?"]),
    ("Spare key", ["I've left the spare key with the neighbours at number 12.", "Please water the ferns while we're away.",
                   "Back on the 14th."]),
    ("Your old bike", ["Is your old bike still in Mum and Dad's garage?", "A friend of mine is looking for one for the commute.",
                       "Happy to clean it up if you're okay with selling it."]),
    ("Rotorua long weekend", ["How about Rotorua for the long weekend?", "There's a place by the Government Gardens with a hot pool.",
                              "We could take the bikes to the Redwoods."]),
    ("Quick favour", ["Could you look after the cat on Friday night?", "Food is in the cupboard under the sink.",
                      "I owe you a coffee at {coffee}."]),
    ("Lunch this week?", ["Are you around for lunch on Wednesday?", "{coffee} at 12:30?", "I have news."]),
    ("Dad's seventieth", ["We should start planning Dad's birthday.", "I've asked about the function room at the boating club.",
                          "Can you look into a photo book?"]),
    ("Movie on Friday", ["The film festival programme is out.", "There's a 6:15 session on Friday at the Embassy.",
                         "I'll book if you're in."]),
]

LANDLORD_TOPICS = [
    ("Flat inspection next week", ["The six-monthly inspection is due. Would Thursday at 5 pm suit?", "It takes about fifteen minutes.",
                                   "Let me know if anything needs fixing before then."]),
    ("Heat pump service", ["The heat pump is due for its annual service.", "The technician can come on Tuesday morning between 9 and 11.",
                           "Someone will need to be home to let them in."]),
    ("Leak under the kitchen sink", ["There's a slow leak under the kitchen sink; I've put a bucket under it for now.",
                                     "Could you send a plumber this week?", "Weekday mornings are best for access."]),
    ("Smoke alarm", ["The hallway smoke alarm has started chirping.", "I think it needs a new battery or replacing altogether.",
                     "Happy to buy one and send you the receipt."]),
]

LANDLORD_REPLIES = ["That works, thanks.", "Thursday is fine. See you then.", "Thanks for sorting that out so quickly.",
                    "I'll be working from home that day, so any time suits.", "All done. Receipt attached to the next rent e-mail."]

PERSONAL_REPLIES = [
    "Sounds good to me!", "Yes, count me in.", "I can't do Saturday, but Sunday works.", "Thanks, that's perfect.",
    "Let me check with Alex and get back to you.", "Ha, of course. See you then.", "Could we make it a bit later? I finish at six.",
    "Love that idea.", "Booked. I'll send the details through.", "Running late, sorry. Start without me.",
    "Great, see you there. I'll bring the thermos.", "That works. Shall I drive?", "Perfect. Thank you so much!",
    "I'll ask Mum tonight.", "Yes please!",
]

NEWSLETTER_LINES = {
    "design": ["This week: why naming a component is harder than drawing it.", "A short essay on defaults, and who they serve.",
               "Three portfolios we enjoyed, and what they have in common.", "Listener question: how do you run a critique remotely?",
               "A teardown of an onboarding flow that asks for too much, too soon.", "Tools corner: variables, tokens and when not to bother."],
    "news": ["The week in review, in five short items.", "Council votes on the harbour-side cycleway.",
             "A long read on the future of the regional rail network.", "Weather: a southerly change arrives on Thursday.",
             "The quiet return of the neighbourhood bookshop.", "What the new ferry timetable means for commuters."],
    "birds": ["Kākā numbers in the city are up again this spring.", "How to tell a tūī from a bellbird by ear.",
              "Volunteers needed for the five-minute bird count.", "A kererū's guide to your garden: what to plant.",
              "Field notes from Kāpiti Island.", "Why the dawn chorus is loudest in October."],
    "trail": ["Track report: the Southern Crossing is clear but muddy above the bush line.", "Gear note: looking after a down jacket.",
              "A weekend loop in the Remutaka range.", "Hut etiquette, revisited.", "Reader trip: three days on the Heaphy.",
              "Know before you go: river crossings after rain."],
    "music": ["The new season opens with an evening of chamber works.", "Subscribers can book from Monday.",
              "A conversation with our principal cellist.", "Lunchtime concerts return to the waterfront."],
    "gym": ["The overhang wall has been reset with twelve new routes.", "Beginner lead course starts next Tuesday.",
            "Reminder: the gym closes at 6 pm on public holidays.", "Bring a friend for free on the first Sunday of the month."],
    "shop": ["New-season merino layers have arrived.", "Members get 20% off rain shells this weekend.",
             "Our guide to choosing a three-season tent.", "Last sizes: trail shoes from $89."],
}

VIP_KEYS = ("alex", "aroha", "helen", "landlord")      # the same four the comms generator marks as VIPs

SEARCH_QUERIES = ["boarding pass", "payslip", "statement", "invoice", "tenancy", "Queenstown", "from:alex", "dentist",
                  "verification code", "Figma", "retro notes", "onboarding", "rent receipt", "parcel", "tracking number",
                  "passport", "power bill", "roadmap", "lakeview lodge", "wof", "recipe", "ferry", "interview panel",
                  "leave", "from:aroha roadmap", "kowhai payroll", "usability", "membership", "library", "booking reference"]


class Corpus:
    """Builds the list of messages."""

    def __init__(self, world: World):
        self.w = world
        self.rng = world.sub()
        self.out: list[Message] = []
        p = world.p
        self.cafe = p.place("cafe").name
        self.coffee = p.place("coffee").name
        self.gym = p.place("gym").name
        self.market = p.place("market").name
        self.parks = [p.place(k).name for k in ("zealandia", "botanic", "oriental", "mt_vic")]
        self.colleagues = p.people_with("colleague") + p.people_with("manager")
        self.manager = p.person("manager")
        self.circle = [x for x in p.others if x.relationship in ("partner", "mother", "father", "sister", "friend")]
        self.artists = sorted({t.artist for t in p.tracks})

    # -- text ---------------------------------------------------------------------------

    def fill(self, text: str, when: datetime.datetime) -> str:
        rng = self.rng
        later = when + datetime.timedelta(days=rng.randint(1, 6))
        return text.format(
            p=rng.choice(PROJECTS), weekday=self.w.local(later).strftime("%A"), month=self.w.local(when).strftime("%B"),
            n=20 + int((SPAN_MONTHS * MONTH - (self.w.now - when).days) / 14) % 90, cafe=self.cafe, coffee=self.coffee,
            gym=self.gym, market=self.market, park=rng.choice(self.parks), artist=rng.choice(self.artists),
            colleague=rng.choice(self.colleagues).given, manager=self.manager.given,
        )

    def letter(self, to_given: str, lines: list, from_given: str, maori: bool = False) -> str:
        rng = self.rng
        greeting = rng.choice(["Hi", "Hey", "Kia ora", "Mōrena", "Hi"] if maori else ["Hi", "Hey", "Hi", "Hello"])
        sign = rng.choice(["Cheers,", "Ngā mihi,", "Thanks,", "Talk soon,"] if maori else ["Love,", "Cheers,", "See you soon,", "x"])
        return f"{greeting} {to_given},\n\n" + "\n\n".join(lines) + f"\n\n{sign}\n{from_given}"

    def quote(self, previous: Message) -> str:
        local = self.w.local(previous.date)
        first = [line for line in previous.body.split("\n") if line.strip()][1:4]
        stamp = f"On {local.day} {local.strftime('%b %Y')}, at {local.strftime('%H:%M')}, {previous.sender[0]} <{previous.sender[1]}> wrote:"
        return "\n\n" + stamp + "\n\n" + "\n".join("> " + line for line in first)

    # -- threads between people ---------------------------------------------------------

    def thread(self, account: Account, people: list, subject: str, opening: list, replies: list, start: datetime.datetime,
               kind: str, attachments: Optional[list] = None, event: Optional[dict] = None) -> None:
        rng, w = self.rng, self.w
        me = (w.me.full_name, account.address)
        parties = [(x.full_name, x.email) for x in people]
        everyone = [me] + parties
        length = rng.choices([1, 2, 3, 4, 5, 6], weights=[30, 28, 19, 11, 7, 5])[0]
        when = start
        previous: Optional[Message] = None
        for index in range(length):
            if index == 0:
                sender = me if rng.random() < 0.2 else parties[0]
            else:
                candidates = [x for x in everyone if x != previous.sender]
                sender = rng.choices(candidates, weights=[0.7 if x == me else 1.0 for x in candidates])[0]
            others = [x for x in everyone if x != sender]
            to_given = others[0][0].split(" ")[0]
            if index == 0:
                body = self.letter(to_given, opening, sender[0].split(" ")[0], maori=kind in ("work", "invite"))
            else:
                lines = [self.fill(x, when) for x in rng.sample(replies, rng.choice([1, 1, 2]))]
                if kind in ("work", "invite") and rng.random() < 0.5:
                    lines.append(self.fill(rng.choice(WORK_SENTENCES), when))
                body = self.letter(to_given, lines, sender[0].split(" ")[0], maori=kind in ("work", "invite")) + self.quote(previous)
            message = Message(
                account=account, date=when, subject=("Re: " if index else "") + subject, sender=sender, to=others[:1], cc=others[1:],
                body=body, kind=kind, mailbox="Sent" if sender == me else "INBOX", reply_to=previous,
                attachments=list(attachments or []) if index == 0 else [], event=event if index == 0 else None,
            )
            if previous is not None and sender == me:
                previous.replied = True
            self.out.append(message)
            previous = message
            when = when + datetime.timedelta(minutes=rng.choice([4, 9, 17, 35, 62, 140, 300, 900, 1500]) + rng.randrange(4), seconds=rng.randrange(60))
            when = w.awake(when, rng, work=kind in ("work", "invite"))
            if when > w.now - datetime.timedelta(minutes=3):
                break

    def work_month(self, month: int) -> None:
        rng, w = self.rng, self.w
        for _ in range(rng.randint(8, 12)):
            when = w.at(rng, month * MONTH + rng.uniform(0, MONTH), hours=(8, 18), weekdays=True)
            people = rng.sample(self.colleagues, rng.choice([1, 1, 2, 2, 3]))
            if rng.random() < 0.3 and self.manager not in people:
                people[0] = self.manager
            subject = self.fill(rng.choice(WORK_SUBJECTS), when)
            opening = [self.fill(x, when) for x in rng.sample(WORK_SENTENCES, rng.randint(2, 5))]
            attachments = None
            if rng.random() < 0.3 and any(project in subject for project in PROJECTS):
                attachments = [self.work_file(subject, when)]
            self.thread(w.work, people, subject, opening, WORK_REPLIES, when, "work", attachments)

    def work_file(self, subject: str, when: datetime.datetime) -> Attachment:
        rng = self.rng
        topic = next((project for project in PROJECTS if project in subject), subject.split(":")[0].strip())
        stem = topic.replace(" ", "-").replace(".", "-")
        kind = rng.choice(["pdf", "docx", "pptx", "png", "csv", "pdf", "docx"])
        if kind == "csv":
            rows = ["participant,task,completed,time_s,notes"]
            for n in range(1, rng.randint(6, 9)):
                rows.append(f"P{n},{rng.choice(['sign up', 'change plan', 'find invoice', 'invite teammate'])},{rng.choice(['yes', 'yes', 'yes', 'no'])},{rng.randint(22, 190)},{rng.choice(['', 'hesitated at step 2', 'missed the link', 'asked for help'])}")
            return Attachment(f"{stem}-test-results.csv", "\n".join(rows))
        if kind == "png":
            return Attachment(f"{stem}-screens-v{rng.randint(1, 5)}.png")
        title = {"pdf": "Summary", "docx": "Findings", "pptx": "Review deck"}[kind]
        text = (f"{topic} — {title}\n{self.w.p.company} · prepared by {self.w.me.full_name} · {self.w.month(when)}\n\n"
                + "\n".join("• " + self.fill(x, when) for x in rng.sample(WORK_SENTENCES, 6))
                + "\n\nNext steps\n1. Share with the wider team\n2. Agree scope for the next sprint\n3. Re-test with five participants")
        return Attachment(f"{stem}-{title.lower().replace(' ', '-')}.{kind}", text)

    def personal_month(self, month: int, volume: float) -> None:
        rng, w = self.rng, self.w
        count = max(1, round(rng.uniform(3.5, 7.5) * volume))
        for _ in range(count):
            when = w.at(rng, month * MONTH + rng.uniform(0, MONTH), hours=(7, 23))
            person = rng.choices(self.circle, weights=[x.closeness ** 2 for x in self.circle])[0]
            people = [person]
            if rng.random() < 0.05:
                landlord = w.p.person("landlord")
                subject, lines = rng.choice(LANDLORD_TOPICS)
                self.thread(w.personal, [landlord], subject, lines[:rng.randint(2, len(lines))], LANDLORD_REPLIES, when, "personal")
                continue
            if rng.random() < 0.25:
                extra = rng.choice(self.circle)
                if extra is not person:
                    people.append(extra)
            subject, lines = rng.choice(PERSONAL_TOPICS)
            subject = self.fill(subject, when)
            opening = [self.fill(x, when) for x in lines[:rng.randint(2, len(lines))]]
            attachments = None
            if subject.startswith("Photos from"):
                first = rng.randint(1000, 8900)
                attachments = [Attachment(f"IMG_{first + n}.{rng.choice(['jpeg', 'jpeg', 'heic'])}") for n in range(rng.randint(1, 4))]
            self.thread(w.personal, people, subject, opening, PERSONAL_REPLIES, when, "personal", attachments)

    # -- single messages from organisations -----------------------------------------------

    def post(self, account: Account, when: datetime.datetime, sender: tuple, subject: str, body: str, kind: str, **extra) -> Message:
        me = (self.w.me.full_name, account.address)
        message = Message(account=account, date=when, subject=subject, sender=sender, to=[me], body=body, kind=kind, **extra)
        self.out.append(message)
        return message

    def monthly(self, month: int) -> None:
        """Bills, statements, payslips, newsletters, orders, codes for one month back."""
        rng, w, me = self.rng, self.w, self.w.me
        base = month * MONTH
        period = w.month(w.now - datetime.timedelta(days=base + 20))
        stamp = w.local(w.now - datetime.timedelta(days=base + 20)).strftime("%Y-%m")

        # Bank statement
        when = w.at(rng, base + 2, hours=(6, 8))
        opening = rng.uniform(1800, 6200)
        spend = [(self.cafe, rng.uniform(4.5, 28)), (self.gym, 89.0), (self.market, rng.uniform(22, 96)),
                 ("Windward Energy", rng.uniform(88, 240)), ("Tūī Mobile", 45.0), ("Trailhead Outfitters", rng.uniform(30, 260)),
                 (self.coffee, rng.uniform(4.5, 11)), ("Southerly Rail", 12.5)]
        lines = [f"{rng.randint(1, 28):02d} {period[:3]}  {name:<28} -{_money(amount)}" for name, amount in rng.sample(spend, 6)]
        text = (f"Harbourlight Bank\nStatement of account — {period}\n{me.full_name}\nEveryday account ending 4821\n\n"
                f"Opening balance  {_money(opening)}\n" + "\n".join(sorted(lines))
                + f"\n{rng.randint(14, 16)} {period[:3]}  {'Salary ' + w.p.company:<28} +{_money(rng.uniform(4100, 4600)) if month < WORK_MONTHS else _money(rng.uniform(2900, 3400))}"
                + f"\n\nClosing balance  {_money(opening + rng.uniform(-900, 1400))}\nThis is an invented demo statement.")
        self.post(w.personal, when, ("Harbourlight Bank", "statements@harbourlightbank.example.com"), f"Your {period} statement is ready",
                  f"Kia ora {me.given},\n\nYour statement for {period} is attached and is also available in online banking.\n\n"
                  "If you did not expect this message, call us on the number on the back of your card. We will never ask for your password by e-mail.\n\nHarbourlight Bank",
                  "bill", attachments=[Attachment(f"Statement-{stamp}.pdf", text)])

        # Mobile
        if month < 60:
            amount = rng.choice([45.0, 45.0, 45.0, 52.4, 61.9])
            self.post(w.personal, w.at(rng, base + 9, hours=(7, 10)), ("Tūī Mobile", "billing@tuimobile.example.net"),
                      f"Your Tūī Mobile bill for {period}: {_money(amount)}",
                      f"Hi {me.given},\n\nYour bill for {period} is {_money(amount)} and will be paid by direct debit on the 20th.\n\n"
                      f"Plan: Everyday 12 GB\nMobile number: {me.phone}\nData used: {rng.uniform(2, 11.5):.1f} GB\n\nThanks for being with Tūī Mobile.",
                      "bill", attachments=[Attachment(f"TuiMobile-{stamp}.pdf", f"Tūī Mobile — tax invoice\nAccount holder: {me.full_name}\nPeriod: {period}\nPlan Everyday 12 GB  {_money(45)}\nExtras  {_money(amount - 45)}\nTotal due  {_money(amount)}")])

        if month < HOME_MONTHS:
            # Power and rent: since the move to the current flat
            home = w.p.place("home")
            amount = rng.uniform(92, 248)
            units = rng.randint(310, 820)
            self.post(w.personal, w.at(rng, base + 14, hours=(8, 12)), ("Windward Energy", "hello@windwardenergy.example.com"),
                      f"Your power bill is ready — {_money(amount)} due",
                      f"Kia ora {me.given},\n\nYour latest bill for the property on {home.street}, {home.city} is {_money(amount)}.\n"
                      f"You used {units} kWh this period.\n\nPay by the 28th to keep your prompt-payment discount.\n\nWindward Energy",
                      "bill", attachments=[Attachment(f"Windward-invoice-{stamp}.pdf", f"Windward Energy — invoice\nCustomer: {me.full_name}\nSupply address: {home.street}, {home.city} {home.postal_code}\nUsage: {units} kWh\nAmount due: {_money(amount)}")])
            landlord = w.p.person("landlord")
            self.post(w.personal, w.at(rng, base + 1, hours=(9, 17)), (landlord.full_name, landlord.email), f"Rent receipt — {period}",
                      f"Hi {me.given},\n\nReceived with thanks: rent for {period}, {_money(2340)}.\n\nThe gutters are being cleaned next week; the contractor will only need access to the side path.\n\nRegards,\n{landlord.given}",
                      "bill")

        if month < WORK_MONTHS:
            gross = 7916.67 if month < 14 else 7333.33
            paye, saver = gross * 0.246, gross * 0.03
            text = (f"{w.p.company} Limited — Payslip\nEmployee: {me.full_name}\nPosition: {me.job_title}\nPay period: {period}\n\n"
                    f"Gross pay        {_money(gross)}\nPAYE             -{_money(paye)}\nKiwiSaver (3%)   -{_money(saver)}\n"
                    f"Net pay          {_money(gross - paye - saver)}\n\nPaid to account ending 4821\nIRD number: 000-000-000 (demo)")
            self.post(w.work, w.at(rng, base + 16, hours=(6, 7)), (f"{w.p.company} Payroll", f"payroll@{w.p.company_domain}"), f"Payslip for {period}",
                      f"Kia ora {me.given},\n\nYour payslip for {period} is attached. Net pay of {_money(gross - paye - saver)} will be in your account on the 15th.\n\nPayroll questions: reply to this message.\n\nNgā mihi,\nPeople & Culture",
                      "bill", attachments=[Attachment(f"Payslip-{stamp}.pdf", text)])
            # Code review notifications
            for _ in range(rng.randint(3, 7)):
                number = 2200 - month * 46 + rng.randint(0, 40)
                title = rng.choice(["Update button tokens", "Fix focus ring on inputs", "Add empty-state illustrations", "Rename spacing scale",
                                    "Dark mode: elevation colours", "Reduce motion for toasts", "Checkout: inline validation", "Docs: form patterns"])
                author = rng.choice(self.colleagues)
                self.post(w.work, w.at(rng, base + rng.uniform(0, MONTH), hours=(8, 19), weekdays=True),
                          ("Kōwhai Git", f"notifications@git.{w.p.company_domain}"), f"[kowhai/design-system] {title} (#{number})",
                          f"{author.full_name} requested your review on #{number}.\n\n{title}\n\n" + self.fill(rng.choice(WORK_SENTENCES), w.now)
                          + f"\n\nView it: https://git.{w.p.company_domain}/kowhai/design-system/pull/{number}\n\nYou are receiving this because your review was requested.",
                          "notify", list_id=f"kowhai/design-system <design-system.kowhai.git.{w.p.company_domain}>")
            # Calendar invitations
            for _ in range(rng.randint(2, 4)):
                when = w.at(rng, base + rng.uniform(0, MONTH), hours=(8, 17), weekdays=True)
                organiser = rng.choice(self.colleagues)
                title = self.fill(rng.choice(["{p} design review", "{p} sync", "Sprint {n} planning", "Design critique", "1:1 {manager} / Robin",
                                              "{p} usability debrief", "Team retro", "Roadmap workshop"]), when)
                starts = (w.local(when) + datetime.timedelta(days=rng.randint(1, 8))).replace(hour=rng.choice([9, 10, 11, 13, 14, 15]), minute=rng.choice([0, 30]), second=0)
                while starts.weekday() >= 5:
                    starts += datetime.timedelta(days=1)
                starts = starts.replace(tzinfo=w.zone)
                ends = starts + datetime.timedelta(minutes=rng.choice([30, 45, 60]))
                room = rng.choice(["Kōwhai room", "Rātā room", "Level 4 studio", "Video call"])
                event = {"title": title, "start": starts, "end": ends, "where": room, "organiser": organiser, "kind": "invite"}
                self.thread(w.work, [organiser], f"Invitation: {title} @ {starts.strftime('%a')} {starts.day} {starts.strftime('%b %Y %H:%M')}",
                            [f"You have been invited to {title}.", f"When: {starts.strftime('%A')} {starts.day} {starts.strftime('%B %Y, %H:%M')} – {ends.strftime('%H:%M')} (NZ time)\nWhere: {room}\nOrganiser: {organiser.full_name}",
                             "Reply to this message or use your calendar to accept."], WORK_REPLIES, when, "invite",
                            [Attachment("invite.ics", _ics(event, me, w))], event)

        # Newsletters and promotions (weekly / fortnightly / monthly)
        def letters(name: str, address: str, key: str, title: str, since: int, every: float, kind: str = "newsletter") -> None:
            if month >= since:
                return
            offset = rng.uniform(0, every)
            while offset < MONTH:
                when = w.at(rng, base + offset, hours=(5, 9))
                issue = int((since * MONTH - (base + offset)) / every) + 1
                picks = rng.sample(NEWSLETTER_LINES[key], 3)
                body = (f"{title} — issue {issue}\n\n" + "\n\n".join(f"{n}. {line}" for n, line in enumerate(picks, 1))
                        + f"\n\nRead online: https://{address.split('@')[1]}/issues/{issue}\n\nYou are receiving this because you subscribed with {w.personal.address}. Unsubscribe: https://{address.split('@')[1]}/unsubscribe")
                self.post(w.personal, when, (name, address), f"{title} #{issue}: {picks[0].rstrip('.')}", body, kind,
                          list_id=f"{name} <{_slug(name)}.{address.split('@')[1]}>", read=rng.random() < 0.55)
                offset += every

        letters("The Design Detail Hour", "newsletter@designdetail.example.com", "design", "Design Detail Weekly", 44, 7)
        letters("Slow News Weekly", "digest@slownews.example.org", "news", "Slow News Weekly", 70, 7)
        letters("Birdsong Aotearoa", "hello@birdsong.example.org", "birds", "Birdsong Notes", 30, 14)
        letters("Trail Notes", "editor@trailnotes.example.net", "trail", "Trail Notes", SPAN_MONTHS, 30)
        letters("Wellington Harbour Ensemble", "boxoffice@harbourensemble.example.org", "music", "Season News", 60, 45)
        letters(self.gym, "hello@tearoclimbing.example.net", "gym", "Wall Notes", 30, 30)
        letters("Trailhead Outfitters", "news@trailhead.example.com", "shop", "Trailhead", 40, 12, kind="promo")

        # Orders with shipping and delivery notices
        if rng.random() < 0.75:
            when = w.at(rng, base + rng.uniform(4, MONTH), hours=(9, 22))
            order = f"TH-{rng.randint(10000, 99999)}"
            item, price = rng.choice([("Merino base layer", 119.0), ("Trail running shoes", 229.0), ("Chalk bag", 34.0), ("Headlamp 400 lm", 79.0),
                                      ("Rain shell", 349.0), ("Tramping socks (3 pack)", 45.0), ("Gas canister 230 g", 12.5), ("Dry bag 20 L", 39.0)])
            tracking = f"PP{rng.randint(10 ** 9, 10 ** 10 - 1)}NZ"
            home = w.p.place("home")
            self.post(w.personal, when, ("Trailhead Outfitters", "orders@trailhead.example.com"), f"Order {order} confirmed",
                      f"Thanks for your order, {me.given}!\n\nOrder {order}\n1 × {item}  {_money(price)}\nShipping  {_money(6.5)}\nTotal  {_money(price + 6.5)}\n\n"
                      f"Delivering to:\n{me.full_name}\n{home.street}, {home.city} {home.postal_code}\n\nWe'll e-mail you when it ships.", "order")
            shipped = when + datetime.timedelta(hours=rng.randint(18, 50))
            if shipped < w.now:
                self.post(w.personal, shipped, ("Trailhead Outfitters", "orders@trailhead.example.com"), f"Your order {order} has shipped",
                          f"Good news, {me.given}: your {item.lower()} is on its way with Pāua Parcel.\n\nTracking number: {tracking}\nTrack it: https://pauaparcel.example.net/track/{tracking}", "order")
            arriving = shipped + datetime.timedelta(hours=rng.randint(20, 44))
            if arriving < w.now:
                self.post(w.personal, arriving, ("Pāua Parcel", "tracking@pauaparcel.example.net"), f"Your parcel {tracking} is out for delivery",
                          f"Kia ora {me.given},\n\nYour parcel from Trailhead Outfitters is with our courier and will be delivered today between 10 am and 2 pm.\n\n"
                          f"Delivery address: {home.street}, {home.city}\nNo one home? We'll leave a card and take it to the depot.\n\nPāua Parcel", "order")

        if month < 24 and rng.random() < 0.8:
            total = rng.uniform(64, 148)
            self.post(w.personal, w.at(rng, base + rng.uniform(0, MONTH), hours=(8, 20)), (self.market, "orders@harboursidemarket.example.net"),
                      "Your market box is confirmed for Sunday",
                      f"Hi {me.given},\n\nYour seasonal box ({_money(total)}) will be ready to collect from stall 14 from 8 am on Sunday.\n\nThis week: kūmara, silverbeet, feijoas, free-range eggs, sourdough.\n\nSee you at the market!", "order")

        # Sign-in codes and security notices
        for _ in range(rng.choice([0, 1, 1, 2])):
            code = f"{rng.randint(0, 999999):06d}"
            service, address = rng.choice([("Harbourlight Bank", "security@harbourlightbank.example.com"), ("Lumen ID", "no-reply@lumenid.example.com"),
                                           ("Tūī Mobile", "no-reply@tuimobile.example.net"), ("Kōwhai Labs SSO", f"sso@{w.p.company_domain}")])
            account = w.work if "Kōwhai" in service else w.personal
            self.post(account, w.at(rng, base + rng.uniform(0, MONTH), hours=(7, 23)), (service, address), f"{code} is your {service} verification code",
                      f"Your {service} verification code is {code}.\n\nIt expires in 10 minutes. If you didn't try to sign in, you can ignore this message; someone may have typed your address by mistake.\n\nNever share this code with anyone.",
                      "code", two_factor=True)
        if rng.random() < 0.12:
            device = rng.choice(w.p.devices)
            self.post(w.personal, w.at(rng, base + rng.uniform(0, MONTH), hours=(7, 23)), ("Lumen ID", "no-reply@lumenid.example.com"), "New sign-in to your Lumen ID",
                      f"Hi {me.given},\n\nYour Lumen ID was used to sign in on a new device.\n\nDevice: {device.name} ({device.os_name} {device.os_version})\nNear: Wellington, New Zealand\n\n"
                      "If this was you, there's nothing to do. If not, reset your password: https://lumenid.example.com/reset", "notify")

        # Rail tickets to Paraparaumu, dentist, library
        if rng.random() < 0.4:
            when = w.at(rng, base + rng.uniform(0, MONTH), hours=(7, 21))
            ref = f"SR{rng.randint(100000, 999999)}"
            travel = w.local(when) + datetime.timedelta(days=rng.randint(1, 5))
            self.post(w.personal, when, ("Southerly Rail", "tickets@southerlyrail.example.net"), f"Your e-ticket: Wellington to Paraparaumu, {travel.day} {travel.strftime('%b')}",
                      f"Thanks for booking with Southerly Rail.\n\nBooking {ref}\n{me.full_name} — 1 adult, return\nWellington Railway Station → Paraparaumu\n"
                      f"{travel.strftime('%A')} {travel.day} {travel.strftime('%B %Y')}, departs 09:44\n\nShow the attached ticket on your phone.", "travel",
                      attachments=[Attachment(f"eticket-{ref}.pdf", f"Southerly Rail e-ticket\nBooking {ref}\nPassenger: {me.full_name}\nWellington → Paraparaumu (return)\n{travel.day} {travel.strftime('%B %Y')} 09:44\nFare {_money(25)}")])
        if month % 6 == 3:
            dentist = w.p.person("drlee")
            when = w.at(rng, base + 6, hours=(9, 16), weekdays=True)
            starts = (w.local(when) + datetime.timedelta(days=7)).replace(hour=8, minute=30, second=0, tzinfo=w.zone)
            event = {"title": f"Dental check-up, {dentist.organization}", "start": starts, "end": starts + datetime.timedelta(minutes=40),
                     "where": dentist.organization, "organiser": dentist, "kind": "appointment"}
            self.post(w.personal, when, (dentist.organization, dentist.email), f"Appointment reminder: {starts.strftime('%A')} {starts.day} {starts.strftime('%B')} at 8:30 am",
                      f"Dear {me.given},\n\nThis is a reminder of your check-up and clean with Dr {dentist.full_name} on {starts.strftime('%A')} {starts.day} {starts.strftime('%B')} at 8:30 am.\n\n"
                      f"Please reply or call {dentist.phone} if you need to reschedule. A fee applies to appointments cancelled with less than 24 hours' notice.\n\n{dentist.organization}", "notify", event=event)
        if rng.random() < 0.22:
            self.post(w.personal, w.at(rng, base + rng.uniform(0, MONTH), hours=(6, 9)), ("Pōneke Community Library", "notices@ponekelibrary.example.org"), "2 items are due back in three days",
                      f"Kia ora {me.given},\n\nThese items are due back soon:\n\n• A Field Guide to the Birds of Aotearoa\n• Thinking in Systems (large print)\n\nRenew them online or at any branch.", "notify")

    def trips(self) -> None:
        """Flights and hotel bookings: three past trips and one coming up."""
        rng, w, me = self.rng, self.w, self.w.me
        places = {"queenstown": ("ZQN", "Queenstown", "Lakeview Lodge Queenstown"), "auckland": ("AKL", "Auckland", "Harbour Quarter Hotel"),
                  "rotorua": ("ROT", "Rotorua", "Geyser View Motor Inn")}
        for key, booked_days_ago, leaves_in in (("queenstown", 172, 18), ("auckland", 431, 24), ("rotorua", 800, 30), ("auckland", 6, 12)):
            code, city, hotel = places[key]
            booked = w.at(rng, booked_days_ago, hours=(19, 22))
            depart = (w.local(booked) + datetime.timedelta(days=leaves_in)).replace(hour=rng.choice([7, 9, 11]), minute=rng.choice([10, 35, 50]), second=0, tzinfo=w.zone)
            arrive = depart + datetime.timedelta(minutes=rng.choice([65, 80, 105]))
            ref = "".join(rng.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(6))
            flight = f"KR {rng.randint(120, 890)}"
            seat = f"{rng.randint(4, 27)}{rng.choice('ACDF')}"
            event = {"title": f"Flight {flight} to {city}", "start": depart, "end": arrive, "where": "Wellington Airport (WLG)", "organiser": None, "kind": "flight"}
            self.post(w.personal, booked, ("Kererū Air", "bookings@kereruair.example.com"), f"Booking confirmed: Wellington to {city}, {depart.day} {depart.strftime('%b %Y')} ({ref})",
                      f"Kia ora {me.given},\n\nYou're going to {city}! Booking reference {ref}.\n\n{flight}  WLG → {code}\n{depart.strftime('%A')} {depart.day} {depart.strftime('%B %Y')}\n"
                      f"Departs {depart.strftime('%H:%M')} · Arrives {arrive.strftime('%H:%M')}\nPassenger: {me.full_name} · 1 × 23 kg bag\n\nTotal paid: {_money(rng.uniform(138, 420))} (card ending 4821)\n\nCheck-in opens 24 hours before departure.",
                      "travel", event=event, flagged=booked_days_ago < 30)
            nights = rng.randint(2, 4)
            self.post(w.personal, booked + datetime.timedelta(minutes=rng.randint(12, 90)), (hotel, f"reservations@{_slug(hotel)}.example.com"),
                      f"Reservation confirmed — {hotel}, {depart.day} {depart.strftime('%b')}",
                      f"Dear {me.full_name},\n\nThank you for your reservation.\n\nConfirmation: {rng.randint(10 ** 7, 10 ** 8 - 1)}\nCheck-in: {depart.strftime('%A')} {depart.day} {depart.strftime('%B %Y')}, from 2 pm\n"
                      f"Nights: {nights}\nRoom: Queen studio with kitchenette\nGuests: 2\nRate: {_money(rng.uniform(165, 289))} per night\n\nFree cancellation until 48 hours before arrival.\n\n{hotel}", "travel",
                      event={"title": f"Stay at {hotel}", "start": depart.replace(hour=14, minute=0), "end": (depart + datetime.timedelta(days=nights)).replace(hour=10, minute=0),
                             "where": f"{hotel}, {city}", "organiser": None, "kind": "hotel"})
            checkin = depart.astimezone(UTC) - datetime.timedelta(hours=24)
            if checkin < w.now:
                text = (f"BOARDING PASS\nKererū Air {flight}\n{me.family.upper()}/{me.given.upper()}\nWellington (WLG) → {city} ({code})\n"
                        f"{depart.day} {depart.strftime('%b %Y').upper()}  Boarding {(depart - datetime.timedelta(minutes=25)).strftime('%H:%M')}  Gate {rng.randint(8, 21)}  Seat {seat}\n"
                        f"Booking reference {ref}\nSequence {rng.randint(11, 140):03d}")
                self.post(w.personal, checkin + datetime.timedelta(minutes=rng.randint(1, 40)), ("Kererū Air", "checkin@kereruair.example.com"), f"Your boarding pass for {flight} to {city}",
                          f"Kia ora {me.given},\n\nYou're checked in. Your boarding pass is attached; you can also add it to your wallet.\n\n{flight}  WLG → {code}  Seat {seat}\nBoarding closes 15 minutes before departure.\nBooking reference {ref}\n\nHaere rā and have a good flight.",
                          "travel", attachments=[Attachment(f"BoardingPass-{ref}.pdf", text)])
        # A scan Robin sent to themselves before the last trip, and the tenancy renewal
        when = w.at(rng, 196, hours=(20, 22))
        scan = Message(account=w.personal, date=when, subject="Passport scan", sender=(me.full_name, w.personal.address), to=[(me.full_name, w.work.address)],
                       body="For the travel booking form.\n\nSent from my iPhone", kind="personal", mailbox="Sent", flagged=True,
                       attachments=[Attachment("Passport-scan.pdf", f"NEW ZEALAND · AOTEAROA\nPASSPORT · URUWHENUA\nSurname / Ingoa whānau  {me.family.upper()}\nGiven names / Ingoa tapa  {me.given.upper()}\n"
                                               f"Nationality  NEW ZEALAND\nDate of birth  {me.birthday[2]:02d} MAR {me.birthday[0]}\nPassport No.  LX000000\nSPECIMEN — invented demo document")])
        self.out.append(scan)
        landlord = w.p.person("landlord")
        home = w.p.place("home")
        self.post(w.personal, w.at(rng, 318, hours=(10, 16), weekdays=True), (landlord.full_name, landlord.email), "Tenancy agreement renewal",
                  f"Hi {me.given},\n\nAttached is the renewal for another twelve months at the same rent. If you and Alex are happy, sign page 4 and send it back by the end of the month.\n\nRegards,\n{landlord.given}",
                  "personal", flagged=True, attachments=[Attachment("Tenancy-agreement-renewal.pdf",
                                                                       f"RESIDENTIAL TENANCY AGREEMENT — RENEWAL\nLandlord: {landlord.full_name}\nTenants: {me.full_name}, {w.p.person('partner').full_name}\n"
                                                                       f"Premises: {home.street}, {home.city} {home.postal_code}\nTerm: 12 months, fixed\nRent: {_money(540)} per week, payable fortnightly\nBond held: {_money(2160)}\nInvented demo document.")])

    def today(self) -> None:
        """The last two days, so that the newest items are always from just now."""
        rng, w, me = self.rng, self.w, self.w.me
        ago = lambda **kw: w.now - datetime.timedelta(**kw)                       # noqa: E731
        at = w.clock.at                                                             # local wall time, never in the future
        lucas, nina, partner, sister = w.p.person("lucas"), w.p.person("nina"), w.p.person("partner"), w.p.person("sister")
        self.thread(w.work, [lucas, self.manager], "Settings redesign: handoff checklist",
                    ["The handoff checklist for the settings redesign is in the doc; three items are still open.",
                     "Could you confirm the copy for the notification toggles before stand-up tomorrow?",
                     "I've attached the latest screens so we are all looking at the same version."], WORK_REPLIES, at(1, 9, 12, 40), "work",
                    [Attachment("Settings-redesign-screens-v7.png"), self.work_file("Settings redesign: handoff", ago(hours=27))])
        self.thread(w.personal, [partner], "Dinner on Saturday?", ["Are we still on for Saturday? I was thinking " + self.cafe + " around seven.",
                                                                   "Jamie and Priya are both keen.", "I can book a table for four."], PERSONAL_REPLIES, at(1, 17, 41, 9), "personal")
        self.thread(w.work, [nina], "Onboarding flow: usability test findings",
                    ["Five of six participants finished sign-up without help; the one who didn't got stuck on the verification step.",
                     "Full notes and clips are in the research folder.", "Shall we walk the team through it on Thursday?"], WORK_REPLIES, at(0, 9, 5, 22), "work",
                    [self.work_file("Onboarding flow: usability", ago(hours=6))])
        self.post(w.personal, at(0, 7, 8, 38), ("The Design Detail Hour", "newsletter@designdetail.example.com"), "Design Detail Weekly: the case for boring buttons",
                  "This week: the case for boring buttons.\n\n1. Why the plainest control usually wins.\n2. A short history of the toggle.\n3. Listener question: how do you say no to a carousel?\n\n"
                  f"You are receiving this because you subscribed with {w.personal.address}.", "newsletter", list_id="The Design Detail Hour <thedesigndetailhour.designdetail.example.com>", read=False)
        self.thread(w.personal, [sister], "Photos from " + self.parks[0], ["The photos from " + self.parks[0] + " are up. The kākā on the feeder is my favourite.",
                                                                           "Send me yours when you get a chance."], PERSONAL_REPLIES, at(0, 8, 21, 38), "personal",
                    [Attachment("IMG_4821.jpeg"), Attachment("IMG_4822.jpeg")])
        code = f"{rng.randint(0, 999999):06d}"
        self.post(w.personal, ago(minutes=38), ("Harbourlight Bank", "security@harbourlightbank.example.com"), f"{code} is your Harbourlight Bank verification code",
                  f"Your Harbourlight Bank verification code is {code}.\n\nIt expires in 10 minutes. If you didn't try to sign in, call us on the number on the back of your card.\n\nNever share this code with anyone.",
                  "code", two_factor=True, read=False)
        self.post(w.work, at(0, 10, 19, 38), ("Kōwhai Git", f"notifications@git.{w.p.company_domain}"), "[kowhai/design-system] Settings: notification toggles (#2231)",
                  f"{lucas.full_name} requested your review on #2231.\n\nSettings: notification toggles\n\nImplements the toggles from the handoff checklist.\n\n"
                  f"View it: https://git.{w.p.company_domain}/kowhai/design-system/pull/2231", "notify", list_id=f"kowhai/design-system <design-system.kowhai.git.{w.p.company_domain}>", read=False)

    # -- assembly -----------------------------------------------------------------------

    def build(self) -> list:
        rng, w = self.rng, self.w
        for month in range(SPAN_MONTHS):
            volume = 0.4 + 0.6 * (1 - month / SPAN_MONTHS)
            if month < WORK_MONTHS:
                self.work_month(month)
            self.personal_month(month, volume)
            self.monthly(month)
        self.trips()
        self.today()
        cutoff = w.now - datetime.timedelta(seconds=40)
        messages = sorted((m for m in self.out if m.date <= cutoff), key=lambda m: m.date)
        rowid, att_id = 1200, 300
        for message in messages:
            rowid += rng.choice([1, 1, 1, 2, 3])
            message.rowid = rowid
            host = message.sender[1].split("@")[1]
            message.message_id = f"<{lib.uuid_string(rng, upper=False)}@{host}>"
            message.source_hash = _h64(rng)
            message.instance_uuid = lib.uuid_string(rng)
            age = (w.now - message.date).days
            gone = {"promo": 0.2, "newsletter": 0.1, "code": 0.3, "notify": 0.06}.get(message.kind, 0.015)
            message.live = not (age > 20 and rng.random() < gone)
            message.has_text = rng.random() < 0.965
            if age < 4 and message.kind in ("newsletter", "promo", "notify"):
                message.read = rng.random() < 0.3
            for attachment in message.attachments:
                att_id += rng.choice([1, 1, 2])
                attachment.att_id = att_id
                attachment.source_hash = _h64(rng)
        return messages


def _ics(event: dict, me: Person, w: World) -> str:
    organiser = event["organiser"]
    stamp = "%Y%m%dT%H%M%S"
    return "\n".join([
        "BEGIN:VCALENDAR", "PRODID:-//Kowhai Labs//Demo Calendar 1.0//EN", "VERSION:2.0", "METHOD:REQUEST", "BEGIN:VEVENT",
        f"UID:{lib.uuid_string(w.rng)}", f"DTSTART;TZID={w.p.time_zone}:{event['start'].strftime(stamp)}",
        f"DTEND;TZID={w.p.time_zone}:{event['end'].strftime(stamp)}", f"SUMMARY:{event['title']}", f"LOCATION:{event['where']}",
        f"ORGANIZER;CN={organiser.full_name}:mailto:{organiser.email}", f"ATTENDEE;CN={me.full_name};RSVP=TRUE:mailto:{w.work.address}",
        "SEQUENCE:0", "STATUS:CONFIRMED", "END:VEVENT", "END:VCALENDAR",
    ])


# ----------------------------------------------------------------------------------------
# Cascade sets
# ----------------------------------------------------------------------------------------

@dataclass
class Item:
    meta: bytes
    content: bytes
    written: datetime.datetime
    source_hash: Optional[int] = None
    deleted: Optional[datetime.datetime] = None
    seq: int = 0


def _set_path(root: pathlib.Path, *components: str) -> pathlib.Path:
    return lib.library(root, "Biome/sets/Default/" + "/".join(components) + "/Database/Set.db")


def _write_set(path: pathlib.Path, items: list, world: World, rng: random.Random) -> None:
    """One Set.db. Sequence numbers follow the written date; a deleted item keeps its
    metacontent and its row in the provenance log but loses the payload."""
    with lib.sqlite_db(path, SET_DDL) as con:
        con.execute("INSERT INTO device VALUES (1, ?, NULL, 3, 1, 1, 1, 1, NULL)", (world.device_uuid,))
        seq = rng.randint(2, 40)
        for item in sorted(items, key=lambda i: i.written):
            instance, content = _h64(rng), _h64(rng)
            item.seq = seq
            con.execute("INSERT INTO metacontent VALUES (?, ?)", (instance, item.meta))
            if item.deleted is None:
                con.execute("INSERT INTO content VALUES (?, ?)", (content, item.content))
            con.execute("INSERT INTO content_provenance VALUES (1, ?, ?, ?, ?)",
                        (content, seq, 0 if item.deleted is None else 1, None if item.deleted is None else _micros(item.deleted)))
            con.execute("INSERT INTO metacontent_provenance VALUES (1, ?, ?, ?, ?, ?, ?, ?)",
                        (item.source_hash, instance, content, seq, 0 if item.deleted is None else 1, _micros(item.written),
                         None if item.deleted is None else _micros(item.deleted)))
            seq += rng.choice([1, 1, 1, 1, 2])


def _donated(world: World, rng: random.Random, when: datetime.datetime, backfill_days: float = 74.0, lag: tuple = (3, 90)) -> datetime.datetime:
    """When an item with date `when` reached a set: shortly after it arrived, or — for
    everything older than the set — during the initial backfill, in date order."""
    start = world.now - datetime.timedelta(days=backfill_days)
    if when >= start:
        return min(world.now - datetime.timedelta(seconds=1), when + datetime.timedelta(seconds=rng.uniform(*lag)))
    span = SPAN_MONTHS * MONTH * 86400.0
    position = 1.0 - min(1.0, (start - when).total_seconds() / span)
    return start - datetime.timedelta(hours=40) + datetime.timedelta(seconds=position * 38 * 3600 + rng.uniform(0, 20))


def _headers(m: Message, world: World, rng: random.Random) -> list:
    """The header block Mail donates (lower-case names, alphabetical), all values invented."""
    host = m.sender[1].split("@")[1]
    local = world.local(m.date)
    name = lambda pair: f"{pair[0]} <{pair[1]}>" if pair[0] else pair[1]           # noqa: E731
    relay = f"mx{rng.randint(1, 4)}.{host}"
    address = f"{rng.choice(['192.0.2', '198.51.100', '203.0.113'])}.{rng.randint(2, 250)}"
    out = {
        "authentication-results": [f"mx.example.com; dkim=pass header.d={host}; spf=pass smtp.mailfrom={host}; dmarc=pass header.from={host}"],
        "content-type": [f"multipart/{'mixed' if m.attachments else 'alternative'}; boundary=\"b1_{lib.hex_string(rng, 24)}\""],
        "date": [email.utils.format_datetime(local)],
        "dkim-signature": [f"v=1; a=rsa-sha256; c=relaxed/relaxed; d={host}; s=demo{rng.randint(1, 3)}; h=from:to:subject:date:message-id; bh={lib.hex_string(rng, 43)}=; b={lib.hex_string(rng, 86)}=="],
        "from": [name(m.sender)],
        "message-id": [m.message_id],
        "mime-version": ["1.0"],
        "received": [f"from {relay} ({relay} [{address}]) by mx.example.com with ESMTPS id {lib.hex_string(rng, 12)} for <{m.to[0][1]}>; {email.utils.format_datetime(local + datetime.timedelta(seconds=2))}",
                     f"from localhost (unknown [10.0.{rng.randint(0, 9)}.{rng.randint(2, 250)}]) by {relay} with ESMTP id {lib.hex_string(rng, 10)}; {email.utils.format_datetime(local)}"],
        "return-path": [f"<{'bounce+' + lib.hex_string(rng, 8) + '@' + host if m.list_id else m.sender[1]}>"],
        "subject": [m.subject],
        "to": [", ".join(name(x) for x in m.to)],
    }
    if m.cc:
        out["cc"] = [", ".join(name(x) for x in m.cc)]
    if m.reply_to is not None:
        out["in-reply-to"] = [m.reply_to.message_id]
        chain, parent = [], m.reply_to
        while parent is not None and len(chain) < 6:
            chain.append(parent.message_id)
            parent = parent.reply_to
        out["references"] = [" ".join(reversed(chain))]
    if m.list_id:
        out["list-id"] = [m.list_id]
        out["list-unsubscribe"] = [f"<https://{host}/unsubscribe/{lib.hex_string(rng, 16)}>, <mailto:unsubscribe@{host}>"]
        out["list-unsubscribe-post"] = ["List-Unsubscribe=One-Click"]
        out["precedence"] = ["bulk"]
    if m.kind in ("work", "personal", "invite") and not m.list_id:
        out["x-mailer"] = [rng.choice(["Apple Mail (2.3864.300.41)", "iPhone Mail (23C52)", "Apple Mail (2.3864.300.41)"])]
    return sorted(out.items())


def _mail_entity(m: Message, world: World, rng: random.Random) -> bytes:
    owner_addresses = list(world.me.emails)
    sent, received = lib.unix(m.date), lib.unix(m.date) + rng.uniform(1, 9)
    correspondents = pb.message(
        [(2, a) for a in owner_addresses] + [(3, m.account.uuid), (6, m.sender[1]), (7, m.sender[0]), (13, 0)]
        + [(14, box) for box in m.mailboxes] + [(18, a) for _, a in m.to + m.cc] + [(19, n) for n, _ in m.to + m.cc if n]
        + [(25, float(sent)), (26, 0), (27, 1 if m.read else 0)]
        + [(29, [(1, name)] + [(2, value) for value in values]) for name, values in _headers(m, world, rng)])
    attributes = [
        (2, [(13, m.subject)]),
        (3, [(2, "public.email-message"), (3, "public.email-message"), (3, "public.message"), (15, m.domain), (17, m.account.kind)]),
        (7, [(2, float(sent)), (44, float(received))]),
        (10, correspondents),
        (12, [(5, 0)]),
        (13, [(1, m.account.uuid), (2, "public.email-message"), (2, "public.message"), (3, "public.email-message")]),
    ]
    custom = [
        ("com_apple_mail_dateReceived", (3, float(received))), ("com_apple_mail_flagged", (4, m.flagged)),
        ("com_apple_mail_is_authenticated", (4, True)), ("com_apple_mail_messageID", (1, str(m.rowid))),
        ("com_apple_mail_message_id_header", (1, m.message_id)), ("com_apple_mail_notification_id", (1, str(_h64(rng)))),
        ("com_apple_mail_priority", (2, 3)), ("com_apple_mail_read", (4, m.read)), ("com_apple_mail_repliedTo", (4, m.replied)),
    ]
    return pb.message([(1, "MailMessageEntity"), (2, [(1, m.subject)]), (5, attributes)]
                      + [(6, [(3, key), (2, [value])]) for key, value in custom])


def _attachment_entity(m: Message, a: Attachment) -> bytes:
    return pb.message([
        (1, "MailAttachmentEntity"), (2, [(1, a.name)]),
        (5, [(3, [(2, a.uti), (3, a.uti), (3, "public.data"), (6, a.name), (15, m.domain)]),
             (7, [(2, float(lib.unix(m.date)))]),
             (10, [(3, m.account.uuid), (6, m.sender[1]), (7, m.sender[0])])]),
        (6, [(3, "com_apple_mail_messageID"), (2, [(1, str(m.rowid))])]),
    ])


def _write_mail_sets(root: pathlib.Path, world: World, messages: list) -> dict:
    rng = world.sub()
    entities: list[Item] = []
    bodies: list[Item] = []
    files: list[Item] = []
    texts: list[Item] = []
    for m in messages:
        written = _donated(world, rng, m.date)
        deleted = None
        if not m.live:
            deleted = min(world.now - datetime.timedelta(minutes=5), max(written, m.date) + datetime.timedelta(days=rng.uniform(0.2, 18)))
        meta = pb.message([(1, str(m.rowid)), (3, pb.fixed32(rng.getrandbits(32))), (4, m.domain),
                           (6, f"1%2%0%{m.rowid}%{m.rowid}"), (7, rng.getrandbits(63)), (8, 0)])
        entities.append(Item(meta, _blob(_mail_entity(m, world, rng)), written, m.source_hash, deleted))
        if m.has_text and m.live:
            body_meta = pb.message([(1, str(m.rowid)), (2, _opaque16(rng)), (7, f"mail0:{m.domain}")])
            bodies.append(Item(body_meta, _blob(m.body.encode("utf-8")), written + datetime.timedelta(seconds=rng.uniform(0.5, 30)), m.source_hash))
        if not m.live:
            continue
        for a in m.attachments:
            item_id = f"attachment:{a.att_id}"
            entity_meta = pb.message([(1, f"{m.rowid}/{a.att_id}"), (3, pb.fixed32(rng.getrandbits(32))), (4, m.domain),
                                      (6, f"1%2%1%{m.rowid}%{a.att_id}"), (7, rng.getrandbits(63)), (8, 0)])
            entities.append(Item(entity_meta, _blob(_attachment_entity(m, a)), written + datetime.timedelta(seconds=1), a.source_hash))
            box = {"INBOX": "INBOX", "Sent": "Sent Messages", "Archive": "Archive"}[m.mailbox]
            location = f"file:///Users/robin/Library/Mail/V10/{m.account.uuid}/{box.replace(' ', '%20')}.mbox/Data/Attachments/{m.rowid}/2/{a.name}"
            file_meta = pb.message([(1, item_id), (2, location), (4, 1), (5, float(lib.unix(m.date))), (6, rng.getrandbits(63)), (7, str(m.rowid))])
            record = pb.message([(1, a.uti), (2, a.name), (3, m.account.uuid)] + [(4, box_name) for box_name in reversed(m.mailboxes)]
                                + [(5, m.message_id), (6, float(lib.unix(m.date))), (7, float(lib.unix(m.date)) + 3.0), (8, [(1, m.sender[0]), (2, m.sender[1])])])
            imported = written + datetime.timedelta(seconds=rng.uniform(5, 240))
            files.append(Item(file_meta, record, imported, a.source_hash))
            if a.text:
                texts.append(Item(pb.message([(1, item_id), (2, _opaque16(rng))]), _blob(a.text.encode("utf-8")),
                                  imported + datetime.timedelta(seconds=rng.uniform(2, 60)), a.source_hash))
    _write_set(_set_path(root, "App.Intents.IndexedEntity", "sourceIdentifier=com.apple.mail"), entities, world, rng)
    _write_set(_set_path(root, "Cascade.CachedDocument", "associatedSet=App.Intents.IndexedEntity", "sourceIdentifier=com.apple.mail"), bodies, world, rng)
    _write_set(_set_path(root, "Mail.ImportedAttachment", "sourceIdentifier=com.apple.mail"), files, world, rng)
    _write_set(_set_path(root, "Cascade.CachedDocument", "associatedSet=Mail.ImportedAttachment", "sourceIdentifier=com.apple.mail"), texts, world, rng)
    return {"entities": sum(1 for i in entities if i.deleted is None), "attachments": len(files), "texts": len(texts)}


def _entity(type_name: str, title: str, display: str, groups: list, custom: Optional[list] = None) -> bytes:
    """An App Intents entity: 1 type, 2 title, 3 type display name, 5 attribute groups, 6* custom attributes."""
    fields = [(1, type_name), (2, [(1, title)]), (3, [(1, display)]), (5, groups)]
    for key, value in custom or []:
        if isinstance(value, bool):
            fields.append((6, [(3, key), (2, [(4, value)])]))
        elif isinstance(value, int):
            fields.append((6, [(3, key), (2, [(2, value)])]))
        elif isinstance(value, float):
            fields.append((6, [(3, key), (2, [(3, value)])]))
        else:
            fields.append((6, [(3, key), (2, [(1, value)])]))
    return _blob(pb.message(fields))


def _write_other_sets(root: pathlib.Path, world: World) -> None:
    rng, p, me, clock = world.sub(), world.p, world.me, world.clock
    entity = "App.Intents.IndexedEntity"
    meta = lambda item_id, domain="": pb.message([(1, item_id), (3, pb.fixed32(rng.getrandbits(32)))] + ([(4, domain)] if domain else []) + [(6, item_id)])  # noqa: E731
    recent = lambda days: clock.ago(days=rng.uniform(0.05, days), minutes=rng.uniform(0, 600))  # noqa: E731

    # Reminders -------------------------------------------------------------------------
    account = lib.uuid_string(rng)
    store = lib.uuid_string(rng)
    lists = {
        "Reminders": ["Renew passport", "Book WOF for the car", "Call Mum back", "Return library books", "Pay power bill", "Back up laptop",
                      "Order new climbing shoes", "Send photos to Jamie", "Book dentist check-up", "Cancel free trial"],
        "Groceries": ["Oat milk", "Kūmara", "Coffee beans", "Sourdough", "Feijoas", "Dish tabs", "Eggs", "Olive oil", "Silverbeet", "Dark chocolate"],
        "Work": ["Prep slides for all-hands", "Review Lucas's pull request", "Write up usability findings", "Update the design tokens doc",
                 "Send research plan to Nina", "Book room for critique", "Expense the conference ticket", "Draft roadmap notes for Aroha"],
        "Queenstown trip": ["Check in for flight", "Pack rain shell", "Book Ben Lomond shuttle", "Charge camera batteries", "Print hotel confirmation"],
        "Flat": ["Water the ferns", "Clean heat pump filter", "Email Chris about the gutters", "Buy smoke alarm battery", "Sort recycling"],
    }
    items: list[Item] = []
    pk = 40
    for index, (name, titles) in enumerate(lists.items()):
        list_url = f"x-coredata://{store}/REMCDList/p{index + 3}"
        created = world.at(rng, rng.uniform(200, 900))
        items.append(Item(meta(list_url, account), _entity("ListEntity", name, "List", [
            (3, [(2, "com.apple.reminders.list"), (6, name), (14, name), (15, account)]), (7, [(2, float(lib.unix(created)))])],
            [("_REMItemTypeName", "list")]), _donated(world, rng, created, backfill_days=41)))
        for title in titles:
            pk += rng.randint(1, 4)
            url = f"x-coredata://{store}/REMCDReminder/p{pk}"
            created = world.at(rng, rng.uniform(0, 400) if name != "Queenstown trip" else rng.uniform(175, 190))
            groups = [(2, [(7, url)]), (3, [(2, "public.to-do-item"), (3, "public.to-do-item"), (6, title), (14, title), (15, account)]),
                      (7, [(2, float(lib.unix(created))), (3, float(lib.unix(created)) + rng.uniform(0, 86400))])]
            if rng.random() < 0.4:
                groups.append((5, [(2, float(lib.unix(created)) + rng.uniform(1, 12) * 86400)]))
            if title in ("Return library books", "Water the ferns"):
                place = p.place("home") if "ferns" in title else p.place("station")
                groups.append((6, [(20, place.latitude), (21, place.longitude), (22, place.name), (26, place.address)]))
            groups.append((11, [(1, name), (2, list_url), (4, name)]))
            items.append(Item(meta(url, account), _entity("ReminderEntity", title, "Reminder", groups, [
                ("_REMAccountID", f"x-apple-reminderkit://REMCDAccount/{account}"), ("_REMFlagged", 1 if rng.random() < 0.1 else 0), ("_REMIsRecurrent", title.startswith(("Water", "Back up"))),
                ("_REMIsUrgentForCurrentUser", False), ("_REMItemType", 0), ("_REMItemTypeName", "reminder"),
                ("_REMListID", f"x-apple-reminderkit://REMCDList/{lib.uuid_string(rng)}"), ("_REMObjectID", f"x-apple-reminderkit://REMCDReminder/{lib.uuid_string(rng)}")]),
                _donated(world, rng, created, backfill_days=41)))
    _write_set(_set_path(root, entity, "sourceIdentifier=com.apple.reminders"), items, world, rng)

    # Contact cards ---------------------------------------------------------------------
    items = []
    home = p.place("home")
    for person in p.people:
        ident = person.contact_id.split(":")[0]
        handles = [(2, h) for h in person.phones + person.emails]
        address = [(5, f"{home.street}"), (5, home.postal_code), (5, home.city), (5, home.country)] if person.key in ("robin", "alex") else []
        groups = [(3, [(1, person.given), (1, person.family), (2, "public.contact"), (3, "public.contact"), (6, person.full_name), (15, "contact")]),
                  (7, [(2, float(lib.unix(clock.ago(days=rng.uniform(300, 2000)))))]),
                  (10, handles + address + [(9, e) for e in person.emails] + [(15, n) for n in person.phones])]
        custom = [("organizationName", person.organization)] if person.organization else []
        items.append(Item(meta(ident, "contact"), _entity("ContactEntity", person.full_name, "Contact", groups, custom), recent(39) - datetime.timedelta(days=2)))
    _write_set(_set_path(root, entity, "sourceIdentifier=com.apple.contactsd"), items, world, rng)

    # Safari bookmarks and reading list -------------------------------------------------
    items = []
    pages = [(f"https://{domain}/", title, "BookmarkEntity", "Bookmark") for domain, title in p.web_domains]
    pages += [
        ("https://en.wikipedia.org/wiki/K%C4%81k%C4%81", "Kākā — Wikipedia", "ReadingListItemEntity", "Reading List Item"),
        ("https://en.wikipedia.org/wiki/Tararua_Range", "Tararua Range — Wikipedia", "ReadingListItemEntity", "Reading List Item"),
        ("https://www.doc.govt.nz/parks-and-recreation/places-to-go/", "Places to go — Department of Conservation", "BookmarkEntity", "Bookmark"),
        ("https://www.metservice.com/towns-cities/locations/wellington", "Wellington weather — MetService", "BookmarkEntity", "Bookmark"),
        ("https://developer.apple.com/design/human-interface-guidelines/", "Human Interface Guidelines", "BookmarkEntity", "Bookmark"),
        ("https://en.wikipedia.org/wiki/Typography", "Typography — Wikipedia", "ReadingListItemEntity", "Reading List Item"),
        ("https://github.com/explore", "Explore GitHub", "BookmarkEntity", "Bookmark"),
        ("https://www.openstreetmap.org/#map=14/-41.2900/174.7770", "OpenStreetMap — Wellington", "BookmarkEntity", "Bookmark"),
        ("https://en.wikipedia.org/wiki/Bouldering", "Bouldering — Wikipedia", "ReadingListItemEntity", "Reading List Item"),
        ("https://archive.org/details/texts", "Texts — Internet Archive", "BookmarkEntity", "Bookmark"),
        ("https://example.org/handbook/design-principles", "Design principles — Kōwhai Labs Intranet", "BookmarkEntity", "Bookmark"),
        ("https://example.org/people/leave", "Leave and holidays — Kōwhai Labs Intranet", "BookmarkEntity", "Bookmark"),
        ("https://en.wikipedia.org/wiki/Queenstown,_New_Zealand", "Queenstown, New Zealand — Wikipedia", "ReadingListItemEntity", "Reading List Item"),
        ("https://www.bbc.com/news/science_and_environment", "Science & Environment — BBC News", "ReadingListItemEntity", "Reading List Item"),
    ]
    for url, title, type_name, display in pages:
        host = url.split("/")[2]
        ident = lib.hex_string(rng, 64)
        groups = [(3, [(2, "com.apple.safari.bookmark"), (3, "com.apple.safari.bookmark"), (3, "public.item"), (4, url), (9, "/" + "/".join(url.split("/")[3:])),
                       (14, title), (15, "com.apple.Safari.BookmarksDomain"), (16, lib.hex_string(rng, 64))]), (7, [(1, host)])]
        items.append(Item(meta(ident, "com.apple.Safari.BookmarksDomain"), _entity(type_name, title, display, groups), recent(60)))
    _write_set(_set_path(root, entity, "sourceIdentifier=com.apple.Safari"), items, world, rng)

    # Music -----------------------------------------------------------------------------
    items = []
    for track in p.tracks:
        ident = f"music://library?persistentID={rng.getrandbits(62)}&kind=song"
        added = clock.ago(days=rng.uniform(5, 1200))
        groups = [(3, [(2, "public.audio"), (3, "public.audio"), (6, track.title), (14, track.title)]),
                  (7, [(2, float(lib.unix(added))), (15, float(track.seconds)), (31, track.genre), (37, 0)]),
                  (8, [(1, track.album), (2, track.artist), (10, track.genre)])]
        items.append(Item(pb.message([(1, ident), (3, pb.fixed32(rng.getrandbits(32))), (6, ident)]),
                          _entity("SongSiriEntity", track.title, "Song", groups), _donated(world, rng, added, backfill_days=52)))
    for album, artist, genre in sorted({(t.album, t.artist, t.genre) for t in p.tracks}):
        ident = f"music://library?persistentID={rng.getrandbits(62)}&kind=album"
        groups = [(3, [(2, "public.audio"), (3, "public.audio"), (6, album), (14, album)]), (7, [(2, float(lib.unix(clock.ago(days=rng.uniform(5, 1200)))))]),
                  (8, [(1, album), (2, artist), (10, genre)])]
        items.append(Item(pb.message([(1, ident), (3, pb.fixed32(rng.getrandbits(32))), (6, ident)]),
                          _entity("AlbumSiriEntity", album, "Album", groups), recent(50) - datetime.timedelta(days=2)))
    _write_set(_set_path(root, entity, "sourceIdentifier=com.apple.Music"), items, world, rng)

    # Find My: people and items ---------------------------------------------------------
    items = []
    for person in (p.person("partner"), p.person("sister"), p.person("mother")):
        ident = f"PersonEntity/{lib.hex_string(rng, 20)}~~"
        groups = [(3, [(2, "com.apple.appintents.entity"), (3, "com.apple.appintents.entity"), (14, person.given), (15, "PersonEntity")]),
                  (10, [(18, person.email), (19, person.given)])]
        items.append(Item(meta(ident, "PersonEntity"), _entity("PersonEntity", person.given, "", groups), recent(30)))
    _write_set(_set_path(root, entity, "sourceIdentifier=com.apple.findmy.findmylocateagent"), items, world, rng)
    items = []
    partner = p.person("partner")
    for name, owner in (("Keys", None), ("Backpack", None), ("Bike", None), (f"{partner.given}'s Keys", partner)):
        ident = f"ItemEntity/item0:{lib.uuid_string(rng)}"
        groups = [(3, [(2, "com.apple.appintents.entity"), (3, "com.apple.appintents.entity"), (6, name), (14, name), (15, "ItemEntity")])]
        if owner is not None:
            groups.append((10, [(6, owner.email), (7, owner.full_name)]))
        items.append(Item(meta(ident, "ItemEntity"), _entity("ItemEntity", name, "", groups), recent(30)))
    _write_set(_set_path(root, entity, "sourceIdentifier=com.apple.icloud.searchpartyuseragent"), items, world, rng)

    # HomeKit ---------------------------------------------------------------------------
    items = []
    home_id, home_name = lib.uuid_string(rng), "My Home"
    things = [("HomeEntity", "Home", home_name, "")] + [("RoomEntity", "Room", r, "") for r in ("Living Room", "Kitchen", "Bedroom", "Study", "Hallway")]
    things += [("AccessoryEntity", "Accessory", a, room) for a, room in (("Desk Lamp", "Study"), ("Living Room Speaker", "Living Room"), ("Heat Pump", "Living Room"),
                                                                      ("Bedside Lamp", "Bedroom"), ("Front Door Sensor", "Hallway"), ("Kitchen Plug", "Kitchen"))]
    things += [("SceneEntity", "Scene", s, "") for s in ("Good Morning", "Good Night", "Movie Time", "Leaving Home")]
    for type_name, display, name, room in things:
        ident = lib.uuid_string(rng)
        keywords = f"{home_name} {room} {name}".replace("  ", " ")
        groups = [(3, [(1, keywords), (2, "com.apple.appintents.entity"), (3, "com.apple.appintents.entity"), (6, name), (14, name), (15, type_name)]), (4, [(1, 1), (3, 1)])]
        custom = [("HomeKit_homeIdentifier", home_id), ("HomeKit_homeName", home_name)] + ([("HomeKit_roomName", room)] if room else [])
        items.append(Item(meta(f"{type_name}/{ident}", type_name), _entity(type_name, name, display, groups, custom), recent(45)))
    _write_set(_set_path(root, entity, "sourceIdentifier=com.apple.homed"), items, world, rng)

    # Plain (uncompressed protobuf) sets ---------------------------------------------------
    apple = [("com.apple.Maps", "Maps"), ("com.apple.weather", "Weather"), ("com.apple.calculator", "Calculator"), ("com.apple.TextEdit", "TextEdit"),
             ("com.apple.ActivityMonitor", "Activity Monitor"), ("com.apple.VoiceMemos", "Voice Memos"), ("com.apple.clock", "Clock"),
             ("com.apple.AppStore", "App Store"), ("com.apple.Dictionary", "Dictionary"), ("com.apple.ScreenSharing", "Screen Sharing")]
    apps = {a.bundle_id: a.name for a in p.apps_on("mac")}
    apps.update(apple)
    items = [Item(pb.message([(1, bundle), (2, f"{rng.randint(10 ** 11, 10 ** 12 - 1)}.{rng.randint(0, 9)}")]), pb.message([(1, bundle), (3, name)]), recent(70))
             for bundle, name in sorted(apps.items())]
    _write_set(_set_path(root, "App.InstalledApp"), items, world, rng)

    items = [Item(pb.message([(1, person.contact_id.split(":")[0])]), pb.message([(1, person.given), (3, person.family)]), recent(39) - datetime.timedelta(days=2))
             for person in p.people]
    _write_set(_set_path(root, "Contacts.Contact"), items, world, rng)

    devices = [(d.name, None) for d in p.devices] + [("Robin's AirPods Pro", None), (f"{partner.given}'s iPhone", partner)]
    items = [Item(pb.message([(1, str(index + 1))]), pb.message([(1, name), (2, [(1, owner.given), (2, owner.family)] if owner else "")]), recent(20))
             for index, (name, owner) in enumerate(devices)]
    _write_set(_set_path(root, "FindMy.Device"), items, world, rng)

    items = [Item(pb.message([(1, lib.uuid_string(rng)), (2, f"x-hm://h/id={home_id}")]), pb.message([(4, [(1, name), (2, 1)])]), recent(45))
             for _, _, name, _ in things]
    _write_set(_set_path(root, "HomeKit.Home"), items, world, rng)

    phrases = {
        "com.apple.VoiceMemos": [("Record a voice memo", "Record a ${applicationName}"), ("Start a new recording in Voice Memos", "Start a new recording in ${applicationName}"),
                                 ("Play my last voice memo", "Play my last ${applicationName}")],
        "com.apple.clock": [("Start a timer in Clock", "Start a timer in ${applicationName}"), ("Show my alarms in Clock", "Show my alarms in ${applicationName}"),
                            ("Open the stopwatch in Clock", "Open the stopwatch in ${applicationName}"), ("Show world clock in Clock", "Show world clock in ${applicationName}")],
        "com.apple.freeform": [("Create a new board in Freeform", "Create a new board in ${applicationName}"), ("Open my last Freeform board", "Open my last ${applicationName} board")],
    }
    for bundle, entries in phrases.items():
        items = []
        for phrase, template in entries:
            action = f"appshortcut://{bundle}#{rng.getrandbits(62)}#{lib.uuid_string(rng, upper=False)}"
            items.append(Item(pb.message([(1, action)]), pb.message([(1, phrase), (2, template), (3, lib.uuid_string(rng, upper=False)), (4, action)]), recent(70)))
        _write_set(_set_path(root, "App.Shortcut.Phrase", f"sourceIdentifier={bundle}"), items, world, rng)

    for name in EMPTY_SETS:
        _write_set(_set_path(root, name), [], world, rng)


# ----------------------------------------------------------------------------------------
# Hybrid search index (Kuzu file)
# ----------------------------------------------------------------------------------------

def _mail_payload(m: Message, world: World) -> dict:
    snippet = " ".join(m.body.split())[:280]
    person = lambda pair: {"displayName": pair[0], "emailAddress": pair[1]} if pair[0] else {"emailAddress": pair[1]}  # noqa: E731
    return {
        "attachments": [{"name": a.name, "identifier": f"attachment:{a.att_id}"} for a in m.attachments],
        "dateReceived": int(lib.cocoa(m.date)) + 2, "appEntityIdentifier": f"1%2%0%{m.rowid}%{m.rowid}",
        "to": [{"emailAddress": a} for _, a in m.to], "bodyLength": len(m.body), "isFromVIPSender": m.sender[1] in world.vips,
        "metadata": {"messageID": str(m.rowid), "messageIDHeader": m.message_id, "isAuthenticated": True},
        "body": {}, "cc": [{"emailAddress": a} for _, a in m.cc], "isReply": m.reply_to is not None, "dateSent": int(lib.cocoa(m.date)),
        "attributes": {"isTrash": False, "isJunk": False, "isRead": m.read, "isFlagged": m.flagged},
        "isHighImpact": m.kind in ("travel", "bill") and m.flagged, "isTwoFactorCode": m.two_factor, "filterDate": int(lib.cocoa(m.date)) + 2,
        "bcc": [], "itemInstanceUUID": m.instance_uuid, "mailCategory": m.category, "sourceItemUUID": m.instance_uuid,
        "sourceBundleIdentifier": "com.apple.mail", "mailboxes": m.mailboxes[1:], "subject": m.subject, "accountID": m.account.uuid,
        "isReplied": m.replied, "priority": 3, "sender": person(m.sender), "identifier": str(m.rowid), "bodySnippet": snippet,
    }


def _attachment_payload(m: Message, a: Attachment) -> dict:
    return {
        "name": a.name, "contentType": a.uti, "identifier": f"attachment:{a.att_id}", "messageIdentifier": str(m.rowid),
        "contentURL": f"file:///Users/robin/Library/Mail/V10/{m.account.uuid}/INBOX.mbox/Data/Attachments/{m.rowid}/2/{a.name}",
        "textContent": {}, "textContentLength": len(a.text), "textContentSnippet": " ".join(a.text.split())[:280],
        "sender": {"displayName": m.sender[0], "emailAddress": m.sender[1]}, "dateReceived": int(lib.cocoa(m.date)) + 2,
        "sourceBundleIdentifier": "com.apple.mail", "accountID": m.account.uuid,
    }


def _write_hybrid_search(root: pathlib.Path, world: World, messages: list) -> None:
    rng = world.sub()
    base = lib.daemon_container(root, "com.apple.hybridsearchd", world.rng) / "Library" / "HybridSearch"
    empty = lib.plist_bytes({})
    for name in COLLECTIONS:
        lib.write_bytes(base / "bookmarks" / name, empty)
        lib.write_bytes(base / "bookmarks" / (name + "_nodes"), empty)

    payloads: list[bytes] = []
    for m in messages:
        if not (m.live and m.has_text):
            continue
        payloads.append(json.dumps(_mail_payload(m, world), ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
        for a in m.attachments:
            if a.text:
                payloads.append(json.dumps(_attachment_payload(m, a), ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
    recent, older = payloads[-14:], payloads[:-14]

    def pages(count: int) -> bytes:
        return rng.randbytes(count * 4096)

    def strings(blobs: list, cut: float) -> bytes:
        """String pages: payloads back to back, each behind a length word; now and then one
        is cut short where the real file continues it on a page elsewhere."""
        out = bytearray()
        for index, blob in enumerate(blobs):
            if rng.random() < cut:
                blob = blob[:rng.randint(len(blob) // 3, len(blob) - 40)]
            out += struct.pack("<I", len(blob)) + blob
            out += bytes(-len(out) % 8)
            if index % 48 == 47:                         # a run of vector pages between string pages
                out += bytes(-len(out) % 4096) + pages(rng.randint(40, 56))
        return bytes(out + bytes(-len(out) % 4096))

    body = bytes(4096 * 3) + pages(96) + strings(older, 0.13) + pages(420)
    catalog_pages, metadata_pages = 5, 115
    total = 1 + len(body) // 4096 + catalog_pages + metadata_pages
    header = b"KUZU" + struct.pack("<QIIII", 57, total - catalog_pages - metadata_pages, catalog_pages, total - metadata_pages, metadata_pages) + lib.uuid_obj(rng).bytes
    data = header + bytes(4096 - len(header)) + body + pages(catalog_pages + metadata_pages)
    index_dir = base / "index" / "C"
    lib.write_bytes(index_dir / "index.db", data)
    lib.write_bytes(index_dir / "index.db.wal", pages(6) + strings(recent, 0.0) + pages(20))


# ----------------------------------------------------------------------------------------
# CoreSpotlight: document processing, knowledge graph, loose files
# ----------------------------------------------------------------------------------------

def _write_document_processing(root: pathlib.Path, world: World, messages: list) -> None:
    rng, now = world.sub(), world.now
    storage = lib.library(root, "Metadata/CoreSpotlight/DocumentProcessing/PipelineStorage")
    mail_source, file_source = rng.getrandbits(62), rng.getrandbits(62)
    pid = {name: index + 1 for index, (name, _) in enumerate(PIPELINES)}
    version = dict(PIPELINES)
    migrations = ["v1_5_initialSchema", "v1_5_removeDocStoreCacheTextContentHash", "v1_5_addInstanceIdentifierToDocStoreCache", "v1_5_addDestinationCookie",
                  "v1_5_addBookmarkNeedsReindex", "v1_5_addPriorityDateIndex", "v1_5_denormalizePriorityDate", "v1_5_denormalizeSource",
                  "v1_5_addProcessingTierPartialIndex", "v1_5_addPipelineItemErrorCount", "v1_5_addPipelineItemDeleteIndex", "v1_5_createRedonationTable"]
    embedded: list[tuple] = []          # (itemHash, message) of embedded mail, for the result cache

    with lib.sqlite_db(storage / "StateStore.db", STATE_DDL) as con:
        con.executemany("INSERT INTO grdb_migrations VALUES (?)", [(m,) for m in migrations])
        con.executemany("INSERT INTO pipeline (id, name, currentProcessorVersion) VALUES (?, ?, ?)", [(pid[n], n, v) for n, v in PIPELINES])
        destinations = {"GLPIndexing": (1, "HybridDatabaseIndex"), "GLPEmbedding": (2, "HybridDatabaseIndex"), "GLPMailAttachments": (3, "MailImportedAttachment")}
        for name, (dest, kind) in destinations.items():
            source = file_source if name == "GLPMailAttachments" else mail_source
            con.execute("INSERT INTO destination VALUES (?, ?, ?, ?, ?)", (dest, pid[name], f"{kind}-{source}", kind, rng.randint(1, 4)))
        for source in (mail_source, file_source):
            con.execute("INSERT INTO bookmark (source, bookmark, needsReindex) VALUES (?, ?, 0)", (source, rng.randbytes(rng.randint(96, 180))))

        def track(pipeline: str, identity: bytes, source: int, date: int, processed: float, result: float, error: float = 0.0, dest: Optional[int] = None) -> Optional[int]:
            """One pipeline_item row; returns the item hash when the pipeline produced a result."""
            item_hash = _h64(rng)
            done = rng.random() < processed
            failed = done and rng.random() < error
            has_result = done and not failed and rng.random() < result
            domain = code = None
            if failed:
                domain, code = rng.choice({
                    "GLPEmbedding": [("SpotlightKnowledgeDaemon.GLPEmbeddingSinkError", 1), ("Swift.CancellationError", 1)],
                    "GLPMailAttachments": [("NSPOSIXErrorDomain", 22), ("com.apple.CascadeSets.Item", 4)],
                }.get(pipeline, [("Swift.CancellationError", 1), ("Foundation._GenericObjCError", 0)]))
            con.execute("INSERT INTO pipeline_item VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?)",
                        (pid[pipeline], identity, version[pipeline] or 1 if done and not failed else None, (1 if has_result else 0) if done else None, item_hash,
                         domain, code, 1 if (now - datetime.datetime.fromtimestamp(date, UTC)).days < 3 else 0,
                         dest if done and not failed else None, 1 if dest and done and not failed else None, date, source, 1 if failed else 0))
            return item_hash if has_result else None

        live = [m for m in messages if m.live]
        for m in live:
            date = int(lib.unix(m.date))
            age = (now - m.date).days
            fresh = 0.55 if age < 1 else 1.0                      # the newest mail is still queued
            for entity_index in range(1 + len(m.attachments)):
                identity, lookup = rng.randbytes(16), rng.randbytes(16)
                is_message = entity_index == 0
                con.execute("INSERT INTO item VALUES (?, ?, ?, ?, ?)", (identity, lookup, mail_source, _h64(rng) if m.has_text else None, date))
                if rng.random() < 0.3:
                    con.execute("INSERT INTO document_store_cache VALUES (?, ?)", (lookup, rng.randbytes(16)))
                text = m.has_text if is_message else bool(m.attachments[entity_index - 1].text)
                item_hash = track("GLPEmbedding", identity, mail_source, date, 0.992 * fresh, 0.985 if text else 0.0, 0.006, dest=2)
                if item_hash is not None and is_message:
                    embedded.append((item_hash, m))
                track("GLPIndexing", identity, mail_source, date, 0.997 * fresh, 1.0, 0.002, dest=1)
                if not is_message:
                    continue
                track("LSSR5EventsandordersBackground", identity, mail_source, date, 0.93 * fresh, 0.9 if m.event or m.kind in ("order", "travel") else 0.004, 0.003)
                track("LSSR5CarkeydataBackground", identity, mail_source, date, 0.9 * fresh, 0.0)
                track("LSSR5IdentificationdocumentsBackground", identity, mail_source, date, 0.71 * fresh, 1.0 if m.subject in ("Passport scan", "Tenancy agreement renewal") else 0.0, 0.002)
                if age < 45:
                    track("LSSR5EventsandordersUrgent", identity, mail_source, date, 0.98 * fresh, 0.9 if m.event else 0.01)
                if age < 120 and m.kind in ("work", "personal", "invite") and m.mailbox == "INBOX":
                    track("LSSR5SmartrepliesBackground", identity, mail_source, date, 0.95 * fresh, 0.42)
            for a in m.attachments:
                identity = rng.randbytes(16)
                con.execute("INSERT INTO item VALUES (?, ?, ?, ?, ?)", (identity, rng.randbytes(16), file_source, _h64(rng) if a.text else None, date))
                track("GLPMailAttachments", identity, file_source, date, 0.985 * fresh, 0.97 if a.text else 0.0, 0.03, dest=3)

    with lib.sqlite_db(storage / "CachedResultStore.db", CACHE_DDL) as con:
        con.execute("INSERT INTO grdb_migrations VALUES ('v2_versionPerEntry')")
        cached = [n for n, _ in PIPELINES if n.startswith(("GLP", "LSSR5"))]
        recent = embedded[-1400:]
        for index, name in enumerate(cached, 1):
            con.execute("INSERT INTO pipeline (id, name, count) VALUES (?, ?, ?)", (index, name, len(recent) if name == "GLPEmbedding" else 0))
        attribute = json.dumps({"name": "textContent", "namespace": {"global": {}}}, separators=(",", ":")).encode()
        for position, (item_hash, m) in enumerate(recent):
            accessed = int(lib.unix(min(now, m.date + datetime.timedelta(hours=rng.uniform(0.01, 40)))))
            con.execute("INSERT INTO cached_result VALUES (1, ?, ?, 1, ?)", (item_hash, version["GLPEmbedding"], accessed))
            if position >= len(recent) - 120:           # vectors are kept for the newest results only
                results = [{"version": version["GLPEmbedding"], "vector": {"float16": {"_0": [round(rng.gauss(0, 0.09), 4) for _ in range(512)]}},
                            "key": {"entityType": "mail", "sourceItemIdentifier": str(m.rowid), "attributeName": attribute}} for _ in range(2)]
                con.execute("INSERT INTO cached_result_data VALUES (1, ?, ?)", (item_hash, lib.plist_bytes({"results": results})))

    # What System Settings shows as indexing progress, and the recent deltas.
    mail_items = sum(1 + len(m.attachments) for m in live)
    counts = {"com.apple.mail": mail_items, "com.apple.MobileSMS": 18240, "com.apple.Notes": 312, "com.apple.reminders": 43,
              "com.apple.iCal": 1286, "com.apple.Safari": 2904}
    per_bundle = {}
    for bundle, known in counts.items():
        percent = {"com.apple.mail": 99, "com.apple.MobileSMS": 97, "com.apple.Safari": 88}.get(bundle, 100)
        processed = known * percent // 100
        by_pipeline = {"GLPEmbedding": percent, "GLPIndexing": min(100, percent + 1)}
        per_bundle[bundle] = {
            "cachedDonation": {"allKnownItems": known, "dateOfNewestUndonatedItem": lib.iso(now - datetime.timedelta(minutes=rng.randint(4, 300))),
                               "isPartial": False, "itemsNeedingDonation": known - processed if percent < 100 else 0},
            "classification": "primary" if bundle in ("com.apple.mail", "com.apple.MobileSMS") else "secondary",
            "lastMonthAverage": percent, "lastMonthProgressByPipeline": by_pipeline, "lastSixMonthsAverage": percent,
            "lastSixMonthsProgressByPipeline": by_pipeline, "overallAverage": percent, "overallProgressByPipeline": by_pipeline,
            "percent": percent, "pipelineAverage": percent, "rank": "complete" if percent >= 97 else "indexing",
            "rawCountsByPipeline": {"GLPEmbedding": {"eligible": known, "processed": processed}, "GLPIndexing": {"eligible": known, "processed": min(known, processed + known // 100)}},
        }
    completeness = {"firstComputedAt": lib.iso(now - datetime.timedelta(days=74)),
                    "lastCalculated": {"clampApplied": 0, "computedAt": lib.iso(now - datetime.timedelta(minutes=47)), "enabledPipelines": ["GLPEmbedding", "GLPIndexing"],
                                       "perBundle": per_bundle, "percent": 97, "rank": "complete"},
                    "lastReportedFloor": {"percent": 97, "rank": "complete"}}
    lib.write_text(storage.parent / "SettingsUIPipelineCompleteness" / "latest.json", json.dumps(completeness, indent=2))
    rows = [{"bundle": bundle, "eligibleDelta": delta, "maxAgeDays": 30, "pipeline": pipeline, "processedDelta": delta - rng.randint(0, 2)}
            for bundle, delta in (("com.apple.mail", 61), ("com.apple.MobileSMS", 214), ("com.apple.Safari", 97), ("com.apple.Notes", 6))
            for pipeline in ("GLPEmbedding", "GLPIndexing")]
    lib.write_text(storage / "DeadReckoning.json", json.dumps({"rows": rows}, indent=2))


def _bitset(ids: list, minimum: int = 128) -> bytes:
    """Label / edge-membership bitset of the knowledge graph: 24-byte header, then bit n
    set for identifier n."""
    size = max(minimum, -(-(max(ids, default=0) + 1) // 64) * 8)
    bits = bytearray(size)
    for n in ids:
        bits[n // 8] |= 1 << (n % 8)
    return struct.pack("<IIIIII", 7, 1, 0, size // 64, 0, 0) + bytes(bits)


def _write_knowledge_graph(root: pathlib.Path, world: World, messages: list) -> None:
    rng, p, clock = world.sub(), world.p, world.clock
    labels = ["personUser", "domain_100", "personIdentifier", "referenceIdentifier", "personaIdentifier", "domainIdentifier", "phoneNumber",
              "relationship", "displayName", "name", "contactIdentifier", "nameKey", "emailAddress", "entityIdentifier", "photosPersonIdentifier"]
    label_id = {name: index + 1 for index, name in enumerate(labels)}
    attributes = {"value": 1, "score": 2, "relationship": 3, "domainIdentifier": 4, "firstName": 5, "lastName": 6}
    nodes: list[tuple] = []               # (kind, value, first, last)
    index: dict[tuple, int] = {}
    edges: list[tuple] = []               # (label, source, target, relationship, score, domain)

    def node(kind: str, value: str, first: str = "", last: str = "") -> int:
        key = (kind, value)
        if key not in index:
            nodes.append((kind, value, first, last))
            index[key] = len(nodes)
        return index[key]

    def pair(kind_a: str, a: int, kind_b: str, b: int) -> None:
        """An identity link in both directions, each labelled after its source kind."""
        score = round(rng.uniform(0.55, 1.0), 3)
        edges.append((kind_a, a, b, kind_a, score, None))
        edges.append((kind_b, b, a, kind_b, score, None))

    user = node("personUser", "user")
    persona = node("personaIdentifier", "0")
    domains = {d: node("domainIdentifier", d) for d in ("com.apple.CalendarUI", "com.apple.mobilephone", "com.apple.reminders", "com.apple.findmy")}
    pair("domainIdentifier", domains["com.apple.CalendarUI"], "personaIdentifier", persona)

    def dated(target: int, domain: str, count: int, days: float) -> None:
        """Dated links between the owner and an identifier (invitations, calls)."""
        for _ in range(count):
            when = lib.cocoa(clock.ago(days=0.1 + days * rng.random() ** 2.2, minutes=rng.uniform(0, 900)))
            if rng.random() < 0.66:
                edges.append(("relationship", target, user, "creationDate", when, domain))
            else:
                edges.append(("relationship", user, target, "creationDate", when, domain))

    def reference(domain: str, targets: list) -> None:
        ref = node("referenceIdentifier", f"{domain}:{lib.uuid_string(rng, upper=False)}")
        pair("personaIdentifier", persona, "referenceIdentifier", ref)
        for target in targets:
            edges.append(("referenceIdentifier", ref, target, "referenceIdentifier", round(rng.uniform(0.6, 1.0), 3), None))

    for person in p.people:
        weight = person.closeness if person is not world.me else 0.5
        name = node("name", person.full_name)
        key = node("nameKey", f"{_slug(person.given)}_{_slug(person.family)}", person.given, person.family)
        display = node("displayName", person.nickname if person.nickname in ("Mum", "Dad") else person.full_name)
        contact = node("contactIdentifier", person.contact_id)
        pair("name", name, "nameKey", key)
        pair("displayName", display, "name", name)
        pair("contactIdentifier", contact, "name", name)
        pair("name", name, "domainIdentifier", domains["com.apple.CalendarUI"])
        pair("contactIdentifier", contact, "domainIdentifier", domains["com.apple.reminders" if person is world.me else "com.apple.findmy" if person.favourite else "com.apple.CalendarUI"])
        mails = [node("emailAddress", e) for e in person.emails]
        phones = [node("phoneNumber", n) for n in person.phones]
        for mail in mails:
            pair("emailAddress", mail, "name", name)
            pair("emailAddress", mail, "domainIdentifier", domains["com.apple.CalendarUI"])
            dated(mail, "com.apple.CalendarUI", 2 + int(weight ** 1.6 * rng.uniform(30, 48)), 700)
        for phone in phones:
            pair("phoneNumber", phone, "name", name)
            pair("contactIdentifier", contact, "phoneNumber", phone)
            pair("phoneNumber", phone, "domainIdentifier", domains["com.apple.mobilephone"])
            dated(phone, "com.apple.mobilephone", int(weight * weight * rng.uniform(4, 30)), 400)
        dated(name, "com.apple.CalendarUI", 1 + int(weight * rng.uniform(6, 16)), 700)
        if person.favourite or person is world.me:
            dated(contact, "com.apple.findmy" if person.favourite else "com.apple.reminders", rng.randint(2, 6), 300)
        for _ in range(3 + int(weight * rng.uniform(20, 60))):
            targets = [rng.choice(mails)] + ([name] if rng.random() < 0.3 else []) + ([contact] if rng.random() < 0.08 else [])
            reference("com.apple.CalendarUI", targets)
        for phone in phones:
            for _ in range(int(weight * rng.uniform(1, 8))):
                reference("com.apple.mobilephone", [phone])

    # Organisations that sent invitations or bookings: an address and nothing else.
    senders = sorted({m.sender for m in messages if m.kind in ("invite", "travel", "notify") and not m.sender[1].endswith(tuple(e for x in p.people for e in x.emails))})
    for display_name, address in senders[:24]:
        mail = node("emailAddress", address)
        dated(mail, "com.apple.CalendarUI", rng.randint(1, 4), 500)
        reference("com.apple.CalendarUI", [mail])

    path = lib.library(root, "Metadata/CoreSpotlight/SpotlightKnowledge/index.V2/KG/kg")
    with lib.sqlite_db(path, KG_DDL) as con:
        incoming: dict[int, list] = {}
        outgoing: dict[int, list] = {}
        by_label: dict[str, tuple] = {name: ([], []) for name in labels}
        for edge_id, (label, source, target, relationship, score, domain) in enumerate(edges, 1):
            con.execute("INSERT INTO Edge VALUES (?, ?, ?, ?)", (edge_id, _bitset([label_id["domain_100"], label_id[label]]), source, target))
            con.execute("INSERT INTO EdgeValue VALUES (?, ?, NULL, NULL, ?, 3)", (edge_id, attributes["relationship"], relationship))
            con.execute("INSERT INTO EdgeValue VALUES (?, ?, NULL, ?, NULL, 2)", (edge_id, attributes["score"], float(score)))
            if domain:
                con.execute("INSERT INTO EdgeValue VALUES (?, ?, NULL, NULL, ?, 3)", (edge_id, attributes["domainIdentifier"], domain))
            outgoing.setdefault(source, []).append(edge_id)
            incoming.setdefault(target, []).append(edge_id)
            by_label[label][1].append(edge_id)
            by_label["domain_100"][1].append(edge_id)
        for node_id, (kind, value, first, last) in enumerate(nodes, 1):
            con.execute("INSERT INTO Node VALUES (?, ?, ?, ?)", (node_id, _bitset([label_id["domain_100"], label_id[kind]]),
                                                                _bitset(incoming.get(node_id, [])), _bitset(outgoing.get(node_id, []))))
            con.execute("INSERT INTO NodeValue VALUES (?, 1, NULL, NULL, ?, 3)", (node_id, value))
            if first:
                con.execute("INSERT INTO NodeValue VALUES (?, 5, NULL, NULL, ?, 3)", (node_id, first))
                con.execute("INSERT INTO NodeValue VALUES (?, 6, NULL, NULL, ?, 3)", (node_id, last))
            by_label[kind][0].append(node_id)
            by_label["domain_100"][0].append(node_id)
        for name in labels:
            con.execute("INSERT INTO Label VALUES (?, ?, ?, ?)", (label_id[name], name, _bitset(by_label[name][0]), _bitset(by_label[name][1])))
        con.executemany("INSERT INTO Attribute VALUES (?, ?)", [(i, n) for n, i in attributes.items()])
        con.execute("INSERT INTO GraphMetadata VALUES (3, '1')")
        con.execute("INSERT INTO ClientLog VALUES (1, 1)")


def _write_spotlight_files(root: pathlib.Path, world: World, counts: dict) -> None:
    rng, now, me = world.sub(), world.now, world.me
    cs = lib.library(root, "Metadata/CoreSpotlight")
    classes = ["Priority", "NSFileProtectionComplete", "NSFileProtectionCompleteUnlessOpen", "NSFileProtectionCompleteUntilFirstUserAuthentication"]
    # Opaque index files per data-protection class (the app only sizes them).
    sizes = {"Priority": 0.35, "NSFileProtectionComplete": 2.4, "NSFileProtectionCompleteUnlessOpen": 0.2, "NSFileProtectionCompleteUntilFirstUserAuthentication": 1.1}
    parts = [("0.indexHead", 0.01), ("0.indexIds", 0.06), ("0.indexPostings", 0.42), ("0.indexPositions", 0.24), ("0.indexDirectory", 0.05),
             ("0.indexGroups", 0.03), ("0.indexArrays", 0.07), ("0.directoryStoreFile", 0.1), ("live.0.indexHead", 0.01), ("live.0.indexPostings", 0.01)]
    for name in classes:
        for part, share in parts:
            lib.write_bytes(cs / name / "index.spotlightV3" / part, rng.randbytes(max(4096, int(sizes[name] * share * (1 << 20)) // 4096 * 4096)))
    for name in classes[:2]:
        lib.write_plist(cs / name / "meCardInfo.plist", {"givenname": me.given})
    lib.write_plist(cs / "PersonaList.plist", [lib.uuid_string(rng)])
    lib.write_plist(cs / "FileProviderDomains.plist", [["com.apple.CloudDocs.iCloudDriveFileProvider/" + lib.uuid_string(rng)]])
    heartbeat = {}
    for letter, name in zip("abcd", classes):
        documents = int(counts["entities"] * {"a": 0.2, "b": 2.6, "c": 0.1, "d": 1.3}[letter])
        heartbeat[f"index_{letter}"] = {
            "age": int(74 * 86400 + rng.randint(0, 9000)), "config": 3, "count_add_request": documents + rng.randint(200, 3000), "count_delete_request": rng.randint(40, 900),
            "count_drop": 0, "count_open_clean": rng.randint(30, 80), "count_open_dirty": rng.randint(0, 2), "count_queue_pressure": 0,
            "count_update_request": rng.randint(300, 5000), "max_index_gen_merge_level": rng.randint(2, 4), "max_journal_file_bytes": rng.randint(1, 9) << 18,
            "num_docids": documents, "num_file": rng.randint(28, 61), "num_index_gen_compacted": rng.randint(1, 3), "num_index_gen_non_compacted": rng.randint(0, 2),
            "num_index_gen_read_only": rng.randint(1, 3), "num_index_gen_writeable": 1, "num_journal_file": rng.randint(1, 3), "num_object_sdb": documents + rng.randint(5, 400),
            "sdb_file_size_bytes": rng.randint(2, 30) << 20, "sdb_shadow_file_size_bytes": rng.randint(1, 8) << 16, "size_bytes": int(sizes[name] * (1 << 20)),
            "time_since_defrag_end": rng.randint(4000, 500000), "time_since_defrag_start": rng.randint(500000, 600000),
            "time_since_last_open_clean": rng.randint(600, 90000), "time_since_sync_end": rng.randint(5, 600), "time_since_sync_start": rng.randint(600, 700),
        }
    lib.write_plist(cs / "heartbeat.plist", heartbeat)
    previous = {"_reportPID": rng.randint(400, 900), "_reportProcessName": "corespotlightd",
                "_reportTime": (now - datetime.timedelta(days=1, hours=3)).strftime("%Y-%m-%d-%H-%M-%S"), "age_heartbeat": 86400,
                "config_locale": "en_NZ@collation=search", "count_memory_throttle": 0, "count_thermal_throttle": 1, "data_collection_error": 0}
    for letter in "abcd":
        for key, value in heartbeat[f"index_{letter}"].items():
            previous[f"index_{letter}_{key}"] = max(0, value - rng.randint(0, 40)) if key.startswith(("count_", "num_doc")) else value
    lib.write_plist(cs / "IndexDropReports" / "spotlight_heartbeat_last.plist", previous)
    build = world.p.this_mac.os_build
    lib.write_plist(cs / "com.apple.corespotlight.receiver.suggestions.plist",
                    {"cts": ["public.email-message", "public.message", "public.calendar-event", "public.contact"], "jt": rng.randint(4000, 90000), "rcv": rng.randint(20000, 80000), "sv": build})
    for name, bundles in (("textunderstandingd", ["com.apple.mail", "com.apple.MobileSMS", "com.apple.Notes", "com.apple.reminders"]),
                          ("photos", ["com.apple.Photos"]), ("coreduet", ["com.apple.mail", "com.apple.iCal", "com.apple.Safari"])):
        lib.write_plist(cs / f"com.apple.corespotlight.receiver.{name}.plist", {"bids": bundles, "jt": rng.randint(4000, 90000), "rcv": rng.randint(20000, 80000), "sv": build})


# ----------------------------------------------------------------------------------------
# Biome streams
# ----------------------------------------------------------------------------------------

def _html(m: Message) -> str:
    paragraphs = "".join("<p>" + part.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\n", "<br>") + "</p>" for part in m.body.split("\n\n"))
    return ("<!DOCTYPE html><html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">"
            "<style>body{font-family:-apple-system,Helvetica,sans-serif;font-size:14px;line-height:1.45}</style></head>"
            f"<body>{paragraphs}</body></html>")


def _write_streams(root: pathlib.Path, world: World, messages: list) -> None:
    rng, now = world.sub(), world.now
    live = [m for m in messages if m.live]
    person = lambda pair: [(1, pair[0]), (2, pair[1])]            # noqa: E731

    # ProactiveHarvesting.Mail — the queue: recent messages, erased once consumed.
    records = []
    recent = [m for m in live if (now - m.date).days < 21 and m.mailbox == "INBOX"]
    for position, m in enumerate(recent):
        headers = [(10, [(1, name), (2, value)]) for name, values in _headers(m, world, rng) for value in values]
        payload = pb.message(
            [(1, str(m.rowid)), (2, m.domain), (3, float(lib.cocoa(m.date))), (4, m.account.uuid), (5, str(m.rowid))] + headers
            + [(11, m.subject), (13, 1), (14, _html(m))] + [(17, a) for a in sorted(world.me.emails, key=lambda a: a != m.account.address)] + [(19, box) for box in m.mailboxes]
            + [(21, m.account.kind), (23, person(m.sender))] + [(24, person(x)) for x in m.to + m.cc]
            + [(28, lib.hex_string(rng, 8)), (29, str(m.rowid)), (30, float(lib.cocoa(m.date))), (31, len(m.body)), (33, 0), (35, 0)])
        when = min(now - datetime.timedelta(seconds=2), m.date + datetime.timedelta(seconds=rng.uniform(2, 40)))
        records.append(lib.SEGBRecord(when, payload, deleted=position < len(recent) - 14))
    lib.write_stream(lib.biome_stream_dir(root, "ProactiveHarvesting.Mail"), records)

    # TextUnderstanding.Output.Document — what the pipeline has read.
    records = []
    for m in [x for x in live if (now - x.date).days < 60 and x.has_text]:
        snippet = _html(m)[:400]
        payload = pb.message(
            [(1, [(1, "com.apple.mail"), (2, m.domain), (3, str(m.rowid)), (4, 1)]), (2, float(lib.cocoa(m.date)) + rng.uniform(4, 400)),
             (3, float(lib.cocoa(m.date))), (6, rng.randint(10000, 99999)), (9, 1), (10, m.message_id), (11, m.account.uuid), (12, m.subject), (13, str(m.rowid))]
            + [(14, box) for box in reversed(m.mailboxes)] + [(15, 0), (17, snippet), (18, person(m.sender))]
            + [(19, [(2, a)]) for _, a in m.to] + [(22, m.account.kind), (23, 0)] + [(24, [(2, a)]) for _, a in m.cc] + [(25, m.to[0][1])])
        when = min(now - datetime.timedelta(seconds=1), m.date + datetime.timedelta(seconds=rng.uniform(5, 420)))
        records.append((when, payload))
    lib.write_stream(lib.biome_stream_dir(root, "TextUnderstanding.Output.Document"), records)

    # TextUnderstanding.Output.Event — events found in those documents.
    records = []
    for m in [x for x in live if x.event and (now - x.date).days < 240]:
        event = m.event
        organiser = event["organiser"]
        kind = {"invite": "icsAttachment", "flight": "structuredData", "hotel": "structuredData", "appointment": "languageModel"}[event["kind"]]
        notes = f"<b>{event['title']}</b>\n{event['where']}" + (f"\n{organiser.full_name}\n{organiser.email}" if organiser else "")
        fields = [(1, [(1, "com.apple.mail"), (2, m.domain), (3, str(m.rowid)), (4, 1)]), (2, "event"), (3, kind), (4, kind)]
        if event["kind"] == "invite":
            fields.append((5, [(26, m.attachments[0].text)]))
        fields += [(6, float(lib.unix(event["start"]))), (7, float(lib.unix(event["end"]))), (8, [(1, event["kind"])]), (13, notes), (14, event["title"]), (17, 1), (18, 1)]
        when = min(now - datetime.timedelta(seconds=1), m.date + datetime.timedelta(seconds=rng.uniform(20, 900)))
        records.append((when, pb.message(fields)))
    lib.write_stream(lib.biome_stream_dir(root, "TextUnderstanding.Output.Event"), records)

    # TextUnderstanding.Deletions.Document — every request to forget a document.
    records = []
    for m in [x for x in messages if not x.live]:
        gone = min(now - datetime.timedelta(minutes=4), m.date + datetime.timedelta(days=rng.uniform(0.3, 20)))
        if (now - gone).days < 150:
            records.append((gone, pb.message([(1, "com.apple.mail"), (3, str(m.rowid)), (4, float(lib.cocoa(gone))), (9, 1)])))
    for bundle, count, reason in (("com.apple.MobileSMS", 46, 1), ("com.apple.mobilenotes", 11, 2), ("com.apple.reminders", 19, 1), ("com.apple.Safari", 28, 3)):
        for when in world.clock.spread(rng, count, days=140, recent_bias=1.3):
            item = lib.uuid_string(rng) if bundle != "com.apple.MobileSMS" else str(rng.randint(20000, 99999))
            records.append((when, pb.message([(1, bundle), (3, item), (4, float(lib.cocoa(when))), (9, reason)])))
    lib.write_stream(lib.biome_stream_dir(root, "TextUnderstanding.Deletions.Document"), records)

    # Mail.Search.Query — what was typed into Mail's search field.
    records = []
    for when in world.clock.spread(rng, 64, days=120, hours=(8, 22), recent_bias=1.6):
        query = rng.choice(SEARCH_QUERIES)
        if rng.random() < 0.25:
            query = query[:rng.randint(3, max(3, len(query) - 1))]              # typed in steps
        records.append((when, pb.message([(1, query), (2, 0), (3, 0), (4, 0), (5, 1), (6, rng.choice([1, 2, 2])), (7, 0)])))
    lib.write_stream(lib.biome_stream_dir(root, "Mail.Search.Query"), records)


# ----------------------------------------------------------------------------------------
# iCloud key-value cache (shared container)
# ----------------------------------------------------------------------------------------

class KVS:
    """The `com.apple.kvs` databases. Shared with other generators: a database is created
    only if it is missing, and a store that already has keys anywhere is not touched."""

    def __init__(self, root: pathlib.Path, world: World):
        self.rng = world.sub()
        self.dir = lib.daemon_container(root, "com.apple.kvs", world.rng) / "com.apple.kvs"
        lib.ensure_dir(self.dir)

    def path(self, variant: str) -> pathlib.Path:
        return self.dir / f"com.apple.KeyValueService{variant}-Production.sqlite"

    def ensure(self, variant: str) -> pathlib.Path:
        path = self.path(variant)
        if not path.exists():
            with lib.sqlite_db(path, KVS_DDL) as con:
                lib.coredata_tables(con, {"SYDManagedDatabase": 1, "SYDManagedKeyValue": 2, "SYDManagedStore": 3}, self.rng)
                con.execute("INSERT INTO ZSYDMANAGEDDATABASE (Z_PK, Z_ENT, Z_OPT, ZDIDMIGRATEFROMPLISTS, ZFAILEDMIGRATIONCOUNT, ZHASPERFORMEDONETIMEDATASEPARATEDLOCALDATARESET) VALUES (1, 1, 3, 1, 0, 1)")
        return path

    def exists(self, identifier: str) -> bool:
        for path in sorted(self.dir.glob("*.sqlite")):
            con = sqlite3.connect(str(path))
            try:
                row = con.execute("SELECT count(*) FROM ZSYDMANAGEDKEYVALUE k JOIN ZSYDMANAGEDSTORE s ON s.Z_PK = k.ZSTORE WHERE s.ZIDENTIFIER = ?", (identifier,)).fetchone()
            except sqlite3.Error:
                row = None
            finally:
                con.close()
            if row and row[0]:
                return True
        return False

    def add(self, identifier: str, entries: list, variant: str = "") -> None:
        """`entries`: (key, plist value, modified datetime). Skipped when the store exists."""
        if not entries or self.exists(identifier):
            return
        con = sqlite3.connect(str(self.ensure(variant)))
        try:
            store_columns = {r[1] for r in con.execute("PRAGMA table_info(ZSYDMANAGEDSTORE)")}
            key_columns = {r[1] for r in con.execute("PRAGMA table_info(ZSYDMANAGEDKEYVALUE)")}
            row = con.execute("SELECT Z_PK FROM ZSYDMANAGEDSTORE WHERE ZIDENTIFIER = ?", (identifier,)).fetchone()
            store = row[0] if row else (con.execute("SELECT coalesce(max(Z_PK), 0) FROM ZSYDMANAGEDSTORE").fetchone()[0] + 1)
            blobs = [(key, lib.plist_bytes(value), when) for key, value, when in entries]
            if not row:
                values = {"Z_PK": store, "Z_ENT": 3, "Z_OPT": len(entries) + 1, "ZTOTALDATALENGTH": sum(len(b) for _, b, _ in blobs), "ZDATABASE": 1, "ZIDENTIFIER": identifier}
                values = {k: v for k, v in values.items() if k in store_columns}
                con.execute(f"INSERT INTO ZSYDMANAGEDSTORE ({', '.join(values)}) VALUES ({', '.join('?' for _ in values)})", list(values.values()))
            pk = con.execute("SELECT coalesce(max(Z_PK), 0) FROM ZSYDMANAGEDKEYVALUE").fetchone()[0]
            for key, blob, when in blobs:
                pk += 1
                values = {"Z_PK": pk, "Z_ENT": 2, "Z_OPT": self.rng.randint(1, 6), "ZPLISTDATALENGTH": len(blob), "ZSTORE": store,
                          "ZVALUEMODIFICATIONDATE": lib.cocoa(when), "ZKEY": key, "ZRECORDNAME": lib.uuid_string(self.rng), "ZPLISTDATAVALUE": blob}
                values = {k: v for k, v in values.items() if k in key_columns}
                con.execute(f"INSERT INTO ZSYDMANAGEDKEYVALUE ({', '.join(values)}) VALUES ({', '.join('?' for _ in values)})", list(values.values()))
            try:
                con.execute("UPDATE Z_PRIMARYKEY SET Z_MAX = (SELECT max(Z_PK) FROM ZSYDMANAGEDKEYVALUE) WHERE Z_NAME = 'SYDManagedKeyValue'")
                con.execute("UPDATE Z_PRIMARYKEY SET Z_MAX = (SELECT max(Z_PK) FROM ZSYDMANAGEDSTORE) WHERE Z_NAME = 'SYDManagedStore'")
            except sqlite3.Error:
                pass
            con.commit()
        finally:
            con.close()


def _write_kvs(root: pathlib.Path, world: World, messages: list) -> None:
    kvs = KVS(root, world)
    rng, p, me, now, clock = kvs.rng, world.p, world.me, world.now, world.clock
    for variant in ("", ".Encrypted", ".EndToEndEncrypted", ".EndToEndEncrypted.AllPlatforms"):
        kvs.ensure(variant)
    live = [m for m in messages if m.live]

    # Mail recents: everyone Robin wrote to, with the dates of the last messages.
    written: dict[tuple, list] = {}
    for m in live:
        if m.mailbox == "Sent":
            for target in m.to + m.cc:
                if target[1] not in me.emails:
                    written.setdefault((target, m.account.address), []).append(m.date)
    entries = [("MAX_RECENTS", {"m": 1000, "v": 1}, now - datetime.timedelta(days=412))]
    for ((name, address), account), dates in sorted(written.items(), key=lambda kv: kv[0][0][1] + kv[0][1]):
        dates = sorted(dates)[-8:]
        entries.append((f"MR_{lib.hex_string(rng, 40).upper()}", {"v": 1, "t": dates, "n": name, "a": address, "k": "email", "s": account, "S": "com.apple.mail"}, dates[-1]))
    partner, sister, mother = p.person("partner"), p.person("sister"), p.person("mother")
    group_dates = [clock.ago(days=d, hours=3) for d in (61, 33, 9)]
    entries.append((f"GP_{lib.hex_string(rng, 40).upper()}", {"k": "gr", "t": group_dates, "gK": 1, "S": "com.apple.mail", "v": 1, "s": world.personal.address,
                                                             "mrs": [{"n": x.full_name, "a": x.email, "k": "email"} for x in (partner, sister, mother)]}, group_dates[-1]))
    kvs.add("com.apple.mail.recents", entries)

    vips = [p.person(key) for key in VIP_KEYS]
    kvs.add("com.apple.mail.vipsenders", [(f"VIP_{lib.uuid_string(rng)}", {"n": x.full_name, "a": list(x.emails), "v": 1}, clock.ago(days=rng.uniform(200, 900))) for x in vips])

    invited = [(x, sorted(clock.ago(days=rng.uniform(1, 300)) for _ in range(rng.randint(1, 6)))) for x in p.people_with("colleague") + [p.person("manager"), partner]]
    kvs.add("com.apple.calendar.recents", [("MAX_RECENTS", {"m": 1000, "v": 1}, now - datetime.timedelta(days=412))] + [
        (f"MR_{lib.hex_string(rng, 40).upper()}", {"v": 1, "t": dates, "n": x.full_name, "a": x.email, "k": "email", "S": "com.apple.iCal"}, dates[-1]) for x, dates in invited])

    favourites = [{"Name": x.full_name, "Value": x.phone, "Label": "_$!<Mobile>!$_", "ActionType": "AudioCallActionType" if index else "MessageActionType",
                   "BundleIdentifier": "com.apple.mobilephone" if index else "com.apple.MobileSMS", "EntryType": 2} for index, x in enumerate(c for c in p.people if c.favourite and c.phone)]
    kvs.add("com.apple.contacts.favorites", [("entries", favourites, clock.ago(days=77)), ("version", 2, clock.ago(days=77))])

    blocked = [{"__kCMFItemTypeKey": 0, "__kCMFItemVersionKey": 1, "__kCMFItemPhoneNumberUnformattedKey": f"+1202555{number:04d}", "__kCMFItemPhoneNumberCountryCodeKey": "us"}
               for number in (163, 177, 191, 196)]            # the same block list the comms generator writes
    blocked += [{"__kCMFItemTypeKey": 1, "__kCMFItemVersionKey": 1, "__kCMFItemEmailUnformattedKey": address} for address in ("prizes@example.net", "winner-notice@example.com")]
    kvs.add("com.apple.cmfsyncagent", [("__kCMFBlockListStoreTopLevelKey", {"__kCMFBlockListStoreArrayKey": blocked, "__kCMFBlockListStoreRevisionKey": 7,
                                                                         "__kCMFBlockListStoreTypeKey": "_CMFBlockListType", "__kCMFBlockListStoreVersionKey": 1}, clock.ago(days=58))])

    # Mail's own stores wrap every value as {updatedAt, value}.
    senders: dict[str, list] = {}
    people = {e for x in p.people for e in x.emails if x.key != "drlee"}
    for m in live:
        if m.kind not in ("work", "personal", "invite") and m.mailbox == "INBOX" and m.sender[1] not in people:
            senders.setdefault(m.sender[1], [m.sender[0], m.kind, m.date, m.list_id])[2] = m.date
    wrap = lambda value, when: {"updatedAt": lib.unix(when), "value": value}                                # noqa: E731
    categories, unsubscribed = [], []
    seen: dict[str, dict] = {}                # one business per sending organisation
    category_code = {"bill": 1, "order": 1, "travel": 1, "code": 1, "notify": 2, "newsletter": 2, "promo": 3}
    category_name = {1: "transactions", 2: "updates", 3: "promotions"}
    for address, (name, kind, last, list_id) in sorted(senders.items()):
        host = address.split("@")[1]
        code = category_code[kind]
        organisation = name if host.count(".") < 2 or host.startswith("git.") else host.split(".")[-3]
        entry = seen.setdefault(organisation, {"id": name, "dates": {}, "last": last})
        entry["dates"][category_name[code]] = max(lib.unix(last), entry["dates"].get(category_name[code], 0))
        entry["last"] = max(entry["last"], last)
        categories.append((address, wrap({"mailbox": address, "category": code, "ls": lib.unix(last), "lsd": lib.unix(last)}, last), last))
    for kind, who in (("L", "weekly.dealsdaily.example.com"), ("L", "members.fitpass.example.net"), ("S", "survey@feedbackpanel.example.org"),
                      ("L", "updates.homeloans.example.com"), ("S", "winner-notice@example.com"), ("L", "news.oldflatmates.example.net")):
        when = clock.ago(days=rng.uniform(20, 800))
        unsubscribed.append((f"{kind}:{who}", wrap("unsubscribed", when), when))
    kvs.add("com.apple.mail.businesses", [(f"B:{_slug(key)}", wrap({"id": e["id"], "lastSeenDates": e["dates"]}, e["last"]), e["last"]) for key, e in sorted(seen.items())])
    kvs.add("com.apple.mail.mailboxCategories", categories)
    kvs.add("com.apple.mail.listUnsubscribeInfo", unsubscribed)
    remind = []
    for m in [x for x in live if x.flagged or (x.kind in ("work", "bill") and (now - x.date).days < 10)][-6:]:
        when = m.date + datetime.timedelta(hours=rng.uniform(1, 30))
        due = when + datetime.timedelta(days=rng.choice([1, 1, 2, 7]))
        remind.append((m.message_id, wrap({"date": lib.unix(due), "display-date": lib.unix(due), "message-id": m.message_id}, when), min(when, now)))
    kvs.add("com.apple.mail.remindMe", remind)

    # Known Wi-Fi networks (the persona's), synced end-to-end encrypted.
    networks = []

    def added_by(device) -> str:
        # "<system>.<version with underscores>.<build>.<model, lower case>.<n>"
        system = "macos" if device.kind == "Mac" else "iphoneos"
        return f"{system}.{device.os_version.replace('.', '_')}.{device.os_build}.{device.model.lower()}.2"

    for number, network in enumerate(p.networks):
        added = clock.ago(days=900 - number * 170 + rng.uniform(0, 30))
        joined = clock.ago(days=rng.uniform(0.1, 3) if network.place in ("home", "work") else rng.uniform(8, 200))
        value = {"SSID": network.ssid, "addedAt": lib.cocoa(added), "lastJoinedByUserAt": lib.cocoa(joined), "addedByVersion": added_by(p.this_mac if number % 2 else p.device("iphone")),
                 "isWPA3": "WPA3" in network.security, "isWPA2": "WPA2" in network.security, "isEnterprise": "Enterprise" in network.security,
                 "isOpen": network.security == "Open", "isCaptive": network.security == "Open", "isPersonalHotspot": "iPhone" in network.ssid,
                 "isAutoJoinEnabled": network.security != "Open", "lowDataMode": "iPhone" in network.ssid}
        if network.security == "Open":
            value["removedAt"] = lib.cocoa(clock.ago(days=5))
        networks.append((f"network.{network.ssid}", value, joined))
    kvs.add("com.apple.wifi.syncable-networks", networks, variant=".EndToEndEncrypted")

    # A few plain app stores (layouts invented: small preferences an app would sync).
    kvs.add("com.apple.weather", [("cities", [{"name": c, "country": "New Zealand"} for c in ("Wellington", "Paraparaumu", "Queenstown", "Auckland", "Rotorua")], clock.ago(days=21)),
                                  ("temperatureUnit", "celsius", clock.ago(days=600))])
    kvs.add("com.apple.iBooks", [("readingGoalMinutes", 20, clock.ago(days=300)), ("lastOpenedTitle", "A Field Guide to the Birds of Aotearoa", clock.ago(days=2)),
                                 ("finishedThisYear", 14, clock.ago(days=2))])
    kvs.add("com.apple.Maps", [("recentSearches", [x.name for x in (p.place("cafe"), p.place("te_papa"), p.place("gym"), p.place("airport"), p.place("zealandia"))], clock.ago(days=1)),
                               ("preferredTransport", "walking", clock.ago(days=420))])
    kvs.add("com.apple.stocks", [("watchlist", ["^NZ50", "^AORD", "NZDUSD=X"], clock.ago(days=90))])
    for bundle, values in (("notion.id", [("lastWorkspace", "Kōwhai Labs — Design"), ("sidebarCollapsed", False), ("theme", "system")]),
                           ("com.figma.Desktop", [("recentFiles", ["Settings redesign v3", "Design system 2.0", "Onboarding flow"]), ("nudgeAmount", 8)])):
        team = "".join(rng.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(10))
        kvs.add(f"{team}.{bundle}", [(key, value, clock.ago(days=rng.uniform(1, 200))) for key, value in values])


# ----------------------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------------------

def generate(root: pathlib.Path, persona: Persona, rng: random.Random, now: datetime.datetime) -> None:
    """Create this module's stores below `root`."""
    clock = lib.Clock(now, persona.tz_offset_hours)
    world = World(persona, rng, clock)
    world.vips = {e for key in VIP_KEYS for e in persona.person(key).emails}
    messages = Corpus(world).build()
    counts = _write_mail_sets(root, world, messages)
    _write_other_sets(root, world)
    _write_hybrid_search(root, world, messages)
    _write_document_processing(root, world, messages)
    _write_knowledge_graph(root, world, messages)
    _write_spotlight_files(root, world, counts)
    _write_streams(root, world, messages)
    _write_kvs(root, world, messages)
