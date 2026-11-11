import Foundation

/// Conversions between the timestamp encodings used by Apple's on-device stores.
///
/// - Cocoa / CFAbsoluteTime: seconds since 2001-01-01 00:00:00 UTC (CoreData, Biome, graph.db)
/// - Unix: seconds since 1970-01-01 (some caches), also milliseconds / microseconds / nanoseconds
/// - WebKit: microseconds since 1601-01-01 (Chromium-derived stores)
public enum DossierDate {
    /// Seconds between 1970-01-01 and 2001-01-01.
    public static let cocoaEpochOffset: TimeInterval = 978_307_200
    /// Seconds between 1601-01-01 and 1970-01-01.
    public static let webKitEpochOffset: TimeInterval = 11_644_473_600

    /// A plausible range for "this is a timestamp about the user's device" (2005 ... now + 5y).
    public static var plausibleRange: ClosedRange<Date> {
        Date(timeIntervalSince1970: 1_104_537_600)...Date().addingTimeInterval(5 * 365 * 86_400)
    }

    public static func isPlausible(_ date: Date) -> Bool { plausibleRange.contains(date) }

    /// Seconds since 2001 → Date.
    public static func cocoa(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }
    public static func cocoa(_ seconds: Int64) -> Date { Date(timeIntervalSinceReferenceDate: Double(seconds)) }
    /// Optional convenience (nil / 0 → nil). Disfavoured so that a non-optional `Double`
    /// argument resolves to the non-optional overload instead of being ambiguous.
    @_disfavoredOverload
    public static func cocoa(_ seconds: Double?) -> Date? {
        guard let seconds, seconds != 0 else { return nil }
        return cocoa(seconds)
    }

    /// Seconds since 1970 → Date.
    public static func unix(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    /// For columns that hold Unix seconds on some macOS versions and Cocoa seconds on
    /// others (Biome `sync.db` mixes both): values beyond 1.2e9 are read as Unix time
    /// (a Cocoa value that large would lie after 2039). Nil for 0, negative, non-finite
    /// or implausible results.
    public static func cocoaOrUnix(_ seconds: Double?) -> Date? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let date = seconds > 1.2e9 ? unix(seconds) : cocoa(seconds)
        return isPlausible(date) ? date : nil
    }
    public static func unixMillis(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1_000) }
    public static func unixMicros(_ us: Int64) -> Date { Date(timeIntervalSince1970: Double(us) / 1_000_000) }
    public static func unixNanos(_ ns: Int64) -> Date { Date(timeIntervalSince1970: Double(ns) / 1_000_000_000) }

    /// Microseconds since 1601 → Date.
    public static func webKit(_ micros: Int64) -> Date {
        Date(timeIntervalSince1970: Double(micros) / 1_000_000 - webKitEpochOffset)
    }

    /// Guesses the encoding of a numeric timestamp and returns a date if one of the known
    /// encodings lands in ``plausibleRange``. Order: Cocoa seconds, Unix seconds, Unix ms,
    /// Unix µs, Cocoa ns, Unix ns, WebKit µs.
    public static func guess(_ value: Double) -> (date: Date, encoding: String)? {
        guard value.isFinite, value > 0 else { return nil }
        let candidates: [(Date, String)] = [
            (cocoa(value), "Cocoa s"),
            (unix(value), "Unix s"),
            (unix(value / 1_000), "Unix ms"),
            (unix(value / 1_000_000), "Unix µs"),
            (cocoa(value / 1_000_000_000), "Cocoa ns"),
            (unix(value / 1_000_000_000), "Unix ns"),
            (unix(value / 1_000_000 - webKitEpochOffset), "WebKit µs"),
        ]
        // Cocoa seconds for small values would map everything after 2005 (> 1.26e8); prefer
        // tighter "recent" plausibility (2008+) to reduce false positives on plain integers.
        let lower = Date(timeIntervalSince1970: 1_199_145_600)
        for (date, name) in candidates where date >= lower && date <= plausibleRange.upperBound {
            return (date, name)
        }
        return nil
    }

    // MARK: Formatting

    private static let mediumFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let sortableFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// "11 Nov 2026 at 10:55:12" (locale dependent).
    public static func medium(_ date: Date?) -> String { date.map(mediumFormatter.string(from:)) ?? "—" }
    /// "11.11.26, 10:55" (locale dependent).
    public static func short(_ date: Date?) -> String { date.map(shortFormatter.string(from:)) ?? "—" }
    /// Date only.
    public static func day(_ date: Date?) -> String { date.map(dayFormatter.string(from:)) ?? "—" }
    /// ISO-8601, UTC.
    public static func iso(_ date: Date?) -> String { date.map(isoFormatter.string(from:)) ?? "—" }
    /// "2026-11-11 10:55:12" in local time; sorts lexicographically. Use for copy / export
    /// and raw views; for table cells prefer ``table(_:)`` (`PagedColumn.date`).
    public static func sortable(_ date: Date?) -> String { date.map(sortableFormatter.string(from:)) ?? "—" }

    private static func templateFormatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }
    // "j" = the locale's preferred hour cycle (24 h or am/pm).
    private static let tableThisYearFormatter = templateFormatter("dMMMjmm")
    private static let tableOtherYearFormatter = templateFormatter("dMMMyyyyjmm")
    private static let tableLock = NSLock()
    nonisolated(unsafe) private static var tableYear: (start: Date, end: Date) = (.distantPast, .distantPast)

    /// Compact localized timestamp for table cells: "11 Nov, 16:29" within the current
    /// year, "11 Nov 2025, 16:29" otherwise (order and separators follow the user's
    /// locale). Pair it with ``medium(_:)`` in the tooltip and ``sortable(_:)`` for export —
    /// `PagedColumn.date` does all three.
    public static func table(_ date: Date?) -> String {
        guard let date else { return "—" }
        let year = tableLock.withLock { () -> (start: Date, end: Date) in
            let now = Date()
            if now < tableYear.start || now >= tableYear.end,
               let interval = Calendar.current.dateInterval(of: .year, for: now) {
                tableYear = (interval.start, interval.end)
            }
            return tableYear
        }
        let thisYear = date >= year.start && date < year.end
        return (thisYear ? tableThisYearFormatter : tableOtherYearFormatter).string(from: date)
    }
    /// Alias of ``table(_:)``.
    public static func tableString(_ date: Date?) -> String { table(date) }

    /// "3 days ago".
    public static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        if abs(date.timeIntervalSinceNow) < 90 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// "12 Mar 2024 – 11 Nov 2026".
    public static func range(_ range: ClosedRange<Date>?) -> String {
        guard let range else { return "—" }
        let a = day(range.lowerBound), b = day(range.upperBound)
        return a == b ? a : "\(a) – \(b)"
    }
}

/// Formatting helpers for counts, byte sizes and durations.
public enum Format {
    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    /// "1,234,567".
    public static func count(_ n: Int) -> String { countFormatter.string(from: NSNumber(value: n)) ?? "\(n)" }
    public static func count(_ n: Int64) -> String { count(Int(n)) }
    public static func count(_ n: Int?) -> String { n.map { count($0) } ?? "—" }

    /// "1.2M", "34K", "512".
    public static func compact(_ n: Int) -> String {
        let v = Double(n)
        switch abs(v) {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 10_000...: return String(format: "%.0fK", v / 1_000)
        case 1_000...: return String(format: "%.1fK", v / 1_000)
        default: return "\(n)"
        }
    }

    /// "1.5 GB".
    public static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
    public static func bytes(_ n: Int) -> String { bytes(Int64(n)) }
    public static func bytes(_ n: Int64?) -> String { n.map { bytes($0) } ?? "—" }

    /// "2h 5m", "45s", "1d 3h".
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "—" }
        let s = Int(seconds.rounded())
        if s < 1 { return seconds > 0 ? String(format: "%.0f ms", seconds * 1000) : "0s" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        if s < 86_400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86_400)d \((s % 86_400) / 3600)h"
    }

    /// "42.5%".
    public static func percent(_ fraction: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f%%", fraction * 100)
    }

    /// Fixed-point number without trailing zeros noise: 0.5, 12.25, 3.
    public static func number(_ v: Double, maxDigits: Int = 3) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = maxDigits
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// Collapses whitespace/newlines and truncates to `max` characters (for table cells).
    public static func oneLine(_ s: String, max: Int = 300) -> String {
        var out = String()
        out.reserveCapacity(min(s.utf8.count, max + 1))
        var count = 0
        var lastWasSpace = false
        for ch in s {
            if count >= max { out.append("…"); break }
            if ch.isNewline || ch.isWhitespace {
                if !lastWasSpace { out.append(" "); count += 1 }
                lastWasSpace = true
            } else {
                out.append(ch); count += 1
                lastWasSpace = false
            }
        }
        return out
    }

    /// Path with the home directory abbreviated to "~".
    public static func tildePath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
