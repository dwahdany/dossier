import SwiftUI
import DossierCore

/// Communications — who the system knows the owner talks to.
///
/// Sources (all read-only):
/// * Siri Remembers view database + the Biome `Siri.Remembers.*` streams it is built from
///   (a year of message / call metadata donated by apps on the owner's devices, plus
///   media requests, Find My lookups, shortcut runs and Siri suggestions),
/// * knowledgeC `/app/intents` (recent intents incl. retained message text),
/// * interactionC (Mail / Calendar correspondents and meeting keywords),
/// * the Mac's call history, CoreRecents and the iCloud key-value cache (mail recents,
///   VIPs, favourites, blocked contacts).
public final class CommsModule: DossierModule {
    public let id = "comms"
    public let title = "Communications"
    public let symbol = "bubble.left.and.bubble.right"
    public let group = SidebarGroup.people

    public init() {}

    public var sections: [ModuleSection] {
        [
            ModuleSection(id: "comms.overview", title: "Summary", symbol: "chart.bar.xaxis") { CommsOverviewView() },
            ModuleSection(id: "comms.people", title: "People", symbol: "person.2") { PeopleView() },
            ModuleSection(id: "comms.conversations", title: "Conversations", symbol: "bubble.left.and.text.bubble.right") { ConversationsView() },
            ModuleSection(id: "comms.messages", title: "Messages Timeline", symbol: "text.bubble") { MessagesView() },
            ModuleSection(id: "comms.calls", title: "Calls", symbol: "phone") { CallsView() },
            ModuleSection(id: "comms.siri", title: "Other Siri Memories", symbol: "waveform") { SiriMemoriesView() },
            ModuleSection(id: "comms.correspondents", title: "Mail & Meeting Contacts", symbol: "at") { CorrespondentsView() },
            ModuleSection(id: "comms.retained", title: "Retained Content", symbol: "lock.doc") { RetainedContentView() },
            ModuleSection(id: "comms.recents", title: "Recents, VIPs & Favourites", symbol: "star") { RecentsView() },
        ]
    }

    // MARK: Summary

    public func summary() async -> ModuleSummary {
        var stores: [StoreInfo] = []
        var facts: [Fact] = []

        // Siri Remembers view.
        var view = StoreInfo.file("Siri Remembers (view.db)", CommsPaths.remembersView, note: "messages & calls donated by apps, synced from your devices")
        if let overview = try? await RemembersStore.overview() {
            view.rowCount = overview.total
            view.timeRange = overview.range
            let messageApps = overview.apps.filter { $0.messages > 0 }.count
            facts.append(Fact("Messages remembered", "\(Format.count(overview.messages)) across \(messageApps) apps", sensitivity: .personal, symbol: "text.bubble", sectionID: "comms.messages"))
            if overview.calls > 0 {
                facts.append(Fact("Calls remembered", "\(Format.count(overview.calls)) · \(Format.duration(overview.callSeconds)) talk time", sensitivity: .personal, symbol: "phone", sectionID: "comms.calls"))
            }
            if let top = overview.apps.first {
                facts.append(Fact("Most used messaging app", "\(AppNames.name(top.bundle)) (\(Format.count(top.total)))", sensitivity: .personal, symbol: "app.badge", sectionID: "comms.overview"))
            }
        }
        stores.append(view)
        if let kinds = try? await SiriMemories.kinds(), !kinds.isEmpty {
            let total = kinds.reduce(0) { $0 + $1.count }
            let examples = kinds.prefix(3).map(\.label).joined(separator: ", ")
            facts.append(Fact("Other Siri memories", "\(Format.count(total)) besides messages and calls: \(examples)\(kinds.count > 3 ? " …" : "")", sensitivity: .personal, symbol: "waveform", sectionID: "comms.siri"))
        }
        if let people = try? await CommsCache.shared.people(0), let top = people.first {
            facts.append(Fact("People you talk to", "\(Format.count(people.count)) counterparts", sensitivity: .personal, symbol: "person.2", sectionID: "comms.people"))
            facts.append(Fact("Most frequent counterpart", "\(top.name) (\(Format.count(top.total)) interactions)", sensitivity: .sensitive, symbol: "person.crop.circle", sectionID: "comms.people"))
        }

        // Biome streams.
        for stat in await RemembersStore.streamStats() where stat.records > 0 {
            if let stream = Biome.stream(named: stat.name) {
                stores.append(StoreInfo(name: "Biome \(stat.name)", path: stream.url, sizeBytes: stat.bytes, rowCount: stat.records, timeRange: stat.range, note: stat.devices.joined(separator: ", ")))
            }
        }

        // knowledgeC intents.
        var knowledge = StoreInfo.file("knowledgeC (/app/intents)", Paths.knowledgeC, note: "recent intents incl. retained message text")
        if let snapshot = try? await IntentStore.shared.snapshot() {
            knowledge.rowCount = snapshot.streamTotal
            knowledge.timeRange = snapshot.range
            let texts = snapshot.withText
            if !texts.isEmpty {
                let apps = Set(texts.map(\.bundle)).count
                facts.append(Fact("Message bodies retained", "\(Format.count(texts.count)) verbatim texts from \(apps) apps", sensitivity: .sensitive, symbol: "lock.doc", sectionID: "comms.retained"))
                let codes = texts.filter(\.isCode).count
                if codes > 0 {
                    facts.append(Fact("Likely one-time codes retained", Format.count(codes), sensitivity: .sensitive, symbol: "key", sectionID: "comms.retained"))
                }
            }
        }
        stores.append(knowledge)

        // interactionC.
        var interaction = StoreInfo.file("interactionC.db", Paths.interactionC, note: "Mail & Calendar correspondents")
        if let overview = try? await InteractionCStore.overview() {
            interaction.rowCount = overview.interactions
            interaction.timeRange = overview.range
            facts.append(Fact("Mail & meeting contacts", "\(Format.count(overview.contacts)) contacts, \(Format.count(overview.past)) past interactions", sensitivity: .personal, symbol: "envelope.open", sectionID: "comms.correspondents"))
            if overview.scheduled > 0 {
                // Future occurrences of (recurring) calendar events — not part of the time range above.
                interaction.note = "Mail & Calendar correspondents · \(Format.count(overview.past)) past + \(Format.count(overview.scheduled)) scheduled"
                let until = overview.scheduledUntil.map { " up to \(DossierDate.day($0))" } ?? ""
                facts.append(Fact("Scheduled meetings on record", "\(Format.count(overview.scheduled)) future calendar occurrences\(until)", sensitivity: .personal, symbol: "calendar.badge.clock", sectionID: "comms.correspondents"))
            }
            if !overview.keywords.isEmpty {
                facts.append(Fact("Meeting-title keywords", "\(Format.count(overview.keywords.count)) words, e.g. “\(overview.keywords[0].word)”", sensitivity: .personal, symbol: "textformat", sectionID: "comms.correspondents"))
            }
        }
        stores.append(interaction)

        // Call history, recents, kvs.
        var calls = StoreInfo.file("CallHistory.storedata", CommsPaths.callHistory, note: "this Mac's call log")
        if let db = await CommsDB.openIfAvailable(CommsPaths.callHistory), await db.tableExists("ZCALLRECORD") {
            calls.rowCount = await db.rowCount(of: "ZCALLRECORD")
            if let r = try? await db.first("SELECT min(ZDATE), max(ZDATE) FROM ZCALLRECORD"), let lo = r[0].cocoaDate, let hi = r[1].cocoaDate { calls.timeRange = lo...hi }
        }
        stores.append(calls)

        var recents = StoreInfo.file("CoreRecents", CommsPaths.recentsDB, note: "recent addressees of Mail, Calendar, Wallet")
        if let db = await CommsDB.openIfAvailable(CommsPaths.recentsDB), await db.tableExists("contacts") {
            recents.rowCount = await db.rowCount(of: "contacts")
        }
        stores.append(recents)

        if let dir = CommsPaths.kvsDirectory {
            let availability = Paths.probe(dir)
            var kvs = StoreInfo(name: "iCloud Key-Value Cache", path: dir, availability: availability, note: "mail recents, VIPs, favourites, blocked contacts")
            if availability.isAvailable {
                kvs.sizeBytes = CommsPaths.kvsDatabases().reduce(Int64(0)) { $0 + FileProbe.databaseSize($1) }
                kvs.rowCount = (try? await KVSStore.rows())?.count
            }
            stores.append(kvs)
        } else {
            stores.append(StoreInfo(name: "iCloud Key-Value Cache", path: Paths.daemonContainers, availability: .missing, note: "mail recents, VIPs, favourites, blocked contacts"))
        }
        return ModuleSummary(stores: stores, facts: facts)
    }

    // MARK: Search

    public func search(_ query: String, limit: Int) async -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2, limit > 0 else { return [] }
        var hits: [SearchHit] = []
        var seenPeople = Set<String>()

        for entity in await RemembersStore.searchEntities(needle, limit: limit) {
            if Task.isCancelled { return hits }
            if entity.type == "PersonHandle" {
                let key = RemembersStore.personKey(name: entity.name, handle: entity.id)
                guard seenPeople.insert(key).inserted else { continue }
                let named = !(entity.name ?? "").isEmpty
                hits.append(SearchHit(
                    id: "comms.person.\(key)", title: named ? entity.name! : entity.id,
                    subtitle: "Person · \(named ? entity.id + " · " : "")\(Format.count(entity.count)) interactions (Siri Remembers)",
                    moduleID: id, sectionID: "comms.people", payload: "person:" + key, symbol: "person.crop.circle", sensitivity: .sensitive))
            } else {
                hits.append(SearchHit(
                    id: "comms.conversation.\(entity.id)", title: Format.oneLine(entity.id, max: 120),
                    subtitle: "Conversation title · \(Format.count(entity.count)) messages (Siri Remembers)",
                    moduleID: id, sectionID: "comms.conversations", payload: "title:" + entity.id, symbol: "bubble.left.and.bubble.right", sensitivity: .sensitive))
            }
            if hits.count >= limit { return hits }
        }

        if Task.isCancelled { return hits }
        for memory in await SiriMemories.search(needle, limit: max(1, min(8, limit - hits.count))) {
            hits.append(SearchHit(
                id: "comms.memory.\(memory.id)", title: Format.oneLine(memory.summary.isEmpty ? memory.kind : memory.summary, max: 120),
                subtitle: "Siri memory · \(memory.kind) · \(AppNames.name(memory.bundle)) · \(DossierDate.short(memory.date))",
                moduleID: id, sectionID: "comms.siri", payload: "memory:\(memory.id)", symbol: "waveform", sensitivity: .personal))
            if hits.count >= limit { return hits }
        }

        if Task.isCancelled { return hits }
        for contact in await InteractionCStore.search(needle, limit: max(1, limit - hits.count)) {
            hits.append(SearchHit(
                id: "comms.contact.\(contact.id)", title: contact.name.isEmpty ? contact.identifier : contact.name,
                subtitle: "Mail / meeting contact · \(contact.identifier) (interactionC)",
                moduleID: id, sectionID: "comms.correspondents", payload: "contact:\(contact.id)", symbol: "envelope.open", sensitivity: .sensitive))
            if hits.count >= limit { return hits }
        }

        if Task.isCancelled { return hits }
        let snapshot = await IntentStore.shared.snapshotOrEmpty()
        for record in snapshot.records {
            if Task.isCancelled || hits.count >= limit { break }
            guard let text = record.text, text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }
            hits.append(SearchHit(
                id: "comms.intent.\(record.id)", title: Format.oneLine(text, max: 120),
                subtitle: "Retained message text · \(AppNames.name(record.bundle)) · \(DossierDate.short(record.date))",
                moduleID: id, sectionID: "comms.retained", payload: "intent:\(record.id)", symbol: "lock.doc", sensitivity: .sensitive))
        }
        return hits
    }

    // MARK: Self-test

    public func selfTest() async -> [SelfTestLine] {
        var lines: [SelfTestLine] = []
        func timed<T>(_ work: () async throws -> T) async rethrows -> (T, String) {
            let start = Date()
            let value = try await work()
            return (value, String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000))
        }
        func availability(_ label: String, _ url: URL?) -> Bool {
            let state = Paths.probe(url)
            switch state {
            case .available: lines.append(.pass("\(label) readable")); return true
            case .missing: lines.append(.warn("\(label) missing", "not present on this Mac")); return false
            case .inaccessible(let reason): lines.append(.warn("\(label) inaccessible", reason)); return false
            }
        }

        // Siri Remembers view.
        var viewTypes: [String: Int] = [:]
        if availability("Siri Remembers view.db", CommsPaths.remembersView) {
            do {
                let (overview, ms) = try await timed { try await RemembersStore.overview() }
                viewTypes = Dictionary(overview.types.map { ($0.type, $0.count) }, uniquingKeysWith: +)
                lines.append(.pass("view.db interactions", "\(overview.total) rows · \(overview.messages) messages · \(overview.calls) calls · \(DossierDate.range(overview.range)) · \(ms)"))
                lines.append(.info("view.db direction split", "incoming \(overview.incoming) · outgoing \(overview.outgoing) · call seconds \(Int(overview.callSeconds))"))
                lines.append(.info("view.db apps / devices", "\(overview.apps.count) apps · \(overview.devices.count) source devices · \(overview.handleCount) handles · \(overview.conversationCount) conversation titles"))
                let (people, pms) = try await timed { try await RemembersStore.people() }
                lines.append(.check("people aggregation", !people.isEmpty || overview.total == 0, "\(people.count) counterparts from \(people.reduce(0) { $0 + $1.handles.count }) handles · \(pms)"))
                let (conversations, cms) = try await timed { try await RemembersStore.conversations() }
                let content = conversations.rows.filter(\.isContent).count
                lines.append(.pass("conversation titles", "\(conversations.rows.count) title×app pairs · \(content) flagged as content · \(cms)"))
                let (calls, kms) = try await timed { try await RemembersStore.calls() }
                lines.append(.check("calls list equals call count", calls.count == overview.calls, "\(calls.count) rows · \(kms)"))
                let namer = await RemembersStore.deviceNamer()
                let (page, mms) = try await timed { try await RemembersStore.messages(MessageFilter(), request: PageRequest(offset: 0, limit: 200), texts: [:], namer: namer) }
                let count = try await RemembersStore.messageCount(MessageFilter(), search: "", texts: [:])
                lines.append(.check("messages first page", page.count == min(200, overview.messages) && count == overview.messages, "\(page.count) rows of \(count ?? -1) · \(mms)"))
                let kinds = try await SiriMemories.kinds()
                let otherTotal = try await SiriMemories.total()
                let otherPage = try await SiriMemories.page(request: PageRequest(offset: 0, limit: 200), namer: namer)
                let withDetails = otherPage.filter { !$0.summary.isEmpty }.count
                lines.append(.check("other Siri memories", otherTotal == overview.total - overview.messages - overview.calls && kinds.reduce(0) { $0 + $1.count } == otherTotal && otherPage.count == min(200, otherTotal),
                                    "\(otherTotal) interactions · \(kinds.count) kinds (\(kinds.map { "\($0.type) \($0.count)" }.joined(separator: ", "))) · \(withDetails) of the first \(otherPage.count) with entity details"))
            } catch {
                lines.append(.fail("view.db queries", error.localizedDescription))
            }
        }

        // Biome streams vs. view.
        let (stats, sms) = await timed { await RemembersStore.streamStats() }
        if stats.isEmpty {
            lines.append(.warn("Biome Siri.Remembers streams", "none found"))
        } else {
            for stat in stats {
                lines.append(.info("Biome \(stat.name)", "\(stat.records) records · \(stat.deleted) deleted · \(Format.bytes(stat.bytes)) · \(DossierDate.range(stat.range)) · devices: \(stat.devices.count)"))
            }
            let (streamTypes, tms) = await timed { await Task.detached { RemembersStore.streamTypeCounts() }.value }
            let streamMessages = streamTypes[RemembersSchema.messageType] ?? 0
            let streamCalls = streamTypes[RemembersSchema.callType] ?? 0
            lines.append(.info("Biome stream decode", "\(streamTypes.values.reduce(0, +)) records decoded · \(streamMessages) messages · \(streamCalls) calls · index \(sms) · decode \(tms)"))
            if !viewTypes.isEmpty {
                let viewMessages = viewTypes.first { $0.key.caseInsensitiveCompare(RemembersSchema.messageType) == .orderedSame }?.value ?? 0
                let viewCalls = viewTypes.first { $0.key.caseInsensitiveCompare(RemembersSchema.callType) == .orderedSame }?.value ?? 0
                // The view keeps one row per interaction id; the streams can hold repeated
                // donations of the same call, so the view may be slightly smaller.
                let close = { (view: Int, stream: Int) in view <= stream && (stream - view) * 20 <= max(stream, 1) }
                let status: SelfTestLine.Status = (close(viewMessages, streamMessages) && close(viewCalls, streamCalls)) ? .pass : .warn
                lines.append(SelfTestLine(status, "view.db consistent with Biome streams", "messages \(viewMessages) vs \(streamMessages) · calls \(viewCalls) vs \(streamCalls) (view rows are unique interaction ids; streams may repeat a donation)"))
            }
        }

        // knowledgeC intents.
        if availability("knowledgeC.db", Paths.knowledgeC) {
            do {
                let (snapshot, ms) = try await timed { try await IntentStore.shared.snapshot(token: -1) }
                let messages = snapshot.records.filter { $0.kind == .message }
                let texts = snapshot.withText
                lines.append(.pass("knowledgeC /app/intents", "\(snapshot.streamTotal) rows · \(messages.count) message intents · \(snapshot.records.count - messages.count) call intents · \(DossierDate.range(snapshot.range)) · \(ms)"))
                lines.append(.check("intent blobs decode", snapshot.undecodable == 0 || snapshot.undecodable * 10 < max(snapshot.records.count, 1), "\(snapshot.records.count - snapshot.undecodable) decoded · \(snapshot.undecodable) undecodable"))
                lines.append(.info("retained message text", "\(texts.count) records with body text · \(Set(texts.map(\.bundle)).count) apps · \(texts.filter(\.isCode).count) flagged as likely one-time codes"))
                // Direction convention + id join against the view.
                if let db = try? await RemembersStore.open(), !snapshot.byIntentID.isEmpty {
                    var matched = 0, agree = 0
                    let rows = (try? await db.rows("SELECT upper(id), direction FROM interactions WHERE startDate >= ?", [.real((snapshot.range?.lowerBound ?? Date()).cocoa - 1)])) ?? []
                    for row in rows {
                        guard let id = row[0].string, let record = snapshot.byIntentID[id] else { continue }
                        matched += 1
                        if CommDirection.remembers(row[1].int) == record.direction { agree += 1 }
                    }
                    let status: SelfTestLine.Status = matched == 0 ? .warn : (agree * 100 >= matched * 95 ? .pass : .fail)
                    lines.append(SelfTestLine(status, "intents join Siri Remembers by id", "\(matched) of \(snapshot.byIntentID.count) intents found in view.db · direction agrees for \(agree)"))
                }
            } catch {
                lines.append(.fail("knowledgeC intents", error.localizedDescription))
            }
        }

        // interactionC.
        if availability("interactionC.db", Paths.interactionC) {
            do {
                let (overview, ms) = try await timed { try await InteractionCStore.overview() }
                let people = try await InteractionCStore.correspondents()
                lines.append(.pass("interactionC", "\(overview.interactions) interactions (\(overview.past) past + \(overview.scheduled) scheduled\(overview.scheduledUntil.map { " up to " + DossierDate.day($0) } ?? "")) · \(overview.contacts) contacts (\(people.count) listed) · \(overview.keywords.count) keywords / \(overview.keywordLinks) links · \(DossierDate.range(overview.range)) · \(ms)"))
            } catch {
                lines.append(.fail("interactionC queries", error.localizedDescription))
            }
        }

        // Call history.
        if availability("CallHistory.storedata", CommsPaths.callHistory) {
            do {
                let calls = try await CallHistoryStore.calls()
                let stats = CallMath.stats(calls)
                lines.append(.pass("CallHistory", "\(calls.count) calls · \(stats.incoming) in / \(stats.outgoing) out · \(Int(stats.seconds)) s · \(DossierDate.range(stats.range))"))
            } catch {
                lines.append(.fail("CallHistory queries", error.localizedDescription))
            }
        }

        // CoreRecents.
        if availability("CoreRecents", CommsPaths.recentsDB) {
            do {
                let rows = try await RecentsStore.rows()
                let dates = rows.compactMap(\.last)
                let range = dates.min().flatMap { lo in dates.max().map { lo...$0 } }
                lines.append(.pass("CoreRecents", "\(rows.count) contact rows · \(Set(rows.map(\.bundle)).count) apps · \(DossierDate.range(range))"))
            } catch {
                lines.append(.fail("CoreRecents queries", error.localizedDescription))
            }
        }

        // kvs.
        if availability("iCloud key-value cache", CommsPaths.kvsDirectory) {
            do {
                let rows = try await KVSStore.rows()
                let byCategory = Dictionary(grouping: rows, by: \.category).mapValues(\.count).sorted { $0.key < $1.key }
                lines.append(.pass("iCloud key-value cache", "\(CommsPaths.kvsDatabases().count) databases · " + byCategory.map { "\($0.key) \($0.value)" }.joined(separator: " · ")))
            } catch {
                lines.append(.fail("kvs queries", error.localizedDescription))
            }
        }

        // Generic detector sanity (synthetic strings only).
        let detectorOK = CodeDetector.looksLikeCode("Your verification code is 482913.")
            && CodeDetector.looksLikeCode("TAN: 123 456")
            && !CodeDetector.looksLikeCode("See you at 18:30 on 12.03.2024")
            && !CodeDetector.looksLikeCode("Meeting moved to room 2048")
        lines.append(.check("one-time-code detector", detectorOK, "synthetic positives and negatives"))

        let (summary, sums) = await timed { await self.summary() }
        lines.append(.info("summary()", "\(summary.stores.count) stores · \(summary.facts.count) facts · \(sums)"))
        return lines
    }
}

/// Per-refresh cache of the aggregated lists the table sections page over.
actor CommsCache {
    static let shared = CommsCache()

    private var token = Int.min
    private var peopleValue: [PersonRow]?
    private var conversationValue: ConversationData?
    private var callValues: [String: [CallRow]] = [:]
    private var correspondentValue: [CorrespondentRow]?
    private var recentValues: [String: [RecentRow]] = [:]
    private var namer: RemembersStore.DeviceNamer?

    private func sync(_ newToken: Int) {
        guard newToken != token else { return }
        token = newToken
        peopleValue = nil; conversationValue = nil; callValues = [:]; correspondentValue = nil; recentValues = [:]; namer = nil
    }

    func people(_ token: Int) async throws -> [PersonRow] {
        sync(token)
        if let peopleValue { return peopleValue }
        let value = try await RemembersStore.people()
        peopleValue = value
        return value
    }

    func conversations(_ token: Int) async throws -> ConversationData {
        sync(token)
        if let conversationValue { return conversationValue }
        let value = try await RemembersStore.conversations()
        conversationValue = value
        return value
    }

    func calls(_ source: CallSource, _ token: Int) async throws -> [CallRow] {
        sync(token)
        if let value = callValues[source.rawValue] { return value }
        let value: [CallRow]
        switch source {
        case .remembers: value = try await RemembersStore.calls()
        case .callHistory: value = try await CallHistoryStore.calls()
        case .knowledge:
            let snapshot = try await IntentStore.shared.snapshot(token: token)
            value = snapshot.records.filter { $0.kind == .call }.map { record in
                CallRow(id: "kc-\(record.id)", date: record.date, bundle: record.bundle, direction: record.direction,
                        person: record.recipients.map(\.display).joined(separator: ", "),
                        handle: record.recipients.map(\.handle).joined(separator: ", "),
                        seconds: record.seconds, status: record.seconds > 0 ? "Connected" : "Not connected",
                        device: record.remote ? "Synced device" : "This Mac")
            }
        }
        callValues[source.rawValue] = value
        return value
    }

    func correspondents(_ token: Int) async throws -> [CorrespondentRow] {
        sync(token)
        if let correspondentValue { return correspondentValue }
        let value = try await InteractionCStore.correspondents()
        correspondentValue = value
        return value
    }

    func recents(_ source: RecentSource, _ token: Int) async throws -> [RecentRow] {
        sync(token)
        if let value = recentValues[source.rawValue] { return value }
        let value: [RecentRow]
        switch source {
        case .coreRecents: value = try await RecentsStore.rows()
        case .kvs: value = try await KVSStore.rows()
        }
        recentValues[source.rawValue] = value
        return value
    }

    func deviceNamer(_ token: Int) async -> RemembersStore.DeviceNamer {
        sync(token)
        if let namer { return namer }
        let value = await RemembersStore.deviceNamer()
        namer = value
        return value
    }
}

enum CallSource: String, CaseIterable, Identifiable, Sendable {
    case remembers = "Siri Remembers", callHistory = "Call History", knowledge = "knowledgeC"
    var id: String { rawValue }

    var url: URL {
        switch self {
        case .remembers: return CommsPaths.remembersView
        case .callHistory: return CommsPaths.callHistory
        case .knowledge: return Paths.knowledgeC
        }
    }

    var note: String {
        switch self {
        case .remembers: return "Calls donated to Siri by phone and messaging apps on your devices (about a year, synced through Biome)."
        case .callHistory: return "This Mac's own call log: phone calls relayed through the iPhone and FaceTime calls."
        case .knowledge: return "Call intents in knowledgeC — the most recent weeks only, synced from your other devices."
        }
    }
}

enum RecentSource: String, CaseIterable, Identifiable, Sendable {
    case coreRecents = "CoreRecents", kvs = "iCloud Key-Value Cache"
    var id: String { rawValue }
}
