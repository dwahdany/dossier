import SwiftUI
import AppKit
import DossierCore

/// The SwiftUI application (started by `main.swift` when no CLI flag is given).
struct DossierApplication: App {
    @NSApplicationDelegateAdaptor(DevAppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    static let minimumSize = CGSize(width: 980, height: 600)
    static let defaultSize = CGSize(width: 1360, height: 860)

    /// The main window's content. `--uitest` hosts exactly this view (see `AppUITestShell`),
    /// so the scene and the test cannot drift apart.
    static func windowContent(_ state: AppState) -> some View {
        RootView()
            .environmentObject(state)
            .frame(minWidth: minimumSize.width, minHeight: minimumSize.height)
    }

    var body: some Scene {
        Window("Dossier", id: "main") {
            DossierApplication.windowContent(state)
                .defaultAppStorage(AppState.preferences)
        }
        .defaultSize(width: DossierApplication.defaultSize.width, height: DossierApplication.defaultSize.height)
        .commands { DossierCommands(state: state) }

        Settings {
            SettingsView()
                .environmentObject(state)
                .defaultAppStorage(AppState.preferences)
        }
    }
}

/// Menu commands and keyboard shortcuts.
struct DossierCommands: Commands {
    @ObservedObject var state: AppState

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Dossier") { AboutPanel.show() }
        }
        CommandGroup(replacing: .newItem) {}
        SidebarCommands()
        CommandGroup(after: .sidebar) {
            Divider()
            Toggle("Privacy Mode", isOn: $state.privacyMode)
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Refresh") { state.refresh() }
                .keyboardShortcut("r")
            Divider()
        }
        CommandGroup(replacing: .printItem) {}
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(after: .textEditing) {
            Button("Search All Stores") { state.searchPresented = true }
                .keyboardShortcut("f")
        }
        CommandMenu("Go") {
            Button("Back") { state.goBack() }
                .keyboardShortcut("[")
                .disabled(!state.canGoBack)
            Button("Forward") { state.goForward() }
                .keyboardShortcut("]")
                .disabled(!state.canGoForward)
            Divider()
            Button("Next Section") { state.step(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Section") { state.step(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Divider()
            Button("Overview") { state.select(AppState.overviewID) }
                .keyboardShortcut("0")
            ForEach(Array(state.modules.prefix(9).enumerated()), id: \.offset) { index, module in
                Button(module.title) { if let first = module.sections.first?.id { state.select(first) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
        CommandGroup(replacing: .help) {
            Button("Grant Full Disk Access…") { state.openFullDiskAccessSettings() }
            Button("Check Access Again") { state.recheckAccess() }
            Divider()
            Button("Show Stores in Raw Explorer") { state.select("raw.stores") }
        }
    }
}

enum AboutPanel {
    @MainActor static func show() {
        let credits = NSAttributedString(
            string: "A read-only viewer for the knowledge and personalization data macOS keeps on this Mac.\nNothing is modified and no store content is sent anywhere. The only network use is Apple map tiles for the areas shown on maps.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Dossier",
            .applicationVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "development build",
            .version: "",
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Settings scene (⌘,).
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("privacyOnLaunch") private var privacyOnLaunch = false
    @AppStorage("restoreLastSection") private var restoreLastSection = true

    var body: some View {
        TabView {
            Form {
                Section {
                    Toggle("Start in Privacy Mode", isOn: $privacyOnLaunch)
                    Toggle("Privacy Mode", isOn: $state.privacyMode)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Privacy Mode blurs personal and sensitive values so the window can be shared on screen. It also replaces maps with a placeholder. Otherwise maps download map tiles from Apple for the area they show, which is the app's only network use; no store content is sent.")
                }
                Section("Navigation") {
                    Toggle("Reopen the last viewed section on launch", isOn: $restoreLastSection)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section {
                    LabeledContent("Full Disk Access") {
                        Label(state.hasFullDiskAccess ? "Granted" : "Not granted", systemImage: state.hasFullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(state.hasFullDiskAccess ? .green : .orange)
                    }
                    HStack {
                        Button("Open Privacy & Security…") { state.openFullDiskAccessSettings() }
                        Button("Check Again") { state.recheckAccess() }
                    }
                } header: {
                    Text("Access")
                } footer: {
                    Text("Dossier opens every store read-only. Without Full Disk Access most stores are shown as inaccessible, and macOS may ask whether Dossier may access data from other apps when a section reads a store inside another app's container. When launched from a terminal, the terminal app is the one that needs the permission.")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Access", systemImage: "lock.shield") }
        }
        .frame(width: 480, height: 340)
    }
}
