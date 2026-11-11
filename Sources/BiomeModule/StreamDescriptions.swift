import Foundation
import DossierCore

// Static, generic documentation: one plain-English sentence per known stream. Nothing in
// this file comes from any particular Mac.

public extension BiomeStreamRegistry {
    /// What each stream records, by stream name.
    static let descriptions: [String: String] = [
        // App
        "App.Activity": "NSUserActivity donations: what you were viewing or doing inside an app (used for Handoff, Siri suggestions and Spotlight).",
        "App.DocumentInteraction": "Documents opened or saved, with the file path, content type and the app that handled them.",
        "App.ExtensionUsage": "Starts and stops of app extensions (share sheets, widgets, keyboards).",
        "App.InFocus": "Every time an app comes to the foreground or leaves it, on this Mac and on synced devices. The backbone of app-usage history.",
        "App.Intent": "Intents donated by apps (calls started, messages sent, workouts, shortcuts run), including the archived interaction with its participants.",
        "App.Intents.Transcript": "App Intents actions performed by apps and system extensions, with their parameter names and values.",
        "App.LanguageConsumption": "Languages of the content you read in apps, used to tune language-related suggestions.",
        "App.MediaUsage": "Periods during which an app was playing audio or video.",
        "App.MenuItem": "Menu bar commands you chose, per app (macOS). Used to suggest commands.",
        "App.RelevantShortcuts": "Shortcuts that apps declared relevant for a time or place, as candidates for Siri suggestions.",
        "App.WebUsage": "Web pages shown in Safari and web views, with URL and domain (Screen Time web usage).",
        "ScreenTime.AppUsage": "Screen Time's record of app usage start and stop events.",
        // Device & system
        "Accessibility.ClassicInvert": "On/off changes of Classic Invert.",
        "Accessibility.ColorFilters": "On/off changes of display colour filters.",
        "Accessibility.Contrast": "On/off changes of Increase Contrast.",
        "Accessibility.MotionCues": "On/off changes of Vehicle Motion Cues.",
        "Accessibility.ReduceMotion": "On/off changes of Reduce Motion.",
        "Accessibility.ReduceTransparency": "On/off changes of Reduce Transparency.",
        "Accessibility.SmartInvert": "On/off changes of Smart Invert.",
        "Accessibility.SoundDetection": "On/off changes of Sound Recognition.",
        "Accessibility.VoiceControl": "On/off changes of Voice Control.",
        "Accessibility.VoiceOver": "On/off changes of VoiceOver.",
        "Accessibility.Zoom": "On/off changes of screen Zoom.",
        "Audio.Route": "Changes of the audio output route (speakers, headphones, AirPlay).",
        "CarPlay.Connected": "CarPlay connections and disconnections.",
        "Clock.Alarm": "Alarms firing, being snoozed or dismissed.",
        "Device.Power.LowPowerMode": "Low Power Mode being switched on or off.",
        "Device.Wireless.AirplaneMode": "Airplane Mode being switched on or off.",
        "Device.Wireless.Bluetooth": "Bluetooth accessories connecting and disconnecting, with name, address and battery levels.",
        "Device.Wireless.BluetoothNearbyDevice": "Bluetooth devices detected nearby (proximity, not connection).",
        "Device.Wireless.NFCTag": "NFC tags that were scanned.",
        "Device.Wireless.WiFi": "Wi-Fi networks joined and left, by network name.",
        "Discoverability.Signals": "Feature-usage signals (for example that Control Centre was opened or a screenshot taken) that drive the Tips app and feature hints.",
        "GameController.Connected": "Game controllers connecting and disconnecting.",
        "LocalAuthentication.UI.Dialogs": "Authentication dialogs (password / Touch ID prompts) that were shown, and which process asked for them.",
        "Passwords.SecurityRecommendations": "Password security recommendations that were surfaced.",
        "Pasteboard.Change": "Changes of the clipboard (which app copied, what kind of content).",
        "Screen.Sharing": "Screen sharing sessions starting and stopping.",
        "SpringBoard.ExternalDisplay.DisplayConnected": "External displays being connected (iPad).",
        "SpringBoard.WindowManagement.StageManagerMode": "Stage Manager mode changes (iPad).",
        "SystemSettings.SearchTerms": "Search terms typed into System Settings.",
        "WindowManager.StageManager.Toggled": "Stage Manager being switched on or off (macOS).",
        "UserFocus.ComputedMode": "The Focus mode that is in effect (Do Not Disturb, Sleep, Work, …) each time it changes.",
        "UserFocus.InferredMode": "The system's own guess of what you are doing (working, exercising, driving, …) with a confidence, used to suggest Focus modes.",
        "UserFocus.StatusChange": "Changes of your shared Focus status.",
        // Apple Intelligence
        "AppleIntelligence.Availability": "Whether Apple Intelligence is available on this device and why (not): eligibility, language, opt-in and asset state.",
        "AppleIntelligence.Reporting.AssetDeliveryLog.Availability": "Asset-delivery log: availability decisions for model assets per subscribing feature.",
        "AppleIntelligence.Reporting.AssetDeliveryLog.ModelCatalog": "Asset-delivery log: which features subscribed to which on-device models in the model catalogue.",
        "AppleIntelligence.Reporting.AssetDeliveryLog.SoftwareUpdateController": "Asset-delivery log: model downloads scheduled by the software update controller.",
        "AppleIntelligence.Reporting.AssetDeliveryLog.UnifiedAssetFramework": "Asset-delivery log: asset sets resolved by the Unified Asset Framework.",
        "AppleIntelligence.Reporting.Buddy": "Apple Intelligence choices made in Setup Assistant.",
        "Feedback.EvaluationResponse": "Thumbs-up / thumbs-down feedback you gave on generated content.",
        "Feedback.TextImageToImageEvaluationData": "Evaluation data attached to feedback about image-to-image generation.",
        "Feedback.TextToImageEvaluationData": "Evaluation data attached to feedback about image generation.",
        "Feedback.TextToTextEvaluationData": "Evaluation data attached to feedback about text generation.",
        "GenerativeExperiences.TransparencyLog": "Transparency log of generative requests (the source of the Apple Intelligence Report): prompts and responses sent to on-device and Private Cloud Compute models.",
        "GenerativeModels.GenerativeFunctions.Instrumentation": "Performance instrumentation of on-device generative models: every model load, prompt construction and inference with its use case — no prompt text.",
        "Intelligence.Usage": "Counters of Apple Intelligence feature usage.",
        "IntelligenceEngine.Interaction.Donation": "Interactions donated to the intelligence engine for personal context.",
        "ModelCatalog.Subscriptions.Decisions": "Decisions of the model catalogue about which features get which model assets, and what triggered the re-evaluation.",
        "PrivateMLClient.SafetyMetrics": "Safety-classifier metrics for requests to Private Cloud Compute.",
        // IntelligenceFlow / ToolKit
        "IntelligenceFlow.ExecutorTelemetry": "Telemetry of the Siri / Apple Intelligence plan executor (which tools ran, how long).",
        "IntelligenceFlow.Experimentation": "Experiment assignments of the IntelligenceFlow orchestrator.",
        "IntelligenceFlow.IFRequestTelemetry": "Per-request telemetry of the IntelligenceFlow orchestrator.",
        "IntelligenceFlow.JointResolverTelemetry": "Telemetry of entity resolution during request planning.",
        "IntelligenceFlow.PlanGenerationTelemetry": "Telemetry of plan generation (the model turning a request into tool calls).",
        "IntelligenceFlow.PlanResolutionTelemetry": "Telemetry of resolving a generated plan against available tools.",
        "IntelligenceFlow.QueryDecorationTelemetry": "Telemetry of query decoration (adding personal context to a request).",
        "IntelligenceFlow.ResponseGeneration": "Telemetry of response generation.",
        "IntelligenceFlow.SearchToolTelemetry": "Telemetry of the personal-context search tool.",
        "IntelligenceFlow.Telemetry": "General IntelligenceFlow session telemetry.",
        "IntelligenceFlow.Transcript.Datastream": "Full transcripts of Apple Intelligence / Siri orchestration sessions: requests, plans, tool calls and responses.",
        "ToolKit.Transcript": "Transcript of tools (App Intents) invoked on your behalf by the assistant.",
        // IntelligencePlatform
        "IntelligencePlatform.EntityTagging.PersonInference": "Relationship tags the knowledge graph inferred for people (family, partner, coworker, …) with a confidence.",
        "IntelligencePlatform.Views.Updated": "Notifications that a derived knowledge-graph view was rebuilt.",
        // Analytics pipeline
        "Lighthouse.Ledger.DediscoPrivacyEvent": "Ledger of differentially-private telemetry submissions.",
        "Lighthouse.Ledger.DeviceTelemetry": "Daily summary of on-device analytics task executions.",
        "Lighthouse.Ledger.LighthousePluginEvent": "Events of on-device analytics plug-ins.",
        "Lighthouse.Ledger.MlruntimedEvent": "Events of the on-device ML task runtime.",
        "Lighthouse.Ledger.TaskCustomEvent": "Stage markers (start, load, process, upload, finished) of on-device analytics and learning tasks.",
        "Lighthouse.Ledger.TaskError": "Errors of on-device analytics and learning tasks.",
        "Lighthouse.Ledger.TaskStatus": "Status changes of on-device analytics and learning tasks: which task ran when.",
        "Lighthouse.Ledger.TaskTelemetry": "Per-task run statistics of the on-device analytics scheduler.",
        "Lighthouse.Ledger.TrialdEvent": "Events of the experimentation (Trial) system.",
        "Unilog.HealthAggregatedSummary": "Aggregated health counters of the unified analytics logging pipeline.",
        "Unilog.HealthTelemetry": "Health telemetry of the unified analytics logging pipeline.",
        "Unilog.MailSearch.Processed": "Processed Mail search analytics, staged for upload.",
        "Unilog.SafariFeature.Aggregation": "Aggregated Safari feature-usage analytics.",
        "Unilog.SafariFeature.Stage": "Safari feature-usage analytics staged for aggregation.",
        "Unilog.SafariSearch.Aggregation": "Aggregated Safari search analytics.",
        "Unilog.SafariSearch.LongTermAggregationId": "Rotating identifier used to aggregate Safari search analytics.",
        "Unilog.SafariSearch.Stage": "Safari search analytics staged for aggregation.",
        // Location
        "FindMy.LocationChange": "Location changes reported by Find My.",
        "Location.HashedCoordinates": "Hashed (coarse) coordinates of places you were at.",
        "Location.MicroLocationVisit": "Micro-location visits: which room-scale place you were in, from radio fingerprints.",
        "Location.PointOfInterest.Category": "Category of the point of interest you are at (café, gym, …).",
        "Location.Semantic": "Semantic location changes: arriving at or leaving Home, Work, School, Gym.",
        // Mail
        "Mail.Categorization": "Categories Mail assigned to messages (Primary, Transactions, Updates, Promotions).",
        "Mail.CategorizationAnalytics.Read": "Analytics about reading categorised mail.",
        "Mail.CategorizationAnalytics.Recategorize": "Analytics about manual re-categorisation.",
        "Mail.CategorizationAnalytics.Receive": "Analytics about receiving categorised mail.",
        "Mail.Recategorization": "Messages you moved to another category.",
        "Mail.Search.Query": "Search queries typed into Mail.",
        "Mail.Search.RankerEvent": "Ranking features of Mail search results (scores per candidate message).",
        "Mail.Search.UIEvent": "User-interface events of a Mail search session (typing, results shown, result opened).",
        // Media / photos
        "Media.NowPlaying": "What was playing: title, artist, album, app, playback state and output route — on this Mac and on synced devices.",
        "MediaAnalysis.PEC.Processing": "Counters of photo-library background analysis runs (private-cloud / embedding processing).",
        "MediaAnalysis.TextUnderstanding.ProcessingResults": "Counters of text extracted from images during background analysis.",
        "MediaAnalysis.VisualSearch.Processing": "Counters of Visual Look Up background processing.",
        "Photos.AutonamingSuggestions.Feedback": "Your responses to suggested names for people in Photos.",
        "Photos.Delete": "Deletions of photos.",
        "Screenshots.Screenshot": "Screenshots taken, with file path and a bookmark to the file.",
        // Messages / calls / notifications
        "CommApps.CallIntelligence.CallContextCardsFedStats": "Federated statistics about call context cards.",
        "Messages.Read": "Messages being read.",
        "Messages.SharedWithYou.Feedback": "Feedback on Shared with You items.",
        "Moments.Events.Notifications": "Notification events used as Journal suggestions input.",
        "Notification.Delivery": "Notifications delivered, per app.",
        "Notification.Usage": "What happened to each notification: received, shown, opened, dismissed.",
        // Proactive harvesting / text understanding
        "ProactiveHarvesting.Mail": "Full content of e-mails harvested for Siri suggestions and personal context: headers, subject, sender, body.",
        "ProactiveHarvesting.Messages": "Message content harvested for Siri suggestions and personal context.",
        "ProactiveHarvesting.News.Article": "News articles you read.",
        "ProactiveHarvesting.Notes": "Notes content harvested for personal context.",
        "ProactiveHarvesting.Notifications": "Notification text harvested for personal context.",
        "ProactiveHarvesting.NotificationStacks": "Notification stacks as shown on the lock screen.",
        "ProactiveHarvesting.ParsecSearch": "Spotlight / Siri web searches.",
        "ProactiveHarvesting.Photos.KnowledgeGraphEnrichment": "Photos knowledge-graph facts harvested for personal context.",
        "ProactiveHarvesting.Photos.View": "Photos you viewed.",
        "ProactiveHarvesting.Reminders": "Reminders content harvested for personal context.",
        "ProactiveHarvesting.Safari.PageView": "Web pages viewed in Safari, with extracted content.",
        "ProactiveHarvesting.Siri.Query": "Siri requests.",
        "ProactiveHarvesting.ThirdPartyApp": "Content donated by third-party apps (user activities, intents).",
        "TextUnderstanding.Deletions.Document": "Documents (mails, calls, pages) that were deleted and must be removed from derived knowledge.",
        "TextUnderstanding.Output.Document": "Documents processed by on-device text understanding, with the full text that was analysed.",
        "TextUnderstanding.Output.Event": "Events (appointments, reservations) extracted from documents.",
        "TextUnderstanding.Output.Link": "Links extracted from documents.",
        // Safari
        "Safari.Navigations": "Sites navigated to in Safari (domain, URL, coarse time bucket).",
        "Safari.PageLoad": "Safari page loads.",
        "Safari.SearchEngine": "The search engine used in Safari.",
        // Siri
        "Siri.AnalyticsIdentifiers.HomeSeed": "Rotating seed from which Siri derives per-home analytics identifiers.",
        "Siri.AnalyticsIdentifiers.UserAggregationId": "Rotating identifier under which Siri analytics are aggregated.",
        "Siri.AnalyticsIdentifiers.UserSamplingId": "Identifier used to sample this user into Siri analytics cohorts.",
        "Siri.AnalyticsIdentifiers.UserSeed": "Rotating seed from which Siri derives ephemeral analytics identifiers.",
        "Siri.ODDI.ODDAssistantLLMSiriDigests": "On-device digests of assistant quality metrics.",
        "Siri.ODDI.ScorecardMetrics": "On-device Siri scorecard metrics.",
        "Siri.ODDI.SegmentsCohorts": "Analytics cohorts this device was assigned to.",
        "Siri.PostSiriEngagement": "What you did right after a Siri request (used to judge whether Siri helped).",
        "Siri.Remembers.AssistantSuggestions": "Suggestions Siri offered and the ones you engaged with.",
        "Siri.Remembers.AudioHistory": "Media you asked to play: title, artist, app — Siri's memory for “play that again”.",
        "Siri.Remembers.CallHistory": "Calls with app, direction, duration and the people involved — Siri's memory for “call them back”.",
        "Siri.Remembers.InteractionHistory": "Other app interactions Siri remembers (shortcuts run, items located, notes created).",
        "Siri.Remembers.MessageHistory": "Who you exchanged messages with, in which app and when (no message text) — Siri's memory for “message them again”.",
        "Siri.SELFProcessedEvent": "Siri instrumentation (SELF) events after on-device processing, staged for upload.",
        "Siri.SELFProcessedRemote": "Siri instrumentation events received from other devices.",
        // Home / family / wallet
        "Family.AskToBuy": "Ask to Buy requests in Family Sharing.",
        "Family.ScreenTime.ChildState": "Screen Time state of child accounts.",
        "Family.ScreenTime.Request": "Screen Time requests (more time, app approval).",
        "HomeKit.Client.AccessoryControl": "HomeKit accessories you controlled, and from which app.",
        "Wallet.Transaction": "Wallet / Apple Pay transactions.",
        "WalletPaymentsCommerce.FoundIn.OrderEmail": "Orders detected in e-mails for Wallet order tracking.",
        "WalletPaymentsCommerce.FoundIn.ReceiptEmail": "Receipts detected in e-mails.",
        // Legacy
        "_DKEvent.Device.LowPowerMode": "Legacy CoreDuet event mirrored into Biome: Low Power Mode periods.",
        "_DKEvent.Wifi.Connection": "Legacy CoreDuet event mirrored into Biome: Wi-Fi connection periods with the network name.",
        // Duet Expert (proactive suggestions)
        "ERM": "Engagement records of proactive suggestions (shown, tapped, dismissed).",
        "appLaunchInferredMode": "App launches annotated with the inferred activity mode, training data for Focus suggestions.",
        "clientModel": "Suggestion candidates produced by each prediction model before blending.",
        "contextHeuristics": "Heuristic context triggers (headphones connected, arriving somewhere) that produce suggestions.",
        "homeScreen": "Home-screen events: pages viewed, widgets and suggestions engaged.",
        "lightweightClientModelCacheUpdates": "Log of refreshes of the per-model suggestion caches.",
        "location": "Location context snapshots used by the suggestions engine.",
        "notificationSuggestion": "Suggestions about notifications (digest, mute, Focus).",
        "predictionContext": "Snapshots of the context each prediction ran in (time, device state, recent apps).",
        "proactiveSuggestionUIFeedbackResults": "Feedback on suggestions shown in the user interface.",
        "spotlightUI": "Spotlight sessions: suggestions shown and what was engaged.",
        "userNotificationEvents": "Notification events used for notification ranking and digests.",
    ]
}

/// Documentation for the legacy knowledgeC (CoreDuet) streams.
public enum KnowledgeStreamRegistry {
    public static func summary(for stream: String) -> String {
        if let d = descriptions[stream] { return d }
        if stream.hasPrefix("/knowledge-sync-deletion-bookmark/") { return "Bookkeeping: how far deletions from a synced device have been applied." }
        if stream.hasPrefix("/knowledge-sync-addition-window/") { return "Bookkeeping: time windows of events already received from a synced device." }
        return "CoreDuet event stream without public documentation."
    }

    public static func isBookkeeping(_ stream: String) -> Bool { stream.hasPrefix("/knowledge-sync-") }

    /// Streams whose event value (`ZVALUESTRING`) is a bundle identifier.
    private static let appValued: [String: String] = [
        "/app/usage": "App", "/app/inFocus": "App", "/app/activity": "App", "/app/mediaUsage": "App", "/app/install": "App",
        "/app/webUsage": "Browser", "/app/relevantShortcuts": "App", "/widgets/viewed": "App",
    ]

    /// What the event value of a stream means — the title of the value column.
    private static let valueTitles: [String: String] = [
        "/app/intents": "Category", "/notification/usage": "Event", "/bluetooth/isConnected": "Connected", "/display/isBacklit": "Display On",
        "/device/isLocked": "Locked", "/device/isPluggedIn": "Plugged In", "/device/batteryPercentage": "Battery Level",
        "/device/lowPowerMode": "Low Power Mode", "/audio/outputRoute": "Route", "/media/nowPlaying": "Item", "/safari/history": "Page",
        "/user/isSleeping": "Asleep", "/wifi/connection": "Network", "/portrait/topic": "Topic", "/portrait/entity": "Entity",
    ]

    /// Streams whose integer value is an on / off state.
    private static let booleanValued: Set<String> = [
        "/bluetooth/isConnected", "/display/isBacklit", "/device/isLocked", "/device/isPluggedIn", "/device/lowPowerMode", "/user/isSleeping",
    ]

    /// True when the stream's event value is a bundle identifier.
    public static func valueIsApp(_ stream: String) -> Bool { appValued[stream] != nil }

    /// Column title for the event value of a stream ("App" for `/app/usage`, …).
    public static func valueTitle(for stream: String) -> String { appValued[stream] ?? valueTitles[stream] ?? "Value" }

    /// The event value as it should be read: app name for bundle identifiers, Yes / No
    /// for on / off streams, otherwise unchanged.
    public static func displayValue(_ value: String, stream: String) -> String {
        if valueIsApp(stream) { return RecordDecoder.appName(value) }
        if booleanValued.contains(stream) {
            if value == "1" { return "Yes" }
            if value == "0" { return "No" }
        }
        return value
    }

    /// One-line description of an event for the unified timeline.
    static func eventSummary(_ event: KnowledgeEvent) -> String {
        var parts: [String] = []
        if !event.value.isEmpty {
            if booleanValued.contains(event.stream), event.value == "0" || event.value == "1" {
                let title = valueTitle(for: event.stream).lowercased()
                parts.append(event.value == "1" ? title : "not " + title)
            } else {
                parts.append(displayValue(event.value, stream: event.stream))
            }
        }
        if !event.bundle.isEmpty, event.bundle != event.value { parts.append("from " + RecordDecoder.appName(event.bundle)) }
        if let duration = event.duration { parts.append(Format.duration(duration)) }
        return parts.joined(separator: "  ·  ")
    }

    public static let descriptions: [String: String] = [
        "/app/usage": "Foreground periods of apps on this Mac: bundle identifier, start, end.",
        "/app/intents": "Intents donated by apps, mostly synced from iPhone: calls, messages, media, with the serialized interaction.",
        "/app/webUsage": "Web usage periods (Screen Time): which page was in front, in which browser.",
        "/app/mediaUsage": "Periods during which an app played media.",
        "/app/activity": "NSUserActivity donations (what you were doing in an app).",
        "/app/inFocus": "Apps in focus (older systems).",
        "/app/install": "App installations and removals.",
        "/bluetooth/isConnected": "Bluetooth accessory connection periods with device name and type.",
        "/display/isBacklit": "Periods during which the display was on.",
        "/notification/usage": "Notification events per app: received, shown, dismissed, opened.",
        "/device/isLocked": "Periods during which the device was locked.",
        "/device/isPluggedIn": "Periods during which the device was connected to power.",
        "/device/batteryPercentage": "Battery level samples.",
        "/device/lowPowerMode": "Low Power Mode periods.",
        "/audio/outputRoute": "Audio output route changes.",
        "/media/nowPlaying": "Now-playing items.",
        "/safari/history": "Safari history visits.",
        "/user/isSleeping": "Inferred sleep periods.",
        "/wifi/connection": "Wi-Fi connection periods.",
        "/portrait/topic": "Topics of interest inferred from content.",
        "/portrait/entity": "Named entities inferred from content.",
        "/search/feedback": "Spotlight search feedback.",
        "/siri/ui": "Siri user-interface sessions.",
    ]
}
