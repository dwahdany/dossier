import SwiftUI
import AppKit

// MARK: - Tree viewer

/// Outline viewer for ``DataNode`` trees (decoded plists, NSKeyedArchiver graphs, JSON,
/// protobuf messages). Lazy: only visible rows are built, so large trees stay smooth.
///
/// ```swift
/// DataTreeView(DataNode.from(message))                       // protobuf
/// DataTreeView([DataNode.from(plistValue, key: "Root")])     // plist / archive / JSON
/// ```
public struct DataTreeView: View {
    private let nodes: [DataNode]
    private let sensitivity: Sensitivity
    private let initialDepth: Int
    private let onOpenData: ((Data, String) -> Void)?

    @State private var expanded: Set<String>?

    /// - Parameters:
    ///   - nodes: top-level nodes.
    ///   - sensitivity: redaction level of values in Privacy Mode.
    ///   - expandedDepth: how many levels start expanded.
    ///   - onOpenData: called when the user opens a raw data leaf (bytes, key).
    public init(_ nodes: [DataNode], sensitivity: Sensitivity = .sensitive, expandedDepth: Int = 2, onOpenData: ((Data, String) -> Void)? = nil) {
        self.nodes = nodes; self.sensitivity = sensitivity; self.initialDepth = expandedDepth; self.onOpenData = onOpenData
    }

    private struct VisibleRow: Identifiable {
        let node: DataNode
        let depth: Int
        var id: String { node.id }
    }

    private func defaultExpanded() -> Set<String> {
        var out: Set<String> = []
        var budget = 400
        func walk(_ list: [DataNode], _ depth: Int) {
            for n in list {
                guard depth < initialDepth, budget > 0, let children = n.children, !children.isEmpty else { continue }
                if children.count > 60 && depth > 0 { continue }
                out.insert(n.id); budget -= 1
                walk(children, depth + 1)
            }
        }
        walk(nodes, 0)
        return out
    }

    private func visibleRows(_ expanded: Set<String>) -> [VisibleRow] {
        var out: [VisibleRow] = []
        func walk(_ list: [DataNode], _ depth: Int) {
            for n in list {
                out.append(VisibleRow(node: n, depth: depth))
                if let children = n.children, expanded.contains(n.id) { walk(children, depth + 1) }
            }
        }
        walk(nodes, 0)
        return out
    }

    public var body: some View {
        let open = expanded ?? defaultExpanded()
        let rows = visibleRows(open)
        ScrollView([.vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    TreeRow(node: row.node, depth: row.depth, isExpanded: open.contains(row.node.id), sensitivity: sensitivity, toggle: {
                        var set = open
                        if set.contains(row.node.id) { set.remove(row.node.id) } else { set.insert(row.node.id) }
                        expanded = set
                    }, expandAll: {
                        var set = open
                        func walk(_ n: DataNode, _ budget: inout Int) {
                            guard budget > 0, let children = n.children else { return }
                            set.insert(n.id); budget -= 1
                            for c in children { walk(c, &budget) }
                        }
                        var budget = 3_000
                        walk(row.node, &budget)
                        expanded = set
                    }, onOpenData: onOpenData)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct TreeRow: View {
    let node: DataNode
    let depth: Int
    let isExpanded: Bool
    let sensitivity: Sensitivity
    let toggle: () -> Void
    let expandAll: () -> Void
    let onOpenData: ((Data, String) -> Void)?
    @State private var hovering = false

    private var hasChildren: Bool { !(node.children?.isEmpty ?? true) }

    private var kindColor: Color {
        switch node.kind {
        case "string": return .green
        case "int", "varint", "real", "double", "float", "fixed32", "fixed64": return .blue
        case "date": return .purple
        case "bool": return .orange
        case "data": return .brown
        case "null", "": return .gray
        default: return .teal
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(hasChildren ? 1 : 0)
                .frame(width: 10)
            Text(node.key)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .lineLimit(1)
                .layoutPriority(2)
            if !node.kind.isEmpty {
                Text(node.kind)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(kindColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(kindColor.opacity(0.12), in: Capsule())
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(node.value)
                .font(.callout)
                .foregroundStyle(hasChildren ? .secondary : .primary)
                .lineLimit(hasChildren ? 1 : 4)
                .textSelection(.enabled)
                .sensitive(hasChildren ? .low : sensitivity)
                .layoutPriority(1)
            if let hint = node.hint {
                Text(hint).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let raw = node.raw, let onOpenData, hovering {
                Button("Open") { onOpenData(raw, node.key) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.leading, CGFloat(depth) * 14 + 8)
        .padding(.trailing, 8)
        .padding(.vertical, 2.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Color.primary.opacity(0.045) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if hasChildren { toggle() } }
        .contextMenu {
            Button("Copy Value") { Pasteboard.copy(node.value) }
            Button("Copy Key") { Pasteboard.copy(node.key) }
            Button("Copy Subtree as Text") { Pasteboard.copy(node.textDump()) }
            if let raw = node.raw {
                Button("Copy Bytes as Hex") { Pasteboard.copy(raw.map { String(format: "%02x", $0) }.joined()) }
                if let onOpenData { Button("Open in Blob Inspector") { onOpenData(raw, node.key) } }
            }
            if hasChildren {
                Divider()
                Button("Expand All Children", action: expandAll)
            }
        }
    }
}

// MARK: - Hex viewer

/// Classic offset / hex / ASCII dump. Lazy rows; shows at most `limit` bytes.
///
/// ```swift
/// HexView(data)
/// ```
public struct HexView: View {
    private let data: Data
    private let limit: Int
    private let bytesPerRow = 16

    public init(_ data: Data, limit: Int = 1 << 20) { self.data = data; self.limit = limit }

    private var shown: Int { min(data.count, limit) }
    private var rowCount: Int { (shown + bytesPerRow - 1) / bytesPerRow }

    public var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0..<rowCount, id: \.self) { row in
                    HexRow(data: data, offset: row * bytesPerRow, count: min(bytesPerRow, shown - row * bytesPerRow))
                }
                if data.count > limit {
                    Text("Showing the first \(Format.bytes(limit)) of \(Format.bytes(data.count)).")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
                if data.isEmpty {
                    Text("0 bytes").font(.callout).foregroundStyle(.secondary).padding(12)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct HexRow: View {
    let data: Data
    let offset: Int
    let count: Int

    private static let hexDigits = Array("0123456789abcdef".utf8)

    var body: some View {
        let base = data.startIndex + offset
        var hex = [UInt8]()
        hex.reserveCapacity(52)
        var ascii = [UInt8]()
        ascii.reserveCapacity(16)
        for i in 0..<16 {
            if i == 8 { hex.append(0x20) }
            if i < count {
                let b = data[base + i]
                hex.append(HexRow.hexDigits[Int(b >> 4)])
                hex.append(HexRow.hexDigits[Int(b & 0xF)])
                ascii.append((0x20...0x7E).contains(b) ? b : 0x2E)
            } else {
                hex.append(0x20); hex.append(0x20)
            }
            hex.append(0x20)
        }
        return HStack(spacing: 14) {
            Text(String(format: "%08x", offset)).foregroundStyle(.tertiary)
            Text(String(decoding: hex, as: UTF8.self))
            Text(String(decoding: ascii, as: UTF8.self)).foregroundStyle(.secondary)
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
        .fixedSize()
        .frame(height: 16)
    }
}

// MARK: - Blob inspector

/// Shows any blob with automatic format detection: binary/XML plist, NSKeyedArchiver,
/// protobuf and JSON as a tree; images as an image; text as text; everything as hex.
/// Nested data leaves can be opened in place (breadcrumb back).
///
/// ```swift
/// BlobInspector(data: row.payload, sensitivity: .sensitive)
/// ```
public struct BlobInspector: View {
    private let root: Data
    private let rootTitle: String
    private let sensitivity: Sensitivity

    private enum Mode: String, CaseIterable, Identifiable {
        case decoded = "Decoded", text = "Text", hex = "Hex"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .decoded
    @State private var stack: [(title: String, data: Data)] = []

    public init(data: Data, title: String = "Blob", sensitivity: Sensitivity = .sensitive) {
        self.root = data; self.rootTitle = title; self.sensitivity = sensitivity
    }

    private var current: Data { stack.last?.data ?? root }

    fileprivate enum Decoded: Sendable {
        case tree([DataNode], BlobSniffer.Kind)
        case image(Data, BlobSniffer.Kind)
        case text(String, BlobSniffer.Kind)
        case none(BlobSniffer.Kind)

        var kind: BlobSniffer.Kind {
            switch self {
            case .tree(_, let k), .image(_, let k), .text(_, let k), .none(let k): return k
            }
        }
    }

    fileprivate static func decode(_ data: Data) -> Decoded {
        let kind = BlobSniffer.sniff(data)
        switch kind {
        case .binaryPlist, .keyedArchive, .xmlPlist:
            if let value = PlistDecoder.decodeAny(data) { return .tree([DataNode.from(value, key: kind.label)], kind) }
        case .json:
            if let value = PlistDecoder.decodeJSON(data) { return .tree([DataNode.from(value, key: "JSON")], kind) }
        case .protobuf:
            if let message = ProtoMessage(data) { return .tree(DataNode.from(message), kind) }
        case .image:
            return .image(data, kind)
        case .text:
            return .text(String(decoding: data.prefix(4 << 20), as: UTF8.self), kind)
        default:
            break
        }
        return .none(kind)
    }

    public var body: some View {
        let data = current
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !stack.isEmpty {
                    Button { stack.removeLast() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless)
                        .help("Back to enclosing blob")
                    Text(stack.last?.title ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 4)
                // The byte count is dropped when the header is narrow (a 260-pt inspector
                // with the back button showing) instead of wrapping one character per
                // line. Only the text is inside `ViewThatFits`, never the picker.
                ViewThatFits(in: .horizontal) {
                    Text(Format.bytes(data.count)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            switch mode {
            case .decoded:
                AsyncContent(reloadKey: data, load: { BlobInspector.decode(data) }) { decoded in
                    VStack(spacing: 0) {
                        decodedBody(decoded, data: data)
                        Divider()
                        HStack {
                            TagLabel(decoded.kind.label, tint: .teal)
                            if case .tree(let nodes, _) = decoded {
                                Text("\(Format.count(nodes.reduce(0) { $0 + $1.nodeCount })) nodes").font(.caption).foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(.bar)
                    }
                }
            case .text:
                ScrollView {
                    Text(String(decoding: data.prefix(1 << 20), as: UTF8.self))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .sensitive(sensitivity)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
            case .hex:
                HexView(data).sensitive(sensitivity)
            }
        }
    }

    @ViewBuilder private func decodedBody(_ decoded: Decoded, data: Data) -> some View {
        switch decoded {
        case .tree(let nodes, _):
            DataTreeView(nodes, sensitivity: sensitivity) { nested, key in
                stack.append((key, nested))
                mode = .decoded
            }
        case .image(let imageData, _):
            if let image = NSImage(data: imageData) {
                ScrollView([.vertical, .horizontal]) {
                    Image(nsImage: image).sensitive(sensitivity).padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HexView(data)
            }
        case .text(let text, _):
            ScrollView {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .sensitive(sensitivity)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        case .none:
            HexView(data).sensitive(sensitivity)
        }
    }
}
