import SwiftUI
import DossierCore

/// Streams & System Log — a curated catalogue of every Biome stream plus the legacy
/// knowledgeC store, presented as one event firehose: catalogue, typed stream detail,
/// unified timeline, knowledgeC, generative-AI telemetry and device sync.
///
/// Data layer: `BiomeCatalog` (stream discovery + SEGB index statistics),
/// `StreamRecordSource` / `TimelineSource` (paged record access, k-way merge),
/// `KnowledgeStore`, `SyncStore`, `AIStore`. Decoding is driven by the public declarative
/// `BiomeStreamRegistry` (field-number → meaning tables).
public final class BiomeModule: DossierModule {
    public let id = "biome"
    public let title = "Streams & System Log"
    public let symbol = "waveform.path.ecg.rectangle"
    public let group = SidebarGroup.raw

    public init() {}

    public var sections: [ModuleSection] {
        [
            ModuleSection(id: "biome.catalogue", title: "Stream Catalogue", symbol: "square.grid.3x3.square") { CatalogueSection() },
            ModuleSection(id: "biome.stream", title: "Stream Records", symbol: "list.bullet.rectangle") { StreamSection() },
            ModuleSection(id: "biome.timeline", title: "Unified Timeline", symbol: "clock.arrow.circlepath") { TimelineSection() },
            ModuleSection(id: "biome.knowledge", title: "knowledgeC", symbol: "cylinder") { KnowledgeSection() },
            ModuleSection(id: "biome.ai", title: "AI Telemetry", symbol: "sparkles") { AISection() },
            ModuleSection(id: "biome.sync", title: "Device Sync", symbol: "arrow.triangle.2.circlepath") { SyncSection() },
        ]
    }

    // MARK: Summary

    public func summary() async -> ModuleSummary {
        var stores: [StoreInfo] = []
        var facts: [Fact] = []
        let snapshot = await BiomeCatalog.shared.snapshot()

        func storeInfo(_ name: String, _ url: URL, origin: BiomeStreamOrigin, note: String) -> StoreInfo {
            let availability = Paths.probe(url)
            let entries = snapshot.entries.filter { $0.origin == origin }
            guard availability.isAvailable else { return StoreInfo(name: name, path: url, availability: availability, note: note) }
            let ranges = entries.compactMap(\.range)
            let range: ClosedRange<Date>? = ranges.isEmpty ? nil : ranges.map(\.lowerBound).min()!...ranges.map(\.upperBound).max()!
            return StoreInfo(name: name, path: url, sizeBytes: entries.reduce(0) { $0 + $1.bytes }, rowCount: entries.reduce(0) { $0 + $1.live },
                             timeRange: range, availability: .available, note: "\(entries.count) streams · \(note)")
        }
        stores.append(storeInfo("Biome streams", Paths.biomeRestrictedStreams, origin: .biome, note: "SEGB event streams, local and synced"))
        if snapshot.entries.contains(where: { $0.origin == .duetExpert }) {
            stores.append(storeInfo("Duet Expert streams", Paths.duetExpertCenter.appendingPathComponent("streams", isDirectory: true), origin: .duetExpert, note: "proactive suggestion engine"))
        }
        if let linkd = Paths.daemonContainerData("com.apple.linkd"), snapshot.entries.contains(where: { $0.origin == .linkd }) {
            // linkd writes every execution to the combined log and to a per-app log: report
            // distinct executions, not stored records.
            var store = storeInfo("App Intents transcripts", linkd, origin: .linkd, note: "linkd ActionTranscript")
            if store.availability.isAvailable {
                let perApp = snapshot.entries.filter { $0.origin == .linkd && !$0.isMirror && $0.live > 0 }.count
                let copies = snapshot.linkdStored - snapshot.linkdDistinct
                store.rowCount = snapshot.linkdDistinct
                store.note = "\(snapshot.entries.filter { $0.origin == .linkd }.count) streams · linkd ActionTranscript · \(Format.count(snapshot.linkdDistinct)) distinct executions"
                    + (copies > 0 ? ", mirrored in \(perApp) per-app log\(perApp == 1 ? "" : "s") (\(Format.count(snapshot.linkdStored)) records stored)" : "")
            }
            stores.append(store)
        }

        var knowledge = StoreInfo.file("knowledgeC.db", Paths.knowledgeC, note: "legacy CoreDuet event store")
        var knowledgeEvents = 0
        if let streams = try? await KnowledgeStore.streams() {
            knowledgeEvents = streams.reduce(0) { $0 + $1.count }
            knowledge.rowCount = knowledgeEvents
            let firsts = streams.compactMap(\.first), lasts = streams.compactMap(\.last)
            if let lo = firsts.min(), let hi = lasts.max() { knowledge.timeRange = lo...hi }
        }
        stores.append(knowledge)
        var sync = StoreInfo.file("Biome sync.db", Paths.biomeSyncDB, note: "device-to-device stream sync")
        if let db = await SQLiteDB.sharedIfAvailable(Paths.biomeSyncDB), await db.tableExists("CKAtom") {
            sync.rowCount = await db.rowCount(of: "CKAtom")
        }
        stores.append(sync)

        let biome = snapshot.entries.filter { $0.origin == .biome }
        if !biome.isEmpty {
            let active = biome.filter { $0.live > 0 }
            facts.append(Fact("Biome streams with records", "\(active.count) of \(biome.count) streams · \(Format.count(active.reduce(0) { $0 + $1.live })) events",
                              sensitivity: .low, symbol: "square.grid.3x3.square", sectionID: "biome.catalogue"))
            var remote = 0
            var remoteDevices = Set<String>()
            var oldest: Date?
            for e in biome { for d in e.devices where !d.device.isLocal && d.live > 0 {
                remote += d.live
                if let id = d.device.identifier { remoteDevices.insert(id) }
                if let f = d.first, oldest.map({ f < $0 }) ?? true { oldest = f }
            } }
            if remote > 0 {
                facts.append(Fact("Events synced from your other devices", "\(Format.count(remote)) from \(remoteDevices.count) device\(remoteDevices.count == 1 ? "" : "s"), back to \(DossierDate.day(oldest))",
                                  sensitivity: .personal, symbol: "arrow.triangle.2.circlepath", sectionID: "biome.sync"))
            }
            func count(_ name: String) -> Int { snapshot.entry(named: name)?.live ?? 0 }
            let focus = count("App.InFocus")
            if focus > 0 {
                facts.append(Fact("App focus changes recorded", "\(Format.count(focus)) since \(DossierDate.day(snapshot.entry(named: "App.InFocus")?.range?.lowerBound))",
                                  sensitivity: .personal, symbol: "app.badge", sectionID: "biome.timeline"))
            }
            let messages = count("Siri.Remembers.MessageHistory"), calls = count("Siri.Remembers.CallHistory")
            if messages + calls > 0 {
                facts.append(Fact("Who you messaged and called (Siri Remembers)", "\(Format.count(messages)) message and \(Format.count(calls)) call records with names",
                                  sensitivity: .sensitive, symbol: "person.2.wave.2", sectionID: "biome.stream"))
            }
            let playing = count("Media.NowPlaying")
            if playing > 0 {
                facts.append(Fact("Now-playing history", "\(Format.count(playing)) playback events with titles and artists", sensitivity: .personal, symbol: "music.note", sectionID: "biome.stream"))
            }
            let models = count(AIStore.instrumentationStream)
            if models > 0 {
                facts.append(Fact("On-device AI model events", "\(Format.count(models)) instrumentation records (no prompt text)", sensitivity: .low, symbol: "sparkles", sectionID: "biome.ai"))
            }
            let transparency = count("GenerativeExperiences.TransparencyLog")
            facts.append(Fact("Generative transparency log", transparency > 0 ? "\(Format.count(transparency)) requests with prompts and responses" : "empty",
                              sensitivity: transparency > 0 ? .sensitive : .low, symbol: "doc.text.magnifyingglass", sectionID: "biome.ai"))
        }
        if knowledgeEvents > 0 {
            facts.append(Fact("knowledgeC events", "\(Format.count(knowledgeEvents)) legacy CoreDuet events", sensitivity: .personal, symbol: "cylinder.split.1x2", sectionID: "biome.knowledge"))
        }
        return ModuleSummary(stores: stores, facts: facts)
    }

    // MARK: Search

    public func search(_ query: String, limit: Int) async -> [SearchHit] {
        let needleText = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needleText.count >= 2, limit > 0 else { return [] }
        var hits: [SearchHit] = []
        let snapshot = await BiomeCatalog.shared.snapshot()

        // 1. Stream names and documentation.
        for entry in snapshot.entries where hits.count < max(3, limit / 3) {
            if entry.displayName.localizedCaseInsensitiveContains(needleText) {
                hits.append(SearchHit(
                    title: entry.displayName, subtitle: "Stream · \(countOrDash(entry.live)) records · \(entry.info.summary)",
                    moduleID: id, sectionID: "biome.catalogue", payload: entry.id, symbol: "waveform.path.ecg", sensitivity: .low
                ))
            }
        }
        if Task.isCancelled { return hits }

        // 2. knowledgeC values.
        if hits.count < limit, let db = await SQLiteDB.sharedIfAvailable(Paths.knowledgeC), await db.hasColumns("ZOBJECT", ["ZSTREAMNAME", "ZVALUESTRING", "ZSTARTDATE"]) {
            let like = "%" + needleText.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            let rows = (try? await db.rows("""
                SELECT ZSTREAMNAME, ZVALUESTRING, count(*), max(ZSTARTDATE) FROM ZOBJECT
                WHERE ZVALUESTRING LIKE ? ESCAPE '\\' GROUP BY 1, 2 ORDER BY 3 DESC LIMIT ?
                """, [.text(like), .integer(Int64(min(5, limit - hits.count)))])) ?? []
            for row in rows {
                guard let stream = row[0].string, let value = row[1].string else { continue }
                let n = Int(row[2].int ?? 0)
                hits.append(SearchHit(
                    title: value, subtitle: "knowledgeC \(stream) · \(Format.count(n)) event\(n == 1 ? "" : "s") · latest \(DossierDate.short(row[3].cocoaDate))",
                    moduleID: id, sectionID: "biome.knowledge", payload: stream + "\t" + value, symbol: "cylinder.split.1x2", sensitivity: .personal
                ))
            }
        }
        if Task.isCancelled { return hits }

        // 3. Record contents of the owner-activity streams (byte search over the mapped
        //    segments; telemetry streams are skipped to keep keystroke latency low).
        let needle = ByteNeedle(needleText)
        let candidates = snapshot.activityEntries.sorted { $0.live < $1.live }
        for entry in candidates {
            if hits.count >= limit || Task.isCancelled { break }
            var matches = 0
            var newest: (date: Date, summary: String)?
            for segment in entry.stream.dataSegments().reversed() {
                if Task.isCancelled { break }
                guard let file = try? SEGBFile(url: segment.url) else { continue }
                for e in file.entries.reversed() where e.state.isLive {
                    let payload = file.payload(e)
                    guard needle.matches(payload) else { continue }
                    matches += 1
                    if newest.map({ e.timestamp > $0.date }) ?? true {
                        newest = (e.timestamp, RecordDecoder.summary(entry.info.schema, payload: payload, max: 120))
                    }
                    if matches >= 5_000 { break }
                }
            }
            if let newest, matches > 0 {
                hits.append(SearchHit(
                    title: newest.summary.isEmpty ? entry.displayName : newest.summary,
                    subtitle: "\(entry.displayName) · \(Format.count(matches))\(matches >= 5_000 ? "+" : "") matching record\(matches == 1 ? "" : "s") · latest \(DossierDate.short(newest.date))",
                    moduleID: id, sectionID: "biome.stream", payload: entry.id + "\t" + needleText, symbol: "list.bullet.rectangle", sensitivity: entry.info.sensitivity
                ))
            }
        }
        return Array(hits.prefix(limit))
    }

    // MARK: Self-test

    /// Two page requests with different cut-offs that overlap on one `TimelineSource`
    /// (what a jump-to-time deep link or a quick filter change does while the first page
    /// is still loading). The later request must return exactly what a fresh source
    /// returns, stream records included.
    private static func overlapCheck(snapshot: CatalogSnapshot, selection: TimelineSelection, sample: [TimelineRow]) async -> SelfTestLine {
        let streamRows = sample.filter { if case .record = $0.origin { return true } else { return false } }
        guard streamRows.count > 250, let anchor = streamRows.dropFirst(streamRows.count / 2).first else {
            return .info("Timeline overlapping requests", "not enough stream records to test")
        }
        var jump = selection
        jump.before = anchor.date.addingTimeInterval(1)
        let expected = ((try? await TimelineSource().page(jump, catalog: snapshot, offset: 0, limit: 200)) ?? []).map(\.id)
        var failures = 0, withStreams = 0
        let rounds = 12
        for round in 0..<rounds {
            let shared = TimelineSource()
            let first = Task { try? await shared.page(selection, catalog: snapshot, offset: 0, limit: 200) }
            // Wait until the first request has opened its cursors (it is then suspended in
            // its knowledgeC query or, at the latest, done), then issue the jump: the jump
            // is the later request and must win.
            while await shared.cursorCount() == 0 { await Task.yield() }
            for _ in 0..<(round % 4) { await Task.yield() }
            let second = (try? await shared.page(jump, catalog: snapshot, offset: 0, limit: 200)) ?? []
            if round % 2 == 1 { first.cancel() }
            _ = await first.value
            if second.map(\.id) != expected { failures += 1 }
            if second.contains(where: { $0.date <= jump.before! && { if case .record = $0.origin { return true } else { return false } }($0) }) { withStreams += 1 }
        }
        let expectedStreams = expected.filter { !$0.hasPrefix("k") }.count
        return .check("Timeline overlapping requests", failures == 0 && withStreams == rounds && expectedStreams > 0,
                      "\(rounds - failures)/\(rounds) overlapped jump-to-time pages identical to a fresh merge (\(expectedStreams) stream rows of \(expected.count))")
    }

    /// linkd keeps each App Intent execution twice (combined log + per-app log) and the
    /// Biome stream `App.Intents.Transcript` a third time: totals count it once and the
    /// timeline's default selection takes it from one source.
    private static func linkdChecks(_ snapshot: CatalogSnapshot) -> [SelfTestLine] {
        let linkd = snapshot.entries.filter { $0.origin == .linkd }
        guard !linkd.isEmpty else { return [] }
        let mirror = linkd.filter(\.isMirror).reduce(0) { $0 + $1.live }
        let perApp = linkd.filter { !$0.isMirror }
        let perAppRecords = perApp.reduce(0) { $0 + $1.live }
        let perAppDistinct = BiomeCatalog.distinctPayloads(perApp)
        let biome = snapshot.entry(named: "App.Intents.Transcript")?.devices.first { $0.device.isLocal }?.live ?? 0
        var lines: [SelfTestLine] = [
            .info("App Intents transcripts", "\(snapshot.linkdStored) records stored = \(mirror) combined log + \(perAppRecords) in \(perApp.count) per-app logs; \(snapshot.linkdDistinct) distinct payloads (\(perAppDistinct) in per-app logs); Biome App.Intents.Transcript has \(biome) local records"),
            .check("App Intent executions counted once", snapshot.linkdDistinct <= max(mirror, perAppRecords) && snapshot.totalLive == snapshot.entries.reduce(0) { $0 + $1.live } - snapshot.linkdStored + snapshot.linkdDistinct,
                   "\(snapshot.linkdDistinct) reported, \(snapshot.linkdStored - snapshot.linkdDistinct) duplicate records left out of totals"),
        ]
        let chosen = snapshot.activityEntries
        let sources = [chosen.contains { $0.origin == .biome && $0.stream.name == "App.Intents.Transcript" }, chosen.contains { $0.origin == .linkd && !$0.isMirror }].filter { $0 }.count
        lines.append(.check("Timeline default takes App Intents from one source", sources <= 1 && !chosen.contains(where: \.isMirror),
                            chosen.contains { $0.origin == .linkd } ? "linkd per-app logs" : "Biome App.Intents.Transcript"))
        return lines
    }

    /// The direction numbering of the `Siri.Remembers.*` streams is checked against two
    /// independent sources: `interactions.direction` in Siri Remembers' view.db for the
    /// same interaction id, and the entity roles inside the record (a received message
    /// names its sender, a sent one only recipients).
    private static func remembersDirectionChecks(_ snapshot: CatalogSnapshot) async -> [SelfTestLine] {
        var lines: [SelfTestLine] = []
        guard let field = BiomeStreamRegistry.schemas["Siri.Remembers.MessageHistory"]?.fields.first(where: { $0.name == "Direction" }) else {
            return [.fail("Siri.Remembers direction", "schema has no Direction field")]
        }
        let viewDB = Paths.intelligencePlatformArtifacts.appendingPathComponent("siri/remembers/view.db")
        var view: SQLiteDB?
        if let db = await SQLiteDB.sharedIfAvailable(viewDB), await db.hasColumns("interactions", ["id", "direction"]) { view = db }

        for name in ["Siri.Remembers.MessageHistory", "Siri.Remembers.CallHistory"] {
            guard let entry = snapshot.entry(named: name), entry.live > 0 else { continue }
            // Sample: the newest records of the stream.
            var sample: [(id: String, direction: Int64, label: String, roles: [String])] = []
            BiomeStreamReader(entry.stream).forEachMessage(order: .newestFirst) { record, message in
                if let id = message.string(at: 1, 1), let direction = message[1]?.message?[6]?.int {
                    let roles = message.all(2).compactMap { $0.message?[1]?.string }
                    sample.append((id, Int64(direction), RecordDecoder.display(field, in: record.payload), roles))
                }
                return sample.count < 400
            }
            guard !sample.isEmpty else { continue }

            if name.hasSuffix("MessageHistory") {
                let incoming = sample.filter { $0.label == "Incoming" }, outgoing = sample.filter { $0.label == "Outgoing" }
                let incomingWithSender = incoming.filter { $0.roles.contains { $0.lowercased().contains("sender") } }.count
                let outgoingWithSender = outgoing.filter { $0.roles.contains { $0.lowercased().contains("sender") } }.count
                let anySender = sample.contains { $0.roles.contains { $0.lowercased().contains("sender") } }
                if anySender {
                    lines.append(.check("Siri.Remembers direction vs sender entity", incomingWithSender * 2 > incoming.count && outgoingWithSender == 0,
                                        "\(incomingWithSender)/\(incoming.count) incoming and \(outgoingWithSender)/\(outgoing.count) outgoing messages name a sender"))
                } else {
                    lines.append(.info("Siri.Remembers direction vs sender entity", "no sender entities in the sampled records"))
                }
            }

            guard let view else { continue }
            var agree = 0, joined = 0
            var labels: [Int64: Set<String>] = [:]
            for chunk in stride(from: 0, to: sample.count, by: 200).map({ Array(sample[$0..<min($0 + 200, sample.count)]) }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = (try? await view.rows("SELECT id, direction FROM interactions WHERE id IN (\(marks))", chunk.map { .text($0.id) })) ?? []
                var byID: [String: Int64] = [:]
                for row in rows { if let id = row[0].string, let d = row[1].int { byID[id] = d } }
                for item in chunk {
                    guard let d = byID[item.id] else { continue }
                    joined += 1
                    if d == item.direction { agree += 1 }
                    labels[d, default: []].insert(item.label)
                }
            }
            if joined == 0 {
                lines.append(.info("\(name) direction vs view.db", "no sampled record found in view.db"))
            } else {
                // Same number in both stores, and one label per view.db direction: 1 = Incoming, 2 = Outgoing.
                let consistent = agree == joined && (labels[1] ?? ["Incoming"]) == ["Incoming"] && (labels[2] ?? ["Outgoing"]) == ["Outgoing"]
                lines.append(.check("\(name) direction vs view.db", consistent, "\(agree)/\(joined) sampled records carry the view.db direction (1 = incoming, 2 = outgoing)"))
            }
        }
        if view == nil { lines.append(.info("Siri Remembers view.db", "not available; direction checked against record entities only")) }
        return lines
    }

    public func selfTest() async -> [SelfTestLine] {
        var lines: [SelfTestLine] = []
        func ms(_ start: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000) }
        let verbose = ProcessInfo.processInfo.environment["DOSSIER_BIOME_VERBOSE"] != nil

        // Catalogue
        let restricted = Paths.probe(Paths.biomeRestrictedStreams)
        lines.append(restricted.isAvailable ? .pass("Biome stream directory readable") : .warn("Biome stream directory", restricted.label))
        var start = Date()
        await BiomeCatalog.shared.sync(token: -1)
        let snapshot = await BiomeCatalog.shared.snapshot()
        let biome = snapshot.entries.filter { $0.origin == .biome }
        lines.append(.info("Catalogue", "\(snapshot.entries.count) streams (\(biome.count) Biome, \(snapshot.entries.filter { $0.origin == .duetExpert }.count) Duet Expert, \(snapshot.entries.filter { $0.origin == .linkd }.count) linkd), \(snapshot.nonEmpty.count) with records, indexed in \(ms(start))"))
        lines.append(.info("Biome totals", "\(biome.filter { $0.live > 0 }.count) non-empty streams, \(biome.reduce(0) { $0 + $1.live }) live, \(biome.reduce(0) { $0 + $1.deleted }) deleted records, \(Format.bytes(biome.reduce(0) { $0 + $1.bytes }))"))
        lines.append(.info("All origins", "\(snapshot.totalLive) live, \(snapshot.totalDeleted) deleted records, \(Format.bytes(snapshot.totalBytes))"))
        lines.append(contentsOf: Self.linkdChecks(snapshot))
        let remoteDevices = Set(snapshot.entries.flatMap { $0.devices.compactMap { $0.live > 0 ? $0.device.identifier : nil } })
        lines.append(.info("Devices", "local + \(remoteDevices.count) remote; \(snapshot.peers.count) peers in sync.db"))

        // Cross-check against the Core reader (independent code path).
        start = Date()
        var mismatches: [String] = []
        for entry in snapshot.nonEmpty {
            let stats = BiomeStreamReader(entry.stream).stats()
            if stats.records != entry.live || stats.deleted != entry.deleted { mismatches.append(entry.displayName) }
        }
        lines.append(.check("Counts agree with BiomeStreamReader.stats()", mismatches.isEmpty, mismatches.isEmpty ? "\(snapshot.nonEmpty.count) streams, \(ms(start))" : mismatches.prefix(5).joined(separator: ", ")))

        // Per-stream figures (top streams, or all with DOSSIER_BIOME_VERBOSE=1).
        let listed = verbose ? snapshot.nonEmpty : Array(snapshot.nonEmpty.sorted { $0.live > $1.live }.prefix(12))
        for entry in listed {
            let devices = entry.devices.filter { $0.live > 0 || $0.deleted > 0 }.map { d in
                "\(d.device.isLocal ? "local" : "remote") \(d.live)/\(d.deleted)"
            }.joined(separator: ", ")
            lines.append(.info("  " + entry.displayName, "\(entry.live) live, \(entry.deleted) deleted [\(devices)] \(entry.range.map { DossierDate.sortable($0.lowerBound) + " … " + DossierDate.sortable($0.upperBound) } ?? "no dates")"))
        }

        // Registry coverage and decoder sanity.
        let typed = snapshot.nonEmpty.filter { $0.info.schema != nil }
        lines.append(.info("Registry", "\(BiomeStreamRegistry.schemas.count) schemas, \(BiomeStreamRegistry.descriptions.count) descriptions; typed decoders for \(typed.count) of \(snapshot.nonEmpty.count) non-empty streams (\(typed.reduce(0) { $0 + $1.live }) of \(snapshot.totalLive) records)"))
        let undocumented = biome.filter { BiomeStreamRegistry.descriptions[$0.stream.name] == nil }.map(\.stream.name)
        lines.append(undocumented.isEmpty ? .pass("Every Biome stream has a description") : .warn("Streams with generic description", undocumented.prefix(8).joined(separator: ", ")))
        start = Date()
        var weak: [String] = []
        var crcChecked = 0, crcBad = 0, unparsed = 0, sampled = 0
        for entry in snapshot.nonEmpty {
            var decoded = 0, seen = 0
            BiomeStreamReader(entry.stream).forEach(order: .newestFirst) { record in
                seen += 1; sampled += 1
                if seen <= 40 {
                    crcChecked += 1
                    if CRC32.checksum(record.payload) != record.entry.crc { crcBad += 1 }
                }
                if ProtoMessage(record.payload) == nil, PlistDecoder.decodeAny(record.payload) == nil { unparsed += 1 }
                if let schema = entry.info.schema, schema.headlines.contains(where: { !RecordDecoder.display($0, in: record.payload).isEmpty }) { decoded += 1 }
                return seen < 300
            }
            if entry.info.schema != nil, seen > 0, decoded * 2 < seen { weak.append("\(entry.displayName) \(decoded)/\(seen)") }
        }
        lines.append(contentsOf: await Self.remembersDirectionChecks(snapshot))
        lines.append(.check("Typed decoders produce values", weak.isEmpty, weak.isEmpty ? "sampled \(sampled) records in \(ms(start))" : weak.joined(separator: ", ")))
        lines.append(.check("Record CRC-32", crcBad == 0, "\(crcChecked - crcBad)/\(crcChecked) sampled records verified"))
        lines.append(unparsed == 0 ? .pass("Payloads parse as protobuf or keyed archive", "\(sampled) sampled") : .info("Payloads neither protobuf nor plist", "\(unparsed) of \(sampled) sampled records (shown as raw blobs)"))

        // Timeline merge.
        start = Date()
        let activity = snapshot.activityEntries
        let source = TimelineSource()
        let selection = TimelineSelection(streams: Set(activity.map(\.id)), devices: nil, before: nil, includeKnowledge: true, search: "", refresh: 0)
        if let rows = try? await source.page(selection, catalog: snapshot, offset: 0, limit: 200) {
            let firstPage = ms(start)
            let more = (try? await source.page(selection, catalog: snapshot, offset: 200, limit: 1_800)) ?? []
            let all = rows + more
            var ordered = true
            for i in 1..<max(1, all.count) where all[i].date > all[i - 1].date { ordered = false }
            let cursors = await source.cursorCount()
            lines.append(.check("Timeline merge is ordered", ordered, "\(all.count) rows over \(cursors) cursors (\(activity.count) activity streams + knowledgeC); first page \(firstPage), 2,000 rows \(ms(start))"))
            if let first = all.first, let last = all.last {
                lines.append(.info("Timeline window", "\(DossierDate.sortable(last.date)) … \(DossierDate.sortable(first.date))"))
            }
            let everything = TimelineSelection(streams: Set(snapshot.nonEmpty.map(\.id)), devices: nil, before: Date().addingTimeInterval(-86_400), includeKnowledge: true, search: "", refresh: 1)
            start = Date()
            let jumped = (try? await TimelineSource().page(everything, catalog: snapshot, offset: 0, limit: 200)) ?? []
            lines.append(.check("Timeline jump-to-time", jumped.allSatisfy { $0.date <= everything.before! }, "all \(snapshot.nonEmpty.count) streams, 200 rows before yesterday in \(ms(start))"))
            lines.append(await Self.overlapCheck(snapshot: snapshot, selection: selection, sample: all))
        } else {
            lines.append(.fail("Timeline merge", "page failed"))
        }

        // knowledgeC
        start = Date()
        switch Paths.probe(Paths.knowledgeC) {
        case .available:
            do {
                let streams = try await KnowledgeStore.streams()
                let total = streams.reduce(0) { $0 + $1.count }
                let real = streams.filter { !$0.isBookkeeping }
                let firsts = real.compactMap(\.first), lasts = real.compactMap(\.last)
                lines.append(.pass("knowledgeC.db", "\(total) events in \(streams.count) streams (\(real.count) event streams, \(real.reduce(0) { $0 + $1.count }) events), \(DossierDate.sortable(firsts.min())) … \(DossierDate.sortable(lasts.max())), \(ms(start))"))
                for s in real.prefix(verbose ? 100 : 6) {
                    lines.append(.info("  " + s.name, "\(s.count) events, \(s.withMetadata) with metadata, \(s.devices.count) source device(s), \(DossierDate.sortable(s.first)) … \(DossierDate.sortable(s.last))"))
                }
                if let first = real.first {
                    let page = try await KnowledgeStore.events(stream: first.name, search: "", sort: nil, offset: 0, limit: 50)
                    let n = try await KnowledgeStore.count(stream: first.name, search: "")
                    lines.append(.check("knowledgeC paging", n == first.count && page.count == min(50, first.count), "\(first.name): count \(n), page \(page.count), \(page.filter { !$0.metadata.isEmpty }.count) rows with decoded metadata"))
                }
            } catch {
                lines.append(.fail("knowledgeC.db", error.localizedDescription))
            }
        case let other:
            lines.append(.warn("knowledgeC.db", other.label))
        }

        // sync.db
        start = Date()
        switch Paths.probe(Paths.biomeSyncDB) {
        case .available:
            do {
                let sync = try await SyncStore.load(catalog: snapshot)
                let resolved = Set(sync.locations.filter { $0.resolvedStream != nil }.map(\.syncStream)).count
                lines.append(.pass("Biome sync.db", "\(sync.peers.count) devices, \(sync.streamCount) synced streams (\(resolved) resolved to stream folders), \(sync.locationTotal) CRDT locations, \(sync.atomTotal) atoms, \(sync.mergedTotal) merge-log rows, \(sync.sessions.count) sessions, \(sync.cloudRecords) CloudKit records, \(ms(start))"))
            } catch {
                lines.append(.fail("Biome sync.db", error.localizedDescription))
            }
        case let other:
            lines.append(.warn("Biome sync.db", other.label))
        }

        // AI telemetry
        start = Date()
        let ai = await AIStore.shared.load(token: -1, catalog: snapshot)
        lines.append(.info("AI telemetry", "\(ai.instrumentationRecords) instrumentation records, \(ai.events.count) event types, \(ai.useCases.count) use cases (\(ai.requests) attributed), \(ai.models.count) model assets, \(ai.errors.reduce(0) { $0 + $1.count }) errors, \(ai.availability.count) availability records, \(ai.tasks.count) ledger tasks (\(ai.ledgerRecords) records), \(ai.transcripts.filter { $0.records > 0 }.count)/\(ai.transcripts.count) transcript streams non-empty, \(ms(start))"))
        for item in ai.events.prefix(verbose ? 30 : 3) { lines.append(.info("  event " + item.name, "\(item.count)")) }
        for item in ai.useCases.prefix(verbose ? 30 : 3) { lines.append(.info("  use case " + item.name, "\(item.count)")) }

        // Summary + search timings.
        start = Date()
        let summary = await summary()
        lines.append(.info("summary()", "\(summary.stores.count) stores, \(summary.facts.count) facts, \(ms(start))"))
        start = Date()
        let hits = await search("apple", limit: 20)
        lines.append(.info("search(\"apple\")", "\(hits.count) hits, \(ms(start))"))
        return lines
    }
}
