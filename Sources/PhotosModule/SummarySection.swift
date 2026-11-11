import SwiftUI
import Charts
import DossierCore

/// (1) Library summary: assets by year / country / camera / source app and analysis coverage.
struct SummarySection: View {
    @ObservedObject private var selection = PhotosLibrarySelection.shared
    @Environment(\.refreshToken) private var refreshToken

    private struct Loaded: Sendable {
        let library: PhotosLibrary
        let summary: LibrarySummary
        let countries: [NamedCount]
        let stores: [StoreInfo]
        let graphNodes: Int?
        let captions: Int?
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionStrip {
                LibraryMenu()
                if let lib = selection.current {
                    Text(Format.tildePath(lib.root)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            } trailing: {
                Text("Read-only · no images are decoded").font(.caption).foregroundStyle(.tertiary)
            }
            content.requiresLibrary(selection.current)
        }
    }

    @ViewBuilder
    private var content: some View {
        let lib = selection.current
        let token = refreshToken
        AsyncContent(reloadKey: lib?.id ?? "") {
            guard let lib else { throw PhotosError.noLibrary() }
            await PhotosCaches.shared.sync(token: token)
            let summary = try await PhotosStore.summary(lib)
            var countries: [NamedCount] = []
            if let backend = await SearchIndexStore.preferredBackend(lib) {
                countries = (try? await SearchIndexStore.topTerms(lib, backend: backend, category: backend.countryCode, limit: 14)) ?? []
            }
            let graphURL = lib.graphDB
            let mediaURL = lib.mediaAnalysisDB
            var stores = [
                StoreInfo.file("Photos.sqlite", lib.photosDB, rowCount: summary.assets, timeRange: summary.range, note: "Assets, people, faces, moments, memories and the search lexicon"),
                StoreInfo.file("photosgraph.kgdb", graphURL ?? lib.expectedGraphDB, note: "Knowledge graph built by photoanalysisd: people, places, relationships, meanings"),
                StoreInfo.file("MediaAnalysis.sqlite", mediaURL ?? lib.expectedMediaAnalysisDB, note: "Captions, audio and motion analysis by mediaanalysisd"),
                StoreInfo.file("psi.sqlite", lib.psiDB, note: "Legacy search index (kept from earlier system versions)"),
            ]
            var graphNodes: Int?
            if let graphURL, let db = await SQLiteDB.sharedIfAvailable(graphURL), await db.tableExists("Node") {
                graphNodes = await db.rowCount(of: "Node")
                stores[1].rowCount = graphNodes
            }
            var captions: Int?
            if let mediaURL, let db = await SQLiteDB.sharedIfAvailable(mediaURL), await db.tableExists("ZIMAGECAPTIONRESULT") {
                captions = await db.rowCount(of: "ZIMAGECAPTIONRESULT")
                stores[2].rowCount = captions
            }
            if let db = await SQLiteDB.sharedIfAvailable(lib.psiDB), await db.tableExists("groups") { stores[3].rowCount = await db.rowCount(of: "groups") }
            return Loaded(library: lib, summary: summary, countries: countries, stores: stores, graphNodes: graphNodes, captions: captions)
        } content: { loaded in
            VStack(spacing: 0) {
                ScrollPage {
                    page(loaded)
                }
                StoreFooter(loaded.library.photosDB, note: "ZASSET, ZADDITIONALASSETATTRIBUTES, ZEXTENDEDATTRIBUTES, ZMEDIAANALYSISASSETATTRIBUTES")
            }
        }
    }

    @ViewBuilder
    private func page(_ loaded: Loaded) -> some View {
        let s = loaded.summary
        InfoNote("Photos analyses every picture and video on this Mac: it recognises faces, scenes and text, resolves locations, writes captions and builds a knowledge graph about your life. This module shows what those stores contain — as numbers, labels and text. It never opens an image.")

        StatTileRow([
            Stat("Assets", Format.compact(s.assets), caption: "\(Format.count(s.photos)) photos · \(Format.count(s.videos)) videos", symbol: "photo.stack", tint: .blue),
            Stat("Time Span", s.range.map { yearSpan($0) } ?? "—", caption: "first to last capture date", symbol: "calendar", tint: .orange, sensitivity: .personal),
            Stat("With Location", Format.compact(s.withLocation), caption: s.assets > 0 ? Format.percent(Double(s.withLocation) / Double(s.assets), digits: 0) + " of the library" : nil, symbol: "mappin.and.ellipse", tint: .red),
            Stat("People", Format.compact(s.namedPersons), caption: "named" + (s.namedPets > 0 ? " + \(Format.count(s.namedPets)) pet\(s.namedPets == 1 ? "" : "s")" : "") + " · \(Format.count(s.persons)) clusters", symbol: "person.crop.rectangle.stack", tint: .purple),
            Stat("Faces", Format.compact(s.faces), caption: "detected and described", symbol: "faceid", tint: .pink),
            Stat("Scene Labels", Format.compact(s.sceneClassifications), caption: "classifier results stored", symbol: "tag", tint: .teal),
            Stat("Moments", Format.compact(s.moments), caption: "\(Format.count(s.highlights)) highlights", symbol: "clock.arrow.circlepath", tint: .indigo),
            Stat("Memories", Format.compact(s.memories), caption: "generated stories", symbol: "sparkles.rectangle.stack", tint: .yellow),
        ])

        SectionHeader("Assets per Year", subtitle: "Capture date of every photo and video that is not in the trash", symbol: "chart.bar")
        YearChart(years: s.years).card()

        AdaptiveColumns(minWidth: 300) {
            TitledCard("Countries", subtitle: "Assets per country, as indexed for search from reverse-geocoded locations", symbol: "globe.europe.africa") {
                RankList(loaded.countries, tint: .red, sensitivity: .sensitive, limit: 8)
            }
            TitledCard("Cameras", subtitle: "Make and model recorded in the image metadata", symbol: "camera") {
                RankList(s.cameras, tint: .orange, sensitivity: .personal, limit: 8)
            }
            TitledCard("Source Apps", subtitle: "The app that saved each asset into the library", symbol: "square.and.arrow.down") {
                RankList(s.sources, tint: .green, sensitivity: .personal, limit: 8)
            }
            TitledCard("Media Types", subtitle: "Kind and subtype codes of ZASSET", symbol: "square.stack.3d.up") {
                RankList(s.subtypes, tint: .blue, limit: 8)
            }
        }

        SectionHeader("Analysis Coverage", subtitle: "How many assets each on-device analysis has processed (a version number greater than zero is stored per asset)", symbol: "checklist")
        CoverageList(rows: s.coverage).card()

        SectionHeader("Stores", subtitle: "The files inside the library bundle this module reads", symbol: "internaldrive")
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(loaded.stores.enumerated()), id: \.element.id) { index, store in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: store.availability.isAvailable ? "cylinder.split.1x2" : "exclamationmark.triangle")
                        .foregroundStyle(store.availability.isAvailable ? Color.secondary : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.name).font(.callout.weight(.medium))
                        Text(store.note ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.availability.isAvailable {
                        if let rows = store.rowCount { Text("\(Format.count(rows)) rows").font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                        Text(Format.bytes(store.sizeBytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 76, alignment: .trailing)
                    } else {
                        TagLabel(store.availability.label, tint: .orange)
                    }
                }
                .padding(.vertical, 7)
                if index < loaded.stores.count - 1 { Divider() }
            }
        }
        .card()
    }

    private func yearSpan(_ range: ClosedRange<Date>) -> String {
        let cal = Calendar.current
        let a = cal.component(.year, from: range.lowerBound), b = cal.component(.year, from: range.upperBound)
        return a == b ? String(a) : "\(a)–\(b)"
    }
}
