"""Shared helpers for the demo-data generators. Python 3 standard library only.

    from demo import lib
    from demo.lib import pb

Everything written here is invented content in the real stores' formats. Nothing in this
package ever reads a real store.

Sections: paths below a demo root · dates · identifiers · SQLite · protobuf encoder ·
Biome SEGB segments, streams and sync.db · plists and NSKeyedArchiver · LZFSE (stored) ·
small file helpers.
"""

from __future__ import annotations

import datetime as _dt
import os
import pathlib
import plistlib
import random
import sqlite3
import struct
import hashlib
import uuid as _uuid
import zlib
from contextlib import contextmanager
from typing import Any, Iterable, Iterator, Mapping, Optional, Sequence, Union

Path = pathlib.Path
UTC = _dt.timezone.utc

# --------------------------------------------------------------------------------------
# Paths below a demo root (mirror of Sources/DossierCore/Data/Paths.swift in demo mode)
# --------------------------------------------------------------------------------------

#: Where Paths.darwinUserDirectory points below a demo root.
DARWIN_USER_DIR = "/private/var/folders/demo/0"


def home(root: Path) -> Path:
    """`<root>/Home` — what the app treats as the home directory (Paths.home)."""
    return Path(root) / "Home"


def library(root: Path, relative: str = "") -> Path:
    """`<root>/Home/Library[/relative]` (Paths.library)."""
    base = home(root) / "Library"
    return base / relative if relative else base


def system(root: Path, absolute_path: str) -> Path:
    """An absolute system location below the root (Paths.system):
    system(root, "/private/var/db/CoreDuet/People") -> <root>/private/var/db/CoreDuet/People"""
    if not absolute_path.startswith("/"):
        raise ValueError("system() takes an absolute path: " + absolute_path)
    return Path(root) / absolute_path.lstrip("/")


def darwin_user_dir(root: Path) -> Path:
    """`<root>/private/var/folders/demo/0` (Paths.darwinUserDirectory)."""
    return system(root, DARWIN_USER_DIR)


def photos_library(root: Path) -> Path:
    """`<root>/Home/Pictures/Photos Library.photoslibrary` (Paths.photosLibrary)."""
    return home(root) / "Pictures" / "Photos Library.photoslibrary"


def ensure_dir(path: Path) -> Path:
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True)
    return path


def ensure_parent(path: Path) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def write_bytes(path: Path, data: bytes) -> Path:
    ensure_parent(path).write_bytes(data)
    return Path(path)


def write_text(path: Path, text: str) -> Path:
    ensure_parent(path).write_text(text, encoding="utf-8")
    return Path(path)


SEED = 0
"""The run's seed; `make-demo-data.py` sets it before any generator runs."""


def daemon_container(root: Path, identifier: str, rng: random.Random) -> Path:
    """Creates `~/Library/Daemon Containers/<uuid>/` with the container-manager metadata
    plist the app uses to find a daemon's container (Paths.daemonContainerData) and returns
    its `Data` directory. Calling it again for the same identifier returns the same one."""
    base = ensure_dir(library(root, "Daemon Containers"))
    meta_name = ".com.apple.containermanagerd.metadata.plist"
    for existing in sorted(base.iterdir()):
        meta = existing / meta_name
        if meta.is_file():
            with meta.open("rb") as handle:
                if plistlib.load(handle).get("MCMMetadataIdentifier") == identifier:
                    return ensure_dir(existing / "Data")
    # From the seed and the identifier alone, not from `rng`: how far a module's random
    # stream has advanced depends on the clock, and a container's name is visible in paths.
    def derived(purpose: str) -> str:
        digest = hashlib.sha256(f"dossier-demo-{SEED}-{purpose}-{identifier}".encode("utf-8")).digest()
        return str(_uuid.UUID(bytes=digest[:16], version=4)).upper()
    container = base / derived("container")
    ensure_dir(container / "Data")
    write_plist(container / meta_name, {
        "MCMMetadataIdentifier": identifier,
        "MCMMetadataContentClass": 10,
        "MCMMetadataVersion": 6,
        "MCMMetadataUUID": derived("metadata"),
    }, binary=True)
    return container / "Data"


# --------------------------------------------------------------------------------------
# Dates
# --------------------------------------------------------------------------------------

#: Seconds between the Unix epoch (1970) and the Cocoa reference date (2001-01-01 UTC).
COCOA_EPOCH = 978_307_200
#: Seconds between the WebKit / Chrome epoch (1601) and the Unix epoch.
WEBKIT_EPOCH = 11_644_473_600

DateLike = Union[_dt.datetime, float, int]


def _aware(value: _dt.datetime) -> _dt.datetime:
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)


def unix(value: DateLike) -> float:
    """Seconds since 1970 (a datetime, or a number that already is Unix seconds)."""
    if isinstance(value, _dt.datetime):
        return _aware(value).timestamp()
    return float(value)


def cocoa(value: DateLike) -> float:
    """Seconds since 2001-01-01 UTC (CoreData / Biome / NSDate): cocoa(now) -> 8.1e8"""
    return unix(value) - COCOA_EPOCH


def from_cocoa(seconds: float) -> _dt.datetime:
    return _dt.datetime.fromtimestamp(seconds + COCOA_EPOCH, UTC)


def unix_ms(value: DateLike) -> int:
    return int(round(unix(value) * 1000))


def webkit_us(value: DateLike) -> int:
    """Microseconds since 1601 (WebKit / Chrome history timestamps)."""
    return int(round((unix(value) + WEBKIT_EPOCH) * 1_000_000))


def iso(value: DateLike) -> str:
    """2026-01-31T09:15:00Z"""
    return _dt.datetime.fromtimestamp(unix(value), UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


class Clock:
    """Dates relative to `now`, so that a data set always looks current.

        clock = lib.Clock(now, tz_offset_hours=persona.tz_offset_hours)
        clock.ago(days=3, hours=2)                      # datetime (UTC)
        clock.at(days_ago=1, hour=8, minute=30)         # 08:30 local time yesterday
        clock.spread(rng, 200, days=90)                 # 200 sorted datetimes, waking hours
        clock.sessions(rng, days=30, per_day=(3, 9))    # [(start, seconds)] app-like sessions
        lib.cocoa(clock.ago(hours=1))                   # -> Cocoa seconds
    """

    def __init__(self, now: _dt.datetime, tz_offset_hours: float = 0.0):
        self.now = _aware(now)
        self.tz = _dt.timezone(_dt.timedelta(hours=tz_offset_hours))

    def ago(self, days: float = 0, hours: float = 0, minutes: float = 0, seconds: float = 0) -> _dt.datetime:
        return self.now - _dt.timedelta(days=days, hours=hours, minutes=minutes, seconds=seconds)

    def at(self, days_ago: int, hour: int, minute: int = 0, second: int = 0) -> _dt.datetime:
        """A wall-clock time in the persona's time zone, `days_ago` days back. Never in the
        future: a time later than now is moved back one day."""
        local = self.now.astimezone(self.tz) - _dt.timedelta(days=days_ago)
        stamp = local.replace(hour=hour, minute=minute, second=second, microsecond=0)
        if stamp > self.now:
            stamp -= _dt.timedelta(days=1)
        return stamp.astimezone(UTC)

    def local_hour(self, value: _dt.datetime) -> int:
        return _aware(value).astimezone(self.tz).hour

    def spread(self, rng: random.Random, count: int, days: float, hours: tuple[int, int] = (7, 23),
               recent_bias: float = 1.0) -> list[_dt.datetime]:
        """`count` sorted datetimes within the last `days` days, at local `hours` (from, to).
        `recent_bias` > 1 puts more of them near now."""
        out: list[_dt.datetime] = []
        lo, hi = hours
        for _ in range(count):
            back = int((rng.random() ** recent_bias) * days)
            stamp = self.at(back, rng.randrange(lo, max(lo + 1, hi)), rng.randrange(60), rng.randrange(60))
            out.append(stamp)
        return sorted(out)

    def sessions(self, rng: random.Random, days: int, per_day: tuple[int, int] = (3, 9),
                 seconds: tuple[int, int] = (20, 1800), hours: tuple[int, int] = (7, 23)
                 ) -> list[tuple[_dt.datetime, int]]:
        """Non-overlapping (start, duration seconds) sessions, oldest first, none in the future."""
        starts: list[_dt.datetime] = []
        for day in range(days, -1, -1):
            for _ in range(rng.randint(*per_day)):
                starts.append(self.at(day, rng.randrange(hours[0], hours[1]), rng.randrange(60), rng.randrange(60)))
        out: list[tuple[_dt.datetime, int]] = []
        previous_end: Optional[_dt.datetime] = None
        for start in sorted(starts):
            if previous_end is not None and start < previous_end:
                start = previous_end + _dt.timedelta(seconds=rng.randint(5, 120))
            length = rng.randint(*seconds)
            if start + _dt.timedelta(seconds=length) > self.now:
                continue
            out.append((start, length))
            previous_end = start + _dt.timedelta(seconds=length)
        return out


# --------------------------------------------------------------------------------------
# Identifiers (always from the generator's rng: deterministic, never real)
# --------------------------------------------------------------------------------------

def uuid_obj(rng: random.Random) -> _uuid.UUID:
    return _uuid.UUID(int=rng.getrandbits(128), version=4)


def uuid_string(rng: random.Random, upper: bool = True) -> str:
    """A random (version 4) UUID string from `rng`."""
    text = str(uuid_obj(rng))
    return text.upper() if upper else text


def hex_string(rng: random.Random, digits: int) -> str:
    return "".join(rng.choice("0123456789abcdef") for _ in range(digits))


# --------------------------------------------------------------------------------------
# SQLite
# --------------------------------------------------------------------------------------

Row = Union[Sequence[Any], Mapping[str, Any]]


def _insert(con: sqlite3.Connection, table: str, rows: Iterable[Row]) -> int:
    count = 0
    quoted = '"' + table.replace('"', '""') + '"'
    for row in rows:
        if isinstance(row, Mapping):
            columns = ", ".join('"' + c.replace('"', '""') + '"' for c in row)
            marks = ", ".join("?" for _ in row)
            con.execute(f"INSERT INTO {quoted} ({columns}) VALUES ({marks})", list(row.values()))
        else:
            marks = ", ".join("?" for _ in row)
            con.execute(f"INSERT INTO {quoted} VALUES ({marks})", list(row))
        count += 1
    return count


@contextmanager
def sqlite_db(path: Path, ddl: str = "", *, user_version: Optional[int] = None,
              page_size: int = 4096) -> Iterator[sqlite3.Connection]:
    """Creates a new database (replacing an existing one), runs `ddl`, yields the
    connection for inserts, then commits and closes. Rollback-journal mode: no `-wal` /
    `-shm` companions are left behind, so the app's read-only open needs no fallback.

        with lib.sqlite_db(path, DDL) as con:
            lib.insert(con, "ZOBJECT", [{"Z_PK": 1, "ZSTREAMNAME": "/app/usage"}])
    """
    path = ensure_parent(path)
    for suffix in ("", "-wal", "-shm", "-journal"):
        try:
            os.remove(str(path) + suffix)
        except FileNotFoundError:
            pass
    con = sqlite3.connect(str(path), isolation_level=None)
    try:
        con.execute(f"PRAGMA page_size={int(page_size)}")
        con.execute("PRAGMA journal_mode=DELETE")
        if user_version is not None:
            con.execute(f"PRAGMA user_version={int(user_version)}")
        con.execute("BEGIN")
        if ddl:
            # executescript would commit; run statement by statement inside the transaction.
            for statement in split_sql(ddl):
                con.execute(statement)
        yield con
        con.execute("COMMIT")
    except BaseException:
        if con.in_transaction:
            con.execute("ROLLBACK")
        raise
    finally:
        con.close()


def insert(con: sqlite3.Connection, table: str, rows: Iterable[Row]) -> int:
    """Inserts tuples (all columns, table order) or dicts (named columns). Returns the count."""
    return _insert(con, table, rows)


def create_db(path: Path, ddl: str, rows: Optional[Mapping[str, Iterable[Row]]] = None, *,
              user_version: Optional[int] = None) -> Path:
    """One call: create the database from DDL and fill tables.

        lib.create_db(path, "CREATE TABLE t (a INTEGER, b TEXT);", {"t": [(1, "x"), {"a": 2}]})
    """
    with sqlite_db(path, ddl, user_version=user_version) as con:
        for table, table_rows in (rows or {}).items():
            _insert(con, table, table_rows)
    return Path(path)


def split_sql(script: str) -> list[str]:
    """Splits a DDL script into statements (handles `CREATE TRIGGER … BEGIN … END;`)."""
    out: list[str] = []
    buffer = ""
    for line in script.splitlines(keepends=True):
        buffer += line
        if sqlite3.complete_statement(buffer):
            statement = buffer.strip()
            if statement and statement != ";":
                out.append(statement)
            buffer = ""
    if buffer.strip():
        out.append(buffer.strip())
    return out


def coredata_tables(con: sqlite3.Connection, entities: Mapping[str, int], rng: random.Random,
                    max_pk: Optional[Mapping[str, int]] = None) -> None:
    """Adds the bookkeeping tables every CoreData SQLite store has (`Z_PRIMARYKEY`,
    `Z_METADATA`, `Z_MODELCACHE`). `entities` maps entity name -> Z_ENT number; `max_pk`
    entity name -> highest Z_PK (default 0). Create the `Z<ENTITY>` tables yourself."""
    con.execute("CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER)")
    con.execute("CREATE TABLE Z_METADATA (Z_VERSION INTEGER PRIMARY KEY, Z_UUID VARCHAR(255), Z_PLIST BLOB)")
    con.execute("CREATE TABLE Z_MODELCACHE (Z_CONTENT BLOB)")
    for name, ent in entities.items():
        con.execute("INSERT INTO Z_PRIMARYKEY VALUES (?, ?, 0, ?)", (ent, name, (max_pk or {}).get(name, 0)))
    con.execute("INSERT INTO Z_METADATA VALUES (1, ?, ?)",
                (uuid_string(rng), plist_bytes({"NSStoreType": "SQLite", "NSStoreModelVersionIdentifiers": [""]})))


# --------------------------------------------------------------------------------------
# Protobuf encoder (schema-less, the mirror of Sources/DossierCore/Data/Protobuf.swift)
# --------------------------------------------------------------------------------------

class pb:
    """Minimal protobuf encoder.

    A message is a list of `(field number, value)` pairs (repeat a number for repeated
    fields) or a dict. Value types:

        int / bool          varint (negative ints as 64-bit two's complement)
        float               64-bit double  (wire type 1) — Biome timestamps are doubles
        str                 length-delimited UTF-8
        bytes               length-delimited
        list of pairs/dict  nested message
        None                field is left out
        pb.sint(n)          zigzag varint          pb.float32(x)    32-bit float
        pb.fixed64(n)       fixed 64-bit integer   pb.fixed32(n)    fixed 32-bit integer
        pb.packed([1, 2])   packed varints         pb.packed_doubles([..]) / pb.packed_floats([..])

        payload = pb.message([(1, "com.apple.Safari"), (2, lib.cocoa(when)), (3, True),
                              (4, [(1, "nested"), (2, 7)]), (5, "a"), (5, "b")])
    """

    class _Raw:
        __slots__ = ("wire", "data")

        def __init__(self, wire: int, data: bytes):
            self.wire = wire
            self.data = data

    @staticmethod
    def varint(value: int) -> bytes:
        if value < 0:
            value += 1 << 64
        out = bytearray()
        while True:
            byte = value & 0x7F
            value >>= 7
            if value:
                out.append(byte | 0x80)
            else:
                out.append(byte)
                return bytes(out)

    @staticmethod
    def sint(value: int) -> "pb._Raw":
        return pb._Raw(0, pb.varint((value << 1) ^ (value >> 63)))

    @staticmethod
    def fixed64(value: int) -> "pb._Raw":
        return pb._Raw(1, struct.pack("<Q", value & 0xFFFFFFFFFFFFFFFF))

    @staticmethod
    def double(value: float) -> "pb._Raw":
        return pb._Raw(1, struct.pack("<d", value))

    @staticmethod
    def fixed32(value: int) -> "pb._Raw":
        return pb._Raw(5, struct.pack("<I", value & 0xFFFFFFFF))

    @staticmethod
    def float32(value: float) -> "pb._Raw":
        return pb._Raw(5, struct.pack("<f", value))

    @staticmethod
    def packed(values: Iterable[int]) -> "pb._Raw":
        body = b"".join(pb.varint(v) for v in values)
        return pb._Raw(2, pb.varint(len(body)) + body)

    @staticmethod
    def packed_doubles(values: Iterable[float]) -> "pb._Raw":
        body = b"".join(struct.pack("<d", v) for v in values)
        return pb._Raw(2, pb.varint(len(body)) + body)

    @staticmethod
    def packed_floats(values: Iterable[float]) -> "pb._Raw":
        body = b"".join(struct.pack("<f", v) for v in values)
        return pb._Raw(2, pb.varint(len(body)) + body)

    @staticmethod
    def _field(number: int, value: Any) -> bytes:
        if value is None:
            return b""
        if number <= 0:
            raise ValueError("protobuf field numbers start at 1")
        if isinstance(value, pb._Raw):
            return pb.varint((number << 3) | value.wire) + value.data
        if isinstance(value, bool):
            return pb.varint(number << 3) + (b"\x01" if value else b"\x00")
        if isinstance(value, int):
            return pb.varint(number << 3) + pb.varint(value)
        if isinstance(value, float):
            return pb.varint((number << 3) | 1) + struct.pack("<d", value)
        if isinstance(value, str):
            value = value.encode("utf-8")
        elif isinstance(value, (list, tuple, dict)):
            value = pb.message(value)
        if isinstance(value, (bytes, bytearray, memoryview)):
            data = bytes(value)
            return pb.varint((number << 3) | 2) + pb.varint(len(data)) + data
        raise TypeError(f"cannot encode {type(value).__name__} as a protobuf field")

    @staticmethod
    def message(fields: Union[Mapping[int, Any], Iterable[tuple[int, Any]]]) -> bytes:
        pairs = fields.items() if isinstance(fields, Mapping) else fields
        return b"".join(pb._field(number, value) for number, value in pairs)


# --------------------------------------------------------------------------------------
# Biome SEGB (version 2 — the framing current macOS writes; spec: Sources/DossierCore/Data/SEGB.swift)
# --------------------------------------------------------------------------------------

SEGB_STATE_WRITTEN = 1
SEGB_STATE_DELETED = 3
_SEGB_HEADER = 32
_SEGB_PAGE = 4096


def crc32(data: bytes) -> int:
    """CRC-32 (IEEE 802.3) as stored in SEGB record headers."""
    return zlib.crc32(data) & 0xFFFFFFFF


class SEGBRecord:
    """One record of a segment: `SEGBRecord(when, payload)`; `deleted=True` writes a
    deleted record (state 3, payload zero-filled, as the system leaves them)."""

    __slots__ = ("when", "payload", "deleted")

    def __init__(self, when: DateLike, payload: bytes, deleted: bool = False):
        self.when = when
        self.payload = bytes(payload)
        self.deleted = deleted


RecordLike = Union[SEGBRecord, tuple]


def _record(value: RecordLike) -> SEGBRecord:
    return value if isinstance(value, SEGBRecord) else SEGBRecord(*value)


def segb_bytes(records: Iterable[RecordLike], created: Optional[DateLike] = None) -> bytes:
    """A complete SEGB v2 segment.

    Layout: 32-byte header (`SEGB`, u32 record count, f64 Cocoa creation time, u32 10,
    u32 0xFFFFFFFF, 8 zero bytes); records from offset 32, each aligned to 4 bytes
    (`u32 crc32(payload) | u32 0 | payload`); zero padding; then one 16-byte trailer entry
    per record, growing backwards from the end of the file
    (`u32 end offset relative to 32 | u32 state | f64 Cocoa timestamp`). The file is padded
    to a multiple of 4096 bytes like the preallocated originals.
    """
    items = [_record(r) for r in records]
    body = bytearray()
    trailer: list[bytes] = []
    for item in items:
        while len(body) % 4:
            body.append(0)
        payload = bytes(len(item.payload)) if item.deleted else item.payload
        if not payload:
            raise ValueError("a SEGB record needs a non-empty payload")
        crc = 0 if item.deleted else crc32(payload)
        body += struct.pack("<II", crc, 0) + payload
        state = SEGB_STATE_DELETED if item.deleted else SEGB_STATE_WRITTEN
        trailer.append(struct.pack("<Iid", len(body), state, cocoa(item.when)))
    if created is None:
        created = min((unix(i.when) for i in items), default=COCOA_EPOCH)
    header = b"SEGB" + struct.pack("<IdII", len(items), cocoa(created), 10, 0xFFFFFFFF) + bytes(8)
    assert len(header) == _SEGB_HEADER
    used = _SEGB_HEADER + len(body) + 16 * len(trailer)
    size = max(_SEGB_PAGE, -(-used // _SEGB_PAGE) * _SEGB_PAGE)
    padding = size - used
    return bytes(header) + bytes(body) + bytes(padding) + b"".join(reversed(trailer))


def segment_name(created: DateLike) -> str:
    """Segment file names are the creation time in microseconds since the Cocoa epoch."""
    return str(int(round(cocoa(created) * 1_000_000)))


def write_segb(path: Path, records: Iterable[RecordLike], created: Optional[DateLike] = None) -> Path:
    return write_bytes(path, segb_bytes(records, created))


def read_segb(data: bytes) -> list[tuple[float, int, bytes, bool]]:
    """Independent reader for checks: [(Cocoa timestamp, state, payload, crc ok)]."""
    if data[:4] != b"SEGB":
        raise ValueError("not a SEGB v2 file")
    count = struct.unpack_from("<I", data, 4)[0]
    out = []
    previous_end = 0
    for index in range(count):
        end, state, stamp = struct.unpack_from("<Iid", data, len(data) - 16 * (index + 1))
        start = (previous_end + 3) & ~3
        previous_end = end
        crc = struct.unpack_from("<I", data, _SEGB_HEADER + start)[0]
        payload = data[_SEGB_HEADER + start + 8:_SEGB_HEADER + end]
        out.append((stamp, state, payload, state == SEGB_STATE_DELETED or crc32(payload) == crc))
    return out


def biome_stream_dir(root: Path, name: str, kind: str = "restricted") -> Path:
    """`~/Library/Biome/streams/<restricted|public>/<name>` below the root."""
    return library(root, f"Biome/streams/{kind}/{name}")


def write_stream(stream_dir: Path, records: Iterable[RecordLike], device: Optional[str] = None,
                 max_records: int = 4000, max_bytes: int = 4 << 20) -> list[Path]:
    """Writes records (sorted by time) as one or more segments of a Biome stream directory:
    `<stream_dir>/local/<segment>` for this Mac (`device=None`) or
    `<stream_dir>/remote/<device identifier>/<segment>` for a synced device. Segments are
    split by record count / size and named after their first record's time.

        d = lib.biome_stream_dir(root, "App.InFocus")
        lib.write_stream(d, [(when, pb.message([...])) for when in times])                # local
        lib.write_stream(d, records, device=persona.device("iphone").identifier)           # remote

    Calling it again for the same device adds segments (file names are made unique).
    Use the device identifiers from `persona.devices` so that sync.db can name them.
    """
    items = sorted((_record(r) for r in records), key=lambda r: unix(r.when))
    folder = Path(stream_dir) / "local" if device is None else Path(stream_dir) / "remote" / device
    ensure_dir(folder)
    written: list[Path] = []
    chunk: list[SEGBRecord] = []
    size = 0

    def flush() -> None:
        nonlocal chunk, size
        if not chunk:
            return
        stamp = int(segment_name(chunk[0].when))
        while (folder / str(stamp)).exists():
            stamp += 1
        written.append(write_segb(folder / str(stamp), chunk, created=chunk[0].when))
        chunk, size = [], 0

    for item in items:
        if chunk and (len(chunk) >= max_records or size + len(item.payload) + 24 > max_bytes):
            flush()
        chunk.append(item)
        size += len(item.payload) + 24
    flush()
    if not written and device is None:
        pass  # an empty local folder is still a valid (empty) stream
    return written


#: `DevicePeer` of ~/Library/Biome/sync/sync.db (column names and types from the real schema).
BIOME_SYNC_DDL = """
CREATE TABLE DevicePeer (
 device_identifier STRING NOT NULL,
 ids_device_identifier STRING,
 me BOOLEAN,
 name STRING,
 model STRING,
 platform INTEGER,
 last_sync_date INTEGER,
 protocol_version INTEGER NOT NULL
);
"""


def write_biome_sync_db(root: Path, devices: Sequence[Any], now: DateLike, rng: random.Random,
                        extra_ddl: str = "") -> Path:
    """Creates `~/Library/Biome/sync/sync.db` with one `DevicePeer` row per persona device
    (identifier, name, OS build as `model`, platform code 2 = iPhone/iPad, 3 = Mac,
    4 = Apple Watch, `me` for this Mac, `last_sync_date` in Unix seconds). `extra_ddl`
    adds further tables to the same file; fill them by reopening with sqlite3 or by passing
    a script with INSERT statements."""
    path = library(root, "Biome/sync/sync.db")
    with sqlite_db(path, BIOME_SYNC_DDL + extra_ddl, user_version=34) as con:
        for device in devices:
            last_sync = None if device.is_me else int(unix(now)) - rng.randint(120, 6 * 3600)
            con.execute("INSERT INTO DevicePeer VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                        (device.identifier, device.ids_identifier, 1 if device.is_me else 0, device.name,
                         device.os_build, device.platform, last_sync, 2))
    return path


# --------------------------------------------------------------------------------------
# Plists and NSKeyedArchiver
# --------------------------------------------------------------------------------------

def plist_bytes(value: Any, binary: bool = True) -> bytes:
    """A binary (default) or XML property list. datetime values must be naive UTC or aware."""
    return plistlib.dumps(_plist_ready(value), fmt=plistlib.FMT_BINARY if binary else plistlib.FMT_XML, sort_keys=False)


def write_plist(path: Path, value: Any, binary: bool = True) -> Path:
    return write_bytes(path, plist_bytes(value, binary))


def _plist_ready(value: Any) -> Any:
    if isinstance(value, _dt.datetime):
        return _aware(value).astimezone(UTC).replace(tzinfo=None)   # plistlib wants naive UTC
    if isinstance(value, Mapping):
        return {str(k): _plist_ready(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_plist_ready(v) for v in value]
    if isinstance(value, _uuid.UUID):
        return str(value).upper()
    return value


class ArchiveObject:
    """A custom object inside a keyed archive: class name, coded keys, superclass chain.

        lib.ArchiveObject("FAFamilyMember", {"_firstName": "Robin", "_age": 34},
                          classes=["FAFamilyMember", "NSObject"])
    """

    def __init__(self, class_name: str, fields: Mapping[str, Any], classes: Optional[Sequence[str]] = None):
        self.class_name = class_name
        self.fields = dict(fields)
        self.classes = list(classes) if classes else [class_name, "NSObject"]


class ArchiveURL:
    """An NSURL (`NS.relative`, optional `NS.base`)."""

    def __init__(self, relative: str, base: Optional[str] = None):
        self.relative = relative
        self.base = base


class _Archiver:
    def __init__(self, mutable: bool):
        self.objects: list[Any] = ["$null"]
        self.class_index: dict[tuple[str, ...], int] = {}
        self.mutable = mutable

    def _class(self, chain: Sequence[str]) -> plistlib.UID:
        key = tuple(chain)
        if key not in self.class_index:
            self.objects.append({"$classname": chain[0], "$classes": list(chain)})
            self.class_index[key] = len(self.objects) - 1
        return plistlib.UID(self.class_index[key])

    def _add(self, obj: Any) -> plistlib.UID:
        self.objects.append(obj)
        return plistlib.UID(len(self.objects) - 1)

    def encode(self, value: Any) -> plistlib.UID:
        if value is None:
            return plistlib.UID(0)
        if isinstance(value, (bool, int, float, str)):
            return self._add(value)
        if isinstance(value, (bytes, bytearray)):
            return self._add(bytes(value))
        if isinstance(value, _dt.datetime):
            slot = self._add(None)
            self.objects[slot.data] = {"NS.time": cocoa(value), "$class": self._class(["NSDate", "NSObject"])}
            return slot
        if isinstance(value, _uuid.UUID):
            slot = self._add(None)
            self.objects[slot.data] = {"NS.uuidbytes": value.bytes, "$class": self._class(["NSUUID", "NSObject"])}
            return slot
        if isinstance(value, ArchiveURL):
            slot = self._add(None)
            relative = self.encode(value.relative)
            base = self.encode(value.base)
            self.objects[slot.data] = {"NS.base": base, "NS.relative": relative, "$class": self._class(["NSURL", "NSObject"])}
            return slot
        if isinstance(value, Mapping):
            slot = self._add(None)
            keys = [self.encode(k) for k in value.keys()]
            values = [self.encode(v) for v in value.values()]
            chain = ["NSMutableDictionary", "NSDictionary", "NSObject"] if self.mutable else ["NSDictionary", "NSObject"]
            self.objects[slot.data] = {"NS.keys": keys, "NS.objects": values, "$class": self._class(chain)}
            return slot
        if isinstance(value, (set, frozenset)):
            slot = self._add(None)
            members = [self.encode(v) for v in sorted(value, key=repr)]
            chain = ["NSMutableSet", "NSSet", "NSObject"] if self.mutable else ["NSSet", "NSObject"]
            self.objects[slot.data] = {"NS.objects": members, "$class": self._class(chain)}
            return slot
        if isinstance(value, (list, tuple)):
            slot = self._add(None)
            members = [self.encode(v) for v in value]
            chain = ["NSMutableArray", "NSArray", "NSObject"] if self.mutable else ["NSArray", "NSObject"]
            self.objects[slot.data] = {"NS.objects": members, "$class": self._class(chain)}
            return slot
        if isinstance(value, ArchiveObject):
            slot = self._add(None)
            body: dict[str, Any] = {}
            for key, field in value.fields.items():
                # Scalars are stored inline, objects by reference — as NSKeyedArchiver does.
                if isinstance(field, (bool, int, float)):
                    body[key] = field
                else:
                    body[key] = self.encode(field)
            body["$class"] = self._class(value.classes)
            self.objects[slot.data] = body
            return slot
        raise TypeError(f"cannot archive {type(value).__name__}")


def keyed_archive(root_object: Any, *, mutable_collections: bool = False, top_key: str = "root") -> bytes:
    """An NSKeyedArchiver binary plist (`$archiver`, `$version`, `$top`, `$objects`).

    dict → NSDictionary, list/tuple → NSArray, set → NSSet, str / int / float / bool /
    bytes → themselves, datetime → NSDate, uuid.UUID → NSUUID, ArchiveURL → NSURL,
    ArchiveObject → a custom class. `top_key` is the key in `$top` (`root` for
    `archivedData(withRootObject:)`).

        blob = lib.keyed_archive({"name": "Robin", "when": clock.ago(days=2), "tags": ["a", "b"]})
    """
    archiver = _Archiver(mutable_collections)
    top = archiver.encode(root_object)
    return plistlib.dumps({
        "$version": 100000,
        "$archiver": "NSKeyedArchiver",
        "$top": {top_key: top},
        "$objects": archiver.objects,
    }, fmt=plistlib.FMT_BINARY, sort_keys=False)


# --------------------------------------------------------------------------------------
# LZFSE
# --------------------------------------------------------------------------------------

def lzfse_stored(data: bytes) -> bytes:
    """A valid LZFSE stream that stores `data` without compressing it.

    Python has no LZFSE encoder, but the LZFSE container defines an *uncompressed block*
    (`bvx-`, u32 length, raw bytes) besides the compressed ones, ended by `bvx$`. Apple's
    decoder — and therefore Core's `LZFSE.decode` — reads such a stream like any other, so
    stores whose payloads are LZFSE-compressed can be generated without a compressor.
    """
    out = bytearray()
    for offset in range(0, len(data), 1 << 30):
        block = data[offset:offset + (1 << 30)]
        out += b"bvx-" + struct.pack("<I", len(block)) + block
    out += b"bvx$"
    return bytes(out)
