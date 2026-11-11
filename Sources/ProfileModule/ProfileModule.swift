import SwiftUI
import DossierCore

/// Interest Profile — what the system infers the owner cares about.
///
/// Sources: PersonalizationPortrait (topics, named entities, locations, contact handles),
/// the cached Family Sharing roster,
/// Suggestions (contacts, events, Wallet passes and links found in mail), the Siri speech
/// profile and custom vocabulary, the keyboard's learned lexicon, Trial experiment
/// assignments and Siri analytics identifiers.
public final class ProfileModule: DossierModule {
    public let id = "profile"
    public let title = "Interest Profile"
    public let symbol = "person.text.rectangle"
    public let group = SidebarGroup.identity

    public init() {}

    public var sections: [ModuleSection] {
        [
            ModuleSection(id: "profile.summary", title: "Summary", symbol: "sparkles.rectangle.stack") { SummarySection() },
            ModuleSection(id: "profile.topics", title: "Topics", symbol: "number") { TopicsSection() },
            ModuleSection(id: "profile.entities", title: "Named Entities", symbol: "person.2.crop.square.stack") { EntitiesSection() },
            ModuleSection(id: "profile.places", title: "Places", symbol: "mappin.and.ellipse") { PlacesSection() },
            ModuleSection(id: "profile.mail", title: "Found in Mail", symbol: "envelope.badge") { MailSection() },
            ModuleSection(id: "profile.contacts", title: "Contacts Intelligence", symbol: "person.crop.circle.badge.questionmark") { ContactsSection() },
            ModuleSection(id: "profile.vocabulary", title: "Vocabulary & Identifiers", symbol: "character.book.closed") { VocabularySection() },
        ]
    }

    // MARK: Summary

    private static func directoryStore(_ name: String, _ url: URL, note: String? = nil) -> StoreInfo {
        let availability = Paths.probe(url)
        var info = StoreInfo(name: name, path: url, availability: availability, note: note)
        if availability.isAvailable {
            let size = FileProbe.directorySize(url, maxFiles: 20_000)
            info.sizeBytes = size.bytes
        }
        return info
    }

    public func summary() async -> ModuleSummary {
        var stores: [StoreInfo] = []
        var facts: [Fact] = []

        // PersonalizationPortrait
        var portrait = StoreInfo.file("PersonalizationPortrait", ProfilePaths.portraitDB, note: "topics, named entities, locations per source document")
        if let overview = try? await PortraitStore.overview() {
            portrait.rowCount = overview.topicRecords + overview.entityRecords + overview.placeRecords
            portrait.timeRange = overview.timeRange
            if let top = overview.topTopics.first {
                facts.append(Fact("Top inferred topic", (top.name.map { "\($0) (\(top.qid))" } ?? top.qid) + " — first of \(Format.count(overview.topics)) topics", sensitivity: .personal, symbol: "number", sectionID: "profile.topics"))
            }
            if let person = overview.topPerson {
                // The tagger files pronouns and capitalised words under "Person" as well, so
                // the fact only says "person" when the name is also known as a contact.
                facts.append(Fact(person.matchesContact ? "Most mentioned person" : "Most mentioned name (as classified by the system)",
                                  "\(person.name) (\(Format.count(person.mentions)) mentions; \(Format.count(overview.entities)) entities in total)",
                                  sensitivity: .sensitive, symbol: "person", sectionID: "profile.entities"))
            }
            if overview.placeRecords > 0 {
                facts.append(Fact("Places in your profile", "\(Format.count(overview.placeRecords)) location records", sensitivity: .personal, symbol: "mappin.and.ellipse", sectionID: "profile.places"))
            }
        }
        stores.append(portrait)

        // Suggestions
        var suggestions = StoreInfo.file("Suggestions (found in mail)", ProfilePaths.suggestionsDB, note: "pseudo-contacts, events, wallet passes, links")
        if let counts = try? await SuggestionsStore.counts() {
            suggestions.rowCount = counts.contacts + counts.events + counts.passes + counts.urls + counts.emails
            suggestions.timeRange = counts.timeRange
            if counts.passes > 0 {
                facts.append(Fact("Wallet passes kept from mail", "\(Format.count(counts.passes)) complete passes incl. barcodes", sensitivity: .sensitive, symbol: "wallet.pass", sectionID: "profile.mail"))
            }
            if counts.contacts + counts.events > 0 {
                facts.append(Fact("Harvested from messages", "\(Format.count(counts.contacts)) contacts, \(Format.count(counts.events)) events, \(Format.count(counts.urls)) links", sensitivity: .personal, symbol: "envelope.open", sectionID: "profile.mail"))
            }
            if counts.secretURLs > 0 {
                facts.append(Fact("Links carrying tokens", "\(Format.count(counts.secretURLs)) of \(Format.count(counts.urls)) stored links", sensitivity: .sensitive, symbol: "key", sectionID: "profile.mail"))
            }
            var snippets = StoreInfo.file("Suggestions snippets", ProfilePaths.snippetsDB, note: "text excerpts of processed mail")
            snippets.rowCount = counts.mailSnippets + counts.entitySnippets
            stores.append(suggestions)
            stores.append(snippets)
        } else {
            stores.append(suggestions)
        }

        // Family Sharing roster cached for suggestions (a few KB).
        var family = StoreInfo.file("Family Sharing cache", ProfilePaths.familyCircleCache, note: "family members with Apple Accounts and dates of birth")
        if family.availability.isAvailable, let circle = await Task.detached(priority: .utility, operation: { FamilyStore.loadIfAvailable() }).value {
            family.rowCount = circle.members.count
            let joined = circle.members.compactMap(\.joined)
            if let lo = joined.min(), let hi = joined.max() { family.timeRange = lo...hi }
            if !circle.members.isEmpty {
                var details: [String] = []
                if circle.members.contains(where: { !$0.appleID.isEmpty }) { details.append("Apple IDs") }
                if circle.members.contains(where: { $0.birth != nil }) { details.append("dates of birth") }
                facts.append(Fact("Family Sharing members cached", Format.count(circle.members.count) + (details.isEmpty ? "" : ", with " + details.joined(separator: " and ")),
                                  sensitivity: .sensitive, symbol: "figure.2.and.child.holdinghands", sectionID: "profile.contacts"))
            }
        }
        stores.append(family)

        // Speech profile + keyboard (file scans of a few MB, run off the main actor).
        let vocabulary = await Task.detached(priority: .utility) { () -> (speech: SpeechVocabularyData?, keyboard: KeyboardData?) in
            ((try? SpeechVocabulary.load()), (try? KeyboardLexicon.load()))
        }.value
        var assistant = ProfileModule.directoryStore("Siri speech profile & vocabulary", Paths.assistant, note: "names Siri learned to recognise")
        if let speech = vocabulary.speech {
            assistant.rowCount = speech.words.count
            let contacts = speech.categories.filter { $0.category.hasPrefix("contact") && !$0.category.hasSuffix("derived") }.reduce(0) { $0 + $1.count }
            if contacts > 0 {
                facts.append(Fact("Speech profile", "\(Format.count(contacts)) contact names taught to Siri", sensitivity: .personal, symbol: "waveform", sectionID: "profile.vocabulary"))
            }
        }
        stores.append(assistant)
        var keyboard = ProfileModule.directoryStore("Keyboard language models", ProfilePaths.languageModeling, note: "learned typing vocabulary")
        if let data = vocabulary.keyboard {
            keyboard.rowCount = data.words.count
            let dates = data.words.compactMap(\.date)
            if let lo = dates.min(), let hi = dates.max() { keyboard.timeRange = lo...hi }
            if !data.words.isEmpty {
                facts.append(Fact("Keyboard vocabulary", "\(Format.count(data.words.count)) remembered words, \(Format.count(data.words.filter(\.learned).count)) outside the dictionary", sensitivity: .personal, symbol: "keyboard", sectionID: "profile.vocabulary"))
            }
        }
        stores.append(keyboard)

        // Trial
        var trial = StoreInfo.file("Trial experiments", ProfilePaths.trialDB, note: "experiment and rollout assignments")
        if let assignments = try? await TrialStore.assignments() {
            trial.rowCount = assignments.count
            let dates = assignments.compactMap(\.start)
            if let lo = dates.min(), let hi = dates.max() { trial.timeRange = lo...hi }
        }
        stores.append(trial)
        stores.append(ProfileModule.directoryStore("First-party topics", ProfilePaths.firstPartyTopics, note: "IntelligencePlatform topic scores"))
        return ModuleSummary(stores: stores, facts: facts)
    }

    // MARK: Search

    public func search(_ query: String, limit: Int) async -> [SearchHit] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, limit > 0 else { return [] }
        var hits: [SearchHit] = []
        let per = max(3, limit / 4)
        func add(_ hit: SearchHit) { if hits.count < limit { hits.append(hit) } }

        if let rows = try? await PortraitStore.entities(offset: 0, limit: per, sort: nil, search: text, category: nil, bundle: nil) {
            for row in rows {
                add(SearchHit(id: "profile.entity.\(row.category).\(row.key)", title: row.name,
                              subtitle: "\(PortraitLabels.entityCategory(row.category)) · \(Format.count(row.mentions)) mentions in your documents",
                              moduleID: id, sectionID: "profile.entities", payload: "\(row.category)\t\(row.key)",
                              symbol: PortraitLabels.entitySymbol(row.category), sensitivity: .sensitive))
            }
        }
        if Task.isCancelled { return hits }
        if let rows = try? await PortraitStore.topics(offset: 0, limit: 4, sort: nil, search: text) {
            for row in rows {
                add(SearchHit(id: "profile.topic.\(row.qid)", title: row.name.map { "\($0) (\(row.qid))" } ?? row.qid,
                              subtitle: "Inferred topic · \(Format.count(row.records)) extractions" + (row.name == nil ? (row.context.map { " · seen with " + $0 } ?? "") : ""),
                              moduleID: id, sectionID: "profile.topics", payload: row.qid, symbol: "number", sensitivity: .personal))
            }
        }
        if Task.isCancelled { return hits }
        if let rows = try? await PortraitStore.places(offset: 0, limit: 4, sort: nil, search: text, origin: .all) {
            for row in rows {
                add(SearchHit(id: "profile.place.\(row.id)", title: row.name, subtitle: "Place · " + row.origin,
                              moduleID: id, sectionID: "profile.places", payload: row.name, symbol: "mappin.and.ellipse", sensitivity: .sensitive))
            }
        }
        if Task.isCancelled { return hits }
        if let rows = try? await PortraitStore.handles(offset: 0, limit: 4, sort: nil, search: text) {
            for row in rows {
                add(SearchHit(id: "profile.handle.\(row.id)", title: row.value, subtitle: "Contact handle · in \(Format.count(row.documents)) documents",
                              moduleID: id, sectionID: "profile.contacts", payload: "handles\t\(row.value)", symbol: "at", sensitivity: .sensitive))
            }
        }
        if Task.isCancelled { return hits }
        let needle = text.lowercased()
        if let circle = await Task.detached(priority: .utility, operation: { FamilyStore.loadIfAvailable() }).value {
            for member in circle.members where member.name.lowercased().contains(needle) || member.appleID.lowercased().contains(needle) {
                add(SearchHit(id: "profile.family.\(member.id)", title: member.name, subtitle: "Family Sharing · \(member.role)\(member.isMe ? " · you" : "")",
                              moduleID: id, sectionID: "profile.contacts", payload: "family\t\(member.name)", symbol: "figure.2.and.child.holdinghands", sensitivity: .sensitive))
            }
        }
        if let rows = try? await SuggestionsStore.contacts(offset: 0, limit: 4, sort: nil, search: text) {
            for row in rows {
                add(SearchHit(id: "profile.pseudo.\(row.id)", title: row.name.isEmpty ? row.details : row.name, subtitle: "Contact found in mail · " + Format.oneLine(row.details, max: 80),
                              moduleID: id, sectionID: "profile.mail", payload: "contacts\t\(row.name)", symbol: "person.crop.circle.badge.plus", sensitivity: .sensitive))
            }
        }
        if Task.isCancelled { return hits }
        if let rows = try? await SuggestionsStore.events(offset: 0, limit: 3, sort: nil, search: text) {
            for row in rows {
                add(SearchHit(id: "profile.event.\(row.id)", title: row.title, subtitle: "Event found in mail · " + DossierDate.day(row.start),
                              moduleID: id, sectionID: "profile.mail", payload: "events\t\(row.title)", symbol: "calendar.badge.clock", sensitivity: .sensitive))
            }
        }
        if let rows = try? await SuggestionsStore.passes(offset: 0, limit: 3, sort: nil, search: text) {
            for row in rows {
                add(SearchHit(id: "profile.pass.\(row.id)", title: row.title, subtitle: "Wallet pass from mail · " + row.organization,
                              moduleID: id, sectionID: "profile.mail", payload: "wallet\t\(row.title)", symbol: "wallet.pass", sensitivity: .sensitive))
            }
        }
        if Task.isCancelled { return hits }
        if let rows = try? await SuggestionsStore.urls(offset: 0, limit: 3, sort: nil, search: text) {
            for row in rows {
                add(SearchHit(id: "profile.url.\(row.id)", title: row.title.isEmpty ? row.host : row.title, subtitle: "Harvested link · " + Format.oneLine(row.url, max: 80),
                              moduleID: id, sectionID: "profile.mail", payload: "links\t\(text)", symbol: "link", sensitivity: .sensitive))
            }
        }
        if let rows = try? await SuggestionsStore.snippets(offset: 0, limit: 3, sort: nil, search: text) {
            for row in rows {
                add(SearchHit(id: "profile.snippet.\(row.id)", title: row.title.isEmpty ? "Snippet" : row.title, subtitle: "Mail snippet · " + Format.oneLine(row.content, max: 90),
                              moduleID: id, sectionID: "profile.mail", payload: "snippets\t\(text)", symbol: "text.quote", sensitivity: .sensitive))
            }
        }
        return hits
    }

    // MARK: Self-test

    public func selfTest() async -> [SelfTestLine] {
        await ProfileSelfTest.run()
    }
}
