import Foundation
import DossierCore

struct NotificationEvent: Identifiable, Sendable {
    let id: String
    let date: Date
    let bundle: String
    /// "Usage" (interaction / receipt logged by the notification system) or "Delivery".
    let stream: String
    let detail: String
    let identifier: String
    let ref: RawRef
}

struct FeatureSignal: Identifiable, Sendable {
    let id: String
    let date: Date
    let identifier: String
    let context: String
    let build: String
    let ref: RawRef
}

struct SignalsData: Sendable {
    var notifications: [NotificationEvent] = []
    var usageCount = 0
    var deliveryCount = 0
    /// Distinct notifications: the Usage and Delivery streams both log the same
    /// notification, so their entry counts must not be added up.
    var distinctCount = 0
    /// Per app, most notifications first. `distinct` counts each notification once.
    var perApp: [(bundle: String, usage: Int, delivery: Int, distinct: Int)] = []
    var notificationsPerDay: [ChartPoint] = []
    var knowledgePerApp: [(bundle: String, count: Int)] = []
    var knowledgeTotal = 0
    var knowledgeRange: ClosedRange<Date>?
    var signals: [FeatureSignal] = []
    var perSignal: [(identifier: String, count: Int)] = []
    var signalsPerDay: [ChartPoint] = []
    var notificationRange: ClosedRange<Date>?
    var signalRange: ClosedRange<Date>?
}

enum SignalsLoader {
    static func load(token: Int) async throws -> SignalsData {
        await EnvCache.shared.sync(token: token)
        return try await EnvCache.shared.value("signals") { await build() }
    }

    /// Seconds within which a Delivery entry and a Usage entry of one app are taken to
    /// describe the same notification.
    static let pairingWindow: TimeInterval = 5

    private static func perDay(_ dates: [Date], series: String = "") -> [ChartPoint] {
        let calendar = Calendar.current
        var bins: [Date: Int] = [:]
        for d in dates { bins[calendar.startOfDay(for: d), default: 0] += 1 }
        return bins.sorted { $0.key < $1.key }.map { ChartPoint($0.key, Double($0.value), series: series) }
    }

    private static func range(_ dates: [Date]) -> ClosedRange<Date>? {
        guard let lo = dates.min(), let hi = dates.max() else { return nil }
        return lo...hi
    }

    private static func build() async -> SignalsData {
        var data = SignalsData()
        var usage: [String: Int] = [:], delivery: [String: Int] = [:]
        var usageDates: [Date] = [], deliveryDates: [Date] = []
        // For de-duplication: notification UUIDs and usage times per app.
        var usageIDs: [String: Set<String>] = [:], usageAnonymous: [String: Int] = [:]
        var usageTimes: [String: [TimeInterval]] = [:], deliveryTimes: [String: [TimeInterval]] = [:]

        // Notification.Usage — 2 Cocoa date, 3 usage type code, 4 bundle id, 5 notification UUID.
        EnvBiome.forEach("Notification.Usage") { record, msg in
            let bundle = msg[4]?.string ?? "(unknown)"
            let date = msg[2]?.cocoaDate ?? record.timestamp
            usage[bundle, default: 0] += 1
            usageDates.append(date)
            usageTimes[bundle, default: []].append(date.timeIntervalSinceReferenceDate)
            if let uuid = msg[5]?.string, !uuid.isEmpty { usageIDs[bundle, default: []].insert(uuid) } else { usageAnonymous[bundle, default: 0] += 1 }
            data.notifications.append(NotificationEvent(
                id: "u|" + record.id, date: date, bundle: bundle, stream: "Usage",
                detail: msg[3]?.int.map { "usage type \($0)" } ?? "", identifier: msg[5]?.string ?? "", ref: EnvBiome.ref(record)))
        }
        // Notification.Delivery — 1 notification / category identifier, 2 bundle id, 3 Unix date.
        EnvBiome.forEach("Notification.Delivery") { record, msg in
            let bundle = msg[2]?.string ?? "(unknown)"
            let date = msg[3]?.unixDate ?? record.timestamp
            delivery[bundle, default: 0] += 1
            deliveryDates.append(date)
            deliveryTimes[bundle, default: []].append(date.timeIntervalSinceReferenceDate)
            data.notifications.append(NotificationEvent(
                id: "d|" + record.id, date: date, bundle: bundle, stream: "Delivery",
                detail: "delivered", identifier: msg[1]?.string ?? "", ref: EnvBiome.ref(record)))
        }
        data.usageCount = usageDates.count
        data.deliveryCount = deliveryDates.count
        data.notifications.sort { $0.date > $1.date }
        // A notification is counted once: every distinct Usage UUID, plus the Delivery
        // entries that have no Usage entry of the same app within a few seconds.
        func distinct(_ bundle: String) -> Int {
            let times = (usageTimes[bundle] ?? []).sorted()
            var unmatched = 0
            for t in deliveryTimes[bundle] ?? [] {
                // First usage time >= t - window.
                var lo = 0, hi = times.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if times[mid] < t - Self.pairingWindow { lo = mid + 1 } else { hi = mid }
                }
                if lo == times.count || times[lo] > t + Self.pairingWindow { unmatched += 1 }
            }
            return (usageIDs[bundle]?.count ?? 0) + (usageAnonymous[bundle] ?? 0) + unmatched
        }
        data.perApp = Set(usage.keys).union(delivery.keys)
            .map { ($0, usage[$0] ?? 0, delivery[$0] ?? 0, distinct($0)) }
            .sorted { ($0.3, $1.0) > ($1.3, $0.0) }
        data.distinctCount = data.perApp.reduce(0) { $0 + $1.distinct }
        data.notificationsPerDay = perDay(usageDates, series: "Usage") + perDay(deliveryDates, series: "Delivery")
        data.notificationRange = range(usageDates + deliveryDates)

        let knowledge = await KnowledgeSource.notificationCounts()
        data.knowledgePerApp = knowledge.perApp
        data.knowledgeTotal = knowledge.total
        data.knowledgeRange = knowledge.range

        // Discoverability.Signals — 1 signal identifier, 2 context, 3 OS build.
        var perSignal: [String: Int] = [:]
        EnvBiome.forEach("Discoverability.Signals") { record, msg in
            let identifier = msg[1]?.string ?? "(unknown)"
            perSignal[identifier, default: 0] += 1
            data.signals.append(FeatureSignal(
                id: record.id, date: record.timestamp, identifier: identifier, context: msg[2]?.string ?? "",
                build: msg[3]?.string ?? "", ref: EnvBiome.ref(record)))
        }
        data.perSignal = perSignal.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { ($0.key, $0.value) }
        data.signalsPerDay = perDay(data.signals.map(\.date))
        data.signalRange = range(data.signals.map(\.date))
        return data
    }
}
