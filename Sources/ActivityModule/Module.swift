import DossierCore
import SwiftUI

/// Activity — what you do on your devices: foreground apps (this Mac and every device
/// whose Biome streams sync here), media, Safari web usage, and the routine model that
/// DuetExpert ("ATX") derives from it.
public final class ActivityModule: DossierModule {
    public let id = "activity"
    public let title = "Activity"
    public let symbol = "chart.bar.xaxis"
    public let group = SidebarGroup.behaviour

    public init() {}

    public var sections: [ModuleSection] {
        [
            ModuleSection(id: "activity.dashboard", title: "Summary", symbol: "gauge.with.dots.needle.50percent") { DashboardView() },
            ModuleSection(id: "activity.apps", title: "App Usage", symbol: "square.grid.2x2") { AppUsageView() },
            ModuleSection(id: "activity.timeline", title: "Timeline", symbol: "calendar.day.timeline.left") { TimelineSectionView() },
            ModuleSection(id: "activity.media", title: "Media History", symbol: "music.note.list") { MediaView() },
            ModuleSection(id: "activity.web", title: "Web Usage", symbol: "safari") { WebUsageView() },
            ModuleSection(id: "activity.predictions", title: "Predictions & Routine", symbol: "wand.and.rays") { PredictionsView() },
        ]
    }

    // MARK: Summary

    public func summary() async -> ModuleSummary {
        let store = ActivityStore.shared
        var stores: [StoreInfo] = []
        var facts: [Fact] = []

        func streamInfo(_ name: String, note: String) -> StoreInfo {
            guard let stream = Biome.stream(named: name) else {
                let url = Paths.biomeRestrictedStreams.appendingPathComponent(name)
                let probe = Paths.probe(Paths.biomeRestrictedStreams)
                return StoreInfo(name: "Biome \(name)", path: url, availability: probe.isAvailable ? .missing : probe, note: note)
            }
            let stats = BiomeStreamReader(stream).stats()
            return StoreInfo(name: "Biome \(name)", path: stream.url, sizeBytes: stream.totalSize, rowCount: stats.records, timeRange: stats.timeRange, note: note)
        }
        stores.append(streamInfo("App.InFocus", note: "Foreground app start/stop events, this Mac and synced devices"))
        stores.append(streamInfo("Media.NowPlaying", note: "Now Playing metadata: title, artist, app, output route"))
        stores.append(streamInfo("ScreenTime.AppUsage", note: "Screen Time's own app usage events"))
        stores.append(streamInfo("App.WebUsage", note: "Safari page usage for Screen Time"))

        var knowledge = StoreInfo.file("knowledgeC.db", Paths.knowledgeC, note: "/app/usage, /app/webUsage, /app/mediaUsage, /display/isBacklit")
        if let db = await SQLiteDB.sharedIfAvailable(Paths.knowledgeC), await db.hasColumns("ZOBJECT", ["ZSTREAMNAME", "ZSTARTDATE"]) {
            let streams = "('/app/usage','/app/webUsage','/app/mediaUsage','/display/isBacklit')"
            if let r = try? await db.first("SELECT count(*), min(ZSTARTDATE), max(ZSTARTDATE) FROM ZOBJECT WHERE ZSTREAMNAME IN \(streams)") {
                knowledge.rowCount = r[0].int.map(Int.init)
                if let lo = r[1].cocoaDate, let hi = r[2].cocoaDate { knowledge.timeRange = lo...hi }
            }
        }
        stores.append(knowledge)

        var atx = StoreInfo.file("_ATXDataStore.db", DuetPaths.dataStore, note: "DuetExpert app launch statistics, transitions, anchors")
        let duet = await store.duet()
        if atx.availability.isAvailable { atx.rowCount = duet.tables.values.reduce(0, +) }
        stores.append(atx)

        let devices = await store.devices()
        let local = await store.aggregate(device: ActivityDevice.localID, range: .all)
        if let top = local.apps.first {
            facts.append(Fact("Most used app on this Mac", "\(top.name) — \(Format.usage(top.total)) in front", sensitivity: .personal, symbol: "app.badge", sectionID: "activity.apps"))
        }
        if local.total > 0, let range = local.range {
            let days = max(1, local.days.count)
            facts.append(Fact("Foreground time recorded (this Mac)", "\(Format.usage(local.total)) across \(local.apps.count) apps, \(days) days since \(DossierDate.day(range.lowerBound))", sensitivity: .personal, symbol: "clock", sectionID: "activity.dashboard"))
        }
        let remote = devices.filter { !$0.isLocal }
        if !remote.isEmpty {
            var sessions = 0
            for d in remote { sessions += await store.focus(d.id).sessions.count }
            facts.append(Fact("Other devices tracked from this Mac", "\(remote.count) (\(Set(remote.map(\.platform)).sorted().joined(separator: ", "))) — \(Format.count(sessions)) app sessions synced", sensitivity: .personal, symbol: "iphone", sectionID: "activity.dashboard"))
        }
        let media = await store.mediaSummary(device: nil)
        if media.plays > 0 {
            facts.append(Fact("Now Playing history", "\(Format.count(media.plays)) plays of \(Format.count(media.distinctTitles)) titles by \(Format.count(media.distinctArtists)) artists", sensitivity: .personal, symbol: "music.note", sectionID: "activity.media"))
            if let artist = media.topArtists.first {
                facts.append(Fact("Most played artist", "\(artist.label) (\(Int(artist.value)) plays)", sensitivity: .personal, symbol: "music.mic", sectionID: "activity.media"))
            }
            if media.flaggedTitles > 0 {
                facts.append(Fact("Non-music text captured as titles", "\(Format.count(media.flaggedTitles)) page, video or message titles stored verbatim", sensitivity: .sensitive, symbol: "text.quote", sectionID: "activity.media"))
            }
        }
        let web = await store.web()
        if let top = web.domains.first {
            facts.append(Fact("Safari usage recorded", "\(web.domains.count) domains, most time on \(top.domain) (\(Format.usage(top.seconds)))", sensitivity: .sensitive, symbol: "safari", sectionID: "activity.web"))
        }
        if let consumer = duet.consumers.first, let p = duet.predictions[consumer]?.first {
            facts.append(Fact("App the system expects you to open next", "\(p.name) (\(consumer) ranking of \(duet.predictions[consumer]?.count ?? 0) apps)", sensitivity: .personal, symbol: "wand.and.stars", sectionID: "activity.predictions"))
        }
        return ModuleSummary(stores: stores, facts: Array(facts.prefix(8)))
    }

    // MARK: Search

    public func search(_ query: String, limit: Int) async -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2, limit > 0 else { return [] }
        let store = ActivityStore.shared
        var hits: [SearchHit] = []
        let quota = max(3, limit / 3)

        // Apps (any device).
        var seenApps = Set<String>()
        for device in await store.devices() {
            if Task.isCancelled { return hits }
            let agg = await store.aggregate(device: device.id, range: .all)
            for app in agg.apps where app.name.localizedCaseInsensitiveContains(needle) || app.bundle.localizedCaseInsensitiveContains(needle) {
                guard seenApps.insert(device.id + app.bundle).inserted else { continue }
                hits.append(SearchHit(
                    id: "activity.app|\(device.id)|\(app.bundle)",
                    title: app.name, subtitle: "App usage on \(device.name) · \(Format.usage(app.total)) · \(Format.count(app.activations)) activations",
                    moduleID: id, sectionID: "activity.apps", payload: "app:\(device.id)\t\(app.bundle)", symbol: "app.badge", sensitivity: .personal))
                if hits.count >= quota { break }
            }
            if hits.count >= quota { break }
        }

        // Media titles / artists.
        if Task.isCancelled { return hits }
        var seenMedia = Set<String>()
        var mediaHits = 0
        for play in await store.mediaPlays(device: nil).reversed() {
            if mediaHits >= quota || Task.isCancelled { break }
            guard play.title.localizedCaseInsensitiveContains(needle) || play.artist.localizedCaseInsensitiveContains(needle) else { continue }
            guard seenMedia.insert(play.key).inserted else { continue }
            hits.append(SearchHit(
                id: "activity.media|\(play.key)",
                title: play.title, subtitle: "Now Playing · \(play.artist.isEmpty ? AppNames.name(play.bundle) : play.artist) · \(DossierDate.short(play.date))",
                moduleID: id, sectionID: "activity.media", payload: "q:\(play.title)", symbol: "music.note",
                sensitivity: play.flag == .none ? .personal : .sensitive))
            mediaHits += 1
        }

        // Web domains / URLs.
        if Task.isCancelled { return hits }
        var webHits = 0
        for domain in await store.web().domains {
            if webHits >= quota { break }
            guard domain.domain.localizedCaseInsensitiveContains(needle) || domain.urls.contains(where: { $0.localizedCaseInsensitiveContains(needle) }) else { continue }
            hits.append(SearchHit(
                id: "activity.web|\(domain.domain)",
                title: domain.domain, subtitle: "Safari web usage · \(Format.usage(domain.seconds)) · \(domain.visits) visits",
                moduleID: id, sectionID: "activity.web", payload: "q:\(domain.domain)", symbol: "safari", sensitivity: .sensitive))
            webHits += 1
        }

        // Predicted menu commands / documents.
        if Task.isCancelled { return hits }
        let duet = await store.duet()
        for item in duet.menuItems.prefix(200) where hits.count < limit && item.title.localizedCaseInsensitiveContains(needle) {
            hits.append(SearchHit(
                id: "activity.menu|\(item.id)", title: item.title, subtitle: "Predicted menu command in \(item.name)",
                moduleID: id, sectionID: "activity.predictions", payload: "tab:menu", symbol: "filemenu.and.selection", sensitivity: .personal))
        }
        for doc in duet.documents.prefix(200) where hits.count < limit && doc.url.localizedCaseInsensitiveContains(needle) {
            hits.append(SearchHit(
                id: "activity.doc|\(doc.id)", title: doc.fileName, subtitle: "Predicted document · \(doc.folder)",
                moduleID: id, sectionID: "activity.predictions", payload: "tab:menu", symbol: "doc", sensitivity: .sensitive))
        }
        return Array(hits.prefix(limit))
    }

    // MARK: Self-test

    public func selfTest() async -> [SelfTestLine] {
        let store = ActivityStore.shared
        var lines: [SelfTestLine] = []
        let started = Date()
        func range(_ r: ClosedRange<Date>?) -> String { r.map { DossierDate.sortable($0.lowerBound) + " … " + DossierDate.sortable($0.upperBound) } ?? "no dates" }

        // Stores.
        for (label, url) in [("Biome restricted streams", Paths.biomeRestrictedStreams), ("knowledgeC.db", Paths.knowledgeC), ("DuetExpertCenter", DuetPaths.root), ("Biome sync.db", Paths.biomeSyncDB)] {
            let probe = Paths.probe(url)
            lines.append(probe.isAvailable ? .pass(label, "readable") : .warn(label, probe.label))
        }

        // Devices + App.InFocus.
        let devices = await store.devices()
        lines.append(.info("Devices with activity", devices.map { "\($0.name) [\($0.platform)\($0.build.map { " " + $0 } ?? "")]" }.joined(separator: "; ")))
        if let stream = Biome.stream(named: "App.InFocus") {
            for device in devices {
                let stats = BiomeStreamReader(stream).stats(device: device.biome)
                let focus = await store.focus(device.id)
                let agg = await store.aggregate(device: device.id, range: .all)
                let label = "App.InFocus · \(device.name)"
                let detail = "\(stats.records) live records (\(stats.deleted) deleted), \(focus.eventCount) decoded events (\(focus.startEvents) start / \(focus.stopEvents) stop, \(focus.undecodable) undecodable), \(focus.sessions.count) sessions, \(agg.apps.count) apps, foreground \(Format.usage(agg.total)) [\(Int(agg.total)) s], system surfaces \(Format.usage(agg.systemTotal)), capped \(focus.cappedSessions), implied stops \(focus.impliedStops), unmatched stops \(focus.unmatchedStops), flicker \(focus.droppedFlickers); \(range(focus.timeRange))"
                if focus.eventCount == 0 {
                    lines.append(.info(label, "no focus records (media only)"))
                } else {
                    // Records that are not events are the empty segment-rollover markers.
                    lines.append(focus.sessions.isEmpty || focus.undecodable > stats.records / 100 ? .warn(label, detail) : .pass(label, detail))
                }
            }
        } else {
            lines.append(.warn("App.InFocus", "stream not found"))
        }

        // Cross-check: this Mac, InFocus pairing vs. Screen Time stream vs. knowledgeC intervals.
        let st = await store.screenTime()
        let stTotal = st.sessions.reduce(0.0) { $0 + ($1.isSystem ? 0 : $1.duration) }
        lines.append(st.eventCount > 0
            ? .pass("ScreenTime.AppUsage", "\(st.eventCount) events, \(st.sessions.count) sessions, \(st.bundles.count) apps, total \(Format.usage(stTotal)) [\(Int(stTotal)) s]; \(range(st.timeRange))")
            : .warn("ScreenTime.AppUsage", "no events"))
        if let db = await SQLiteDB.sharedIfAvailable(Paths.knowledgeC), await db.hasColumns("ZOBJECT", ["ZSTREAMNAME", "ZSTARTDATE", "ZENDDATE", "ZVALUESTRING"]) {
            for stream in ["/app/usage", "/app/webUsage", "/app/mediaUsage", "/display/isBacklit"] {
                if let r = try? await db.first("SELECT count(*), min(ZSTARTDATE), max(ZSTARTDATE), sum(ZENDDATE - ZSTARTDATE), count(DISTINCT ZVALUESTRING) FROM ZOBJECT WHERE ZSTREAMNAME = ?", [.text(stream)]) {
                    let n = r[0].int ?? 0
                    var detail = "\(n) rows, \(Int(r[3].double ?? 0)) s total"
                    if stream == "/app/usage" { detail += ", \(r[4].int ?? 0) apps" }
                    if let lo = r[1].cocoaDate, let hi = r[2].cocoaDate { detail += "; " + range(lo...hi) }
                    lines.append(n > 0 ? .pass("knowledgeC \(stream)", detail) : .info("knowledgeC \(stream)", "empty"))
                }
            }
            // Compare the three foreground-time measurements over the window all of them cover.
            if let r = try? await db.first("SELECT min(ZSTARTDATE), max(ZENDDATE) FROM ZOBJECT WHERE ZSTREAMNAME = '/app/usage'"),
               let lo = r[0].double, let hi = r[1].double {
                let focus = await store.focus(ActivityDevice.localID)
                func clipped(_ f: DeviceFocus, excluding: Set<String>) -> Double {
                    f.sessions.reduce(0.0) { acc, s in
                        if excluding.contains(f.bundles[Int(s.app)]) { return acc }
                        return acc + max(0, min(s.end, hi) - max(s.start, lo))
                    }
                }
                let kTotal = (try? await db.scalar("SELECT sum(ZENDDATE - ZSTARTDATE) FROM ZOBJECT WHERE ZSTREAMNAME = '/app/usage'"))?.double ?? 0
                let kLogin = (try? await db.scalar("SELECT sum(ZENDDATE - ZSTARTDATE) FROM ZOBJECT WHERE ZSTREAMNAME = '/app/usage' AND ZVALUESTRING = 'com.apple.loginwindow'"))?.double ?? 0
                let inFocus = clipped(focus, excluding: ["com.apple.loginwindow"])
                let screen = clipped(st, excluding: ["com.apple.loginwindow"])
                let detail = "same window, excluding lock screen: InFocus pairing \(Int(inFocus)) s, ScreenTime pairing \(Int(screen)) s, knowledgeC \(Int(kTotal - kLogin)) s"
                let reference = max(1, kTotal - kLogin)
                lines.append(abs(inFocus - reference) / reference < 0.15 ? .pass("Foreground time cross-check", detail) : .warn("Foreground time cross-check", detail))
            }
        } else {
            lines.append(.warn("knowledgeC", "ZOBJECT not readable"))
        }

        // Media.
        let media = await store.media()
        let mediaSummary = await store.mediaSummary(device: nil)
        var perDevice: [String] = []
        for d in devices { if let n = media.perDevice[d.id] { perDevice.append("\(d.name) \(n)") } }
        lines.append(media.events.isEmpty
            ? .warn("Media.NowPlaying", "no events")
            : .pass("Media.NowPlaying", "\(media.events.count) events (\(perDevice.joined(separator: ", "))), \(media.undecodable) undecodable, \(mediaSummary.plays) plays, \(mediaSummary.distinctTitles) titles, \(mediaSummary.distinctArtists) artists, \(mediaSummary.flagged) flagged plays (\(mediaSummary.flaggedTitles) titles); \(range(media.timeRange))"))
        if !media.plays.isEmpty {
            var mirrorParts: [String] = []
            for d in devices {
                let own = media.plays.filter { $0.deviceID == d.id }
                if !own.isEmpty { mirrorParts.append("\(d.name) \(own.count - own.filter { media.mirrored.contains($0.index) }.count)/\(own.count)") }
            }
            // Residual check: counted plays of one item on two devices less than 10 min apart.
            var lastByKey: [String: MediaPlay] = [:]
            var residual = 0
            for p in await store.mediaPlays(device: nil) {
                if let l = lastByKey[p.key], l.deviceID != p.deviceID, p.date.timeIntervalSince(l.date) < 600 { residual += 1 }
                lastByKey[p.key] = p
            }
            lines.append(.info("Now Playing mirroring", "\(media.plays.count) per-device plays, \(media.mirrored.count) mirror another device and are left out of all-device counts (counted/own: \(mirrorParts.joined(separator: ", "))); \(residual) cross-device repeats < 10 min remain; top artist \(Int(mediaSummary.topArtists.first?.value ?? 0)) plays"))
        }
        lines.append(.info("Media usage sessions", "\(media.usage.filter { $0.source.hasPrefix("Biome") }.count) from Biome App.MediaUsage, \(media.usage.filter { $0.source.hasPrefix("knowledgeC") }.count) from knowledgeC"))

        // Web.
        let web = await store.web()
        lines.append(.info("Web usage", "knowledgeC \(web.knowledge.count) intervals (\(Int(web.knowledge.reduce(0) { $0 + $1.duration })) s), Biome App.WebUsage \(web.streamCounts["App.WebUsage"] ?? 0) events → \(web.biome.count) intervals (\(Int(web.biome.reduce(0) { $0 + $1.duration })) s), Safari.Navigations \(web.navigations.count), Safari.PageLoad \(web.pageLoads), search engines \(web.searchEngines.count), \(web.domains.count) domains; \(range(web.timeRange))"))

        // DuetExpert.
        let duet = await store.duet()
        if duet.availability.isAvailable {
            let tables = duet.tables.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            lines.append(duet.tables.isEmpty ? .warn("_ATXDataStore.db", "no known tables") : .pass("_ATXDataStore.db", tables))
            let withTransitions = duet.appInfo.values.filter { !$0.nextLaunches.isEmpty }.count
            lines.append(.info("DuetExpert model", "\(duet.appInfo.count) apps (\(duet.appInfo.values.filter { $0.lastLaunch != nil }.count) launched, \(withTransitions) with next-app scores), \(duet.anchors.count) anchor types / \(duet.anchors.reduce(0) { $0 + $1.occurrences }) occurrences / \(duet.anchors.reduce(0) { $0 + $1.followUps.count }) follow-up candidates, predictions \(duet.consumers.map { "\($0) \(duet.predictions[$0]?.count ?? 0)" }.joined(separator: ", ")), \(duet.menuItems.count) menu predictions, \(duet.documents.count) document predictions, doses today \(duet.currentDose.count) / historical \(duet.historicalDose.count), \(duet.modes.count) inferred modes, \(duet.menuCommands.count) logged actions (\(duet.menuCommands.filter { !$0.title.isEmpty }.count) with titles)"))
        } else {
            lines.append(.warn("DuetExpertCenter", duet.availability.label))
        }

        // Games.
        let games = await GamesSource.load()
        lines.append(.info("Games.RecentlyPlayed", games.note))

        // Cold first-paint cost of every section's loader (caches dropped before each).
        var sectionTimes: [String] = []
        func measure(_ name: String, _ work: () async -> Void) async {
            await store.reset()
            let t = Date()
            await work()
            sectionTimes.append(String(format: "%@ %.0f ms", name, Date().timeIntervalSince(t) * 1000))
        }
        await measure("dashboard") { _ = await store.aggregate(device: ActivityDevice.localID, range: .all) }
        if let busiest = devices.filter({ !$0.isLocal }).first {
            await measure("dashboard (largest remote)") {
                for d in devices where !d.isLocal { _ = await store.aggregate(device: d.id, range: .all) }
                _ = busiest
            }
        }
        await measure("apps") { _ = await store.appRows(device: ActivityDevice.localID, range: .all, request: PageRequest(offset: 0, limit: 200)) }
        await measure("timeline") { _ = await TimelineLoader.load(day: nil) }
        await measure("media") { _ = await store.mediaPage(device: nil, filter: .all, search: "", sort: nil, offset: 0, limit: 200); _ = await store.mediaSummary(device: nil) }
        await measure("web") { _ = await store.web() }
        await measure("predictions") { _ = await store.duet() }
        lines.append(.info("Section first load (cold)", sectionTimes.joined(separator: ", ")))

        // Timings.
        let timings = await store.timings.sorted { $0.key < $1.key }.map { String(format: "%@ %.0f ms", $0.key, $0.value * 1000) }.joined(separator: ", ")
        lines.append(.info("Timings", String(format: "self-test %.2f s; ", Date().timeIntervalSince(started)) + timings))
        return lines
    }
}

/// `~/Library/Biome/databases/Games.RecentlyPlayed`: a materialised Biome view
/// ("AppsRecentlyFocused": bundle id → latest focus timestamp) kept for Game Center / the
/// Games app. Despite the name it lists every recently focused app.
enum GamesSource {
    struct Row: Identifiable, Sendable {
        var id: String { bundle }
        let bundle: String
        let name: String
        let last: Date?
    }

    struct Result: Sendable {
        var rows: [Row] = []
        var url: URL
        var note: String
    }

    static var url: URL { Paths.biomeDatabases.appendingPathComponent("Games.RecentlyPlayed/Games.RecentlyPlayed.sqlite3") }

    static func load() async -> Result {
        var result = Result(url: url, note: "not present")
        guard let db = await SQLiteDB.sharedIfAvailable(url) else {
            let probe = Paths.probe(url)
            if !probe.isAvailable { result.note = probe.label }
            return result
        }
        guard await db.hasColumns("AppsRecentlyFocused", ["bundleID", "maxEventTimestamp"]) else {
            result.note = "table AppsRecentlyFocused missing"
            return result
        }
        let rows = (try? await db.rows("SELECT bundleID, maxEventTimestamp FROM AppsRecentlyFocused ORDER BY maxEventTimestamp DESC LIMIT 2000")) ?? []
        result.rows = rows.compactMap { r in
            guard let b = r[0].string else { return nil }
            // The view stores Unix seconds (the source events use Cocoa time); accept either.
            let last = r[1].double.flatMap { $0 > 1_200_000_000 ? DossierDate.unix($0) : DossierDate.cocoa($0) }
            return Row(bundle: b, name: AppNames.name(b), last: last)
        }
        result.note = "\(result.rows.count) recently focused apps" + (result.rows.first?.last.map { ", newest " + DossierDate.sortable($0) } ?? "")
        return result
    }
}
