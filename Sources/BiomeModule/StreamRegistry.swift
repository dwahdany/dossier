import Foundation
import DossierCore

// MARK: - Declarative stream registry
//
// Biome payloads are protobuf messages without public `.proto` files. Everything this
// module knows about a stream is declared here as data: a family, a one-line description
// and (where the meaning of fields could be established from real records) a list of
// `BiomeField`s mapping a field-number path to a name and a value kind. Adding a stream is
// one entry in `BiomeStreamRegistry.schemas` (typed columns) and/or
// `BiomeStreamRegistry.descriptions` (documentation only). Streams without a schema fall
// back to the generic protobuf tree.
//
// Field meanings were derived empirically (value shapes over many records, agreement with
// the same event in knowledgeC, and the names of the corresponding public enums). Fields
// whose meaning is not evident are deliberately left unnamed and show up as `#n` in the
// record tree.

/// How the raw protobuf value(s) at a field path are interpreted and rendered.
public enum BiomeFieldKind: Sendable {
    /// UTF-8 text.
    case string
    /// A bundle identifier: shown as the app's name (`AppDirectory`), the identifier
    /// stays available as secondary text and in the inspector.
    case app
    /// Signed integer (varint).
    case integer
    /// Varint 0 / 1.
    case bool
    /// Floating point number (fixed64 double / fixed32 float).
    case number
    /// Double or integer seconds since 2001-01-01 (Cocoa epoch).
    case cocoaDate
    /// Double or integer seconds since 1970-01-01.
    case unixDate
    /// A duration in seconds.
    case seconds
    /// Integer with known labels; unknown values render as the number.
    case enumeration([Int64: String])
    /// 16 raw bytes rendered as a UUID string.
    case uuidBytes
    /// A JSON object; the given key is extracted (`nil`: the whole JSON text).
    case json(key: String?)
    /// An embedded binary property list / NSKeyedArchiver graph (rendered as its strings).
    case plist
    /// Opaque bytes (rendered as a size).
    case bytes
    /// A value in the range 0…100.
    case percent
}

/// One documented field of a stream's protobuf message.
public struct BiomeField: Sendable {
    /// Field numbers from the top-level message down to the value. Repeated fields at any
    /// level are followed, all matches are collected.
    public let path: [Int]
    public let name: String
    public let kind: BiomeFieldKind
    public let sensitivity: Sensitivity
    /// Shown as a column of the record table (otherwise only in the inspector).
    public let column: Bool
    /// Part of the one-line record summary (unified timeline, search hits).
    public let headline: Bool
    /// Preferred column width in points.
    public let width: Double

    public init(_ path: [Int], _ name: String, _ kind: BiomeFieldKind = .string, sensitivity: Sensitivity = .low,
                column: Bool = true, headline: Bool = false, width: Double = 150) {
        self.path = path; self.name = name; self.kind = kind; self.sensitivity = sensitivity
        self.column = column; self.headline = headline; self.width = width
    }

    public var pathLabel: String { path.map(String.init).joined(separator: ".") }
}

/// Field-number → meaning table of one stream.
public struct BiomeStreamSchema: Sendable {
    public let fields: [BiomeField]
    public init(_ fields: [BiomeField]) { self.fields = fields }

    /// Name of the field at exactly this path, if documented.
    public func name(at path: [Int]) -> String? { fields.first { $0.path == path }?.name }
    public var columns: [BiomeField] { fields.filter(\.column) }
    public var headlines: [BiomeField] {
        let h = fields.filter(\.headline)
        return h.isEmpty ? Array(columns.prefix(3)) : h
    }
    /// Highest sensitivity of any documented field.
    public var sensitivity: Sensitivity { fields.map(\.sensitivity).max() ?? .low }
}

/// Where a stream directory lives.
public enum BiomeStreamOrigin: String, Sendable, CaseIterable {
    case biome = "Biome"
    case duetExpert = "Duet Expert"
    case linkd = "App Intents (linkd)"
    case other = "Other"

    /// Classifies a stream directory by its location (paths are derived at runtime).
    public static func of(_ url: URL) -> BiomeStreamOrigin {
        let path = url.standardizedFileURL.path
        if path.hasPrefix(Paths.biomeStreams.standardizedFileURL.path) { return .biome }
        if path.hasPrefix(Paths.duetExpertCenter.standardizedFileURL.path) { return .duetExpert }
        if path.contains("/ActionTranscript/") { return .linkd }
        return .other
    }
}

/// Static documentation + decoding hints for one stream.
public struct BiomeStreamInfo: Sendable {
    public let name: String
    /// Grouping in the catalogue ("App", "Siri", "IntelligenceFlow", …).
    public let family: String
    /// One plain-English sentence about what the stream records.
    public let summary: String
    public let schema: BiomeStreamSchema?
    /// Sensitivity of the stream's content as a whole.
    public let sensitivity: Sensitivity
    /// True for streams that record what the owner did (as opposed to system telemetry);
    /// used as the default selection of the unified timeline.
    public let isActivity: Bool
}

public enum BiomeStreamRegistry {
    /// Documentation and schema for a stream, with generic fallbacks for unknown names.
    public static func info(for name: String, origin: BiomeStreamOrigin = .biome) -> BiomeStreamInfo {
        let family = Self.family(of: name, origin: origin)
        let schema = origin == .biome ? schemas[name] : nil
        let summary = descriptions[name] ?? fallbackDescription(name: name, family: family, origin: origin)
        let sensitivity = sensitivityOverrides[name] ?? schema?.sensitivity ?? defaultSensitivity(family: family)
        let activity = (origin == .linkd && name != linkdMirrorName) || (origin == .biome && activityStreams.contains(name))
        return BiomeStreamInfo(name: name, family: family, summary: summary, schema: schema, sensitivity: sensitivity, isActivity: activity)
    }

    /// Family = the first dot-separated component, with a few special cases.
    public static func family(of name: String, origin: BiomeStreamOrigin = .biome) -> String {
        switch origin {
        case .duetExpert: return "Proactive Suggestions"
        case .linkd: return "App Intents Transcripts"
        case .other: return "Other"
        case .biome: break
        }
        let head = name.split(separator: ".").first.map(String.init) ?? name
        switch head {
        case "_DKEvent": return "Legacy Duet Events"
        case "AppleIntelligence", "GenerativeModels", "GenerativeExperiences", "ModelCatalog", "PrivateMLClient", "Feedback", "Intelligence", "IntelligenceEngine":
            return "Apple Intelligence"
        case "Lighthouse", "Unilog": return "Analytics Pipeline"
        case "Device", "Audio", "CarPlay", "GameController", "SpringBoard", "WindowManager", "Screen", "Clock", "Pasteboard", "SystemSettings", "LocalAuthentication", "Passwords", "Discoverability":
            return "Device & System"
        case "Safari", "Mail", "Messages", "Photos", "Wallet", "WalletPaymentsCommerce", "HomeKit", "FindMy", "Family", "CommApps", "Moments", "Screenshots", "ScreenTime", "Notification", "Media", "MediaAnalysis":
            return appFamilies[head] ?? head
        default: return head
        }
    }

    private static let appFamilies: [String: String] = [
        "Wallet": "Wallet", "WalletPaymentsCommerce": "Wallet", "Screenshots": "Photos & Media", "Photos": "Photos & Media",
        "Media": "Photos & Media", "MediaAnalysis": "Photos & Media", "ScreenTime": "App", "Notification": "Notifications",
        "Moments": "Notifications", "Messages": "Messages & Calls", "CommApps": "Messages & Calls", "Family": "Family",
        "FindMy": "Location", "HomeKit": "Home",
    ]

    private static func defaultSensitivity(family: String) -> Sensitivity {
        switch family {
        case "Accessibility", "Analytics Pipeline", "Apple Intelligence", "Device & System": return .low
        case "ProactiveHarvesting", "TextUnderstanding", "Messages & Calls", "Location", "Wallet", "Siri", "Mail": return .sensitive
        default: return .personal
        }
    }

    private static func fallbackDescription(name: String, family: String, origin: BiomeStreamOrigin) -> String {
        switch origin {
        case .duetExpert:
            if name.hasPrefix("blendingUI") { return "Which proactive suggestions were actually shown on this surface, and how they were laid out." }
            if name.hasPrefix("blending") { return "Ranked proactive suggestion candidates (apps, actions, shortcuts) computed for this system surface." }
            return "Internal stream of the proactive suggestions engine (duetexpertd)."
        case .linkd:
            if name == linkdMirrorName {
                return "Combined App Intents action transcript: linkd writes every action here and a second, byte-identical copy to the per-app transcript. The records mirror the per-app streams and are counted once in totals."
            }
            return "App Intents action transcript for this app: every App Intent / Shortcuts action the app performed or donated, with its parameters (archived LNTranscriptActionRecord objects)."
        case .other:
            return "SEGB stream found outside the standard Biome directories."
        case .biome:
            if name.hasPrefix("Accessibility.") { return "On/off changes of the \(name.dropFirst("Accessibility.".count)) accessibility setting." }
            return "Biome stream of the \(family) family; no public documentation exists for it."
        }
    }

    /// Directory name of linkd's combined transcript, which duplicates the per-app ones.
    public static let linkdMirrorName = "System"

    /// Streams that describe owner activity; the default selection of the timeline.
    static let activityStreams: Set<String> = [
        "App.InFocus", "App.Intent", "App.Activity", "App.DocumentInteraction", "App.MediaUsage", "App.MenuItem", "App.WebUsage",
        "Audio.Route", "CarPlay.Connected", "Clock.Alarm", "Device.Power.LowPowerMode", "Device.Wireless.AirplaneMode",
        "Device.Wireless.Bluetooth", "Device.Wireless.WiFi", "Device.Wireless.NFCTag", "Discoverability.Signals", "FindMy.LocationChange",
        "GameController.Connected", "HomeKit.Client.AccessoryControl", "LocalAuthentication.UI.Dialogs", "Location.Semantic",
        "Location.MicroLocationVisit", "Mail.Search.Query", "Media.NowPlaying", "Messages.Read", "Notification.Delivery", "Notification.Usage",
        "Pasteboard.Change", "Photos.Delete", "ProactiveHarvesting.Mail", "ProactiveHarvesting.Messages", "ProactiveHarvesting.Notes",
        "ProactiveHarvesting.Notifications", "ProactiveHarvesting.Reminders", "ProactiveHarvesting.Safari.PageView",
        "ProactiveHarvesting.Siri.Query", "ProactiveHarvesting.ThirdPartyApp", "Safari.Navigations", "Safari.PageLoad", "Safari.SearchEngine",
        "Screen.Sharing", "Screenshots.Screenshot", "Siri.Remembers.AssistantSuggestions", "Siri.Remembers.AudioHistory",
        "Siri.Remembers.CallHistory", "Siri.Remembers.InteractionHistory", "Siri.Remembers.MessageHistory",
        "SpringBoard.ExternalDisplay.DisplayConnected", "SystemSettings.SearchTerms", "TextUnderstanding.Output.Document",
        "UserFocus.ComputedMode", "UserFocus.InferredMode", "UserFocus.StatusChange", "Wallet.Transaction",
        "WindowManager.StageManager.Toggled", "App.Intents.Transcript",
    ]

    private static let sensitivityOverrides: [String: Sensitivity] = [
        "App.InFocus": .personal, "ScreenTime.AppUsage": .personal, "Media.NowPlaying": .personal,
        "GenerativeModels.GenerativeFunctions.Instrumentation": .low,
    ]

    // MARK: Shared enumerations

    /// `MRPlaybackState` of the MediaRemote framework.
    static let playbackState: [Int64: String] = [0: "Unknown", 1: "Playing", 2: "Paused", 3: "Stopped", 4: "Interrupted", 5: "Seeking"]
    /// `INInteractionDirection` of the Intents framework (used by `App.Intent` #11).
    static let interactionDirection: [Int64: String] = [0: "Unspecified", 1: "Outgoing", 2: "Incoming"]
    /// Direction in the `Siri.Remembers.*` streams (#1.6). The numbering is the opposite
    /// of `INInteractionDirection`: the value equals `interactions.direction` in Siri
    /// Remembers' `view.db`, where only direction-1 messages have a `senderHandle` entity
    /// and direction-2 messages only `recipientHandles`; the self-test re-checks both.
    static let remembersDirection: [Int64: String] = [0: "Unspecified", 1: "Incoming", 2: "Outgoing"]
    /// `INIntentHandlingStatus` of the Intents framework.
    static let intentHandlingStatus: [Int64: String] = [0: "Unspecified", 1: "Ready", 2: "In progress", 3: "Success", 4: "Failure", 5: "Deferred to app", 6: "User confirmation required"]

    /// Shared layout of the `Siri.Remembers.*` streams: message #1 is the interaction,
    /// repeated message #2 are named groups of entities (people, media items, …).
    private static func siriRemembers(durationColumn: Bool, entityTitle: String, jsonKey: String) -> BiomeStreamSchema {
        BiomeStreamSchema([
            BiomeField([1, 8], "Time", .unixDate, column: false),
            BiomeField([1, 4], "App", .app, sensitivity: .personal, headline: true, width: 190),
            BiomeField([1, 2], "Intent", width: 160),
            BiomeField([1, 6], "Direction", .enumeration(remembersDirection), headline: true, width: 96),
            BiomeField([2, 2, 4], entityTitle, .json(key: jsonKey), sensitivity: .sensitive, headline: true, width: 260),
            BiomeField([1, 9], "Duration", .seconds, column: durationColumn, width: 96),
            BiomeField([1, 11], "Metadata", .json(key: nil), column: false),
            BiomeField([1, 3], "Domain", column: false),
            BiomeField([2, 1], "Entity roles", column: false),
            BiomeField([2, 2, 2], "Entity types", column: false),
            BiomeField([2, 2, 1], "Entity identifiers", sensitivity: .sensitive, column: false),
            BiomeField([1, 12], "Conversation identifier", sensitivity: .sensitive, column: false),
            BiomeField([1, 1], "Interaction identifier", column: false),
            BiomeField([1, 13], "Donation identifier", column: false),
        ])
    }

    private static let assetDeliveryLog = BiomeStreamSchema([
        BiomeField([1, 1], "Time", .unixDate, column: false),
        BiomeField([1, 3, 1], "Use case", headline: true, width: 240),
        BiomeField([1, 9], "Subscriber", headline: true, width: 190),
        BiomeField([1, 8], "Subscription", headline: true, width: 300),
        BiomeField([1, 5], "Asset types", width: 260),
        BiomeField([1, 4], "Assets", column: false),
        BiomeField([1, 7], "OS build", width: 80),
    ])

    private static let onOff = BiomeStreamSchema([BiomeField([1], "Enabled", .bool, headline: true, width: 80)])

    private static let duetEvent = BiomeStreamSchema([
        BiomeField([1, 1], "Legacy stream", headline: true, width: 180),
        BiomeField([2], "Start", .cocoaDate, width: 150),
        BiomeField([3], "End", .cocoaDate, width: 150),
        BiomeField([4, 3], "Value", sensitivity: .personal, headline: true, width: 180),
        BiomeField([8], "Created", .cocoaDate, column: false),
        BiomeField([10], "Seconds from GMT", .integer, column: false),
        BiomeField([5], "Event identifier", column: false),
    ])

    // MARK: Schemas

    /// Field tables by stream name.
    public static let schemas: [String: BiomeStreamSchema] = {
        var s: [String: BiomeStreamSchema] = [:]

        s["App.InFocus"] = BiomeStreamSchema([
            BiomeField([6], "App", .app, sensitivity: .personal, headline: true, width: 240),
            BiomeField([3], "In focus", .bool, headline: true, width: 70),
            BiomeField([9], "Version", width: 80),
            BiomeField([10], "Build", width: 80),
            BiomeField([1], "Launch reason", width: 300),
            BiomeField([14], "Transition context", column: false),
            BiomeField([4], "Timestamp", .cocoaDate, column: false),
            BiomeField([2], "Type", .integer, column: false),
        ])
        s["ScreenTime.AppUsage"] = BiomeStreamSchema([
            BiomeField([3], "App", .app, sensitivity: .personal, headline: true, width: 260),
            BiomeField([1], "Started", .bool, headline: true, width: 70),
            BiomeField([2], "Timestamp", .unixDate, column: false),
        ])
        s["App.MediaUsage"] = BiomeStreamSchema([
            BiomeField([2], "App", .app, sensitivity: .personal, headline: true, width: 260),
            BiomeField([1], "Started", .bool, headline: true, width: 70),
            BiomeField([6], "Timestamp", .unixDate, column: false),
            BiomeField([8], "Session identifier", column: false),
        ])
        s["App.MenuItem"] = BiomeStreamSchema([
            BiomeField([1], "App", .app, sensitivity: .personal, headline: true, width: 240),
            BiomeField([3], "Menu item", sensitivity: .personal, headline: true, width: 360),
        ])
        s["App.WebUsage"] = BiomeStreamSchema([
            BiomeField([5], "Domain", sensitivity: .sensitive, headline: true, width: 200),
            BiomeField([4], "URL", sensitivity: .sensitive, width: 320),
            BiomeField([6], "Browser", .app, width: 160),
            BiomeField([3], "Usage state", .integer, width: 80),
            BiomeField([2], "Timestamp", .cocoaDate, column: false),
            BiomeField([1], "Web view identifier", column: false),
        ])
        s["App.Intent"] = BiomeStreamSchema([
            BiomeField([2], "App", .app, sensitivity: .personal, headline: true, width: 200),
            BiomeField([4], "Intent class", headline: true, width: 180),
            BiomeField([5], "Verb", width: 110),
            BiomeField([11], "Direction", .enumeration(interactionDirection), width: 80),
            BiomeField([7], "Handling status", .enumeration(intentHandlingStatus), width: 110),
            BiomeField([12], "Item / group identifier", sensitivity: .sensitive, width: 200),
            BiomeField([8], "Interaction (archived INInteraction)", .plist, sensitivity: .sensitive, column: false),
            BiomeField([1], "Timestamp", .cocoaDate, column: false),
            BiomeField([3], "Source", column: false),
            BiomeField([9], "Interaction identifier", column: false),
        ])
        s["App.Intents.Transcript"] = BiomeStreamSchema([
            BiomeField([1], "App", .app, sensitivity: .personal, headline: true, width: 300),
            BiomeField([6, 1], "Action", headline: true, width: 260),
            BiomeField([6, 7, 1], "Parameters", width: 280),
            BiomeField([5, 1], "Predicted action", column: false),
            BiomeField([4], "Timestamp", .unixDate, column: false),
            BiomeField([3], "Record identifier", .uuidBytes, column: false),
        ])
        s["App.DocumentInteraction"] = BiomeStreamSchema([
            BiomeField([2, 1], "Document", sensitivity: .sensitive, headline: true, width: 380),
            BiomeField([3], "Content type", width: 150),
            BiomeField([4, 1], "Opened with", .app, sensitivity: .personal, headline: true, width: 180),
            BiomeField([1], "Interaction type", .integer, width: 90),
            BiomeField([2, 2], "Bookmark", .bytes, column: false),
        ])
        s["App.RelevantShortcuts"] = BiomeStreamSchema([
            BiomeField([1], "App", .app, sensitivity: .personal, headline: true, width: 220),
            BiomeField([3], "Shortcut (archived)", .plist, sensitivity: .personal, headline: true, width: 420),
        ])
        s["Media.NowPlaying"] = BiomeStreamSchema([
            BiomeField([8], "Title", sensitivity: .personal, headline: true, width: 240),
            BiomeField([5], "Artist", sensitivity: .personal, headline: true, width: 160),
            BiomeField([4], "Album", sensitivity: .personal, width: 160),
            BiomeField([3], "State", .enumeration(playbackState), headline: true, width: 80),
            BiomeField([15], "App", .app, sensitivity: .personal, width: 200),
            BiomeField([6], "Length", .seconds, width: 70),
            BiomeField([10], "Media type", width: 120),
            BiomeField([14, 3], "Output route", sensitivity: .personal, width: 160),
            BiomeField([2], "Timestamp", .cocoaDate, column: false),
        ])
        s["Notification.Usage"] = BiomeStreamSchema([
            BiomeField([4], "App", .app, sensitivity: .personal, headline: true, width: 280),
            BiomeField([3], "Usage type", .integer, headline: true, width: 90),
            BiomeField([5], "Notification identifier", width: 280),
            BiomeField([2], "Timestamp", .cocoaDate, column: false),
        ])
        s["Notification.Delivery"] = BiomeStreamSchema([
            BiomeField([2], "App", .app, sensitivity: .personal, headline: true, width: 280),
            BiomeField([1], "Notification identifier", sensitivity: .personal, width: 360),
            BiomeField([3], "Timestamp", .unixDate, column: false),
        ])
        s["Device.Wireless.Bluetooth"] = BiomeStreamSchema([
            BiomeField([2], "Device name", sensitivity: .personal, headline: true, width: 200),
            BiomeField([4], "Connected", .bool, headline: true, width: 80),
            BiomeField([1], "Address", sensitivity: .personal, width: 140),
            BiomeField([5], "Device type", .integer, width: 80),
            BiomeField([11], "Vendor ID", .integer, width: 70),
            BiomeField([3], "Product ID", .integer, width: 80),
            BiomeField([6], "Battery (#6)", .percent, width: 80),
            BiomeField([7], "Battery (#7)", .percent, width: 80),
            BiomeField([8], "Battery (#8)", .percent, width: 80),
        ])
        s["Device.Wireless.BluetoothNearbyDevice"] = BiomeStreamSchema([
            BiomeField([2], "Device identifier", sensitivity: .personal, headline: true, width: 300),
            BiomeField([1], "Nearby", .bool, headline: true, width: 70),
        ])
        s["Device.Wireless.WiFi"] = BiomeStreamSchema([
            BiomeField([1], "Network (SSID)", sensitivity: .sensitive, headline: true, width: 240),
            BiomeField([2], "Connected", .bool, headline: true, width: 80),
        ])
        s["Discoverability.Signals"] = BiomeStreamSchema([
            BiomeField([1], "Signal", headline: true, width: 300),
            BiomeField([2], "Context", headline: true, width: 180),
            BiomeField([3], "OS build", width: 120),
        ])
        s["LocalAuthentication.UI.Dialogs"] = BiomeStreamSchema([
            BiomeField([2], "Requested by", .app, sensitivity: .personal, headline: true, width: 300),
            BiomeField([1], "Dialog host", headline: true, width: 300),
        ])
        s["Safari.Navigations"] = BiomeStreamSchema([
            BiomeField([1], "Domain", sensitivity: .sensitive, headline: true, width: 200),
            BiomeField([8], "URL", sensitivity: .sensitive, width: 360),
            BiomeField([5], "Region", width: 60),
            BiomeField([2], "Time bucket", .unixDate, width: 150),
        ])
        s["Safari.SearchEngine"] = BiomeStreamSchema([BiomeField([1], "Search engine", headline: true, width: 240)])
        s["Screenshots.Screenshot"] = BiomeStreamSchema([
            BiomeField([1, 4, 1], "File", sensitivity: .sensitive, headline: true, width: 520),
            BiomeField([1, 4, 2], "Bookmark", .bytes, column: false),
            BiomeField([1, 4, 3], "Content hash", .bytes, column: false),
        ])
        s["UserFocus.ComputedMode"] = BiomeStreamSchema([
            BiomeField([6], "Focus", sensitivity: .personal, headline: true, width: 240),
            BiomeField([2], "Active", .bool, headline: true, width: 70),
            BiomeField([1], "Mode identifier", width: 280),
        ])
        s["UserFocus.InferredMode"] = BiomeStreamSchema([
            BiomeField([14], "Focus", sensitivity: .personal, headline: true, width: 140),
            BiomeField([6], "Started", .bool, headline: true, width: 70),
            BiomeField([10], "Confidence", .number, width: 90),
            BiomeField([3], "Mode type", .integer, width: 80),
            BiomeField([12], "Origin", .integer, width: 70),
            BiomeField([2], "Mode identifier", column: false),
            BiomeField([7], "Inference identifier", column: false),
            BiomeField([1], "Timestamp", .cocoaDate, column: false),
        ])
        for name in ["Siri.Remembers.MessageHistory", "Siri.Remembers.InteractionHistory", "Siri.Remembers.AssistantSuggestions"] {
            s[name] = siriRemembers(durationColumn: false, entityTitle: name.hasSuffix("MessageHistory") ? "People" : "Entities", jsonKey: "name")
        }
        s["Siri.Remembers.CallHistory"] = siriRemembers(durationColumn: true, entityTitle: "People", jsonKey: "name")
        s["Siri.Remembers.AudioHistory"] = siriRemembers(durationColumn: false, entityTitle: "Media", jsonKey: "title")
        s["GenerativeModels.GenerativeFunctions.Instrumentation"] = BiomeStreamSchema([
            BiomeField([3], "Event", headline: true, width: 320),
            BiomeField([10, 8], "Use case", headline: true, width: 240),
            BiomeField([10, 3], "Client app", .app, sensitivity: .personal, width: 160),
            BiomeField([10, 13], "Inference provider", width: 220),
            BiomeField([10, 10, 1], "Model assets", width: 280),
            BiomeField([10, 10, 2], "Asset versions", column: false),
            BiomeField([11, 1, 1], "Error domain", width: 220),
            BiomeField([11, 1, 2], "Error code", .integer, width: 80),
            BiomeField([4, 3, 7, 1], "Loaded assets", column: false),
            BiomeField([8], "Timestamp", .unixDate, column: false),
            BiomeField([6, 1], "Trace identifier", .uuidBytes, column: false),
        ])
        s["AppleIntelligence.Availability"] = BiomeStreamSchema([
            BiomeField([6], "Languages", headline: true, width: 120),
            BiomeField([1, 1], "Flag 1.1", .integer, width: 70),
            BiomeField([2, 1], "Flag 2.1", .integer, width: 70),
            BiomeField([3], "Flag 3", .integer, width: 70),
            BiomeField([8, 1], "Flag 8.1", .integer, width: 70),
            BiomeField([8, 2], "Flag 8.2", .integer, width: 70),
            BiomeField([8, 3], "Flag 8.3", .integer, width: 70),
        ])
        for suffix in ["Availability", "ModelCatalog", "UnifiedAssetFramework", "SoftwareUpdateController"] {
            s["AppleIntelligence.Reporting.AssetDeliveryLog." + suffix] = assetDeliveryLog
        }
        s["ModelCatalog.Subscriptions.Decisions"] = BiomeStreamSchema([
            BiomeField([1], "Trigger", headline: true, width: 160),
            BiomeField([2, 1, 1], "Use cases", headline: true, width: 600),
        ])
        s["Lighthouse.Ledger.TaskStatus"] = BiomeStreamSchema([
            BiomeField([2], "Task", headline: true, width: 380),
            BiomeField([3], "Status", headline: true, width: 180),
            BiomeField([4], "Trigger", width: 90),
            BiomeField([5, 1], "Push topic", column: false),
        ])
        s["Lighthouse.Ledger.TaskCustomEvent"] = BiomeStreamSchema([
            BiomeField([2], "Task", headline: true, width: 420),
            BiomeField([3], "Event", headline: true, width: 100),
            BiomeField([1], "Run identifier", width: 280),
        ])
        s["Lighthouse.Ledger.TaskError"] = BiomeStreamSchema([
            BiomeField([2], "Task", headline: true, width: 340),
            BiomeField([3], "Error", headline: true, width: 320),
        ])
        s["Lighthouse.Ledger.TaskTelemetry"] = BiomeStreamSchema([
            BiomeField([4], "Task", headline: true, width: 380),
            BiomeField([5], "Status", headline: true, width: 110),
            BiomeField([2], "Window start", .unixDate, width: 150),
            BiomeField([3], "Window end", .unixDate, width: 150),
            BiomeField([6], "Reported", .unixDate, column: false),
        ])
        s["Lighthouse.Ledger.DeviceTelemetry"] = BiomeStreamSchema([
            BiomeField([2], "Window start", .unixDate, headline: true, width: 150),
            BiomeField([3], "Window end", .unixDate, width: 150),
        ])
        s["IntelligencePlatform.Views.Updated"] = BiomeStreamSchema([BiomeField([1], "View", headline: true, width: 320)])
        s["IntelligencePlatform.EntityTagging.PersonInference"] = BiomeStreamSchema([
            BiomeField([1], "Entity", .integer, sensitivity: .personal, headline: true, width: 190),
            BiomeField([2], "Tag", .integer, headline: true, width: 60),
            BiomeField([3], "Confidence", .number, headline: true, width: 100),
        ])
        s["Mail.Search.Query"] = BiomeStreamSchema([BiomeField([1], "Query", sensitivity: .sensitive, headline: true, width: 320)])
        s["Mail.Search.UIEvent"] = BiomeStreamSchema([
            BiomeField([1], "Search session", headline: true, width: 320),
            BiomeField([2], "Event type", .integer, headline: true, width: 90),
        ])
        s["Mail.Search.RankerEvent"] = BiomeStreamSchema([
            BiomeField([1], "Search session", headline: true, width: 320),
            BiomeField([4, 7, 1], "Ranked message identifiers", sensitivity: .personal, width: 420),
        ])
        s["ProactiveHarvesting.Mail"] = BiomeStreamSchema([
            BiomeField([11], "Subject", sensitivity: .sensitive, headline: true, width: 340),
            BiomeField([23, 1], "Sender", sensitivity: .sensitive, headline: true, width: 160),
            BiomeField([23, 2], "Sender address", sensitivity: .sensitive, width: 220),
            BiomeField([17], "Account", sensitivity: .sensitive, width: 200),
            BiomeField([19], "Mailboxes", sensitivity: .personal, width: 200),
            BiomeField([3], "Date", .cocoaDate, width: 150),
            BiomeField([14], "Body (HTML)", sensitivity: .sensitive, column: false),
            BiomeField([10, 1], "Header names", column: false),
            BiomeField([1], "Message identifier", column: false),
        ])
        s["TextUnderstanding.Output.Document"] = BiomeStreamSchema([
            BiomeField([12], "Title", sensitivity: .sensitive, headline: true, width: 340),
            BiomeField([1, 1], "App", .app, sensitivity: .personal, headline: true, width: 140),
            BiomeField([18, 1], "Author", sensitivity: .sensitive, width: 160),
            BiomeField([18, 2], "Author address", sensitivity: .sensitive, width: 220),
            BiomeField([25], "Account", sensitivity: .sensitive, width: 200),
            BiomeField([3], "Document date", .cocoaDate, width: 150),
            BiomeField([17], "Body", sensitivity: .sensitive, column: false),
            BiomeField([2], "Processed", .cocoaDate, column: false),
            BiomeField([1, 3], "Document identifier", column: false),
        ])
        s["TextUnderstanding.Deletions.Document"] = BiomeStreamSchema([
            BiomeField([1], "App", .app, sensitivity: .personal, headline: true, width: 200),
            BiomeField([3], "Deleted document identifiers", headline: true, width: 480),
            BiomeField([4], "Timestamp", .cocoaDate, column: false),
        ])
        for name in ["Siri.AnalyticsIdentifiers.UserSeed", "Siri.AnalyticsIdentifiers.UserAggregationId", "Siri.AnalyticsIdentifiers.UserSamplingId", "Siri.AnalyticsIdentifiers.HomeSeed"] {
            s[name] = BiomeStreamSchema([
                BiomeField([1], "Identifier", .uuidBytes, sensitivity: .personal, headline: true, width: 290),
                BiomeField([2], "Valid from", .unixDate, headline: true, width: 150),
                BiomeField([3], "Validity (days)", .integer, width: 100),
                BiomeField([4], "Created", .unixDate, width: 150),
                BiomeField([5], "Updated", .unixDate, column: false),
            ])
        }
        s["Device.Power.LowPowerMode"] = onOff
        s["Device.Wireless.AirplaneMode"] = onOff
        s["GameController.Connected"] = BiomeStreamSchema([BiomeField([1], "Connected", .bool, headline: true, width: 80)])
        for name in ["ClassicInvert", "ColorFilters", "Contrast", "MotionCues", "ReduceMotion", "ReduceTransparency", "SmartInvert", "SoundDetection", "VoiceControl", "VoiceOver", "Zoom"] {
            s["Accessibility." + name] = onOff
        }
        s["_DKEvent.Device.LowPowerMode"] = duetEvent
        s["_DKEvent.Wifi.Connection"] = duetEvent
        return s
    }()
}
