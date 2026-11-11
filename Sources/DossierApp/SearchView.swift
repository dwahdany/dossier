import SwiftUI
import DossierCore

/// Runs global search: every module's `search()` concurrently, results grouped by module.
@MainActor
final class SearchCoordinator: ObservableObject {
    static let shared = SearchCoordinator()

    struct Group: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let hits: [SearchHit]
    }

    @Published var groups: [Group] = []
    @Published var isSearching = false
    @Published var query = ""
    private var generation = 0

    static let perModuleLimit = 40

    func run(_ query: String, modules: [any DossierModule]) async {
        generation += 1
        let gen = generation
        self.query = query
        isSearching = true
        groups = []
        await withTaskGroup(of: (Int, [SearchHit]).self) { group in
            for (index, module) in modules.enumerated() {
                group.addTask { (index, await module.search(query, limit: SearchCoordinator.perModuleLimit)) }
            }
            // Publish each module's hits as soon as they arrive, in registry order.
            var collected: [Int: [SearchHit]] = [:]
            for await (index, hits) in group {
                guard gen == generation, !Task.isCancelled else { return }
                collected[index] = hits
                groups = collected.keys.sorted().compactMap { i in
                    guard let hits = collected[i], !hits.isEmpty else { return nil }
                    let module = modules[i]
                    return Group(id: module.id, title: module.title, symbol: module.symbol, hits: hits)
                }
            }
        }
        if gen == generation { isSearching = false }
    }

    func openFirst(_ state: AppState) {
        if let first = groups.first?.hits.first { state.open(first) }
    }
}

struct SearchResultsView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var coordinator = SearchCoordinator.shared
    @State private var selection: String?

    private var query: String { state.searchText.trimmingCharacters(in: .whitespaces) }

    private func hit(_ id: String?) -> SearchHit? {
        guard let id else { return nil }
        for group in coordinator.groups {
            if let hit = group.hits.first(where: { $0.id == id }) { return hit }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if coordinator.groups.isEmpty {
                if coordinator.isSearching || coordinator.query != query {
                    LoadingPlaceholder("Searching all stores…")
                } else if query.count < 2 {
                    StatePlaceholder(title: "Keep Typing", symbol: "magnifyingglass", message: "Enter at least two characters.")
                } else {
                    StatePlaceholder(title: "No Results", symbol: "magnifyingglass", message: "Nothing in any store matches “\(query)”.")
                }
            } else {
                List(selection: $selection) {
                    ForEach(coordinator.groups) { group in
                        Section {
                            ForEach(group.hits) { hit in
                                SearchHitRow(hit: hit).tag(hit.id)
                            }
                        } header: {
                            Label("\(group.title) — \(group.hits.count)\(group.hits.count >= SearchCoordinator.perModuleLimit ? "+" : "")", systemImage: group.symbol)
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let hit = hit(ids.first) {
                        Button("Open") { state.open(hit) }
                        Button("Copy Title") { Pasteboard.copy(hit.title) }
                    }
                } primaryAction: { ids in
                    if let hit = hit(ids.first) { state.open(hit) }
                }
            }
            Divider()
            HStack(spacing: 8) {
                if coordinator.isSearching { ProgressView().controlSize(.mini) }
                Text("\(Format.count(coordinator.groups.reduce(0) { $0 + $1.hits.count })) results in \(coordinator.groups.count) module\(coordinator.groups.count == 1 ? "" : "s")")
                Spacer()
                Text("Double-click or press Return to open")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: Metrics.barHeight - 4)
            .background(.bar)
        }
        .task(id: query) {
            guard query.count >= 2 else {
                coordinator.groups = []
                coordinator.query = query
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await coordinator.run(query, modules: state.modules)
        }
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: hit.symbol ?? "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.title).font(.callout.weight(.medium)).lineLimit(1).sensitive(hit.sensitivity)
                if !hit.subtitle.isEmpty {
                    Text(hit.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).sensitive(hit.sensitivity)
                }
            }
            Spacer(minLength: 8)
            if hit.sensitivity > .low { SensitivityBadge(hit.sensitivity, compact: true) }
        }
        .padding(.vertical, 2)
    }
}
