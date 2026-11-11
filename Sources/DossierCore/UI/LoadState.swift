import SwiftUI

/// The lifecycle of asynchronously loaded content.
public enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    /// Loaded fine but there is nothing to show (optional explanation).
    case empty(String?)
    /// The store exists but cannot be read (Full Disk Access).
    case inaccessible(String)
    /// The store / table does not exist on this Mac.
    case missing(String)
    case failed(String)

    public var value: Value? {
        if case .loaded(let v) = self { return v }
        return nil
    }

    public var isLoading: Bool {
        switch self {
        case .idle, .loading: return true
        default: return false
        }
    }

    /// The explanation carried by a non-loaded state, if any.
    public var message: String? {
        switch self {
        case .empty(let m): return m
        case .inaccessible(let m), .missing(let m), .failed(let m): return m
        case .idle, .loading, .loaded: return nil
        }
    }

    /// Maps an error thrown by a loader to the matching state.
    public static func from(error: Error) -> LoadState<Value> {
        if let e = error as? DossierError {
            switch e {
            case .inaccessible(let m): return .inaccessible(m)
            case .missing(let m): return .missing(m)
            case .message(let m): return .failed(m)
            }
        }
        if let e = error as? SQLiteError {
            switch e {
            case .inaccessible(_, let m): return .inaccessible(m)
            case .missing: return .missing(e.localizedDescription)
            default: return .failed(e.localizedDescription)
            }
        }
        return .failed(error.localizedDescription)
    }
}

// MARK: - Environment

private struct PrivacyModeKey: EnvironmentKey { static let defaultValue = false }
private struct RefreshTokenKey: EnvironmentKey { static let defaultValue = 0 }
private struct DeepLinkKey: EnvironmentKey { static let defaultValue: DeepLink? = nil }
private struct NavigateKey: EnvironmentKey { static let defaultValue: (@MainActor (DeepLink) -> Void)? = nil }

public extension EnvironmentValues {
    /// Global Privacy Mode: when true, values marked `.sensitive(...)` are redacted.
    var privacyMode: Bool {
        get { self[PrivacyModeKey.self] }
        set { self[PrivacyModeKey.self] = newValue }
    }

    /// Incremented by the toolbar's Refresh button. ``AsyncContent`` and ``PagedTable``
    /// reload automatically when it changes; custom loaders should use it in `.task(id:)`.
    var refreshToken: Int {
        get { self[RefreshTokenKey.self] }
        set { self[RefreshTokenKey.self] = newValue }
    }

    /// The pending navigation payload for the visible section (from global search), if any.
    var deepLink: DeepLink? {
        get { self[DeepLinkKey.self] }
        set { self[DeepLinkKey.self] = newValue }
    }

    /// Navigates the app to another section (cross-module links). Nil in snapshots.
    var navigate: (@MainActor (DeepLink) -> Void)? {
        get { self[NavigateKey.self] }
        set { self[NavigateKey.self] = newValue }
    }
}

// MARK: - Snapshot readiness

/// Tracks outstanding asynchronous loads so the offscreen snapshot harness knows when a
/// view has settled. ``AsyncContent`` and ``PagedTable`` report automatically; custom
/// loaders can bracket their work with ``begin()`` / ``end()`` or use ``track(_:)``.
@MainActor
public enum SnapshotReadiness {
    public private(set) static var pending = 0
    /// Total number of loads started (lets the harness detect "nothing ever loaded").
    public private(set) static var started = 0
    public private(set) static var lastChange = Date()
    /// True while the process renders an offscreen `--snapshot` (never in the live app).
    /// Views backed by GPU layers that an offscreen capture cannot see (MapKit) use it to
    /// substitute a static rendering; see ``PointMapView``.
    public internal(set) static var isSnapshotting = false

    public static func begin() { pending += 1; started += 1; lastChange = Date() }
    public static func end() { pending = max(0, pending - 1); lastChange = Date() }

    /// Runs `work` while counting it as an outstanding load.
    public static func track<T>(_ work: () async throws -> T) async rethrows -> T {
        begin()
        defer { end() }
        return try await work()
    }
}

// MARK: - Cancellable background work

/// Runs `work` on a detached task (off the caller's actor) and **forwards cancellation**:
/// when the calling task is cancelled, the detached task is cancelled too, so
/// `Task.isCancelled` / `Task.checkCancellation()` inside `work` fire and a running
/// ``SQLiteDB`` statement is interrupted.
///
/// Use this instead of `try await Task.detached { … }.value`, which keeps running to
/// completion after the caller has been cancelled (an unstructured task does not inherit
/// cancellation) and keeps the store's serial connection busy for the next query.
public func cancellableDetached<T: Sendable>(
    priority: TaskPriority? = nil,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    let task = Task.detached(priority: priority) { try await work() }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

// MARK: - AsyncContent

/// Loads a value off the main actor and renders loading / empty / error / inaccessible
/// placeholders consistently.
///
/// ```swift
/// AsyncContent(reloadKey: selectedPerson) {
///     try await store.loadPerson(selectedPerson)          // runs off the main actor
/// } isEmpty: { $0.rows.isEmpty } content: { person in
///     PersonView(person)
/// }
/// ```
/// Reloads when `reloadKey` or the environment's `refreshToken` changes. The previous
/// load is cancelled (as is the current one when the view disappears): the loader's task
/// is cancelled, so its `Task.isCancelled` checks fire and running SQLite statements are
/// interrupted.
public struct AsyncContent<Value: Sendable, Content: View>: View {
    private let reloadKey: AnyHashable
    private let emptyTitle: String
    private let emptySymbol: String
    private let load: @Sendable () async throws -> Value
    private let isEmpty: (Value) -> Bool
    private let content: (Value) -> Content

    @State private var state: LoadState<Value> = .idle
    @Environment(\.refreshToken) private var refreshToken

    public init(
        reloadKey: AnyHashable = 0,
        emptyTitle: String = "Nothing Here",
        emptySymbol: String = "tray",
        load: @escaping @Sendable () async throws -> Value,
        isEmpty: @escaping (Value) -> Bool = { _ in false },
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.reloadKey = reloadKey
        self.emptyTitle = emptyTitle
        self.emptySymbol = emptySymbol
        self.load = load
        self.isEmpty = isEmpty
        self.content = content
    }

    private struct TaskKey: Hashable { let key: AnyHashable; let token: Int }

    public var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                LoadingPlaceholder()
            case .loaded(let value):
                content(value)
            case .empty(let message):
                StatePlaceholder(title: emptyTitle, symbol: emptySymbol, message: message)
            case .inaccessible(let message):
                StatePlaceholder.inaccessible(message)
            case .missing(let message):
                StatePlaceholder.missing(message)
            case .failed(let message):
                StatePlaceholder(title: "Couldn’t Load", symbol: "exclamationmark.triangle", message: message)
            }
        }
        .task(id: TaskKey(key: reloadKey, token: refreshToken)) {
            if state.value == nil { state = .loading }
            SnapshotReadiness.begin()
            defer { SnapshotReadiness.end() }
            let loader = load
            do {
                let value = try await cancellableDetached(priority: .userInitiated) { try await loader() }
                if Task.isCancelled { return }
                state = isEmpty(value) ? .empty(nil) : .loaded(value)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                state = .from(error: error)
            }
        }
    }
}

public extension AsyncContent where Value: Collection {
    /// Collection convenience: shows the empty placeholder for an empty collection.
    init(
        reloadKey: AnyHashable = 0,
        emptyTitle: String = "Nothing Here",
        emptySymbol: String = "tray",
        loadCollection: @escaping @Sendable () async throws -> Value,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.init(reloadKey: reloadKey, emptyTitle: emptyTitle, emptySymbol: emptySymbol, load: loadCollection, isEmpty: { $0.isEmpty }, content: content)
    }
}

// MARK: - Placeholders

/// Centered spinner used while content loads.
public struct LoadingPlaceholder: View {
    private let label: String?
    public init(_ label: String? = nil) { self.label = label }

    public var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            if let label {
                Text(label).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Centered icon + title + message placeholder (empty / error / missing / no access).
public struct StatePlaceholder: View {
    private let title: String
    private let symbol: String
    private let message: String?
    private let tint: Color

    public init(title: String, symbol: String, message: String? = nil, tint: Color = .secondary) {
        self.title = title; self.symbol = symbol; self.message = message; self.tint = tint
    }

    /// "No Access" placeholder with the Full Disk Access hint.
    public static func inaccessible(_ message: String? = nil) -> StatePlaceholder {
        StatePlaceholder(
            title: "No Access",
            symbol: "lock.fill",
            message: [message, "Grant Full Disk Access in System Settings › Privacy & Security, then relaunch."].compactMap { $0 }.joined(separator: "\n"),
            tint: .orange
        )
    }

    /// "Not on this Mac" placeholder for stores that do not exist.
    public static func missing(_ message: String? = nil) -> StatePlaceholder {
        StatePlaceholder(title: "Not on This Mac", symbol: "questionmark.folder", message: message ?? "This store does not exist on this macOS version.")
    }

    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(tint)
                .padding(.bottom, 2)
            Text(title).font(.title3.weight(.semibold))
            if let message, !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
