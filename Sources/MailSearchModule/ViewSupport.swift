import SwiftUI
import DossierCore

// MARK: - Background job monitors

/// Publishes the state of the background mail index to SwiftUI (polls while building).
@MainActor
final class MailIndexMonitor: ObservableObject {
    static let shared = MailIndexMonitor()

    @Published private(set) var status = MailIndex.Status()
    @Published private(set) var insights: MailIndex.Insights?
    private var poller: Task<Void, Never>?
    private var tracking = false

    /// Picks up the index state without starting a build; resumes polling when a build
    /// started elsewhere is still running.
    func refresh() {
        Task {
            await pull()
            if status.phase == .building { start() }
        }
    }

    func start() {
        guard poller == nil else { return }
        if SnapshotReadiness.isSnapshotting, !tracking { tracking = true; SnapshotReadiness.begin() }
        poller = Task { [weak self] in
            await MailIndex.shared.start()
            while !Task.isCancelled {
                guard let self else { return }
                await self.pull()
                if self.status.phase != .building { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            self?.finish()
        }
    }

    func cancel() {
        Task { await MailIndex.shared.cancel() }
    }

    func sync(token: Int) {
        Task {
            await MailIndex.shared.sync(token: token)
            await pull()
        }
    }

    private func finish() {
        poller = nil
        if tracking { tracking = false; SnapshotReadiness.end() }
    }

    private func pull() async {
        let latest = await MailIndex.shared.currentStatus()
        if latest != status { status = latest }
        if latest.isReady {
            if insights == nil { insights = await MailIndex.shared.insights() }
        } else if insights != nil {
            insights = nil
        }
    }
}

/// Publishes the state of the hybrid-search file scan.
@MainActor
final class KuzuMonitor: ObservableObject {
    static let shared = KuzuMonitor()

    @Published private(set) var report = KuzuReport()
    private var poller: Task<Void, Never>?
    private var tracking = false

    func start() {
        guard poller == nil else { return }
        if SnapshotReadiness.isSnapshotting, !tracking { tracking = true; SnapshotReadiness.begin() }
        poller = Task { [weak self] in
            await KuzuScanner.shared.start()
            while !Task.isCancelled {
                guard let self else { return }
                self.report = await KuzuScanner.shared.current()
                if self.report.phase != .scanning { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            self?.finish()
        }
    }

    func cancel() {
        Task { await KuzuScanner.shared.cancel() }
    }

    /// Picks up the scanner's state (a scan started earlier may be running or finished)
    /// without starting one.
    func sync(token: Int) {
        Task {
            await KuzuScanner.shared.sync(token: token)
            report = await KuzuScanner.shared.current()
            if report.phase == .scanning || MSDebug.autoStartJobs { start() }
        }
    }

    func rescan() {
        Task {
            await KuzuScanner.shared.reset()
            poller?.cancel(); poller = nil
            start()
        }
    }

    private func finish() {
        poller = nil
        if tracking { tracking = false; SnapshotReadiness.end() }
    }
}

// MARK: - Small shared views

/// 46-pt strip at the top of a pane: icon, title, one-line explanation, trailing controls.
struct PaneHeader<Accessory: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(subtitle)
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension PaneHeader where Accessory == EmptyView {
    init(symbol: String, title: String, subtitle: String) {
        self.init(symbol: symbol, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Row of a master list: icon, title, optional secondary line and a trailing count.
struct MasterRow: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var count: String?
    var dimmed = false
    var sensitivity: Sensitivity = .low

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(dimmed ? .tertiary : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                // Wraps onto a second line in a narrow list rather than losing its middle.
                Text(title).font(.callout).lineLimit(2).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(dimmed ? .secondary : .primary)
                    .sensitive(sensitivity)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if let count {
                Text(count)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(dimmed ? .tertiary : .secondary)
            }
        }
        .padding(.vertical, 1)
        .help(title)
    }
}

/// A block of potentially very private text that is fetched and shown only on request.
struct RevealText: View {
    let label: String
    let reloadKey: AnyHashable
    let load: @Sendable () async throws -> String?

    private enum Phase { case hidden, loading, shown(String), none, failed(String) }
    @State private var phase: Phase = .hidden
    @State private var expanded = false

    private static let previewLimit = 6_000
    private var autoReveal: Bool { ProcessInfo.processInfo.environment["DOSSIER_MAILSEARCH_REVEAL"] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch phase {
            case .hidden:
                Button {
                    reveal()
                } label: {
                    Label("Reveal \(label)", systemImage: "eye")
                }
                .controlSize(.small)
            case .loading:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading \(label.lowercased())…").font(.caption).foregroundStyle(.secondary) }
            case .none:
                Label("No \(label.lowercased()) is cached for this item.", systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            case .shown(let text):
                let long = text.count > Self.previewLimit
                Text(long && !expanded ? String(text.prefix(Self.previewLimit)) + "…" : text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
                    .sensitive(.sensitive)
                HStack(spacing: 10) {
                    Text("\(Format.count(text.count)) characters").font(.caption).foregroundStyle(.tertiary)
                    if long {
                        Button(expanded ? "Show Less" : "Show All") { expanded.toggle() }.buttonStyle(.link).font(.caption)
                    }
                    Button("Copy") { Pasteboard.copy(text) }.buttonStyle(.link).font(.caption)
                    Button("Hide") { phase = .hidden; expanded = false }.buttonStyle(.link).font(.caption)
                }
            }
        }
        .onChange(of: reloadKey) { _, _ in
            phase = .hidden; expanded = false
            if autoReveal { reveal() }
        }
        .onAppear { if autoReveal, case .hidden = phase { reveal() } }
    }

    private func reveal() {
        phase = .loading
        let load = self.load
        let tracked = SnapshotReadiness.isSnapshotting
        if tracked { SnapshotReadiness.begin() }
        Task {
            defer { if tracked { SnapshotReadiness.end() } }
            do {
                if let text = try await Task.detached(operation: load).value, !text.isEmpty { phase = .shown(text) } else { phase = .none }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

/// Linear progress with label, counters and a Cancel button.
struct JobProgress: View {
    let title: String
    let detail: String
    let fraction: Double
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.callout)
                    Spacer()
                    Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                ProgressView(value: fraction)
            }
            Button("Cancel", action: onCancel).controlSize(.small)
        }
    }
}

/// Collapsible group inside an inspector.
struct InspectorDisclosure<Content: View>: View {
    let title: String
    @State var expanded: Bool
    @ViewBuilder var content: Content

    init(_ title: String, expanded: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self._expanded = State(initialValue: expanded)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    InspectorGroupTitle(title)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { content }
        }
    }
}

/// Simple grid table for dashboards (a handful of rows; not a PagedTable).
struct InfoTable: View {
    struct Column {
        let title: String
        var alignment: HorizontalAlignment = .leading
    }
    struct Row: Identifiable {
        let id: String
        var symbol: String?
        let cells: [String]
        var caption: String?
        var sensitivity: Sensitivity = .low
    }

    let columns: [Column]
    let rows: [Row]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    Text(column.title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(column.alignment)
                }
            }
            .padding(.bottom, 6)
            ForEach(rows) { row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow(alignment: .top) {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { index, cell in
                        if index == 0 {
                            HStack(alignment: .top, spacing: 8) {
                                if let symbol = row.symbol {
                                    Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cell).font(.callout.weight(.medium)).sensitive(row.sensitivity)
                                    if let caption = row.caption {
                                        Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(cell).font(.callout.monospacedDigit()).foregroundStyle(index == row.cells.count - 1 ? .secondary : .primary)
                        }
                    }
                }
                .padding(.vertical, 7)
            }
        }
    }
}

// MARK: - Adaptive layout

/// Size classes the sections of this module adapt to. The detail column of the minimum
/// window is about 680–780 pt wide and 560–600 pt high; fixed-size intros and master
/// lists designed for a large window leave almost nothing for the actual table there.
enum MSLayout {
    /// Below this height a section drops its intro paragraph and shows its headline
    /// numbers as a one-line strip (see ``PageIntro``).
    static let compactHeight: CGFloat = 740

    enum WidthClass: Int { case narrow, regular, wide }

    static func widthClass(_ width: CGFloat) -> WidthClass {
        width < 800 ? .narrow : (width < 1150 ? .regular : .wide)
    }
}

extension View {
    /// Sets `compact` while the view is lower than `threshold`. Attach it to a view that
    /// fills the height it is offered, so the result does not depend on `compact` itself.
    func tracksCompactHeight(_ compact: Binding<Bool>, below threshold: CGFloat = MSLayout.compactHeight) -> some View {
        onGeometryChange(for: Bool.self) { $0.size.height < threshold } action: { compact.wrappedValue = $0 }
    }

    /// Reports the width class of a view that fills the width it is offered.
    func tracksWidthClass(_ widthClass: Binding<MSLayout.WidthClass>) -> some View {
        onGeometryChange(for: MSLayout.WidthClass.self) { MSLayout.widthClass($0.size.width) } action: { widthClass.wrappedValue = $0 }
    }
}

/// Intro of a section that continues with a table: an explanatory paragraph and a row of
/// stat tiles. In a low window (`compact`) the paragraph moves behind an info button and
/// the tiles become a single strip, so the table below keeps most of the height.
struct PageIntro<Extra: View>: View {
    let text: String
    let stats: [Stat]
    let compact: Bool
    @ViewBuilder var extra: Extra
    @State private var showsText = false

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 0) {
                    ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                        if index > 0 { Divider().frame(height: 24).padding(.horizontal, 9) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stat.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Text(stat.value)
                                .font(.system(.callout, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                                .lineLimit(1)
                                .sensitive(stat.sensitivity)
                        }
                        .help(stat.caption.map { "\(stat.title): \($0)" } ?? stat.title)
                    }
                    Spacer(minLength: 8)
                    Button { showsText.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("About this store")
                        .popover(isPresented: $showsText, arrowEdge: .bottom) {
                            Text(text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 340, alignment: .leading)
                                .padding(14)
                        }
                }
                extra
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                StatTileRow(stats)
                extra
            }
            .padding(Metrics.pagePadding)
        }
    }
}

extension PageIntro where Extra == EmptyView {
    init(text: String, stats: [Stat], compact: Bool) {
        self.init(text: text, stats: stats, compact: compact) { EmptyView() }
    }
}
