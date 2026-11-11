import SwiftUI
import AppKit
import DossierCore

// MARK: - Store locations

/// Store locations used only by this module (everything else comes from `Paths`).
enum CommsPaths {
    /// Siri Remembers materialized view (GRDB database built from the Biome
    /// `Siri.Remembers.*` streams).
    static var remembersView: URL {
        Paths.intelligencePlatformArtifacts.appendingPathComponent("siri/remembers/view.db")
    }

    /// The Mac's own call log (Phone / FaceTime calls placed or relayed on this Mac).
    static var callHistory: URL {
        Paths.library.appendingPathComponent("Application Support/CallHistoryDB/CallHistory.storedata")
    }

    /// CoreRecents database (recent correspondents of Mail, Calendar, Wallet …).
    static var recentsDB: URL { Paths.coreRecents.appendingPathComponent("Recents") }

    /// Directory holding the iCloud key-value service caches.
    static var kvsDirectory: URL? {
        Paths.daemonContainerData("com.apple.kvs")?.appendingPathComponent("com.apple.kvs", isDirectory: true)
    }

    /// All SQLite files of the key-value service (one per encryption class).
    static func kvsDatabases() -> [URL] {
        guard let dir = kvsDirectory,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension == "sqlite" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static let remembersStreams = [
        "Siri.Remembers.MessageHistory", "Siri.Remembers.CallHistory", "Siri.Remembers.InteractionHistory",
        "Siri.Remembers.AudioHistory", "Siri.Remembers.AssistantSuggestions",
    ]
}

/// Opens a store read-only through the shared pool, mapping problems to `DossierError` so
/// `AsyncContent` / `PagedTable` show the right placeholder.
enum CommsDB {
    static func open(_ url: URL?, _ name: String) async throws -> SQLiteDB {
        guard let url else { throw DossierError.missing("\(name) does not exist on this Mac.") }
        switch Paths.probe(url) {
        case .missing: throw DossierError.missing("\(name) does not exist on this Mac.")
        case .inaccessible(let reason): throw DossierError.inaccessible(reason)
        case .available: break
        }
        do {
            return try await SQLiteDB.shared(url)
        } catch let error as SQLiteError {
            if error.isAccessProblem { throw DossierError.inaccessible(error.localizedDescription) }
            throw DossierError.message(error.localizedDescription)
        }
    }

    static func openIfAvailable(_ url: URL?) async -> SQLiteDB? {
        guard let url, Paths.probe(url).isAvailable else { return nil }
        return try? await SQLiteDB.shared(url)
    }
}

// MARK: - Direction

enum CommDirection: Int, Sendable, Hashable, CaseIterable {
    case unspecified = 0, incoming = 1, outgoing = 2

    var label: String {
        switch self {
        case .unspecified: return "Unspecified"
        case .incoming: return "Incoming"
        case .outgoing: return "Outgoing"
        }
    }

    var short: String {
        switch self {
        case .unspecified: return "—"
        case .incoming: return "In"
        case .outgoing: return "Out"
        }
    }

    var symbol: String {
        switch self {
        case .unspecified: return "minus"
        case .incoming: return "arrow.down.left"
        case .outgoing: return "arrow.up.right"
        }
    }

    var tint: Color {
        switch self {
        case .unspecified: return .secondary
        case .incoming: return .blue
        case .outgoing: return .green
        }
    }

    /// Siri Remembers (`view.db` / Biome): 1 = incoming, 2 = outgoing. Verified against
    /// the same events in knowledgeC, where the flag is the other way round.
    static func remembers(_ raw: Int64?) -> CommDirection { CommDirection(rawValue: Int(raw ?? 0)) ?? .unspecified }

    /// `INInteractionDirection` (knowledgeC intents): 1 = outgoing, 2 = incoming.
    static func intent(_ raw: Int64?) -> CommDirection {
        switch raw {
        case 1: return .outgoing
        case 2: return .incoming
        default: return .unspecified
        }
    }
}

struct DirectionCell: View {
    let direction: CommDirection
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: direction.symbol).imageScale(.small).foregroundStyle(direction.tint)
            Text(direction.short).font(.callout)
        }
    }
}

// MARK: - App names

/// Bundle identifier → human app name (shared resolver: `DossierCore.AppDirectory`),
/// plus the app classes this module cares about.
enum AppNames {
    static func name(_ bundle: String?) -> String { AppDirectory.name(bundle, unknown: "Unknown app") }

    /// Apps whose "conversation title" is really a mail subject line.
    static let mailApps: Set<String> = [
        "com.google.Gmail", "com.apple.mobilemail", "com.apple.mail", "com.microsoft.Office.Outlook",
        "com.readdle.smartemail", "ch.protonmail.protonmail", "com.yahoo.Aerogram", "com.superhuman.Superhuman",
        "com.hey.app.ios", "com.fastmail.FastMail",
    ]

    /// Apps whose "conversation title" is the title of an issue / ticket / notification.
    static let trackerApps: Set<String> = [
        "com.linear.ios", "com.github.stormbreaker.prod", "com.atlassian.jira.app", "com.asana.app",
        "com.notion.id", "com.trello.trello", "com.gitlab.ios",
    ]
}

// MARK: - One-time-code heuristic

/// Flags text that looks like it carries a one-time code (OTP / TAN / verification code).
/// Purely generic: a short digit group next to a keyword such as "code" or "TAN" in a
/// handful of languages. No concrete values are known to the app.
enum CodeDetector {
    private static let digits = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\d.,:/+\-])(\d{4,8}|\d{3}[ \-]\d{3})(?![\p{L}\d]|[.,:/\-]\d)"#)
    private static let keywords = try! NSRegularExpression(
        pattern: #"\b(code|codes|otp|tan|mtan|pin|passcode|password|passwort|kennwort|verif\w*|bestätig\w*|sicherheits\w*|einmal\w*|one[- ]time|2fa|authenti\w*|confirm\w*|código|codigo|codice|token|zugangs\w*|freischalt\w*|anmelde\w*)\b"#,
        options: [.caseInsensitive])

    static func looksLikeCode(_ text: String) -> Bool {
        guard text.utf8.count <= 4_000 else { return false }
        let range = NSRange(text.startIndex..., in: text)
        guard digits.firstMatch(in: text, range: range) != nil else { return false }
        return keywords.firstMatch(in: text, range: range) != nil
    }
}

// MARK: - In-memory paging with typed sort keys

/// Pages / filters / sorts a small, already-loaded array for `PagedTable`'s fetch closure.
/// Unlike the built-in in-memory variant, numeric columns sort numerically.
struct MemoryTable<Row: Sendable>: Sendable {
    enum Key: Sendable {
        case text(@Sendable (Row) -> String)
        case number(@Sendable (Row) -> Double)
    }

    let rows: [Row]
    let search: @Sendable (Row) -> String
    let keys: [String: Key]

    private func view(_ request: PageRequest) -> [Row] {
        var result = rows
        let needle = request.search.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            result = result.filter { search($0).range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        if let sort = request.sort, let key = keys[sort.columnID] {
            switch key {
            case .text(let f):
                result.sort {
                    let r = f($0).compare(f($1), options: [.caseInsensitive, .numeric])
                    return sort.ascending ? r == .orderedAscending : r == .orderedDescending
                }
            case .number(let f):
                result.sort { sort.ascending ? f($0) < f($1) : f($0) > f($1) }
            }
        }
        return result
    }

    func page(_ request: PageRequest) -> [Row] {
        let all = view(request)
        guard request.offset < all.count else { return [] }
        return Array(all[request.offset..<min(all.count, request.offset + request.limit)])
    }

    func count(_ request: PageRequest) -> Int { view(request).count }
}

// MARK: - SQL snippets

enum CommsSQL {
    /// `strftime` modifiers turning a Cocoa-epoch column into local time.
    static func local(_ column: String) -> String { "\(column) + 978307200, 'unixepoch', 'localtime'" }

    /// "YYYY-MM" → first day of that month (local calendar).
    static func monthDate(_ key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count >= 2, let y = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return Calendar.current.date(from: DateComponents(year: y, month: m, day: parts.count > 2 ? Int(parts[2]) ?? 1 : 1))
    }

    /// Escapes `%`, `_` and `\` for a `LIKE ? ESCAPE '\'` pattern and wraps it in `%`.
    static func like(_ text: String) -> String {
        var out = ""
        for ch in text {
            if ch == "%" || ch == "_" || ch == "\\" { out.append("\\") }
            out.append(ch)
        }
        return "%" + out + "%"
    }
}

// MARK: - Small shared views

/// App name with the bundle id as tooltip.
struct AppCell: View {
    let bundle: String
    var body: some View {
        Text(AppNames.name(bundle)).font(.callout).lineLimit(1).help(bundle)
    }
}

/// A plain-English explanation block ("what is this store"), used at the top of sections.
struct ExplainerCard: View {
    let symbol: String
    let title: String
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card()
    }
}

/// Compact one-line explanation used in header strips above tables.
struct HeaderNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            .help(text)   // two lines can truncate at the minimum window width
    }
}

/// A dashboard summary stacked above a table. The summary keeps its natural height while
/// the table below still gets `minTableHeight`; in a shorter window the summary becomes a
/// vertically scrolling strip instead of squeezing the table down to its header.
struct SummaryOverTable<Summary: View, Table: View>: View {
    private let minTableHeight: CGFloat
    private let summary: Summary
    private let table: Table
    @State private var natural: CGFloat = 0
    @State private var available: CGFloat = 0

    init(minTableHeight: CGFloat = 250, @ViewBuilder summary: () -> Summary, @ViewBuilder table: () -> Table) {
        self.minTableHeight = minTableHeight
        self.summary = summary()
        self.table = table()
    }

    private var summaryHeight: CGFloat? {
        guard natural > 0, available > 0 else { return nil }
        return min(natural, max(available - minTableHeight - 1, 110))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                summary
                    .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { natural = $0 }
            }
            .frame(height: summaryHeight)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            table.frame(maxHeight: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.down) } action: { available = $0 }
    }
}

extension Date {
    var cocoa: Double { timeIntervalSinceReferenceDate }
}

func durationText(_ seconds: Double) -> String { seconds > 0 ? Format.duration(seconds) : "—" }
