import AppKit
import SwiftUI

/// Resolves bundle identifiers to human-readable app names, shared by every module so the
/// same app is called the same thing everywhere.
///
/// Order: a table of well-known generic identifiers (system apps of other Apple platforms,
/// system UI surfaces and widespread third-party apps — none of it personal), then
/// whatever Launch Services finds installed on this Mac, then a prettified last component
/// of the identifier. Thread-safe; results are cached.
public enum AppDirectory {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    nonisolated(unsafe) private static var urlCache: [String: URL?] = [:]

    private static let known: [String: String] = [
        // iOS / iPadOS system apps
        "com.apple.mobilesafari": "Safari",
        "com.apple.mobilemail": "Mail",
        "com.apple.MobileSMS": "Messages",
        "com.apple.mobileslideshow": "Photos",
        "com.apple.mobilephone": "Phone",
        "com.apple.mobilecal": "Calendar",
        "com.apple.mobilenotes": "Notes",
        "com.apple.mobiletimer": "Clock",
        "com.apple.mobileme.fmip1": "Find My",
        "com.apple.findmy": "Find My",
        "com.apple.Preferences": "Settings",
        "com.apple.camera": "Camera",
        "com.apple.AppStore": "App Store",
        "com.apple.Maps": "Maps",
        "com.apple.Music": "Music",
        "com.apple.podcasts": "Podcasts",
        "com.apple.Health": "Health",
        "com.apple.Passbook": "Wallet",
        "com.apple.passbook": "Wallet",
        "com.apple.weather": "Weather",
        "com.apple.reminders": "Reminders",
        "com.apple.DocumentsApp": "Files",
        "com.apple.InCallService": "Phone",
        "com.apple.Telephony": "Phone",
        "com.apple.facetime": "FaceTime",
        "com.apple.FaceTime": "FaceTime",
        "com.apple.Fitness": "Fitness",
        "com.apple.shortcuts": "Shortcuts",
        "com.apple.siriVoiceShortcuts": "Siri Shortcuts",
        "com.apple.tv": "TV",
        "com.apple.news": "News",
        "com.apple.stocks": "Stocks",
        "com.apple.Translate": "Translate",
        "com.apple.Passwords": "Passwords",
        "com.apple.Bridge": "Watch",
        "com.apple.Home": "Home",
        "com.apple.iBooks": "Books",
        "com.apple.calculator": "Calculator",
        "com.apple.MobileAddressBook": "Contacts",
        "com.apple.mail": "Mail",
        "com.apple.CalendarUI": "Calendar",
        "com.apple.iCal": "Calendar",
        "com.apple.calendar": "Calendar",
        "com.apple.eventkit.osx": "Calendar (EventKit)",
        "com.apple.introductions.accepted": "Accepted Introductions",
        // System surfaces
        "com.apple.Spotlight": "Spotlight",
        "com.apple.springboard": "Home Screen",
        "com.apple.springboard.home-screen": "Home Screen",
        "com.apple.springboard.home-screen-open-folder": "Home Screen Folder",
        "com.apple.springboard.app-switcher": "App Switcher",
        "com.apple.springboard.today-view": "Today View",
        "com.apple.springboard.app-library": "App Library",
        "com.apple.springboard.spotlight-search": "Spotlight Search",
        "com.apple.springboard.lock-screen": "Lock Screen",
        "com.apple.springboard.control-center": "Control Center",
        "com.apple.springboard.notification-center": "Notification Center",
        "com.apple.carousel.clock": "Watch Face",
        "com.apple.carousel.home-screen": "Watch Home Screen",
        "com.apple.carousel.dock": "Watch Dock",
        "backlightActivated": "Display Wake",
        "com.apple.WebKit.GPU": "Web Content (WebKit)",
        "com.apple.WebKit.WebContent": "Web Content (WebKit)",
        "com.apple.loginwindow": "Lock Screen",
        "com.apple.ScreenSaver.Engine": "Screen Saver",
        "com.apple.SecurityAgent": "Authentication Prompt",
        "com.apple.UserNotificationCenter": "System Alert",
        "com.apple.dock": "Dock",
        "com.apple.finder": "Finder",
        "com.apple.controlcenter": "Control Center",
        "com.apple.notificationcenterui": "Notification Center",
        "com.apple.systempreferences": "System Settings",
        "com.apple.coreservices.uiagent": "System UI Agent",
        "com.apple.Siri": "Siri",
        "com.apple.siri": "Siri",
        "com.apple.SetupAssistant": "Setup Assistant",
        // watchOS
        "com.apple.SessionTrackerApp": "Workout",
        "com.apple.NanoMaps": "Maps",
        "com.apple.NanoMusic": "Music",
        "com.apple.NanoPhone": "Phone",
        "com.apple.NanoSettings": "Settings",
        "com.apple.NanoAlarm": "Alarms",
        "com.apple.NanoNowPlaying": "Now Playing",
        "com.apple.private.NanoTimer": "Timers",
        "com.apple.NanoStopwatch": "Stopwatch",
        "com.apple.NanoWeatherApp": "Weather",
        "com.apple.NanoHeartRate": "Heart Rate",
        "com.apple.NanoSleep.watchkitapp": "Sleep",
        // Widespread third-party apps (iOS bundle ids that Launch Services cannot resolve on a Mac)
        "chat.threema.Threema": "Threema",
        "com.atebits.Tweetie2": "X (Twitter)",
        "com.burbn.instagram": "Instagram",
        "com.facebook.Messenger": "Messenger",
        "com.github.stormbreaker.prod": "GitHub",
        "com.google.Gmail": "Gmail",
        "com.google.ios.youtube": "YouTube",
        "com.hammerandchisel.discord": "Discord",
        "com.linear.ios": "Linear",
        "com.linkedin.LinkedIn": "LinkedIn",
        "com.microsoft.Office.Outlook": "Outlook",
        "com.microsoft.skype.teams": "Microsoft Teams",
        "com.readdle.smartemail": "Spark",
        "com.skype.skype": "Skype",
        "com.tencent.xin": "WeChat",
        "com.tinyspeck.chatlyio": "Slack",
        "com.toyopagroup.picaboo": "Snapchat",
        "com.viber": "Viber",
        "im.element.app": "Element",
        "jp.naver.line": "LINE",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "net.whatsapp.WhatsAppSMB": "WhatsApp Business",
        "org.whispersystems.signal": "Signal",
        "ph.telegra.Telegraph": "Telegram",
        "us.zoom.videomeetings": "Zoom",
    ]

    /// Display name for a bundle identifier; `unknown` for an empty identifier.
    public static func name(_ bundle: String?, unknown: String = "Unknown") -> String {
        guard let bundle, !bundle.isEmpty else { return unknown }
        lock.lock()
        if let hit = cache[bundle] { lock.unlock(); return hit }
        lock.unlock()
        let resolved = resolve(bundle)
        lock.lock(); cache[bundle] = resolved; lock.unlock()
        return resolved
    }

    /// Sorted, comma-separated names for a comma-separated list of bundle identifiers.
    public static func names(csv: String?, unknown: String = "—") -> String {
        guard let csv, !csv.isEmpty else { return unknown }
        return csv.split(separator: ",").map { name(String($0)) }.sorted().joined(separator: ", ")
    }

    /// Location of the installed app, if this Mac has it.
    public static func appURL(_ bundle: String) -> URL? {
        lock.lock()
        if let hit = urlCache[bundle] { lock.unlock(); return hit }
        lock.unlock()
        let url = bundle.isEmpty ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        lock.lock(); urlCache[bundle] = .some(url); lock.unlock()
        return url
    }

    private static func resolve(_ bundle: String) -> String {
        if let k = known[bundle] { return k }
        if let url = appURL(bundle) {
            var n = FileManager.default.displayName(atPath: url.path)
            if n.hasSuffix(".app") { n = String(n.dropLast(4)) }
            if !n.isEmpty { return n }
        }
        if bundle.hasPrefix("com.apple.springboard.") {
            return prettify(String(bundle.dropFirst("com.apple.springboard.".count)))
        }
        var parts = bundle.split(separator: ".").map(String.init)
        // Some iOS apps report "<bundle id>.<10-character team id>".
        if parts.count > 2, let last = parts.last, last.count == 10, last.allSatisfy({ $0.isNumber || ($0.isLetter && $0.isUppercase) }) {
            parts.removeLast()
            let trimmed = parts.joined(separator: ".")
            if let k = known[trimmed] { return k }
        }
        // Drop platform suffixes and generic trailing components.
        while parts.count > 1, let last = parts.last, ["ios", "iphone", "ipad", "mac", "macos", "app", "desktop", "client", "mobile", "watchkitapp", "watchkitextension", "watchapp"].contains(last.lowercased()) {
            parts.removeLast()
        }
        guard let last = parts.last else { return bundle }
        return prettify(last)
    }

    private static func prettify(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        for suffix in [" ios", " iOS", " mac", " desktop"] where s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        if s.hasPrefix("Nano"), s.count > 5 { s = String(s.dropFirst(4)) }
        if s == s.lowercased() { s = s.capitalized }
        return s.isEmpty ? raw : s
    }

    /// System UI that takes focus without being "an app you used": lock screen, home
    /// screen and its sub-scenes, screen saver.
    public static func isSystemSurface(_ bundle: String) -> Bool {
        bundle == "com.apple.loginwindow" || bundle == "com.apple.ScreenSaver.Engine"
            || bundle.hasPrefix("com.apple.springboard") || bundle.lowercased().hasPrefix("com.apple.carousel")
            || bundle == "com.apple.PineBoard" || bundle == "com.apple.HeadBoard"
    }

    /// Lock-screen style surfaces (as opposed to the home screen).
    public static func isLockSurface(_ bundle: String) -> Bool {
        bundle == "com.apple.loginwindow" || bundle == "com.apple.ScreenSaver.Engine" || bundle == "com.apple.springboard.lock-screen"
    }

    @MainActor private static var icons: [String: NSImage?] = [:]

    /// Icon of the installed app, nil when this Mac does not have it.
    @MainActor public static func icon(_ bundle: String) -> NSImage? {
        if let hit = icons[bundle] { return hit }
        let image = appURL(bundle).map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[bundle] = image
        return image
    }
}

/// App icon (installed apps) or a neutral placeholder glyph.
public struct AppIcon: View {
    private let bundle: String
    private let size: CGFloat

    public init(bundle: String, size: CGFloat = 16) { self.bundle = bundle; self.size = size }

    public var body: some View {
        Group {
            if let image = AppDirectory.icon(bundle) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: AppDirectory.isSystemSurface(bundle) ? "lock.rectangle" : "app.dashed")
                    .resizable().scaledToFit().foregroundStyle(.tertiary).padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Icon + name cell for app lists and table cells.
public struct AppLabel: View {
    private let bundle: String
    private let name: String?
    private let size: CGFloat
    private let showsIcon: Bool

    public init(bundle: String, name: String? = nil, size: CGFloat = 16, showsIcon: Bool = true) {
        self.bundle = bundle; self.name = name; self.size = size; self.showsIcon = showsIcon
    }

    public var body: some View {
        HStack(spacing: 6) {
            if showsIcon { AppIcon(bundle: bundle, size: size) }
            Text(name ?? AppDirectory.name(bundle)).lineLimit(1).truncationMode(.tail)
        }
        .help(bundle)
    }
}
