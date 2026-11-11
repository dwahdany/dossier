import Foundation
import DossierCore

// MARK: - Microlocation (milod)

struct MiloLOI: Identifiable, Sendable {
    let id: Int64
    let type: String
    let lastSeen: Date?
}

struct MiloBSSID: Identifiable, Sendable {
    var id: Int64 { bssid }
    let bssid: Int64
    let samples: Int
    let avgRSSI: Double
    let minRSSI: Int
    let maxRSSI: Int
    let channel: Int
    let first: Date?
    let last: Date?
    let associated: Bool

    var mac: String { EnvFormat.mac(bssid) }
}

struct MiloEvent: Identifiable, Sendable {
    let id: Int64
    let date: Date?
    let text: String
}

struct MiloModel: Identifiable, Sendable {
    let id: Int64
    let type: Int
    let generated: Date?
    let bytes: Int
}

struct MiloBluetoothIdentity: Identifiable, Sendable {
    let id: Int64
    let name: String
    let lastSeen: Date?
}

struct MiloData: Sendable {
    var availability: Availability = .missing
    var lois: [MiloLOI] = []
    var scans = 0
    var scanRange: ClosedRange<Date>?
    var measurements = 0
    var bssids: [MiloBSSID] = []
    var rssiHistogram: [(bucket: Int, count: Int)] = []
    var channelHistogram: [(channel: Int, count: Int)] = []
    var scansPerDay: [ChartPoint] = []
    var events: [MiloEvent] = []
    var models: [MiloModel] = []
    var identities: [MiloBluetoothIdentity] = []
    var services: [KV] = []
}

enum MiloSource {
    static func db() async -> SQLiteDB? { await SQLiteDB.sharedIfAvailable(EnvPaths.miloDB) }

    static func lois() async -> [MiloLOI] {
        guard let db = await db(), await db.hasColumns("ZULLOIMO", ["ZLOITYPE", "ZLASTSEENTIMESTAMP"]) else { return [] }
        // Several rows can describe the same labelled place; keep one per label / group.
        let group = await db.hasColumns("ZULLOIMO", ["ZLOIGROUPID"]) ? "coalesce(ZLOIGROUPID, Z_PK)" : "Z_PK"
        let rows = (try? await db.rows("SELECT min(Z_PK), ZLOITYPE, max(ZLASTSEENTIMESTAMP) FROM ZULLOIMO GROUP BY ZLOITYPE, \(group) LIMIT 500")) ?? []
        return rows.compactMap { row in
            row[0].int.map { MiloLOI(id: $0, type: row[1].string ?? "", lastSeen: row[2].cocoaDate) }
        }
    }

    static func load() async -> MiloData {
        var data = MiloData()
        data.availability = Paths.probe(EnvPaths.miloDB)
        guard let db = await db() else { return data }
        data.lois = await lois()

        if await db.hasColumns("ZULSCANNINGEVENTMO", ["ZTIMESTAMP"]) {
            if let row = try? await db.first("SELECT count(*), min(ZTIMESTAMP), max(ZTIMESTAMP) FROM ZULSCANNINGEVENTMO") {
                data.scans = Int(row[0].int ?? 0)
                if let lo = row[1].cocoaDate, let hi = row[2].cocoaDate, lo <= hi { data.scanRange = lo...hi }
            }
            let perDay = (try? await db.rows("SELECT CAST((ZTIMESTAMP + 978307200) / 86400 AS INTEGER), count(*) FROM ZULSCANNINGEVENTMO GROUP BY 1 ORDER BY 1")) ?? []
            data.scansPerDay = perDay.compactMap { row in
                row[0].int.map { ChartPoint(Date(timeIntervalSince1970: Double($0) * 86_400), Double(row[1].int ?? 0)) }
            }
        }

        if await db.hasColumns("ZULWIFIMEASUREMENTMO", ["ZSOURCEBSSID", "ZRSSI", "ZCHANNEL", "ZTIMESTAMP"]) {
            data.measurements = await db.rowCount(of: "ZULWIFIMEASUREMENTMO") ?? 0
            var associated = Set<Int64>()
            if await db.hasColumns("ZULSCANNINGEVENTMO", ["ZWIFIASSOCIATIONBSSID"]) {
                for row in (try? await db.rows("SELECT DISTINCT ZWIFIASSOCIATIONBSSID FROM ZULSCANNINGEVENTMO WHERE ZWIFIASSOCIATIONBSSID IS NOT NULL LIMIT 1000")) ?? [] {
                    if let b = row[0].int { associated.insert(b) }
                }
            }
            let sql = """
                SELECT ZSOURCEBSSID, count(*), avg(ZRSSI), min(ZRSSI), max(ZRSSI), max(ZCHANNEL), min(ZTIMESTAMP), max(ZTIMESTAMP)
                FROM ZULWIFIMEASUREMENTMO GROUP BY ZSOURCEBSSID ORDER BY 2 DESC LIMIT 5000
                """
            data.bssids = ((try? await db.rows(sql)) ?? []).compactMap { row in
                guard let b = row[0].int else { return nil }
                return MiloBSSID(
                    bssid: b, samples: Int(row[1].int ?? 0), avgRSSI: row[2].double ?? 0, minRSSI: Int(row[3].int ?? 0),
                    maxRSSI: Int(row[4].int ?? 0), channel: Int(row[5].int ?? 0), first: row[6].cocoaDate, last: row[7].cocoaDate,
                    associated: associated.contains(b))
            }
            // RSSI is negative; 5 dBm buckets labelled by their lower (weaker) edge.
            let hist = (try? await db.rows("SELECT CAST((ZRSSI - 4) / 5 AS INTEGER) * 5, count(*) FROM ZULWIFIMEASUREMENTMO WHERE ZRSSI < 0 GROUP BY 1 ORDER BY 1")) ?? []
            data.rssiHistogram = hist.compactMap { row in row[0].int.map { (Int($0), Int(row[1].int ?? 0)) } }
            let channels = (try? await db.rows("SELECT ZCHANNEL, count(*) FROM ZULWIFIMEASUREMENTMO GROUP BY 1 ORDER BY 1")) ?? []
            data.channelHistogram = channels.compactMap { row in row[0].int.map { (Int($0), Int(row[1].int ?? 0)) } }
        }

        if await db.hasColumns("ZULEVENTLOGMO", ["ZTIMESTAMP", "ZEVENT"]) {
            data.events = ((try? await db.rows("SELECT Z_PK, ZTIMESTAMP, ZEVENT FROM ZULEVENTLOGMO ORDER BY ZTIMESTAMP DESC LIMIT 5000")) ?? []).compactMap { row in
                row[0].int.map { MiloEvent(id: $0, date: row[1].cocoaDate, text: row[2].string ?? "") }
            }
        }
        if await db.hasColumns("ZULMODELMO", ["ZMODELTYPE", "ZGENERATIONTIMESTAMP", "ZMODEL"]) {
            data.models = ((try? await db.rows("SELECT Z_PK, ZMODELTYPE, ZGENERATIONTIMESTAMP, length(ZMODEL) FROM ZULMODELMO ORDER BY ZGENERATIONTIMESTAMP DESC LIMIT 200")) ?? []).compactMap { row in
                row[0].int.map { MiloModel(id: $0, type: Int(row[1].int ?? 0), generated: row[2].cocoaDate, bytes: Int(row[3].int ?? 0)) }
            }
        }
        if await db.hasColumns("ZULBLUETOOTHIDENTITYMO", ["ZDEVICENAME", "ZLASTSEENTIMESTAMP"]) {
            let sql = "SELECT min(Z_PK), ZDEVICENAME, max(ZLASTSEENTIMESTAMP) FROM ZULBLUETOOTHIDENTITYMO GROUP BY ZDEVICENAME ORDER BY 3 DESC LIMIT 500"
            data.identities = ((try? await db.rows(sql)) ?? []).compactMap { row in
                row[0].int.map { MiloBluetoothIdentity(id: $0, name: row[1].string ?? "Unnamed device", lastSeen: row[2].cocoaDate) }
            }
        }
        if await db.hasColumns("ZULSERVICEMO", ["ZCLIENTID", "ZLASTACTIVETIMESTAMP"]) {
            for row in (try? await db.rows("SELECT ZCLIENTID, ZLASTACTIVETIMESTAMP FROM ZULSERVICEMO LIMIT 100")) ?? [] {
                data.services.append(KV(row[0].string ?? "client", "last active " + DossierDate.medium(row[1].cocoaDate)))
            }
        }
        return data
    }

    /// One page of raw Wi-Fi measurements (keyset-free: sorted views use OFFSET).
    static func measurements(_ request: PageRequest) async throws -> [MiloMeasurement] {
        guard let db = await db(), await db.hasColumns("ZULWIFIMEASUREMENTMO", ["ZSOURCEBSSID", "ZRSSI", "ZCHANNEL", "ZTIMESTAMP"]) else {
            throw DossierError.missing("The microlocation database has no Wi-Fi measurement table on this macOS version.")
        }
        let allowed = ["ZTIMESTAMP", "ZRSSI", "ZCHANNEL", "ZSOURCEBSSID", "ZSCANNINGEVENT"]
        let order: String
        if let sort = request.sort, allowed.contains(sort.columnID) { order = "\(sort.columnID) \(sort.sqlDirection)" } else { order = "ZTIMESTAMP DESC" }
        let hasScan = await db.hasColumns("ZULWIFIMEASUREMENTMO", ["ZSCANNINGEVENT"])
        let sql = "SELECT Z_PK, ZTIMESTAMP, ZSOURCEBSSID, ZRSSI, ZCHANNEL, \(hasScan ? "ZSCANNINGEVENT" : "NULL") FROM ZULWIFIMEASUREMENTMO ORDER BY \(order) LIMIT ? OFFSET ?"
        return try await db.rows(sql, [.integer(Int64(request.limit)), .integer(Int64(request.offset))]).compactMap { row in
            guard let pk = row[0].int else { return nil }
            return MiloMeasurement(id: pk, date: row[1].cocoaDate, bssid: row[2].int ?? 0, rssi: Int(row[3].int ?? 0), channel: Int(row[4].int ?? 0), scan: row[5].int)
        }
    }
}

struct MiloMeasurement: Identifiable, Sendable {
    let id: Int64
    let date: Date?
    let bssid: Int64
    let rssi: Int
    let channel: Int
    let scan: Int64?
}

// MARK: - Wi-Fi

struct WifiJoin: Identifiable, Sendable {
    let id: String
    let date: Date
    let end: Date?
    let ssid: String
    let bssid: String
    let channel: String
    let event: String
    let source: String
    let device: String
    let ref: RawRef
}

struct WifiData: Sendable {
    var networks: [KnownNetwork] = []
    var printers: [KnownPrinter] = []
    var joins: [WifiJoin] = []
    var kvsAvailability: Availability = .missing
    var streamCounts: [(name: String, count: Int)] = []
}

// MARK: - Bluetooth

struct BluetoothSession: Identifiable, Sendable {
    let id: String
    let address: String
    let name: String
    let host: String
    let start: Date
    /// Nil while the device was still connected at the end of the log.
    let end: Date?
    let source: String
    /// False for CoreDuet intervals of an accessory the Biome log already covers; such
    /// sessions are listed but not counted or drawn twice.
    var primary = true

    var duration: TimeInterval? { end.map { $0.timeIntervalSince(start) } }
}

struct BluetoothDevice: Identifiable, Sendable {
    var id: String { address }
    let address: String
    var name: String
    var productID: Int?
    var vendorID: Int?
    var deviceType: Int?
    var events: Int
    var sessions: Int
    var connectedSeconds: TimeInterval
    var first: Date?
    var last: Date?
    var hosts: Set<String>
    var lastBattery: String
}

struct NearbyDevice: Identifiable, Sendable {
    let id: String
    let date: Date
    let identifier: String
    let codes: String
    let ref: RawRef
}

struct BluetoothData: Sendable {
    var devices: [BluetoothDevice] = []
    var sessions: [BluetoothSession] = []
    var nearby: [NearbyDevice] = []
    var biomeEvents = 0
    var biomeEventsPerHost: [(host: String, count: Int)] = []
    /// knowledgeC intervals during which the accessory was connected.
    var knowledgeSessions = 0
    /// knowledgeC intervals recording that the accessory was NOT connected (not sessions).
    var knowledgeNotConnected = 0
    var range: ClosedRange<Date>?
}

struct NetworksData: Sendable {
    var wifi = WifiData()
    var milo = MiloData()
    var bluetooth = BluetoothData()
}

enum NetworksLoader {
    static func load(token: Int) async throws -> NetworksData {
        await EnvCache.shared.sync(token: token)
        return try await EnvCache.shared.value("networks") {
            async let wifi = wifi()
            async let milo = MiloSource.load()
            async let bluetooth = bluetooth()
            return await NetworksData(wifi: wifi, milo: milo, bluetooth: bluetooth)
        }
    }

    static func wifi() async -> WifiData {
        var data = WifiData()
        data.kvsAvailability = Paths.probe(EnvPaths.kvsDirectory)
        data.networks = await WifiKVS.networks()
        data.printers = await WifiKVS.printers()
        let namer = await DeviceNamer.load()
        var joins: [WifiJoin] = []

        // Device.Wireless.WiFi — 1 SSID, 2 connected flag.
        var n = 0
        EnvBiome.forEach("Device.Wireless.WiFi") { record, msg in
            n += 1
            joins.append(WifiJoin(
                id: "w|" + record.id, date: record.timestamp, end: nil, ssid: msg[1]?.string ?? "", bssid: "", channel: "",
                event: (msg[2]?.bool ?? false) ? "Connected" : "Disconnected", source: "Biome · Device.Wireless.WiFi",
                device: namer.name(record.device), ref: EnvBiome.ref(record)))
        }
        data.streamCounts.append(("Device.Wireless.WiFi", n))
        // _DKEvent.Wifi.Connection — a CoreDuet event: 2 start, 3 end (Cocoa), 4 { 3 SSID }.
        n = 0
        EnvBiome.forEach("_DKEvent.Wifi.Connection") { record, msg in
            n += 1
            joins.append(WifiJoin(
                id: "dk|" + record.id, date: msg[2]?.cocoaDate ?? record.timestamp, end: msg[3]?.cocoaDate,
                ssid: msg.string(at: 4, 3) ?? "", bssid: "", channel: "", event: "Connection interval",
                source: "Biome · _DKEvent.Wifi.Connection", device: namer.name(record.device), ref: EnvBiome.ref(record)))
        }
        data.streamCounts.append(("_DKEvent.Wifi.Connection", n))

        // milod association log: the access point (BSSID) the Mac was associated with.
        if let db = await MiloSource.db(), await db.hasColumns("ZULASSOCIATEDSTATEMO", ["ZTIMESTAMP", "ZMACADDRESS", "ZCHANNEL", "ZISASSOCIATED"]) {
            let rows = (try? await db.rows("SELECT Z_PK, ZTIMESTAMP, ZMACADDRESS, ZCHANNEL, ZISASSOCIATED FROM ZULASSOCIATEDSTATEMO ORDER BY ZTIMESTAMP DESC LIMIT 20000")) ?? []
            for row in rows {
                guard let pk = row[0].int, let date = row[1].cocoaDate else { continue }
                let channel = Int(row[3].int ?? 0)
                joins.append(WifiJoin(
                    id: "milo|\(pk)", date: date, end: nil, ssid: "", bssid: EnvFormat.mac(hex: row[2].string ?? ""),
                    channel: channel > 0 ? "\(channel) · \(EnvFormat.band(channel: channel))" : "",
                    event: (row[4].bool ?? true) ? "Associated with access point" : "Disassociated",
                    source: "milod · ZULASSOCIATEDSTATEMO", device: "This Mac", ref: .none))
            }
            data.streamCounts.append(("milod associations", rows.count))
        }
        // Known networks carry the last time the owner joined them by hand.
        for network in data.networks {
            if let date = network.lastJoinedByUser {
                joins.append(WifiJoin(
                    id: "kvs|" + network.id, date: date, end: nil, ssid: network.ssid, bssid: network.bssid, channel: "",
                    event: "Joined by user (last time)", source: "iCloud known networks", device: network.addedByText, ref: network.ref))
            }
        }
        data.joins = joins.sorted { $0.date > $1.date }
        return data
    }

    // Device.Wireless.Bluetooth — 1 address, 2 name, 3 product id, 4 connected flag,
    // 5 device type code, 6 case battery, 7 / 8 left / right battery, 9 Apple audio flag,
    // 11 vendor (Bluetooth SIG company id).
    static func bluetooth() async -> BluetoothData {
        var data = BluetoothData()
        let namer = await DeviceNamer.load()
        struct Event { let date: Date; let host: String; let address: String; let connected: Bool }
        var events: [Event] = []
        var devices: [String: BluetoothDevice] = [:]
        var perHost: [String: Int] = [:]

        func touch(_ address: String, name: String, date: Date, host: String) {
            var d = devices[address] ?? BluetoothDevice(
                address: address, name: name, productID: nil, vendorID: nil, deviceType: nil, events: 0, sessions: 0,
                connectedSeconds: 0, first: nil, last: nil, hosts: [], lastBattery: "")
            if d.name.isEmpty || d.name == "Unnamed device" { d.name = name }
            d.first = min(d.first ?? date, date)
            d.last = max(d.last ?? date, date)
            d.hosts.insert(host)
            devices[address] = d
        }

        EnvBiome.forEach("Device.Wireless.Bluetooth") { record, msg in
            guard let address = msg[1]?.string else { return }
            let host = namer.name(record.device)
            let name = msg[2]?.string ?? "Unnamed device"
            events.append(Event(date: record.timestamp, host: host, address: address, connected: msg[4]?.bool ?? false))
            perHost[host, default: 0] += 1
            touch(address, name: name, date: record.timestamp, host: host)
            if var d = devices[address] {
                d.events += 1
                d.productID = d.productID ?? msg[3]?.int.map(Int.init)
                d.deviceType = d.deviceType ?? msg[5]?.int.map(Int.init)
                d.vendorID = d.vendorID ?? msg[11]?.int.map(Int.init)
                if d.lastBattery.isEmpty {
                    let parts = [("L", 7), ("R", 8), ("case", 6)].compactMap { label, n in
                        msg[n]?.int.flatMap { $0 > 0 ? "\(label) \($0)%" : nil }
                    }
                    d.lastBattery = parts.joined(separator: " · ")
                }
                devices[address] = d
            }
        }
        data.biomeEvents = events.count
        data.biomeEventsPerHost = perHost.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }

        // Pair connect / disconnect events per (host, device) into sessions.
        var sessions: [BluetoothSession] = []
        let grouped = Dictionary(grouping: events) { $0.host + "\u{1}" + $0.address }
        for (_, list) in grouped {
            var open: Date?
            for (i, e) in list.sorted(by: { $0.date < $1.date }).enumerated() {
                let name = devices[e.address]?.name ?? ""
                if e.connected {
                    if open == nil { open = e.date }
                } else if let start = open {
                    sessions.append(BluetoothSession(id: "b|\(e.host)|\(e.address)|\(i)", address: e.address, name: name, host: e.host, start: start, end: e.date, source: "Biome"))
                    open = nil
                }
                if i == list.count - 1, let start = open {
                    sessions.append(BluetoothSession(id: "b|\(e.host)|\(e.address)|open", address: e.address, name: name, host: e.host, start: start, end: nil, source: "Biome"))
                }
            }
        }
        let biomeAddresses = Set(sessions.map(\.address))
        // knowledgeC intervals (synced from the owner's other devices).
        let (knowledge, notConnected) = await KnowledgeSource.bluetoothSessions()
        data.knowledgeSessions = knowledge.count
        data.knowledgeNotConnected = notConnected
        for s in knowledge {
            let address = s.address.isEmpty ? s.name : s.address
            touch(address, name: s.name, date: s.start, host: s.host)
            if var d = devices[address] {
                d.productID = d.productID ?? s.productID
                d.deviceType = d.deviceType ?? s.deviceType
                d.last = max(d.last ?? s.end, s.end)
                devices[address] = d
            }
            sessions.append(BluetoothSession(id: "k|\(s.pk)", address: address, name: s.name, host: s.host, start: s.start, end: s.end, source: "knowledgeC", primary: !biomeAddresses.contains(address)))
        }
        for s in sessions where s.primary {
            guard var d = devices[s.address] else { continue }
            d.sessions += 1
            d.connectedSeconds += s.duration ?? 0
            devices[s.address] = d
        }
        data.sessions = sessions.sorted { $0.start > $1.start }
        data.devices = devices.values.sorted { $0.connectedSeconds > $1.connectedSeconds }
        let all = sessions.flatMap { [$0.start, $0.end ?? $0.start] }
        if let lo = all.min(), let hi = all.max() { data.range = lo...hi }

        // Device.Wireless.BluetoothNearbyDevice — 2 anonymous device identifier, 1/3/4 codes.
        EnvBiome.forEach("Device.Wireless.BluetoothNearbyDevice") { record, msg in
            let codes = [1, 3, 4].compactMap { n in msg[n]?.int.map { "field \(n) = \($0)" } }.joined(separator: ", ")
            data.nearby.append(NearbyDevice(id: record.id, date: record.timestamp, identifier: msg[2]?.string ?? "", codes: codes, ref: EnvBiome.ref(record)))
        }
        return data
    }
}
