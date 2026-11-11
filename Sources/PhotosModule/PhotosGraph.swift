import Foundation
import DossierCore

// PhotosGraph (`photosgraph.kgdb`) — worked out empirically from real files.
//
// The file is a plain SQLite database written by photoanalysisd's knowledge-graph engine:
//
//   Label(identifier, name, nodeIds BLOB, edgeIds BLOB)      every label and the elements carrying it
//   Node(identifier, labels BLOB, edgesIn BLOB, edgesOut BLOB)
//   Edge(identifier, labels BLOB, sourceNodeId, targetNodeId)
//   Attribute(identifier, name)
//   NodeValue / EdgeValue(elementId, attributeId, intValue, realValue, stringValue, dataType)
//
// All BLOB columns are sparse bitmaps:
//   u32 version (7) | u32 chunkCount | chunkCount × { u32 reserved | u32 popcount | u64 firstBit | 128 bytes bitmap }
// i.e. 144-byte chunks of 1024 bits; bit k of a chunk stands for element id firstBit + k.
//
// Every node carries one "domain_<n>" label plus type labels ("Moment", "People", "Home", …);
// every edge carries one domain label plus an upper-case relation label ("PRESENT", "FRIEND", …).
// Rather than decoding 150-byte label blobs per element we invert the Label table once.

enum GraphValue: Sendable, Hashable {
    case int(Int64), real(Double), string(String)

    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var int: Int64? {
        switch self {
        case .int(let i): return i
        case .real(let d): return d.isFinite && abs(d) < 9e18 ? Int64(d) : nil
        case .string: return nil
        }
    }
    var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .real(let d): return d
        case .string: return nil
        }
    }
    var display: String {
        switch self {
        case .int(let i): return String(i)
        case .real(let d): return Format.number(d, maxDigits: 4)
        case .string(let s): return s
        }
    }
}

struct KGEdge: Sendable {
    let id: Int32
    /// Numeric domain of the edge (from its `domain_<n>` label), 0 if none.
    let domain: Int16
    let label: Int32
    let source: Int32
    let target: Int32
}

enum KGBitmap {
    /// Calls `body` for every set bit; returns false if the blob does not have the expected framing.
    @discardableResult
    static func forEach(_ data: Data?, _ body: (Int) -> Void) -> Bool {
        guard let data, data.count >= 8 else { return data == nil || data?.isEmpty == true }
        return data.withUnsafeBytes { raw -> Bool in
            let chunks = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
            guard 8 + chunks * 144 == raw.count else { return false }
            var offset = 8
            for _ in 0..<chunks {
                let base = Int(truncatingIfNeeded: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self)))
                for w in 0..<16 {
                    var word = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 16 + w * 8, as: UInt64.self))
                    while word != 0 {
                        body(base + w * 64 + word.trailingZeroBitCount)
                        word &= word - 1
                    }
                }
                offset += 144
            }
            return true
        }
    }

    static func count(_ data: Data?) -> Int {
        var n = 0
        forEach(data) { _ in n += 1 }
        return n
    }
}

/// Immutable in-memory skeleton of the graph: labels, node types, the non-scene edges and a
/// whitelisted set of node attributes. Scene edges (the bulk of the file) are only counted.
final class PhotosGraph: @unchecked Sendable {
    let url: URL
    let db: SQLiteDB
    let labelNames: [Int32: String]
    let labelIDs: [String: Int32]
    let nodeDomain: [Int32: Int]
    let nodeKinds: [Int32: [String]]
    let attrs: [Int32: [String: GraphValue]]
    let edges: [KGEdge]
    let outgoing: [Int32: [Int32]]      // node → indexes into `edges`
    let incoming: [Int32: [Int32]]
    let sceneMoments: [Int32: Int]      // scene node → number of moments linked by SCENE
    let nodeCount: Int
    let edgeCount: Int
    let attributeNames: [Int32: String]
    let metadata: [String]
    let bitmapsValid: Bool

    private init(url: URL, db: SQLiteDB, labelNames: [Int32: String], nodeDomain: [Int32: Int], nodeKinds: [Int32: [String]],
                 attrs: [Int32: [String: GraphValue]], edges: [KGEdge], sceneMoments: [Int32: Int], nodeCount: Int, edgeCount: Int,
                 attributeNames: [Int32: String], metadata: [String], bitmapsValid: Bool) {
        self.url = url; self.db = db; self.labelNames = labelNames
        self.labelIDs = Dictionary(labelNames.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        self.nodeDomain = nodeDomain; self.nodeKinds = nodeKinds; self.attrs = attrs; self.edges = edges
        var out: [Int32: [Int32]] = [:], inc: [Int32: [Int32]] = [:]
        for (i, e) in edges.enumerated() {
            out[e.source, default: []].append(Int32(i))
            inc[e.target, default: []].append(Int32(i))
        }
        self.outgoing = out; self.incoming = inc
        self.sceneMoments = sceneMoments; self.nodeCount = nodeCount; self.edgeCount = edgeCount
        self.attributeNames = attributeNames; self.metadata = metadata; self.bitmapsValid = bitmapsValid
    }

    /// Node attributes kept in memory. Everything else (per-moment scores etc.) is skipped.
    static let keptAttributes: Set<String> = [
        "name", "id", "lat", "lng", "uuid", "cnid", "fav", "sex", "bday", "agecategory", "usercreated", "shareparticipant",
        "utcs", "utce", "cnt", "universalStartDate", "universalEndDate", "localeIdentifier", "tabooType", "holc", "anml",
        "favorite", "localIdentifier", "isUserVerified", "importance", "persistedUUID", "popularityScore", "latitude",
        "longitude", "radius", "venueCapacity", "eventID", "attdc", "localizedName", "sceneIdentifier", "level", "memid",
        "subcategory", "identifier", "lcln", "lvl", "blocked",
    ]

    static func load(_ url: URL) async throws -> PhotosGraph {
        let db = try await SQLiteDB.shared(url)
        guard await db.hasColumns("Label", ["identifier", "name", "nodeIds", "edgeIds"]),
              await db.hasColumns("Edge", ["identifier", "sourceNodeId", "targetNodeId"]),
              await db.hasColumns("NodeValue", ["elementId", "attributeId", "intValue", "realValue", "stringValue"]) else {
            throw DossierError.missing("photosgraph.kgdb does not have the Label / Node / Edge layout this viewer understands.")
        }

        // 1. Invert the Label table.
        struct LabelAcc: Sendable {
            var names: [Int32: String] = [:]
            var domain: [Int32: Int] = [:]
            var kinds: [Int32: [String]] = [:]
            var edgeLabel: [Int32: Int32] = [:]
            var edgeDomain: [Int32: Int16] = [:]
            var valid = true
        }
        let labels = try await db.reduce("SELECT identifier, name, nodeIds, edgeIds FROM Label ORDER BY identifier", into: LabelAcc()) { acc, row in
            guard let id = row[0].int, let name = row[1].string else { return }
            let lid = Int32(truncatingIfNeeded: id)
            acc.names[lid] = name
            let isDomain = name.hasPrefix("domain_")
            let domainCode = isDomain ? Int(name.dropFirst(7)) : nil
            let okNodes = KGBitmap.forEach(row[2].data) { bit in
                let node = Int32(truncatingIfNeeded: bit)
                if let domainCode { acc.domain[node] = domainCode } else if !isDomain { acc.kinds[node, default: []].append(name) }
            }
            let okEdges = KGBitmap.forEach(row[3].data) { bit in
                if !isDomain { acc.edgeLabel[Int32(truncatingIfNeeded: bit)] = lid }
                else if let domainCode { acc.edgeDomain[Int32(truncatingIfNeeded: bit)] = Int16(truncatingIfNeeded: domainCode) }
            }
            if !okNodes || !okEdges { acc.valid = false }
        }

        // 2. Edges: keep everything except SCENE (≈ 60 % of all edges), which is only counted.
        struct EdgeAcc: Sendable {
            var edges: [KGEdge] = []
            var scene: [Int32: Int] = [:]
            var total = 0
        }
        let sceneLabel = labels.names.first { $0.value == "SCENE" }?.key ?? -1
        let edgeLabel = labels.edgeLabel
        let edgeDomain = labels.edgeDomain
        let edgeAcc = try await db.reduce("SELECT identifier, sourceNodeId, targetNodeId FROM Edge", into: EdgeAcc()) { acc, row in
            guard let id = row[0].int, let s = row[1].int, let t = row[2].int else { return }
            acc.total += 1
            let eid = Int32(truncatingIfNeeded: id)
            let label = edgeLabel[eid] ?? -1
            if label == sceneLabel {
                acc.scene[Int32(truncatingIfNeeded: t), default: 0] += 1
            } else {
                acc.edges.append(KGEdge(id: eid, domain: edgeDomain[eid] ?? 0, label: label, source: Int32(truncatingIfNeeded: s), target: Int32(truncatingIfNeeded: t)))
            }
        }

        // 3. Attribute names and the whitelisted node values.
        var attributeNames: [Int32: String] = [:]
        for row in try await db.rows("SELECT identifier, name FROM Attribute") {
            if let id = row[0].int, let name = row[1].string { attributeNames[Int32(truncatingIfNeeded: id)] = name }
        }
        let kept = attributeNames.filter { keptAttributes.contains($0.value) }
        var attrs: [Int32: [String: GraphValue]] = [:]
        if !kept.isEmpty {
            let list = kept.keys.map(String.init).joined(separator: ",")
            let names = attributeNames
            attrs = try await db.reduce("SELECT elementId, attributeId, intValue, realValue, stringValue FROM NodeValue WHERE attributeId IN (\(list))", into: [Int32: [String: GraphValue]]()) { acc, row in
                guard let e = row[0].int, let a = row[1].int, let name = names[Int32(truncatingIfNeeded: a)] else { return }
                let value: GraphValue
                if let s = row[4].string, !row[4].isNull { value = .string(s) }
                else if !row[3].isNull, let d = row[3].double { value = .real(d) }
                else if !row[2].isNull, let i = row[2].int { value = .int(i) }
                else { return }
                acc[Int32(truncatingIfNeeded: e), default: [:]][name] = value
            }
        }
        // The single "Info" node keeps library-wide statistics in many attributes: load them all.
        if let infoNode = labels.kinds.first(where: { $0.value.contains("Info") })?.key {
            for row in try await db.rows("SELECT attributeId, intValue, realValue, stringValue FROM NodeValue WHERE elementId = ?", [.integer(Int64(infoNode))]) {
                guard let a = row[0].int, let name = attributeNames[Int32(truncatingIfNeeded: a)] else { continue }
                if let s = row[3].string, !row[3].isNull { attrs[infoNode, default: [:]][name] = .string(s) }
                else if !row[2].isNull, let d = row[2].double { attrs[infoNode, default: [:]][name] = .real(d) }
                else if !row[1].isNull, let i = row[1].int { attrs[infoNode, default: [:]][name] = .int(i) }
            }
        }

        var metadata: [String] = []
        if await db.tableExists("GraphMetadata") {
            metadata = ((try? await db.rows("SELECT metadataKey, value FROM GraphMetadata ORDER BY metadataKey")) ?? []).map { "\($0[0].int ?? 0)=\($0[1].string ?? "")" }
        }
        let nodeCount = await db.rowCount(of: "Node") ?? labels.domain.count
        return PhotosGraph(url: url, db: db, labelNames: labels.names, nodeDomain: labels.domain, nodeKinds: labels.kinds, attrs: attrs,
                           edges: edgeAcc.edges, sceneMoments: edgeAcc.scene, nodeCount: nodeCount, edgeCount: edgeAcc.total,
                           attributeNames: attributeNames, metadata: metadata, bitmapsValid: labels.valid)
    }

    // MARK: Navigation helpers

    func nodes(domain: Int, kind: String? = nil) -> [Int32] {
        nodeDomain.compactMap { (node, d) -> Int32? in
            guard d == domain else { return nil }
            if let kind, !(nodeKinds[node] ?? []).contains(kind) { return nil }
            return node
        }.sorted()
    }

    func kind(_ node: Int32) -> String { nodeKinds[node]?.first ?? "Node" }
    func label(_ edge: KGEdge) -> String { labelNames[edge.label] ?? "?" }
    func attr(_ node: Int32, _ name: String) -> GraphValue? { attrs[node]?[name] }
    func string(_ node: Int32, _ name: String) -> String? { attrs[node]?[name]?.string }

    func out(_ node: Int32, _ label: String) -> [KGEdge] {
        guard let lid = labelIDs[label] else { return [] }
        return (outgoing[node] ?? []).map { edges[Int($0)] }.filter { $0.label == lid }
    }

    func into(_ node: Int32, _ label: String) -> [KGEdge] {
        guard let lid = labelIDs[label] else { return [] }
        return (incoming[node] ?? []).map { edges[Int($0)] }.filter { $0.label == lid }
    }

    func edges(labelled label: String) -> [KGEdge] {
        guard let lid = labelIDs[label] else { return [] }
        return edges.filter { $0.label == lid }
    }

    /// Display name of a node: its name attribute, else its type label.
    func name(_ node: Int32) -> String {
        if let s = string(node, "name"), !s.isEmpty { return s }
        if let s = string(node, "localizedName"), !s.isEmpty { return s }
        if let v = attr(node, "name") { return v.display }
        return kind(node)
    }

    /// Edge attributes for a set of edges, fetched on demand (primary-key lookups, chunked).
    func edgeValues(_ ids: [Int32]) async -> [Int32: [String: GraphValue]] {
        var out: [Int32: [String: GraphValue]] = [:]
        guard await db.tableExists("EdgeValue") else { return out }
        var start = 0
        while start < ids.count {
            if Task.isCancelled { break }
            let chunk = ids[start..<min(start + 400, ids.count)]
            start += 400
            let list = chunk.map(String.init).joined(separator: ",")
            guard let rows = try? await db.rows("SELECT elementId, attributeId, intValue, realValue, stringValue FROM EdgeValue WHERE elementId IN (\(list))") else { continue }
            for row in rows {
                guard let e = row[0].int, let a = row[1].int, let name = attributeNames[Int32(truncatingIfNeeded: a)] else { continue }
                let value: GraphValue
                if let s = row[4].string, !row[4].isNull { value = .string(s) }
                else if !row[3].isNull, let d = row[3].double { value = .real(d) }
                else if !row[2].isNull, let i = row[2].int { value = .int(i) }
                else { continue }
                out[Int32(truncatingIfNeeded: e), default: [:]][name] = value
            }
        }
        return out
    }

    struct AddressParts {
        var line = ""
        var district = ""
        var city = ""
        var state = ""
        var country = ""
    }

    /// Address components found by walking the location hierarchy (number → street → district → city → … → country).
    func addressParts(_ address: Int32) -> AddressParts {
        func first(_ from: [Int32], _ label: String) -> Int32? {
            for n in from { if let e = out(n, label).first { return e.target } }
            return nil
        }
        let number = first([address], "NUMBER")
        let street = first([address] + (number.map { [$0] } ?? []), "STREET")
        let district = first([address] + [street].compactMap { $0 }, "DISTRICT")
        let city = first([address] + [district, street].compactMap { $0 }, "CITY")
        let county = first([address] + [city, district, street].compactMap { $0 }, "COUNTY")
        let state = first([address] + [county, city, district].compactMap { $0 }, "STATE")
        let country = first([state].compactMap { $0 }, "COUNTRY")
        var parts = AddressParts()
        parts.line = [street.map(name), number.map(name)].compactMap { $0 }.joined(separator: " ")
        if parts.line.isEmpty, let area = first([address], "AREA") { parts.line = name(area) }
        parts.district = district.map(name) ?? ""
        parts.city = city.map(name) ?? ""
        parts.state = state.map(name) ?? ""
        parts.country = country.map { Self.regionName(name($0)) } ?? ""
        return parts
    }

    /// Readable postal address.
    func addressText(_ address: Int32) -> String {
        let a = addressParts(address)
        var parts: [String] = []
        for p in [a.line, a.district, a.city, a.state, a.country] where !p.isEmpty && !parts.contains(p) { parts.append(p) }
        if parts.isEmpty { return string(address, "name") ?? "Address" }
        return parts.joined(separator: ", ")
    }

    /// Country nodes are named by ISO region code; show the localized country name instead.
    static func regionName(_ code: String) -> String {
        guard code.count == 2, code == code.uppercased() else { return code }
        return Locale.current.localizedString(forRegionCode: code) ?? code
    }

    func coordinate(_ node: Int32) -> (lat: Double, lon: Double)? {
        if let lat = attr(node, "lat")?.double, let lon = attr(node, "lng")?.double { return (lat, lon) }
        if let lat = attr(node, "latitude")?.double, let lon = attr(node, "longitude")?.double { return (lat, lon) }
        return nil
    }
}

/// Plain-English description of the numeric graph domains (derived from the type labels found in each).
enum GraphDomains {
    static let names: [Int: String] = [
        21: "Graph info", 100: "Moments", 101: "Moment sequence", 102: "Highlights", 103: "Trip types",
        200: "Address hierarchy", 201: "Named areas", 202: "Home & work", 203: "Mobility", 204: "Frequent locations", 205: "Languages",
        300: "People", 301: "Birthdays", 302: "Social groups", 304: "Pets", 305: "Relationship tags", 306: "Relationship storyline",
        400: "Dates & times", 401: "Holidays", 402: "Over the years",
        501: "Points of interest", 502: "Regions of interest", 503: "Businesses", 504: "Business categories",
        600: "Scenes", 601: "Moment features", 603: "Knowledge entities", 700: "Meanings", 701: "Person activities",
        900: "Public events", 901: "Event categories", 902: "Event subcategories",
        1100: "Memories", 1200: "Moment features", 1201: "Audio features", 1300: "Taboo (sensitive content)",
    ]
    static func name(_ code: Int) -> String { names[code] ?? "Domain \(code)" }
}
