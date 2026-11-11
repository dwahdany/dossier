import Foundation
import DossierCore

/// In-memory index over the mail message entities of the Cascade mail set.
///
/// The set stores each message as an LZFSE-compressed protobuf with no SQL-visible date,
/// sender or subject, so sorting by message date, counting by year or filtering needs
/// every item decoded once. The index is built in the background in keyset batches on
/// its own read-only connection (so browsing stays responsive), decodes on all cores,
/// reports progress, can be cancelled, and lives in memory only (~90 bytes per message).
actor MailIndex {
    static let shared = MailIndex()

    enum Phase: Sendable, Equatable {
        case idle
        case building
        case ready
        case cancelled
        case failed(String)
    }

    struct Status: Sendable, Equatable {
        var phase: Phase = .idle
        var done = 0
        var total = 0
        var seconds: Double = 0
        var isReady: Bool { phase == .ready }
        var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    }

    struct Sender: Sendable, Hashable {
        let address: String
        let name: String
        let count: Int
    }

    struct Insights: Sendable {
        /// All entities in the set (messages and attachment entities).
        let entities: Int
        let messages: Int
        let attachments: Int
        let years: [(year: Int, count: Int)]
        let topSenders: [Sender]
        let distinctSenders: Int
        let undated: Int
        let range: ClosedRange<Date>?
    }

    private var status = Status()
    private var task: Task<Void, Never>?
    private var token = -1

    // Parallel arrays, one entry per live message.
    private var seqs: [Int64] = []
    private var dates: [Double] = []            // unix seconds, 0 = unknown
    private var attachmentCount = 0
    private var offsets: [UInt32] = [0]         // into `text`
    private var text: [UInt8] = []              // lowercased "subject\nsender name address"
    private var senderCounts: [String: (name: String, count: Int)] = [:]
    private var dateOrder: [Int32] = []         // indices sorted by date, newest first
    private var insightsCache: Insights?

    private var lastQuery: (key: String, matches: [Int32])?

    // MARK: Lifecycle

    func currentStatus() -> Status { status }

    /// Starts a build unless one is running or finished.
    func start() {
        guard task == nil else { return }
        switch status.phase {
        case .ready, .building: return
        default: break
        }
        status = Status(phase: .building)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.build()
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Drops the index when the app-wide refresh token changes.
    func sync(token: Int) {
        guard token != self.token else { return }
        let first = self.token == -1
        self.token = token
        if !first { reset() }
    }

    private func reset() {
        task?.cancel(); task = nil
        status = Status()
        seqs = []; dates = []; offsets = [0]; text = []; senderCounts = [:]; dateOrder = []
        attachmentCount = 0
        insightsCache = nil; lastQuery = nil
    }

    // MARK: Build

    private struct Entry: Sendable {
        let seq: Int64
        let date: Double
        let text: [UInt8]
        let address: String
        let name: String
        var isAttachment = false
    }

    private func build() async {
        let started = Date()
        defer { task = nil }
        guard let set = await CascadeLinks.shared.set(kind: .mail) else {
            status.phase = .failed("The Mail message set does not exist on this Mac.")
            return
        }
        do {
            _ = try await CascadeStore.open(set)                       // schema probe + access check
            let db = try SQLiteDB(path: set.url.path)                  // dedicated read-only connection
            status.total = await db.count("SELECT count(*) FROM metacontent_provenance p WHERE \(CascadeStore.liveFilter)") ?? 0
            seqs.reserveCapacity(status.total); dates.reserveCapacity(status.total); offsets.reserveCapacity(status.total + 1)
            var cursor: Int64 = -1
            let batch = 4_000
            while true {
                try Task.checkCancellation()
                let rows = try await db.rows(
                    """
                    SELECT p.sequence_number, c.content FROM metacontent_provenance p
                    JOIN content c ON c.content_hash = p.content_hash
                    WHERE \(CascadeStore.liveFilter) AND p.sequence_number > ? ORDER BY p.sequence_number LIMIT ?
                    """, [.integer(cursor), .integer(Int64(batch))], maxRows: batch
                )
                guard let last = rows.last else { break }
                cursor = last[0].int ?? Int64.max
                let entries = await Self.decode(rows)
                for e in entries {
                    seqs.append(e.seq)
                    dates.append(e.date)
                    text.append(contentsOf: e.text)
                    offsets.append(UInt32(truncatingIfNeeded: text.count))
                    if e.isAttachment { attachmentCount += 1; continue }
                    if !e.address.isEmpty {
                        var slot = senderCounts[e.address] ?? (name: e.name, count: 0)
                        slot.count += 1
                        if slot.name.isEmpty { slot.name = e.name }
                        senderCounts[e.address] = slot
                    }
                }
                status.done = seqs.count
                status.seconds = Date().timeIntervalSince(started)
                if rows.count < batch { break }
            }
            let snapshot = dates
            dateOrder = await Self.sortedByDate(snapshot)
            status.done = seqs.count
            status.total = max(status.total, seqs.count)
            status.seconds = Date().timeIntervalSince(started)
            status.phase = .ready
        } catch is CancellationError {
            seqs = []; dates = []; offsets = [0]; text = []; senderCounts = [:]; attachmentCount = 0
            status = Status(phase: .cancelled)
        } catch let error as SQLiteError where error.isAccessProblem {
            status.phase = .failed("No access to the Mail message set.")
        } catch {
            status.phase = .failed(error.localizedDescription)
        }
    }

    private static func sortedByDate(_ dates: [Double]) async -> [Int32] {
        var order = Array(Int32(0)..<Int32(dates.count))
        order.sort { dates[Int($0)] > dates[Int($1)] }
        return order
    }

    /// Extracts entity type (1), title (2.1), created date (5.7.2), author address (5.10.6) and author
    /// name (5.10.7) without materializing the message.
    private static func decode(_ rows: [SQLRow]) async -> [Entry] {
        msConcurrentMap(rows.count) { index -> Entry in
            let row = rows[index]
            let seq = row[0].int ?? 0
            guard let raw = row[1].data else { return Entry(seq: seq, date: 0, text: [], address: "", name: "") }
            let data = CascadeBlob.decode(raw)
            var title = "", address = "", name = ""
            var date = 0.0
            var isAttachment = false
            let attachmentType = Array("MailAttachmentEntity".utf8)
            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var top = PBWalker(base, 0..<buffer.count)
                while let field = top.next() {
                    guard field.wire == 2 else { continue }
                    let range = field.start..<(field.start + field.length)
                    if field.number == 1 {
                        isAttachment = field.length == attachmentType.count && memcmp(base + field.start, attachmentType, attachmentType.count) == 0
                    } else if field.number == 2 {
                        if let t = PBWalker.find(base, range, 1) { title = PBWalker.string(base, t) }
                    } else if field.number == 5 {
                        var attrs = PBWalker(base, range)
                        while let group = attrs.next() {
                            guard group.wire == 2 else { continue }
                            let groupRange = group.start..<(group.start + group.length)
                            if group.number == 7 {
                                var g = PBWalker(base, groupRange)
                                while let f = g.next() {
                                    if f.number == 2, f.wire == 1 { date = Double(bitPattern: f.scalar); break }
                                }
                            } else if group.number == 10 {
                                var g = PBWalker(base, groupRange)
                                while let f = g.next() {
                                    guard f.wire == 2 else { continue }
                                    if f.number == 6, address.isEmpty { address = PBWalker.string(base, f.start..<(f.start + f.length)) }
                                    if f.number == 7, name.isEmpty { name = PBWalker.string(base, f.start..<(f.start + f.length)) }
                                }
                            } else if group.number == 2, title.isEmpty {
                                if let t = PBWalker.find(base, groupRange, 13) { title = PBWalker.string(base, t) }
                            }
                        }
                    }
                }
            }
            if !(date.isFinite && date > 0 && date < 4_102_444_800) { date = 0 }
            let lowered = (title + "\n" + name + " " + address).lowercased()
            return Entry(seq: seq, date: date, text: Array(lowered.utf8), address: address.lowercased(), name: name, isAttachment: isAttachment)
        }
    }

    // MARK: Queries

    struct Page: Sendable {
        let seqs: [Int64]
        let total: Int
    }

    /// Message sequence numbers matching `search` (substring of subject / sender,
    /// case-insensitive) and `year`, ordered by message date.
    func page(search: String, year: Int?, ascending: Bool, offset: Int, limit: Int) -> Page? {
        guard status.isReady else { return nil }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let key = needle + "\u{1}" + (year.map(String.init) ?? "")
        let matches: [Int32]
        if let cached = lastQuery, cached.key == key {
            matches = cached.matches
        } else {
            matches = computeMatches(needle: needle, year: year)
            lastQuery = (key, matches)
        }
        let total = matches.count
        guard offset < total else { return Page(seqs: [], total: total) }
        let upper = min(total, offset + limit)
        var out: [Int64] = []
        out.reserveCapacity(upper - offset)
        for i in offset..<upper {
            let index = ascending ? matches[total - 1 - i] : matches[i]
            out.append(seqs[Int(index)])
        }
        return Page(seqs: out, total: total)
    }

    private func computeMatches(needle: String, year: Int?) -> [Int32] {
        var yearRange: ClosedRange<Double>?
        if let year {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            if let lo = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
               let hi = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) {
                yearRange = lo.timeIntervalSince1970...(hi.timeIntervalSince1970 - 0.001)
            }
        }
        if needle.isEmpty, yearRange == nil { return dateOrder }
        let needleBytes = Array(needle.utf8)
        var out: [Int32] = []
        text.withUnsafeBufferPointer { haystack in
            guard let base = haystack.baseAddress else { return }
            needleBytes.withUnsafeBufferPointer { n in
                for index in dateOrder {
                    let i = Int(index)
                    if let yearRange, !yearRange.contains(dates[i]) { continue }
                    if !needleBytes.isEmpty {
                        let start = Int(offsets[i]), length = Int(offsets[i + 1]) - start
                        if length < needleBytes.count || memmem(base + start, length, n.baseAddress, needleBytes.count) == nil { continue }
                    }
                    out.append(index)
                }
            }
        }
        return out
    }

    func insights() -> Insights? {
        guard status.isReady else { return nil }
        if let insightsCache { return insightsCache }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var years: [Int: Int] = [:]
        var undated = 0
        var lo = Double.greatestFiniteMagnitude, hi = 0.0
        // Year boundaries are computed once per year instead of running Calendar per message.
        var bounds: [(year: Int, start: Double, end: Double)] = []
        func bucket(_ t: Double) -> Int {
            if let hit = bounds.first(where: { t >= $0.start && t < $0.end }) { return hit.year }
            let year = calendar.component(.year, from: Date(timeIntervalSince1970: t))
            let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))?.timeIntervalSince1970 ?? t
            let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))?.timeIntervalSince1970 ?? t + 1
            bounds.append((year, start, end))
            return year
        }
        for t in dates {
            if t <= 0 { undated += 1; continue }
            years[bucket(t), default: 0] += 1
            lo = min(lo, t); hi = max(hi, t)
        }
        let top = senderCounts.sorted { $0.value.count > $1.value.count }.prefix(40).map {
            Sender(address: $0.key, name: $0.value.name, count: $0.value.count)
        }
        let result = Insights(
            entities: seqs.count, messages: seqs.count - attachmentCount, attachments: attachmentCount,
            years: years.sorted { $0.key < $1.key }.map { (year: $0.key, count: $0.value) },
            topSenders: Array(top),
            distinctSenders: senderCounts.count,
            undated: undated,
            range: hi > 0 ? Date(timeIntervalSince1970: lo)...Date(timeIntervalSince1970: hi) : nil
        )
        insightsCache = result
        return result
    }

    /// Approximate heap use of the index, for the self-test.
    func memoryBytes() -> Int {
        seqs.count * 8 + dates.count * 8 + offsets.count * 4 + text.count + dateOrder.count * 4 + senderCounts.count * 64
    }
}
