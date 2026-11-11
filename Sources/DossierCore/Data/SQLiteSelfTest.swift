import Foundation
import SQLite3

public extension SQLiteDB {
    /// Proves on scratch WAL databases in the temporary directory (never a system store)
    /// that opening and querying through ``SQLiteDB`` leaves the database directory
    /// untouched: no file is created and the `-shm` / `-wal` / main files keep their
    /// inode, size and modification time. Covers a stale `-shm` nobody holds, a live
    /// database with a concurrent writer, and a WAL database whose `-shm` is missing.
    static func sidecarSelfTest() async -> [SelfTestLine] {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dossier-shmtest-\(UUID().uuidString)", isDirectory: true)
        let live = root.appendingPathComponent("live", isDirectory: true)
        let stale = root.appendingPathComponent("stale", isDirectory: true)
        let noShm = root.appendingPathComponent("noshm", isDirectory: true)
        for dir in [live, stale, noShm] { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: root) }

        // A writer that stays open so the -wal and -shm files exist and hold live frames.
        var writer: OpaquePointer?
        let livePath = live.appendingPathComponent("a.db").path
        guard sqlite3_open(livePath, &writer) == SQLITE_OK else {
            sqlite3_close(writer)
            return [.warn("Read-only sidecars", "could not create scratch database")]
        }
        defer { sqlite3_close(writer) }
        let setup = """
            PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
            CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT); INSERT INTO t(b) VALUES ('one');
            PRAGMA wal_checkpoint(FULL);
            INSERT INTO t(b) VALUES ('two');
            """
        guard sqlite3_exec(writer, setup, nil, nil, nil) == SQLITE_OK else {
            return [.warn("Read-only sidecars", "could not populate scratch database")]
        }
        // Copies taken while the writer is open: 1 row checkpointed, 1 row only in the WAL.
        for suffix in ["", "-wal", "-shm"] {
            try? fm.copyItem(atPath: livePath + suffix, toPath: stale.appendingPathComponent("a.db").path + suffix)
            if suffix != "-shm" { try? fm.copyItem(atPath: livePath + suffix, toPath: noShm.appendingPathComponent("a.db").path + suffix) }
        }

        func fingerprint(_ dir: URL, excluding: Set<String> = []) -> [String] {
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            return names.filter { !excluding.contains($0) }.map { name in
                var st = stat()
                guard lstat(dir.appendingPathComponent(name).path, &st) == 0 else { return name + " ?" }
                return "\(name) ino=\(st.st_ino) size=\(st.st_size) mtime=\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
            }
        }

        var lines: [SelfTestLine] = []

        // 1. Stale -shm, nobody else holds the database.
        do {
            let before = fingerprint(stale)
            let db = try? SQLiteDB(path: stale.appendingPathComponent("a.db").path)
            let rows = await db?.rowCount(of: "t")
            let after = fingerprint(stale)
            lines.append(.check("Read-only sidecars: unheld WAL database", before == after && rows == 2 && db?.isImmutableFallback == false,
                                "\(rows.map(String.init) ?? "no") rows incl. WAL frame; " + (before == after ? "directory, inode, size and mtime of all \(after.count) files unchanged" : "FILES CHANGED: \(before) -> \(after)")))
        }

        // 2. WAL database without a -shm: nothing may be created.
        do {
            let before = fingerprint(noShm)
            let db = try? SQLiteDB(path: noShm.appendingPathComponent("a.db").path)
            let rows = await db?.rowCount(of: "t")
            let after = fingerprint(noShm)
            let mode = db == nil ? "not opened" : (db!.isImmutableFallback ? "immutable snapshot" : "read-only WAL")
            lines.append(.check("Read-only sidecars: WAL database without -shm", before == after && db != nil && (rows == 1 || rows == 2),
                                "\(mode), \(rows.map(String.init) ?? "no") rows; " + (before == after ? "no -shm created, files unchanged" : "FILES CHANGED: \(before) -> \(after)")))
        }

        // 3. Live database: the writer commits while the reader is connected. The writer
        //    itself changes -wal and -shm, so only the main file and the listing are compared.
        do {
            let names = Set(((try? fm.contentsOfDirectory(atPath: live.path)) ?? []))
            let db = try? SQLiteDB(path: livePath)
            let first = await db?.rowCount(of: "t")
            sqlite3_exec(writer, "INSERT INTO t(b) VALUES ('three')", nil, nil, nil)
            let second = await db?.rowCount(of: "t")
            let namesAfter = Set(((try? fm.contentsOfDirectory(atPath: live.path)) ?? []))
            lines.append(.check("Read-only sidecars: live database with a writer", first == 2 && second == 3 && names == namesAfter && db?.isImmutableFallback == false,
                                "saw \(first ?? -1) rows, then \(second ?? -1) after a concurrent commit; no files added"))
        }
        return lines
    }
}
