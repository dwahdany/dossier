"""Unit checks for the shared helpers: `scripts/make-demo-data.py --check`.

These check the writers against independent expectations (known protobuf byte vectors,
a second SEGB reader, plistlib, sqlite3). The cross-check against the app's own readers
is done by running the app on a generated root (`--selftest` in demo mode).
"""

from __future__ import annotations

import datetime
import pathlib
import plistlib
import random
import sqlite3
import struct
import tempfile
import uuid

from . import lib, persona as persona_module
from .lib import pb


def _decode_proto(data: bytes) -> list[tuple[int, int, object]]:
    """Tiny independent protobuf reader: [(field, wire type, value)]."""
    out = []
    i = 0

    def varint() -> int:
        nonlocal i
        shift = value = 0
        while True:
            byte = data[i]
            i += 1
            value |= (byte & 0x7F) << shift
            if not byte & 0x80:
                return value
            shift += 7

    while i < len(data):
        key = varint()
        field, wire = key >> 3, key & 7
        if wire == 0:
            out.append((field, wire, varint()))
        elif wire == 1:
            out.append((field, wire, data[i:i + 8]))
            i += 8
        elif wire == 2:
            n = varint()
            out.append((field, wire, data[i:i + n]))
            i += n
        elif wire == 5:
            out.append((field, wire, data[i:i + 4]))
            i += 4
        else:
            raise ValueError("bad wire type")
    return out


def run() -> int:
    failures = 0

    def check(label: str, condition: bool, detail: str = "") -> None:
        nonlocal failures
        if not condition:
            failures += 1
        print(f"  [{'PASS' if condition else 'FAIL'}] {label}" + (f" — {detail}" if detail else ""))

    print("== demo helpers")
    now = datetime.datetime(2026, 1, 15, 2, 30, tzinfo=datetime.timezone.utc)
    rng = random.Random(7)

    # Dates
    check("cocoa epoch", lib.cocoa(datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)) == 0.0)
    check("cocoa round trip", lib.from_cocoa(lib.cocoa(now)) == now)
    check("webkit epoch", lib.webkit_us(datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)) == 11_644_473_600_000_000)
    clock = lib.Clock(now, 13)
    spread = clock.spread(rng, 300, days=30)
    check("Clock.spread: sorted, never in the future, inside the window",
          spread == sorted(spread) and max(spread) <= now and min(spread) >= clock.ago(days=32))
    check("Clock.spread: local waking hours", all(7 <= clock.local_hour(s) < 23 for s in spread))
    sessions = clock.sessions(rng, days=5)
    ends = [s + datetime.timedelta(seconds=n) for s, n in sessions]
    check("Clock.sessions: no overlap, none in the future",
          all(sessions[i + 1][0] >= ends[i] for i in range(len(sessions) - 1)) and max(ends) <= now, f"{len(sessions)} sessions")
    check("Clock.at: local wall time", clock.at(1, 8, 30).astimezone(clock.tz).strftime("%H:%M") == "08:30")

    # Protobuf: reference vectors from the protobuf encoding documentation.
    check("protobuf varint 150", pb.message([(1, 150)]) == bytes.fromhex("089601"))
    check("protobuf string", pb.message([(2, "testing")]) == bytes.fromhex("120774657374696e67"))
    check("protobuf nested", pb.message([(3, [(1, 150)])]) == bytes.fromhex("1a03089601"))
    check("protobuf packed", pb.message([(4, pb.packed([3, 270, 86942]))]) == bytes.fromhex("2206038e029ea705"))
    check("protobuf negative int = 10 bytes", pb.message([(1, -1)]) == bytes.fromhex("08ffffffffffffffffff01"))
    check("protobuf zigzag", pb.message([(1, pb.sint(-1)), (2, pb.sint(1))]) == bytes.fromhex("08011002"))
    message = pb.message([(1, "a"), (2, 1.5), (3, True), (4, None), (5, b"\x00\x01"), (6, pb.float32(2.0)),
                          (7, pb.fixed64(9)), (8, {1: "x"}), (5, b"\x02")])
    decoded = _decode_proto(message)
    check("protobuf mixed message decodes", [(f, w) for f, w, _ in decoded] ==
          [(1, 2), (2, 1), (3, 0), (5, 2), (6, 5), (7, 1), (8, 2), (5, 2)]
          and struct.unpack("<d", decoded[1][2])[0] == 1.5 and struct.unpack("<f", decoded[4][2])[0] == 2.0)

    with tempfile.TemporaryDirectory(prefix="dossier-demo-check-") as tmp:
        root = pathlib.Path(tmp)

        # Paths
        check("paths", lib.library(root, "Biome") == root / "Home/Library/Biome"
              and lib.system(root, "/private/var/db/CoreDuet/People") == root / "private/var/db/CoreDuet/People"
              and lib.photos_library(root) == root / "Home/Pictures/Photos Library.photoslibrary")

        # SEGB
        records = [lib.SEGBRecord(clock.ago(hours=h), pb.message([(1, f"record {h}"), (2, lib.cocoa(clock.ago(hours=h)))]))
                   for h in (5, 4, 3)]
        records.append(lib.SEGBRecord(clock.ago(hours=2), b"gone-gone", deleted=True))
        records.append(lib.SEGBRecord(clock.ago(hours=1), b"x"))               # odd length: forces alignment padding
        records.append(lib.SEGBRecord(clock.ago(minutes=5), pb.message([(1, "last")])))
        blob = lib.segb_bytes(records)
        parsed = lib.read_segb(blob)
        check("SEGB: header", blob[:4] == b"SEGB" and struct.unpack_from("<I", blob, 4)[0] == 6 and len(blob) % 4096 == 0)
        check("SEGB: records read back, CRCs valid",
              len(parsed) == 6 and all(ok for _, _, _, ok in parsed)
              and [p for _, s, p, _ in parsed if s == 1] == [r.payload for r in records if not r.deleted])
        check("SEGB: deleted record is zero-filled, state 3", parsed[3][1] == 3 and parsed[3][2] == bytes(9))
        check("SEGB: timestamps", [round(t, 3) for t, _, _, _ in parsed] == [round(lib.cocoa(r.when), 3) for r in records])
        big = lib.segb_bytes([(clock.ago(seconds=n), bytes([n % 251 + 1]) * 900) for n in range(40, 0, -1)])
        check("SEGB: multi-page segment", len(big) % 4096 == 0 and len(big) > 8192 and all(ok for *_, ok in lib.read_segb(big)))

        stream = lib.biome_stream_dir(root, "Demo.SelfCheck")
        device = lib.uuid_string(rng)
        local = lib.write_stream(stream, [(clock.ago(minutes=m), pb.message([(1, m)])) for m in range(50, 0, -1)], max_records=20)
        remote = lib.write_stream(stream, [(clock.ago(minutes=m), pb.message([(1, m)])) for m in range(9, 0, -1)], device=device)
        check("stream layout: local/<segment>, remote/<device>/<segment>",
              len(local) == 3 and all(p.parent == stream / "local" and p.name.isdigit() and len(p.name) == 15 for p in local)
              and len(remote) == 1 and remote[0].parent == stream / "remote" / device)
        check("stream segments are time-ordered by name",
              [p.name for p in local] == sorted(p.name for p in local)
              and sum(len(lib.read_segb(p.read_bytes())) for p in local) == 50)

        # SQLite
        db = lib.create_db(root / "t.db", "CREATE TABLE t (a INTEGER, b TEXT);\nCREATE INDEX i ON t(a);",
                           {"t": [(1, "x"), {"a": 2, "b": "y"}, {"a": 3}]})
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        rows = con.execute("SELECT a, b FROM t ORDER BY a").fetchall()
        mode = con.execute("PRAGMA journal_mode").fetchone()[0]
        con.close()
        leftovers = sorted(p.name for p in root.glob("t.db*"))
        check("sqlite: rows", rows == [(1, "x"), (2, "y"), (3, None)])
        check("sqlite: rollback journal, no -wal / -shm left", mode == "delete" and leftovers == ["t.db"], f"{mode}, {leftovers}")
        check("sqlite: trigger DDL splits", len(lib.split_sql(
            "CREATE TABLE a (x);\nCREATE TRIGGER tr AFTER INSERT ON a BEGIN\n  UPDATE a SET x = 1;\n  UPDATE a SET x = 2;\nEND;\nCREATE TABLE b (y);")) == 3)
        with lib.sqlite_db(root / "cd.db", "CREATE TABLE ZTHING (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZNAME VARCHAR);") as con2:
            lib.coredata_tables(con2, {"Thing": 1}, rng, {"Thing": 2})
            lib.insert(con2, "ZTHING", [(1, 1, 1, "a"), (2, 1, 1, "b")])
        con = sqlite3.connect(f"file:{root / 'cd.db'}?mode=ro", uri=True)
        check("sqlite: CoreData bookkeeping tables",
              con.execute("SELECT Z_NAME, Z_MAX FROM Z_PRIMARYKEY").fetchall() == [("Thing", 2)]
              and con.execute("SELECT count(*) FROM Z_METADATA").fetchone()[0] == 1)
        con.close()

        sync = lib.write_biome_sync_db(root, persona_module.build(1).devices, now, rng)
        con = sqlite3.connect(f"file:{sync}?mode=ro", uri=True)
        peers = con.execute("SELECT name, platform, me, last_sync_date FROM DevicePeer ORDER BY me DESC, name").fetchall()
        con.close()
        check("Biome sync.db: one peer per device, exactly one 'me'",
              len(peers) == 4 and [p[2] for p in peers] == [1, 0, 0, 0] and peers[0][1] == 3
              and all(p[3] is None or 1.2e9 < p[3] <= lib.unix(now) for p in peers))

        # Plists
        plain = plistlib.loads(lib.plist_bytes({"a": 1, "when": now, "list": [1, "x"], "id": uuid.UUID(int=5)}))
        check("binary plist", lib.plist_bytes({"a": 1})[:6] == b"bplist" and plain["a"] == 1
              and plain["when"] == now.replace(tzinfo=None) and plain["list"] == [1, "x"])
        archive = plistlib.loads(lib.keyed_archive({
            "name": "Robin", "when": now, "tags": ["a", "b"], "id": uuid.UUID(int=5), "blob": b"\x01\x02",
            "url": lib.ArchiveURL("https://example.com/"), "set": {"x"},
            "custom": lib.ArchiveObject("DemoThing", {"_title": "t", "_count": 3, "_flag": True}, ["DemoThing", "NSObject"]),
        }))
        objects = archive["$objects"]

        def resolve(value):
            if isinstance(value, plistlib.UID):
                return resolve(objects[value.data])
            if isinstance(value, dict) and "$class" in value:
                cls = objects[value["$class"].data]["$classname"]
                if cls in ("NSDictionary", "NSMutableDictionary"):
                    return {resolve(k): resolve(v) for k, v in zip(value["NS.keys"], value["NS.objects"])}
                if cls in ("NSArray", "NSMutableArray", "NSSet", "NSMutableSet"):
                    return [resolve(v) for v in value["NS.objects"]]
                if cls == "NSDate":
                    return ("date", value["NS.time"])
                if cls == "NSUUID":
                    return ("uuid", value["NS.uuidbytes"])
                if cls == "NSURL":
                    return ("url", resolve(value["NS.relative"]), resolve(value["NS.base"]))
                return {"$class": cls, **{k: resolve(v) for k, v in value.items() if k != "$class"}}
            return None if value == "$null" else value

        top = resolve(archive["$top"]["root"])
        check("keyed archive: envelope", archive["$archiver"] == "NSKeyedArchiver" and archive["$version"] == 100000 and objects[0] == "$null")
        check("keyed archive: collections and values",
              top["name"] == "Robin" and top["tags"] == ["a", "b"] and top["blob"] == b"\x01\x02" and top["set"] == ["x"]
              and top["when"] == ("date", lib.cocoa(now)) and top["id"] == ("uuid", uuid.UUID(int=5).bytes)
              and top["url"] == ("url", "https://example.com/", None))
        check("keyed archive: custom object", top["custom"] == {"$class": "DemoThing", "_title": "t", "_count": 3, "_flag": True})
        check("keyed archive: class records are shared",
              sum(1 for o in objects if isinstance(o, dict) and o.get("$classname") == "NSArray") == 1)

        # LZFSE container (decoding is checked against Apple's decoder by the app self-test)
        stored = lib.lzfse_stored(b"hello" * 10)
        check("LZFSE stored stream framing", stored[:4] == b"bvx-" and struct.unpack_from("<I", stored, 4)[0] == 50
              and stored[8:58] == b"hello" * 10 and stored[58:] == b"bvx$")

        # Daemon containers
        data_dir = lib.daemon_container(root, "com.apple.linkd", rng)
        again = lib.daemon_container(root, "com.apple.linkd", rng)
        other = lib.daemon_container(root, "com.apple.kvs", rng)
        meta = plistlib.loads((data_dir.parent / ".com.apple.containermanagerd.metadata.plist").read_bytes())
        check("daemon container: metadata plist, stable per identifier",
              meta["MCMMetadataIdentifier"] == "com.apple.linkd" and data_dir == again and other != data_dir
              and data_dir.name == "Data" and data_dir.parent.parent == lib.library(root, "Daemon Containers"))

    # Persona
    a, b, c = persona_module.build(1), persona_module.build(1), persona_module.build(2)
    check("persona: follows its own rules", persona_module.audit(a) == [], "; ".join(persona_module.audit(a)))
    check("persona: deterministic per seed",
          [p.graph_id for p in a.people] == [p.graph_id for p in b.people]
          and [d.identifier for d in a.devices] == [d.identifier for d in b.devices]
          and [d.identifier for d in a.devices] != [d.identifier for d in c.devices]
          and [p.full_name for p in a.people] == [p.full_name for p in c.people])
    check("persona: lookups", a.owner.full_name == "Robin Sample" and a.person("partner").key == "alex"
          and a.place("home").city == "Wellington" and a.this_mac.platform == 3 and len(a.remote_devices) == 3
          and a.app("com.apple.MobileSMS").name == "Messages")
    check("uuid_string: version 4, from rng", lib.uuid_string(random.Random(1)) == lib.uuid_string(random.Random(1))
          and lib.uuid_string(random.Random(1))[14] == "4")

    print("Helper checks OK" if failures == 0 else f"Helper checks: {failures} failure(s)")
    return 0 if failures == 0 else 1
