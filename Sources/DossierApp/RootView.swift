import SwiftUI
import DossierCore

/// The main window: grouped sidebar, detail area, toolbar with global search.
struct RootView: View {
    @EnvironmentObject private var state: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    static let sidebarWidth: ClosedRange<CGFloat> = 200...340

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: RootView.sidebarWidth.lowerBound, ideal: 240, max: RootView.sidebarWidth.upperBound)
        } detail: {
            detail
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button { state.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                            .disabled(!state.canGoBack)
                            .help("Back (⌘[)")
                        Button { state.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                            .disabled(!state.canGoForward)
                            .help("Forward (⌘])")
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Toggle(isOn: $state.privacyMode) {
                            Label("Privacy Mode", systemImage: state.privacyMode ? "eye.slash.fill" : "eye")
                        }
                        .help("Privacy Mode: blur personal values for screen sharing (⇧⌘P)")
                        Button { state.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                            .help("Reload all data (⌘R)")
                    }
                }
        }
        .searchable(text: $state.searchText, isPresented: $state.searchPresented, placement: .toolbar, prompt: "Search all stores")
        .onSubmit(of: .search) { SearchCoordinator.shared.openFirst(state) }
        .environment(\.privacyMode, state.privacyMode)
        .environment(\.refreshToken, state.refreshToken)
        .environment(\.navigate, { link in state.navigate(link) })
    }

    @ViewBuilder private var detail: some View {
        let searching = !state.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        ZStack {
            if !state.hasFullDiskAccess && !state.permissionDismissed {
                PermissionView()
                    .navigationTitle("Dossier")
            } else {
                SectionStack()
                    .opacity(searching ? 0 : 1)
                    .allowsHitTesting(!searching)
                if searching {
                    SearchResultsView()
                        .navigationTitle("Search")
                        .navigationSubtitle("")
                }
            }
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("collapsedModules") private var collapsedRaw = ""

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { open in
                var set = collapsed
                if open { set.remove(id) } else { set.insert(id) }
                collapsedRaw = set.sorted().joined(separator: ",")
            }
        )
    }

    var body: some View {
        // A module's disclosure row is selectable in a sidebar List and carries the module id,
        // which is not a section: route it to the module's first section instead.
        List(selection: Binding<String?>(
            get: { state.selection },
            set: { new in
                guard let new else { return }
                if state.section(new) == nil, new != AppState.overviewID,
                   let first = state.modules.first(where: { $0.id == new })?.sections.first {
                    state.select(first.id)
                } else {
                    state.selection = new
                }
            }
        )) {
            Label("Overview", systemImage: "rectangle.3.group")
                .tag(AppState.overviewID)
            ForEach(state.groups, id: \.group) { entry in
                Section(entry.group.title) {
                    ForEach(entry.modules, id: \.id) { module in
                        let sections = module.sections
                        if sections.count == 1, let only = sections.first {
                            Label(only.title, systemImage: module.symbol).tag(only.id)
                        } else {
                            DisclosureGroup(isExpanded: expansion(module.id)) {
                                ForEach(sections) { section in
                                    Label(section.title, systemImage: section.symbol).tag(section.id)
                                }
                            } label: {
                                Label(module.title, systemImage: module.symbol)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .labelStyle(SidebarLabelStyle())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: state.hasFullDiskAccess ? "lock.open" : "lock.fill")
                    .foregroundStyle(state.hasFullDiskAccess ? Color.secondary : Color.orange)
                Text(state.hasFullDiskAccess ? (Paths.isDemo ? "Read-only" : "Read-only · on-device") : "Limited access")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                DemoBadge()
                if state.privacyMode {
                    Image(systemName: "eye.slash.fill").foregroundStyle(.secondary).help("Privacy Mode is on")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

/// Sidebar rows: icon in the accent colour, as a sidebar list draws them on screen.
/// Off-screen captures (`--screenshot`, `--uitest`, `--snapshot app`) draw the window
/// without the window server, so the sidebar's vibrancy is not composited and the
/// system-tinted icons come out grey in light mode and nearly black in dark mode; there
/// the tint is applied explicitly. On screen the system's own style is left alone.
struct SidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        if SnapshotReadiness.isSnapshotting {
            Label {
                configuration.title
            } icon: {
                configuration.icon.foregroundStyle(Color.accentColor)
            }
        } else {
            Label(configuration)
        }
    }
}

// MARK: - Section hosting

/// Hosts the selected section. Recently visited sections are kept alive (hidden) so their
/// state — selections, scroll positions, loaded pages — survives switching back and forth.
struct SectionStack: View {
    @EnvironmentObject private var state: AppState
    @State private var alive: [String] = []
    private let keepAlive = 4

    var body: some View {
        let current = state.selection ?? AppState.overviewID
        ZStack {
            ForEach(visibleIDs(current), id: \.self) { id in
                host(id)
                    .uiTestSection(id)
                    .containedSection(minimumWindow: DossierApplication.minimumSize, narrowestSidebar: RootView.sidebarWidth.lowerBound)
                    .opacity(id == current ? 1 : 0)
                    .allowsHitTesting(id == current)
                    .accessibilityHidden(id != current)
            }
        }
        .navigationTitle(title(current))
        .navigationSubtitle(subtitle(current))
        .onChange(of: current, initial: true) { _, new in
            var list = alive.filter { $0 != new }
            list.append(new)
            alive = Array(list.suffix(keepAlive))
        }
    }

    private func visibleIDs(_ current: String) -> [String] {
        alive.contains(current) ? alive : alive + [current]
    }

    private func title(_ id: String) -> String {
        id == AppState.overviewID ? "Overview" : (state.section(id)?.section.title ?? "Dossier")
    }

    private func subtitle(_ id: String) -> String {
        id == AppState.overviewID ? (Paths.isDemo ? "Demo data — an invented person" : "What this Mac knows about you") : (state.section(id)?.module.title ?? "")
    }

    @ViewBuilder private func host(_ id: String) -> some View {
        if id == AppState.overviewID {
            OverviewView(modules: state.modules)
        } else if let found = state.section(id) {
            found.section.makeView()
                .environment(\.deepLink, state.deepLink?.sectionID == id ? state.deepLink : nil)
        } else {
            StatePlaceholder(title: "Section Not Found", symbol: "questionmark.square.dashed", message: id)
        }
    }
}

// MARK: - First run / permission

/// Shown when Full Disk Access is missing.
struct PermissionView: View {
    @EnvironmentObject private var state: AppState
    @State private var confirmingContinue = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.orange)
            Text("Full Disk Access Needed").font(.title.weight(.semibold))
            Text("The stores Dossier reads — the knowledge graph, Biome streams, the Photos analysis and others — are protected by macOS. Without Full Disk Access they appear as inaccessible.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            HStack(alignment: .center, spacing: 18) {
                if AppDragPanel.isAvailable {
                    VStack(spacing: 4) {
                        AppIconDragSource()
                            .frame(width: 72, height: 72)
                            .help("Drag into the Full Disk Access list")
                        Text("Drag me").font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    if AppDragPanel.isAvailable {
                        step(1, "Open Privacy & Security. The Dossier icon follows the Settings window.")
                        step(2, "Drag the icon into the Full Disk Access list and switch it on.")
                        step(3, "Let macOS quit and reopen Dossier when it offers to.")
                    } else {
                        step(1, "Open System Settings › Privacy & Security › Full Disk Access.")
                        step(2, "Enable the terminal app Dossier was started from.")
                        step(3, "Quit and reopen the terminal, then choose Check Again.")
                    }
                }
            }
            .card()
            .frame(maxWidth: 560)
            // Notices the grant without the user having to press Check Again.
            .task {
                while !Task.isCancelled, !state.hasFullDiskAccess {
                    try? await Task.sleep(for: .seconds(1.5))
                    state.recheckAccess()
                }
                AppDragPanel.shared.close()
            }
            HStack(spacing: 10) {
                Button("Open Privacy & Security…") { state.openFullDiskAccessSettings() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Check Again") { state.recheckAccess() }
                    .controlSize(.large)
                // Nothing is read until the user confirms: a few stores live inside other
                // apps' containers, and reading those without Full Disk Access can make
                // macOS show its own "access data from other apps" alert.
                Button("Continue Without Access…") { confirmingContinue = true }
                    .controlSize(.large)
            }
            Label("Dossier only ever reads. It never modifies a store and never sends store content anywhere.", systemImage: "hand.raised")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Continue without Full Disk Access?", isPresented: $confirmingContinue) {
            Button("Continue") { state.permissionDismissed = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Most stores will be shown as inaccessible. Some stores are kept inside other apps' containers, so macOS may ask whether Dossier may access data from other apps. Declining is fine: those stores then appear as inaccessible too.")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.callout.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Text(text).font(.callout)
            Spacer(minLength: 0)
        }
    }
}
