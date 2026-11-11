import SwiftUI
import DossierCore

/// Places › Addresses: the postal address Photos attached to each photo (decoded from the
/// per-asset reverse-geocode archive) and its own "taken at home" flag.
struct AddressesPane: View {
    let library: PhotosLibrary
    @Binding var homeOnly: Bool
    @Binding var filterText: String
    @Environment(\.refreshToken) private var refreshToken
    @State private var selected: AssetAddressRow?
    @State private var flags: HomeFlags?
    @State private var flagsUnavailable = false
    /// Progress of the address pass that backs the filter field (nil = not running).
    @State private var reading: (done: Int, total: Int)?

    var body: some View {
        let lib = library
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                SensitivityBadge(.sensitive)
                Text("Photos resolves each photo’s coordinates to a postal address and stores it with the photo, together with its own verdict on whether the photo was taken at your home.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                homeStatus
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.vertical, 8)
            if let reading {
                HStack(spacing: 10) {
                    ProgressView(value: Double(reading.done), total: Double(max(reading.total, 1)))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                    Text("Reading addresses for the filter · \(Format.count(reading.done)) of \(Format.count(reading.total))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.bottom, 8)
            }
            Divider()
            table(lib)
                .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                    if let selected { AddressInspector(library: lib, row: selected, onClose: { self.selected = nil }) }
                }
            StoreFooter(lib.photosDB, note: "ZADDITIONALASSETATTRIBUTES.ZREVERSELOCATIONDATA (keyed archive per asset), ZASSET")
        }
        .task(id: "\(lib.id)|\(refreshToken)") {
            flags = nil; flagsUnavailable = false
            do {
                flags = try await SnapshotReadiness.track { try await ReverseGeoCache.shared.homeFlags(lib) }
            } catch {
                flagsUnavailable = !(error is CancellationError)
            }
            // The address pass is started by the table (first use of the filter field); show its progress.
            while !Task.isCancelled {
                let p = await ReverseGeoCache.shared.indexProgress(lib)
                if p?.done != reading?.done || p?.total != reading?.total { reading = p }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        .onDisappear {
            Task { await ReverseGeoCache.shared.cancelIndex(lib) }
        }
    }

    @ViewBuilder
    private var homeStatus: some View {
        if let flags {
            Text("\(Format.count(flags.home.count)) of \(Format.count(flags.total)) flagged at home")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .help("Archives whose isHome flag is set. Checked \(Format.count(flags.checked)) archives in \(String(format: "%.1f", flags.seconds)) s.")
            Toggle("At Home Only", isOn: $homeOnly)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .disabled(flags.home.isEmpty && !homeOnly)
        } else if flagsUnavailable {
            Text("At-home flags unavailable").font(.caption).foregroundStyle(.tertiary)
        } else {
            ProgressView().controlSize(.small)
            Text("Checking at-home flags…").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Asset keys a request is limited to: the at-home set and / or the addresses matching the filter text.
    private static func restriction(_ lib: PhotosLibrary, homeOnly: Bool, search: String) async throws -> [Int64]? {
        var only: Set<Int64>?
        if homeOnly { only = Set(try await ReverseGeoCache.shared.homeFlags(lib).home) }
        if !search.isEmpty {
            let index = try await ReverseGeoCache.shared.index(lib)
            try Task.checkCancellation()
            var matches = Set<Int64>()
            for (asset, line) in index.addresses where line.localizedCaseInsensitiveContains(search) { matches.insert(asset) }
            only = only.map { $0.intersection(matches) } ?? matches
        }
        return only.map(Array.init)
    }

    private func table(_ lib: PhotosLibrary) -> some View {
        let homeOnly = homeOnly
        return PagedTable(
            columns: [
                PagedColumn<AssetAddressRow>.date("Taken", id: "ZDATECREATED", width: 130, sensitivity: .personal) { $0.date },
                PagedColumn("Address", id: "address", width: 420, min: 200, sortable: false, sensitivity: .sensitive) { $0.decoded ? ($0.address.isEmpty ? "—" : $0.address) : "(archive not readable)" }
                    .cell { row in
                        HStack(spacing: 6) {
                            if row.isHome { HomeBadge() }
                            Text(row.decoded ? (row.address.isEmpty ? "—" : row.address) : "Archive not readable")
                                .font(.callout)
                                .foregroundStyle(row.decoded && !row.address.isEmpty ? .primary : .tertiary)
                                .lineLimit(1)
                                .sensitive(.sensitive)
                        }
                    },
                PagedColumn("At Home", id: "home", width: 64, sortable: false, hiddenByDefault: true) { $0.isHome ? "yes" : "" },
                PagedColumn("Country", id: "country", width: 62, sortable: false, sensitivity: .personal, secondary: true) { $0.countryCode },
                PagedColumn("Coordinates", id: "coordinates", width: 150, sortable: false, sensitivity: .sensitive, monospaced: true, secondary: true) { $0.coordinates },
                PagedColumn("Asset", id: "asset", width: 250, sortable: false, monospaced: true, secondary: true, hiddenByDefault: true) { $0.uuid },
            ],
            searchPrompt: "Filter addresses",
            reloadKey: "\(lib.id)|\(homeOnly)",
            exportName: homeOnly ? "photos-addresses-at-home" : "photos-addresses",
            emptyTitle: homeOnly ? "No Photos Flagged at Home" : "No Addresses",
            filter: $filterText,
            initialSort: PageSort(columnID: "ZDATECREATED", ascending: false),
            fetch: { req in
                let only = try await Self.restriction(lib, homeOnly: homeOnly, search: req.search)
                return try await ReverseGeoStore.rows(lib, only: only, request: req)
            },
            count: { req in
                if let only = try await Self.restriction(lib, homeOnly: homeOnly, search: req.search) { return only.count }
                return await ReverseGeoStore.archiveCount(lib)
            },
            onSelect: { rows in selected = rows.count == 1 ? rows.first : nil }
        )
    }
}

/// "At home" marker: Photos' verdict for this photo.
private struct HomeBadge: View {
    var body: some View {
        Label("At home", systemImage: "house.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(.green)
            .background(Color.green.opacity(0.13), in: Capsule())
            .fixedSize()
            .help("Photos flagged this photo as taken at your home (isHome in the reverse-geocode archive)")
    }
}

/// Inspector: the full archive of the selected asset, decoded on demand.
private struct AddressInspector: View {
    let library: PhotosLibrary
    let row: AssetAddressRow
    let onClose: () -> Void
    @State private var loaded: (id: Int64, info: ReverseGeoInfo?, bytes: Int)?

    var body: some View {
        let info = loaded?.id == row.id ? loaded?.info : nil
        InspectorPage(title: row.isHome ? "Taken at Home" : "Photo Address", subtitle: DossierDate.medium(row.date), sensitivity: .sensitive, onClose: onClose) {
            if row.isHome {
                HStack(spacing: 8) {
                    HomeBadge()
                    Text("Photos’ own judgement, stored with this photo.").font(.caption).foregroundStyle(.secondary)
                }
            }
            KeyValueGrid([
                KeyValueItem("Taken", DossierDate.medium(row.date), sensitivity: .personal),
                KeyValueItem("Address", row.address.isEmpty ? nil : row.address, sensitivity: .sensitive),
                KeyValueItem("Coordinates", row.coordinates, sensitivity: .sensitive, monospaced: true),
                KeyValueItem("Taken at home", row.decoded ? (row.isHome ? "Yes" : "No") : nil),
            ].filter { $0.value != "—" })
            if let info {
                if !info.postal.isEmpty {
                    InspectorGroupTitle("Postal address")
                    KeyValueGrid(info.postal.enumerated().map { KeyValueItem($0.element.label, $0.element.value, sensitivity: .sensitive, id: "postal\($0.offset)") })
                }
                if !info.places.isEmpty {
                    InspectorGroupTitle("Named places around it")
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(info.places) { place in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(place.name).font(.callout).lineLimit(1).sensitive(.sensitive)
                                Spacer(minLength: 6)
                                Text(Self.area(place.area)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                Text(place.level.map { "level \($0)" } ?? "").font(.caption2).foregroundStyle(.tertiary).frame(width: 46, alignment: .trailing)
                                    .help("placeType of the archive: 1 is the country, larger numbers are finer places")
                            }
                        }
                    }
                    Text("From the smallest named place to the country, with the area of each as the geocoder reported it.")
                        .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                InspectorGroupTitle("Archive")
                KeyValueGrid([
                    KeyValueItem("Geocoder", info.provider.isEmpty ? nil : info.provider),
                    KeyValueItem("Format version", info.version.map(String.init)),
                    KeyValueItem("Size", loaded.map { Format.bytes(Int64($0.bytes)) }),
                    KeyValueItem("Marked valid", row.valid.map { $0 ? "Yes" : "No" }),
                    KeyValueItem("Asset identifier", row.uuid.isEmpty ? nil : row.uuid, monospaced: true),
                ].filter { $0.value != "—" })
            } else if loaded?.id == row.id {
                Text("The archive of this photo could not be decoded.").font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: row.id) {
            let lib = library, asset = row.id
            let result = await SnapshotReadiness.track { try? await ReverseGeoStore.info(lib, asset: asset) }
            if !Task.isCancelled { loaded = (asset, result?.info, result?.bytes ?? 0) }
        }
    }

    private static func area(_ squareMetres: Double?) -> String {
        guard let a = squareMetres, a > 0 else { return "" }
        if a >= 1e6 { return Format.count(Int((a / 1e6).rounded())) + " km²" }
        return Format.count(Int(a.rounded())) + " m²"
    }
}
