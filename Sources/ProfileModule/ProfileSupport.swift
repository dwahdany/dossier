import Foundation
import AppKit
import DossierCore

/// Store locations used by the Interest Profile module (all derived from the home
/// directory at runtime).
enum ProfilePaths {
    // PersonalizationPortrait
    static var portraitDB: URL { Paths.personalizationPortrait.appendingPathComponent("PPSQLDatabase.db") }
    static var topicScoreCache: URL { Paths.personalizationPortrait.appendingPathComponent("Topics/ScoreCache") }
    static var meCard: URL { Paths.personalizationPortrait.appendingPathComponent("Contacts/me_card.pb") }
    static var nameRecords: URL { Paths.personalizationPortrait.appendingPathComponent("Contacts/name_records", isDirectory: true) }
    static var socialHighlights: URL { Paths.personalizationPortrait.appendingPathComponent("streams/rankedSocialHighlights", isDirectory: true) }

    // Suggestions
    static var suggestionsDB: URL { Paths.suggestions.appendingPathComponent("entities.db") }
    static var snippetsDB: URL { Paths.suggestions.appendingPathComponent("snippets.db") }
    static var emailNameCache: URL { Paths.suggestions.appendingPathComponent("email-to-name.kvcache") }
    static var phoneNameCache: URL { Paths.suggestions.appendingPathComponent("phone-to-name.kvcache") }

    // Assistant / speech
    static var speechProfiles: URL { Paths.assistant.appendingPathComponent("SiriVocabulary/Modules/CESR/Default", isDirectory: true) }
    static var speechEntityProfile: URL { Paths.assistant.appendingPathComponent("SpeechMaintenance/ncbvqprofile") }
    static var customVocabulary: URL { Paths.assistant.appendingPathComponent("CustomVocabulary", isDirectory: true) }
    static var assistantBackedUpPrefs: URL { Paths.library.appendingPathComponent("Preferences/com.apple.assistant.backedup.plist") }

    // Keyboard
    static var languageModeling: URL { Paths.library.appendingPathComponent("LanguageModeling", isDirectory: true) }
    static var textReplacements: URL { Paths.library.appendingPathComponent("KeyboardServices/TextReplacements.db") }
    static var spellingCounts: URL { Paths.library.appendingPathComponent("Spelling/dynamic-counts.dat") }

    // Trial
    static var trialDB: URL { Paths.trial.appendingPathComponent("v7/Database/triald.db") }

    // IntelligencePlatform first-party topics
    static var firstPartyTopics: URL { Paths.intelligencePlatformArtifacts.appendingPathComponent("firstPartyTopics", isDirectory: true) }

    /// Resource directory of the framework that ships the generic topic assets
    /// (model weights, block lists and the Photos scene → Wikidata map).
    static var portraitAssets: URL {
        URL(fileURLWithPath: "/System/Library/PrivateFrameworks/PersonalizationPortraitInternals.framework/Versions/A/Resources", isDirectory: true)
    }

    /// Name list of the system's "augmented gazetteer" topic matcher (generic data shipped
    /// with the OS): newest asset folder that has one.
    static var gazetteerDB: URL? {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(atPath: portraitAssets.path) else { return nil }
        for folder in folders.filter({ $0.hasPrefix("assets") }).sorted(by: >) {
            let url = portraitAssets.appendingPathComponent(folder).appendingPathComponent("AugmentedGazetteerMetadata.db")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Family Sharing circle as cached for Siri suggestions (NSKeyedArchiver, `FAFamilyCircle`).
    static var familyCircleCache: URL { Paths.duetExpertCenter.appendingPathComponent("caches/familyCircleCache") }

    static let identifierStreams = [
        "Siri.AnalyticsIdentifiers.UserSeed",
        "Siri.AnalyticsIdentifiers.UserAggregationId",
        "Siri.AnalyticsIdentifiers.UserSamplingId",
        "Siri.AnalyticsIdentifiers.HomeSeed",
    ]
    static let segmentStream = "Siri.ODDI.SegmentsCohorts"
}

/// Enum labels of the PersonalizationPortrait store. The numeric codes are generic
/// framework constants (the same on every Mac); unknown codes fall back to "Code n".
enum PortraitLabels {
    private static let entityCategories: [Int: String] = [
        0: "Unknown", 1: "Person", 2: "Organization", 3: "Location", 4: "Restaurant",
        5: "Activity Location", 6: "Media", 7: "Artist", 8: "Street Address", 9: "City",
        10: "State", 11: "Country", 12: "Full Address", 13: "Tourist Attraction",
        14: "Event Title", 15: "Sports Team", 16: "Professional Athlete", 17: "Musician",
        18: "Movie", 19: "Dynamic", 20: "Politician", 21: "TV Show",
    ]
    private static let entitySymbols: [Int: String] = [
        1: "person", 2: "building.2", 3: "mappin.and.ellipse", 4: "fork.knife", 5: "figure.run",
        6: "play.rectangle", 7: "music.mic", 8: "signpost.right", 9: "building.columns", 10: "map",
        11: "globe.europe.africa", 12: "envelope", 13: "camera", 14: "calendar", 15: "sportscourt",
        16: "figure.basketball", 17: "guitars", 18: "film", 19: "sparkles", 20: "person.wave.2", 21: "tv",
    ]
    private static let entityAlgorithms: [Int: String] = [
        1: "Lookup Hints", 2: "CoreNLP", 3: "Core Routine", 4: "Data Detectors",
        5: "Structured Location", 6: "Trusted Location", 7: "Maps Interaction",
        8: "Now Playing", 9: "Custom Tagger", 10: "EventKit Import",
        11: "Photos Knowledge Graph", 12: "Parsec Donation", 13: "Podcasts Interaction",
        14: "Contacts Import", 15: "ContextKit", 16: "Augmented Gazetteer", 17: "Knowledge Graph",
    ]
    private static let topicAlgorithms: [Int: String] = [
        1: "ContextKit", 2: "Siri Donation", 3: "Lookup Hints", 4: "Named Entity",
        5: "Photos Knowledge Graph", 6: "High-Level Topic Extraction", 7: "Parsec Donation",
        8: "Podcasts Interaction", 9: "HealthKit Import", 10: "Augmented Gazetteer",
        11: "Knowledge Graph", 12: "Language Tagger",
    ]
    private static let locationAlgorithms: [Int: String] = [
        1: "Lookup Hints", 2: "CoreNLP", 3: "Core Routine", 4: "Data Detectors",
        5: "Structured Location", 6: "Trusted Location", 7: "Maps Interaction",
        8: "Custom Tagger", 9: "EventKit Import", 10: "Photos Knowledge Graph",
        11: "Augmented Gazetteer", 12: "Knowledge Graph",
    ]
    private static let locationCategories: [Int: String] = [
        0: "Uncategorized", 1: "Organization", 2: "Restaurant", 3: "Activity Location",
        4: "Tourist Attraction", 5: "Home", 6: "Work", 7: "Dynamic",
    ]

    static func entityCategory(_ code: Int) -> String { entityCategories[code] ?? "Category \(code)" }
    static func entitySymbol(_ code: Int) -> String { entitySymbols[code] ?? "tag" }
    static func entityAlgorithm(_ code: Int) -> String { entityAlgorithms[code] ?? "Algorithm \(code)" }
    static func topicAlgorithm(_ code: Int) -> String { topicAlgorithms[code] ?? "Algorithm \(code)" }
    static func locationAlgorithm(_ code: Int) -> String { locationAlgorithms[code] ?? "Algorithm \(code)" }
    static func locationCategory(_ code: Int) -> String { locationCategories[code] ?? "Category \(code)" }
    static var knownEntityCategories: [Int] { entityCategories.keys.sorted() }

    /// Turns a comma separated list of codes ("2,10") into labels.
    static func list(_ csv: String?, _ label: (Int) -> String) -> String {
        guard let csv, !csv.isEmpty else { return "—" }
        return csv.split(separator: ",").compactMap { Int($0) }.sorted().map(label).joined(separator: ", ")
    }

    /// Where a Portrait source document came from, derived from its bundle and group id.
    static func origin(bundle: String?, group: String?) -> String {
        let group = group ?? ""
        if group.hasSuffix("Maps.Collections") { return "Maps Guide / Collection" }
        if group.hasSuffix("Maps.PinnedPlaces") { return "Maps Pinned Place" }
        if group.contains("HVSearchableUserActivity") { return "Viewed / Searched in " + AppNames.name(bundle ?? "") }
        if group.contains("PhotosGraphDonation") { return "Photos Knowledge Graph" }
        if group.contains("PageContentDonation") { return "Web Page Content" }
        if group.contains("HVInteraction") { return "App Interaction" }
        guard let bundle, !bundle.isEmpty else { return "Unknown" }
        return AppNames.name(bundle)
    }
}

/// Human names for bundle identifiers (shared resolver: `DossierCore.AppDirectory`).
enum AppNames {
    static func name(_ bundle: String) -> String { AppDirectory.name(bundle, unknown: "—") }
    static func list(_ csv: String?) -> String { AppDirectory.names(csv: csv) }
}

/// Small shared helpers.
enum ProfileFormat {
    static func score(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value == 0 { return "0" }
        if abs(value) >= 100 { return String(format: "%.0f", value) }
        if abs(value) >= 1 { return String(format: "%.2f", value) }
        return String(format: "%.3f", value)
    }

    static func signed(_ value: Double?) -> String {
        guard let value else { return "—" }
        if abs(value) < 0.0005 { return "0" }
        return String(format: "%+.2f", value)
    }

    static func sentimentLabel(_ value: Double?) -> String {
        guard let value, abs(value) >= 0.0005 else { return "Neutral" }
        return value > 0 ? "Positive" : "Negative"
    }

    static func coordinate(_ lat: Double?, _ lon: Double?) -> String {
        guard let lat, let lon else { return "—" }
        return String(format: "%.5f, %.5f", lat, lon)
    }

    static func language(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "—" }
        let base = code.split(separator: "@").first.map(String.init) ?? code
        return Locale.current.localizedString(forIdentifier: base) ?? base
    }

    /// LIKE pattern with `%`, `_` and `\` escaped (use with `ESCAPE '\'`).
    static func like(_ text: String) -> String {
        var out = "%"
        for ch in text {
            if ch == "%" || ch == "_" || ch == "\\" { out.append("\\") }
            out.append(ch)
        }
        return out + "%"
    }

    static func wikidataURL(_ qid: String) -> URL? {
        guard qid.range(of: "^Q[0-9]+$", options: .regularExpression) != nil else { return nil }
        return URL(string: "https://www.wikidata.org/wiki/" + qid)
    }

    /// Names of URL query parameters that commonly carry credentials or one-time secrets.
    private static let secretParameters: Set<String> = [
        "pwd", "pass", "passwd", "password", "passcode", "pin", "otp", "code", "token", "access_token",
        "auth", "authkey", "auth_token", "key", "apikey", "api_key", "secret", "sig", "signature", "tk",
        "invite", "invitation", "session", "sessionid", "sid", "ticket", "magic", "login_token", "confirmation",
        "confirm", "verify", "verification", "reset", "hash", "nonce", "jwt", "id_token", "oobcode",
    ]

    /// Query parameters of `url` whose names look like they carry a passcode or token.
    static func secretParameters(in url: String) -> [String] {
        guard let components = URLComponents(string: url) else { return [] }
        var items = components.queryItems ?? []
        if let fragment = components.fragment, fragment.contains("="), let nested = URLComponents(string: "x://x?" + fragment) {
            items += nested.queryItems ?? []
        }
        var found: [String] = []
        for item in items {
            let name = item.name.lowercased()
            guard let value = item.value, value.count >= 4 else { continue }
            if secretParameters.contains(name) || name.hasSuffix("token") || name.hasSuffix("passcode") || name.hasSuffix("password") {
                if !found.contains(item.name) { found.append(item.name) }
            }
        }
        return found
    }

    static func host(_ url: String) -> String {
        URLComponents(string: url)?.host ?? ""
    }

    static func mask(_ secret: String) -> String {
        String(repeating: "•", count: min(max(secret.count, 4), 24)) + "  (\(secret.count) characters)"
    }
}

extension Array where Element == SQLValue {
    static func texts(_ values: [String]) -> [SQLValue] { values.map { .text($0) } }
}
