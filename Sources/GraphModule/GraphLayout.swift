import Foundation
import CoreGraphics
import DossierCore

// MARK: - Scene

struct GraphOptions: Hashable, Sendable {
    enum Scope: String, CaseIterable, Identifiable, Sendable {
        case ego = "Around Me"
        case linked = "All Linked"
        case everything = "Everything"
        var id: String { rawValue }

        var help: String {
            switch self {
            case .ego: return "Nodes within a few links of you"
            case .linked: return "Every node that has at least one link"
            case .everything: return "All nodes, including unconnected ones"
            }
        }
    }

    var scope = Scope.ego
    var hops = 2
    var kinds: Set<EntityKind> = [.person, .organization, .place, .group, .event, .other]
}

struct SceneNode: Sendable {
    let id: Int64
    let name: String
    let kind: EntityKind
    let isOwner: Bool
    /// Declared relationship to the owner ("" if none).
    let relation: String
    var degree: Int
}

struct SceneEdge: Sendable, Hashable {
    let a: Int32
    let b: Int32
    let label: String
}

/// The filtered subgraph that is laid out and drawn.
struct GraphScene: Sendable {
    var nodes: [SceneNode] = []
    var edges: [SceneEdge] = []
    var adjacency: [[Int32]] = []
    var ownerIndex: Int?
    /// Nodes that matched the kind filter before scope filtering.
    var candidateNodes = 0
    var relations: [String] = []

    static let maxNodes = 6_000

    static func build(options: GraphOptions) async throws -> GraphScene {
        let index = try await GraphStore.shared.index()
        let events = options.kinds.contains(.event) ? ((try? await GraphStore.shared.events()) ?? []) : []
        let ontology = index.ontology

        // Declared relationship labels on the owner's node.
        var relation: [Int64: String] = [:]
        if let owner = index.ownerID {
            let statements = Statement.group((try? await GraphStore.shared.triples(subject: owner)) ?? [])
            for s in statements where s.predicate == P.association {
                guard let ref = s.field("nm_personIdentifier").flatMap(GraphRef.parse) else { continue }
                let label = s.field("nm_unlocalizedRelationshipLabel").map(GraphFormat.cleanLabel) ?? s.field("nm_relationshipLabel") ?? ""
                // Prefer the most specific label: keep the first non-generic one.
                let genericLabels: Set<String> = ["other", "family", "friend", "parent"]
                if let existing = relation[ref], !genericLabels.contains(existing.lowercased()) { continue }
                if !label.isEmpty { relation[ref] = label }
            }
        }

        // Candidate nodes.
        struct Candidate { let id: Int64; let name: String; let kind: EntityKind; let isOwner: Bool }
        var candidates: [Int64: Candidate] = [:]
        for e in index.ordered where options.kinds.contains(e.kind) || e.isOwner {
            candidates[e.id] = Candidate(id: e.id, name: e.name, kind: e.kind, isOwner: e.isOwner)
        }
        for e in events { candidates[e.id] = Candidate(id: e.id, name: e.title, kind: .event, isOwner: false) }

        // Candidate links (undirected, de-duplicated).
        struct Link: Hashable { let a: Int64; let b: Int64 }
        var links: [Link: String] = [:]
        func add(_ a: Int64, _ b: Int64, _ label: String) {
            guard a != b, candidates[a] != nil, candidates[b] != nil else { return }
            let key = a < b ? Link(a: a, b: b) : Link(a: b, b: a)
            if links[key] == nil { links[key] = label }
        }
        for e in index.edges { add(e.from, e.to, ontology.predicateLabel(e.predicate)) }
        for e in events {
            for p in e.participants { add(e.id, p.node, p.isOrganizer ? "organizer" : "attendee") }
            if let l = e.locationID { add(e.id, l, "location") }
        }
        // Without event nodes, keep the social signal: link attendees of the same event.
        if !options.kinds.contains(.event), let all = try? await GraphStore.shared.events() {
            for e in all {
                let people = Array(Set(e.participants.map(\.node)))
                guard people.count > 1, people.count <= 40 else { continue }
                let hub = e.organizer?.node ?? people[0]
                for p in people where p != hub { add(hub, p, "shared calendar event") }
            }
        }

        var neighbours: [Int64: [Int64]] = [:]
        for key in links.keys {
            neighbours[key.a, default: []].append(key.b)
            neighbours[key.b, default: []].append(key.a)
        }

        // Scope.
        var keep = Set<Int64>()
        switch options.scope {
        case .everything:
            keep = Set(candidates.keys)
        case .linked:
            keep = Set(neighbours.keys)
            if let owner = index.ownerID, candidates[owner] != nil { keep.insert(owner) }
        case .ego:
            if let owner = index.ownerID, candidates[owner] != nil {
                keep.insert(owner)
                var frontier = [owner]
                for _ in 0..<max(1, options.hops) {
                    var next: [Int64] = []
                    for n in frontier { for m in neighbours[n] ?? [] where keep.insert(m).inserted { next.append(m) } }
                    frontier = next
                    if frontier.isEmpty { break }
                }
            } else {
                keep = Set(neighbours.keys)
            }
        }

        var scene = GraphScene()
        scene.candidateNodes = candidates.count
        // Deterministic order: owner, then by degree, then id; cap for safety.
        var ids = Array(keep)
        ids.sort { a, b in
            let oa = candidates[a]?.isOwner == true, ob = candidates[b]?.isOwner == true
            if oa != ob { return oa }
            let da = neighbours[a]?.count ?? 0, db = neighbours[b]?.count ?? 0
            if da != db { return da > db }
            return a < b
        }
        if ids.count > maxNodes { ids = Array(ids.prefix(maxNodes)) }
        var position: [Int64: Int32] = [:]
        for (i, id) in ids.enumerated() {
            guard let c = candidates[id] else { continue }
            position[id] = Int32(scene.nodes.count)
            scene.nodes.append(SceneNode(id: id, name: c.name, kind: c.kind, isOwner: c.isOwner, relation: relation[id] ?? "", degree: 0))
            _ = i
        }
        scene.adjacency = Array(repeating: [], count: scene.nodes.count)
        for (key, label) in links {
            guard let a = position[key.a], let b = position[key.b] else { continue }
            scene.edges.append(SceneEdge(a: a, b: b, label: label))
            scene.adjacency[Int(a)].append(b)
            scene.adjacency[Int(b)].append(a)
        }
        scene.edges.sort { ($0.a, $0.b) < ($1.a, $1.b) }
        for i in scene.nodes.indices { scene.nodes[i].degree = scene.adjacency[i].count }
        scene.ownerIndex = scene.nodes.firstIndex { $0.isOwner }
        scene.relations = Array(Set(scene.nodes.map(\.relation).filter { !$0.isEmpty })).sorted()
        return scene
    }
}

// MARK: - Layout

/// Deterministic force-directed layout (Fruchterman–Reingold with a uniform grid for the
/// repulsion term, so it stays near-linear for thousands of nodes). Runs synchronously —
/// call it from a detached task; it checks for cancellation every iteration.
enum ForceLayout {
    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    }

    static let spacing: Float = 46

    static func run(
        scene: GraphScene, seed: UInt64 = 7,
        progress: (@Sendable (_ positions: [CGPoint], _ fraction: Double) -> Void)? = nil
    ) -> [CGPoint] {
        let n = scene.nodes.count
        guard n > 0 else { return [] }
        let k = spacing
        var rng = SplitMix64(state: seed)
        var pos = [SIMD2<Float>](repeating: .zero, count: n)
        let radius = k * Float(n).squareRoot() * 0.8
        for i in 0..<n {
            if i == scene.ownerIndex { continue }
            let angle = rng.unit() * 2 * .pi
            let r = radius * rng.unit().squareRoot()
            pos[i] = SIMD2(cos(angle) * r, sin(angle) * r)
        }
        if n == 1 { return [CGPoint.zero] }

        let iterations = n > 1_500 ? 160 : (n > 500 ? 220 : 300)
        let exact = n <= 320
        let cutoff = k * 3.2
        let cutoff2 = cutoff * cutoff
        var disp = [SIMD2<Float>](repeating: .zero, count: n)
        var temperature = max(k * 2.5, radius * 0.12)
        let cooling = pow(0.012, 1 / Float(iterations))
        // Isolated nodes get pulled in harder so they form a tidy halo instead of a cloud.
        let gravity: [Float] = scene.nodes.map { $0.degree == 0 ? 0.11 : 0.045 }
        let k2 = k * k
        var cells: [Int64: [Int32]] = [:]

        for iteration in 0..<iterations {
            if Task.isCancelled { break }
            for i in 0..<n { disp[i] = .zero }

            // Repulsion.
            if exact {
                for i in 0..<n {
                    for j in (i + 1)..<n {
                        var d = pos[i] - pos[j]
                        var l2 = d.x * d.x + d.y * d.y
                        if l2 < 0.01 { d = SIMD2(rng.unit() - 0.5, rng.unit() - 0.5); l2 = 0.25 }
                        let f = d * (k2 / l2)
                        disp[i] += f
                        disp[j] -= f
                    }
                }
            } else {
                cells.removeAll(keepingCapacity: true)
                for i in 0..<n {
                    let cx = Int64((pos[i].x / cutoff).rounded(.down)), cy = Int64((pos[i].y / cutoff).rounded(.down))
                    cells[(cx << 32) ^ (cy & 0xFFFF_FFFF), default: []].append(Int32(i))
                }
                for i in 0..<n {
                    let cx = Int64((pos[i].x / cutoff).rounded(.down)), cy = Int64((pos[i].y / cutoff).rounded(.down))
                    for dx in -1...1 {
                        for dy in -1...1 {
                            guard let bucket = cells[((cx + Int64(dx)) << 32) ^ ((cy + Int64(dy)) & 0xFFFF_FFFF)] else { continue }
                            for j32 in bucket {
                                let j = Int(j32)
                                if j == i { continue }
                                var d = pos[i] - pos[j]
                                var l2 = d.x * d.x + d.y * d.y
                                if l2 > cutoff2 { continue }
                                if l2 < 0.01 { d = SIMD2(rng.unit() - 0.5, rng.unit() - 0.5); l2 = 0.25 }
                                disp[i] += d * (k2 / l2)
                            }
                        }
                    }
                }
            }

            // Attraction along links (softened for hubs so spokes do not collapse).
            for e in scene.edges {
                let a = Int(e.a), b = Int(e.b)
                let d = pos[a] - pos[b]
                let l = max(0.01, (d.x * d.x + d.y * d.y).squareRoot())
                let hub = Float(max(scene.nodes[a].degree, scene.nodes[b].degree))
                let f = d * (l / k) * 0.7 / (1 + hub.squareRoot() * 0.22)
                disp[a] -= f
                disp[b] += f
            }

            // Gravity + bounded step.
            for i in 0..<n {
                disp[i] -= pos[i] * gravity[i]
                let l = (disp[i].x * disp[i].x + disp[i].y * disp[i].y).squareRoot()
                if l > 0 { pos[i] += disp[i] / l * min(l, temperature) }
            }
            temperature *= cooling

            if let progress, iteration % 12 == 11, iteration < iterations - 1 {
                progress(pos.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }, Double(iteration + 1) / Double(iterations))
            }
        }
        // Collision pass: nodes with identical neighbourhoods end up on top of each other;
        // nudge apart anything closer than a minimum distance.
        let minDistance = k * 0.42
        let cell = minDistance
        for _ in 0..<24 {
            if Task.isCancelled { break }
            cells.removeAll(keepingCapacity: true)
            for i in 0..<n {
                let cx = Int64((pos[i].x / cell).rounded(.down)), cy = Int64((pos[i].y / cell).rounded(.down))
                cells[(cx << 32) ^ (cy & 0xFFFF_FFFF), default: []].append(Int32(i))
            }
            var moved = false
            for i in 0..<n {
                let cx = Int64((pos[i].x / cell).rounded(.down)), cy = Int64((pos[i].y / cell).rounded(.down))
                for dx in -1...1 {
                    for dy in -1...1 {
                        guard let bucket = cells[((cx + Int64(dx)) << 32) ^ ((cy + Int64(dy)) & 0xFFFF_FFFF)] else { continue }
                        for j32 in bucket {
                            let j = Int(j32)
                            if j <= i { continue }
                            var d = pos[i] - pos[j]
                            var l = (d.x * d.x + d.y * d.y).squareRoot()
                            if l >= minDistance { continue }
                            if l < 0.01 { d = SIMD2(rng.unit() - 0.5, rng.unit() - 0.5); l = max(0.01, (d.x * d.x + d.y * d.y).squareRoot()) }
                            let push = d / l * ((minDistance - l) * 0.5)
                            if i != scene.ownerIndex { pos[i] += push }
                            if j != scene.ownerIndex { pos[j] -= push }
                            moved = true
                        }
                    }
                }
            }
            if !moved { break }
        }

        // Centre on the owner (or the centroid).
        var origin = SIMD2<Float>.zero
        if let o = scene.ownerIndex { origin = pos[o] } else {
            for p in pos { origin += p }
            origin /= Float(n)
        }
        return pos.map { CGPoint(x: CGFloat($0.x - origin.x), y: CGFloat($0.y - origin.y)) }
    }
}
