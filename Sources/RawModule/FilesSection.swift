import SwiftUI
import DossierCore

/// (d) Viewer for stray files in the known stores: plists, NSKeyedArchiver archives,
/// protobuf caches, JSON and text. Files are memory-mapped and decoded on selection.
struct FilesSection: View {
    @State private var selected: FileEntry?
    @Environment(\.deepLink) private var deepLink
    @Environment(\.refreshToken) private var refreshToken

    /// Files larger than this are shown as hex only (first MiB) instead of being decoded.
    static let decodeLimit: Int64 = 48 << 20

    private var columns: [PagedColumn<FileEntry>] {
        [
            PagedColumn<FileEntry>("Name", width: 280, min: 150, sensitivity: .personal) { $0.name }
                .cell { file in
                    HStack(spacing: 6) {
                        Image(systemName: FilesSection.symbol(for: file.ext)).foregroundStyle(.secondary).imageScale(.small).frame(width: 14)
                        Text(file.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    }
                },
            PagedColumn("Type", width: 70, min: 48, secondary: true) { $0.ext.isEmpty ? "—" : $0.ext },
            PagedColumn("Store", width: 170, min: 90, secondary: true) { $0.storeTitle },
            PagedColumn("Folder", width: 300, min: 90, sensitivity: .personal, secondary: true) { $0.folder },
            PagedColumn("Size", width: 80, min: 72, alignment: .trailing) { Format.bytes($0.size) },
            PagedColumn("Modified", width: 150, min: 146) { DossierDate.sortable($0.modified) },
        ]
    }

    static func symbol(for ext: String) -> String {
        switch ext {
        case "plist": return "list.bullet.rectangle"
        case "json": return "curlybraces"
        case "pb", "proto", "protobuf", "binpb": return "shippingbox"
        case "txt", "log", "md", "xml", "strings": return "doc.text"
        case "png", "jpg", "jpeg", "heic", "gif", "tiff": return "photo"
        default: return "doc"
        }
    }

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = selected
        let token = refreshToken
        AsyncContent(reloadKey: token, emptyTitle: "No Files", emptySymbol: "doc") {
            await RawCatalog.shared.sync(token: token)
            return await RawCatalog.shared.files()
        } isEmpty: { $0.isEmpty } content: { files in
            PagedTable(
                rows: files,
                columns: columns,
                searchPrompt: "Filter files (name, type, store, folder)",
                reloadKey: files.count,
                exportName: "files",
                onSelect: { selected = $0.count == 1 ? $0.first : nil }
            )
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { FileInspector(file: selected, onClose: { self.selected = nil }).id(selected.id) }
            }
            .onChange(of: deepLink?.nonce, initial: true) { _, _ in
                if let link = deepLink, link.sectionID == "raw.files", let match = files.first(where: { $0.id == link.payload }) {
                    selected = match
                }
            }
        }
    }
}

private struct FileInspector: View {
    let file: FileEntry
    let onClose: () -> Void

    var body: some View {
        let url = file.url
        InspectorPage(title: file.name, subtitle: "\(file.storeTitle) · \(Format.bytes(file.size))", scrolls: false, onClose: onClose) {
            AsyncContent(reloadKey: url) {
                // Memory-mapped: large files are not copied into the heap.
                let data = try Data(contentsOf: url, options: [.alwaysMapped])
                return data.count > FilesSection.decodeLimit ? data.prefix(1 << 20) : data
            } content: { data in
                VStack(spacing: 0) {
                    if Int64(data.count) < file.size {
                        Text("Large file: showing the first \(Format.bytes(data.count)) only.")
                            .font(.caption).foregroundStyle(.secondary).padding(6)
                        Divider()
                    }
                    BlobInspector(data: data, title: file.name)
                    StoreFooter(url)
                }
            }
        }
    }
}
