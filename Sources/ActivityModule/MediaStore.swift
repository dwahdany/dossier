import DossierCore
import Foundation

/// One `Media.NowPlaying` record: what the system-wide Now Playing widget showed.
///
/// Field numbers (empirical): 2 absolute timestamp (Cocoa), 3 playback state (0 unknown,
/// 1 playing, 2 paused, 3 stopped, 4 interrupted, 5 seeking), 4 album, 5 artist, 6 duration
/// (s), 7 genre, 8 title, 9 elapsed, 10 media type, 14 output device { 1 type, 2 subtype,
/// 3 name }, 15 bundle id.
struct NowPlayingEvent: Identifiable, Sendable {
    let id: Int
    let date: Date
    let state: Int
    let title: String
    let artist: String
    let album: String
    let genre: String
    let bundle: String
    let appName: String
    let route: String
    let mediaType: String
    let duration: Double
    let deviceID: String
    let flag: MediaFlag

    var stateLabel: String {
        switch state {
        case 1: return "Playing"
        case 2: return "Paused"
        case 3: return "Stopped"
        case 4: return "Interrupted"
        case 5: return "Seeking"
        default: return "Unknown"
        }
    }

    var kindLabel: String {
        if mediaType.localizedCaseInsensitiveContains("podcast") { return "Podcast" }
        if mediaType.localizedCaseInsensitiveContains("video") { return "Video" }
        if mediaType.localizedCaseInsensitiveContains("audio") { return "Audio" }
        return mediaType.isEmpty ? "—" : mediaType
    }
}

/// Why a now-playing title is probably not a music track but text captured verbatim from
/// something else (a web page, a video, a voice message, a call…).
enum MediaFlag: String, Sendable, CaseIterable {
    case none = ""
    case webPage = "Web / video title"
    case freeText = "Free text"
    case noMetadata = "No track metadata"

    var explanation: String {
        switch self {
        case .none: return "Looks like a regular track."
        case .webPage: return "Published by a browser or a video / social app: the title is the page or clip title, captured verbatim."
        case .freeText: return "Unusually long title, a URL or hashtags: free text rather than a track name."
        case .noMetadata: return "No artist, album, duration or media type: not a catalogued track."
        }
    }
}

/// A (title, artist) play: a transition into the playing state with a new item.
struct MediaPlay: Sendable {
    let key: String
    let title: String
    let artist: String
    let bundle: String
    let date: Date
    let deviceID: String
    let flag: MediaFlag
    /// Item duration in seconds (0 = unknown); sizes the cross-device mirror window.
    var duration: Double = 0
    /// Position in `MediaHistory.plays`.
    var index: Int = 0
}

struct MediaInterval: Identifiable, Sendable, Hashable {
    let id: Int
    let start: Date
    let end: Date
    let title: String
    let artist: String
    let bundle: String
}

struct MediaUsageSession: Identifiable, Sendable {
    let id: Int
    let bundle: String
    let name: String
    let start: Date
    let end: Date?
    let source: String
    let url: String
}

struct MediaHistory: Sendable {
    var events: [NowPlayingEvent] = []
    var plays: [MediaPlay] = []
    /// Indexes into `plays` of plays that only mirror another device's session (see
    /// `MediaMirror`). They stay in the per-device views and are left out of all-device counts.
    var mirrored: Set<Int> = []
    /// Route of every "playing" record that names one, with the play it belongs to (-1: none).
    var playingRoutes: [(play: Int, route: String, deviceID: String)] = []
    /// Per device: playing intervals for the timeline lane (sorted by start).
    var intervals: [String: [MediaInterval]] = [:]
    var usage: [MediaUsageSession] = []
    var undecodable = 0
    var perDevice: [String: Int] = [:]
    var timeRange: ClosedRange<Date>?
}

struct MediaSummary: Sendable {
    var events = 0
    var plays = 0
    /// All-device view only: plays left out because they mirror another device's session.
    var mirrored = 0
    var distinctTitles = 0
    var distinctArtists = 0
    var flagged = 0
    var flaggedTitles = 0
    var topArtists: [ChartBar] = []
    var topTitles: [ChartBar] = []
    var topApps: [(bundle: String, name: String, plays: Int)] = []
    var topRoutes: [ChartBar] = []
    var hours: [(weekday: Int, hour: Int, weight: Double)] = []
    var timeRange: ClosedRange<Date>?
    var listened: Double = 0
}

/// Turns Now Playing output-device identifiers into readable route names.
///
/// Field 14 of a record is `{ 1 type, 2 subtype, 3 output device id }`. The id is "Speaker"
/// for the built-in speaker; Bluetooth routes are `<address>-tacl` (A2DP audio) or
/// `<address>-tsco` (hands-free / call audio); AirPlay streams are
/// `<address>-Audio-AudioMain-<n>`; a bare address is an AirPlay / network receiver.
enum RouteNamer {
    static func label(_ id: String) -> String {
        if id.isEmpty { return "" }
        if id == "Speaker" { return "Built-in Speaker" }
        func tail(_ address: Substring) -> String {
            let hex = address.filter { $0.isHexDigit }
            return hex.count >= 4 ? " ··" + hex.suffix(4) : ""
        }
        if id.hasSuffix("-tacl") { return "Bluetooth Audio" + tail(id.dropLast(5)) }
        if id.hasSuffix("-tsco") { return "Bluetooth Hands-Free" + tail(id.dropLast(5)) }
        if let r = id.range(of: "-Audio-AudioMain") { return "AirPlay Stream" + tail(id[..<r.lowerBound]) }
        let groups = id.split(separator: ":")
        if groups.count == 6, groups.allSatisfy({ $0.count == 2 }) { return "AirPlay Receiver" + tail(id[...]) }
        return id
    }
}

/// Cross-device de-duplication of plays.
///
/// A watch (or a Mac) republishes the session of the phone it remote-controls: the same
/// item, with the phone app's bundle id, seconds to minutes later. Such a record is a
/// mirror, not a second play. Rule: plays of the same item are grouped when they start on
/// *different* devices within max(5 min, item duration, capped at 4 h); a group counts once
/// and is represented by its earliest play. A device appears at most once per group, so a
/// genuine replay on the same device opens a new group (which its own mirror then joins).
enum MediaMirror {
    static let minimumWindow: Double = 300
    static let maximumWindow: Double = 4 * 3600

    static func window(_ duration: Double) -> Double {
        max(minimumWindow, min(duration, maximumWindow))
    }

    /// Indexes (`MediaPlay.index`) of the plays that mirror an earlier play elsewhere.
    static func mirrored(_ plays: [MediaPlay]) -> Set<Int> {
        struct Group { var start: Date; var window: Double; var devices: [String] }
        var groups: [String: [Group]] = [:]
        var out = Set<Int>()
        for p in plays.sorted(by: { $0.date != $1.date ? $0.date < $1.date : $0.index < $1.index }) {
            var open = groups[p.key] ?? []
            open.removeAll { p.date.timeIntervalSince($0.start) > $0.window }
            // Most recent group this device is not part of yet.
            if let i = open.lastIndex(where: { !$0.devices.contains(p.deviceID) }) {
                open[i].devices.append(p.deviceID)
                open[i].window = max(open[i].window, window(p.duration))
                out.insert(p.index)
            } else {
                open.append(Group(start: p.date, window: window(p.duration), devices: [p.deviceID]))
            }
            groups[p.key] = open
        }
        return out
    }
}

enum MediaClassifier {
    /// Bundle id fragments of browsers and video / social apps, whose now-playing titles
    /// are page or clip titles. Generic product identifiers only.
    private static let webLike = [
        "safari", "firefox", "chrome", "brave", "edgemac", "opera", "arc", "browser", "webkit", "duckduckgo",
        "youtube", "tiktok", "instagram", "twitter", "tweetie", "facebook", "reddit", "linkedin", "twitch", "vimeo",
        "whatsapp", "telegram", "signal", "discord", "slack",
    ]

    static func flag(title: String, artist: String, album: String, bundle: String, mediaType: String, duration: Double) -> MediaFlag {
        if title.isEmpty { return .none }
        let b = bundle.lowercased()
        let isCatalogued = !album.isEmpty && !artist.isEmpty && duration > 0 && mediaType.localizedCaseInsensitiveContains("audio")
        if !isCatalogued, webLike.contains(where: { b.contains($0) }) { return .webPage }
        if title.count > 90 || title.contains("http://") || title.contains("https://") || title.filter({ $0 == "#" }).count >= 2 {
            return .freeText
        }
        if artist.isEmpty && album.isEmpty && duration <= 0 && mediaType.isEmpty { return .noMetadata }
        return .none
    }
}

extension ActivityStore {
    /// Decodes `Media.NowPlaying` for all devices (cached). Strings are interned: the same
    /// title / artist repeats for every play, pause and stop.
    func media() async -> MediaHistory {
        if let mediaCache { return mediaCache }
        let t0 = Date()
        var history = MediaHistory()
        var intern = StringInterner()
        var lo: Date?, hi: Date?
        if let stream = Biome.stream(named: "Media.NowPlaying") {
            var id = 0
            for device in stream.devices {
                let deviceID = device.identifier ?? ActivityDevice.localID
                var lastKey = ""
                var currentPlay = -1
                var openStart: Date?
                var openEvent: NowPlayingEvent?
                var intervals: [MediaInterval] = []
                var count = 0
                func closeInterval(at end: Date) {
                    guard let s = openStart, let e = openEvent else { return }
                    var stop = end
                    // Cap: an item cannot play longer than its duration (if known) or 4 h.
                    let cap = e.duration > 0 ? e.duration * 1.25 + 30 : FocusPairer.maxSession
                    if stop.timeIntervalSince(s) > cap { stop = s.addingTimeInterval(cap) }
                    if stop > s { intervals.append(MediaInterval(id: e.id, start: s, end: stop, title: e.title, artist: e.artist, bundle: e.bundle)) }
                    openStart = nil; openEvent = nil
                }
                BiomeStreamReader(stream).forEach(device: device, order: .oldestFirst) { record in
                    if record.payload.isEmpty { return true }
                    var time: Double?
                    var state = 0
                    var title = "", artist = "", album = "", genre = "", bundle = "", route = "", mediaType = ""
                    var duration: Double = 0
                    let ok = FastProto.scan(record.payload) { field, value in
                        switch (field, value) {
                        case (2, .fixed64(let bits)): time = FastProto.double(bits)
                        case (3, .varint(let v)): state = Int(v)
                        case (4, .bytes(let r)): album = FastProto.string(r)
                        case (5, .bytes(let r)): artist = FastProto.string(r)
                        case (6, .varint(let v)): duration = Double(v)
                        case (6, .fixed64(let bits)): duration = FastProto.double(bits)
                        case (7, .bytes(let r)): genre = FastProto.string(r)
                        case (8, .bytes(let r)): title = FastProto.string(r)
                        case (10, .bytes(let r)): mediaType = FastProto.string(r)
                        case (14, .bytes(let r)):
                            FastProto.forEach(r) { f, v in
                                if f == 3, case .bytes(let rr) = v {
                                    let name = RouteNamer.label(FastProto.string(rr))
                                    route = route.isEmpty ? name : route + ", " + name
                                }
                            }
                        case (15, .bytes(let r)): bundle = FastProto.string(r)
                        default: break
                        }
                    }
                    guard ok else { history.undecodable += 1; return true }
                    let date = time.map(DossierDate.cocoa) ?? record.timestamp
                    let flag = MediaClassifier.flag(title: title, artist: artist, album: album, bundle: bundle, mediaType: mediaType, duration: duration)
                    let event = NowPlayingEvent(
                        id: id, date: date, state: state,
                        title: intern(title), artist: intern(artist), album: intern(album), genre: intern(genre),
                        bundle: intern(bundle), appName: intern(AppNames.name(bundle)), route: intern(route),
                        mediaType: intern(mediaType), duration: duration, deviceID: deviceID, flag: flag
                    )
                    id += 1
                    count += 1
                    history.events.append(event)
                    lo = min(lo ?? date, date); hi = max(hi ?? date, date)
                    let key = title + "\u{1f}" + artist
                    if state == 1 {
                        if key != lastKey || openStart == nil {
                            closeInterval(at: date)
                            openStart = date; openEvent = event
                        }
                        if key != lastKey, !title.isEmpty {
                            currentPlay = history.plays.count
                            history.plays.append(MediaPlay(key: key, title: event.title, artist: event.artist, bundle: event.bundle, date: date, deviceID: deviceID, flag: flag, duration: duration, index: currentPlay))
                        } else if key != lastKey {
                            currentPlay = -1
                        }
                        if !event.route.isEmpty { history.playingRoutes.append((play: currentPlay, route: event.route, deviceID: deviceID)) }
                        lastKey = key
                    } else {
                        closeInterval(at: date)
                        // A stop resets the item, so replaying the same track counts again.
                        if state == 3 || state == 0 { lastKey = "" }
                    }
                    return true
                }
                history.intervals[deviceID] = intervals
                history.perDevice[deviceID] = count
            }
        }
        if let lo, let hi { history.timeRange = lo...hi }
        history.mirrored = MediaMirror.mirrored(history.plays)
        history.usage = await mediaUsage()
        mediaCache = history
        note("media.decode", since: t0)
        return history
    }

    /// `App.MediaUsage` (Biome, this Mac) paired by session UUID, plus knowledgeC
    /// `/app/mediaUsage` intervals: which apps played media, as recorded for Screen Time.
    private func mediaUsage() async -> [MediaUsageSession] {
        var out: [MediaUsageSession] = []
        var id = 0
        if let stream = Biome.stream(named: "App.MediaUsage") {
            var open: [String: (bundle: String, start: Date)] = [:]
            BiomeStreamReader(stream).forEach(device: .local, order: .oldestFirst) { record in
                var starting = false
                var bundle = "", session = "", url = ""
                var unix: Double?
                FastProto.scan(record.payload) { field, value in
                    switch (field, value) {
                    case (1, .varint(let v)): starting = v != 0
                    case (2, .bytes(let r)): bundle = FastProto.string(r)
                    case (3, .bytes(let r)), (4, .bytes(let r)): url = FastProto.string(r)
                    case (6, .fixed64(let bits)): unix = FastProto.double(bits)
                    case (8, .bytes(let r)): session = FastProto.string(r)
                    default: break
                    }
                }
                let date = unix.map(DossierDate.unix) ?? record.timestamp
                let key = session.isEmpty ? bundle : session
                if starting {
                    open[key] = (bundle, date)
                } else if let o = open.removeValue(forKey: key) {
                    out.append(MediaUsageSession(id: id, bundle: o.bundle, name: AppNames.name(o.bundle), start: o.start, end: date, source: "Biome App.MediaUsage", url: url))
                    id += 1
                }
                return true
            }
            for (_, o) in open {
                out.append(MediaUsageSession(id: id, bundle: o.bundle, name: AppNames.name(o.bundle), start: o.start, end: nil, source: "Biome App.MediaUsage", url: ""))
                id += 1
            }
        }
        if let db = await SQLiteDB.sharedIfAvailable(Paths.knowledgeC),
           await db.hasColumns("ZOBJECT", ["ZSTREAMNAME", "ZSTARTDATE", "ZENDDATE", "ZVALUESTRING", "ZSTRUCTUREDMETADATA"]) {
            let hasURL = await db.hasColumns("ZSTRUCTUREDMETADATA", ["Z_DKAPPMEDIAUSAGEMETADATAKEY__URL"])
            let urlExpr = hasURL ? "(SELECT m.Z_DKAPPMEDIAUSAGEMETADATAKEY__URL FROM ZSTRUCTUREDMETADATA m WHERE m.Z_PK = o.ZSTRUCTUREDMETADATA)" : "NULL"
            if let rows = try? await db.rows("SELECT o.ZVALUESTRING, o.ZSTARTDATE, o.ZENDDATE, \(urlExpr) FROM ZOBJECT o WHERE o.ZSTREAMNAME = '/app/mediaUsage' ORDER BY o.ZSTARTDATE DESC LIMIT 20000") {
                for r in rows {
                    guard let bundle = r[0].string, let start = r[1].cocoaDate else { continue }
                    var url = r[3].string ?? ""
                    if url.isEmpty, let data = r[3].data { url = PlistDecoder.decodeAny(data)?.allStrings(limit: 2).first ?? "" }
                    out.append(MediaUsageSession(id: id, bundle: bundle, name: AppNames.name(bundle), start: start, end: r[2].cocoaDate, source: "knowledgeC /app/mediaUsage", url: url))
                    id += 1
                }
            }
        }
        return out.sorted { $0.start > $1.start }
    }

    /// Plays restricted to a device (nil = all), oldest first. With all devices, a play that
    /// only mirrors another device's session (`MediaMirror`) is left out, so an item played
    /// on the phone and echoed by the watch counts once.
    func mediaPlays(device: String?) async -> [MediaPlay] {
        let history = await media()
        if let device { return history.plays.filter { $0.deviceID == device } }
        return history.plays
            .filter { !history.mirrored.contains($0.index) }
            .sorted { $0.date != $1.date ? $0.date < $1.date : $0.index < $1.index }
    }

    func mediaSummary(device: String?) async -> MediaSummary {
        let history = await media()
        let plays = await mediaPlays(device: device)
        var s = MediaSummary()
        let events = device == nil ? history.events : history.events.filter { $0.deviceID == device }
        s.events = events.count
        s.plays = plays.count
        s.mirrored = device == nil ? history.mirrored.count : 0
        var artists: [String: Int] = [:], titles: [String: Int] = [:], apps: [String: Int] = [:]
        var titleLabel: [String: String] = [:]
        var artistLabel: [String: String] = [:]
        var flaggedKeys = Set<String>()
        var heat = [Double](repeating: 0, count: 7 * 24)
        let cal = Calendar.current
        for p in plays {
            titles[p.key, default: 0] += 1
            if titleLabel[p.key] == nil { titleLabel[p.key] = p.artist.isEmpty ? p.title : p.title + " — " + p.artist }
            if !p.artist.isEmpty, p.flag == .none {
                // Catalogues disagree on capitalisation; count case-insensitively, show the first spelling.
                let k = p.artist.lowercased()
                artists[k, default: 0] += 1
                if artistLabel[k] == nil { artistLabel[k] = p.artist }
            }
            apps[p.bundle, default: 0] += 1
            if p.flag != .none { s.flagged += 1; flaggedKeys.insert(p.key) }
            let c = cal.dateComponents([.weekday, .hour], from: p.date)
            if let w = c.weekday, let h = c.hour { heat[(w - 1) * 24 + h] += 1 }
        }
        s.distinctTitles = titles.count
        s.distinctArtists = artists.count
        s.flaggedTitles = flaggedKeys.count
        func top(_ m: [String: Int], _ n: Int, label: (String) -> String) -> [ChartBar] {
            var seen = Set<String>()
            return m.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n * 2).compactMap { entry in
                var l = Format.oneLine(label(entry.key), max: 48)
                if l.isEmpty { return nil }
                while seen.contains(l) { l += " " }
                seen.insert(l)
                return ChartBar(l, Double(entry.value))
            }.prefix(n).map { $0 }
        }
        s.topArtists = top(artists, 12) { artistLabel[$0] ?? $0 }
        s.topTitles = top(titles.filter { !flaggedKeys.contains($0.key) }, 12) { titleLabel[$0] ?? $0 }
        s.topApps = apps.sorted { $0.value > $1.value }.prefix(8).map { (bundle: $0.key, name: AppNames.name($0.key), plays: $0.value) }
        var routes: [String: Int] = [:]
        for r in history.playingRoutes {
            if let device {
                if r.deviceID != device { continue }
            } else if history.mirrored.contains(r.play) {
                continue
            }
            routes[r.route, default: 0] += 1
        }
        s.topRoutes = top(routes, 6) { $0 }
        s.hours = heat.enumerated().compactMap { i, w in w > 0 ? (weekday: i / 24 + 1, hour: i % 24, weight: w) : nil }
        let intervals = device.map { history.intervals[$0] ?? [] } ?? (history.intervals.values.max { $0.count < $1.count } ?? [])
        s.listened = intervals.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        if let a = events.map(\.date).min(), let b = events.map(\.date).max() { s.timeRange = a...b }
        return s
    }

    enum MediaFilter: String, CaseIterable, Identifiable, Sendable {
        case all = "All Events", plays = "Playing Only", flagged = "Flagged Text"
        var id: String { rawValue }
    }

    /// Filtered + sorted page of now-playing events for the table.
    func mediaPage(device: String?, filter: MediaFilter, search: String, sort: PageSort?, offset: Int, limit: Int) async -> (rows: [NowPlayingEvent], total: Int) {
        let key = [device ?? "*", filter.rawValue, search, sort?.columnID ?? "", String(sort?.ascending ?? false)].joined(separator: "\u{1f}")
        if let cached = mediaViewCache, cached.key == key {
            return (Array(cached.rows.dropFirst(offset).prefix(limit)), cached.rows.count)
        }
        let history = await media()
        let needle = search.trimmingCharacters(in: .whitespaces)
        var rows = history.events.filter { e in
            if let device, e.deviceID != device { return false }
            switch filter {
            case .all: break
            case .plays: if e.state != 1 { return false }
            case .flagged: if e.flag == .none { return false }
            }
            if needle.isEmpty { return true }
            return e.title.localizedCaseInsensitiveContains(needle) || e.artist.localizedCaseInsensitiveContains(needle)
                || e.album.localizedCaseInsensitiveContains(needle) || e.appName.localizedCaseInsensitiveContains(needle)
                || e.bundle.localizedCaseInsensitiveContains(needle) || e.route.localizedCaseInsensitiveContains(needle)
        }
        let ascending = sort?.ascending ?? false
        func order<T: Comparable>(_ key: (NowPlayingEvent) -> T) {
            rows.sort { a, b in
                let ka = key(a), kb = key(b)
                if ka == kb { return a.date > b.date }
                return ascending ? ka < kb : ka > kb
            }
        }
        switch sort?.columnID ?? "date" {
        case "title": order { $0.title.lowercased() }
        case "artist": order { $0.artist.lowercased() }
        case "album": order { $0.album.lowercased() }
        case "app": order { $0.appName.lowercased() }
        case "route": order { $0.route.lowercased() }
        case "state": order { $0.state }
        case "duration": order { $0.duration }
        case "flag": order { $0.flag.rawValue }
        case "device": order { $0.deviceID }
        default: rows.sort { ascending ? $0.date < $1.date : $0.date > $1.date }
        }
        mediaViewCache = (key, rows)
        let total = rows.count
        return (Array(rows.dropFirst(offset).prefix(limit)), total)
    }

    func mediaIntervals(device: String, from: Date, to: Date) async -> [MediaInterval] {
        let history = await media()
        return (history.intervals[device] ?? []).filter { $0.end > from && $0.start < to }
    }
}
