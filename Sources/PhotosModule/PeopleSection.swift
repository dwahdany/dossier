import SwiftUI
import Charts
import DossierCore

/// (2) People: recognised persons with face counts, naming / verification state, contact link, and
/// the aggregate of the coded face attributes — per person, or for all faces when nothing is selected.
struct PeopleSection: View {
    @ObservedObject private var selection = PhotosLibrarySelection.shared
    @Environment(\.deepLink) private var deepLink
    @State private var filter: PhotosStore.PersonFilter = .named
    @State private var selected: PhotosStore.PersonRow?
    @State private var filterText = ""
    /// Persons merged into another one keep their row and name; they are hidden unless asked for.
    @State private var showMerged = false
    @State private var mergedCount = 0

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (filter, selected, filterText, showMerged)
        VStack(spacing: 0) {
            SectionStrip {
                Picker("Show", selection: $filter) {
                    ForEach(PhotosStore.PersonFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .layoutPriority(1)
                StripCaption("Face clusters Photos built, and what its classifiers concluded about each face")
            } trailing: {
                LibraryMenu()
            }
            if let lib = selection.current {
                HStack(spacing: 0) {
                    table(lib).frame(minWidth: 380, idealWidth: 470, maxWidth: 520)
                    Divider()
                    PersonDetail(library: lib, person: selected, onClear: { selected = nil })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                StoreFooter(lib.photosDB, note: "ZPERSON, ZDETECTEDFACE")
            } else {
                StatePlaceholder.missing("No Photos library was found in ~/Pictures. Use the library menu to choose one.")
            }
        }
        .task(id: "\(selection.current?.id ?? "")|\(filter.rawValue)") {
            guard let lib = selection.current else { mergedCount = 0; return }
            let filter = filter
            mergedCount = await SnapshotReadiness.track { await PhotosStore.mergedPersonCount(lib, filter: filter) }
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink, link.payload.hasPrefix("person:"), let pk = Int64(link.payload.dropFirst(7)), let lib = selection.current else { return }
            Task {
                if let row = try? await PhotosStore.person(lib, pk: pk) {
                    filter = row.isNamed ? .named : .all
                    if row.merged { showMerged = true }
                    filterText = row.isNamed ? row.title : ""
                    selected = row
                }
            }
        }
    }

    private func table(_ lib: PhotosLibrary) -> some View {
        let filter = filter
        let showMerged = showMerged
        return PagedTable(
            columns: [
                PagedColumn<PhotosStore.PersonRow>("Person", id: "ZFULLNAME", width: 160, min: 110, sensitivity: .sensitive) { $0.title }
                    .cell { row in
                        HStack(spacing: 5) {
                            Text(row.title).foregroundStyle(row.isNamed ? .primary : .secondary).lineLimit(1).sensitive(.sensitive)
                            if row.type == 1 { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.pink).help("Favourite") }
                            if row.hasContact { Image(systemName: "person.crop.circle.badge.checkmark").font(.caption2).foregroundStyle(.blue).help("Linked to a contact") }
                            if row.detection != nil && row.detection != 1 { Image(systemName: "pawprint.fill").font(.caption2).foregroundStyle(.brown).help("Pet") }
                            if row.merged { TagLabel("merged", tint: .gray).help("Merged into another person: this row is a leftover duplicate and holds no faces of its own") }
                        }
                    },
                PagedColumn("Faces", id: "faces", width: 62, alignment: .trailing) { Format.count($0.faces) },
                PagedColumn("Verified", id: "ZVERIFIEDTYPE", width: 134) { PhotosCodes.verifiedType.shortLabel($0.verified) },
                PagedColumn("Gender", id: "ZGENDERTYPE", width: 70, hiddenByDefault: true) { $0.gender == 0 ? "—" : PhotosCodes.faceAttributes[1].table.shortLabel($0.gender) },
                PagedColumn("Age", id: "ZAGETYPE", width: 90, hiddenByDefault: true) { $0.age == 0 ? "—" : PhotosCodes.faceAttributes[0].table.shortLabel($0.age) },
                PagedColumn("Type", id: "ZTYPE", width: 76, hiddenByDefault: true) { PhotosCodes.personType.shortLabel($0.type) },
                PagedColumn("Kind", id: "ZDETECTIONTYPE", width: 90, hiddenByDefault: true) { PhotosCodes.detectionType.shortLabel($0.detection) },
                PagedColumn("Row", id: "Z_PK", width: 56, alignment: .trailing, secondary: true, hiddenByDefault: true) { String($0.id) },
            ],
            searchPrompt: "Filter people",
            reloadKey: "\(lib.id)|\(filter.rawValue)|\(showMerged)",
            exportName: "photos-people",
            emptyTitle: "No People",
            filter: $filterText,
            initialSort: PageSort(columnID: "faces", ascending: false),
            fetch: { req in try await PhotosStore.persons(lib, filter: filter, includeMerged: showMerged, request: req) },
            count: { req in try await PhotosStore.personCount(lib, filter: filter, includeMerged: showMerged, search: req.search) },
            onSelect: { rows in if rows.count == 1 { selected = rows.first } else if rows.isEmpty { selected = nil } }
        ) {
            if mergedCount > 0 || showMerged {
                Toggle("Show merged (\(Format.count(mergedCount)))", isOn: $showMerged)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.caption)
                    .help("Persons that were merged into another person keep a row with the same name and no faces. They are hidden by default.")
            }
        }
    }
}

/// Right-hand pane: header for the selected person (or the whole library) and the attribute distributions.
private struct PersonDetail: View {
    let library: PhotosLibrary
    let person: PhotosStore.PersonRow?
    let onClear: () -> Void

    private struct Loaded: Sendable {
        let profile: PhotosStore.FaceProfile
        let stats: PhotosStore.PeopleStats?
        let graph: GPerson?
        let relationships: [GRelationship]
    }

    var body: some View {
        let lib = library
        let person = person
        AsyncContent(reloadKey: "\(lib.id)|\(person?.id ?? -1)") {
            let profile = try await PhotosStore.faceProfile(lib, person: person?.id)
            let stats = person == nil ? try? await PhotosStore.peopleStats(lib) : nil
            var graphPerson: GPerson?
            var relationships: [GRelationship] = []
            if let person, !person.uuid.isEmpty, let (_, inf) = try? await PhotosCaches.shared.graph(for: lib) {
                graphPerson = inf.people.first { $0.uuid == person.uuid }
                relationships = inf.relationships.filter { $0.personUUID == person.uuid }
            }
            return Loaded(profile: profile, stats: stats, graph: graphPerson, relationships: relationships)
        } content: { loaded in
            ScrollPage {
                header(loaded)
                if !loaded.profile.years.isEmpty {
                    SectionHeader(person == nil ? "Assets with Faces per Year" : "Appearances per Year", subtitle: "Distinct assets in which a face was detected", symbol: "chart.bar")
                    YearChart(years: loaded.profile.years, firstLabel: "Assets", secondLabel: nil, height: 130).card()
                }
                SectionHeader("Inferred Face Attributes",
                              subtitle: "Each detected face is run through classifiers; the class per face is stored as an integer code. Bars show how often each code was assigned\(person == nil ? " across all faces" : " to this person’s faces"). Labels are given only where the meaning is established — everything else is the raw code.",
                              symbol: "faceid") { SensitivityBadge(.sensitive) }
                let useful = loaded.profile.distributions.filter { $0.distinctAnalysed > 0 }
                if useful.isEmpty {
                    StatePlaceholder(title: "No Attributes", symbol: "faceid", message: "None of these faces has been through the attribute classifiers yet.")
                        .frame(height: 160)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(useful) { CodeDistributionView(distribution: $0) }
                    }
                    let empty = loaded.profile.distributions.filter { $0.distinctAnalysed == 0 }
                    if !empty.isEmpty {
                        Text("Columns that exist but hold no classification here: " + empty.map { "\($0.attribute.title) (\($0.attribute.column))" }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func header(_ loaded: Loaded) -> some View {
        let p = loaded.profile
        if let person {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(person.title).font(.title2.weight(.semibold)).lineLimit(1).sensitive(.sensitive)
                Spacer()
                Button("Show All Faces", action: onClear).controlSize(.small)
            }
            HStack(spacing: 6) {
                if person.type == 1 { TagLabel("Favourite", tint: .pink) }
                if person.type == -1 { TagLabel("Hidden", tint: .gray) }
                if person.hasContact { TagLabel("Contact linked", tint: .blue) }
                if person.merged { TagLabel("Merged away", tint: .gray) }
                if loaded.graph?.isMe == true { TagLabel("Me", tint: .green) }
                ForEach(loaded.relationships.prefix(6)) { rel in
                    TagLabel("Graph: " + rel.type.lowercased() + (rel.confidence.map { " " + Format.percent($0, digits: 0) } ?? ""), tint: .purple)
                }
                Spacer(minLength: 0)
            }
            StatTileRow([
                Stat("Faces", Format.count(p.faces), caption: "assigned to this person", symbol: "faceid", tint: .pink),
                Stat("Assets", Format.count(p.assets), caption: "photos and videos", symbol: "photo.stack", tint: .blue),
                Stat("First Seen", DossierDate.day(p.range?.lowerBound), symbol: "calendar", tint: .orange, sensitivity: .personal),
                Stat("Last Seen", DossierDate.day(p.range?.upperBound), symbol: "calendar.badge.clock", tint: .orange, sensitivity: .personal),
            ], minTileWidth: 130)
            // Decoded labels only; the column name and stored integer are in each value's tooltip.
            HintedGrid([
                HintedItem("Verification", code: person.verified, table: PhotosCodes.verifiedType, column: "ZVERIFIEDTYPE"),
                HintedItem("Detection kind", code: person.detection, table: PhotosCodes.detectionType, column: "ZDETECTIONTYPE"),
                HintedItem("Person-level gender", code: person.gender, table: PhotosCodes.faceAttributes[1].table, column: "ZGENDERTYPE", unset: "Not set", sensitivity: .sensitive),
                HintedItem("Person-level age", code: person.age, table: PhotosCodes.faceAttributes[0].table, column: "ZAGETYPE", unset: "Not set", sensitivity: .sensitive),
                HintedItem("Stored face count", Format.count(person.faceCount), hint: "ZFACECOUNT — a cached counter; \(Format.count(p.faces)) faces actually point at this person"),
                HintedItem("“Is me” confidence", person.meConfidence.map { Format.number($0) }, hint: "ZISMECONFIDENCE"),
                HintedItem("Graph: moments present", loaded.graph.map { "\(Format.count($0.moments)) moments · \(Format.count($0.assets)) assets" }),
                HintedItem("Graph: relationship tags", loaded.graph.flatMap { $0.tags.isEmpty ? nil : $0.tags.joined(separator: ", ") }, sensitivity: .sensitive),
                HintedItem("Graph: activities", loaded.graph.flatMap { $0.activities.isEmpty ? nil : $0.activities.joined(separator: ", ") }, sensitivity: .sensitive),
                HintedItem("Graph: birthday", loaded.graph?.birthday.map { DossierDate.day($0) }, sensitivity: .sensitive),
                HintedItem("Mean face quality", p.quality.map { Format.number($0) }, hint: "Average ZQUALITY of this person’s faces"),
                HintedItem("Person UUID", person.uuid.isEmpty ? nil : person.uuid, monospaced: true),
            ], labelWidth: 170)
            .card()
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("All Faces").font(.title2.weight(.semibold))
                Text("Select a person to see their profile").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            if let s = loaded.stats {
                StatTileRow([
                    Stat("Named", Format.count(s.people.namedPeople), caption: s.people.namedPets > 0 ? "people · + \(Format.count(s.people.namedPets)) pet\(s.people.namedPets == 1 ? "" : "s")" : "people with a name", symbol: "person.text.rectangle", tint: .blue, sensitivity: .personal),
                    Stat("Face Clusters", Format.compact(s.people.clusters), caption: "excl. \(Format.count(s.people.merged)) merged", symbol: "person.crop.rectangle.stack", tint: .purple),
                    Stat("Confirmed by You", Format.count(s.people.verified), caption: "\(Format.count(s.people.withContact)) linked to a contact", symbol: "checkmark.seal", tint: .green),
                    Stat("Faces", Format.compact(s.faces), caption: "\(Format.count(s.facesAssigned)) assigned to a cluster", symbol: "faceid", tint: .pink),
                    Stat("Classified", Format.compact(s.facesAnalysed), caption: s.faces > 0 ? Format.percent(Double(s.facesAnalysed) / Double(s.faces), digits: 0) + " carry attributes" : nil, symbol: "wand.and.stars", tint: .orange),
                    Stat("Pets", Format.count(s.people.petClusters), caption: "non-human clusters", symbol: "pawprint", tint: .brown),
                ], minTileWidth: 130)
            }
        }
    }
}
