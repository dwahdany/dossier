import Foundation
import DossierCore

/// Aggregates of the generative-AI related streams.
struct AITelemetry: Sendable {
    struct Count: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let count: Int
        var last: Date?
    }

    struct TaskRow: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let events: Int
        let completed: Int
        let failed: Int
        let errors: Int
        let last: Date?
        let lastStatus: String
    }

    struct AvailabilityRow: Identifiable, Sendable {
        let id: Int
        let date: Date
        let languages: String
        let flags: String
    }

    struct StreamState: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let summary: String
        let records: Int
        let deleted: Int
        let bytes: Int64
        let last: Date?
    }

    // GenerativeModels.GenerativeFunctions.Instrumentation
    var instrumentationRecords = 0
    var instrumentationRange: ClosedRange<Date>?
    var events: [Count] = []
    var useCases: [Count] = []
    var providers: [Count] = []
    var models: [Count] = []
    var clients: [Count] = []
    var errors: [Count] = []
    /// Requests per time bucket and use case (top use cases + "Other").
    var timeline: [ChartPoint] = []
    var timelineUnit: Calendar.Component = .day
    var requests = 0

    // AppleIntelligence.Availability
    var availability: [AvailabilityRow] = []
    // ModelCatalog / asset delivery
    var subscribers: [Count] = []
    var assetLogRecords = 0
    // Lighthouse ledger
    var tasks: [TaskRow] = []
    var ledgerRecords = 0
    // Transcript / transparency streams
    var transcripts: [StreamState] = []
    var scanSeconds = 0.0
}

/// Scans the AI telemetry streams once per refresh. The instrumentation stream holds
/// 100k+ small records, so it is walked with `FastProto` straight from the mapped file.
actor AIStore {
    static let shared = AIStore()
    private var token = Int.min
    private var cached: AITelemetry?

    /// Streams listed under "Transcripts & transparency", in display order.
    static let transcriptStreams: [String] = [
        "GenerativeExperiences.TransparencyLog", "IntelligenceFlow.Transcript.Datastream", "ToolKit.Transcript",
        "IntelligenceFlow.Telemetry", "IntelligenceFlow.IFRequestTelemetry", "IntelligenceFlow.PlanGenerationTelemetry",
        "IntelligenceFlow.PlanResolutionTelemetry", "IntelligenceFlow.ExecutorTelemetry", "IntelligenceFlow.ResponseGeneration",
        "IntelligenceFlow.QueryDecorationTelemetry", "IntelligenceFlow.JointResolverTelemetry", "IntelligenceFlow.SearchToolTelemetry",
        "IntelligenceFlow.Experimentation", "PrivateMLClient.SafetyMetrics", "Intelligence.Usage",
        "Feedback.EvaluationResponse", "Feedback.TextToTextEvaluationData", "Feedback.TextToImageEvaluationData",
        "Feedback.TextImageToImageEvaluationData",
    ]

    static let instrumentationStream = "GenerativeModels.GenerativeFunctions.Instrumentation"

    func load(token: Int, catalog: CatalogSnapshot) -> AITelemetry {
        if token == self.token, let cached { return cached }
        let started = Date()
        var out = AITelemetry()
        scanInstrumentation(catalog, into: &out)
        scanAvailability(catalog, into: &out)
        scanSubscribers(catalog, into: &out)
        scanLedger(catalog, into: &out)
        out.transcripts = AIStore.transcriptStreams.map { name in
            let entry = catalog.entry(named: name)
            return AITelemetry.StreamState(name: name, summary: BiomeStreamRegistry.info(for: name).summary, records: entry?.live ?? 0,
                                           deleted: entry?.deleted ?? 0, bytes: entry?.bytes ?? 0, last: entry?.range?.upperBound)
        }
        out.scanSeconds = Date().timeIntervalSince(started)
        if !Task.isCancelled {
            self.token = token
            cached = out
        }
        return out
    }

    private static func forEachPayload(_ entry: CatalogEntry?, _ body: (Date, UnsafeRawBufferPointer) -> Void) {
        guard let entry else { return }
        for segment in entry.stream.dataSegments() {
            if Task.isCancelled { return }
            guard let file = try? SEGBFile(url: segment.url) else { continue }
            for e in file.entries where e.state.isLive {
                file.payload(e).withUnsafeBytes { body(e.timestamp, $0) }
            }
        }
    }

    private static func top(_ counts: [String: Int], last: [String: Date] = [:], limit: Int = 40) -> [AITelemetry.Count] {
        counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit)
            .map { AITelemetry.Count(name: $0.key, count: $0.value, last: last[$0.key]) }
    }

    /// Fields used (see the registry): #3 event name, #10.8 use case, #10.3 client bundle,
    /// #10.13 inference provider, #10.10.1 model asset, #11.1.1 / #11.1.2 error domain / code.
    private func scanInstrumentation(_ catalog: CatalogSnapshot, into out: inout AITelemetry) {
        let entry = catalog.entry(named: AIStore.instrumentationStream)
        out.instrumentationRecords = entry?.live ?? 0
        out.instrumentationRange = entry?.range
        guard let entry, entry.live > 0 else { return }
        var events: [String: Int] = [:], useCases: [String: Int] = [:], providers: [String: Int] = [:]
        var models: [String: Int] = [:], clients: [String: Int] = [:], errors: [String: Int] = [:]
        var useCaseLast: [String: Date] = [:]
        let span = (entry.range?.upperBound.timeIntervalSince(entry.range?.lowerBound ?? Date()) ?? 0)
        let bucket: Double = span > 21 * 86_400 ? 86_400 : 3_600
        out.timelineUnit = bucket == 86_400 ? .day : .hour
        let tz = bucket == 86_400 ? DayIndex.offset : 0
        var buckets: [String: [Int: Int]] = [:]
        var requests = 0

        AIStore.forEachPayload(entry) { date, raw in
            var event: String?, useCase: String?
            FastProto.forEach(raw) { number, value in
                switch (number, value) {
                case (3, .bytes(let b)):
                    event = String(bytes: b, encoding: .utf8)
                case (10, .bytes(let sub)):
                    FastProto.forEach(sub) { n, v in
                        guard case .bytes(let b) = v else { return }
                        switch n {
                        case 8: useCase = String(bytes: b, encoding: .utf8)
                        case 3: if let s = String(bytes: b, encoding: .utf8) { clients[s, default: 0] += 1 }
                        case 13: if let s = String(bytes: b, encoding: .utf8) { providers[s, default: 0] += 1 }
                        case 10: if let s = FastProto.string(b, [1]) { models[s, default: 0] += 1 }
                        default: break
                        }
                    }
                case (11, .bytes(let sub)):
                    let domain = FastProto.string(sub, [1, 1]) ?? "Error"
                    let code = FastProto.double(sub, [1, 2]).map { " \(Int($0))" } ?? ""
                    errors[domain + code, default: 0] += 1
                default: break
                }
            }
            if let event { events[event, default: 0] += 1 }
            if let useCase, !useCase.isEmpty {
                useCases[useCase, default: 0] += 1
                useCaseLast[useCase] = max(useCaseLast[useCase] ?? date, date)
                requests += 1
                let slot = Int(((date.timeIntervalSinceReferenceDate + tz) / bucket).rounded(.down))
                buckets[useCase, default: [:]][slot, default: 0] += 1
            }
        }
        out.events = AIStore.top(events)
        out.useCases = AIStore.top(useCases, last: useCaseLast)
        out.providers = AIStore.top(providers)
        out.models = AIStore.top(models)
        out.clients = AIStore.top(clients)
        out.errors = AIStore.top(errors)
        out.requests = requests
        let leaders = Set(out.useCases.prefix(5).map(\.name))
        var series: [String: [Int: Int]] = [:]
        for (name, slots) in buckets {
            let key = leaders.contains(name) ? name : "Other"
            for (slot, n) in slots { series[key, default: [:]][slot, default: 0] += n }
        }
        out.timeline = series.flatMap { name, slots in
            slots.map { ChartPoint(Date(timeIntervalSinceReferenceDate: Double($0.key) * bucket - tz), Double($0.value), series: name) }
        }.sorted { $0.date < $1.date }
    }

    private func scanAvailability(_ catalog: CatalogSnapshot, into out: inout AITelemetry) {
        var rows: [AITelemetry.AvailabilityRow] = []
        AIStore.forEachPayload(catalog.entry(named: "AppleIntelligence.Availability")) { date, raw in
            var languages: [String] = []
            var flags: [String] = []
            FastProto.forEach(raw) { number, value in
                switch value {
                case .bytes(let b):
                    if number == 6, let s = String(bytes: b, encoding: .utf8) { languages.append(s); return }
                    FastProto.forEach(b) { n, v in
                        if case .varint(let x) = v { flags.append("#\(number).\(n)=\(x)") }
                    }
                case .varint(let x): flags.append("#\(number)=\(x)")
                default: break
                }
            }
            rows.append(AITelemetry.AvailabilityRow(id: rows.count, date: date, languages: languages.joined(separator: ", "), flags: flags.joined(separator: "  ")))
        }
        out.availability = rows.sorted { $0.date > $1.date }
    }

    /// Features subscribed to model assets: #1.3.1 of the asset-delivery log streams.
    private func scanSubscribers(_ catalog: CatalogSnapshot, into out: inout AITelemetry) {
        var counts: [String: Int] = [:]
        var last: [String: Date] = [:]
        var records = 0
        for suffix in ["ModelCatalog", "Availability", "UnifiedAssetFramework", "SoftwareUpdateController"] {
            AIStore.forEachPayload(catalog.entry(named: "AppleIntelligence.Reporting.AssetDeliveryLog." + suffix)) { date, raw in
                records += 1
                FastProto.collect(raw, path: [1, 3, 1]) { value in
                    if case .bytes(let b) = value, let s = String(bytes: b, encoding: .utf8), !s.isEmpty {
                        counts[s, default: 0] += 1
                        last[s] = max(last[s] ?? date, date)
                    }
                }
            }
        }
        out.assetLogRecords = records
        out.subscribers = AIStore.top(counts, last: last, limit: 60)
    }

    /// Lighthouse ledger: TaskStatus (#2 task, #3 status), TaskError (#2 task),
    /// TaskCustomEvent (#2 task; sub-task suffixes are folded into their task).
    private func scanLedger(_ catalog: CatalogSnapshot, into out: inout AITelemetry) {
        struct Acc { var events = 0; var completed = 0; var failed = 0; var errors = 0; var last: Date?; var lastStatus = "" }
        var tasks: [String: Acc] = [:]
        var records = 0
        AIStore.forEachPayload(catalog.entry(named: "Lighthouse.Ledger.TaskStatus")) { date, raw in
            records += 1
            guard let task = FastProto.string(raw, [2]) else { return }
            let status = FastProto.string(raw, [3]) ?? ""
            var acc = tasks[task] ?? Acc()
            acc.events += 1
            if status == "Completed" { acc.completed += 1 }
            if status == "Failed" { acc.failed += 1 }
            if acc.last.map({ date >= $0 }) ?? true { acc.last = date; acc.lastStatus = status }
            tasks[task] = acc
        }
        AIStore.forEachPayload(catalog.entry(named: "Lighthouse.Ledger.TaskError")) { _, raw in
            records += 1
            guard let task = FastProto.string(raw, [2]) else { return }
            tasks[task, default: Acc()].errors += 1
        }
        for name in ["Lighthouse.Ledger.TaskCustomEvent", "Lighthouse.Ledger.TaskTelemetry", "Lighthouse.Ledger.DeviceTelemetry"] {
            records += catalog.entry(named: name)?.live ?? 0
        }
        out.ledgerRecords = records
        out.tasks = tasks.map { name, acc in
            AITelemetry.TaskRow(name: name, events: acc.events, completed: acc.completed, failed: acc.failed, errors: acc.errors, last: acc.last, lastStatus: acc.lastStatus)
        }.sorted { $0.events == $1.events ? $0.name < $1.name : $0.events > $1.events }
    }
}
