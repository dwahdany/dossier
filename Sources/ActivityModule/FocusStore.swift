import DossierCore
import Foundation

// MARK: - Models

/// A device that contributed activity records: this Mac (`local`) or a device whose Biome
/// streams were synced here through iCloud (`remote/<identifier>`).
struct ActivityDevice: Identifiable, Hashable, Sendable {
    /// "local" or the remote Biome device identifier. Never displayed.
    let id: String
    var name: String
    var platform: String
    /// OS build reported by `sync.db` (not a hardware model).
    var build: String?
    var isLocal: Bool
    var lastSync: Date?

    var symbol: String {
        if platform.contains("Mac") { return isLocal ? "laptopcomputer" : "desktopcomputer" }
        if platform.contains("Watch") { return "applewatch" }
        if platform.contains("iPhone") || platform.contains("iPad") { return "iphone" }
        if platform.contains("TV") { return "appletv" }
        return "questionmark.square.dashed"
    }

    var biome: BiomeDevice { isLocal ? .local : .remote(id) }
    static let localID = "local"
}

/// One foreground interval of one app. 24 bytes; a device with a million sessions costs
/// 24 MB, so whole-device arrays can be cached.
struct FocusSession: Sendable {
    var app: Int32
    /// Bit 0: duration was capped. Bit 1: system surface (lock / home screen). Bit 2: still
    /// open. Bit 3: continuation after a display-off gap.
    var flags: UInt8
    var start: Double   // seconds since the Cocoa reference date
    var end: Double

    var duration: Double { end - start }
    var isCapped: Bool { flags & 1 != 0 }
    var isSystem: Bool { flags & 2 != 0 }
    var isOpen: Bool { flags & 4 != 0 }
    /// Later piece of a session that was split by a display-off interval (not a new activation).
    var isContinuation: Bool { flags & 8 != 0 }
}

/// Decoded and paired `App.InFocus` history of one device.
struct DeviceFocus: Sendable {
    var bundles: [String] = []
    var names: [String] = []
    var systemFlags: [Bool] = []
    /// Sorted by start time; never overlapping.
    var sessions: [FocusSession] = []
    var eventCount = 0
    var startEvents = 0
    var stopEvents = 0
    var unmatchedStops = 0
    var impliedStops = 0
    var cappedSessions = 0
    var droppedFlickers = 0
    var undecodable = 0
    var firstEvent: Double?
    var lastEvent: Double?

    var timeRange: ClosedRange<Date>? {
        guard let a = firstEvent, let b = lastEvent else { return nil }
        return DossierDate.cocoa(a)...DossierDate.cocoa(b)
    }
}

enum ActivityRange: String, CaseIterable, Identifiable, Sendable {
    case week = "7 Days", month = "30 Days", all = "All Time"
    var id: String { rawValue }
    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .all: return nil
        }
    }
}

struct AppUsageRow: Identifiable, Sendable, Hashable {
    var id: String { bundle }
    let bundle: String
    let name: String
    var activations = 0
    var total: Double = 0
    var median: Double = 0
    var longest: Double = 0
    var first: Date?
    var last: Date?
    var daysActive = 0
    var capped = 0
    /// Cross-check columns (this Mac only): the same app in other stores.
    var knowledgeSeconds: Double?
    var screenTimeSeconds: Double?
    var atxMedianGap: Double?
    var atxLastLaunch: Date?
    var dailyDose: Double?
}

struct DayStat: Identifiable, Sendable, Hashable {
    var id: Date { day }
    let day: Date
    var total: Double = 0
    var sessions = 0
    /// Fractional hours since the day's midnight; the "logical day" runs 04:00–28:00 so a
    /// night that ends at 01:30 belongs to the previous day (last = 25.5).
    var first: Double?
    var last: Double?
}

struct FocusAggregate: Sendable {
    var apps: [AppUsageRow] = []
    var days: [DayStat] = []
    var rhythm: [DayStat] = []
    /// `heat[weekday 1...7 as in Calendar][hour]` → seconds.
    var heat: [(weekday: Int, hour: Int, weight: Double)] = []
    var total: Double = 0
    var systemTotal: Double = 0
    var activations = 0
    var capped = 0
    var medianSession: Double = 0
    var range: ClosedRange<Date>?
    /// (from app index << 32 | to app index) → count of "opened B right after A".
    var transitions: [UInt64: Int] = [:]
    var bundles: [String] = []
    var names: [String] = []
}

struct TransitionEdge: Identifiable, Sendable, Hashable {
    var id: String { bundle }
    let bundle: String
    let name: String
    let count: Int
}

struct AppDetail: Sendable {
    var row: AppUsageRow
    var daily: [ChartPoint] = []
    var hourly: [Double] = Array(repeating: 0, count: 24)
    var next: [TransitionEdge] = []
    var previous: [TransitionEdge] = []
    var recent: [TimelineBlock] = []
    /// DuetExpert's own decayed "launched next" scores (this Mac only).
    var atxNext: [(bundle: String, name: String, score: Double)] = []
    var atxInfo: ATXAppInfo?
}

struct TimelineBlock: Identifiable, Sendable, Hashable {
    let id: Int
    let bundle: String
    let name: String
    let start: Date
    let end: Date
    let isSystem: Bool
    let isCapped: Bool
    var duration: Double { end.timeIntervalSince(start) }
}

// MARK: - Pairing

/// Turns a time-ordered list of focus start / stop events into foreground sessions.
///
/// **Pairing rules** (shared by `App.InFocus` and `ScreenTime.AppUsage`):
///
/// 1. Events are sorted by their own timestamp (stable, so a stop and a start written with
///    the same timestamp keep their file order: stop first, then start).
/// 2. A *start* opens a session. If another session is still open — its stop was lost
///    because the segment was pruned, the device crashed, or the process was killed — that
///    session is closed at the new start time ("implied stop"): only one app can be
///    frontmost.
/// 3. A *stop* closes the open session only if it names the same bundle id. Stops without
///    a matching open session (start lost to pruning, duplicates) are counted and ignored.
/// 4. **Runaway cap**: an app session can last at most ``maxSession`` (the device slept or was
///    switched off without a stop record, and the next start comes hours or days later).
///    Longer sessions are truncated to the cap and flagged; they are counted separately so
///    the UI can say how much of the total is an estimate.
/// 5. Sessions shorter than ``minSession`` are dropped as flicker (apps that are passed
///    through while switching); they would inflate activation counts.
/// 6. A session still open at the end of the stream is closed at "now" for this Mac (it is
///    the app in front right now), subject to the cap, and dropped for remote devices
///    (there is no way to know when it ended).
/// 7. Lock screen, screen saver and SpringBoard scenes are kept as sessions (the timeline
///    shows them) but flagged as *system surfaces* and excluded from all usage totals.
struct FocusPairer {
    static let maxSession: Double = 4 * 3600
    static let minSession: Double = 0.5

    private(set) var focus = DeviceFocus()
    private var index: [String: Int32] = [:]
    private var openApp: Int32 = -1
    private var openStart: Double = 0

    mutating func appIndex(_ bundle: String) -> Int32 {
        if let i = index[bundle] { return i }
        let i = Int32(focus.bundles.count)
        index[bundle] = i
        focus.bundles.append(bundle)
        focus.names.append(AppNames.name(bundle))
        focus.systemFlags.append(AppNames.isSystemSurface(bundle))
        return i
    }

    private mutating func close(at end: Double, open stillOpen: Bool = false) {
        guard openApp >= 0 else { return }
        var e = end
        var flags: UInt8 = focus.systemFlags[Int(openApp)] ? 2 : 0
        // Lock screens are exempt from the cap: "locked until the next event" is accurate.
        if e - openStart > Self.maxSession, !AppNames.isLockSurface(focus.bundles[Int(openApp)]) {
            e = openStart + Self.maxSession
            flags |= 1
            focus.cappedSessions += 1
        }
        if stillOpen { flags |= 4 }
        if e - openStart >= Self.minSession {
            focus.sessions.append(FocusSession(app: openApp, flags: flags, start: openStart, end: e))
        } else {
            focus.droppedFlickers += 1
        }
        openApp = -1
    }

    mutating func add(time: Double, app: Int32, starting: Bool) {
        focus.eventCount += 1
        focus.firstEvent = min(focus.firstEvent ?? time, time)
        focus.lastEvent = max(focus.lastEvent ?? time, time)
        if starting {
            focus.startEvents += 1
            if openApp >= 0 {
                focus.impliedStops += 1
                close(at: time)
            }
            openApp = app
            openStart = time
        } else {
            focus.stopEvents += 1
            if openApp == app {
                close(at: time)
            } else {
                focus.unmatchedStops += 1
            }
        }
    }

    mutating func finish(isLocal: Bool, now: Double) -> DeviceFocus {
        if openApp >= 0 {
            if isLocal, now > openStart { close(at: now, open: true) } else { openApp = -1 }
        }
        return focus
    }
}

/// Raw focus event before pairing.
struct RawFocusEvent {
    var time: Double
    var app: Int32
    var starting: Bool
}

// MARK: - Calendar helper

/// Maps Cocoa timestamps to local calendar days quickly: `Calendar` is consulted only when
/// a timestamp leaves the cached day.
struct DayCursor {
    let calendar: Calendar
    private(set) var dayStart: Double = 1
    private(set) var dayEnd: Double = 0
    private(set) var weekday = 1

    init(calendar: Calendar = .current) { self.calendar = calendar }

    mutating func seek(_ t: Double) {
        if t >= dayStart && t < dayEnd { return }
        let date = Date(timeIntervalSinceReferenceDate: t)
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        dayStart = start.timeIntervalSinceReferenceDate
        dayEnd = end.timeIntervalSinceReferenceDate
        weekday = calendar.component(.weekday, from: start)
    }
}
