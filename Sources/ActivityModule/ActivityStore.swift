import DossierCore
import Foundation

/// Module-wide cache and query engine. Everything here runs off the main actor; decoded
/// streams are cached until the user refreshes (``sync(token:)``).
///
/// Sources and the protobuf field numbers relied on (discovered empirically):
///
/// * `App.InFocus` — 2 type (1 app, 3 SpringBoard scene), 3 starting, 4 absolute timestamp
///   (Cocoa seconds), 6 bundle id, 9 short version, 10 build version, 14 transition reason.
/// * `ScreenTime.AppUsage` — 1 starting, 2 timestamp (**Unix** seconds), 3 bundle id.
/// * `App.MediaUsage` — 1 starting, 2 bundle id, 6 timestamp (Unix seconds), 8 session UUID.
/// * `Media.NowPlaying`, `App.WebUsage`, `Safari.Navigations` — see `MediaStore.swift` and
///   `WebStore.swift`.
actor ActivityStore {
    static let shared = ActivityStore()

    private var lastToken = 0
    private var devicesCache: [ActivityDevice]?
    private var focusCache: [String: DeviceFocus] = [:]
    private var aggregateCache: [String: FocusAggregate] = [:]
    private var screenTimeCache: DeviceFocus?
    private var knowledgeUsageCache: [String: Double]?
    private var backlightCache: [(start: Double, end: Double, on: Bool)]?
    var mediaCache: MediaHistory?
    var webCache: WebHistory?
    var duetCache: DuetSnapshot?
    var mediaViewCache: (key: String, rows: [NowPlayingEvent])?
    private(set) var timings: [String: Double] = [:]

    /// Drops all caches when the app's refresh token changed since the last call.
    func sync(token: Int) {
        if token != lastToken { lastToken = token; reset() }
    }

    func reset() {
        devicesCache = nil; focusCache = [:]; aggregateCache = [:]; screenTimeCache = nil
        knowledgeUsageCache = nil; backlightCache = nil; mediaCache = nil; webCache = nil; duetCache = nil
        mediaViewCache = nil
    }

    func note(_ label: String, since start: Date) {
        // Keep the slowest observation per label (several devices share one label).
        timings[label] = max(timings[label] ?? 0, Date().timeIntervalSince(start))
    }

    // MARK: Devices

    /// Devices that have at least one live record in `App.InFocus` or `Media.NowPlaying`,
    /// this Mac first. Names come from `sync.db` → `DevicePeer`; devices that are not (or no
    /// longer) listed there are named by the platform inferred from their bundle ids.
    func devices() async -> [ActivityDevice] {
        if let devicesCache { return devicesCache }
        let t0 = Date()
        let peers = await Biome.devicePeers()
        var seen: [BiomeDevice] = []
        for name in ["App.InFocus", "Media.NowPlaying"] {
            guard let stream = Biome.stream(named: name) else { continue }
            for device in stream.devices where !seen.contains(device) {
                let hasData = stream.dataSegments(device: device).contains { segment in
                    ((try? SEGBFile(url: segment.url))?.liveCount ?? 0) > 0
                }
                if hasData { seen.append(device) }
            }
        }
        var out: [ActivityDevice] = []
        let me = peers.values.first { $0.isMe }
        if seen.contains(.local) || Biome.stream(named: "App.InFocus") != nil {
            out.append(ActivityDevice(id: ActivityDevice.localID, name: "This Mac", platform: "Mac", build: me?.model, isLocal: true, lastSync: nil))
        }
        var unknown = 0
        for device in seen {
            guard case .remote(let id) = device else { continue }
            if let peer = peers[id] {
                var name = peer.displayName
                if name == peer.platformName, peer.platform == 3 { name = "Other Mac" }
                out.append(ActivityDevice(id: id, name: name, platform: peer.platformName, build: peer.model, isLocal: false, lastSync: peer.lastSync))
            } else {
                unknown += 1
                let platform = inferPlatform(device)
                out.append(ActivityDevice(id: id, name: "Unlisted \(platform)", platform: platform, build: nil, isLocal: false, lastSync: nil))
            }
        }
        // Disambiguate equal names without exposing identifiers.
        var counts: [String: Int] = [:]
        for d in out { counts[d.name, default: 0] += 1 }
        var running: [String: Int] = [:]
        for i in out.indices where (counts[out[i].name] ?? 0) > 1 {
            running[out[i].name, default: 0] += 1
            out[i].name += " (\(running[out[i].name]!))"
        }
        devicesCache = out
        note("devices", since: t0)
        return out
    }

    func device(_ id: String) async -> ActivityDevice? {
        await devices().first { $0.id == id }
    }

    /// Guesses the platform of a device missing from `DevicePeer` from the bundle ids of its
    /// first few hundred focus records.
    private func inferPlatform(_ device: BiomeDevice) -> String {
        guard let stream = Biome.stream(named: "App.InFocus") else { return "Device" }
        var mac = 0, ios = 0, watch = 0, tv = 0, n = 0
        BiomeStreamReader(stream).forEach(device: device, order: .newestFirst) { record in
            var bundle = ""
            FastProto.scan(record.payload) { field, value in
                if field == 6, case .bytes(let r) = value { bundle = FastProto.string(r) }
            }
            if bundle.hasPrefix("com.apple.springboard") || bundle.hasPrefix("com.apple.mobile") || bundle == "com.apple.Preferences" { ios += 1 }
            if ["com.apple.finder", "com.apple.loginwindow", "com.apple.dock", "com.apple.systempreferences", "com.apple.Terminal", "com.apple.Safari"].contains(bundle) { mac += 1 }
            if bundle == "com.apple.Carousel" || bundle.hasPrefix("com.apple.Nano") || bundle.contains(".watchkitapp") { watch += 1 }
            if bundle == "com.apple.PineBoard" || bundle == "com.apple.HeadBoard" || bundle.hasPrefix("com.apple.TV") { tv += 1 }
            n += 1
            return n < 600
        }
        let best = max(mac, ios, watch, tv)
        if best == 0 { return "Device" }
        if best == watch { return "Apple Watch" }
        if best == tv { return "Apple TV" }
        return best == mac ? "Mac" : "iPhone / iPad"
    }

    // MARK: Focus sessions

    /// Decodes and pairs the `App.InFocus` history of one device (cached).
    func focus(_ deviceID: String) async -> DeviceFocus {
        if let hit = focusCache[deviceID] { return hit }
        let t0 = Date()
        let isLocal = deviceID == ActivityDevice.localID
        var pairer = FocusPairer()
        var undecodable = 0
        if let stream = Biome.stream(named: "App.InFocus") {
            var events: [RawFocusEvent] = []
            var sorted = true
            var last = -Double.infinity
            BiomeStreamReader(stream).forEach(device: isLocal ? .local : .remote(deviceID), order: .oldestFirst) { record in
                if record.payload.isEmpty { return true }   // segment-rollover marker
                var bundle: String?
                var starting: Bool?
                var time: Double?
                let ok = FastProto.scan(record.payload) { field, value in
                    switch (field, value) {
                    case (3, .varint(let v)): starting = v != 0
                    case (4, .fixed64(let bits)): time = FastProto.double(bits)
                    case (6, .bytes(let r)): bundle = FastProto.string(r)
                    default: break
                    }
                }
                guard ok, let bundle, let starting else { undecodable += 1; return true }
                let t = time ?? record.timestamp.timeIntervalSinceReferenceDate
                if t < last { sorted = false }
                last = t
                events.append(RawFocusEvent(time: t, app: pairer.appIndex(bundle), starting: starting))
                return true
            }
            if !sorted {
                // Stable sort: equal timestamps keep file order (stop before start).
                let order = events.indices.sorted { events[$0].time != events[$1].time ? events[$0].time < events[$1].time : $0 < $1 }
                events = order.map { events[$0] }
            }
            for e in events { pairer.add(time: e.time, app: e.app, starting: e.starting) }
        }
        var result = pairer.finish(isLocal: isLocal, now: Date().timeIntervalSinceReferenceDate)
        result.undecodable = undecodable
        if isLocal { result = await clipToBacklight(result) }
        focusCache[deviceID] = result
        note("focus.decode.\(isLocal ? "local" : "remote")", since: t0)
        return result
    }

    /// For this Mac the pairing is refined with knowledgeC's `/display/isBacklit` stream:
    /// a session cannot continue while the display is recorded as off. Only sessions that
    /// lie inside the period covered by backlight records are clipped; older ones rely on
    /// the cap alone.
    private func clipToBacklight(_ input: DeviceFocus) async -> DeviceFocus {
        let lights = await backlight()
        let off = lights.filter { !$0.on && $0.end - $0.start >= 60 }
        guard !off.isEmpty else { return input }
        var out = input
        var sessions: [FocusSession] = []
        sessions.reserveCapacity(input.sessions.count)
        var cursor = 0
        for s in input.sessions {
            if s.isSystem || s.duration < 120 { sessions.append(s); continue }
            while cursor < off.count, off[cursor].end <= s.start { cursor += 1 }
            var pieces: [FocusSession] = []
            var pieceStart = s.start
            var i = cursor
            while i < off.count, off[i].start < s.end {
                if off[i].start > pieceStart {
                    var piece = s
                    piece.start = pieceStart; piece.end = min(off[i].start, s.end)
                    pieces.append(piece)
                }
                pieceStart = max(pieceStart, off[i].end)
                i += 1
            }
            if i == cursor { sessions.append(s); continue }   // no display-off interval inside
            if pieceStart < s.end {
                var piece = s
                piece.start = pieceStart
                pieces.append(piece)
            }
            // The display record is better evidence than the cap: clipped pieces are exact.
            if s.isCapped { out.cappedSessions -= 1 }
            var first = true
            for var piece in pieces where piece.duration >= FocusPairer.minSession {
                piece.flags &= ~1
                if !first { piece.flags |= 8 }
                first = false
                sessions.append(piece)
            }
        }
        out.sessions = sessions
        return out
    }

    /// knowledgeC `/display/isBacklit` intervals (ZVALUEINTEGER 1 = display on).
    func backlight() async -> [(start: Double, end: Double, on: Bool)] {
        if let backlightCache { return backlightCache }
        var out: [(start: Double, end: Double, on: Bool)] = []
        if let db = await SQLiteDB.sharedIfAvailable(Paths.knowledgeC),
           await db.hasColumns("ZOBJECT", ["ZSTREAMNAME", "ZSTARTDATE", "ZENDDATE", "ZVALUEINTEGER"]),
           let rows = try? await db.rows("SELECT ZSTARTDATE, ZENDDATE, ZVALUEINTEGER FROM ZOBJECT WHERE ZSTREAMNAME = '/display/isBacklit' ORDER BY ZSTARTDATE", maxRows: 500_000) {
            for r in rows {
                guard let a = r[0].double, let b = r[1].double, b >= a else { continue }
                out.append((a, b, (r[2].int ?? 0) != 0))
            }
        }
        backlightCache = out
        return out
    }

    /// `ScreenTime.AppUsage` of this Mac, paired with the same rules (cross-check source).
    func screenTime() -> DeviceFocus {
        if let screenTimeCache { return screenTimeCache }
        let t0 = Date()
        var pairer = FocusPairer()
        if let stream = Biome.stream(named: "ScreenTime.AppUsage") {
            BiomeStreamReader(stream).forEach(device: .local, order: .oldestFirst) { record in
                var bundle: String?
                var starting: Bool?
                var unix: Double?
                FastProto.scan(record.payload) { field, value in
                    switch (field, value) {
                    case (1, .varint(let v)): starting = v != 0
                    case (2, .fixed64(let bits)): unix = FastProto.double(bits)
                    case (3, .bytes(let r)): bundle = FastProto.string(r)
                    default: break
                    }
                }
                guard let bundle, let starting else { return true }
                let t = unix.map { $0 - DossierDate.cocoaEpochOffset } ?? record.timestamp.timeIntervalSinceReferenceDate
                pairer.add(time: t, app: pairer.appIndex(bundle), starting: starting)
                return true
            }
        }
        let result = pairer.finish(isLocal: true, now: Date().timeIntervalSinceReferenceDate)
        screenTimeCache = result
        note("screentime.decode", since: t0)
        return result
    }

    /// Seconds per bundle id in knowledgeC `/app/usage` (already paired by the system).
    func knowledgeUsage() async -> [String: Double] {
        if let knowledgeUsageCache { return knowledgeUsageCache }
        var out: [String: Double] = [:]
        if let db = await SQLiteDB.sharedIfAvailable(Paths.knowledgeC),
           await db.hasColumns("ZOBJECT", ["ZSTREAMNAME", "ZSTARTDATE", "ZENDDATE", "ZVALUESTRING"]),
           let rows = try? await db.rows("SELECT ZVALUESTRING, sum(ZENDDATE - ZSTARTDATE) FROM ZOBJECT WHERE ZSTREAMNAME = '/app/usage' GROUP BY ZVALUESTRING") {
            for r in rows { if let b = r[0].string, let s = r[1].double { out[b] = s } }
        }
        knowledgeUsageCache = out
        return out
    }

    // MARK: Aggregation

    private func bounds(_ focus: DeviceFocus, _ range: ActivityRange) -> (lo: Double, hi: Double) {
        let hi = focus.sessions.last.map { max($0.end, focus.lastEvent ?? $0.end) } ?? 0
        guard let days = range.days else { return (-Double.infinity, Double.infinity) }
        // Relative to the device's newest record, so a device that stopped syncing still
        // shows its last week rather than nothing.
        return (hi - Double(days) * 86_400, Double.infinity)
    }

    /// All dashboard / table numbers for one device and range, in a single pass.
    func aggregate(device: String, range: ActivityRange) async -> FocusAggregate {
        let key = device + "|" + range.rawValue
        if let hit = aggregateCache[key] { return hit }
        let focus = await self.focus(device)
        let t0 = Date()
        let (lo, _) = bounds(focus, range)
        let appCount = focus.bundles.count
        // Plain arrays in the hot loop; the row structs (with strings) are built once at the end.
        var activations = [Int](repeating: 0, count: appCount)
        var totals = [Double](repeating: 0, count: appCount)
        var longest = [Double](repeating: 0, count: appCount)
        var cappedCount = [Int](repeating: 0, count: appCount)
        var daysActive = [Int](repeating: 0, count: appCount)
        var durations = [[Float]](repeating: [], count: appCount)
        var lastDay = [Double](repeating: -1, count: appCount)
        var firstT = [Double](repeating: .infinity, count: appCount)
        var lastT = [Double](repeating: -.infinity, count: appCount)
        var heat = [Double](repeating: 0, count: 7 * 24)
        // Sessions are time-ordered, so days only ever advance: append-on-change arrays
        // instead of dictionaries keep this loop allocation-free.
        var days: [DayStat] = []
        var dayKey = -Double.infinity
        var rhythm: [DayStat] = []
        var rhythmKey = -Double.infinity
        var agg = FocusAggregate()
        var cursor = DayCursor()
        var logical = DayCursor()
        var previousApp: Int32 = -1
        var previousEnd = -Double.infinity
        var minT = Double.infinity, maxT = -Double.infinity

        for s in focus.sessions where s.end > lo {
            let start = max(s.start, lo)
            let duration = s.end - start
            if s.isSystem { agg.systemTotal += duration; continue }
            let a = Int(s.app)
            minT = min(minT, start); maxT = max(maxT, s.end)
            if !s.isContinuation { activations[a] += 1; agg.activations += 1 }
            totals[a] += duration
            if duration > longest[a] { longest[a] = duration }
            if s.isCapped { cappedCount[a] += 1; agg.capped += 1 }
            durations[a].append(Float(duration))
            firstT[a] = min(firstT[a], start); lastT[a] = max(lastT[a], s.end)
            agg.total += duration

            // Split across hours and calendar days.
            var t = start
            while t < s.end {
                cursor.seek(t)
                let hour = min(23, max(0, Int((t - cursor.dayStart) / 3600)))
                let hourEnd = min(cursor.dayStart + Double(hour + 1) * 3600, cursor.dayEnd)
                let pieceEnd = min(s.end, max(hourEnd, t + 0.001))
                heat[(cursor.weekday - 1) * 24 + hour] += pieceEnd - t
                if cursor.dayStart != dayKey {
                    dayKey = cursor.dayStart
                    days.append(DayStat(day: Date(timeIntervalSinceReferenceDate: dayKey)))
                }
                days[days.count - 1].total += pieceEnd - t
                if lastDay[a] != cursor.dayStart { lastDay[a] = cursor.dayStart; daysActive[a] += 1 }
                t = pieceEnd
            }
            if !days.isEmpty { days[days.count - 1].sessions += 1 }

            // Daily rhythm on a 04:00–04:00 "logical day".
            logical.seek(start - 4 * 3600)
            if logical.dayStart != rhythmKey {
                rhythmKey = logical.dayStart
                rhythm.append(DayStat(day: Date(timeIntervalSinceReferenceDate: rhythmKey)))
            }
            let h0 = (start - rhythmKey) / 3600
            let h1 = min((s.end - rhythmKey) / 3600, 28)
            let ri = rhythm.count - 1
            rhythm[ri].first = min(rhythm[ri].first ?? h0, h0)
            rhythm[ri].last = max(rhythm[ri].last ?? h1, h1)
            rhythm[ri].total += duration
            rhythm[ri].sessions += 1

            // Transition: the previous app ended at most 60 s before this one started.
            if previousApp >= 0, previousApp != s.app, start - previousEnd <= 60 {
                agg.transitions[UInt64(previousApp) << 32 | UInt64(a), default: 0] += 1
            }
            previousApp = s.app
            previousEnd = s.end
        }

        var rows: [AppUsageRow] = []
        for a in 0..<appCount where !durations[a].isEmpty {
            var d = durations[a]
            d.sort()
            var row = AppUsageRow(bundle: focus.bundles[a], name: focus.names[a])
            row.activations = activations[a]
            row.total = totals[a]
            row.longest = longest[a]
            row.capped = cappedCount[a]
            row.daysActive = daysActive[a]
            row.median = Double(d.count % 2 == 1 ? d[d.count / 2] : (d[d.count / 2 - 1] + d[d.count / 2]) / 2)
            row.first = Date(timeIntervalSinceReferenceDate: firstT[a])
            row.last = Date(timeIntervalSinceReferenceDate: lastT[a])
            rows.append(row)
        }
        var all = durations.flatMap { $0 }
        all.sort()
        agg.medianSession = all.isEmpty ? 0 : Double(all[all.count / 2])
        agg.apps = rows.filter { $0.total > 0 }.sorted { $0.total > $1.total }
        agg.days = days
        agg.rhythm = rhythm
        agg.heat = heat.enumerated().compactMap { i, w in w > 0 ? (weekday: i / 24 + 1, hour: i % 24, weight: w) : nil }
        agg.bundles = focus.bundles
        agg.names = focus.names
        if minT.isFinite, maxT.isFinite { agg.range = DossierDate.cocoa(minT)...DossierDate.cocoa(maxT) }

        if device == ActivityDevice.localID {
            let knowledge = await knowledgeUsage()
            let st = screenTimeTotals()
            let duet = await duet()
            for i in agg.apps.indices {
                let b = agg.apps[i].bundle
                agg.apps[i].knowledgeSeconds = knowledge[b]
                agg.apps[i].screenTimeSeconds = st[b]
                if let info = duet.appInfo[b] {
                    agg.apps[i].atxMedianGap = info.medianGap
                    agg.apps[i].atxLastLaunch = info.lastLaunch
                }
                agg.apps[i].dailyDose = duet.historicalDose[b]?.average
            }
        }
        aggregateCache[key] = agg
        note("aggregate", since: t0)
        return agg
    }

    private func screenTimeTotals() -> [String: Double] {
        let st = screenTime()
        var out: [String: Double] = [:]
        for s in st.sessions { out[st.bundles[Int(s.app)], default: 0] += s.duration }
        return out
    }

    /// Inspector data for one app.
    func appDetail(device: String, range: ActivityRange, bundle: String) async -> AppDetail? {
        let agg = await aggregate(device: device, range: range)
        guard let row = agg.apps.first(where: { $0.bundle == bundle }) else { return nil }
        let focus = await self.focus(device)
        guard let appIndex = focus.bundles.firstIndex(of: bundle) else { return nil }
        let (lo, _) = bounds(focus, range)
        var detail = AppDetail(row: row)
        var perDay: [Double: Double] = [:]
        var cursor = DayCursor()
        var recent: [TimelineBlock] = []
        for (i, s) in focus.sessions.enumerated() where Int(s.app) == appIndex && s.end > lo {
            var t = max(s.start, lo)
            while t < s.end {
                cursor.seek(t)
                let hour = min(23, max(0, Int((t - cursor.dayStart) / 3600)))
                let pieceEnd = min(s.end, max(min(cursor.dayStart + Double(hour + 1) * 3600, cursor.dayEnd), t + 0.001))
                detail.hourly[hour] += pieceEnd - t
                perDay[cursor.dayStart, default: 0] += pieceEnd - t
                t = pieceEnd
            }
            recent.append(TimelineBlock(id: i, bundle: bundle, name: row.name, start: DossierDate.cocoa(s.start), end: DossierDate.cocoa(s.end), isSystem: s.isSystem, isCapped: s.isCapped))
            if recent.count > 400 { recent.removeFirst(200) }
        }
        detail.recent = Array(recent.suffix(12).reversed())
        detail.daily = perDay.sorted { $0.key < $1.key }.map { ChartPoint(Date(timeIntervalSinceReferenceDate: $0.key), $0.value) }
        var next: [Int: Int] = [:], previous: [Int: Int] = [:]
        for (key, count) in agg.transitions {
            let from = Int(key >> 32), to = Int(key & 0xffff_ffff)
            if from == appIndex { next[to, default: 0] += count }
            if to == appIndex { previous[from, default: 0] += count }
        }
        func edges(_ m: [Int: Int]) -> [TransitionEdge] {
            m.map { TransitionEdge(bundle: agg.bundles[$0.key], name: agg.names[$0.key], count: $0.value) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        }
        detail.next = edges(next)
        detail.previous = edges(previous)
        if device == ActivityDevice.localID {
            let duet = await duet()
            if let info = duet.appInfo[bundle] {
                detail.atxInfo = info
                detail.atxNext = info.nextLaunches.map { (bundle: $0.bundle, name: AppNames.name($0.bundle), score: $0.score) }
            }
        }
        return detail
    }

    /// Sessions of one device that intersect `[from, to]` (binary search, system surfaces included).
    func blocks(device: String, from: Date, to: Date) async -> [TimelineBlock] {
        let focus = await self.focus(device)
        let lo = from.timeIntervalSinceReferenceDate, hi = to.timeIntervalSinceReferenceDate
        var l = 0, r = focus.sessions.count
        // Sessions never overlap, so their ends are sorted too: find the first one ending after `lo`.
        while l < r {
            let m = (l + r) / 2
            if focus.sessions[m].end <= lo { l = m + 1 } else { r = m }
        }
        var out: [TimelineBlock] = []
        var i = l
        while i < focus.sessions.count, focus.sessions[i].start < hi {
            let s = focus.sessions[i]
            if s.end > lo {
                out.append(TimelineBlock(id: i, bundle: focus.bundles[Int(s.app)], name: focus.names[Int(s.app)], start: DossierDate.cocoa(s.start), end: DossierDate.cocoa(s.end), isSystem: s.isSystem, isCapped: s.isCapped))
            }
            i += 1
        }
        return out
    }

    /// Sorted, filtered page of the app table.
    func appRows(device: String, range: ActivityRange, request: PageRequest) async -> [AppUsageRow] {
        var rows = await aggregate(device: device, range: range).apps
        let needle = request.search.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            rows = rows.filter { $0.name.localizedCaseInsensitiveContains(needle) || $0.bundle.localizedCaseInsensitiveContains(needle) }
        }
        if let sort = request.sort {
            func by<T: Comparable>(_ key: (AppUsageRow) -> T) {
                rows.sort { a, b in
                    let ka = key(a), kb = key(b)
                    if ka == kb { return a.total > b.total }
                    return sort.ascending ? ka < kb : ka > kb
                }
            }
            switch sort.columnID {
            case "name": by { $0.name.lowercased() }
            case "bundle": by { $0.bundle.lowercased() }
            case "activations": by { $0.activations }
            case "median": by { $0.median }
            case "longest": by { $0.longest }
            case "days": by { $0.daysActive }
            case "last": by { $0.last ?? .distantPast }
            case "first": by { $0.first ?? .distantPast }
            case "screentime": by { $0.screenTimeSeconds ?? -1 }
            case "knowledge": by { $0.knowledgeSeconds ?? -1 }
            case "gap": by { $0.atxMedianGap ?? -1 }
            case "dose": by { $0.dailyDose ?? -1 }
            default: by { $0.total }
            }
        }
        return Array(rows.dropFirst(request.offset).prefix(request.limit))
    }

    /// Days (local midnight) on which a device has any session, newest last.
    func activeDays(device: String) async -> [Date] {
        let agg = await aggregate(device: device, range: .all)
        return agg.days.map(\.day)
    }
}
