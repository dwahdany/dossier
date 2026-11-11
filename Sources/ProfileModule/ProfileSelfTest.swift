import Foundation
import DossierCore

/// `--selftest` for the Interest Profile module: availability, row counts and time ranges
/// per source, decoder consistency checks, and timings of every section's first load.
enum ProfileSelfTest {
    private static func timed<T>(_ work: () async throws -> T) async rethrows -> (T, String) {
        let start = Date()
        let value = try await work()
        return (value, String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000))
    }

    private static func range(_ lo: Date?, _ hi: Date?) -> String {
        guard let lo, let hi else { return "no dates" }
        return DossierDate.day(lo) + " … " + DossierDate.day(hi)
    }

    private static func availability(_ label: String, _ url: URL) -> SelfTestLine {
        switch Paths.probe(url) {
        case .available: return .pass(label, "readable")
        case .missing: return .warn(label, "not present on this Mac")
        case .inaccessible(let reason): return .warn(label, "no access: \(reason)")
        }
    }

    static func run() async -> [SelfTestLine] {
        var lines: [SelfTestLine] = []
        let started = Date()
        lines += await portrait()
        lines += await suggestions()
        lines += await vocabulary()
        lines += await identifiers()
        lines += decoders()
        lines.append(.info("Total self-test time", String(format: "%.0f ms", Date().timeIntervalSince(started) * 1000)))
        return lines
    }

    // MARK: PersonalizationPortrait

    private static func portrait() async -> [SelfTestLine] {
        var lines = [availability("PersonalizationPortrait/PPSQLDatabase.db", ProfilePaths.portraitDB)]
        guard let db = await SQLiteDB.sharedIfAvailable(ProfilePaths.portraitDB) else { return lines }
        for table in ["sources", "tp_records", "ne_records", "loc_records", "cn_handles", "cn_handles_sources", "significant_contacts"] {
            if let count = await db.rowCount(of: table) {
                lines.append(.pass("portrait.\(table)", "\(count) rows"))
            } else {
                lines.append(.warn("portrait.\(table)", "table missing"))
            }
        }
        if let row = try? await db.first("SELECT min(seconds_from_1970), max(seconds_from_1970), count(DISTINCT bundle_id) FROM sources WHERE seconds_from_1970 > 0") {
            lines.append(.info("portrait.sources range", "\(range(row[0].unixDate, row[1].unixDate)) · \(row[2].int ?? 0) apps"))
        }
        do {
            let (overview, time) = try await timed { try await PortraitStore.overview() }
            lines.append(.pass("portrait overview (summary section)", "\(overview.topics) topics, \(overview.entities) entities, \(overview.placeRecords) place records, \(overview.handles) handles, \(overview.significant) significant · \(time)"))
            let appTotal = overview.apps.reduce(0) { $0 + $1.documents }
            lines.append(.check("portrait per-app documents add up", appTotal == overview.sources, "\(appTotal) vs \(overview.sources) sources"))
            let monthTotal = Int(overview.monthly.reduce(0) { $0 + $1.value })
            lines.append(.check("portrait monthly histogram adds up", monthTotal <= overview.sources && monthTotal > 0 || overview.sources == 0, "\(monthTotal) of \(overview.sources) dated"))

            let (topics, topicTime) = try await timed { try await PortraitStore.topics(offset: 0, limit: 200, sort: nil, search: "") }
            let topicCount = try await PortraitStore.topicCount(search: "")
            lines.append(.check("topics first page", topicCount == overview.topics && !topics.isEmpty || overview.topics == 0, "\(topics.count) of \(topicCount) topics · \(topicTime)"))
            let topicRecords = try await PortraitStore.topics(offset: 0, limit: 100_000, sort: nil, search: "").reduce(0) { $0 + $1.records }
            lines.append(.check("topic extractions add up", topicRecords == overview.topicRecords, "\(topicRecords) vs \(overview.topicRecords) tp_records"))
            let catalog = await PortraitStore.catalog()
            let all = try await PortraitStore.topics(offset: 0, limit: 100_000, sort: nil, search: "")
            let named = all.filter { $0.name != nil }
            var origins: [String: Int] = [:]
            for topic in named { origins[String((topic.nameOrigin ?? "?").split(separator: "·").first ?? "?").trimmingCharacters(in: .whitespaces), default: 0] += 1 }
            let unnamed = all.count - named.count
            let detail = "\(named.count) of \(all.count) of your topics named (" + origins.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
                + "), \(unnamed) unnamed (\(all.filter { $0.name == nil && $0.context != nil }.count) with “seen with” context) · \(catalog.cached.count) cached scores, vocabulary table \(TopicVocabulary.labels.count) labels"
            lines.append(unnamed * 2 > all.count ? .warn("topic names", detail) : .pass("topic names", detail))
            let namedCount = try await PortraitStore.topicCount(search: "", namedOnly: true)
            lines.append(.check("“Named only” filter matches", namedCount == named.count && overview.topicsNamed == named.count, "\(namedCount) vs \(named.count)"))
            if let person = overview.topPerson {
                lines.append(.info("headline person", person.matchesContact ? "top Person entity that matches a known contact name (\(person.mentions) mentions)" : "no Person entity matches a known contact name; phrased as “name (as classified by the system)”"))
            }

            let (entities, entityTime) = try await timed { try await PortraitStore.entities(offset: 0, limit: 200, sort: nil, search: "", category: nil, bundle: nil) }
            let entityCount = try await PortraitStore.entityCount(search: "", category: nil, bundle: nil)
            lines.append(.check("entities first page", entityCount == overview.entities, "\(entities.count) of \(entityCount) entities · \(entityTime)"))
            let categories = try await PortraitStore.entityCategories()
            lines.append(.info("entity categories", categories.map { "\(PortraitLabels.entityCategory($0.category)) \($0.distinct)" }.joined(separator: ", ")))
            if let first = entities.first {
                let (documents, docTime) = try await timed { try await PortraitStore.entityDocuments(key: first.key, category: first.category, limit: 100_000) }
                lines.append(.check("entity detail matches aggregate", documents.count == first.mentions, "\(documents.count) documents vs \(first.mentions) mentions · \(docTime)"))
            }

            let (places, placeTime) = try await timed { try await PortraitStore.places(offset: 0, limit: 200, sort: nil, search: "", origin: .all) }
            let placeCount = try await PortraitStore.placeCount(search: "", origin: .all)
            let allPlaces = try await PortraitStore.places(offset: 0, limit: 100_000, sort: nil, search: "", origin: .all)
            lines.append(.check("places", allPlaces.count == placeCount && allPlaces.reduce(0) { $0 + $1.records } == overview.placeRecords,
                                "\(places.count) of \(placeCount) places, \(allPlaces.filter(\.hasCoordinate).count) with coordinates · \(placeTime)"))
            var byOrigin: [String] = []
            var originTotal = 0
            for origin in PlaceOrigin.allCases where origin != .all {
                let rows = try await PortraitStore.places(offset: 0, limit: 100_000, sort: nil, search: "", origin: origin)
                let records = rows.reduce(0) { $0 + $1.records }
                originTotal += records
                byOrigin.append("\(origin.rawValue) \(records)")
            }
            lines.append(.check("place origins partition the records", originTotal == overview.placeRecords, byOrigin.joined(separator: ", ")))

            let (handles, handleTime) = try await timed { try await PortraitStore.handles(offset: 0, limit: 200, sort: nil, search: "") }
            let significant = try await PortraitStore.significantContacts()
            lines.append(.check("handles", try await PortraitStore.handleCount(search: "") == overview.handles,
                                "\(handles.count) on first page, \(significant.count) significant (\(significant.filter { $0.documents > 0 }.count) also in handle table) · \(handleTime)"))
        } catch {
            lines.append(.fail("portrait queries", error.localizedDescription))
        }
        switch Paths.probe(ProfilePaths.familyCircleCache) {
        case .missing: lines.append(.warn("DuetExpertCenter/caches/familyCircleCache", "not present on this Mac (no Family Sharing group)"))
        case .inaccessible(let reason): lines.append(.warn("DuetExpertCenter/caches/familyCircleCache", "no access: \(reason)"))
        case .available:
            do {
                let circle = try FamilyStore.load()
                let joined = circle.members.compactMap(\.joined)
                lines.append(.check("family circle cache", !circle.members.isEmpty,
                                    "\(circle.members.count) members (\(circle.members.filter(\.pending).count) pending, \(circle.members.filter { !$0.appleID.isEmpty }.count) with Apple ID, \(circle.members.filter { $0.birth != nil }.count) with date of birth, \(circle.members.filter(\.isMe).count) is-me, \(circle.members.filter(\.isOrganizer).count) organizer), joined \(range(joined.min(), joined.max()))"))
            } catch {
                lines.append(.fail("family circle cache", error.localizedDescription))
            }
        }
        lines.append(.info("me card", "\(PortraitStore.meCard().count) fields, \(PortraitStore.nameRecords().count) name records"))
        do {
            let (highlights, time) = try await timed { try PortraitStore.socialHighlights() }
            lines.append(.info("rankedSocialHighlights", "\(highlights.count) distinct links from \(highlights.reduce(0) { $0 + $1.appearances }) records, \(range(highlights.map(\.date).min(), highlights.map(\.date).max())) · \(time)"))
        } catch {
            lines.append(.warn("rankedSocialHighlights", error.localizedDescription))
        }
        let firstParty = await FirstPartyTopicStore.load()
        lines.append(.info("firstPartyTopics", firstParty.stores.isEmpty ? "no stores" : firstParty.stores.map { "\($0.name): \($0.rows)" }.joined(separator: ", ")))
        return lines
    }

    // MARK: Suggestions

    private static func suggestions() async -> [SelfTestLine] {
        var lines = [availability("Suggestions/entities.db", ProfilePaths.suggestionsDB), availability("Suggestions/snippets.db", ProfilePaths.snippetsDB)]
        do {
            let (counts, time) = try await timed { try await SuggestionsStore.counts() }
            lines.append(.pass("suggestions counts", "\(counts.contacts) pseudo-contacts, \(counts.events) events, \(counts.passes) wallet passes, \(counts.urls) urls (\(counts.secretURLs) with token-like parameters), \(counts.emails) e-mails, \(counts.mailSnippets) mail + \(counts.entitySnippets) entity snippets · \(time)"))
            lines.append(.info("suggestions entity range", range(counts.timeRange?.lowerBound, counts.timeRange?.upperBound)))

            let (contacts, contactTime) = try await timed { try await SuggestionsStore.contacts(offset: 0, limit: 100_000, sort: nil, search: "") }
            lines.append(.check("pseudo-contacts page", contacts.count == counts.contacts, "\(contacts.count) rows, \(contacts.reduce(0) { $0 + $1.detailCount }) details · \(contactTime)"))
            let (events, eventTime) = try await timed { try await SuggestionsStore.events(offset: 0, limit: 100_000, sort: nil, search: "") }
            lines.append(.check("events page", events.count == counts.events, "\(events.count) rows, \(events.filter(\.cancelled).count) cancelled, \(range(events.compactMap(\.start).min(), events.compactMap(\.start).max())) · \(eventTime)"))
            var schema = 0, located = 0
            for event in events.prefix(200) {
                let detail = try await SuggestionsStore.eventDetail(event)
                schema += detail.schemaItems.count
                located += detail.locations.count
            }
            lines.append(.info("event details", "\(schema) schema.org records, \(located) locations"))

            let (passes, passTime) = try await timed { try await SuggestionsStore.passes(offset: 0, limit: 100_000, sort: nil, search: "") }
            lines.append(.check("wallet passes page", passes.count == counts.passes, "\(passes.count) rows · \(passTime)"))
            var parsed = 0, fields = 0, barcodes = 0, styles: [String: Int] = [:]
            let passStart = Date()
            for pass in passes.prefix(100) {
                if let detail = try? await SuggestionsStore.passDetail(pass) {
                    parsed += 1
                    fields += detail.groups.reduce(0) { $0 + $1.fields.count }
                    barcodes += detail.barcodes.count
                    styles[detail.style, default: 0] += 1
                }
            }
            let checked = min(passes.count, 100)
            lines.append(.check("pkpass archives unzip and parse", parsed == checked, "\(parsed)/\(checked) parsed, \(fields) fields, \(barcodes) barcodes, styles: \(styles.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ")) · \(String(format: "%.0f ms", Date().timeIntervalSince(passStart) * 1000))"))

            let urls = try await SuggestionsStore.urls(offset: 0, limit: 100_000, sort: nil, search: "")
            lines.append(.check("urls page", urls.count == counts.urls && urls.filter { !$0.secrets.isEmpty }.count == counts.secretURLs,
                                "\(urls.count) rows, \(urls.filter { !$0.secrets.isEmpty }.count) flagged, \(range(urls.compactMap(\.date).min(), urls.compactMap(\.date).max()))"))
            let snippetCount = try await SuggestionsStore.snippetCount(search: "")
            lines.append(.check("snippets", snippetCount == counts.mailSnippets + counts.entitySnippets, "\(snippetCount) rows"))
            let own = try await SuggestionsStore.ownAddresses()
            lines.append(.info("own sender addresses", "\(own.count) addresses, \(own.reduce(0) { $0 + $1.messages }) sent messages"))
        } catch {
            lines.append(.warn("suggestions queries", error.localizedDescription))
        }
        let names = SuggestionsStore.learnedNames()
        lines.append(.info("name caches", "\(names.filter { $0.source == "E-mail" }.count) e-mail, \(names.filter { $0.source == "Phone" }.count) phone"))
        return lines
    }

    // MARK: Vocabulary

    private static func vocabulary() async -> [SelfTestLine] {
        var lines = [availability("Assistant (speech profile)", Paths.assistant)]
        do {
            let (speech, time) = try await timed { try SpeechVocabulary.load() }
            lines.append(.pass("speech profile", "\(speech.words.count) distinct tagged words in \(speech.locales.count) profiles (\(speech.locales.joined(separator: ", "))), \(Format.bytes(speech.profileBytes)) · \(time)"))
            for (locale, url) in SpeechVocabulary.profileFiles() {
                let symbols = SpeechVocabulary.scan(url)
                var counts: [String: Int] = [:]
                for symbol in symbols { counts[symbol.category, default: 0] += 1 }
                let top = counts.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                lines.append(.info("speech profile \(locale)", "\(symbols.count) symbols: \(top)"))
            }
        } catch {
            lines.append(.warn("speech profile", error.localizedDescription))
        }
        let phrases = await CustomVocabulary.all()
        var kinds: [String: Int] = [:]
        for phrase in phrases { kinds[phrase.kind, default: 0] += 1 }
        lines.append(.info("custom vocabulary", kinds.isEmpty ? "none" : kinds.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ")))

        lines.append(availability("LanguageModeling (keyboard lexicons)", ProfilePaths.languageModeling))
        var mismatches: [String] = []
        var summary: [String] = []
        let lexiconStart = Date()
        for (language, url) in KeyboardLexicon.lexiconFiles() {
            guard let parsed = KeyboardLexicon.parse(url, language: language) else { mismatches.append(language + " (unreadable)"); continue }
            if parsed.words.isEmpty && parsed.declared == 0 { continue }
            if parsed.words.count != parsed.declared || !parsed.complete { mismatches.append("\(language) parsed \(parsed.words.count) declared \(parsed.declared)") }
            let dates = parsed.words.compactMap(\.date)
            summary.append("\(language) \(parsed.words.count) (\(parsed.words.filter(\.learned).count) learned, \(range(dates.min(), dates.max())))")
        }
        let lexiconTime = String(format: "%.0f ms", Date().timeIntervalSince(lexiconStart) * 1000)
        if summary.isEmpty {
            lines.append(.info("keyboard lexicons", "no dynamic lexicon files"))
        } else {
            lines.append(.check("keyboard lexicons parse completely", mismatches.isEmpty, (mismatches.isEmpty ? summary : mismatches).joined(separator: "; ") + " · " + lexiconTime))
        }

        lines.append(availability("Trial/triald.db", ProfilePaths.trialDB))
        if let assignments = try? await TrialStore.assignments() {
            let experiments = assignments.filter { $0.kind == "Experiment" }
            lines.append(.pass("trial assignments", "\(experiments.count) experiments, \(assignments.count - experiments.count) rollouts, \(range(assignments.compactMap(\.start).min(), assignments.compactMap(\.start).max()))"))
        }
        return lines
    }

    private static func identifiers() async -> [SelfTestLine] {
        let (rows, time) = await timed { await IdentifierStore.load() }
        var groups: [String: Int] = [:]
        for row in rows { groups[row.group + " / " + row.name, default: 0] += 1 }
        let siri = rows.filter { $0.group == "Siri Analytics" }
        var lines: [SelfTestLine] = [
            .info("identifiers", "\(rows.count) rows · \(time)"),
            .info("siri analytics identifiers", siri.isEmpty ? "none" : "\(siri.count) records, \(Set(siri.map(\.value)).count) distinct ids, \(range(siri.compactMap(\.recorded).min(), siri.compactMap(\.recorded).max()))"),
        ]
        for (key, count) in groups.sorted(by: { $0.key < $1.key }) { lines.append(.info("  " + key, "\(count)")) }
        lines.append(.info("siri segment store", IdentifierStore.segmentRecords().map { "\($0) records" } ?? "stream not present"))
        return lines
    }

    // MARK: Decoder self-checks (synthetic data, no personal content)

    private static func decoders() -> [SelfTestLine] {
        var lines: [SelfTestLine] = []
        // ZIP: a stored entry built in memory must round-trip.
        let payload = Data("{\"description\":\"test\",\"organizationName\":\"Org\",\"generic\":{\"primaryFields\":[{\"key\":\"k\",\"label\":\"L\",\"value\":\"V\"}]}}".utf8)
        let name = Data("pass.json".utf8)
        var zip = Data()
        func put16(_ values: Int...) { for v in values { zip.append(UInt8(v & 0xff)); zip.append(UInt8((v >> 8) & 0xff)) } }
        func put32(_ values: Int...) { for v in values { put16(v & 0xffff, (v >> 16) & 0xffff) } }
        // Local file header.
        put32(0x04034b50); put16(20, 0, 0, 0, 0); put32(0, payload.count, payload.count); put16(name.count, 0)
        zip.append(name); zip.append(payload)
        let central = zip.count
        // Central directory entry.
        put32(0x02014b50); put16(20, 20, 0, 0, 0, 0); put32(0, payload.count, payload.count)
        put16(name.count, 0, 0, 0, 0); put32(0, 0)
        zip.append(name)
        let centralSize = zip.count - central
        // End of central directory.
        put32(0x06054b50); put16(0, 0, 1, 1); put32(centralSize, central); put16(0)
        let detail = try? SuggestionsStore.parsePass(zip)
        lines.append(.check("zip + pass.json decoder (synthetic)", detail?.style == "Generic Pass" && detail?.groups.first?.fields.first?.value == "V" && detail?.organization == "Org"))

        let flagged = ProfileFormat.secretParameters(in: "https://example.com/join?meeting=1&pwd=abcdef&utm_source=x#access_token=123456")
        lines.append(.check("token-like URL parameter detection", flagged == ["pwd", "access_token"] && ProfileFormat.secretParameters(in: "https://example.com/?q=test&page=2").isEmpty, flagged.joined(separator: ", ")))
        lines.append(.check("wikidata link only for valid ids", ProfileFormat.wikidataURL("Q42") != nil && ProfileFormat.wikidataURL("Q42/../x") == nil))

        // Family circle: a synthetic archive-shaped tree (already resolved) must parse.
        let member: PlistValue = .dict([
            (key: "member-first-name", value: .string("Test")), (key: "member-last-name", value: .string("Member")),
            (key: "member-apple-id", value: .string("member@example.com")), (key: "member-date-of-birth", value: .int(-86_400_000)),
            (key: "member-join-date-epoch", value: .int(1_600_000_000_000)), (key: "member-is-organizer", value: .bool(true)),
            (key: "is-me", value: .bool(true)), (key: "member-type", value: .string("ADULT")),
        ])
        let circle = FamilyStore.parse(.dict([(key: "_members", value: .array([.dict([(key: "$class", value: .string("FAFamilyMember")), (key: "_dictionary", value: member)])]))]))
        let parsed = circle.members.first
        lines.append(.check("family circle decoder (synthetic)", circle.members.count == 1 && parsed?.name == "Test Member" && parsed?.role == "Organizer" && parsed?.isMe == true
                            && parsed?.birth == Date(timeIntervalSince1970: -86_400) && parsed?.joined == Date(timeIntervalSince1970: 1_600_000_000)))
        lines.append(.check("topic vocabulary table", TopicVocabulary.labels.count > 700 && TopicVocabulary.labels["Q2"] == "Earth"))
        return lines
    }
}
