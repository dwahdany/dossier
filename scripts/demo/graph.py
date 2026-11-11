"""Demo data for the Knowledge Graph module (`graph`): everything under
`~/Library/IntelligencePlatform` that `Sources/GraphModule` reads.

* `graph.db` — `stable_graph` (the persona's people, places, employer, family group, apps
  and their developers, a few life / music / ticket events), `event_graph` (calendar
  events around today), `expired_*` (superseded facts), `graph_state`, `phase_status`;
* `ontology.db` — class and predicate labels, inheritance, domains, ranges;
* `Artifacts/…` — entity tagging, importance signals, relevance inferences, the feature
  store, the internal views (interaction logs, handle / alias / Photos-person maps),
  language inference, entity summaries, source-confidence priors, life-event maps and
  first-party topics;
* `views.db`, `keyvalue.db`, `aliases.db`, `globalKnowledge.db`.

Shared with other modules: `Artifacts/firstPartyTopics/*.db` is also listed by the
`profile` module. This generator creates those two files only if they do not exist yet
and never touches `Artifacts/siri/` (owned by `comms`).

Format notes (from the DDL and the readers in Sources/GraphModule, never from rows):

* A node is every row sharing a `subject` (18-digit integer). `object` is text; a link to
  another node is `md:<subject>`.
* Simple statement: `relationshipId = 0`, `relationshipPredicate = ''`.
* Facet: several rows sharing a non-zero 64-bit `relationshipId`; `relationshipPredicate`
  names the field and one row with `relationshipPredicate = 'PS1'` gives the facet's
  relationship-type class (`CS97` contact / address, `CS29` location, `CS165` employment,
  `CS168` association, `CS166` group, `CS22` identifier, `CS38` participation).
* `sources` is a bit mask of the feeding systems; `sourceDuplicates` lists the source
  records joined by `^^`, each `<kind>:<identifier>`. Bit → kind as on current macOS:
  0 cnContact, 5 phPerson, 8 ekEvent, 13 faFamilyCircle, 15 lsBundleRecord, 28 pgRelationship.
* `timestamp` is Cocoa seconds; dates inside objects are JSON date components.

Invented where the real value is unknown to this generator (structure only was looked
at): source bits 20–22 and their kinds (`lifeEvent`, `bmAppleMusicEvent`, `pkPass`), the
`behaviorType` of location events, the identifiers of Wi-Fi / location context events,
`people_relationship` rows, schedule states other than `needsUpdate`, all numeric values.

Other generators that need the same Photos person identifier for a persona member can
call `photos_person_uuid(persona, person)`.
"""

from __future__ import annotations

import datetime
import json
import pathlib
import random

from . import lib
from .persona import Persona, Person, Place

UTC = datetime.timezone.utc

# ----------------------------------------------------------------------------------------
# DDL
# ----------------------------------------------------------------------------------------

GRAPH_TABLE = """
CREATE TABLE "{name}" ("subject" INTEGER NOT NULL,
                       "predicate" TEXT NOT NULL,
                       "relationshipId" INTEGER NOT NULL,
                       "relationshipPredicate" TEXT NOT NULL,
                       "object" TEXT NOT NULL,
                       "sources" INTEGER NOT NULL,
                       "confidence" DOUBLE NOT NULL,
                       "sourceDuplicates" TEXT NOT NULL,
                       "timestamp" DOUBLE NOT NULL,
                       PRIMARY KEY ("subject", "predicate", "relationshipId", "relationshipPredicate", "object")
                       ON CONFLICT ABORT);
"""

EXPIRED_TABLE = """
CREATE TABLE "{name}" ("subject" INTEGER NOT NULL,
                       "predicate" TEXT NOT NULL,
                       "relationshipId" INTEGER NOT NULL,
                       "relationshipPredicate" TEXT NOT NULL,
                       "object" TEXT NOT NULL,
                       "sources" INTEGER NOT NULL,
                       "confidence" DOUBLE NOT NULL,
                       "sourceDuplicates" TEXT NOT NULL,
                       "timestamp" DOUBLE NOT NULL);
"""

GRAPH_DDL = (
    GRAPH_TABLE.format(name="stable_graph") + GRAPH_TABLE.format(name="event_graph")
    + EXPIRED_TABLE.format(name="expired_stable_graph") + EXPIRED_TABLE.format(name="expired_event_graph")
    + """
CREATE INDEX "stable_graph_object_index" ON "stable_graph"("object");
CREATE INDEX "stable_graph_predicate_object_index" ON "stable_graph"("predicate", "object");
CREATE INDEX "stable_graph_timestamp_index" ON "stable_graph"("timestamp");
CREATE INDEX "event_graph_object_index" ON "event_graph"("object");
CREATE INDEX "event_graph_predicate_object_index" ON "event_graph"("predicate", "object");
CREATE INDEX "event_graph_timestamp_index" ON "event_graph"("timestamp");
CREATE TABLE "schemaMetadata" ("key" TEXT PRIMARY KEY ON CONFLICT REPLACE NOT NULL, "value" BLOB NOT NULL);
CREATE TABLE "graph_state" ("key" TEXT PRIMARY KEY ON CONFLICT REPLACE, "value" ANY);
CREATE TABLE "phase_status" ("source" INTEGER NOT NULL, "status" INTEGER NOT NULL, PRIMARY KEY ("source") ON CONFLICT REPLACE);
CREATE TABLE "blocks" ("blockingKey" TEXT NOT NULL, "pipelineType" INTEGER NOT NULL, "entityClass" TEXT NOT NULL,
                       "entityIds" TEXT NOT NULL, "timestamp" DOUBLE NOT NULL,
                       PRIMARY KEY ("blockingKey", "pipelineType", "entityClass") ON CONFLICT ABORT);
CREATE TABLE "pairs" ("entityClass" TEXT NOT NULL, "sourceId" INTEGER NOT NULL, "targetId" INTEGER NOT NULL,
                      "targetIsGraphId" BOOL NOT NULL, "timestamp" DOUBLE NOT NULL, "pipelineType" INTEGER NOT NULL,
                      PRIMARY KEY ("entityClass", "sourceId", "targetId", "pipelineType") ON CONFLICT ABORT);
CREATE TABLE "matches" ("entityClass" TEXT NOT NULL, "sourceId" INTEGER NOT NULL, "targetId" INTEGER NOT NULL,
                        "confidence" DOUBLE NOT NULL, "timestamp" DOUBLE NOT NULL, "pipelineType" INTEGER NOT NULL,
                        "metadata" TEXT,
                        PRIMARY KEY ("entityClass", "sourceId", "targetId", "pipelineType") ON CONFLICT ABORT);
"""
)

ONTOLOGY_DDL = """
CREATE TABLE "class" ("id" TEXT, "label" TEXT, PRIMARY KEY ("id") ON CONFLICT REPLACE);
CREATE TABLE "inheritance" ("child" TEXT, "parent" TEXT, PRIMARY KEY ("child", "parent") ON CONFLICT REPLACE);
CREATE TABLE "predicate" ("id" TEXT, "label" TEXT, "maxCount" INTEGER, PRIMARY KEY ("id") ON CONFLICT REPLACE);
CREATE TABLE "predicate_domain" ("predicateId" TEXT, "domain" TEXT, PRIMARY KEY ("predicateId", "domain") ON CONFLICT REPLACE);
CREATE TABLE "predicate_range" ("predicateId" TEXT, "dataType" TEXT, "range" TEXT, PRIMARY KEY ("predicateId", "dataType", "range") ON CONFLICT REPLACE);
CREATE TABLE "relationship_type" ("relationshipType" TEXT, "objectType" TEXT, "objectClass" TEXT, PRIMARY KEY ("relationshipType") ON CONFLICT REPLACE);
CREATE TABLE "version" ("fileName" TEXT, "versionNum" TEXT, "compatibility" TEXT, PRIMARY KEY ("fileName") ON CONFLICT REPLACE);
CREATE INDEX "inheritance_parent" ON "inheritance"("parent");
"""

SUBGRAPH = ('CREATE TABLE "{name}" ("subject" INTEGER, "predicate" TEXT, "relationshipId" INTEGER, "relationshipPredicate" TEXT, '
            '"object" TEXT, PRIMARY KEY ("subject", "predicate", "relationshipId", "relationshipPredicate", "object") ON CONFLICT REPLACE);\n')
EVENTS = ('CREATE TABLE "{name}" ("behaviorType" INTEGER NOT NULL, "behaviorIdentifier" TEXT NOT NULL, "timestamp" REAL NOT NULL, '
          '"timeSincePreviousEvent" REAL);\n')
HISTOGRAMS = ('CREATE TABLE "{name}Histograms" ("type" INTEGER NOT NULL, "behaviorType" INTEGER NOT NULL, "data" BLOB NOT NULL, UNIQUE ("type", "behaviorType"));\n'
              'CREATE TABLE "{name}HistogramKeys" ("behaviorIdentifier" TEXT NOT NULL UNIQUE);\n')
MECHANISMS = ('CREATE TABLE "{name}" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "entityIdentifier" TEXT NOT NULL, "interactionDate" DOUBLE NOT NULL, '
              '"communicationMechanism" INTEGER, "bundleID" TEXT);\n')
ALIAS = ('CREATE TABLE "{name}" ("MD_ID" INTEGER, "alias" TEXT, "entity_type" TEXT, "signal_type" TEXT, "confirmation_confidence" DOUBLE, '
         'PRIMARY KEY ("MD_ID", "alias", "signal_type") ON CONFLICT REPLACE);\n')

TAGGING_LABELS = ["mother", "father", "parent", "sister", "brother", "sibling", "family", "friend", "familyAndFriends",
                  "partner", "coworker", "alumni", "child", "son", "daughter", "myself", "unknown"]

TAGGING_DDL = (
    'CREATE TABLE "entity_tagging" ("mdid" TEXT NOT NULL, '
    + ", ".join(f'"{label}" DOUBLE NOT NULL' for label in TAGGING_LABELS)
    + ', "eventid" INTEGER NOT NULL, PRIMARY KEY ("mdid") ON CONFLICT REPLACE);\n'
    + SUBGRAPH.format(name="has_association_subgraph")
    + 'CREATE INDEX "has_association_subgraph_object_predicate_subject_idx" ON "has_association_subgraph"("object", "predicate", "subject");\n'
)

IMPORTANCE_DDL = """
CREATE TABLE "entityImportanceSignalsIDMap" ("entityIdentifier" INTEGER, "isFavorite" BOOLEAN, "isEmergencyContact" BOOLEAN,
    "isICloudFamily" BOOLEAN, "relationshipLabel" TEXT, PRIMARY KEY ("entityIdentifier") ON CONFLICT REPLACE);
"""

RELEVANCE_DDL = "".join(
    f'CREATE TABLE "{name}" ("mdid" TEXT NOT NULL, "relevanceScore" DOUBLE NOT NULL, "explanation" TEXT NOT NULL, '
    f'"inferenceEventId" INTEGER NOT NULL, PRIMARY KEY ("mdid") ON CONFLICT REPLACE);\n'
    for name in ("person_entity_relevance", "person_entity_longterm", "loi_entity_relevance"))

FEATURES_DDL = (
    'CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);\n'
    'CREATE TABLE "kv" ("viewName" TEXT NOT NULL, "featureName" TEXT NOT NULL, "subidentifierName" TEXT NOT NULL, "value" BLOB NOT NULL, '
    '"confidence" DOUBLE, PRIMARY KEY ("viewName", "featureName", "subidentifierName") ON CONFLICT REPLACE);\n'
    + SUBGRAPH.format(name="location_subgraph_features"))

INTERNAL_VIEWS_DDL = (
    ALIAS.format(name="entity_alias")
    + 'CREATE TABLE "handle_id" ("handle" TEXT, "id" INTEGER, PRIMARY KEY ("handle", "id") ON CONFLICT REPLACE);\n'
    + 'CREATE TABLE "phperson_id_map" ("phPersonIdentifier" TEXT, "id" INTEGER, PRIMARY KEY ("phPersonIdentifier") ON CONFLICT REPLACE);\n'
    + "".join(EVENTS.format(name=n) for n in (
        "coarseGeoHashContextEvents", "loiContextEvents", "wifiContextEvents", "specificGeoHashContextEvents",
        "personEntityInteractionEvents", "loiEntityInteractionEvents", "photosPersonEntityInteractionEvents",
        "bidirectionalPersonEntityInteractionEvents"))
    + "".join(HISTOGRAMS.format(name=n) for n in ("personEntity", "loiEntity", "photosPersonEntity", "bidirectionalPersonEntity"))
    + MECHANISMS.format(name="personInteractionMechanisms") + MECHANISMS.format(name="bidirectionalPersonInteractionMechanisms")
    + 'CREATE TABLE "photosObservedAges" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "entityIdentifier" TEXT NOT NULL, "interactionDate" DOUBLE NOT NULL, "observedAge" INTEGER);\n'
    + 'CREATE TABLE "people_relationship" ("subject" INTEGER, "relation" TEXT, "relationAlias" TEXT);\n'
    + "".join(SUBGRAPH.format(name=n) for n in ("people_subgraph", "entity_subgraph", "app_subgraph", "event_subgraph"))
    + 'CREATE INDEX "people_subgraph_object_predicate_subject_idx" ON "people_subgraph"("object", "predicate", "subject");\n'
    + 'CREATE INDEX "entity_subgraph_object_predicate_subject_idx" ON "entity_subgraph"("object", "predicate", "subject");\n'
    + 'CREATE INDEX "app_subgraph_object_predicate_subject_idx" ON "app_subgraph"("object", "predicate", "subject");\n'
)

LANGUAGES_DDL = """
CREATE TABLE "languages" ("subject" INTEGER, "predicate" INTEGER, "relationshipId" INTEGER, "relationshipPredicate" INTEGER,
    "object" TEXT, "score" DOUBLE, "sources" INTEGER, "timestamp" DOUBLE,
    PRIMARY KEY ("subject", "predicate", "relationshipId", "relationshipPredicate", "object") ON CONFLICT REPLACE);
"""

ECR_DDL = (
    ALIAS.format(name="entity_alias_ecr")
    + 'CREATE TABLE "asr_entity_alias" ("MD_ID" INTEGER, "alias" TEXT, "entity_type" TEXT, "signal_type" TEXT, "contact_identifier" TEXT, '
      'PRIMARY KEY ("MD_ID", "signal_type", "contact_identifier") ON CONFLICT REPLACE);\n'
    + 'CREATE TABLE "kv" ("viewName" TEXT, "featureName" TEXT, "subidentifierName" TEXT, "value" BLOB, '
      'PRIMARY KEY ("viewName", "featureName", "subidentifierName") ON CONFLICT REPLACE);\n'
    + 'CREATE TABLE "entity_summary" ("MD_ID" INTEGER, "entity_type" TEXT, "primary_name" TEXT, "first_name" TEXT, "middle_name" TEXT, '
      '"family_name" TEXT, "alias" TEXT, "location_name" TEXT, "event_name" TEXT, "neighbor_signals" TEXT, "entity_relevance" DOUBLE, '
      '"er_inference_event_id" INTEGER, PRIMARY KEY ("MD_ID") ON CONFLICT REPLACE);\n')

CONFIDENCE_DDL = ('CREATE TABLE "sourceConfidence" ("sourceConfidenceType" TEXT, "source" TEXT, "signalType" TEXT, "confidence" DOUBLE, '
                  'PRIMARY KEY ("source", "signalType") ON CONFLICT REPLACE);\n')


def event_map_ddl(name: str) -> str:
    return (f'CREATE TABLE "{name}_map" ("subject" INTEGER, "starttime" DOUBLE, "endtime" DOUBLE, PRIMARY KEY ("subject") ON CONFLICT REPLACE);\n'
            + SUBGRAPH.format(name=f"{name}_subgraph"))


TOPICS_DDL = 'CREATE TABLE "topics" ("topicId" TEXT, "score" DOUBLE, "most_recent_documentId" TEXT, PRIMARY KEY ("topicId") ON CONFLICT REPLACE);\n'

VIEWS_DDL = """
CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
CREATE TABLE "keyValue" ("key" TEXT PRIMARY KEY ON CONFLICT REPLACE, "value" TEXT) WITHOUT ROWID;
CREATE TABLE "updateQueue" ("schedule" INTEGER, "viewOrderedId" INTEGER, PRIMARY KEY ("schedule", "viewOrderedId") ON CONFLICT IGNORE) WITHOUT ROWID;
CREATE TABLE "viewConfigRecord" ("id" INTEGER PRIMARY KEY, "name" TEXT, "configHash" TEXT, "generationType" TEXT, "customType" TEXT,
    "updateGroup" TEXT, "writeToStream" BOOLEAN, "artifactType" TEXT, "artifactPath" TEXT, "artifactTable" TEXT,
    "viewUpdateDependencies" TEXT, "viewUpdateDependents" TEXT, "config" TEXT, "target" TEXT);
CREATE UNIQUE INDEX "viewConfigRecord_name_idx" ON "viewConfigRecord"("name");
CREATE TABLE "viewState" ("viewOrderedId" INTEGER PRIMARY KEY, "enabledStatus" INTEGER, "attemptCount" INTEGER, "errorMessage" TEXT,
    "options" BOOLEAN, "tablesCreated" BOOLEAN, "diffType" TEXT, "bookmark" BLOB);
CREATE TABLE "viewTables" ("viewOrderedId" INTEGER, "tableName" TEXT);
CREATE TABLE "scheduleState" ("schedule" TEXT PRIMARY KEY, "updateState" TEXT, "startView" INTEGER) WITHOUT ROWID;
CREATE TABLE "sourceState" ("sourceId" INTEGER PRIMARY KEY, "sourceType" TEXT, "sourceIdentifier" TEXT, "updateType" TEXT,
    "modifiedTimestamp" DOUBLE, "available" BOOLEAN, "lastQueriedSourceData" BLOB);
CREATE UNIQUE INDEX "sourceState_idx" ON "sourceState"("sourceType", "sourceIdentifier", "updateType");
"""

KEYVALUE_DDL = """
CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
CREATE TABLE "keyvalue" ("domain" TEXT, "key" TEXT, "value" BLOB, PRIMARY KEY ("domain", "key") ON CONFLICT REPLACE);
"""

GLOBAL_DDL = """
CREATE TABLE "schemaMetadata" ("key" TEXT PRIMARY KEY ON CONFLICT REPLACE NOT NULL, "value" BLOB NOT NULL);
CREATE TABLE "static_assets" ("id" INTEGER PRIMARY KEY, "name" TEXT NOT NULL, "version" INTEGER NOT NULL, "type" TEXT NOT NULL, "featureFlag" TEXT);
CREATE INDEX "static_assets_name_index" ON "static_assets"("name");
CREATE TABLE "static_graph" ("assetId" INTEGER NOT NULL, "subject" INTEGER NOT NULL, "predicate" TEXT NOT NULL,
    "relationshipId" INTEGER NOT NULL, "relationshipPredicate" TEXT NOT NULL, "object" TEXT NOT NULL, "confidence" DOUBLE NOT NULL,
    PRIMARY KEY ("subject", "predicate", "relationshipId", "relationshipPredicate", "object") ON CONFLICT ABORT,
    FOREIGN KEY(assetId) REFERENCES static_assets(id));
CREATE INDEX "static_graph_asset_index" ON "static_graph"("assetId");
CREATE INDEX "static_graph_object_index" ON "static_graph"("object");
CREATE INDEX "static_graph_predicate_object_index" ON "static_graph"("predicate", "object");
CREATE TABLE "live_graph" ("subject" INTEGER NOT NULL, "predicate" TEXT NOT NULL, "relationshipId" INTEGER NOT NULL,
    "relationshipPredicate" TEXT NOT NULL, "object" TEXT NOT NULL, "ttlTimestamp" DOUBLE NOT NULL, "timestamp" DOUBLE NOT NULL,
    "clients" INTEGER NOT NULL,
    PRIMARY KEY ("subject", "predicate", "relationshipId", "relationshipPredicate", "object") ON CONFLICT REPLACE);
"""

# ----------------------------------------------------------------------------------------
# Ontology vocabulary: codes and labels of the system ontology for everything written
# below (generic schema, the same on every Mac — not personal data).
# ----------------------------------------------------------------------------------------

CLASSES = {
    "SB56": "entity", "SB198": "agent", "SB193": "organism", "SB104": "person", "SB10": "organization",
    "SB175": "group", "SB2": "group of humans", "SB51": "work", "SB144": "software", "SB152": "place",
    "SB400": "occurrence", "SB65": "event", "SB472": "calendar event",
    "CS1": "relationship type", "CS13": "membership relationship type", "CS165": "employment relationship type",
    "CS166": "group relationship type", "CS168": "agent affiliation relationship type", "CS22": "identifier relationship type",
    "CS29": "location relationship type", "CS38": "participation relationship type", "CS97": "address relationship type",
    "nm_dateRelationshipType": "date relationship type",
    "nm_entityAliasRelationshipType": "entity alias relationship type",
    "nm_visualIdentifierRelationshipType": "visual identifier relationship type",
}

INHERITANCE = [
    ("SB198", "SB56"), ("SB193", "SB56"), ("SB104", "SB193"), ("SB104", "SB198"), ("SB10", "SB198"), ("SB175", "SB56"),
    ("SB2", "SB175"), ("SB51", "SB56"), ("SB144", "SB51"), ("SB152", "SB56"), ("SB400", "SB56"), ("SB65", "SB400"),
    ("SB472", "SB65"), ("CS1", "SB56"), ("CS13", "CS1"), ("CS165", "CS13"), ("CS166", "CS1"), ("CS168", "CS1"),
    ("CS22", "CS1"), ("CS29", "CS1"), ("CS38", "CS1"), ("CS97", "CS1"), ("nm_dateRelationshipType", "CS1"),
    ("nm_visualIdentifierRelationshipType", "CS1"), ("nm_entityAliasRelationshipType", "CS1"),
]

RELATIONSHIP_TYPES = [
    ("CS22", "non-class", "string"), ("CS13", "non-class", "string"), ("CS29", "class", "SB152"), ("CS38", "class", "SB104"),
    ("CS165", "class", "SB10"), ("CS168", "class", "SB104"), ("CS166", "class", "SB104"), ("CS97", "class", "SB10"),
    ("nm_dateRelationshipType", "non-class", "dateTime"), ("nm_visualIdentifierRelationshipType", "class", "nm_hasVisualIdentifier"),
]

_ANY = ("SB56",)
_AGENT = ("SB104", "SB10", "SB198")
_HUMAN = ("SB104", "SB193")
_EVENT = ("SB65", "SB472")

# id: (label, maxCount, domain classes, (dataType, range))
PREDICATES = {
    "PS1": ("is a", None, _ANY, ("class", "SB56")),
    "PS33": ("name", None, _ANY, ("non-class", "string")),
    "PS102": ("same as", None, _ANY, ("class", "SB56")),
    "PS312": ("first name", None, _HUMAN, ("non-class", "string")),
    "PS441": ("family name", None, _HUMAN, ("non-class", "string")),
    "PS546": ("middle name", None, _HUMAN, ("non-class", "string")),
    "PS545": ("name prefix", None, _HUMAN, ("non-class", "string")),
    "PS89": ("also known as", None, _ANY, ("non-class", "string")),
    "PS72": ("identifier", None, _ANY, ("class", "CS22")),
    "PS396": ("identifier type", None, ("CS22", "nm_entityAliasRelationshipType"), ("non-class", "string")),
    "PS69": ("identifier id", None, ("CS22", "nm_entityAliasRelationshipType"), ("non-class", "string")),
    "PS313": ("username", None, ("CS22", "SB104"), ("non-class", "string")),
    "PS66": ("source URL", None, ("CS22",), ("non-class", "string")),
    "PS520": ("has contact information", None, ("SB104",), ("class", "CS97")),
    "PS406": ("email address", None, _AGENT + ("CS97",), ("non-class", "string")),
    "PS407": ("phone number", None, _AGENT + ("CS97",), ("non-class", "string")),
    "PS740": ("contact label", None, ("SB104", "CS97"), ("non-class", "string")),
    "PS317": ("has address", None, _AGENT + ("SB152",), ("class", "CS97")),
    "PS316": ("full street address", None, ("CS97",), ("non-class", "string")),
    "PS453": ("city", None, ("CS97",), ("non-class", "string")),
    "PS315": ("postal code", None, ("SB152", "CS97"), ("non-class", "string")),
    "PS450": ("address country", None, ("CS97",), ("non-class", "string")),
    "PS455": ("administrative district", None, ("CS97",), ("non-class", "string")),
    "PS454": ("country code ISO 3166-1 alpha-2", None, ("CS97",), ("non-class", "string")),
    "PS568": ("sub administrative area", None, ("CS97",), ("non-class", "string")),
    "PS569": ("sub locality", None, ("CS97",), ("non-class", "string")),
    "PS225": ("has location relationship", None, _ANY, ("class", "CS29")),
    "PS107": ("has location", None, ("CS29",), ("identifier", "SB152")),
    "PS733": ("personalized label", None, ("CS29", "CS97"), ("non-class", "string")),
    "PS573": ("has latitude/longitude", None, ("SB152",), ("class", "CS29")),
    "PS571": ("latitude", None, ("CS29",), ("non-class", "string")),
    "PS572": ("longitude", None, ("CS29",), ("non-class", "string")),
    "PS598": ("has association", None, _AGENT, ("class", "CS168")),
    "PS500": ("employer", None, ("SB104",), ("class", "CS165")),
    "PS45": ("member of", None, ("CS13", "CS165"), ("class", "SB198")),
    "PS753": ("group includes individual", None, ("SB175", "SB2"), ("class", "CS166")),
    "PS566": ("group has part", None, ("CS166",), ("class", "SB56")),
    "PS194": ("published by", None, ("SB51", "SB144"), ("class", "SB10")),
    "PS37": ("date of birth", None, _HUMAN, ("non-class", "dateTime")),
    "PS296": ("URL", None, _ANY, ("non-class", "string")),
    "PS51": ("description", None, _ANY, ("non-class", "string")),
    "PS232": ("has attendee", None, ("SB400",) + _EVENT, ("class", "CS38")),
    "PS578": ("has organizer", None, _EVENT, ("class", "CS38")),
    "PS143": ("attendee identifier", None, ("CS38",), ("identifier", "SB104")),
    "PS734": ("participant obligation", None, ("CS38",), ("non-class", "string")),
    "PS29": ("start time", None, _ANY, ("non-class", "dateTime")),
    "PS30": ("end time", None, _ANY, ("non-class", "dateTime")),
    "nm_isCurrentUser": ("is current user", 1, ("SB104", "CS38"), ("non-class", "number")),
    "nm_bundleID": ("bundle id", None, ("SB104", "SB144"), ("non-class", "string")),
    "nm_applicationIdentifier": ("application identifier", None, ("SB144",), ("non-class", "string")),
    "nm_teamIdentifier": ("team identifier", None, ("SB10",), ("non-class", "string")),
    "nm_personIdentifier": ("person identifier", None, ("CS168",), ("identifier", "SB104")),
    "nm_relationshipLabel": ("relationship label", None, ("CS168",), ("non-class", "string")),
    "nm_unlocalizedRelationshipLabel": ("unlocalized relationship label", None, ("CS168",), ("non-class", "string")),
    "nm_confidence": ("confidence", None, ("SB152", "CS168"), ("non-class", "string")),
    "nm_entityAliasRelationship": ("entity alias relationship", None, _ANY, ("string", "nm_entityAliasRelationshipType")),
    "nm_signalLabel": ("signal label", None, _ANY, ("non-class", "string")),
    "nm_confirmationConfidence": ("confirmation confidence", None, ("nm_entityAliasRelationshipType",), ("non-class", "string")),
    "nm_hasVisualIdentifier": ("has visual identifier", None, ("SB104",), ("class", "nm_visualIdentifierRelationshipType")),
    "nm_visualIdentifier": ("visual identifier", None, ("nm_visualIdentifierRelationshipType",), ("non-class", "string")),
    "nm_associationReason": ("association reason", None, ("nm_visualIdentifierRelationshipType",), ("non-class", "string")),
    "nm_personType": ("person type", None, ("SB104",), ("non-class", "string")),
    "nm_photosDetectionType": ("photos detection type", None, ("SB104",), ("non-class", "string")),
    "nm_age": ("age", None, _ANY, ("non-class", "number")),
    "nm_familyMemberType": ("family member type", None, ("SB104",), ("non-class", "string")),
    "nm_imputedBirthday": ("imputed date of birth", None, _HUMAN, ("non-class", "dateTime")),
    "nm_hasDate": ("has date", None, _EVENT, ("class", "nm_dateRelationshipType")),
    "nm_imputedStartTime": ("imputed start time", None, _ANY, ("non-class", "dateTime")),
    "nm_imputedEndTime": ("imputed end time", None, _ANY, ("non-class", "dateTime")),
    "nm_occurrenceDate": ("occurrence date", None, _EVENT + ("nm_dateRelationshipType",), ("non-class", "dateTime")),
    "nm_imputedOccurrenceDate": ("imputed occurrence date", None, _EVENT + ("nm_dateRelationshipType",), ("non-class", "dateTime")),
    "nm_isAllDay": ("is all day", None, _EVENT, ("non-class", "number")),
    "nm_virtualConferenceURL": ("virtual conference URL", None, _EVENT, ("non-class", "string")),
    "nm_localeIdentifier": ("locale identifier", None, _ANY, ("non-class", "string")),
    "nm_sourceType": ("source type", None, _EVENT + ("SB152",), ("non-class", "string")),
    "nm_reading_confidence": ("reading confidence", None, ("SB152", "CS168"), ("non-class", "string")),
    "nm_writing_confidence": ("writing confidence", None, ("SB152", "CS168"), ("non-class", "string")),
    "nm_listening_confidence": ("listening confidence", None, ("SB152", "CS168"), ("non-class", "string")),
}

# Bit → source record kind. 0–28 as on current macOS; 20–22 are this generator's invention.
SOURCE_BITS = {"cnContact": 0, "phPerson": 5, "ekEvent": 8, "faFamilyCircle": 13, "lsBundleRecord": 15,
               "lifeEvent": 20, "bmAppleMusicEvent": 21, "pkPass": 22, "pgRelationship": 28}
PHASE_COUNT = 30


def source_mask(*kinds: str) -> int:
    mask = 0
    for kind in kinds:
        mask |= 1 << SOURCE_BITS[kind]
    return mask


def ref(node_id: int) -> str:
    return f"md:{node_id}"


def photos_person_uuid(persona: Persona, person: Person) -> str:
    """The Photos person (PHPerson) local-identifier UUID of a persona member — derived from
    the persona seed and the person's key, so any generator can compute the same one."""
    return lib.uuid_string(random.Random(f"dossier-demo-phperson-{persona.seed}-{person.key}"))


# ----------------------------------------------------------------------------------------
# Graph writer
# ----------------------------------------------------------------------------------------

class GraphWriter:
    """Collects graph rows. `simple()` adds a plain statement — the same statement from a
    second source merges into the first (sources OR-ed, records joined), as the real
    pipeline does. `facet()` adds a group of rows sharing a fresh relationship id."""

    def __init__(self, rng: random.Random):
        self.rng = rng
        self.rows: list[list] = []
        self._simple: dict[tuple, int] = {}
        self._by_subject: dict[int, list[list]] = {}

    def _append(self, row: list) -> None:
        self.rows.append(row)
        self._by_subject.setdefault(row[0], []).append(row)

    def simple(self, subject: int, predicate: str, obj: str, *, sources: int, records: list[str],
               when: float, confidence: float = 1.0) -> None:
        key = (subject, predicate, str(obj))
        at = self._simple.get(key)
        if at is not None:
            row = self.rows[at]
            row[5] |= sources
            known = row[7].split("^^") if row[7] else []
            row[7] = "^^".join(known + [r for r in records if r not in known])
            row[8] = max(row[8], when)
            return
        self._simple[key] = len(self.rows)
        self._append([subject, predicate, 0, "", str(obj), sources, confidence, "^^".join(records), when])

    def facet(self, subject: int, predicate: str, type_class: str, fields: list[tuple[str, str]], *,
              sources: int, records: list[str], when: float, confidence: float = 1.0) -> int:
        relationship_id = self.rng.randrange(-(1 << 62), 1 << 62) or 1
        for field, value in [("PS1", type_class)] + [f for f in fields if f[1] is not None and f[1] != ""]:
            self._append([subject, predicate, relationship_id, field, str(value), sources, confidence,
                          "^^".join(records), when])
        return relationship_id

    def rows_of(self, subject: int) -> list[list]:
        return self._by_subject.get(subject, [])


def node_id(rng: random.Random) -> int:
    return rng.randrange(10 ** 17, 10 ** 18)


# ----------------------------------------------------------------------------------------
# Time helpers
# ----------------------------------------------------------------------------------------

class LocalTime:
    """The persona's wall clock. Uses the zone database when the system has it (so daylight
    saving is right for dates months away) and the persona's fixed offset otherwise."""

    def __init__(self, persona: Persona, now: datetime.datetime):
        self.name = persona.time_zone
        self.now = now
        try:
            import zoneinfo
            self.tz: datetime.tzinfo = zoneinfo.ZoneInfo(persona.time_zone)
        except Exception:
            self.tz = datetime.timezone(datetime.timedelta(hours=persona.tz_offset_hours))
        self.today = now.astimezone(self.tz).date()

    def at(self, day_offset: int, hour: int = 0, minute: int = 0) -> datetime.datetime:
        """Local wall time `day_offset` days from today (negative = past), as UTC."""
        day = self.today + datetime.timedelta(days=day_offset)
        local = datetime.datetime(day.year, day.month, day.day, hour, minute, tzinfo=self.tz)
        return local.astimezone(UTC)

    def weekday(self, day_offset: int) -> int:
        return (self.today + datetime.timedelta(days=day_offset)).weekday()

    def local(self, value: datetime.datetime) -> datetime.datetime:
        return value.astimezone(self.tz)

    def components(self, value: datetime.datetime, all_day: bool = False) -> str:
        """JSON date components as the graph stores them (sorted keys, escaped slash)."""
        local = value.astimezone(self.tz)
        parts: dict = {"day": local.day, "isLeapMonth": False, "month": local.month,
                       "timeZone": {"identifier": self.name}, "year": local.year}
        if not all_day:
            parts.update({"hour": local.hour, "minute": local.minute, "second": 0})
        return json.dumps(parts, sort_keys=True, separators=(",", ":")).replace("/", "\\/")


def birthday_json(persona: Persona, year: int, month: int, day: int) -> str:
    return json.dumps({
        "calendar": {"current": 0, "firstWeekday": 2, "identifier": "gregorian",
                     "locale": {"current": 0, "identifier": persona.locale}, "minimumDaysInFirstWeek": 4,
                     "timeZone": {"identifier": persona.time_zone}},
        "day": day, "era": 1, "isLeapMonth": False, "month": month, "year": year,
    }, separators=(",", ":")).replace("/", "\\/")


def age_on(today: datetime.date, birthday: tuple[int, int, int]) -> int:
    year, month, day = birthday
    return today.year - year - ((today.month, today.day) < (month, day))


# ----------------------------------------------------------------------------------------
# Cast details that only this module needs (all invented)
# ----------------------------------------------------------------------------------------

PHOTO_PEOPLE = ["robin", "alex", "helen", "david", "jamie", "priya", "tom", "mei"]

# Relationship-model probabilities per person key (columns of entity_tagging).
TAGGING = {
    "robin": {"myself": 0.991},
    "alex": {"partner": 0.93, "family": 0.71, "familyAndFriends": 0.95, "friend": 0.22},
    "helen": {"mother": 0.91, "parent": 0.94, "family": 0.96, "familyAndFriends": 0.97},
    "david": {"father": 0.88, "parent": 0.92, "family": 0.95, "familyAndFriends": 0.96},
    "jamie": {"sister": 0.34, "sibling": 0.41, "family": 0.58, "friend": 0.52, "familyAndFriends": 0.89},
    "priya": {"friend": 0.84, "familyAndFriends": 0.86, "alumni": 0.31},
    "tom": {"friend": 0.78, "familyAndFriends": 0.8},
    "mei": {"friend": 0.63, "familyAndFriends": 0.66, "coworker": 0.19},
    "sam": {"friend": 0.44, "familyAndFriends": 0.47, "alumni": 0.38},
    "aroha": {"coworker": 0.91},
    "lucas": {"coworker": 0.86, "friend": 0.27},
    "nina": {"coworker": 0.77},
    "oliver": {"coworker": 0.58},
    "hana": {"coworker": 0.49},
    "drlee": {"unknown": 0.71, "coworker": 0.12},
    "landlord": {"unknown": 0.64, "friend": 0.11},
}

# Relationships the Photos knowledge graph inferred (person key → label, confidence).
PHOTOS_RELATIONSHIPS = {"alex": ("Partner", 0.82), "tom": ("Friend", 0.64), "mei": ("Friend", 0.55)}

# Words the owner's side of each declared relationship is known by (people_relationship).
RELATION_WORDS = {"partner": ("partner", "my partner"), "mother": ("mother", "mum"), "father": ("father", "dad"),
                  "sister": ("sister", "my sister"), "friend": ("friend", "my friend"), "manager": ("manager", "my boss")}

EXTRA_MAC_APPS = [
    ("com.apple.calculator", "Calculator"), ("com.apple.TextEdit", "TextEdit"), ("com.apple.ActivityMonitor", "Activity Monitor"),
    ("com.apple.DiskUtility", "Disk Utility"), ("com.apple.FontBook", "Font Book"), ("com.apple.iWork.Keynote", "Keynote"),
    ("com.apple.iWork.Pages", "Pages"), ("com.apple.iWork.Numbers", "Numbers"), ("com.apple.AppStore", "App Store"),
    ("com.apple.Dictionary", "Dictionary"), ("com.apple.Home", "Home"), ("com.apple.findmy", "Find My"),
    ("com.apple.stocks", "Stocks"), ("com.apple.VoiceMemos", "Voice Memos"), ("com.apple.clock", "Clock"),
    ("com.apple.Passwords", "Passwords"), ("com.apple.ScreenSharing", "Screen Sharing"), ("com.apple.TV", "TV"),
    ("com.apple.QuickTimePlayerX", "QuickTime Player"), ("com.apple.Console", "Console"),
    ("com.apple.Automator", "Automator"), ("com.apple.ScriptEditor2", "Script Editor"),
    ("com.apple.Image_Capture", "Image Capture"), ("com.apple.ColorSyncUtility", "ColorSync Utility"),
]

# Developer organisation by bundle-id prefix (public company names; team ids are random).
DEVELOPERS = [
    ("com.apple.", "Apple Inc."), ("com.tinyspeck.", "Slack Technologies"), ("us.zoom.", "Zoom"),
    ("net.whatsapp.", "WhatsApp"), ("com.spotify.", "Spotify"), ("com.figma.", "Figma"),
    ("com.microsoft.", "Microsoft"), ("notion.", "Notion Labs"),
]

WORK_MEETINGS = [
    # title, minutes, attendee keys (organizer first), has call link
    ("Sprint planning", 60, ["oliver", "lucas", "nina", "hana", "aroha"], True),
    ("Design review: onboarding flow", 45, ["aroha", "lucas", "nina"], True),
    ("Research readout: first-run interviews", 45, ["nina", "aroha", "hana", "oliver"], True),
    ("Roadmap workshop", 90, ["aroha", "oliver", "lucas", "nina", "hana"], False),
    ("Design critique", 60, ["robin", "aroha", "nina"], True),
    ("Accessibility audit walkthrough", 30, ["robin", "lucas"], True),
    ("Pairing: settings screen", 60, ["lucas", "robin"], True),
    ("Analytics sync", 30, ["hana", "robin"], True),
    ("Kōwhai Labs all hands", 45, ["oliver", "aroha", "lucas", "nina", "hana"], True),
    ("Usability test session", 60, ["nina", "robin"], False),
    ("Sprint retro", 45, ["oliver", "lucas", "nina", "hana", "aroha"], True),
    ("Portfolio review with Aroha", 30, ["aroha", "robin"], False),
    ("Icon set handover", 30, ["robin", "lucas", "oliver"], True),
    ("Quarterly planning", 120, ["aroha", "oliver", "nina", "hana", "lucas"], False),
]

PERSONAL_EVENTS = [
    # title, minutes, hour, attendee keys (organizer first), place key or None
    ("Brunch with Priya", 90, 10, ["robin", "priya"], "cafe"),
    ("Dinner with Mum & Dad", 150, 18, ["helen", "david", "alex"], "parents"),
    ("Coffee with Mei", 45, 15, ["mei", "robin"], "coffee"),
    ("Te Papa: new exhibition", 120, 13, ["robin", "alex"], "te_papa"),
    ("Zealandia night tour", 150, 19, ["alex", "robin"], "zealandia"),
    ("Walk up Mount Victoria", 75, 8, ["robin", "jamie"], "mt_vic"),
    ("Botanic Garden picnic", 120, 12, ["jamie", "alex", "priya"], "botanic"),
    ("Swim at Oriental Bay", 60, 7, ["robin", "tom"], "oriental"),
    ("Harbourside Market", 60, 9, ["robin", "alex"], "market"),
    ("Dinner with Tom & Sam", 120, 19, ["tom", "sam", "alex"], "cafe"),
    ("Photo walk: waterfront", 90, 17, ["robin", "mei"], "oriental"),
    ("Movie night", 150, 20, ["alex", "robin"], "home"),
    ("Jamie visiting", 180, 14, ["jamie", "robin"], "home"),
    ("Cable Car & lookout with Mum", 90, 11, ["robin", "helen"], "cable_car"),
]

ERRANDS = [
    # title, minutes, hour, attendee keys, place key, URL path or None — the sensitive-looking ones
    ("Dentist: check-up with Dr Lee", 45, 8, ["drlee", "robin"], None, None),
    ("Flat inspection (Chris Aldous)", 30, 16, ["landlord", "robin"], "home", None),
    ("GP appointment", 20, 9, [], None, None),
    ("Passport renewal: photo", 15, 12, [], None, None),
    ("Bike service pick-up", 20, 17, [], None, None),
    ("Mortgage adviser call", 45, 12, ["robin", "alex"], None, "call"),
    ("Physio: shoulder", 40, 7, [], "gym", None),
]

LANGUAGE_WORDS = ["en", "mi", "fr", "de", "es", "it", "nl", "sv", "da", "ja"]
# Relationship words by Wikidata id (aliases.db is shipped reference data; words are common vocabulary).
RELATIONSHIP_ALIASES = {
    "Q7560": ["mother", "whaea", "mère", "Mutter", "madre", "madre", "moeder", "mor", "mor", "母"],
    "Q7565": ["father", "matua", "père", "Vater", "padre", "padre", "vader", "far", "far", "父"],
    "Q7566": ["parent", "matua", "parent", "Elternteil", "progenitor", "genitore", "ouder", "förälder", "forælder", "親"],
    "Q7569": ["child", "tamaiti", "enfant", "Kind", "hijo", "figlio", "kind", "barn", "barn", "子供"],
    "Q595094": ["sister", "tuahine", "sœur", "Schwester", "hermana", "sorella", "zus", "syster", "søster", "姉妹"],
    "Q10861465": ["brother", "tungāne", "frère", "Bruder", "hermano", "fratello", "broer", "bror", "bror", "兄弟"],
    "Q31184": ["sibling", "teina", "frère ou sœur", "Geschwister", "hermano", "fratello o sorella", "broer of zus", "syskon", "søskende", "きょうだい"],
    "Q177232": ["son", "tama", "fils", "Sohn", "hijo", "figlio", "zoon", "son", "søn", "息子"],
    "Q308194": ["daughter", "tamāhine", "fille", "Tochter", "hija", "figlia", "dochter", "dotter", "datter", "娘"],
    "Q17297777": ["friend", "hoa", "ami", "Freund", "amigo", "amico", "vriend", "vän", "ven", "友達"],
    "Q1196129": ["spouse", "hoa rangatira", "conjoint", "Ehepartner", "cónyuge", "coniuge", "echtgenoot", "make", "ægtefælle", "配偶者"],
}
EXTRA_ALIASES = {"Q7560": ["mum", "mom", "mama"], "Q7565": ["dad", "papa"], "Q1196129": ["partner", "husband", "wife"],
                 "Q17297777": ["mate", "pal", "buddy"], "Q595094": ["sis"], "Q10861465": ["bro"]}

# New Zealand public holidays (public knowledge): name, month, day.
HOLIDAYS = [
    ("New Year's Day", 1, 1), ("Day after New Year's Day", 1, 2), ("Wellington Anniversary Day", 1, 22),
    ("Waitangi Day", 2, 6), ("Anzac Day", 4, 25), ("King's Birthday", 6, 2), ("Matariki", 6, 20),
    ("Labour Day", 10, 27), ("Christmas Day", 12, 25), ("Boxing Day", 12, 26),
]

SCHEDULES = ["daily", "dailyWithNetworking", "every21Minutes", "every2Hours", "every4Hours", "every7Minutes", "hourly",
             "live", "none", "weekly"]

# name, generationType, artifactType, artifact file (relative to Artifacts unless it has no folder), table
VIEW_CATALOG = [
    ("peopleSubgraph", "subgraph", "subgraph", "internal/views.db", "people_subgraph"),
    ("entitySubgraph", "subgraph", "subgraph", "internal/views.db", "entity_subgraph"),
    ("appSubgraph", "subgraph", "subgraph", "internal/views.db", "app_subgraph"),
    ("eventSubgraph", "subgraph", "subgraph", "internal/views.db", "event_subgraph"),
    ("entityAlias", "customSQL", "customRow", "internal/views.db", "entity_alias"),
    ("entityAliasECR", "customSQL", "customRow", "ecr/views.db", "entity_alias_ecr"),
    ("asrEntityAlias", "customSQL", "customRow", "ecr/views.db", "asr_entity_alias"),
    ("inferenceFeaturesECR", "custom", "feature", "ecr/views.db", "kv"),
    ("handleMap", "custom", "customRow", "internal/views.db", "handle_id"),
    ("phPersonIdentifierMap", "custom", "customRow", "internal/views.db", "phperson_id_map"),
    ("peopleRelationship", "custom", "customRow", "internal/views.db", "people_relationship"),
    ("currentCoarseTimeOfDayContext", "signal", "feature", "feature/features.db", "kv"),
    ("currentDayOfWeekContext", "signal", "feature", "feature/features.db", "kv"),
    ("currentWiFiContext", "biomeIncremental", "contextualEvents", "internal/views.db", "wifiContextEvents"),
    ("currentLOIContext", "biomeIncremental", "contextualEvents", "internal/views.db", "loiContextEvents"),
    ("currentCoarseGeoHashContext", "biomeIncremental", "contextualEvents", "internal/views.db", "coarseGeoHashContextEvents"),
    ("currentSpecificGeoHashContext", "biomeIncremental", "contextualEvents", "internal/views.db", "specificGeoHashContextEvents"),
    ("personEntityHistograms", "custom", "entityInteractionHistogram", "internal/views.db", "personEntityHistograms"),
    ("bidirectionalPersonEntityHistograms", "custom", "entityInteractionHistogram", "internal/views.db", "bidirectionalPersonEntityHistograms"),
    ("photosPersonEntityHistograms", "custom", "entityInteractionHistogram", "internal/views.db", "photosPersonEntityHistograms"),
    ("loiEntityHistograms", "custom", "entityInteractionHistogram", "internal/views.db", "loiEntityHistograms"),
    ("personEntityRelevanceNonContextualFeatures", "custom", "feature", "feature/features.db", "kv"),
    ("personEntityRelevanceCoarseTimeOfDayFeatures", "custom", "feature", "feature/features.db", "kv"),
    ("personEntityRelevanceDayOfWeekFeatures", "custom", "feature", "feature/features.db", "kv"),
    ("personEntityRelevanceCoarseTimeOfDayAndDayOfWeekFeatures", "custom", "feature", "feature/features.db", "kv"),
    ("personEntityRelevanceWiFiFeatures", "custom", "feature", "feature/features.db", "kv"),
    ("personEntityRelevanceLOIFeatures", "custom", "feature", "feature/features.db", "kv"),
    ("personEntityRelevanceRanking", "custom", "entityRelevanceRanking", "entityRelevance/entityRelevanceInferences.db", "person_entity_relevance"),
    ("personEntityLongTermRanking", "custom", "entityRelevanceRanking", "entityRelevance/entityRelevanceInferences.db", "person_entity_longterm"),
    ("loiEntityRelevanceRanking", "custom", "entityRelevanceRanking", "entityRelevance/entityRelevanceInferences.db", "loi_entity_relevance"),
    ("personEntityTaggingFacts", "custom", "feature", "feature/features.db", "kv"),
    ("personEntityTagging", "custom", "feature", "feature/features.db", "kv"),
    ("photosPersonEntityTagging", "custom", "feature", "feature/features.db", "kv"),
    ("entityTagging", "custom", "entityTagging", "entityTagging/entityTagging.db", "entity_tagging"),
    ("entityImportanceSignals", "custom", "customRow", "entityRelevance/entityImportanceSignals.db", "entityImportanceSignalsIDMap"),
    ("sourceConfidence", "custom", "customRow", "confidenceService/sourceConfidence.db", "sourceConfidence"),
    ("languageView", "custom", "subgraph", "internal/inferred_triples.db", "languages"),
    ("locationSubgraphFeatures", "subgraph", "subgraph", "feature/features.db", "location_subgraph_features"),
    ("lifeEventSubgraph", "subgraph", "subgraph", "lifeEvent/lifeEventView.db", "lifeEvent_subgraph"),
    ("lifeEventMap", "custom", "customRow", "lifeEvent/lifeEventView.db", "lifeEvent_map"),
    ("futureLifeEventSubgraph", "subgraph", "subgraph", "futureLifeEvent/futureLifeEventView.db", "futureLifeEvent_subgraph"),
    ("appleMusicEventSubgraph", "subgraph", "subgraph", "appleMusicEvent/appleMusicEventView.db", "appleMusicEvent_subgraph"),
    ("appleMusicEventMap", "custom", "customRow", "appleMusicEvent/appleMusicEventView.db", "appleMusicEvent_map"),
    ("scoredTopicsFirstPartyLongTerm", "custom", "customRow", "firstPartyTopics/scoredTopicsFirstPartyLongTerm.db", "topics"),
    ("scoredTopicsFirstPartyShortTerm", "custom", "customRow", "firstPartyTopics/scoredTopicsFirstPartyShortTerm.db", "topics"),
    ("siriRemembers", "biomeIncremental", "siriRemembers", "siri/remembers/view.db", None),
    ("defaultResolverInteractions", "custom", "defaultResolverInteractions", "siri/resolver/interactions.db", None),
    ("initializeGlobalKnowledgeAssets", "custom", "external", "", None),
    ("behaviorSequenceSignal", "signal", "unstructured", "", None),
    ("userFocusComputedModeSignal", "signal", "unstructured", "", None),
    ("nowPlayingSignal", "signal", "unstructured", "", None),
    ("timeAndDateSignal", "signal", "unstructured", "", None),
    ("workoutSignal", "signal", "unstructured", "", None),
    ("entityAliasEuclidVDB", "vectordb", "vectordb", "vectors/entityAlias", None),
]

BIOME_SOURCES = ["App.InFocus", "App.Intent", "Device.ScreenLocked", "Device.Wireless.WiFi", "Location.Semantic",
                 "Siri.Remembers.MessageHistory", "Siri.Remembers.CallHistory", "Siri.Remembers.InteractionHistory",
                 "Siri.Remembers.AudioHistory", "Siri.Remembers.AssistantSuggestions"]
SYNCED_SOURCES = [s for s in BIOME_SOURCES if s.startswith("Siri.Remembers.")]

# Source-confidence priors: source → signal types (generic vocabulary; the numbers are invented).
CONFIDENCE_SOURCES = {
    "CNContact": ["cnContact", "cnOrganization", "cnPostalAddress"],
    "EKEvent": ["ekEvent", "ekEventParticipant", "ekStructuredLocation"],
    "FAFamily": ["faFamilyCircle", "faFamilyMember"],
    "LSBundleRecord": ["lsBundleRecord", "lsSoftwareDeveloper"],
    "PHPerson": ["phPerson"],
    "PGPerson": ["pgPerson"],
    "PGEvent": ["pgEvent", "pgEventLocation", "pgEventPerson", "pgEventPlaceOfInterest"],
    "INPerson": ["inPerson"],
    "INGroup": ["inGroup", "inGroupApp", "inGroupPerson"],
    "SGContact": ["sgContact", "sgPostalAddress"],
    "SGEvent": ["sgEvent", "sgLocation"],
    "PPContact": ["ppContact", "ppContactLocation", "ppContactNamedEntity", "ppContactTopic"],
    "PPLocation": ["ppLocation"],
    "PPTopic": ["ppTopic", "ppTopicContact"],
    "RTLocationOfInterest": ["rtLocationOfInterest", "rtLocationOfInterestPerson"],
    "RTVisit": ["rtVisit", "rtVisitedLocation", "rtVisitedPerson"],
    "HMHome": ["hmHome", "hmLocation", "hmUser"],
    "LOI": ["gym", "home", "restaurant", "work"],
    "HealthKit": ["mindful", "sleeping", "workout", "other"],
    "PassKit": ["applePay", "concert", "flight", "Movie"],
    "BMAppleMusicEvent": ["bmAppleMusicEvent", "bmAppleMusicEventSong"],
    "GeoPOI": ["geoPoi"],
    "POI": ["poi"],
    "EventsFoundInApps": ["eventsFoundInApps"],
    "appLaunch": ["appLaunchSoftware"],
    "lifeEvent": ["lifeEventLocationVisit", "lifeEventPhyiscalActivity"],
}

DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
DAY_PARTS = ["Morning", "Afternoon", "Evening", "Night"]
FOCUSES = ["DefaultFocus", "DrivingFocus", "ExerciseFocus", "GamingFocus", "MindfulnessFocus", "PersonalTimeFocus",
           "ReadingFocus", "SleepFocus", "WorkFocus"]
CONTEXT_FEATURES = ["coarseTimeOfDay", "dayOfWeek", "wifi", "loi"]
NON_CONTEXTUAL = ["behaviorPopularityGivenSequence", "dailyDoseL1Error", "dailyDoseL2Error", "lastExecutionAge",
                  "longTermTrendingPopularity", "medianTimeIntervalBetweenExecution", "sequencePopularityGivenBehavior",
                  "shortTermTrendingPopularity", "totalCount", "trendingPopularity"]


def day_part(hour: int) -> str:
    if 6 <= hour < 12:
        return "Morning"
    if 12 <= hour < 17:
        return "Afternoon"
    if 17 <= hour < 22:
        return "Evening"
    return "Night"


def lower_first(text: str) -> str:
    return text[:1].lower() + text[1:]


def feature_value(value) -> bytes:
    """An NSKeyedArchiver `MLFeatureValue` (type 1 integer, 2 double, 3 string)."""
    kind = 3 if isinstance(value, str) else (2 if isinstance(value, float) else 1)
    return lib.keyed_archive(lib.ArchiveObject("MLFeatureValue", {"type": kind, "undefined": False, "value": value},
                                               classes=["MLFeatureValue", "NSObject"]))


# ----------------------------------------------------------------------------------------
# Stable graph
# ----------------------------------------------------------------------------------------

def _aliases(person: Person, owner: bool) -> list[tuple[str, str, float]]:
    given, family = person.given.lower(), person.family.lower()
    out = [(given, "first_provided_alias", 1.0), (family, "family_provided_alias", 0.8),
           (f"{given}\t{family}", "full_provided_alias", 1.0)]
    if person.nickname:
        out.append((person.nickname.lower(), "derived_alias", 0.9))
    if owner:
        out.append(("me", "me_alias", 1.0))
    return out


def _person(g: GraphWriter, persona: Persona, person: Person, clock: lib.Clock, rng: random.Random, today: datetime.date,
            recent: float) -> None:
    owner = person is persona.owner
    contact = f"cnContact:{person.contact_id}"
    sources = source_mask("cnContact")
    when = lib.cocoa(clock.ago(days=rng.uniform(2, 400)))
    node = person.graph_id
    g.simple(node, "PS1", "SB104", sources=sources, records=[contact], when=when)
    g.simple(node, "PS33", person.full_name, sources=sources, records=[contact], when=when)
    g.simple(node, "PS312", person.given, sources=sources, records=[contact], when=when)
    g.simple(node, "PS441", person.family, sources=sources, records=[contact], when=when)
    g.simple(node, "PS102", contact, sources=sources, records=[contact], when=when)
    g.facet(node, "PS72", "CS22", [("PS396", "CNContact"), ("PS69", person.contact_id)], sources=sources, records=[contact], when=when)
    for email in person.emails:
        label = "_$!<Work>!$_" if email.endswith("example.org") else "_$!<Home>!$_"
        g.facet(node, "PS520", "CS97", [("PS406", email), ("PS740", label)], sources=sources, records=[contact], when=when)
    for phone in person.phones:
        g.facet(node, "PS520", "CS97", [("PS407", phone), ("PS740", "_$!<Mobile>!$_")], sources=sources, records=[contact], when=when)
    if person.birthday:
        g.simple(node, "PS37", birthday_json(persona, *person.birthday), sources=sources, records=[contact], when=when)
    for alias, signal, confidence in _aliases(person, owner):
        g.facet(node, "nm_entityAliasRelationship", "nm_entityAliasRelationshipType",
                [("PS89", alias), ("nm_signalLabel", signal), ("nm_confirmationConfidence", f"{confidence:.1f}")],
                sources=sources, records=[contact], when=when, confidence=confidence)
    if owner:
        g.simple(node, "nm_isCurrentUser", "true", sources=sources, records=[contact], when=when)

    # Recognised in Photos.
    if person.key in PHOTO_PEOPLE:
        local_id = f"{photos_person_uuid(persona, person)}/L0/070"
        record = f"phPerson:{local_id}"
        photos = source_mask("phPerson")
        seen = lib.cocoa(clock.ago(days=rng.uniform(1, 40)))
        confidence = 0.96 if owner else round(rng.uniform(0.78, 0.95), 2)
        g.simple(node, "PS1", "SB104", sources=photos, records=[record], when=seen)
        g.simple(node, "PS33", person.full_name, sources=photos, records=[record], when=seen)
        g.simple(node, "PS102", record, sources=photos, records=[record], when=seen)
        g.simple(node, "nm_personType", "Important" if person.closeness >= 0.65 else "Ordinary", sources=photos, records=[record], when=seen)
        g.simple(node, "nm_photosDetectionType", "human", sources=photos, records=[record], when=seen)
        g.facet(node, "PS72", "CS22", [("PS396", "PHPerson"), ("PS69", local_id)], sources=photos, records=[record], when=seen)
        g.facet(node, "nm_hasVisualIdentifier", "nm_visualIdentifierRelationshipType",
                [("nm_visualIdentifier", local_id),
                 ("nm_associationReason", "association:userTaggedPhotos" if person.closeness >= 0.7 else "association:identifierMatch")],
                sources=photos, records=[record], when=seen, confidence=confidence)

    # Family Sharing member.
    if person.key in ("robin", "alex"):
        member_id = str(rng.randrange(10 ** 9, 10 ** 10))
        record = f"faFamilyCircle:{member_id}"
        family = source_mask("faFamilyCircle")
        g.simple(node, "PS1", "SB104", sources=family, records=[record], when=recent)
        g.simple(node, "PS33", person.full_name, sources=family, records=[record], when=recent)
        g.simple(node, "PS312", person.given, sources=family, records=[record], when=recent)
        g.simple(node, "PS441", person.family, sources=family, records=[record], when=recent)
        g.simple(node, "PS102", record, sources=family, records=[record], when=recent)
        g.simple(node, "PS313", person.email, sources=family, records=[record], when=recent)
        g.simple(node, "nm_familyMemberType", "ADULT", sources=family, records=[record], when=recent)
        if person.birthday:
            g.simple(node, "nm_age", str(age_on(today, person.birthday)), sources=family, records=[record], when=recent)
        g.facet(node, "PS72", "CS22", [("PS396", "FAFamilyCircle"), ("PS69", member_id)], sources=family, records=[record], when=recent)
        if owner:
            g.simple(node, "nm_isCurrentUser", "true", sources=family, records=[record], when=recent)


def _place(g: GraphWriter, place: Place, kind: str, record: str, when: float) -> None:
    sources = source_mask(kind)
    node = place.graph_id
    g.simple(node, "PS1", "SB152", sources=sources, records=[record], when=when)
    g.simple(node, "PS102", record, sources=sources, records=[record], when=when)
    if kind != "cnContact":
        g.simple(node, "PS33", place.name, sources=sources, records=[record], when=when)
        g.facet(node, "PS573", "CS29", [("PS571", f"{place.latitude:.5f}"), ("PS572", f"{place.longitude:.5f}")],
                sources=sources, records=[record], when=when)
    g.facet(node, "PS317", "CS97",
            [("PS316", place.street), ("PS453", place.city), ("PS315", place.postal_code),
             ("PS455", place.region), ("PS450", place.country), ("PS454", place.country_code)],
            sources=sources, records=[record], when=when)


def _event_record(rng: random.Random) -> str:
    """An EventKit record id as the graph keeps it: opaque, base64-looking."""
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    return "ekEvent:" + "".join(rng.choice(alphabet) for _ in range(27)) + "="


def _code(rng: random.Random, length: int, alphabet: str = "abcdefghijkmnpqrstuvwxyz") -> str:
    return "".join(rng.choice(alphabet) for _ in range(length))


class Event:
    def __init__(self, title: str, starts: list[datetime.datetime], minutes: int, *, all_day: bool = False,
                 people: list[str] | None = None, place: str | None = None, call: str | None = None,
                 url: str | None = None, birthday_of: str | None = None, days: int = 1):
        self.title, self.starts, self.minutes, self.all_day = title, starts, minutes, all_day
        self.people, self.place, self.call, self.url = people or [], place, call, url
        self.birthday_of, self.days = birthday_of, days


def _plan_events(persona: Persona, rng: random.Random, lt: LocalTime) -> list[Event]:
    events: list[Event] = []

    def call_link() -> str:
        if rng.random() < 0.5:
            return f"https://meet.example.org/{_code(rng, 3)}-{_code(rng, 4)}-{_code(rng, 3)}"
        return f"https://example.com/j/{rng.randrange(10 ** 10, 10 ** 11)}?pwd={_code(rng, 16, 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789')}"

    back, ahead = 56, 42
    last_used: dict[str, int] = {}

    def pick(options: list, day: int, gap: int):
        """A template whose title was not used in the last `gap` days."""
        fresh = [o for o in options if day - last_used.get(o[0], -999) >= gap] or options
        choice = rng.choice(fresh)
        last_used[choice[0]] = day
        return choice

    # Recurring series: one node, one date facet per occurrence.
    standup = [lt.at(d, 9, 30) for d in range(-21, 15) if lt.weekday(d) in (0, 2, 4)]
    events.append(Event("Design stand-up", standup, 15, people=["aroha", "robin", "lucas", "nina", "hana"], call=call_link()))
    events.append(Event("1:1 Aroha / Robin", [lt.at(d, 14, 0) for d in range(-35, 22) if lt.weekday(d) == 1], 30,
                        people=["aroha", "robin"], place="work", call=call_link()))
    events.append(Event("Climbing with Tom", [lt.at(d, 18, 0) for d in range(-42, 22) if lt.weekday(d) == 3], 90,
                        people=["robin", "tom"], place="gym"))
    events.append(Event("Recycling & rubbish out", [lt.at(d) for d in range(-28, 22) if lt.weekday(d) == 2], 0, all_day=True))
    events.append(Event("Call Mum", [lt.at(d, 19, 30) for d in range(-28, 15) if lt.weekday(d) == 6], 30, people=["robin", "helen"]))

    # Work meetings on weekdays.
    for day in range(-back, ahead):
        if lt.weekday(day) >= 5:
            continue
        for _ in range(rng.choice([0, 0, 1, 1, 1, 2] if day <= 14 else [0, 0, 0, 1])):
            title, minutes, people, has_call = pick(WORK_MEETINGS, day, 6)
            hour, minute = rng.choice([10, 10, 11, 13, 14, 15, 16]), rng.choice([0, 0, 30])
            everyone = people if "robin" in people else people + ["robin"]
            events.append(Event(title, [lt.at(day, hour, minute)], minutes, people=everyone,
                                place="work" if not has_call or rng.random() < 0.35 else None,
                                call=call_link() if has_call else None))

    # Personal plans: evenings and weekends.
    for day in range(-back, ahead):
        weekend = lt.weekday(day) >= 5
        if rng.random() < (0.55 if weekend else 0.12):
            title, minutes, hour, people, place = pick(PERSONAL_EVENTS, day, 21)
            if not weekend and hour < 17:
                hour = 18
            events.append(Event(title, [lt.at(day, hour, rng.choice([0, 0, 15, 30]))], minutes,
                                people=people if "robin" in people else people + ["robin"], place=place))

    # Errands and appointments.
    for index, (title, minutes, hour, people, place, url) in enumerate(ERRANDS):
        day = rng.randrange(-back, ahead)
        while lt.weekday(day) >= 5:
            day += 1
        events.append(Event(title, [lt.at(day, hour, rng.choice([0, 15, 30, 45]))], minutes, people=people, place=place,
                            call=call_link() if url == "call" else None))

    # Trips, tickets and all-day things.
    booking = _code(rng, 6, "ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    events.append(Event(f"Flight to Auckland (booking {booking})", [lt.at(9, 7, 5)], 65, people=["robin"], place="airport",
                        url=f"https://example.com/manage-booking?ref={booking}&lastName=SAMPLE"))
    events.append(Event("Flight home from Auckland", [lt.at(11, 18, 40)], 65, people=["robin"], place="auckland",
                        url=f"https://example.com/manage-booking?ref={booking}&lastName=SAMPLE"))
    events.append(Event("Design conference, Auckland", [lt.at(9)], 0, all_day=True, days=3, people=["robin", "nina"], place="auckland"))
    events.append(Event("Queenstown long weekend", [lt.at(24)], 0, all_day=True, days=4, people=["robin", "alex"], place="queenstown"))
    events.append(Event("Rotorua with Jamie", [lt.at(-37)], 0, all_day=True, days=2, people=["jamie", "robin"], place="rotorua"))
    events.append(Event("Marlow Quartet: Late Set tour", [lt.at(17, 20, 0)], 120, people=["robin", "alex", "priya"],
                        url=f"https://example.com/tickets/{_code(rng, 10, 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789')}"))
    events.append(Event("Rent due", [lt.at(d) for d in range(-back, ahead) if (lt.today + datetime.timedelta(days=d)).day == 1], 0, all_day=True))
    events.append(Event("Train to Paraparaumu", [lt.at(-13, 9, 14)], 55, people=["robin"], place="station"))
    events.append(Event("Annual leave", [lt.at(24)], 0, all_day=True, days=4))

    # Birthdays inside the window (from Contacts).
    for person in persona.others:
        if not person.birthday:
            continue
        for year in (lt.today.year - 1, lt.today.year, lt.today.year + 1):
            try:
                date = datetime.date(year, person.birthday[1], person.birthday[2])
            except ValueError:
                continue
            offset = (date - lt.today).days
            if -back <= offset <= ahead + 30:
                events.append(Event(f"{person.given} {person.family}’s Birthday", [lt.at(offset)], 0, all_day=True, birthday_of=person.key))
    for name, month, day in HOLIDAYS:
        for year in (lt.today.year, lt.today.year + 1):
            offset = (datetime.date(year, month, day) - lt.today).days
            if -back <= offset <= ahead + 30:
                events.append(Event(name, [lt.at(offset)], 0, all_day=True))
    return [e for e in events if e.starts]


def _write_events(g: GraphWriter, expired: list[list], persona: Persona, rng: random.Random, clock: lib.Clock,
                  lt: LocalTime, events: list[Event]) -> set[str]:
    """Writes `event_graph` rows; returns the keys of people who appear as participants."""
    ek = source_mask("ekEvent")
    seen: set[str] = set()
    for event in events:
        node = node_id(rng)
        record = _event_record(rng)
        first = min(event.starts)
        # Events are mirrored when created or changed: some days before they start, never in the future.
        lead = datetime.timedelta(days=rng.uniform(1, 21), hours=rng.uniform(0, 8))
        written = lib.cocoa(min(first - lead, clock.ago(hours=rng.uniform(1, 60))))
        kw = dict(sources=ek, records=[record], when=written)
        g.simple(node, "PS1", "SB472", **kw)
        g.simple(node, "PS33", event.title, **kw)
        g.simple(node, "PS102", record, **kw)
        g.simple(node, "nm_isAllDay", "1" if event.all_day else "0", **kw)
        item = lib.uuid_string(rng)
        g.facet(node, "PS72", "CS22", [("PS396", "EKCalendarItemIdentifier"), ("PS69", item)], **kw)
        if event.birthday_of:
            g.facet(node, "PS72", "CS22", [("PS396", "EKBirthdayContactID"), ("PS69", persona.person(event.birthday_of).contact_id)], **kw)
        else:
            domain = "example.org" if event.call or event.place == "work" else "example.com"
            g.facet(node, "PS72", "CS22", [("PS396", "EKCalendarExternalIdentifier"), ("PS69", f"{lib.hex_string(rng, 26)}@{domain}")], **kw)
        for start in event.starts:
            if event.all_day:
                end = start + datetime.timedelta(days=event.days) - datetime.timedelta(seconds=1)
            else:
                end = start + datetime.timedelta(minutes=event.minutes)
            g.facet(node, "nm_hasDate", "nm_dateRelationshipType",
                    [("PS29", lt.components(start, event.all_day)), ("PS30", lt.components(end, event.all_day)),
                     ("nm_imputedStartTime", f"{lib.cocoa(start):.1f}"), ("nm_imputedEndTime", f"{lib.cocoa(end):.1f}"),
                     ("nm_occurrenceDate", lt.components(start, event.all_day) if len(event.starts) > 1 else None),
                     ("nm_imputedOccurrenceDate", f"{lib.cocoa(start):.1f}" if len(event.starts) > 1 else None)], **kw)
        for index, key in enumerate(event.people):
            person = persona.person(key)
            seen.add(person.key)
            g.facet(node, "PS578" if index == 0 else "PS232", "CS38",
                    [("PS143", ref(person.graph_id)), ("PS734", "person")], **kw)
        if event.people and len(event.people) > 1:
            # The organizer also attends.
            g.facet(node, "PS232", "CS38", [("PS143", ref(persona.person(event.people[0]).graph_id)), ("PS734", "person")], **kw)
        if event.place:
            g.facet(node, "PS225", "CS29", [("PS107", ref(persona.place(event.place).graph_id))], **kw)
        if event.call:
            g.simple(node, "nm_virtualConferenceURL", event.call, **kw)
        if event.url:
            g.simple(node, "PS296", event.url, **kw)

        # A rescheduled event leaves its old date facet behind in expired_event_graph.
        if not event.all_day and len(event.starts) == 1 and rng.random() < 0.14:
            old = first - datetime.timedelta(days=rng.choice([1, 2, 7]), hours=rng.choice([0, 1, -1]))
            old_end = old + datetime.timedelta(minutes=event.minutes)
            relationship = rng.randrange(1, 1 << 62)
            gone = written - rng.uniform(3600, 5 * 86400)
            for field, value in (("PS1", "nm_dateRelationshipType"), ("PS29", lt.components(old)), ("PS30", lt.components(old_end)),
                                 ("nm_imputedStartTime", f"{lib.cocoa(old):.1f}"), ("nm_imputedEndTime", f"{lib.cocoa(old_end):.1f}")):
                expired.append([node, "nm_hasDate", relationship, field, value, ek, 1.0, record, gone])
    return seen


# ----------------------------------------------------------------------------------------
# Behaviour (interactions, appearances, context) — shared by several derived views
# ----------------------------------------------------------------------------------------

def _interactions(persona: Persona, rng: random.Random, clock: lib.Clock, lt: LocalTime) -> list[tuple[datetime.datetime, Person, int, str, bool]]:
    """(when, person, mechanism code, bundle id, outgoing) over the last four months."""
    out = []
    for person in persona.others:
        work = person.relationship in ("colleague", "manager")
        count = int(12 + 420 * person.closeness ** 2.2)
        if person.relationship == "service":
            count = rng.randint(3, 7)
        hours = (9, 18) if work else (7, 23)
        for when in clock.spread(rng, count, days=120, hours=hours, recent_bias=1.25):
            if work and lt.local(when).weekday() >= 5:
                when -= datetime.timedelta(days=2)
            if work:
                mechanism, bundle = rng.choices([(1, "com.tinyspeck.slackmacgap"), (5, "com.apple.mail"), (1, "com.apple.MobileSMS")], [6, 3, 1])[0]
            elif person.relationship == "service":
                mechanism, bundle = rng.choices([(5, "com.apple.mail"), (1, "com.apple.MobileSMS")], [3, 1])[0]
            else:
                mechanism, bundle = rng.choices([(1, "com.apple.MobileSMS"), (1, "net.whatsapp.WhatsApp"), (5, "com.apple.mail")], [7, 3, 1])[0]
            out.append((when, person, mechanism, bundle, rng.random() < 0.46))
    out.sort(key=lambda item: item[0])
    return out


def _with_gaps(events: list[tuple[datetime.datetime, str]], behavior_type: int) -> list[tuple]:
    """Rows of a `*Events` table: per identifier, the seconds since its previous event."""
    last: dict[str, float] = {}
    rows = []
    for when, identifier in sorted(events, key=lambda item: item[0]):
        stamp = lib.cocoa(when)
        previous = last.get(identifier)
        rows.append((behavior_type, identifier, stamp, None if previous is None else round(stamp - previous, 3)))
        last[identifier] = stamp
    return rows


# ----------------------------------------------------------------------------------------
# generate
# ----------------------------------------------------------------------------------------

def generate(root: pathlib.Path, persona: Persona, rng: random.Random, now: datetime.datetime) -> None:
    clock = lib.Clock(now, persona.tz_offset_hours)
    lt = LocalTime(persona, now)
    g = GraphWriter(rng)
    owner = persona.owner
    owner_record = f"cnContact:{owner.contact_id}"
    contacts = source_mask("cnContact")
    recent = lib.cocoa(clock.ago(days=1, hours=3))
    base = lib.library(root, "IntelligencePlatform")
    artifacts = base / "Artifacts"
    by_key = {p.key: p for p in persona.people}

    # ---- People ------------------------------------------------------------------------
    for person in persona.people:
        _person(g, persona, person, clock, rng, lt.today, recent)

    # The owner's profiles in apps (Contacts social profiles) and own postal address.
    for service, username, url in (("Slack", "robin.sample", "https://example.org/team/robin.sample"),
                                   ("Instagram", "robin.makes", "https://example.com/robin.makes")):
        g.facet(owner.graph_id, "PS72", "CS22", [("PS396", service), ("PS313", username), ("PS66", url)],
                sources=contacts, records=[owner_record], when=recent)
    home, work = persona.place("home"), persona.place("work")
    g.facet(owner.graph_id, "PS317", "CS97",
            [("PS316", home.street), ("PS453", home.city), ("PS315", home.postal_code), ("PS455", home.region),
             ("PS450", home.country), ("PS454", home.country_code), ("PS733", "_$!<Home>!$_")],
            sources=contacts, records=[owner_record], when=recent)

    # ---- Places ------------------------------------------------------------------------
    place_when = {}
    for place in persona.places:
        if place.key in ("home", "work", "parents"):
            kind, record = "cnContact", f"cnContact:{lib.uuid_string(rng)}:ABPerson"
        else:
            kind, record = "ekEvent", _event_record(rng)
        place_when[place.key] = lib.cocoa(clock.ago(days=rng.uniform(3, 300)))
        _place(g, place, kind, record, place_when[place.key])
    for key in ("home", "work", "gym"):
        place = persona.place(key)
        g.facet(owner.graph_id, "PS225", "CS29", [("PS107", ref(place.graph_id)), ("PS733", place.label)],
                sources=contacts, records=[owner_record], when=recent)
    partner = persona.person("partner")
    g.facet(partner.graph_id, "PS225", "CS29", [("PS107", ref(home.graph_id)), ("PS733", "_$!<Home>!$_")],
            sources=contacts, records=[f"cnContact:{partner.contact_id}"], when=recent)
    for key in ("mother", "father"):
        parent = persona.person(key)
        g.facet(parent.graph_id, "PS225", "CS29", [("PS107", ref(persona.place("parents").graph_id)), ("PS733", "_$!<Home>!$_")],
                sources=contacts, records=[f"cnContact:{parent.contact_id}"], when=recent)

    # ---- Organizations and employment -----------------------------------------------------
    company = persona.company_graph_id
    company_record = f"cnContact:{lib.uuid_string(rng)}:ABPerson"
    g.simple(company, "PS1", "SB10", sources=contacts, records=[company_record], when=recent)
    g.simple(company, "PS33", persona.company, sources=contacts, records=[company_record], when=recent)
    g.simple(company, "PS102", company_record, sources=contacts, records=[company_record], when=recent)
    g.facet(company, "PS225", "CS29", [("PS107", ref(work.graph_id)), ("PS733", "_$!<Work>!$_")],
            sources=contacts, records=[company_record], when=recent)
    organizations = {persona.company: company}
    for person in persona.people:
        if not person.organization:
            continue
        if person.organization not in organizations:
            org, record = node_id(rng), f"cnContact:{person.contact_id}"
            organizations[person.organization] = org
            g.simple(org, "PS1", "SB10", sources=contacts, records=[record], when=recent)
            g.simple(org, "PS33", person.organization, sources=contacts, records=[record], when=recent)
        g.facet(person.graph_id, "PS500", "CS165", [("PS45", ref(organizations[person.organization]))],
                sources=contacts, records=[f"cnContact:{person.contact_id}"], when=recent)

    # ---- Relationships -------------------------------------------------------------------
    for person in persona.others:
        if person.relationship_label:
            g.facet(owner.graph_id, "PS598", "CS168",
                    [("nm_personIdentifier", ref(person.graph_id)),
                     ("nm_relationshipLabel", person.relationship),
                     ("nm_unlocalizedRelationshipLabel", person.relationship_label),
                     ("nm_confidence", "1.0")],
                    sources=contacts, records=[owner_record], when=recent)
    photos_graph = source_mask("pgRelationship")
    for key, (label, confidence) in PHOTOS_RELATIONSHIPS.items():
        person = by_key[key]
        record = f"pgRelationship:{photos_person_uuid(persona, owner)}/L0/070"
        g.facet(owner.graph_id, "PS598", "CS168",
                [("nm_personIdentifier", ref(person.graph_id)), ("nm_relationshipLabel", label.lower()),
                 ("nm_unlocalizedRelationshipLabel", label), ("nm_confidence", f"{confidence:.2f}")],
                sources=photos_graph, records=[record], when=lib.cocoa(clock.ago(days=rng.uniform(2, 30))), confidence=confidence)

    # ---- Family Sharing circle -----------------------------------------------------------
    family = persona.family_group_graph_id
    family_sources = source_mask("faFamilyCircle")
    family_record = f"faFamilyCircle:{lib.uuid_string(rng)}"
    g.simple(family, "PS1", "SB2", sources=family_sources, records=[family_record], when=recent)
    g.simple(family, "PS33", "Family", sources=family_sources, records=[family_record], when=recent)
    g.simple(family, "PS102", family_record, sources=family_sources, records=[family_record], when=recent)
    for member in (owner, partner):
        g.facet(family, "PS753", "CS166", [("PS566", ref(member.graph_id))],
                sources=family_sources, records=[family_record], when=recent)

    # ---- Installed apps and their developers ---------------------------------------------
    apps = source_mask("lsBundleRecord")
    developers: dict[str, tuple[int, str]] = {}
    mac_apps = [(a.bundle_id, a.name) for a in persona.apps_on("mac")] + EXTRA_MAC_APPS
    app_nodes: dict[str, int] = {}
    for bundle, name in mac_apps:
        node = node_id(rng)
        app_nodes[bundle] = node
        record = f"lsBundleRecord:{bundle}"
        when = lib.cocoa(clock.ago(days=rng.uniform(1, 200)))
        g.simple(node, "PS1", "SB144", sources=apps, records=[record], when=when)
        g.simple(node, "PS33", name, sources=apps, records=[record], when=when)
        g.simple(node, "PS102", record, sources=apps, records=[record], when=when)
        g.simple(node, "nm_bundleID", bundle, sources=apps, records=[record], when=when)
        developer = next((d for prefix, d in DEVELOPERS if bundle.startswith(prefix)), None)
        if developer is None:
            continue
        if developer not in developers:
            team = "".join(rng.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(10))
            org = node_id(rng)
            developers[developer] = (org, team)
            g.simple(org, "PS1", "SB10", sources=apps, records=[record], when=when)
            g.simple(org, "PS33", developer, sources=apps, records=[record], when=when)
            g.simple(org, "nm_teamIdentifier", team, sources=apps, records=[record], when=when)
        org, team = developers[developer]
        g.simple(node, "PS194", ref(org), sources=apps, records=[record], when=when)
        if not bundle.startswith("com.apple."):
            g.simple(node, "nm_applicationIdentifier", f"{team}.{bundle}", sources=apps, records=[record], when=when)

    # ---- Life events, listening sessions and tickets (feed the life-event views) -----------
    life_map, music_map, future_map = [], [], []
    life_rows, music_rows, future_rows = [], [], []

    def event_node(kind: str, name: str, start: datetime.datetime, end: datetime.datetime, place: Place | None, written: datetime.datetime) -> int:
        node = node_id(rng)
        record = f"{kind}:{lib.uuid_string(rng)}"
        kw = dict(sources=source_mask(kind), records=[record], when=lib.cocoa(written))
        g.simple(node, "PS1", "SB65", **kw)
        g.simple(node, "PS33", name, **kw)
        g.simple(node, "PS102", record, **kw)
        g.facet(node, "nm_hasDate", "nm_dateRelationshipType",
                [("PS29", lt.components(start)), ("PS30", lt.components(end)),
                 ("nm_imputedStartTime", f"{lib.cocoa(start):.1f}"), ("nm_imputedEndTime", f"{lib.cocoa(end):.1f}")], **kw)
        if place is not None:
            g.facet(node, "PS225", "CS29", [("PS107", ref(place.graph_id))], **kw)
        return node

    visitable = [p for p in persona.places if p.key not in ("home", "work", "parents") and p.visits_per_month > 0]
    for _ in range(44):
        day = -rng.randrange(1, 90)
        if rng.random() < 0.3:
            name, minutes, hour, place = rng.choice([("Outdoor run", 38, 7, None), ("Indoor climb", 85, 18, persona.place("gym")),
                                                     ("Outdoor walk", 52, 12, None), ("Pool swim", 30, 7, persona.place("oriental"))])
            name = f"Workout: {name}"
        else:
            place = rng.choices(visitable, weights=[p.visits_per_month for p in visitable])[0]
            name, minutes, hour = f"Visit: {place.name}", rng.randrange(25, 150), rng.randrange(8, 20)
        start = lt.at(day, hour, rng.randrange(60))
        end = start + datetime.timedelta(minutes=minutes)
        node = event_node("lifeEvent", name, start, end, place, end + datetime.timedelta(minutes=20))
        life_map.append((node, lib.cocoa(start), lib.cocoa(end)))
        life_rows += [r[:5] for r in g.rows_of(node)]
    for _ in range(32):
        track = rng.choice(persona.tracks)
        start = lt.at(-rng.randrange(0, 60), rng.choice([8, 9, 10, 13, 15, 17, 21]), rng.randrange(60))
        if start > now:
            start -= datetime.timedelta(days=1)
        end = start + datetime.timedelta(seconds=track.seconds * rng.randrange(2, 9))
        node = event_node("bmAppleMusicEvent", f"Listening: {track.album} ({track.artist})", start, min(end, now), None, min(end, now))
        music_map.append((node, lib.cocoa(start), lib.cocoa(min(end, now))))
        music_rows += [r[:5] for r in g.rows_of(node)]
    for name, day, hour, minutes, place_key in (("Flight: Wellington to Auckland", 9, 7, 65, "airport"),
                                                ("Flight: Auckland to Wellington", 11, 18, 65, "auckland"),
                                                ("Concert: Marlow Quartet", 17, 20, 120, None),
                                                ("Movie: late session", 5, 20, 130, None),
                                                ("Flight: Wellington to Queenstown", 24, 8, 80, "airport"),
                                                ("Flight: Queenstown to Wellington", 27, 16, 80, "queenstown")):
        start = lt.at(day, hour, 5)
        end = start + datetime.timedelta(minutes=minutes)
        node = event_node("pkPass", name, start, end, persona.place(place_key) if place_key else None, clock.ago(days=rng.uniform(2, 20)))
        future_map.append((node, lib.cocoa(start), lib.cocoa(end)))
        future_rows += [r[:5] for r in g.rows_of(node)]

    # ---- Calendar events -------------------------------------------------------------------
    stable_rows_before_events = len(g.rows)
    events = _plan_events(persona, rng, lt)
    ev = GraphWriter(rng)
    expired_events: list[list] = []
    attendees = _write_events(ev, expired_events, persona, rng, clock, lt, events)
    # People who appear in calendar events are also known to the graph through EventKit.
    ek = source_mask("ekEvent")
    for key in sorted(attendees):
        person = by_key[key]
        record = _event_record(rng)
        g.simple(person.graph_id, "PS1", "SB104", sources=ek, records=[record], when=recent)
        g.simple(person.graph_id, "PS296", f"mailto:{person.email}", sources=ek, records=[record], when=recent)
    assert stable_rows_before_events <= len(g.rows)

    # ---- Superseded facts --------------------------------------------------------------------
    expired: list[list] = []

    def expire_facet(subject: int, predicate: str, type_class: str, fields: list[tuple[str, str]], record: str, days: float) -> None:
        relationship = rng.randrange(1, 1 << 62)
        when = lib.cocoa(clock.ago(days=days))
        for field, value in [("PS1", type_class)] + fields:
            expired.append([subject, predicate, relationship, field, value, contacts, 1.0, record, when])

    expire_facet(owner.graph_id, "PS520", "CS97", [("PS406", "robin.sample@example.net"), ("PS740", "_$!<Work>!$_")], owner_record, 210)
    expire_facet(owner.graph_id, "PS520", "CS97", [("PS407", "+12025550147"), ("PS740", "_$!<Mobile>!$_")], owner_record, 330)
    expire_facet(owner.graph_id, "PS317", "CS97", [("PS316", "Cuba Street"), ("PS453", "Wellington"), ("PS315", "6011"),
                                                   ("PS450", "New Zealand"), ("PS733", "_$!<Home>!$_")], owner_record, 395)
    expired.append([owner.graph_id, "PS33", 0, "", "Robin J Sample", contacts, 1.0, owner_record, lib.cocoa(clock.ago(days=395))])
    for index, key in enumerate(("alex", "jamie", "priya", "lucas", "tom", "mei", "landlord")):
        person = by_key[key]
        record = f"cnContact:{person.contact_id}"
        if index % 2 == 0:
            expire_facet(person.graph_id, "PS520", "CS97", [("PS407", f"+1202555015{index}"), ("PS740", "_$!<Mobile>!$_")], record, 90 + 40 * index)
        else:
            old = f"{person.given.lower()}{person.family[:1].lower()}@example.net"
            expire_facet(person.graph_id, "PS520", "CS97", [("PS406", old), ("PS740", "_$!<Home>!$_")], record, 90 + 40 * index)
    old_job = node_id(rng)
    expire_facet(by_key["lucas"].graph_id, "PS500", "CS165", [("PS45", ref(old_job))], f"cnContact:{by_key['lucas'].contact_id}", 260)

    # ---- graph.db ----------------------------------------------------------------------------
    full_run = clock.ago(days=5, hours=2, minutes=14)
    lib.create_db(base / "graph.db", GRAPH_DDL, {
        "stable_graph": g.rows,
        "event_graph": ev.rows,
        "expired_stable_graph": expired,
        "expired_event_graph": expired_events,
        "graph_state": [("buildFromScratchTimestamp", lib.cocoa(full_run)),
                        ("expiredTriplesPruneTimestamp", lib.cocoa(clock.ago(days=1, hours=3, minutes=40)))],
        "phase_status": [(n, 3) for n in range(1, PHASE_COUNT + 1)],
    })

    # ---- ontology.db -------------------------------------------------------------------------
    lib.create_db(base / "ontology.db", ONTOLOGY_DDL, {
        "class": sorted(CLASSES.items()),
        "inheritance": INHERITANCE,
        "predicate": [(pid, spec[0], spec[1]) for pid, spec in sorted(PREDICATES.items())],
        "predicate_domain": [(pid, d) for pid, spec in sorted(PREDICATES.items()) for d in spec[2]],
        "predicate_range": [(pid, spec[3][0], spec[3][1]) for pid, spec in sorted(PREDICATES.items())],
        "relationship_type": RELATIONSHIP_TYPES,
        "version": [("class.json", "v2.10", "v2.00"), ("inheritance.json", "v2.04", "v2.00"),
                    ("predicate.json", "v3.21", "v3.00"), ("relationship_type.json", "v1.06", "v1.00")],
    })

    # ---- Behaviour ----------------------------------------------------------------------------
    interactions = _interactions(persona, rng, clock, lt)
    per_person: dict[str, list[datetime.datetime]] = {p.key: [] for p in persona.others}
    for when, person, _, _, _ in interactions:
        per_person[person.key].append(when)
    total_interactions = max(1, len(interactions))

    appearances: list[tuple[datetime.datetime, Person]] = []
    for key in PHOTO_PEOPLE:
        person = by_key[key]
        count = 150 if person is owner else int(10 + 130 * person.closeness ** 2)
        for when in clock.spread(rng, count, days=300, hours=(9, 22), recent_bias=1.1):
            appearances.append((when, person))
    appearances.sort(key=lambda item: item[0])

    wifi_events: list[tuple[datetime.datetime, str]] = []
    loi_events: list[tuple[datetime.datetime, str]] = []
    ssid = {n.place: n.ssid for n in persona.networks if n.ssid != persona.device("iphone").name}
    for day in range(120, -1, -1):
        weekday = lt.weekday(-day)
        stops = [("home", 7)]
        if weekday < 5:
            stops += [("work", 9), ("cafe", 12)] if rng.random() < 0.3 else [("work", 9)]
            if weekday == 3:
                stops.append(("gym", 18))
            stops.append(("home", 18 if weekday != 3 else 20))
        elif rng.random() < 0.5:
            stops += [("cafe", 10), ("home", 13)]
        for key, hour in stops:
            when = clock.at(day, hour, rng.randrange(60), rng.randrange(60))
            if key in ssid:
                wifi_events.append((when, f"wifi:{ssid[key]}"))
            if key in ("home", "work", "gym"):
                loi_events.append((when, key))

    # ---- Artifacts/entityTagging ---------------------------------------------------------------
    event_id = rng.randrange(400, 900)
    tagging_rows = []
    for person in persona.people:
        chosen = TAGGING[person.key]
        row = [str(person.graph_id)]
        for label in TAGGING_LABELS:
            row.append(chosen.get(label, round(rng.uniform(0.004, 0.08), 4)))
        row.append(event_id)
        tagging_rows.append(row)
    association_rows = [r[:5] for r in g.rows_of(owner.graph_id) if r[1] in ("PS598", "nm_isCurrentUser")]
    lib.create_db(artifacts / "entityTagging/entityTagging.db", TAGGING_DDL,
                  {"entity_tagging": tagging_rows, "has_association_subgraph": association_rows})

    # ---- Artifacts/entityRelevance --------------------------------------------------------------
    card_labels = {"alex": "partner,spouse", "helen": "mother,parent", "david": "father,parent", "jamie": "sister",
                   "priya": "friend", "aroha": "manager"}
    lib.create_db(artifacts / "entityRelevance/entityImportanceSignals.db", IMPORTANCE_DDL, {
        "entityImportanceSignalsIDMap": [
            (p.graph_id, int(p.favourite), int(p.key in ("alex", "helen")), int(p.key == "alex"), card_labels.get(p.key, ""))
            for p in persona.others],
    })

    def explanation(person: Person, long_term: bool) -> str:
        names = ["posteriorProbabilityGivenContext:coarseTimeOfDay", "posteriorProbabilityGivenContext:dayOfWeek",
                 "posteriorProbabilityGivenContext:coarseTimeOfDay+dayOfWeek", "behaviorPopularityGivenContext:coarseTimeOfDay",
                 "behaviorPopularityGivenContext:dayOfWeek", "contextPopularityGivenBehavior:coarseTimeOfDay",
                 "contextPopularityGivenBehavior:dayOfWeek", "longTermTrendingPopularity", "shortTermTrendingPopularity",
                 "behaviorPopularityGivenSequence", "sequencePopularityGivenBehavior", "lastExecutionAge",
                 "dailyDoseL1Error", "dailyDoseL2Error"]
        rng.shuffle(names)
        split = 3 + int(person.closeness * 6)
        share = len(per_person[person.key]) / total_interactions

        def item(name: str, positive: bool) -> dict:
            if name == "lastExecutionAge":
                value: float = round((now - max(per_person[person.key])).total_seconds())
            elif positive:
                value = round(min(0.98, share * rng.uniform(0.9, 3.2) + rng.uniform(0.01, 0.1)), 4)
            else:
                value = rng.choice([0, 0, round(rng.uniform(0.001, 0.02), 4)])
            z = rng.uniform(0.2, 2.8) * (1 if positive else -1)
            return {"value": value, "zScore": round(z, 3), "name": name,
                    "importance": round(rng.uniform(0.01, 0.22) * (1.4 if long_term and "longTerm" in name else 1), 4)}

        return json.dumps({"negativeContributions": [item(n, False) for n in names[split:]],
                           "positiveContributions": [item(n, True) for n in names[:split]]}, separators=(",", ":"))

    relevance, longterm, relevance_score = [], [], {}
    for person in persona.others:
        if not per_person[person.key]:
            continue
        recent_share = sum(1 for w in per_person[person.key] if (now - w).days < 21) / max(1, sum(1 for w, *_ in interactions if (now - w).days < 21))
        score = round(min(0.97, 0.04 + 2.6 * recent_share + rng.uniform(0, 0.03)), 4)
        long_score = round(min(0.97, 0.05 + 2.4 * len(per_person[person.key]) / total_interactions + rng.uniform(0, 0.03)), 4)
        relevance_score[person.key] = score
        relevance.append((str(person.graph_id), score, explanation(person, False), event_id + 1))
        longterm.append((str(person.graph_id), long_score, explanation(person, True), event_id + 2))
    lib.create_db(artifacts / "entityRelevance/entityRelevanceInferences.db", RELEVANCE_DDL,
                  {"person_entity_relevance": relevance, "person_entity_longterm": longterm})

    # ---- Artifacts/feature -----------------------------------------------------------------------
    kv: list[tuple] = []
    local_now = lt.local(now)
    kv.append(("currentCoarseTimeOfDayContext", "index", "", feature_value(DAY_PARTS.index(day_part(local_now.hour))), None))
    kv.append(("currentDayOfWeekContext", "index", "", feature_value(local_now.weekday()), None))

    def distribution(stamps: list[datetime.datetime]) -> tuple[dict, dict, dict]:
        parts = {p: 0 for p in DAY_PARTS}
        days = {d: 0 for d in DAY_NAMES}
        both: dict[str, int] = {}
        for stamp in stamps:
            local = lt.local(stamp)
            part, day = day_part(local.hour), DAY_NAMES[local.weekday()]
            parts[part] += 1
            days[day] += 1
            both[day + part] = both.get(day + part, 0) + 1
        return parts, days, both

    all_parts, all_days, all_both = distribution([w for w, *_ in interactions])

    def tagging_features(view: str, noun: str, stamps: list[datetime.datetime], everyone: tuple[dict, dict, dict], total: int, subject: str) -> None:
        parts, days, both = distribution(stamps)
        count = max(1, len(stamps))
        every_parts, every_days, every_both = everyone
        upper = noun[:1].upper() + noun[1:]

        def add(name: str, value: float) -> None:
            kv.append((view, name, subject, feature_value(round(float(value), 5)), None))

        add(f"{noun}OverallPopularity", len(stamps) / max(1, total))
        add(f"{noun}LongTermPopularity", len(stamps) / max(1, total) * rng.uniform(0.8, 1.1))
        contexts = [(p, parts[p], every_parts[p]) for p in DAY_PARTS] + [(d, days[d], every_days[d]) for d in DAY_NAMES]
        weekday = sum(days[d] for d in DAY_NAMES[:5])
        contexts += [("Weekday", weekday, sum(every_days[d] for d in DAY_NAMES[:5])),
                     ("Weekend", len(stamps) - weekday, sum(every_days[d] for d in DAY_NAMES[5:]))]
        work_share = sum(1 for s in stamps if lt.local(s).weekday() < 5 and 9 <= lt.local(s).hour < 17)
        for focus in FOCUSES:
            mine = work_share if focus == "WorkFocus" else (len(stamps) - work_share if focus == "DefaultFocus" else 0)
            contexts.append((focus, mine, max(1, total // 2)))
        for context, mine, everyone_count in contexts:
            add(f"{lower_first(context)}PopularityGiven{upper}", mine / count)
            add(f"{noun}PopularityGiven{context}", mine / max(1, everyone_count))
            add(f"{noun}PosteriorProbabilityGiven{context}", min(1.0, (mine + 0.5) / (everyone_count + 8)))
        for day in DAY_NAMES:
            for part in DAY_PARTS:
                add(f"{noun}PosteriorProbabilityGiven{day}{part}", min(1.0, (both.get(day + part, 0) + 0.25) / (every_both.get(day + part, 0) + 6)))

    photo_stamps = {p.key: [w for w, q in appearances if q is p] for p in persona.people}
    photo_all = distribution([w for w, _ in appearances])
    for person in persona.people:
        subject = ref(person.graph_id)
        is_owner = person is owner
        # Facts.
        facts: dict[str, object] = {
            "isCurrentUser": int(is_owner),
            "relationshipWithUser": "self" if is_owner else (person.relationship if person.relationship_label else "none"),
            "hasBirthday": int(person.birthday is not None),
            "sameLastName": int(person.family == owner.family),
            "isFamily": int(person in persona.family or is_owner),
            "iCloudFamilyMember": int(person.key in ("robin", "alex")),
            "iCloudFamilyMemberType": "ADULT" if person.key in ("robin", "alex") else "none",
            "sharesHomeAddress": int(person.key in ("robin", "alex")),
            "sharesWorkAddress": int(person.organization == persona.company),
            "hasSameEmailDomains": int(any(e.endswith(persona.company_domain) for e in person.emails)),
            "hasSamePrivateEmailDomain": 0,
            "nameCategoryMatch": int(person.relationship in ("mother", "father")),
            "partialNameCategoryMatch": int(bool(person.nickname)),
        }
        if person.birthday:
            age = age_on(lt.today, person.birthday)
            difference = age - age_on(lt.today, owner.birthday)
            facts["personAge"] = age
            facts["ageDifferenceCategory"] = 0 if abs(difference) < 8 else (2 if difference > 0 else 1)
        if person.key in PHOTO_PEOPLE:
            facts["photosPersonAge"] = 4 if person.key in ("helen", "david") else 3
            facts["photosAgeDifferenceCategory"] = 2 if person.key in ("helen", "david") else 0
        for name, value in sorted(facts.items()):
            kv.append(("personEntityTaggingFacts", name, subject, feature_value(value), None))
        if is_owner:
            continue
        stamps = per_person[person.key]
        tagging_features("personEntityTagging", "person", stamps, (all_parts, all_days, all_both), total_interactions, subject)
        if person.key in PHOTO_PEOPLE:
            tagging_features("photosPersonEntityTagging", "photosPerson", photo_stamps[person.key], photo_all, len(appearances), subject)
        # Relevance model inputs.
        share = len(stamps) / total_interactions
        gaps = sorted((b - a).total_seconds() for a, b in zip(stamps, stamps[1:])) or [0.0]
        non_contextual = {
            "totalCount": len(stamps),
            "lastExecutionAge": round((now - max(stamps)).total_seconds(), 1) if stamps else 0.0,
            "medianTimeIntervalBetweenExecution": round(gaps[len(gaps) // 2], 1),
            "trendingPopularity": round(share * rng.uniform(0.8, 1.3), 5),
            "shortTermTrendingPopularity": round(relevance_score.get(person.key, 0.0) / 2.6, 5),
            "longTermTrendingPopularity": round(share, 5),
            "behaviorPopularityGivenSequence": round(share * rng.uniform(0.5, 2.0), 5),
            "sequencePopularityGivenBehavior": round(rng.uniform(0.02, 0.4), 5),
            "dailyDoseL1Error": round(rng.uniform(0.1, 1.9), 5),
            "dailyDoseL2Error": round(rng.uniform(0.05, 1.2), 5),
        }
        for name in NON_CONTEXTUAL:
            kv.append(("personEntityRelevanceNonContextualFeatures", name, subject, feature_value(non_contextual[name]), None))
        for view, context in (("personEntityRelevanceCoarseTimeOfDayFeatures", "coarseTimeOfDay"),
                              ("personEntityRelevanceDayOfWeekFeatures", "dayOfWeek"),
                              ("personEntityRelevanceWiFiFeatures", "wifi"), ("personEntityRelevanceLOIFeatures", "loi")):
            for prefix in ("behaviorPopularityGivenContext", "contextPopularityGivenBehavior", "posteriorProbabilityGivenContext"):
                kv.append((view, f"{prefix}:{context}", subject, feature_value(round(min(0.99, share * rng.uniform(0.4, 3.0)), 5)), None))
        kv.append(("personEntityRelevanceCoarseTimeOfDayAndDayOfWeekFeatures", "posteriorProbabilityGivenContext:coarseTimeOfDay+dayOfWeek",
                   subject, feature_value(round(min(0.99, share * rng.uniform(0.4, 3.0)), 5)), None))
    place_rows = [r[:5] for p in persona.places for r in g.rows_of(p.graph_id)]
    lib.create_db(artifacts / "feature/features.db", FEATURES_DDL, {"kv": kv, "location_subgraph_features": place_rows})

    # ---- Artifacts/internal ------------------------------------------------------------------------
    alias_rows = []
    for person in persona.people:
        for alias, signal, confidence in _aliases(person, person is owner):
            alias_rows.append((person.graph_id, alias, "SB104", signal, confidence))
    for bundle, name in mac_apps:
        alias_rows.append((app_nodes[bundle], "\t".join(name.lower().split()), "SB144", "full_provided_alias", 1.0))
    for place in persona.places:
        if place.key not in ("home", "work", "parents"):
            alias_rows.append((place.graph_id, "\t".join(place.name.lower().split()), "SB152", "full_provided_alias", 1.0))
    handles = sorted({(h, p.graph_id) for p in persona.people for h in list(p.emails) + list(p.phones)})
    photo_map = [(f"{photos_person_uuid(persona, by_key[k])}/L0/070", by_key[k].graph_id) for k in PHOTO_PEOPLE]

    def mechanism_rows(only_outgoing: bool) -> list[dict]:
        seen, rows = set(), []
        for when, person, mechanism, bundle, outgoing in interactions:
            if only_outgoing and not outgoing:
                continue
            key = (person.graph_id, round(lib.cocoa(when), 3), mechanism, bundle)
            if key in seen:
                continue
            seen.add(key)
            rows.append({"entityIdentifier": ref(person.graph_id), "interactionDate": key[1],
                         "communicationMechanism": mechanism, "bundleID": bundle})
        return rows

    def photos_age(person: Person) -> int:
        return 4 if person.key in ("helen", "david") else 3

    people_rows = [r[:5] for p in persona.people for r in g.rows_of(p.graph_id)]
    people_ids = {p.graph_id for p in persona.people}
    lib.create_db(artifacts / "internal/views.db", INTERNAL_VIEWS_DDL, {
        "entity_alias": alias_rows,
        "handle_id": handles,
        "phperson_id_map": photo_map,
        "wifiContextEvents": _with_gaps(wifi_events, 10),
        "loiContextEvents": _with_gaps(loi_events, 11),
        "personEntityInteractionEvents": _with_gaps([(w, ref(p.graph_id)) for w, p, _, _, out in interactions if out], 18),
        "bidirectionalPersonEntityInteractionEvents": _with_gaps([(w, ref(p.graph_id)) for w, p, _, _, _ in interactions], 18),
        "photosPersonEntityInteractionEvents": _with_gaps([(w, ref(p.graph_id)) for w, p in appearances], 18),
        "personEntityHistogramKeys": [(ref(p.graph_id),) for p in persona.others],
        "bidirectionalPersonEntityHistogramKeys": [(ref(p.graph_id),) for p in persona.others],
        "photosPersonEntityHistogramKeys": [(ref(by_key[k].graph_id),) for k in PHOTO_PEOPLE],
        "personInteractionMechanisms": mechanism_rows(True),
        "bidirectionalPersonInteractionMechanisms": mechanism_rows(False),
        "photosObservedAges": [{"entityIdentifier": ref(p.graph_id), "interactionDate": round(lib.cocoa(w), 3),
                                "observedAge": photos_age(p) if rng.random() < 0.9 else photos_age(p) + rng.choice([-1, 1])}
                               for w, p in appearances],
        "people_relationship": [(p.graph_id,) + RELATION_WORDS[p.relationship] for p in persona.others
                                if p.relationship_label and p.relationship in RELATION_WORDS],
        "people_subgraph": people_rows,
        "entity_subgraph": [r[:5] for r in g.rows if r[0] not in people_ids and r[0] not in app_nodes.values()],
        "app_subgraph": [r[:5] for node in app_nodes.values() for r in g.rows_of(node)],
        "event_subgraph": [r[:5] for r in ev.rows],
    })

    # ---- Artifacts/internal/inferred_triples.db: languages ---------------------------------------------
    inferred = lib.cocoa(clock.ago(days=2, hours=5))
    language_rows = []
    language_ids = sorted(node_id(rng) for _ in range(2))
    evidence = json.dumps({"en": {"Device Language": 1, "Device Region": 1, "Keyboards": 2}, "mi": {"Keyboards": 1}}, separators=(",", ":"))
    for code, locale, region, overall, reading, writing, listening, source_types in (
            ("en", "en_NZ", "NZ", 0.98, 0.97, 0.95, 0.9, ["Device Language", "Device Region", "Keyboards"]),
            ("mi", "mi_NZ", "NZ", 0.31, 0.22, 0.34, 0.12, ["Keyboards"])):
        subject = language_ids.pop(0)
        for predicate, value in (("PS1", "SB74"), ("PS33", code), ("nm_localeIdentifier", locale), ("PS569", region),
                                 ("nm_confidence", str(overall)), ("nm_reading_confidence", str(reading)),
                                 ("nm_writing_confidence", str(writing)), ("nm_listening_confidence", str(listening)),
                                 ("nm_sourceType", json.dumps(source_types)), ("PS51", evidence)):
            language_rows.append((subject, predicate, 0, "", value, overall, 0, inferred))
    lib.create_db(artifacts / "internal/inferred_triples.db", LANGUAGES_DDL, {"languages": language_rows})

    # ---- Artifacts/ecr -----------------------------------------------------------------------------
    summaries = []
    for person in persona.people:
        colleagues = [p.full_name.lower() for p in persona.people if p is not person and p.organization and p.organization == person.organization][:3]
        signals = {"events": sorted({e.title.lower() for e in events if person.key in e.people})[:3] or None,
                   "locations": ["wellington"] if person.key not in ("helen", "david") else ["paraparaumu"],
                   "people": colleagues or ([owner.full_name.lower()] if person is not owner else [partner.full_name.lower()]),
                   "miscellaneous": None}
        summaries.append((person.graph_id, "SB104", f"{person.given.lower()}\t{person.family.lower()}", person.given.lower(), None,
                          person.family.lower(), person.nickname.lower() or None, None, None,
                          json.dumps(signals, separators=(",", ":")), 1.0 if person is owner else relevance_score.get(person.key, 0.0),
                          event_id + 1))
    lib.create_db(artifacts / "ecr/views.db", ECR_DDL, {
        "entity_alias_ecr": alias_rows,
        "asr_entity_alias": [(p.graph_id, f"{p.given.lower()}\t{p.family.lower()}", "SB104", "full_provided_alias", p.contact_id)
                             for p in persona.people],
        "entity_summary": summaries,
    })

    # ---- Artifacts/confidenceService ------------------------------------------------------------------
    lib.create_db(artifacts / "confidenceService/sourceConfidence.db", CONFIDENCE_DDL, {
        "sourceConfidence": [("priorBelief", source, signal, round(rng.choice([0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 1.0]), 2))
                             for source, signals in CONFIDENCE_SOURCES.items() for signal in signals],
    })

    # ---- Life-event views -----------------------------------------------------------------------------
    lib.create_db(artifacts / "lifeEvent/lifeEventView.db", event_map_ddl("lifeEvent"),
                  {"lifeEvent_map": life_map, "lifeEvent_subgraph": life_rows})
    lib.create_db(artifacts / "futureLifeEvent/futureLifeEventView.db", event_map_ddl("futureLifeEvent"),
                  {"futureLifeEvent_map": future_map, "futureLifeEvent_subgraph": future_rows})
    lib.create_db(artifacts / "appleMusicEvent/appleMusicEventView.db", event_map_ddl("appleMusicEvent"),
                  {"appleMusicEvent_map": music_map, "appleMusicEvent_subgraph": music_rows})

    # ---- First-party topics (shared with the profile module: only created when missing) -------------------
    weights = max(t.weight for t in persona.topics)
    for name, pick, scale in (("scoredTopicsFirstPartyLongTerm.db", persona.topics, 1.0),
                              ("scoredTopicsFirstPartyShortTerm.db", rng.sample(persona.topics, 9), 0.7)):
        path = artifacts / "firstPartyTopics" / name
        if path.exists():
            continue
        lib.create_db(path, TOPICS_DDL, {"topics": [
            (t.qid, round(min(0.99, t.weight / weights * scale * rng.uniform(0.55, 1.0)), 4), lib.uuid_string(rng)) for t in pick]})

    # ---- views.db -----------------------------------------------------------------------------------------
    view_rows, state_rows, table_rows = [], [], []
    for index, (name, generation, artifact, path, table) in enumerate(VIEW_CATALOG, start=1):
        dependencies = "[]" if generation in ("signal", "biomeIncremental") else json.dumps(["peopleSubgraph"] if "erson" in name else ["entitySubgraph"])
        view_rows.append((index, name, lib.hex_string(rng, 16), generation, name[:1].upper() + name[1:] if generation == "custom" else None,
                          "personEntityRelevance" if name.startswith("personEntityRelevance") else None, 0, artifact,
                          path, table, dependencies, "[]", "{}", "default"))
        failed = name in ("entityAliasEuclidVDB",)
        state_rows.append((index, 0, 2 if failed else 0, "Embedding asset is not available on this device" if failed else None,
                           rng.choice([0, 2, 3]), int(table is not None and not failed), rng.choice(["viewChanged", "updatedObject"]), None))
        if table:
            table_rows.append((index, table))
    source_rows = []

    def add_source(kind: str, identifier: str, update: str, hours: float, available: bool = True) -> None:
        source_rows.append((len(source_rows) + 1, kind, identifier, update, lib.cocoa(clock.ago(hours=hours)), int(available), None))

    add_source("alwaysUpdate", "alwaysUpdate", "normal", 0.2)
    for stream in BIOME_SOURCES:
        add_source("biome", stream, "normal", rng.uniform(0.1, 30))
        add_source("biome", stream, "deletion", rng.uniform(30, 400))
    for device in persona.remote_devices:
        for stream in SYNCED_SOURCES:
            add_source("biome", f"{stream}:remotes:{device.identifier}", "normal", rng.uniform(1, 90), device.key != "ipad")
    for stream in ("Location.HashedCoordinates", "IntelligenceFlow.Transcript.Datastream"):
        add_source("biome", stream, "normal", rng.uniform(200, 900), False)
    for asset in ("HolidayEventSubgraph", "MediaEntitiesSubgraph", "PriorBeliefs"):
        add_source("globalKnowledgeGraph", asset, "normal", rng.uniform(100, 400))
    add_source("keyValueDatabase", "photosAutonamingFeedback", "normal", rng.uniform(40, 200))
    add_source("knowledgeGraph", "", "normal", 27.2)
    for name, generation, *_ in VIEW_CATALOG:
        if generation != "vectordb":
            add_source("view", name, "normal", rng.uniform(0.3, 48))
    lib.create_db(base / "views.db", VIEWS_DDL, {
        "viewConfigRecord": view_rows,
        "viewState": state_rows,
        "viewTables": table_rows,
        "scheduleState": [(s, "needsUpdate" if s in ("live", "every7Minutes", "every21Minutes") else "updated", 0) for s in SCHEDULES],
        "sourceState": source_rows,
        "keyValue": [("bootSession", lib.uuid_string(rng)), ("version", "12"), ("schedules", json.dumps(SCHEDULES)),
                     ("remoteDevices", json.dumps([d.identifier for d in persona.remote_devices]))],
    })

    # ---- keyvalue.db ------------------------------------------------------------------------------------------
    def blob(value) -> bytes:
        return lib.plist_bytes(value)

    kv_rows: list[tuple] = []
    delta_start = clock.ago(days=1, hours=3, minutes=12)
    for domain, kind, start, seconds, runs in (("Pipeline.Status.full.previous", "full", full_run, 412, 9),
                                               ("Pipeline.Status.delta.previous", "delta", delta_start, 37, 214)):
        finish = start + datetime.timedelta(seconds=seconds)
        kv_rows += [
            (domain, "lastPipelineRunStartDate", blob(start)), (domain, "lastPipelineRunFinishDate", blob(finish)),
            (domain, "lastPipelineType", blob(kind)), (domain, "sessionPipelineType", blob(kind)),
            (domain, "numberOfFinishedPipelineRuns", blob(runs)), (domain, "pipelineFinishStatus", blob("success")),
            (domain, "previousSessionFinishDate", blob(start - datetime.timedelta(days=1 if kind == "delta" else 7, minutes=3))),
            (domain, "sessionId", blob(lib.uuid_string(rng))),
        ]
        offset = 0.0
        for source in ("CNContact", "PHPerson", "EKEvent", "FAFamily", "LSBundleRecord", "PGPerson"):
            spent = round(rng.uniform(0.4, seconds / 5), 3)
            kv_rows += [
                (domain, f"{source}: <PipelineType: {kind}>.phaseStartTime", blob(start + datetime.timedelta(seconds=offset))),
                (domain, f"{source}: <PipelineType: {kind}>.phaseTimeSpent", blob(spent)),
                (domain, f"{source}: <PipelineType: {kind}>.phaseWallClockLatency", blob(round(spent * rng.uniform(1.0, 1.6), 3))),
            ]
            offset += spent
    for person in persona.people:
        kv_rows.append(("EntityToGraphIdResolver", f"cnContact:{person.contact_id}", blob(person.graph_id)))
    for bundle, _ in mac_apps:
        kv_rows.append(("EntityToGraphIdResolver", f"lsBundleRecord:{bundle}", blob(app_nodes[bundle])))
    for key in PHOTO_PEOPLE:
        person = by_key[key]
        local_id = f"{photos_person_uuid(persona, person)}/L0/070"
        kv_rows.append(("EntityToGraphIdResolver", f"phPerson:{local_id}", blob(person.graph_id)))
        kv_rows.append(("VisionSignalsVisionToEntity", local_id, blob({"entity": ref(person.graph_id), "confidence": round(rng.uniform(0.7, 0.98), 3)})))
        kv_rows.append(("VisionSignalsEntityToVision", ref(person.graph_id), blob({"visualIdentifier": local_id, "faceCount": len(photo_stamps[key])})))
        kv_rows.append(("VisionSignalsVisionToName", local_id, blob({"name": person.full_name, "source": "contact"})))
    for qid, words in RELATIONSHIP_ALIASES.items():
        kv_rows.append(("RelationshipAliasKV", words[0], blob([words[0]] + EXTRA_ALIASES.get(qid, []))))
    for label in ("Partner", "Mother", "Father", "Sister", "Brother", "Friend", "Manager", "Child", "Parent", "Spouse"):
        kv_rows.append(("RelationshipAliasKV", f"_$!<{label}>!$_", blob([label.lower()])))
    for kind in ("CNContact", "PHPerson", "FAFamilyCircle", "EKCalendarItemIdentifier", "EKCalendarExternalIdentifier", "EKBirthdayContactID"):
        kv_rows.append(("IdentifierRelationshipKV", kind, blob({"identifierType": kind, "relationshipType": "CS22"})))
    for name in ("personEntityHistograms", "bidirectionalPersonEntityHistograms", "photosPersonEntityHistograms", "loiEntityHistograms",
                 "currentWiFiContext", "currentLOIContext", "currentCoarseGeoHashContext", "currentSpecificGeoHashContext"):
        kv_rows.append((f"{name}.ERHistogramDigest", "digest", blob(lib.hex_string(rng, 40))))
    kv_rows.append(("kConstruction", "state", blob({"lastFullBuild": full_run, "schemaVersion": 12})))
    lib.create_db(base / "keyvalue.db", KEYVALUE_DDL, {"keyvalue": kv_rows})

    # ---- aliases.db (reference data) -----------------------------------------------------------------------------
    alias_reference = []
    for qid, words in RELATIONSHIP_ALIASES.items():
        for language, word in zip(LANGUAGE_WORDS, words):
            alias_reference.append((qid, language, word))
        for word in EXTRA_ALIASES.get(qid, []):
            alias_reference.append((qid, "en", word))
    lib.create_db(base / "aliases.db", "CREATE TABLE aliases(qid, localization, alias);", {"aliases": alias_reference})

    # ---- globalKnowledge.db (reference data) -----------------------------------------------------------------------
    static_rows = []
    subject = -1000
    for year in (lt.today.year - 1, lt.today.year, lt.today.year + 1):
        for name, month, day in HOLIDAYS:
            subject -= 1
            date = json.dumps({"day": day, "isLeapMonth": False, "month": month, "year": year}, separators=(",", ":"))
            static_rows += [(3, subject, "PS1", 0, "", "SB65", 1.0), (3, subject, "PS33", 0, "", name, 1.0),
                            (3, subject, "PS102", 0, "", f"holiday:NZ:{year}:{name.lower().replace(' ', '-')}", 1.0),
                            (3, subject, "nm_occurrenceDate", 0, "", date, 1.0)]
    for source, signals in CONFIDENCE_SOURCES.items():
        for signal in signals:
            subject -= 1
            relationship = rng.randrange(1, 1 << 62)
            static_rows += [(1, subject, "PS1", 0, "", "nm_priorBelief", 1.0), (1, subject, "PS33", 0, "", f"{source}.{signal}", 1.0),
                            (1, subject, "nm_hasConfidence", relationship, "PS1", "nm_confidenceRelationshipType", 1.0),
                            (1, subject, "nm_hasConfidence", relationship, "nm_hasField", signal, 1.0),
                            (1, subject, "nm_hasConfidence", relationship, "nm_confidence", str(rng.choice([0.5, 0.7, 0.8, 0.9, 1.0])), 1.0)]
    lib.create_db(base / "globalKnowledge.db", GLOBAL_DDL, {
        "static_assets": [(1, "PriorBeliefs", 3, "json", None), (2, "MediaEntitiesSubgraph", 5, "json", None),
                          (3, "HolidayEventSubgraph", 7, "json", None)],
        "static_graph": static_rows,
    })
