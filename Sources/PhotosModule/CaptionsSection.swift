import SwiftUI
import DossierCore

/// (6) Captions & OCR: machine-written descriptions and recognised text, paged. Text is hidden until a
/// row is explicitly revealed.
struct CaptionsSection: View {
    @ObservedObject private var selection = PhotosLibrarySelection.shared
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @State private var source: CaptionSource = .image
    @State private var filterText = ""
    @State private var selected: CaptionRow?
    @StateObject private var reveal = RevealStore()

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (source, filterText, selected)
        VStack(spacing: 0) {
            content.requiresLibrary(selection.current)
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink, !link.payload.isEmpty else { return }
            if link.payload.hasPrefix("source:"), let s = CaptionSource(rawValue: String(link.payload.dropFirst(7))) {
                source = s
            } else {
                source = .image
                filterText = link.payload
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let lib = selection.current
        let token = refreshToken
        AsyncContent(reloadKey: lib?.id ?? "") { () -> (PhotosLibrary, CaptionStats) in
            guard let lib else { throw PhotosError.noLibrary() }
            await PhotosCaches.shared.sync(token: token)
            return (lib, await CaptionStore.stats(lib))
        } content: { loaded in
            let lib = loaded.0
            let stats = loaded.1
            VStack(spacing: 0) {
                SectionStrip {
                    FittingSegmentedPicker(
                        label: "Source",
                        options: CaptionSource.allCases.map { s in
                            .init(value: s, title: "\(s.title) (\(Format.compact(stats.counts[s] ?? 0)))", shortTitle: s.title)
                        },
                        selection: Binding(get: { source }, set: { source = $0; selected = nil })
                    )
                } trailing: {
                    LibraryMenu()
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    SensitivityBadge(.sensitive)
                    Text(source.explanation + " Text stays hidden until you reveal a row.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if source == .image, stats.unsafeImages > 0 {
                        TagLabel("\(Format.count(stats.unsafeImages)) flagged unsafe", tint: .orange)
                    }
                    if source == .image, let c = stats.averageConfidence {
                        Text("mean confidence \(Format.percent(c, digits: 0))").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.vertical, 8)
                Divider()
                table(lib)
                    .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                        if let selected { inspector(selected) }
                    }
                StoreFooter(storeURL(lib, stats), note: storeNote)
            }
        }
    }

    private func storeURL(_ lib: PhotosLibrary, _ stats: CaptionStats) -> URL {
        switch source {
        case .image, .video, .videoSegment: return stats.mediaAnalysisURL ?? lib.expectedMediaAnalysisDB
        case .graph, .description, .ocr: return lib.photosDB
        }
    }

    private var storeNote: String {
        switch source {
        case .image: return "ZIMAGECAPTIONRESULT"
        case .video: return "ZVIDEOCAPTIONRESULT"
        case .videoSegment: return "ZVIDEOSEGMENTCAPTIONRESULT"
        case .graph: return "ZGRAPHNODE (label 1300), ZGRAPHNODEVALUE"
        case .description: return "ZASSETDESCRIPTION"
        case .ocr: return "search lexicon: text-in-image tokens per asset"
        }
    }

    private func table(_ lib: PhotosLibrary) -> some View {
        let source = source
        let store = reveal
        let isOCR = source == .ocr
        var columns: [PagedColumn<CaptionRow>] = [
            PagedColumn("Asset Date", id: "date", width: 150, min: 130, sortable: !isOCR, sensitivity: .personal) { DossierDate.sortable($0.date) },
            PagedColumn(isOCR ? "Recognised Text" : "Caption", id: "text", width: 620, min: 220, sortable: false, sensitivity: .sensitive) { row in
                store.isRevealed(row.id) ? row.text : "(hidden — reveal the row first)"
            }
            .cell { row in
                RevealCell(id: row.id, text: row.text, hiddenSummary: isOCR ? "\(Format.count(row.count)) words" : "\(row.count) characters", store: store)
            },
        ]
        if source == .image || source == .video || source == .videoSegment {
            columns.append(PagedColumn("Confidence", id: "confidence", width: 86, alignment: .trailing) { $0.confidence.map { Format.percent($0, digits: 0) } ?? "—" })
        }
        columns.append(PagedColumn(isOCR ? "Words" : "Length", id: "length", width: 70, alignment: .trailing, sortable: !isOCR) { Format.count($0.count) })
        if source == .image || source == .graph {
            columns.append(PagedColumn(source == .graph ? "Type" : "Flag", id: "flag", width: 70, sortable: false, secondary: true) { $0.flag })
        }
        if source == .videoSegment || source == .graph {
            columns.append(PagedColumn(source == .graph ? "Model" : "Segment", id: "detail", width: 120, sortable: false, secondary: true) { $0.detail })
        }
        columns.append(PagedColumn("Asset", id: "asset", width: 250, sortable: false, monospaced: true, secondary: true, hiddenByDefault: true) { $0.asset })
        return PagedTable(
            columns: columns,
            searchPrompt: isOCR ? "Find a word" : "Search captions",
            reloadKey: "\(lib.id)|\(source.rawValue)",
            exportName: "photos-\(source.rawValue)",
            emptyTitle: "Nothing Stored",
            filter: $filterText,
            fetch: { req in try await CaptionStore.rows(lib, source: source, request: req) },
            count: { req in try await CaptionStore.count(lib, source: source, search: req.search) },
            onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
        ) {
            RevealAllToggle(store: store)
        }
    }

    private func inspector(_ row: CaptionRow) -> some View {
        InspectorPage(title: source.title, subtitle: DossierDate.medium(row.date), sensitivity: .sensitive, onClose: { selected = nil }) {
            KeyValueGrid([
                KeyValueItem("Asset date", DossierDate.medium(row.date), sensitivity: .personal),
                KeyValueItem("Confidence", row.confidence.map { Format.percent($0) }),
                KeyValueItem(source == .ocr ? "Words" : "Characters", Format.count(row.count)),
                KeyValueItem("Flag", row.flag.isEmpty ? nil : row.flag),
                KeyValueItem("Detail", row.detail.isEmpty ? nil : row.detail),
                KeyValueItem("Asset identifier", row.asset.isEmpty ? nil : row.asset, monospaced: true),
            ].filter { $0.value != "—" && !$0.value.isEmpty })
            InspectorGroupTitle(source == .ocr ? "Recognised text" : "Caption")
            if reveal.isRevealed(row.id) {
                Text(row.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sensitive(.sensitive)
                Button("Hide Again") { reveal.toggle(row.id) }.controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    SensitivityBadge(.sensitive)
                    Button {
                        reveal.reveal(row.id)
                    } label: { Label("Reveal Text", systemImage: "eye") }
                    .controlSize(.small)
                }
                Text("This text describes or was read from one of your photos. It is only shown when you ask for it.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}
