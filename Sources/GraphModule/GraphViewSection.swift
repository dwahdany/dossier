import SwiftUI
import AppKit
import DossierCore

// MARK: - Model

@MainActor
final class GraphViewModel: ObservableObject {
    @Published var scene = GraphScene()
    @Published var positions: [CGPoint] = []
    @Published var progress: Double = 0
    @Published var isLaidOut = false
    @Published var error: LoadState<Void>?
    @Published var layoutSeconds: Double = 0

    // View transform: screen = centre + offset + position × scale.
    @Published var scale: CGFloat = 1
    @Published var offset: CGSize = .zero
    @Published var hover: Int?
    @Published var selected: Int?
    /// Set once the user pans / zooms; stops automatic re-fitting.
    var userMoved = false
    /// True while the pointer is over the canvas (gates the scroll-wheel monitor).
    var mouseInside = false
    var canvasSize: CGSize = .zero

    private var generation = 0

    func load(options: GraphOptions, seed: UInt64) async {
        generation += 1
        let gen = generation
        isLaidOut = false
        progress = 0
        error = nil
        hover = nil
        let previousSelection = selected.flatMap { scene.nodes.indices.contains($0) ? scene.nodes[$0].id : nil }
        SnapshotReadiness.begin()
        defer { SnapshotReadiness.end() }
        do {
            let built = try await cancellableDetached(priority: .userInitiated) { try await GraphScene.build(options: options) }
            guard gen == generation, !Task.isCancelled else { return }
            scene = built
            positions = []
            selected = previousSelection.flatMap { id in built.nodes.firstIndex { $0.id == id } }
            userMoved = false
            let animate = !SnapshotReadiness.isSnapshotting
            let started = Date()
            var report: (@Sendable ([CGPoint], Double) -> Void)?
            if animate {
                report = { [weak self] (partial: [CGPoint], fraction: Double) in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, gen == self.generation, !self.isLaidOut else { return }
                            self.positions = partial
                            self.progress = fraction
                            if !self.userMoved { self.fit(animated: false) }
                        }
                    }
                }
            }
            let progressReport = report
            let task = Task.detached(priority: .userInitiated) { () -> [CGPoint] in
                ForceLayout.run(scene: built, seed: seed, progress: progressReport)
            }
            let final = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard gen == generation, !Task.isCancelled else { return }
            positions = final
            layoutSeconds = Date().timeIntervalSince(started)
            isLaidOut = true
            progress = 1
            if !userMoved { fit(animated: false) }
        } catch is CancellationError {
            return
        } catch {
            guard gen == generation else { return }
            self.error = LoadState<Void>.from(error: error)
        }
    }

    /// Width of one legend row; the legend card adds 10 pt padding and sits 12 pt from the edges.
    static let legendRowWidth: CGFloat = 190
    /// Strip at the canvas's leading edge covered by the legend card.
    static let legendInset: CGFloat = legendRowWidth + 20 + 12

    func fit(animated: Bool) {
        guard !positions.isEmpty, canvasSize.width > 40, canvasSize.height > 40 else { return }
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for p in positions { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        let w = max(maxX - minX, 60), h = max(maxY - minY, 60)
        // Keep the graph clear of the legend (bottom-leading) unless that would shrink it noticeably.
        let full = min((canvasSize.width - 90) / w, (canvasSize.height - 90) / h)
        let beside = min((canvasSize.width - Self.legendInset - 90) / w, (canvasSize.height - 90) / h)
        let inset: CGFloat = beside >= full * 0.7 ? Self.legendInset : 0
        let s = inset > 0 ? beside : full
        let newScale = min(max(s, 0.05), 2.2)
        let centre = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let newOffset = CGSize(width: -centre.x * newScale + inset / 2, height: -centre.y * newScale)
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) { scale = newScale; offset = newOffset }
        } else {
            scale = newScale; offset = newOffset
        }
    }

    func screenPoint(_ index: Int) -> CGPoint {
        let p = positions[index]
        return CGPoint(x: canvasSize.width / 2 + offset.width + p.x * scale, y: canvasSize.height / 2 + offset.height + p.y * scale)
    }

    func radius(_ node: SceneNode) -> CGFloat {
        let base = node.isOwner ? 9 : 3.4 + min(7, CGFloat(node.degree).squareRoot() * 1.5)
        return base * min(max(scale.squareRoot(), 0.55), 1.5)
    }

    func node(at point: CGPoint) -> Int? {
        guard positions.count == scene.nodes.count else { return nil }
        var best: Int?
        var bestDistance = CGFloat.infinity
        for i in scene.nodes.indices {
            let p = screenPoint(i)
            let dx = p.x - point.x, dy = p.y - point.y
            let d = dx * dx + dy * dy
            let r = radius(scene.nodes[i]) + 4
            if d <= r * r, d < bestDistance { best = i; bestDistance = d }
        }
        return best
    }

    func zoom(by factor: CGFloat, around anchor: CGPoint? = nil) {
        let newScale = min(max(scale * factor, 0.04), 8)
        let applied = newScale / scale
        let a = anchor ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        // Keep the graph point under the anchor fixed.
        let cx = canvasSize.width / 2 + offset.width, cy = canvasSize.height / 2 + offset.height
        offset = CGSize(width: offset.width + (a.x - cx) * (1 - applied), height: offset.height + (a.y - cy) * (1 - applied))
        scale = newScale
        userMoved = true
    }
}

// MARK: - Section

/// (4) Graph view: interactive node-link diagram of the personal graph.
struct GraphViewSection: View {
    enum ColorMode: String, CaseIterable, Identifiable { case kind = "Class", relation = "Relationship"; var id: String { rawValue } }

    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.privacyMode) private var privacyMode
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model = GraphViewModel()
    @State private var options = GraphOptions()
    @State private var colorMode = ColorMode.kind
    @State private var showLabels = true
    @State private var seed: UInt64 = 7
    @State private var panStart: CGSize?
    @State private var zoomStart: CGFloat?
    @State private var scrollMonitor: Any?

    private struct LoadKey: Hashable { let options: GraphOptions; let seed: UInt64; let token: Int }

    var body: some View {
        let token = refreshToken
        VStack(spacing: 0) {
            controls
            Divider()
            ZStack {
                canvasArea
                if let error = model.error {
                    Group {
                        switch error {
                        case .inaccessible(let m): StatePlaceholder.inaccessible(m)
                        case .missing(let m): StatePlaceholder.missing(m)
                        case .failed(let m): StatePlaceholder(title: "Couldn’t Build the Graph", symbol: "exclamationmark.triangle", message: m)
                        default: EmptyView()
                        }
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
            .detailInspector(isPresented: Binding(get: { model.selected != nil }, set: { if !$0 { model.selected = nil } })) {
                if let i = model.selected, model.scene.nodes.indices.contains(i) {
                    EntityInspector(entityID: model.scene.nodes[i].id, subtitle: "Selected in graph", onClose: { model.selected = nil }) { id in
                        if let j = model.scene.nodes.firstIndex(where: { $0.id == id }) { model.selected = j }
                    }
                }
            }
            StoreFooter(GraphPaths.graph, note: "links = md: references in stable_graph + attendees in event_graph")
        }
        .task(id: LoadKey(options: options, seed: seed, token: token)) {
            await GraphStore.shared.sync(token: token)
            await model.load(options: options, seed: seed)
        }
        .onDisappear { removeScrollMonitor() }
    }

    // MARK: Controls

    /// Widest variant that fits: first the colour picker moves into the Show menu, then the
    /// scope control becomes a pop-up. The alternatives are nested in pairs on purpose: in a
    /// flat `ViewThatFits` the pop-up buttons of a third alternative were measured before
    /// they existed and came out a few points wide (seen in `--uitest`).
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlsRow(segmentedScope: true, colourPicker: true)
            ViewThatFits(in: .horizontal) {
                controlsRow(segmentedScope: true, colourPicker: false)
                controlsRow(segmentedScope: false, colourPicker: false)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func controlsRow(segmentedScope: Bool, colourPicker: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if segmentedScope {
                    Picker("Scope", selection: $options.scope) {
                        ForEach(GraphOptions.Scope.allCases) { s in Text(s.rawValue).tag(s).help(s.help) }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Picker("Scope", selection: $options.scope) {
                        ForEach(GraphOptions.Scope.allCases) { s in Text(s.rawValue).tag(s) }
                    }
                    .pickerStyle(.menu)
                    .help(options.scope.help)
                }
            }
            .labelsHidden()
            .fixedSize()
            if options.scope == .ego {
                Picker("Hops", selection: $options.hops) {
                    Text("1 link away").tag(1)
                    Text("2 links away").tag(2)
                    Text("3 links away").tag(3)
                    Text("4 links away").tag(4)
                }
                .labelsHidden()
                .fixedSize()
                .help("How many links from your node to follow")
            }
            Menu {
                ForEach(EntityKind.allCases) { kind in
                    Toggle(isOn: Binding(
                        get: { options.kinds.contains(kind) },
                        set: { on in if on { options.kinds.insert(kind) } else { options.kinds.remove(kind) } }
                    )) {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
                Divider()
                Toggle("Labels", isOn: $showLabels)
                if !colourPicker {
                    Divider()
                    Picker("Colour by", selection: $colorMode) {
                        ForEach(ColorMode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                }
            } label: {
                Label("Show", systemImage: "line.3.horizontal.decrease.circle")
            }
            .fixedSize()
            .help("Node classes to include. Software adds every installed app and its publisher.")
            if colourPicker {
                Picker("Colour", selection: $colorMode) {
                    ForEach(ColorMode.allCases) { m in Text("Colour: \(m.rawValue)").tag(m) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer(minLength: 8)
            ControlGroup {
                Button { model.zoom(by: 1 / 1.3) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom Out")
                Button { model.userMoved = false; model.fit(animated: true) } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }.help("Zoom to Fit")
                Button { model.zoom(by: 1.3) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom In")
            }
            .fixedSize()
            Button { seed &+= 1 } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                .fixedSize()
                .help("Recompute the layout with a different random start")
        }
    }

    // MARK: Canvas

    private var canvasArea: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Canvas(rendersAsynchronously: false) { context, size in
                    draw(&context, size: size)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            if panStart == nil { panStart = model.offset }
                            let base = panStart ?? .zero
                            model.offset = CGSize(width: base.width + value.translation.width, height: base.height + value.translation.height)
                            model.userMoved = true
                        }
                        .onEnded { _ in panStart = nil }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            if zoomStart == nil { zoomStart = model.scale }
                            let target = (zoomStart ?? 1) * value.magnification
                            model.zoom(by: target / model.scale, around: value.startLocation)
                        }
                        .onEnded { _ in zoomStart = nil }
                )
                .onTapGesture(coordinateSpace: .local) { location in
                    model.selected = model.node(at: location)
                }
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location):
                        model.mouseInside = true
                        let hit = model.node(at: location)
                        if hit != model.hover { model.hover = hit }
                    case .ended:
                        model.mouseInside = false
                        model.hover = nil
                    }
                }

                if model.isLaidOut && model.scene.nodes.isEmpty && model.error == nil {
                    StatePlaceholder(title: "Nothing to Draw", symbol: "point.3.connected.trianglepath.dotted", message: "No nodes match the current scope and class filter. Try “All Linked” or enable more classes under Show.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                legend.padding(12)
                if let i = model.hover, model.scene.nodes.indices.contains(i), model.positions.count == model.scene.nodes.count {
                    hoverCard(i)
                }
            }
            .onAppear { model.canvasSize = geo.size; installScrollMonitor() }
            .onChange(of: geo.size) { _, size in
                model.canvasSize = size
                if !model.userMoved { model.fit(animated: false) }
            }
        }
    }

    private func color(_ node: SceneNode) -> Color {
        if node.isOwner { return .yellow }
        switch colorMode {
        case .kind: return node.kind.tint
        case .relation:
            guard !node.relation.isEmpty, let i = model.scene.relations.firstIndex(of: node.relation) else { return Color.secondary.opacity(0.45) }
            return ChartPalette.color(i + 1)
        }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let scene = model.scene
        guard model.positions.count == scene.nodes.count, !scene.nodes.isEmpty else { return }
        let focus = model.hover ?? model.selected
        var highlighted = Set<Int>()
        if let focus, scene.nodes.indices.contains(focus) {
            highlighted.insert(focus)
            for n in scene.adjacency[focus] { highlighted.insert(Int(n)) }
        }
        let dimming = !highlighted.isEmpty
        let points = scene.nodes.indices.map { model.screenPoint($0) }
        let visible = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)

        // Links.
        var normal = Path(), strong = Path()
        for e in scene.edges {
            let a = points[Int(e.a)], b = points[Int(e.b)]
            if !visible.contains(a) && !visible.contains(b) { continue }
            if dimming, let focus, Int(e.a) == focus || Int(e.b) == focus {
                strong.move(to: a); strong.addLine(to: b)
            } else {
                normal.move(to: a); normal.addLine(to: b)
            }
        }
        context.stroke(normal, with: .color(Color.secondary.opacity(dimming ? 0.12 : 0.32)), lineWidth: 0.8)
        context.stroke(strong, with: .color(Color.accentColor.opacity(0.85)), lineWidth: 1.6)

        // Nodes.
        for i in scene.nodes.indices {
            let p = points[i]
            guard visible.contains(p) else { continue }
            let node = scene.nodes[i]
            let r = model.radius(node)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            let alpha: Double = dimming && !highlighted.contains(i) ? 0.22 : 1
            context.fill(Path(ellipseIn: rect), with: .color(color(node).opacity(alpha)))
            if node.isOwner || i == model.selected {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(Color.accentColor.opacity(0.9)), lineWidth: 2)
            } else {
                context.stroke(Path(ellipseIn: rect), with: .color(Color(nsColor: .textBackgroundColor).opacity(0.9)), lineWidth: 0.8)
            }
        }

        // Labels: focus neighbourhood first, then by degree, skipping overlaps.
        guard showLabels else { return }
        var order: [Int] = []
        if dimming { order = highlighted.sorted { scene.nodes[$0].degree > scene.nodes[$1].degree } }
        let threshold: Int = model.scale > 1.3 ? 0 : (model.scale > 0.75 ? 1 : (model.scale > 0.4 ? 3 : 6))
        if !dimming || highlighted.count < 40 {
            for i in scene.nodes.indices where !highlighted.contains(i) && (scene.nodes[i].isOwner || scene.nodes[i].degree >= threshold) { order.append(i) }
        }
        var taken: [CGRect] = []
        var drawn = 0
        for i in order {
            if drawn >= 220 { break }
            let p = points[i]
            guard visible.contains(p) else { continue }
            let node = scene.nodes[i]
            let emphasised = node.isOwner || highlighted.contains(i)
            let name = privacyMode ? (node.isOwner ? "You" : node.kind.singular) : (node.isOwner ? "\(node.name) (you)" : node.name)
            let text = Text(name.count > 30 ? String(name.prefix(29)) + "…" : name)
                .font(.system(size: emphasised ? 11 : 10, weight: emphasised ? .semibold : .regular))
                .foregroundStyle(dimming && !highlighted.contains(i) ? Color.secondary.opacity(0.45) : Color.primary)
            let resolved = context.resolve(text)
            let textSize = resolved.measure(in: CGSize(width: 240, height: 40))
            let r = model.radius(node)
            let rect = CGRect(x: p.x - textSize.width / 2, y: p.y + r + 2, width: textSize.width, height: textSize.height)
            if !emphasised, taken.contains(where: { $0.intersects(rect.insetBy(dx: -3, dy: -1)) }) { continue }
            taken.append(rect)
            let background = Path(roundedRect: rect.insetBy(dx: -3, dy: -0.5), cornerRadius: 3)
            context.fill(background, with: .color(Color(nsColor: .textBackgroundColor).opacity(emphasised ? 0.9 : 0.7)))
            context.draw(resolved, in: rect)
            drawn += 1
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch colorMode {
            case .kind:
                let counts = Dictionary(grouping: model.scene.nodes, by: \.kind).mapValues(\.count)
                ForEach(EntityKind.allCases.filter { (counts[$0] ?? 0) > 0 }) { kind in
                    legendRow(kind.tint, kind.title, counts[kind] ?? 0)
                }
            case .relation:
                ForEach(Array(model.scene.relations.enumerated()), id: \.offset) { i, relation in
                    legendRow(ChartPalette.color(i + 1), relation, model.scene.nodes.filter { $0.relation == relation }.count, sensitive: true)
                }
                legendRow(Color.secondary.opacity(0.45), "No declared relationship", model.scene.nodes.filter { $0.relation.isEmpty && !$0.isOwner }.count)
            }
            legendRow(.yellow, "You", model.scene.ownerIndex == nil ? 0 : 1)
            Divider().frame(width: GraphViewModel.legendRowWidth)
            HStack(spacing: 6) {
                Text("\(Format.count(model.scene.nodes.count)) nodes · \(Format.count(model.scene.edges.count)) links")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(model.isLaidOut ? String(format: "Layout computed in %.2f s", model.layoutSeconds) : "Computing layout…")
                Spacer(minLength: 4)
                if !model.isLaidOut && model.error == nil {
                    ProgressView(value: model.progress).frame(width: 44).controlSize(.small)
                }
            }
            .frame(width: GraphViewModel.legendRowWidth)
            Text("Drag to pan · pinch or scroll to zoom · click a node")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: GraphViewModel.legendRowWidth, alignment: .leading)
                .padding(.top, 2)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
    }

    private func legendRow(_ color: Color, _ title: String, _ count: Int, sensitive: Bool = false) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(title).font(.caption).lineLimit(1).sensitive(sensitive ? .personal : .low)
            Spacer(minLength: 10)
            Text(Format.count(count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(width: GraphViewModel.legendRowWidth)
    }

    private func hoverCard(_ i: Int) -> some View {
        let node = model.scene.nodes[i]
        let p = model.screenPoint(i)
        let links = Dictionary(grouping: model.scene.edges.filter { Int($0.a) == i || Int($0.b) == i }, by: \.label).map { "\($0.value.count) × \($0.key)" }.sorted()
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                KindIcon(kind: node.kind, size: 18)
                Text(node.isOwner ? "\(node.name) (you)" : node.name).font(.callout.weight(.semibold)).lineLimit(1).sensitive(.sensitive)
            }
            if !node.relation.isEmpty {
                Text("Declared: \(node.relation)").font(.caption).foregroundStyle(.secondary).sensitive(.sensitive)
            }
            Text(links.isEmpty ? "No links in this view" : links.prefix(4).joined(separator: "\n"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
        .fixedSize()
        .position(x: min(max(p.x + 20, 140), max(140, model.canvasSize.width - 140)), y: max(40, p.y - 44))
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Scroll wheel

    private func installScrollMonitor() {
        guard scrollMonitor == nil, !SnapshotReadiness.isSnapshotting else { return }
        let model = self.model
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak model] event in
            guard let model, model.mouseInside else { return event }
            if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
                // Trackpad: two-finger scroll pans (pinch zooms).
                model.offset = CGSize(width: model.offset.width + event.scrollingDeltaX, height: model.offset.height + event.scrollingDeltaY)
                model.userMoved = true
            } else {
                // Mouse wheel (or ⌘-scroll): zoom around the canvas centre.
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.06
                model.zoom(by: exp(delta))
            }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        model.mouseInside = false
    }
}
