import SwiftUI
import DossierCore

/// Section 5 — Focus mode configuration (allowed apps and people, triggers incl.
/// geofences) and the activation history.
struct FocusView: View {
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @State private var selectedID: String?

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = selectedID
        let token = refreshToken
        AsyncContent(reloadKey: token) {
            let data = try await FocusLoader.load(token: token)
            if data.modes.isEmpty && data.events.isEmpty {
                if case .inaccessible(let reason) = data.cacheAvailability { throw DossierError.inaccessible(reason) }
                throw DossierError.missing("No Focus configuration cache was found. It appears once Focus modes have been set up or synced to this Mac.")
            }
            return data
        } content: { data in
            content(data)
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            if let payload = deepLink?.payload, !payload.isEmpty { selectedID = payload }
        }
    }

    private func content(_ data: FocusData) -> some View {
        let mode = data.modes.first { $0.id == selectedID } ?? data.modes.first
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: Binding(get: { mode?.id }, set: { selectedID = $0 })) {
                    Section("Focus Modes") {
                        ForEach(data.modes) { m in
                            HStack(spacing: 9) {
                                Image(systemName: EnvSymbol.available(m.symbol))
                                    .foregroundStyle(.white)
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(width: 26, height: 26)
                                    .background(EnvColor.named(m.tintName).gradient, in: Circle())
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.name).font(.callout).lineLimit(1).sensitive(.personal)
                                    Text(summary(m)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .padding(.vertical, 2)
                            .tag(m.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 260)
                Divider()
                if let mode {
                    FocusDetail(mode: mode, events: data.events, counts: (data.computedCount, data.inferredCount, data.assertionCount))
                } else {
                    StatePlaceholder(title: "No Focus Modes", symbol: "moon.zzz", message: "The configuration cache holds no modes; only the activity log is available.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            StoreFooter(EnvPaths.focusCache, note: "plus UserFocus.* Biome streams and DoNotDisturb assertions")
        }
    }

    private func summary(_ m: FocusMode) -> String {
        var parts: [String] = []
        if !m.allowedApps.isEmpty { parts.append("\(m.allowedApps.count) apps") }
        if !m.allowedContacts.isEmpty { parts.append("\(m.allowedContacts.count) people") }
        let silenced = m.deniedContacts.count + m.deniedApps.count
        if silenced > 0 { parts.append("\(silenced) silenced") }
        if m.triggers.contains(where: { $0.latitude != nil }) { parts.append("geofence") }
        else if !m.triggers.isEmpty { parts.append("\(m.triggers.count) trigger\(m.triggers.count == 1 ? "" : "s")") }
        return parts.isEmpty ? "No exceptions configured" : parts.joined(separator: " · ")
    }
}

private struct FocusDetail: View {
    let mode: FocusMode
    let events: [FocusEvent]
    let counts: (computed: Int, inferred: Int, assertions: Int)

    var body: some View {
        let tint = EnvColor.named(mode.tintName)
        ScrollPage {
            HStack(spacing: 14) {
                Image(systemName: EnvSymbol.available(mode.symbol))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(tint.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.name).font(.title2.weight(.semibold)).sensitive(.personal)
                    Text(mode.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle).help(mode.id)
                }
                Spacer()
                if mode.automaticallyGenerated { TagLabel("generated by the system", tint: .secondary) }
            }
            EnvTiles([
                Stat("Allowed Apps", Format.count(mode.allowedApps.count), caption: mode.deniedApps.isEmpty ? "may notify during this Focus" : "\(mode.deniedApps.count) silenced", symbol: "app.badge", tint: tint),
                Stat("Allowed People", Format.count(mode.allowedContacts.count), caption: mode.deniedContacts.isEmpty ? "may reach you" : "\(mode.deniedContacts.count) silenced", symbol: "person.2", tint: tint),
                Stat("Triggers", Format.count(mode.triggers.count), caption: mode.triggers.contains { $0.latitude != nil } ? "includes a location" : "automation rules", symbol: "bolt", tint: tint),
                Stat("Last Changed", DossierDate.day(mode.modified), caption: mode.created.map { "created " + DossierDate.day($0) }, symbol: "calendar", tint: tint),
            ])

            if !mode.triggers.isEmpty {
                SectionHeader("Triggers", subtitle: "What switches this Focus on automatically", symbol: "bolt")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(mode.triggers.enumerated()), id: \.element.id) { index, trigger in
                        if index > 0 { Divider().padding(.vertical, 8) }
                        TriggerRow(trigger: trigger, mapTitle: trigger.regionName ?? mode.name, tint: tint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }

            if !mode.allowedApps.isEmpty || !mode.deniedApps.isEmpty {
                SectionHeader("Apps", subtitle: "Per platform — the configuration is shared by all your devices. Hover for the bundle identifier.", symbol: "app.badge")
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Dictionary(grouping: mode.allowedApps, by: \.platformName).sorted { $0.key < $1.key }, id: \.key) { platform, apps in
                        appGroup("Allowed · \(platform)", apps, tint: .green)
                    }
                    if !mode.deniedApps.isEmpty { appGroup("Silenced", mode.deniedApps, tint: .red) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }

            if !mode.allowedContacts.isEmpty || !mode.deniedContacts.isEmpty {
                SectionHeader("People", subtitle: "Contacts stored inside the Focus configuration with their phone numbers and addresses", symbol: "person.2")
                VStack(alignment: .leading, spacing: 8) {
                    contactRows("Allowed", mode.allowedContacts, tint: .green)
                    contactRows("Silenced", mode.deniedContacts, tint: .red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }

            SectionHeader("Stored Settings", subtitle: "Remaining switches exactly as stored (numeric codes of the DoNotDisturb framework)", symbol: "slider.horizontal.3")
            KeyValueGrid(
                [KeyValueItem("Colour / symbol", "\(mode.tintName) · \(mode.symbol)"),
                 KeyValueItem("Semantic type", mode.semanticType.map(String.init)),
                 KeyValueItem("Last changed by", mode.modifiedByVersion.isEmpty ? nil : "DoNotDisturb \(mode.modifiedByVersion)"),
                 KeyValueItem("Created", DossierDate.medium(mode.created)),
                 KeyValueItem("Modified", DossierDate.medium(mode.modified))]
                    + mode.settings.items(sensitivity: .low)
            ).card()

            let mine = events.filter { $0.mode == mode.name || $0.mode == mode.id }
            SectionHeader("Activity", subtitle: "\(Format.count(mine.count)) entries for this Focus · \(Format.count(events.count)) in total (computed \(counts.computed), inferred \(counts.inferred), sessions \(counts.assertions))", symbol: "clock.arrow.circlepath")
            FocusEventsTable(events: mine.isEmpty ? events : mine, showingAll: mine.isEmpty)
        }
    }

    private func appGroup(_ title: String, _ apps: [FocusApp], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(apps) { app in
                    AppLabel(bundle: app.bundle, size: 14)
                        .font(.caption.weight(.medium))
                        .padding(.leading, 5).padding(.trailing, 8).padding(.vertical, 3)
                        .background(tint.opacity(0.13), in: Capsule())
                        .fixedSize()
                        .sensitive(.personal)
                }
            }
        }
    }

    @ViewBuilder private func contactRows(_ title: String, _ contacts: [FocusContact], tint: Color) -> some View {
        if !contacts.isEmpty {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(contacts) { contact in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "person.crop.circle").foregroundStyle(tint)
                    Text(contact.name).font(.callout.weight(.medium)).sensitive(.sensitive)
                    Text(contact.handles.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).sensitive(.sensitive)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// One automation trigger. A geofence shows its map beside the text when the row is wide
/// enough for both, otherwise underneath — the map must never squeeze the text away or
/// raise the section's minimum width.
private struct TriggerRow: View {
    let trigger: FocusTrigger
    let mapTitle: String
    let tint: Color

    var body: some View {
        if let lat = trigger.latitude, let lon = trigger.longitude {
            let map = PointMapView([MapPoint(id: trigger.id, latitude: lat, longitude: lon, title: mapTitle, radius: trigger.radius)], tint: tint)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    text.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    map.frame(width: 280, height: 150)
                }
                VStack(alignment: .leading, spacing: 10) {
                    text
                    map.frame(maxWidth: 420).frame(height: 150).padding(.leading, 34)
                }
            }
        } else {
            text
        }
    }

    private var text: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: trigger.symbol).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(trigger.kind).font(.callout.weight(.medium))
                    TagLabel(trigger.stateLabel, tint: trigger.enabledSetting == 1 ? .green : .secondary)
                }
                if !trigger.detail.isEmpty {
                    Text(trigger.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .sensitive(trigger.latitude != nil ? .sensitive : .low)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct FocusEventsTable: View {
    let events: [FocusEvent]
    let showingAll: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showingAll {
                Text("No entries for this Focus — showing the complete log.").font(.caption).foregroundStyle(.secondary)
            }
            PagedTable(
                rows: events,
                columns: [
                    PagedColumn<FocusEvent>("Time", id: "date", width: 150) { DossierDate.sortable($0.date) },
                    PagedColumn("Event", id: "event", width: 110) { $0.event },
                    PagedColumn("Focus", id: "mode", width: 150, sensitivity: .personal) { $0.mode },
                    PagedColumn("Until", id: "end", width: 150) { $0.end.map { DossierDate.sortable($0) } ?? "" },
                    PagedColumn("Details", id: "detail", width: 260, secondary: true) { $0.detail },
                    PagedColumn("Log", id: "source", width: 180, secondary: true) { $0.source },
                ].readableMinimums(),
                searchPrompt: "Filter activity",
                reloadKey: AnyHashable([AnyHashable(events.count), AnyHashable(events.first?.id ?? "")]),
                exportName: "focus-activity",
                emptyTitle: "No Focus Activity Logged"
            )
            .tableCard(height: embeddedTableHeight(rows: events.count, max: 320))
        }
    }
}
