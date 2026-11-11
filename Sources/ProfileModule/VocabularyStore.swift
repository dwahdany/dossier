import Foundation
import DossierCore

// MARK: - Models

struct SpeechWord: Identifiable, Sendable, Hashable {
    var id: String { category + "|" + word }
    let word: String
    let category: String
    let locales: String
    var categoryTitle: String { SpeechVocabulary.title(category) }
}

struct SpeechCategory: Identifiable, Sendable, Hashable {
    var id: String { category }
    let category: String
    let count: Int
    var title: String { SpeechVocabulary.title(category) }
    var personal: Bool { SpeechVocabulary.isPersonal(category) }
}

struct SpeechVocabularyData: Sendable {
    var words: [SpeechWord] = []
    var categories: [SpeechCategory] = []
    var locales: [String] = []
    var profileBytes: Int64 = 0
    var modified: Date?
}

struct CustomPhrase: Identifiable, Sendable, Hashable {
    let id: String
    let kind: String
    let app: String
    let slot: String
    let text: String
    let extra: String
    let date: Date?
}

struct LexiconWord: Identifiable, Sendable, Hashable {
    var id: String { language + "|" + word }
    let word: String
    let language: String
    let count: Int
    let learned: Bool
    let date: Date?
}

struct LexiconLanguage: Identifiable, Sendable, Hashable {
    var id: String { language }
    let language: String
    let words: Int
    let learned: Int
    let tokensTyped: Int?
    let modified: Date?
    var title: String { ProfileFormat.language(language) }
}

struct KeyboardData: Sendable {
    var words: [LexiconWord] = []
    var languages: [LexiconLanguage] = []
    var spellingCounts: [(String, Int)] = []
}

struct IdentifierRow: Identifiable, Sendable, Hashable {
    let id: String
    let group: String
    let name: String
    let value: String
    let device: String
    let effective: Date?
    let validityDays: Int?
    let created: Date?
    let retired: Date?
    let recorded: Date?
    let sensitive: Bool
}

struct TrialAssignment: Identifiable, Sendable, Hashable {
    let id: String
    let kind: String
    let identifier: String
    let namespaces: String
    let project: String
    let status: Int
    let treatment: String
    let deployment: Int
    let start: Date?
    let end: Date?
}

struct TrialEvent: Identifiable, Sendable, Hashable {
    let id: Int64
    let date: Date?
    let type: Int
    let detail: String
}

struct FirstPartyTopic: Identifiable, Sendable, Hashable {
    var id: String { store + "|" + topic }
    let store: String
    let topic: String
    let score: Double
    let document: String
}

struct FirstPartyTopics: Sendable {
    var stores: [(name: String, rows: Int)] = []
    var topics: [FirstPartyTopic] = []
}

// MARK: - Speech vocabulary

/// Siri's speech personalization profile (`~/Library/Assistant/SiriVocabulary/…/SpeechProfile`).
///
/// The file is a binary "Bqsr" container. It embeds a symbol table whose entries are
/// `u32 length | "<word>\<class>" | u64 id`, e.g. a contact's first name tagged
/// `\contact-first` or an installed app tagged `\app-first`. The reader scans for those
/// entries (the file is memory-mapped) instead of decoding the full container.
enum SpeechVocabulary {
    private static let titles: [String: String] = [
        "app-first": "App Names", "contact-first": "Contact First Names", "contact-last": "Contact Last Names",
        "contact-first-derived": "First Names (derived forms)", "contact-last-derived": "Last Names (derived forms)",
        "company-first": "Companies", "device-first": "Home Accessories", "house-first": "Homes",
        "room-first": "Rooms", "scene-first": "Scenes", "zone-first": "Zones", "voice-profile": "Voice Profile Entities",
    ]

    static func title(_ category: String) -> String {
        if let known = titles[category] { return known }
        return category.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Classes filled from the owner's data (contacts, apps, home) as opposed to generic
    /// grammar tokens (letters, punctuation names) every profile contains.
    static func isPersonal(_ category: String) -> Bool {
        category.hasSuffix("-first") || category.hasSuffix("-last") || category.hasSuffix("-derived") || category == "voice-profile"
    }

    static func profileFiles() -> [(locale: String, url: URL)] {
        let fm = FileManager.default
        var out: [(String, URL)] = []
        guard let users = try? fm.contentsOfDirectory(at: ProfilePaths.speechProfiles, includingPropertiesForKeys: nil) else { return [] }
        for user in users where (FileProbe.info(user)?.isDirectory ?? false) {
            guard let locales = try? fm.contentsOfDirectory(at: user, includingPropertiesForKeys: nil) else { continue }
            for locale in locales {
                let file = locale.appendingPathComponent("SpeechProfile")
                if fm.fileExists(atPath: file.path) { out.append((locale.lastPathComponent, file)) }
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Tagged symbols of one profile file: (word, class).
    static func scan(_ url: URL, limit: Int = 500_000) -> [(word: String, category: String)] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 16, data.count < 1 << 30 else { return [] }
        var out: [(String, String)] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var p = 0
            while p + 12 < n {
                // A plausible length word: 1…255, upper three bytes zero.
                if base[p] != 0, base[p + 1] == 0, base[p + 2] == 0, base[p + 3] == 0 {
                    let length = Int(base[p])
                    let start = p + 4, end = start + length
                    if end + 8 <= n, base[end + 4] == 0, base[end + 5] == 0, base[end + 6] == 0, base[end + 7] == 0 {
                        var slash = -1
                        var printable = true
                        for i in start..<end {
                            let c = base[i]
                            if c < 0x20 { printable = false; break }
                            if c == 0x5c { slash = i }
                        }
                        if printable, slash > start, slash < end - 1,
                           let word = String(bytes: UnsafeBufferPointer(start: base + start, count: slash - start), encoding: .utf8),
                           let category = String(bytes: UnsafeBufferPointer(start: base + slash + 1, count: end - slash - 1), encoding: .utf8),
                           category.allSatisfy({ $0.isLetter || $0 == "-" || $0.isNumber }) {
                            out.append((word.replacingOccurrences(of: "_", with: " "), category))
                            p = end + 8
                            if out.count >= limit { return }
                            continue
                        }
                    }
                }
                p += 1
            }
        }
        return out
    }

    static func load() throws -> SpeechVocabularyData {
        switch Paths.probe(Paths.assistant) {
        case .missing: throw DossierError.missing("~/Library/Assistant does not exist on this Mac.")
        case .inaccessible(let reason): throw DossierError.inaccessible(reason)
        case .available: break
        }
        var data = SpeechVocabularyData()
        var merged: [String: (word: String, category: String, locales: Set<String>)] = [:]
        for (locale, url) in profileFiles() {
            if Task.isCancelled { break }
            data.locales.append(locale)
            if let info = FileProbe.info(url) {
                data.profileBytes += info.size
                if let modified = info.modified { data.modified = max(data.modified ?? modified, modified) }
            }
            for (word, category) in scan(url) {
                let key = category + "|" + word
                merged[key, default: (word, category, [])].locales.insert(locale)
            }
        }
        // Words the speech recognizer keeps an acoustic embedding for (JSON, keys only).
        if let json = try? Data(contentsOf: ProfilePaths.speechEntityProfile), json.count < 64 << 20,
           let root = PlistDecoder.decodeJSON(json), let entities = root["entityToEmbedding"]?.dict {
            for pair in entities.prefix(100_000) {
                merged["voice-profile|" + pair.key, default: (pair.key, "voice-profile", [])].locales.insert("all")
            }
        }
        data.words = merged.values.map { SpeechWord(word: $0.word, category: $0.category, locales: $0.locales.sorted().joined(separator: ", ")) }
            .sorted { (isPersonal($0.category) ? 0 : 1, $0.category, $0.word.lowercased()) < (isPersonal($1.category) ? 0 : 1, $1.category, $1.word.lowercased()) }
        var counts: [String: Int] = [:]
        for word in data.words { counts[word.category, default: 0] += 1 }
        data.categories = counts.map { SpeechCategory(category: $0.key, count: $0.value) }.sorted { ($0.personal ? 0 : 1, -$0.count, $0.category) < ($1.personal ? 0 : 1, -$1.count, $1.category) }
        return data
    }
}

// MARK: - Custom vocabulary, shortcuts, text replacements

enum CustomVocabulary {
    /// `~/Library/Assistant/CustomVocabulary/<app>/<user>/<slot>/LatestVocabulary.plist`:
    /// phrases apps registered with Siri (shortcut names, chat group names, …).
    static func phrases() -> [CustomPhrase] {
        let fm = FileManager.default
        var out: [CustomPhrase] = []
        guard let enumerator = fm.enumerator(at: ProfilePaths.customVocabulary, includingPropertiesForKeys: nil) else { return [] }
        for case let url as URL in enumerator where url.lastPathComponent == "LatestVocabulary.plist" {
            guard let data = try? Data(contentsOf: url), data.count < 32 << 20, let plist = PlistDecoder.decodePlist(data) else { continue }
            let app = plist["appBundleID"]?.string ?? url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            let slot = plist["intentSlot"]?.string ?? url.deletingLastPathComponent().lastPathComponent
            let modified = FileProbe.info(url)?.modified
            for (index, item) in (plist["vocabularyItems"]?.array ?? []).enumerated() {
                guard let text = item["string"]?.string, !text.isEmpty else { continue }
                out.append(CustomPhrase(id: "\(app)|\(slot)|\(index)", kind: slotTitle(slot), app: app, slot: slot, text: text, extra: "", date: modified))
                if out.count >= 100_000 { return out }
            }
        }
        return out
    }

    static func slotTitle(_ slot: String) -> String {
        switch slot {
        case "VoiceCommandNameType": return "Shortcut Name"
        case "ContactGroupNameType": return "Chat Group Name"
        default: return JSONFlattener.readable(slot.replacingOccurrences(of: "Type", with: ""))
        }
    }

    /// User-defined keyboard text replacements (`~/Library/KeyboardServices/TextReplacements.db`).
    static func textReplacements() async -> [CustomPhrase] {
        guard let db = await SQLiteDB.sharedIfAvailable(ProfilePaths.textReplacements),
              await db.hasColumns("ZTEXTREPLACEMENTENTRY", ["Z_PK", "ZSHORTCUT", "ZPHRASE"]) else { return [] }
        let cols = await db.columnSet(of: "ZTEXTREPLACEMENTENTRY")
        let deleted = cols.contains("ZWASDELETED") ? "coalesce(ZWASDELETED, 0)" : "0"
        let stamp = cols.contains("ZTIMESTAMP") ? "ZTIMESTAMP" : "NULL"
        let rows = (try? await db.rows("SELECT Z_PK, ZSHORTCUT, ZPHRASE, \(stamp), \(deleted) FROM ZTEXTREPLACEMENTENTRY ORDER BY Z_PK LIMIT 50000")) ?? []
        return rows.map {
            CustomPhrase(id: "replacement|\($0[0].int ?? 0)", kind: "Text Replacement", app: "com.apple.keyboard", slot: "TextReplacement",
                         text: $0[2].string ?? "", extra: ($0[1].string ?? "") + (($0[4].int ?? 0) != 0 ? "  (deleted)" : ""), date: $0[3].cocoaDate)
        }
    }

    static func all() async -> [CustomPhrase] {
        phrases() + (await textReplacements())
    }
}

// MARK: - Keyboard lexicon

/// Learned typing vocabulary: `~/Library/LanguageModeling/<lang>-dynamic.lm/dynamic-lexicon.dat`.
///
/// Layout observed (`DynamicDictionary-9`): ASCII magic + NUL, big-endian `u32` word count,
/// then per word: token id, usage count (both variable length: 1 byte < 0x80, 2 bytes
/// < 0xC0, else 4 bytes), 3 reserved bytes, a big-endian `float32` Cocoa timestamp
/// (0 for words of the static vocabulary) and the NUL-terminated UTF-8 word. Token ids
/// ≥ 0xC00000 are words that are *not* in the built-in vocabulary — genuinely learned.
enum KeyboardLexicon {
    static func lexiconFiles() -> [(language: String, url: URL)] {
        let fm = FileManager.default
        guard let bundles = try? fm.contentsOfDirectory(at: ProfilePaths.languageModeling, includingPropertiesForKeys: nil) else { return [] }
        return bundles.compactMap { bundle in
            let name = bundle.lastPathComponent
            guard name.hasSuffix("-dynamic.lm") else { return nil }
            let file = bundle.appendingPathComponent("dynamic-lexicon.dat")
            guard fm.fileExists(atPath: file.path) else { return nil }
            return (String(name.dropLast("-dynamic.lm".count)), file)
        }.sorted { $0.0 < $1.0 }
    }

    struct Parsed: Sendable {
        var declared = 0
        var words: [LexiconWord] = []
        var complete = false
    }

    static func parse(_ url: URL, language: String, limit: Int = 300_000) -> Parsed? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 256 << 20 else { return nil }
        let magic = Array("DynamicDictionary-".utf8)
        guard data.count > magic.count, data.starts(with: magic) else { return nil }
        var parsed = Parsed()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let b = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var i = magic.count
            while i < n, b[i] != 0 { i += 1 }
            i += 1
            guard i + 4 <= n else { parsed.complete = true; return }
            parsed.declared = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            i += 4
            func varint(_ at: Int) -> (value: Int, size: Int)? {
                guard at < n else { return nil }
                let lead = b[at]
                if lead < 0x80 { return (Int(lead), 1) }
                if lead < 0xc0 { return at + 1 < n ? ((Int(lead & 0x3f) << 8) | Int(b[at + 1]), 2) : nil }
                return at + 3 < n ? (Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3]), 4) : nil
            }
            while i < n, parsed.words.count < limit {
                guard let token = varint(i) else { return }
                i += token.size
                guard let count = varint(i) else { return }
                i += count.size
                guard i + 7 <= n else { return }
                let bits = UInt32(b[i + 3]) << 24 | UInt32(b[i + 4]) << 16 | UInt32(b[i + 5]) << 8 | UInt32(b[i + 6])
                i += 7
                var end = i
                while end < n, b[end] != 0 { end += 1 }
                guard end < n, end > i, end - i < 512,
                      let word = String(bytes: UnsafeBufferPointer(start: b + i, count: end - i), encoding: .utf8) else { return }
                i = end + 1
                let seconds = Double(Float(bitPattern: bits))
                let date = bits != 0 && seconds.isFinite && seconds > 3e8 && seconds < 2e9 ? DossierDate.cocoa(seconds) : nil
                // 4-byte token ids whose second byte is ≥ 0xC0 lie outside the static vocabulary.
                let learned = token.size == 4 && token.value >= 0xC0_0000
                parsed.words.append(LexiconWord(word: word, language: language, count: count.value, learned: learned, date: date))
            }
            parsed.complete = i >= n
        }
        return parsed
    }

    static func load() throws -> KeyboardData {
        switch Paths.probe(ProfilePaths.languageModeling) {
        case .missing: throw DossierError.missing("~/Library/LanguageModeling does not exist on this Mac.")
        case .inaccessible(let reason): throw DossierError.inaccessible(reason)
        case .available: break
        }
        var data = KeyboardData()
        for (language, url) in lexiconFiles() {
            if Task.isCancelled { break }
            guard let parsed = parse(url, language: language), !parsed.words.isEmpty else { continue }
            data.words += parsed.words
            var typed: Int?
            let meta = url.deletingLastPathComponent().appendingPathComponent("meta.dat")
            if let raw = try? Data(contentsOf: meta), raw.count < 1 << 20, let plist = PlistDecoder.decodePlist(raw) {
                typed = plist["numberOfTokensTyped"]?.int.map(Int.init)
            }
            data.languages.append(LexiconLanguage(language: language, words: parsed.words.count, learned: parsed.words.filter(\.learned).count,
                                                  tokensTyped: typed, modified: FileProbe.info(url)?.modified))
        }
        data.languages.sort { $0.words > $1.words }
        if let raw = try? Data(contentsOf: ProfilePaths.spellingCounts), raw.count < 1 << 20, let plist = PlistDecoder.decodePlist(raw) {
            data.spellingCounts = (plist.dict ?? []).compactMap { pair in pair.value.int.map { (pair.key, Int($0)) } }
        }
        return data
    }
}

// MARK: - Identifiers

/// Rotating analytics identifiers Siri keeps in Biome (`Siri.AnalyticsIdentifiers.*`).
/// Record fields observed: 1 = 16-byte UUID, 2 = effective-from (Unix seconds),
/// 3 = validity in days, 4 = created, 5 = retired / replaced at, 6 = retired flag.
enum IdentifierStore {
    static func streamTitle(_ stream: String) -> String {
        JSONFlattener.readable(stream.split(separator: ".").last.map(String.init) ?? stream)
    }

    static func load() async -> [IdentifierRow] {
        var rows: [IdentifierRow] = []
        let peers = await Biome.devicePeers()
        for name in ProfilePaths.identifierStreams {
            guard let stream = Biome.stream(named: name) else { continue }
            BiomeStreamReader(stream).forEachMessage(device: nil, order: .newestFirst) { record, message in
                let uuid: String
                if let bytes = message[1]?.data, bytes.count == 16 {
                    uuid = bytes.withUnsafeBytes { NSUUID(uuidBytes: $0.bindMemory(to: UInt8.self).baseAddress).uuidString }
                } else {
                    uuid = message[1]?.string ?? "—"
                }
                let device: String
                switch record.device {
                case .local: device = "This Mac"
                case .remote(let id): device = peers[id]?.displayName ?? "Other device"
                }
                rows.append(IdentifierRow(
                    id: name + "|" + record.id, group: "Siri Analytics", name: streamTitle(name), value: uuid, device: device,
                    effective: message[2]?.double.flatMap { $0 > 0 ? DossierDate.unix($0) : nil },
                    validityDays: message[3]?.int.map(Int.init),
                    created: message[4]?.double.flatMap { $0 > 0 ? DossierDate.unix($0) : nil },
                    retired: message[5]?.double.flatMap { $0 > 0 ? DossierDate.unix($0) : nil },
                    recorded: record.timestamp, sensitive: true))
                return rows.count < 20_000
            }
        }
        rows += await trialKeyValues()
        rows += siriSharingHistory()
        return rows
    }

    /// Stats of the Siri user-segment stream (cohort assignments); usually empty on a Mac.
    static func segmentRecords() -> Int? {
        guard let stream = Biome.stream(named: ProfilePaths.segmentStream) else { return nil }
        return BiomeStreamReader(stream).stats().records
    }

    /// Persisted Trial targeting values (`kvstore`), e.g. the Maps bucket id used to assign
    /// experiments; values are small NSKeyedArchiver blobs.
    private static func trialKeyValues() async -> [IdentifierRow] {
        guard let db = await SQLiteDB.sharedIfAvailable(ProfilePaths.trialDB), await db.hasColumns("kvstore", ["key", "bytes"]) else { return [] }
        let rows = (try? await db.query("SELECT key, bytes FROM kvstore WHERE key LIKE '%persisted%' OR key LIKE '%optout%' LIMIT 200", cellByteLimit: 16_384).rows) ?? []
        return rows.compactMap { row in
            guard let key = row[0].string else { return nil }
            var value = "—"
            if let data = row[1].data {
                if let decoded = PlistDecoder.decodeAny(data) {
                    value = decoded.string ?? decoded.int.map(String.init) ?? decoded.double.map { String($0) } ?? decoded.bool.map { $0 ? "true" : "false" } ?? PlistDecoder.describe(decoded)
                } else if data.count <= 8 {
                    value = data.map { String($0) }.joined(separator: " ")
                } else {
                    value = "\(data.count) bytes"
                }
            }
            let short = key.replacingOccurrences(of: "com.apple.triald.", with: "")
            return IdentifierRow(id: "trial|" + key, group: "Trial Targeting", name: short, value: Format.oneLine(value, max: 200), device: "This Mac",
                                 effective: nil, validityDays: nil, created: nil, retired: nil, recorded: nil, sensitive: false)
        }
    }

    /// History of the "Improve Siri & Dictation" opt-in state from the Siri preferences.
    private static func siriSharingHistory() -> [IdentifierRow] {
        guard let data = try? Data(contentsOf: ProfilePaths.assistantBackedUpPrefs), data.count < 8 << 20,
              let plist = PlistDecoder.decodePlist(data),
              let history = plist["Siri Data Sharing Opt-In Status History"]?.array else { return [] }
        return history.enumerated().map { index, entry in
            let status = entry["New Opt-In Status"]?.string ?? "—"
            let previous = entry["Previous Opt-In Status"]?.string
            let reason = entry["Reason"]?.string
            let value = status + (previous.map { "  (was \($0))" } ?? "") + (reason.map { " — \($0)" } ?? "")
            return IdentifierRow(id: "sharing|\(index)", group: "Siri Data Sharing", name: "Opt-in status change", value: value, device: "This Mac",
                                 effective: entry["Date"]?.date, validityDays: nil, created: nil, retired: nil, recorded: entry["Date"]?.date, sensitive: false)
        }
    }
}

// MARK: - Trial experiments

/// `~/Library/Trial/v7/Database/triald.db`: A/B experiments and feature rollouts this Mac
/// was enrolled in by Apple's Trial system.
enum TrialStore {
    static func assignments() async throws -> [TrialAssignment] {
        switch Paths.probe(ProfilePaths.trialDB) {
        case .missing: throw DossierError.missing("No Trial database (triald.db) on this Mac.")
        case .inaccessible(let reason): throw DossierError.inaccessible(reason)
        case .available: break
        }
        guard let db = await SQLiteDB.sharedIfAvailable(ProfilePaths.trialDB) else { throw DossierError.message("The Trial database could not be opened.") }
        var out: [TrialAssignment] = []
        if await db.hasColumns("experiments", ["rowid", "experimentId", "deploymentId", "status", "startSecondsFromEpoch", "endSecondsFromEpoch", "treatmentId"]) {
            let namespaces = await db.hasColumns("namespaces", ["experiments_rowid", "name"])
                ? "(SELECT group_concat(n.name, ', ') FROM namespaces n WHERE n.experiments_rowid = e.rowid)" : "NULL"
            let artifact = await db.hasColumns("experiments", ["artifact"]) ? "e.artifact" : "NULL"
            let rows = try await db.query("""
                SELECT e.rowid, e.experimentId, e.deploymentId, e.status, e.startSecondsFromEpoch, e.endSecondsFromEpoch, e.treatmentId, \(namespaces), \(artifact)
                FROM experiments e ORDER BY e.startSecondsFromEpoch DESC LIMIT 5000
                """, cellByteLimit: 256 << 10).rows
            for row in rows {
                // Artifact (protobuf): 9 = experiment definition, 9.9 = project name.
                let project = row[8].data.flatMap { ProtoMessage($0) }?[9]?.message?[9]?.string ?? ""
                out.append(TrialAssignment(
                    id: "experiment|\(row[0].int ?? 0)", kind: "Experiment", identifier: row[1].string ?? "", namespaces: row[7].string ?? "",
                    project: project, status: Int(row[3].int ?? 0), treatment: row[6].string ?? "", deployment: Int(row[2].int ?? 0),
                    start: row[4].unixDate, end: row[5].unixDate))
            }
        }
        if await db.hasColumns("rolloutsV2", ["rowid", "rolloutId", "deploymentId", "status"]) {
            let namespaces = await db.hasColumns("rolloutV2Namespaces", ["rolloutsV2_rowid", "name"])
                ? "(SELECT group_concat(n.name, ', ') FROM rolloutV2Namespaces n WHERE n.rolloutsV2_rowid = r.rowid)" : "NULL"
            let cols = await db.columnSet(of: "rolloutsV2")
            let pack = cols.contains("activeFactorPackSetId") ? "r.activeFactorPackSetId" : "NULL"
            let firstSeen = await db.hasColumns("rolloutHistory", ["rolloutId", "eventLogTime"])
                ? "(SELECT min(h.eventLogTime) FROM rolloutHistory h WHERE h.rolloutId = r.rolloutId)" : "NULL"
            let rows = try await db.rows("""
                SELECT r.rowid, r.rolloutId, r.deploymentId, r.status, \(pack), \(namespaces), \(firstSeen) FROM rolloutsV2 r ORDER BY r.rowid LIMIT 5000
                """)
            for row in rows {
                out.append(TrialAssignment(
                    id: "rollout|\(row[0].int ?? 0)", kind: "Rollout", identifier: row[1].string ?? "", namespaces: row[5].string ?? "",
                    project: "", status: Int(row[3].int ?? 0), treatment: row[4].string ?? "", deployment: Int(row[2].int ?? 0),
                    start: row[6].unixDate, end: nil))
            }
        }
        return out
    }

    static func history(_ assignment: TrialAssignment) async -> [TrialEvent] {
        guard let db = await SQLiteDB.sharedIfAvailable(ProfilePaths.trialDB) else { return [] }
        if assignment.kind == "Experiment", await db.hasColumns("experimentHistory", ["rowid", "eventSecondsFromEpoch", "eventType", "experimentId"]) {
            let cols = await db.columnSet(of: "experimentHistory")
            let detail = cols.contains("errorOrDeactivationReason") ? "coalesce(errorOrDeactivationReason, treatmentId, '')" : "''"
            let rows = (try? await db.rows("SELECT rowid, eventSecondsFromEpoch, eventType, \(detail) FROM experimentHistory WHERE experimentId = ? ORDER BY 2 DESC LIMIT 200", [.text(assignment.identifier)])) ?? []
            return rows.map { TrialEvent(id: $0[0].int ?? 0, date: $0[1].unixDate, type: Int($0[2].int ?? 0), detail: $0[3].string ?? "") }
        }
        if assignment.kind == "Rollout", await db.hasColumns("rolloutHistory", ["rowid", "eventLogTime", "eventType", "rolloutId"]) {
            let cols = await db.columnSet(of: "rolloutHistory")
            let detail = cols.contains("factorPackSetId") ? "coalesce(factorPackSetId, '')" : "''"
            let rows = (try? await db.rows("SELECT rowid, eventLogTime, eventType, \(detail) FROM rolloutHistory WHERE rolloutId = ? ORDER BY 2 DESC LIMIT 200", [.text(assignment.identifier)])) ?? []
            return rows.map { TrialEvent(id: $0[0].int ?? 0, date: $0[1].unixDate, type: Int($0[2].int ?? 0), detail: $0[3].string ?? "") }
        }
        return []
    }

    /// What the device reported about itself when an experiment was activated.
    static func activation(_ assignment: TrialAssignment) async -> [(String, String)] {
        guard assignment.kind == "Experiment", let db = await SQLiteDB.sharedIfAvailable(ProfilePaths.trialDB),
              await db.hasColumns("activationEvents", ["experimentId"]) else { return [] }
        let wanted = [("OS build", "osBuild"), ("Language", "languageCode"), ("Region", "regionCode"),
                      ("Diagnostics sharing", "diagnosticsUsageEnabled"), ("Neural Engine", "hasAne"), ("Neural Engine version", "aneVersion")]
        let cols = await db.columnSet(of: "activationEvents")
        let present = wanted.filter { cols.contains($0.1) }
        guard !present.isEmpty,
              let row = try? await db.first("SELECT " + present.map { SQLiteDB.quote($0.1) }.joined(separator: ", ") + " FROM activationEvents WHERE experimentId = ? LIMIT 1", [.text(assignment.identifier)]) else { return [] }
        return present.enumerated().compactMap { index, field in
            let value = row[index]
            if value.isNull { return nil }
            if field.1 == "diagnosticsUsageEnabled" || field.1 == "hasAne" { return (field.0, (value.int ?? 0) != 0 ? "Yes" : "No") }
            return (field.0, value.string ?? value.description)
        }
    }
}

// MARK: - IntelligencePlatform first-party topics

enum FirstPartyTopicStore {
    static func load() async -> FirstPartyTopics {
        var result = FirstPartyTopics()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: ProfilePaths.firstPartyTopics, includingPropertiesForKeys: nil) else { return result }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "db" {
            guard let db = await SQLiteDB.sharedIfAvailable(file), await db.hasColumns("topics", ["topicId", "score"]) else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            let hasDoc = await db.hasColumns("topics", ["most_recent_documentId"])
            let rows = (try? await db.rows("SELECT topicId, score, \(hasDoc ? "most_recent_documentId" : "NULL") FROM topics ORDER BY score DESC LIMIT 5000")) ?? []
            result.stores.append((name, await db.rowCount(of: "topics") ?? rows.count))
            result.topics += rows.map { FirstPartyTopic(store: name, topic: $0[0].string ?? "", score: $0[1].double ?? 0, document: $0[2].string ?? "") }
        }
        return result
    }
}
