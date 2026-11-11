import Foundation
import DossierCore

/// One row of the unified timeline.
struct TimelineRow: Identifiable, Sendable {
    enum Origin: Sendable, Hashable {
        case record(RecordRef)
        case knowledge(Int64)
    }
    let id: String
    let date: Date
    let source: String
    let family: String
    let device: String
    let summary: String
    let sensitivity: Sensitivity
    let origin: Origin
}

/// What the timeline merges.
struct TimelineSelection: Hashable, Sendable {
    /// Catalogue entry ids.
    var streams: Set<String>
    /// Device keys ("local" or a remote identifier); nil = all devices.
    var devices: Set<String>?
    /// Only events at or before this instant (nil = now).
    var before: Date?
    var includeKnowledge: Bool
    var search: String
    var refresh: Int
}

/// Lazily merges many SEGB streams (and optionally knowledgeC) by timestamp, newest first.
///
/// Each (stream, device) pair is a cursor over its segments from the newest backwards;
/// only one segment per cursor is mapped at a time and segments created after the
/// requested instant are skipped without being opened (segment file names are their
/// creation time). A binary max-heap of cursor heads yields the global order, so a page
/// costs O(rows · log k) and memory stays proportional to the number of cursors.
///
/// Actor re-entrancy: `page` suspends while knowledgeC is queried, and the table issues a
/// new request as soon as the selection changes (deep link, filter toggle, typing), so
/// calls overlap. All merge progress therefore lives in one `MergeState` object per
/// selection; a call only ever touches the state it started with and gives up
/// (`CancellationError`) when, after a suspension, another call has taken over.
actor TimelineSource {
    private final class SegmentCursor {
        let entry: CatalogEntry
        let device: BiomeDevice
        let label: String
        var remaining: [BiomeSegment]          // oldest first; consumed from the end
        var file: SEGBFile?
        var segment: BiomeSegment?
        var order: [Int32] = []                // entry indexes, ascending by time
        var position = -1
        let before: Double

        init(entry: CatalogEntry, device: BiomeDevice, label: String, before: Double) {
            self.entry = entry; self.device = device; self.label = label; self.before = before
            remaining = entry.stream.dataSegments(device: device)
            loadNextSegment()
        }

        var head: Double? {
            guard let file, position >= 0 else { return nil }
            return file.entries[Int(order[position])].timestamp.timeIntervalSinceReferenceDate
        }

        func advance() {
            position -= 1
            if position < 0 { loadNextSegment() }
        }

        private func loadNextSegment() {
            file = nil; segment = nil; order = []; position = -1
            while let next = remaining.popLast() {
                // File names are creation times in Cocoa microseconds.
                if let micros = Double(next.url.lastPathComponent), micros / 1_000_000 > before { continue }
                guard let f = try? SEGBFile(url: next.url) else { continue }
                var live: [Int32] = []
                live.reserveCapacity(f.entries.count)
                for e in f.entries where e.state.isLive && e.timestamp.timeIntervalSinceReferenceDate <= before {
                    live.append(Int32(e.index))
                }
                guard !live.isEmpty else { continue }
                live.sort { f.entries[Int($0)].timestamp < f.entries[Int($1)].timestamp }
                file = f; segment = next; order = live; position = live.count - 1
                return
            }
        }
    }

    private struct HeapItem { let time: Double; let cursor: Int }

    /// The merge progress of one selection. Only touched from inside the actor.
    private final class MergeState {
        let selection: TimelineSelection
        var cursors: [SegmentCursor] = []
        var heap: [HeapItem] = []
        var produced = 0
        var knowledgeBuffer: [KnowledgeEvent] = []
        var knowledgeOffset = 0
        var knowledgeDone = true
        /// Incremented by every `page` call that adopts this state; a call that finds a
        /// different value after a suspension has been superseded.
        var epoch = 0

        /// Opens one cursor per (stream, device). Synchronous: no other call can observe a
        /// half-built state. Throws when the calling task was cancelled meanwhile.
        init(_ selection: TimelineSelection, catalog: CatalogSnapshot) throws {
            self.selection = selection
            let before = (selection.before ?? Date.distantFuture).timeIntervalSinceReferenceDate
            for entry in catalog.entries where selection.streams.contains(entry.id) && entry.live > 0 {
                for stats in entry.devices where stats.live > 0 {
                    let deviceKey = stats.device.identifier ?? "local"
                    if let devices = selection.devices, !devices.contains(deviceKey) { continue }
                    if let first = stats.first, first.timeIntervalSinceReferenceDate > before { continue }
                    try Task.checkCancellation()
                    let cursor = SegmentCursor(entry: entry, device: stats.device, label: catalog.namer.label(stats.device), before: before)
                    if let head = cursor.head {
                        cursors.append(cursor)
                        push(HeapItem(time: head, cursor: cursors.count - 1))
                    }
                }
            }
            knowledgeDone = !(selection.includeKnowledge && (selection.devices?.contains("local") ?? true))
        }

        var cursorCount: Int { cursors.count + (selection.includeKnowledge && (selection.devices?.contains("local") ?? true) ? 1 : 0) }

        // Heap (max by time)

        func push(_ item: HeapItem) {
            heap.append(item)
            var i = heap.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                if heap[parent].time >= heap[i].time { break }
                heap.swapAt(parent, i)
                i = parent
            }
        }

        func pop() -> HeapItem? {
            guard let top = heap.first else { return nil }
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < heap.count, heap[l].time > heap[m].time { m = l }
                    if r < heap.count, heap[r].time > heap[m].time { m = r }
                    if m == i { break }
                    heap.swapAt(m, i)
                    i = m
                }
            }
            return top
        }
    }

    private var current: MergeState?

    /// Number of (stream, device) cursors of the current selection — shown in the footer.
    func cursorCount() -> Int { current?.cursorCount ?? 0 }

    /// Fetches the next knowledgeC batch into `state`. `state` is modified only when the
    /// calling request (`epoch`) still owns it after the query returned.
    private func refillKnowledge(_ state: MergeState, epoch: Int) async throws {
        let batchSize = 400
        var batch: [KnowledgeEvent] = []
        var failed = false
        do {
            batch = try await KnowledgeStore.events(stream: nil, search: "", sort: nil, offset: state.knowledgeOffset, limit: batchSize,
                                                    before: state.selection.before ?? Date.distantFuture)
        } catch {
            // A cancelled query must not be mistaken for "knowledgeC has no more events".
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            failed = true            // store missing / unreadable: the merge goes on without it
        }
        try Task.checkCancellation()
        guard current === state, state.epoch == epoch else { throw CancellationError() }
        state.knowledgeOffset += batch.count
        state.knowledgeBuffer = batch.filter { $0.start != nil }
        if failed || batch.count < batchSize { state.knowledgeDone = true }
    }

    // MARK: Paging

    func page(_ selection: TimelineSelection, catalog: CatalogSnapshot, offset: Int, limit: Int) async throws -> [TimelineRow] {
        let state: MergeState
        if let existing = current, existing.selection == selection, offset >= existing.produced {
            state = existing
        } else {
            state = try MergeState(selection, catalog: catalog)
            current = state
        }
        state.epoch += 1
        let epoch = state.epoch

        // Skip forward if the table asks for a later page than the merge has reached.
        var toSkip = offset - state.produced
        let needle = ByteNeedle(selection.search)
        var rows: [TimelineRow] = []
        rows.reserveCapacity(limit)
        var examined = 0

        while rows.count < limit {
            examined += 1
            if examined % 512 == 0 { try Task.checkCancellation() }
            if state.knowledgeBuffer.isEmpty, !state.knowledgeDone {
                // Suspension point: other `page` calls may run. `refillKnowledge` throws
                // if one of them took over, so nothing below touches a foreign merge.
                try await refillKnowledge(state, epoch: epoch)
            }
            let knowledgeHead = state.knowledgeBuffer.first?.start?.timeIntervalSinceReferenceDate
            let segmentHead = state.heap.first?.time
            guard knowledgeHead != nil || segmentHead != nil else { break }

            if let k = knowledgeHead, k >= (segmentHead ?? -.infinity) {
                let event = state.knowledgeBuffer.removeFirst()
                let summary = KnowledgeStreamRegistry.eventSummary(event)
                if !needle.isEmpty, !needle.matches(Data([summary, event.stream, event.value, event.bundle].joined(separator: " ").utf8)) { continue }
                state.produced += 1
                if toSkip > 0 { toSkip -= 1; continue }
                rows.append(TimelineRow(
                    id: "k\(event.id)", date: event.start ?? .distantPast, source: "knowledgeC " + event.stream, family: "knowledgeC",
                    device: event.device, summary: summary, sensitivity: .personal, origin: .knowledge(event.id)
                ))
                continue
            }

            guard let item = state.pop() else { break }
            let cursor = state.cursors[item.cursor]
            guard let file = cursor.file, let segment = cursor.segment, cursor.position >= 0 else { continue }
            let entry = file.entries[Int(cursor.order[cursor.position])]
            cursor.advance()
            if let head = cursor.head { state.push(HeapItem(time: head, cursor: item.cursor)) }

            let payload = file.payload(entry)
            if !needle.isEmpty, !needle.matches(payload) { continue }
            state.produced += 1
            if toSkip > 0 { toSkip -= 1; continue }
            let info = cursor.entry.info
            rows.append(TimelineRow(
                id: "\(cursor.entry.id)|\(segment.device.identifier ?? "local")/\(segment.url.lastPathComponent)#\(entry.index)",
                date: entry.timestamp, source: cursor.entry.displayName, family: info.family, device: cursor.label,
                summary: RecordDecoder.summary(info.schema, payload: payload), sensitivity: info.sensitivity,
                origin: .record(RecordRef(segmentURL: segment.url, entryIndex: entry.index, streamID: cursor.entry.id))
            ))
        }
        return rows
    }
}
