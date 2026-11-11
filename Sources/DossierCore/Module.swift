import SwiftUI

/// How private a displayed value is. Drives ``SensitivityBadge`` and Privacy Mode.
public enum Sensitivity: Int, Sendable, Comparable, CaseIterable, Hashable {
    /// Generic / technical information (counts, store names, Apple identifiers).
    case low = 0
    /// Information about the owner's behaviour or content (app usage, topics, titles).
    case personal = 1
    /// Highly private: message text, contacts, locations, health, identity documents.
    case sensitive = 2

    public static func < (a: Sensitivity, b: Sensitivity) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .low: return "Technical"
        case .personal: return "Personal"
        case .sensitive: return "Sensitive"
        }
    }

    public var symbol: String {
        switch self {
        case .low: return "gearshape"
        case .personal: return "person"
        case .sensitive: return "lock.shield"
        }
    }

    public var tint: Color {
        switch self {
        case .low: return .secondary
        case .personal: return .blue
        case .sensitive: return .orange
        }
    }
}

/// Sidebar grouping of modules. Use one of the presets so the sidebar stays coherent.
public struct SidebarGroup: Sendable, Hashable, Identifiable {
    public var id: String { title }
    public let title: String
    /// Sort order of the group in the sidebar (ascending).
    public let order: Int

    public init(title: String, order: Int) { self.title = title; self.order = order }

    public static let identity = SidebarGroup(title: "Identity & Knowledge", order: 10)
    public static let people = SidebarGroup(title: "People & Communication", order: 20)
    public static let behaviour = SidebarGroup(title: "Behaviour", order: 30)
    public static let media = SidebarGroup(title: "Media", order: 40)
    public static let raw = SidebarGroup(title: "Raw Data", order: 90)
}

/// A navigation target handed to a section view: set when the user picks a search hit (or
/// follows a cross-module link). Read it with `@Environment(\.deepLink)`.
public struct DeepLink: Sendable, Hashable {
    /// Target section (``ModuleSection/id``).
    public let sectionID: String
    /// Opaque, module-defined payload (the ``SearchHit/payload``).
    public let payload: String
    /// Changes for every navigation so `.onChange` / `.task(id:)` fire even for the same payload.
    public let nonce: UUID

    public init(sectionID: String, payload: String, nonce: UUID = UUID()) {
        self.sectionID = sectionID; self.payload = payload; self.nonce = nonce
    }
}

/// One page of a module, shown as a sidebar row.
public struct ModuleSection: Identifiable {
    /// Globally unique, stable id: `"<moduleID>.<name>"` (used for deep links, state
    /// restoration and `--snapshot`).
    public let id: String
    public let title: String
    /// SF Symbol name.
    public let symbol: String
    /// Builds the section's root view. Called on the main actor each time the section is
    /// shown; keep it cheap and load data inside the view (``AsyncContent`` / ``PagedTable``).
    public let makeView: @MainActor () -> AnyView
    /// Deep-link payloads (``DeepLink/payload``) that put the section into further states
    /// `--uitest` should lay out and capture besides the default one — typically one per
    /// tab or mode behind an in-section picker. The section must handle them through
    /// `@Environment(\.deepLink)`. Generic values only (mode names), never personal data.
    public var uiTestPayloads: [String]

    public init<V: View>(id: String, title: String, symbol: String, uiTestPayloads: [String] = [], @ViewBuilder view: @escaping @MainActor () -> V) {
        self.id = id; self.title = title; self.symbol = symbol
        self.uiTestPayloads = uiTestPayloads
        self.makeView = { AnyView(view()) }
    }
}

/// A data store a module reads, for the Overview dashboard.
public struct StoreInfo: Identifiable, Sendable, Hashable {
    public var id: String { path.path + "|" + name }
    public var name: String
    public var path: URL
    public var sizeBytes: Int64?
    public var rowCount: Int?
    public var timeRange: ClosedRange<Date>?
    public var availability: Availability
    public var note: String?

    public init(name: String, path: URL, sizeBytes: Int64? = nil, rowCount: Int? = nil, timeRange: ClosedRange<Date>? = nil, availability: Availability = .available, note: String? = nil) {
        self.name = name; self.path = path; self.sizeBytes = sizeBytes; self.rowCount = rowCount
        self.timeRange = timeRange; self.availability = availability; self.note = note
    }

    /// Convenience for a single file: probes availability and size (incl. `-wal`/`-shm`).
    public static func file(_ name: String, _ url: URL?, rowCount: Int? = nil, timeRange: ClosedRange<Date>? = nil, note: String? = nil) -> StoreInfo {
        guard let url else {
            return StoreInfo(name: name, path: URL(fileURLWithPath: "/"), availability: .missing, note: note)
        }
        let availability = Paths.probe(url)
        return StoreInfo(name: name, path: url, sizeBytes: availability.isAvailable ? FileProbe.databaseSize(url) : nil, rowCount: rowCount, timeRange: timeRange, availability: availability, note: note)
    }

    /// Convenience for a directory store: probes availability and sums the size of every
    /// file below it (walks the tree — call off the main actor).
    public static func directory(_ name: String, _ url: URL?, rowCount: Int? = nil, timeRange: ClosedRange<Date>? = nil, note: String? = nil) -> StoreInfo {
        guard let url else {
            return StoreInfo(name: name, path: URL(fileURLWithPath: "/"), availability: .missing, note: note)
        }
        let availability = Paths.probe(url)
        return StoreInfo(name: name, path: url, sizeBytes: availability.isAvailable ? FileProbe.directorySize(url).bytes : nil, rowCount: rowCount, timeRange: timeRange, availability: availability, note: note)
    }
}

/// A headline "the system holds this about you" statement for the Overview.
public struct Fact: Identifiable, Sendable, Hashable {
    public var id: String { label + "|" + value }
    public var label: String
    public var value: String
    public var sensitivity: Sensitivity
    /// Optional SF Symbol.
    public var symbol: String?
    /// Optional section to open when the fact is clicked.
    public var sectionID: String?

    public init(_ label: String, _ value: String, sensitivity: Sensitivity = .personal, symbol: String? = nil, sectionID: String? = nil) {
        self.label = label; self.value = value; self.sensitivity = sensitivity
        self.symbol = symbol; self.sectionID = sectionID
    }
}

public struct ModuleSummary: Sendable {
    public var stores: [StoreInfo]
    public var facts: [Fact]

    public init(stores: [StoreInfo] = [], facts: [Fact] = []) {
        self.stores = stores; self.facts = facts
    }

    public static let empty = ModuleSummary()
}

/// A global-search result.
public struct SearchHit: Identifiable, Sendable, Hashable {
    public let id: String
    public var title: String
    public var subtitle: String
    public var moduleID: String
    /// Section that can display the hit.
    public var sectionID: String
    /// Opaque selection payload delivered to the section as ``DeepLink/payload``.
    public var payload: String
    public var symbol: String?
    public var sensitivity: Sensitivity

    public init(id: String? = nil, title: String, subtitle: String = "", moduleID: String, sectionID: String, payload: String = "", symbol: String? = nil, sensitivity: Sensitivity = .personal) {
        self.id = id ?? "\(sectionID)|\(payload)|\(title)"
        self.title = title; self.subtitle = subtitle; self.moduleID = moduleID
        self.sectionID = sectionID; self.payload = payload; self.symbol = symbol; self.sensitivity = sensitivity
    }
}

/// One line of `--selftest` output.
public struct SelfTestLine: Sendable, Hashable {
    public enum Status: String, Sendable { case pass = "PASS", warn = "WARN", fail = "FAIL", info = "INFO" }
    public var status: Status
    public var label: String
    public var detail: String

    public init(_ status: Status, _ label: String, _ detail: String = "") {
        self.status = status; self.label = label; self.detail = detail
    }

    public static func pass(_ label: String, _ detail: String = "") -> SelfTestLine { .init(.pass, label, detail) }
    public static func warn(_ label: String, _ detail: String = "") -> SelfTestLine { .init(.warn, label, detail) }
    public static func fail(_ label: String, _ detail: String = "") -> SelfTestLine { .init(.fail, label, detail) }
    public static func info(_ label: String, _ detail: String = "") -> SelfTestLine { .init(.info, label, detail) }
    /// PASS if `condition` holds, FAIL otherwise.
    public static func check(_ label: String, _ condition: Bool, _ detail: String = "") -> SelfTestLine {
        .init(condition ? .pass : .fail, label, detail)
    }
}

/// A feature module: a set of sidebar sections over one family of stores.
///
/// Implement as a `public final class` with no mutable shared state (or state protected by
/// an actor). All three async methods run off the main actor and must never block it; they
/// must tolerate missing / inaccessible stores (return empty results, mark stores
/// `.missing` / `.inaccessible`) and never throw.
public protocol DossierModule: AnyObject, Sendable {
    /// Stable lower-case id (`"graph"`, `"raw"`); prefix of all section ids.
    var id: String { get }
    var title: String { get }
    /// SF Symbol name.
    var symbol: String { get }
    var group: SidebarGroup { get }
    /// Sidebar rows. Section ids must be `"<id>.<name>"`.
    var sections: [ModuleSection] { get }

    /// Stores and headline facts for the Overview dashboard. Should finish within a few
    /// seconds: use cheap queries (`count(*)`, `min/max`), not full scans.
    func summary() async -> ModuleSummary

    /// Global search. Return at most `limit` hits; honour task cancellation.
    func search(_ query: String, limit: Int) async -> [SearchHit]

    /// Sanity checks printed by `--selftest`: store availability, schema probes, counts.
    func selfTest() async -> [SelfTestLine]
}

public extension DossierModule {
    func search(_ query: String, limit: Int) async -> [SearchHit] { [] }
    func selfTest() async -> [SelfTestLine] { [.info(title, "no self-test implemented")] }
}

/// Error type modules can throw from loaders to get the right placeholder in
/// ``AsyncContent`` / ``PagedTable``.
public enum DossierError: Error, LocalizedError, Sendable {
    /// The store exists but cannot be read (→ "No access" placeholder with FDA hint).
    case inaccessible(String)
    /// The store / table does not exist on this macOS version (→ "Not available").
    case missing(String)
    /// Anything else, with a user-presentable message.
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .inaccessible(let m), .missing(let m), .message(let m): return m
        }
    }
}
