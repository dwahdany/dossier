import Charts
import DossierCore
import SwiftUI

/// (6) Predictions & routine model: what DuetExpert ("ATX", the engine behind Siri
/// Suggestions, Spotlight's app row and the suggested Dock / menu items) expects you to do.
struct PredictionsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case apps = "App Predictions", anchors = "Triggers & Follow-ups", menu = "Menus & Documents", dose = "Daily Dose", more = "Modes & Recents"
        var id: String { rawValue }
        var shortTitle: String {
            switch self {
            case .apps: return "Apps"
            case .anchors: return "Triggers"
            case .menu: return "Menus & Docs"
            case .dose: return "Daily Dose"
            case .more: return "Modes"
            }
        }
        var payload: String {
            switch self {
            case .apps: return "apps"
            case .anchors: return "anchors"
            case .menu: return "menu"
            case .dose: return "dose"
            case .more: return "more"
            }
        }
    }

    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @State private var tab: Tab = .apps

    private struct Loaded: Sendable {
        let duet: DuetSnapshot
        let games: GamesSource.Result
    }

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = tab
        VStack(spacing: 0) {
            HeaderStrip {
                // Five long segment titles need about 730 pt: fall back to short titles, then
                // to a menu, instead of pushing the section wider than the window.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        tabPicker(short: false)
                        Spacer(minLength: 0)
                        Text("DuetExpert (proactive suggestions engine)").font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                    HStack(spacing: 0) { tabPicker(short: false); Spacer(minLength: 0) }
                    HStack(spacing: 0) { tabPicker(short: true); Spacer(minLength: 0) }
                    HStack(spacing: 0) {
                        Picker("View", selection: $tab) {
                            ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                        Spacer(minLength: 0)
                    }
                }
            }
            AsyncContent(reloadKey: refreshToken, emptyTitle: "No Prediction Data", emptySymbol: "wand.and.stars") {
                await ActivityStore.shared.sync(token: refreshToken)
                let duet = await ActivityStore.shared.duet()
                switch duet.availability {
                case .inaccessible(let reason): throw DossierError.inaccessible(reason)
                case .missing: throw DossierError.missing("~/Library/DuetExpertCenter does not exist on this Mac.")
                case .available: break
                }
                return Loaded(duet: duet, games: await GamesSource.load())
            } content: { loaded in
                VStack(spacing: 0) {
                    ScrollPage {
                        switch tab {
                        case .apps: appsTab(loaded.duet)
                        case .anchors: anchorsTab(loaded.duet)
                        case .menu: menuTab(loaded.duet)
                        case .dose: doseTab(loaded.duet)
                        case .more: moreTab(loaded)
                        }
                    }
                    StoreFooter(DuetPaths.root, note: footerNote)
                }
            }
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink, link.payload.hasPrefix("tab:") else { return }
            let name = link.payload.dropFirst(4)
            if let t = Tab.allCases.first(where: { $0.payload == name }) { tab = t }
        }
    }

    private func tabPicker(short: Bool) -> some View {
        Picker("View", selection: $tab) {
            ForEach(Tab.allCases) { Text(short ? $0.shortTitle : $0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    private var footerNote: String {
        switch tab {
        case .apps: return "ClientModelCaches/atx_app_predictions_* · _ATXDataStore.db appInfo"
        case .anchors: return "_ATXDataStore.db anchorType, anchorOccurrence, anchorModelTrainingData"
        case .menu: return "caches/ATXCacheFile-MenuItemPredictions, ATXDocumentPredictorScores-* · _ATXDataStore.db alog"
        case .dose: return "_ATXAppDailyDose_CurrentDose, _ATXAppDailyDose_HistoricalDose"
        case .more: return "streams/appLaunchInferredMode · _ATXDataStore.db appLaunchSequence · Biome databases Games.RecentlyPlayed"
        }
    }

    // MARK: App predictions

    @ViewBuilder private func appsTab(_ duet: DuetSnapshot) -> some View {
        ExplainerText("Before you open Spotlight, Launchpad or the suggested-apps row, the system has already ranked the apps it thinks you will want next. These are the current rankings, straight from the prediction cache\(duet.predictionsUpdated.map { " (written \(DossierDate.relative($0)))" } ?? ""). A higher score means the model is more confident; the reason text is the one the system attaches itself.")
        if duet.consumers.isEmpty {
            StatePlaceholder(title: "No App Predictions Cached", symbol: "wand.and.stars", message: "ClientModelCaches holds no atx_app_predictions files right now.")
                .frame(height: 220)
        } else {
            let groups = duet.predictionGroups
            // One card per distinct ranking; several rankings wrap instead of squeezing.
            LazyVGrid(columns: [groups.count == 1 ? GridItem(.flexible(), alignment: .top) : GridItem(.adaptive(minimum: 300), spacing: Metrics.blockSpacing, alignment: .top)], alignment: .leading, spacing: Metrics.blockSpacing) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    let list = group.list
                    let shown = groups.count == 1 ? 30 : 15
                    let maxScore = max(list.first?.score ?? 1, 0.0001)
                    TitledCard(group.title, subtitle: "\(list.count) apps ranked · top \(min(shown, list.count)) shown" + (groups.count == 1 && duet.consumers.count > 1 ? " · all \(duet.consumers.count) surfaces currently share one ranking" : ""), symbol: Self.consumerSymbol(group.title)) {
                        let columns = groups.count == 1 ? 2 : 1
                        let perColumn = Int((Double(min(shown, list.count)) / Double(columns)).rounded(.up))
                        HStack(alignment: .top, spacing: 28) {
                            ForEach(0..<columns, id: \.self) { c in
                                VStack(spacing: 0) {
                                    ForEach(list.dropFirst(c * perColumn).prefix(perColumn)) { p in
                                        RankedAppRow(rank: p.rank, bundle: p.bundle, name: p.name, detail: nil, fraction: p.score / maxScore, value: Format.number(p.score, maxDigits: 1), tint: .purple)
                                            .help(p.reason.isEmpty ? p.bundle : "\(p.reason) · \(p.bundle)")
                                    }
                                }
                            }
                        }
                        if let reason = list.first?.reason, !reason.isEmpty {
                            Text("Reason given by the system: “\(reason)”." + (list.contains { $0.score < 0 } ? " Apps with a negative score are currently held back by the model." : "")).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        let learned = duet.appInfo.values.filter { $0.lastLaunch != nil && !$0.nextLaunches.isEmpty }.sorted { ($0.lastLaunch ?? .distantPast) > ($1.lastLaunch ?? .distantPast) }
        if !learned.isEmpty {
            TitledCard("Learned App-to-App Transitions", subtitle: "For each app, the apps most often launched right after it (time-decayed counts in appInfo.subsequentLaunchCounts)", symbol: "arrow.triangle.branch") {
                VStack(spacing: 0) {
                    ForEach(Array(learned.prefix(12).enumerated()), id: \.offset) { _, info in
                        HStack(spacing: 10) {
                            AppLabel(bundle: info.bundle).font(.callout).lineLimit(1).frame(minWidth: 110, idealWidth: 190, maxWidth: 190, alignment: .leading)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                            // As many follow-up apps as fit with their full names, at least one.
                            ViewThatFits(in: .horizontal) {
                                ForEach([4, 3, 2, 1], id: \.self) { n in
                                    HStack(spacing: 12) {
                                        ForEach(Array(info.nextLaunches.prefix(n).enumerated()), id: \.offset) { _, next in
                                            HStack(spacing: 4) {
                                                AppIcon(bundle: next.bundle, size: 14)
                                                Text(AppNames.name(next.bundle)).font(.callout).lineLimit(1).fixedSize(horizontal: n > 1, vertical: false)
                                                Text(Format.number(next.score, maxDigits: 1)).font(.caption2).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if let gap = info.medianGap {
                                Text("every \(Format.usage(gap))").font(.caption).monospacedDigit().foregroundStyle(.secondary).fixedSize().help("Median time between launches")
                            }
                        }
                        .padding(.vertical, 4)
                        .sensitive(.personal)
                        Divider()
                    }
                }
                Text("\(duet.appInfo.count) apps known to the model, \(duet.appInfo.values.filter { $0.lastLaunch != nil }.count) launched at least once. \(duet.histogramCount) further launch histograms (by hour, weekday, location hash, Wi-Fi…) are stored with hashed keys and cannot be mapped back to apps without the system's salt.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func consumerSymbol(_ consumer: String) -> String {
        if consumer.contains("·") { return "wand.and.stars" }
        if consumer.contains("Spotlight") { return "magnifyingglass" }
        if consumer.contains("Library") { return "square.grid.3x3" }
        return "dock.rectangle"
    }

    // MARK: Anchors

    @ViewBuilder private func anchorsTab(_ duet: DuetSnapshot) -> some View {
        ExplainerText("An “anchor” is a moment the system treats as a trigger: plugging in the charger, connecting headphones, arriving at or leaving a known place, waking the Mac after a long idle period. For every anchor it logs what you did in the minutes afterwards and uses that to suggest the same apps and actions next time.")
        if duet.anchors.isEmpty {
            StatePlaceholder(title: "No Anchors Recorded", symbol: "pin", message: "The anchor tables in _ATXDataStore.db are empty or missing on this macOS version.")
                .frame(height: 220)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: Metrics.blockSpacing, alignment: .top)], alignment: .leading, spacing: Metrics.blockSpacing) {
            ForEach(duet.anchors) { anchor in
                anchorCard(anchor)
            }
        }
    }

    private func anchorCard(_ anchor: ATXAnchor) -> some View {
        TitledCard(title: anchor.title, subtitle: anchor.description, symbol: anchor.symbol) {
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(anchor.occurrences)×").font(.title3.weight(.semibold)).monospacedDigit()
                Text(anchor.last.map { "last " + DossierDate.relative($0) } ?? "never").font(.caption2).foregroundStyle(.secondary)
            }
        } content: {
            if anchor.occurrences > 0 {
                HStack(spacing: 8) {
                    Text("Hour of day").font(.caption2).foregroundStyle(.tertiary)
                    HourSpark(values: anchor.hours.map(Double.init), tint: .orange).frame(height: 22)
                }
            }
            let apps = anchor.followUps.filter { $0.observations > 0 }.sorted { ($0.performed, $0.observations) > ($1.performed, $1.observations) }
            if apps.isEmpty {
                Text("No follow-up behaviour learned yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                let maxPerformed = Double(max(apps.first?.performed ?? 1, 1))
                VStack(spacing: 0) {
                    ForEach(apps.prefix(6)) { f in
                        HStack(spacing: 8) {
                            if let b = f.bundle { AppIcon(bundle: b, size: 18) } else { Image(systemName: "moon.circle").frame(width: 18) }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(f.label).font(.callout).lineLimit(1)
                                    if f.kind != "app" { TagLabel(f.kind, tint: .purple) }
                                }
                                ProportionBar(fraction: Double(f.performed) / maxPerformed, tint: .orange)
                            }
                            .sensitive(.personal)
                            VStack(alignment: .trailing, spacing: 0) {
                                Text("\(f.performed) of \(f.observations)").font(.callout).monospacedDigit()
                                Text("after ~\(Format.usage(f.averageDelay))").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .frame(minWidth: 86, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                    }
                }
                if apps.count > 6 {
                    Text("+ \(apps.count - 6) more candidates").font(.caption).foregroundStyle(.tertiary)
                }
            }
            if !anchor.livePredictions.isEmpty {
                Text("Currently scheduled: " + anchor.livePredictions.map(AppNames.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).sensitive(.personal)
            }
        }
    }

    // MARK: Menus & documents

    @ViewBuilder private func menuTab(_ duet: DuetSnapshot) -> some View {
        ExplainerText("macOS also predicts individual menu commands and documents (shown as suggestions in Spotlight and the Help menu search). The list on the left is the current ranking of menu commands; below is the log of commands you actually ran that the model is trained on.")
        HStack(alignment: .top, spacing: Metrics.blockSpacing) {
            TitledCard("Predicted Menu Commands", subtitle: "\(duet.menuItems.count) ranked commands (ATXCacheFile-MenuItemPredictions)", symbol: "filemenu.and.selection") {
                if duet.menuItems.isEmpty {
                    Text("No menu predictions cached.").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(duet.menuItems.prefix(25)) { item in
                            HStack(spacing: 8) {
                                AppIcon(bundle: item.bundle, size: 18)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(item.title.isEmpty ? "Untitled command" : item.title).font(.callout).lineLimit(1)
                                    Text(item.name).font(.caption2).foregroundStyle(.secondary)
                                }
                                .sensitive(.personal)
                                Spacer(minLength: 6)
                                if item.score >= 0 {
                                    Text(Format.percent(min(item.score, 1), digits: 1)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                                } else {
                                    Text("ruled out").font(.caption).foregroundStyle(.tertiary).help("Raw score \(Format.number(item.score, maxDigits: 1)): the model excluded this command for now")
                                }
                            }
                            .padding(.vertical, 3)
                            Divider()
                        }
                    }
                }
            }
            VStack(spacing: Metrics.blockSpacing) {
                TitledCard("Predicted Documents", subtitle: "Files the system expects you to open (Spotlight suggestions)", symbol: "doc.text.magnifyingglass") {
                    if duet.documents.isEmpty {
                        Text("No document predictions cached.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(duet.documents.prefix(12)) { doc in
                                HStack(spacing: 8) {
                                    Image(systemName: "doc").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(doc.fileName).font(.callout).lineLimit(1).truncationMode(.middle)
                                        Text(doc.folder).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                    }
                                    .sensitive(.sensitive)
                                    Spacer(minLength: 6)
                                    Text(Format.number(doc.score, maxDigits: 1)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                                Divider()
                            }
                        }
                    }
                }
                TitledCard("Commands You Ran", subtitle: "\(duet.menuCommands.count) logged actions (alog) — the training data", symbol: "list.bullet.rectangle") {
                    if duet.menuCommands.isEmpty {
                        Text("The action log is empty.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(duet.menuCommands.prefix(18)) { c in
                                HStack(spacing: 8) {
                                    AppIcon(bundle: c.bundle, size: 16)
                                    Text(c.title.isEmpty ? c.actionType : c.title).font(.callout).lineLimit(1).sensitive(.personal)
                                    Spacer(minLength: 6)
                                    Text(DossierDate.short(c.date)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                                .help("\(c.name) · \(c.actionType)")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Daily dose

    @ViewBuilder private func doseTab(_ duet: DuetSnapshot) -> some View {
        ExplainerText("The “daily dose” is the system's running tally of how many seconds you spend in each app per day. Today's tally resets at midnight\(duet.doseExpires.map { " (next reset \(DossierDate.short($0)))" } ?? ""); the average is an exponential moving average over past days and feeds the prediction model — an app you have already had your usual dose of is ranked lower. The lock screen is tallied too, but left out here.")
        let doses = duet.doses
        if doses.isEmpty {
            StatePlaceholder(title: "No Daily Dose Data", symbol: "pills", message: "The _ATXAppDailyDose files are missing or empty.").frame(height: 220)
        } else {
            let todayTotal = doses.reduce(0) { $0 + ($1.today ?? 0) }
            let avgTotal = doses.reduce(0) { $0 + ($1.average ?? 0) }
            StatTileRow([
                Stat("Today So Far", Format.usage(todayTotal), caption: "\(duet.currentDose.count) apps", symbol: "sun.max.fill", tint: .orange),
                Stat("Usual Day", Format.usage(avgTotal), caption: "sum of per-app averages", symbol: "chart.line.flattrend.xyaxis", tint: .blue),
                Stat("Apps Tracked", Format.count(duet.historicalDose.count), caption: duet.doseHistoryDate.map { "history as of " + DossierDate.day($0) }, symbol: "square.grid.2x2.fill", tint: .purple),
            ])
            TitledCard("Per-App Dose", subtitle: "Today's seconds in front versus the learned daily average", symbol: "pills") {
                let maxValue = max(doses.map { max($0.today ?? 0, $0.average ?? 0) }.max() ?? 1, 1)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("App").gridColumnAlignment(.leading)
                        Text("Today vs. average")
                        Text("Today").gridColumnAlignment(.trailing)
                        Text("Average").gridColumnAlignment(.trailing)
                        Text("Days").gridColumnAlignment(.trailing)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Divider().gridCellColumns(5)
                    ForEach(doses.prefix(40)) { d in
                        GridRow {
                            AppLabel(bundle: d.bundle, name: d.name).font(.callout).lineLimit(1).frame(minWidth: 110, idealWidth: 220, maxWidth: 220, alignment: .leading).sensitive(.personal)
                            VStack(spacing: 2) {
                                ProportionBar(fraction: (d.today ?? 0) / maxValue, tint: .orange)
                                ProportionBar(fraction: (d.average ?? 0) / maxValue, tint: .blue)
                            }
                            .frame(minWidth: 90)
                            Text(d.today.map(Format.usage) ?? "—").monospacedDigit()
                            Text(d.average.map(Format.usage) ?? "—").monospacedDigit().foregroundStyle(.secondary)
                            Text(d.samples.map { "\($0)" } ?? "—").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                HStack(spacing: 12) {
                    HStack(spacing: 4) { Capsule().fill(.orange).frame(width: 14, height: 5); Text("today") }
                    HStack(spacing: 4) { Capsule().fill(.blue).frame(width: 14, height: 5); Text("average day") }
                    if doses.count > 40 { Text("· \(doses.count - 40) more apps not shown") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Modes & recents

    @ViewBuilder private func moreTab(_ loaded: Loaded) -> some View {
        let duet = loaded.duet
        ExplainerText("From the apps you launch, the system also infers which “mode” you are probably in (the same categories as Focus modes) even when no Focus is switched on, and it keeps a short rolling list of the most recent launches.")
        SideBySide(minWidth: 800) {
            TitledCard("Inferred Modes", subtitle: "streams/appLaunchInferredMode — periods the model assigned to a mode type", symbol: "moon.stars") {
                if duet.modes.isEmpty {
                    Text("No inferred modes recorded.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                        GridRow {
                            Text("From"); Text("Until"); Text("Length").gridColumnAlignment(.trailing); Text("Mode"); Text("Confidence").gridColumnAlignment(.trailing)
                        }
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Divider().gridCellColumns(5)
                        ForEach(duet.modes.prefix(30)) { m in
                            GridRow {
                                Text(DossierDate.sortable(m.start)).monospacedDigit().fixedSize()
                                Text(m.end.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                                Text(Format.usage(m.end.timeIntervalSince(m.start))).monospacedDigit()
                                TagLabel("type \(m.mode)", tint: .indigo)
                                Text(Format.percent(m.confidence, digits: 0)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout).lineLimit(1)
                        }
                    }
                    Text("Mode types are internal numeric codes (ATXMode); Apple does not publish their names.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        } trailing: {
            VStack(spacing: Metrics.blockSpacing) {
                TitledCard("Latest Launch Sequence", subtitle: "appLaunchSequence — the rolling window the next-app model looks at", symbol: "arrow.right.circle") {
                    if duet.launchSequence.isEmpty {
                        Text("Empty.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(duet.launchSequence.prefix(10)) { l in
                                HStack {
                                    AppLabel(bundle: l.bundle).font(.callout).sensitive(.personal)
                                    Spacer()
                                    Text(DossierDate.sortable(l.date)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                TitledCard("Recently Focused Apps", subtitle: "Biome database “Games.RecentlyPlayed”: a materialised view of the latest focus time per app, kept for the Games app", symbol: "gamecontroller") {
                    if loaded.games.rows.isEmpty {
                        Text(loaded.games.note).font(.callout).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(loaded.games.rows.prefix(14)) { r in
                                HStack {
                                    AppLabel(bundle: r.bundle, name: r.name).font(.callout).sensitive(.personal)
                                    Spacer()
                                    Text(DossierDate.sortable(r.last)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("\(loaded.games.rows.count) apps in the view.").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

/// Tiny 24-bar sparkline (hour of day).
struct HourSpark: View {
    let values: [Double]
    var tint: Color = .accentColor
    var body: some View {
        GeometryReader { geo in
            let maxValue = max(values.max() ?? 1, 1)
            let w = geo.size.width / CGFloat(max(values.count, 1))
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(v > 0 ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary.opacity(0.08)))
                        .frame(width: max(1, w - 1.5), height: v > 0 ? max(3, geo.size.height * CGFloat(v / maxValue)) : 2)
                        .frame(width: w)
                }
            }
            .frame(height: geo.size.height, alignment: .bottom)
        }
    }
}
