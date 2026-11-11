import DossierCore
import SwiftUI

/// (3) Zoomable day timeline: foreground app sessions, lock / home screen, display state
/// and media playback, one group of lanes per device.
struct TimelineSectionView: View {
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.deepLink) private var deepLink
    @State private var day: Date?
    @State private var zoom: Double = 1
    @State private var selected: TimelineHit?

    private struct Key: Hashable { let day: Date?; let token: Int }

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = (day, zoom, selected)
        VStack(spacing: 0) {
            HeaderStrip {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: .command).help("Previous day (⌘←)")
                DatePicker("Day", selection: Binding(get: { day ?? Date() }, set: { day = Calendar.current.startOfDay(for: $0); selected = nil }), displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.field).fixedSize()
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: .command).help("Next day (⌘→)")
                Text(day.map { $0.formatted(.dateTime.weekday(.wide)) } ?? "").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...48).frame(width: 150).help("Zoom: from the whole day down to 30 minutes per screen")
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                Text(zoomLabel).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            }
            AsyncContent(reloadKey: Key(day: day, token: refreshToken), emptyTitle: "No Activity on This Day", emptySymbol: "calendar.badge.exclamationmark") {
                try ActivityAccess.requireBiome()
                await ActivityStore.shared.sync(token: refreshToken)
                return await TimelineLoader.load(day: day)
            } content: { model in
                VStack(spacing: 0) {
                    if model.lanes.allSatisfy({ $0.blocks.isEmpty }) {
                        StatePlaceholder(title: "No Activity on This Day", symbol: "calendar.badge.exclamationmark", message: "No device recorded foreground apps or media on \(DossierDate.day(model.day)). Use the arrows to move to another day.")
                    } else {
                        TimelineCanvas(model: model, zoom: zoom, selected: $selected)
                        Divider()
                        TimelineDetailBar(model: model, selected: selected)
                    }
                    StoreFooter(Paths.biomeRestrictedStreams, note: "App.InFocus, Media.NowPlaying · knowledgeC /display/isBacklit")
                }
                .onAppear { if day == nil { day = model.day } }
            }
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            // Payload: "day:<unix seconds>" and / or "zoom:<factor>", separated by ";".
            guard let link = deepLink else { return }
            for part in link.payload.split(separator: ";") {
                if part.hasPrefix("day:"), let t = Double(part.dropFirst(4)) {
                    day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: t))
                } else if part.hasPrefix("zoom:"), let z = Double(part.dropFirst(5)) {
                    zoom = min(48, max(1, z))
                }
            }
        }
    }

    private var zoomLabel: String {
        let hours = 24 / zoom
        return hours >= 1 ? String(format: "%.0f h view", hours) : String(format: "%.0f min view", hours * 60)
    }

    private func step(_ delta: Int) {
        guard let current = day, let next = Calendar.current.date(byAdding: .day, value: delta, to: current) else { return }
        day = next
        selected = nil
    }
}

// MARK: - Model

struct TimelineLane: Identifiable, Sendable {
    enum Kind: Sendable { case apps, media, display }
    let id: String
    let deviceName: String
    let deviceSymbol: String
    let title: String
    let kind: Kind
    let blocks: [TimelineItem]
    let isFirstOfDevice: Bool
}

struct TimelineItem: Identifiable, Sendable, Hashable {
    let id: Int
    let title: String
    let subtitle: String
    let bundle: String
    let start: Date
    let end: Date
    /// 0 app, 1 lock screen, 2 home screen / system surface, 3 media, 4 display on.
    let style: Int
    var duration: Double { end.timeIntervalSince(start) }
}

struct TimelineHit: Hashable, Sendable {
    let lane: String
    let item: TimelineItem
}

struct TimelineModel: Sendable {
    let day: Date
    let dayEnd: Date
    let lanes: [TimelineLane]
    /// Per device: top apps of the day for the legend.
    let legend: [(bundle: String, name: String, seconds: Double)]
    let foreground: Double
}

enum TimelineLoader {
    /// Builds the lanes for `day` (nil = the most recent day on which any device has data).
    static func load(day requested: Date?) async -> TimelineModel {
        let store = ActivityStore.shared
        let devices = await store.devices()
        let calendar = Calendar.current
        var day = requested
        if day == nil {
            var newest: Date?
            for d in devices {
                if let last = await store.focus(d.id).sessions.last.map({ DossierDate.cocoa($0.start) }) { newest = max(newest ?? last, last) }
            }
            day = calendar.startOfDay(for: newest ?? Date())
        }
        let start = day!
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        var lanes: [TimelineLane] = []
        var legend: [String: (name: String, seconds: Double)] = [:]
        var foreground = 0.0
        var nextID = 0
        func clip(_ a: Date, _ b: Date) -> (Date, Date) { (max(a, start), min(b, end)) }

        for device in devices {
            var first = true
            let blocks = await store.blocks(device: device.id, from: start, to: end)
            if !blocks.isEmpty {
                let items = blocks.map { b -> TimelineItem in
                    let (a, e) = clip(b.start, b.end)
                    let style = b.isSystem ? (AppNames.isLockSurface(b.bundle) ? 1 : 2) : 0
                    if style == 0 {
                        legend[b.bundle, default: (b.name, 0)].seconds += e.timeIntervalSince(a)
                        foreground += e.timeIntervalSince(a)
                    }
                    nextID += 1
                    return TimelineItem(id: nextID, title: b.name, subtitle: b.isCapped ? "capped at 4 h" : "", bundle: b.bundle, start: a, end: e, style: style)
                }
                lanes.append(TimelineLane(id: device.id + "|apps", deviceName: device.name, deviceSymbol: device.symbol, title: "Apps", kind: .apps, blocks: items, isFirstOfDevice: first))
                first = false
            }
            if device.isLocal {
                let lights = await store.backlight()
                let lo = start.timeIntervalSinceReferenceDate, hi = end.timeIntervalSinceReferenceDate
                let items = lights.filter { $0.on && $0.end > lo && $0.start < hi }.map { l -> TimelineItem in
                    nextID += 1
                    let (a, e) = clip(DossierDate.cocoa(l.start), DossierDate.cocoa(l.end))
                    return TimelineItem(id: nextID, title: "Display on", subtitle: "knowledgeC /display/isBacklit", bundle: "", start: a, end: e, style: 4)
                }
                if !items.isEmpty {
                    lanes.append(TimelineLane(id: device.id + "|display", deviceName: device.name, deviceSymbol: device.symbol, title: "Display", kind: .display, blocks: items, isFirstOfDevice: first))
                    first = false
                }
            }
            let media = await store.mediaIntervals(device: device.id, from: start, to: end)
            if !media.isEmpty {
                let items = media.map { m -> TimelineItem in
                    nextID += 1
                    let (a, e) = clip(m.start, m.end)
                    return TimelineItem(id: nextID, title: m.title.isEmpty ? AppNames.name(m.bundle) : m.title, subtitle: [m.artist, AppNames.name(m.bundle)].filter { !$0.isEmpty }.joined(separator: " · "), bundle: m.bundle, start: a, end: e, style: 3)
                }
                lanes.append(TimelineLane(id: device.id + "|media", deviceName: device.name, deviceSymbol: device.symbol, title: "Media", kind: .media, blocks: items, isFirstOfDevice: first))
                first = false
            }
        }
        let top = legend.map { (bundle: $0.key, name: $0.value.name, seconds: $0.value.seconds) }.sorted { $0.seconds > $1.seconds }
        return TimelineModel(day: start, dayEnd: end, lanes: lanes, legend: Array(top.prefix(14)), foreground: foreground)
    }
}

// MARK: - Canvas

struct TimelineCanvas: View {
    let model: TimelineModel
    let zoom: Double
    @Binding var selected: TimelineHit?
    @State private var hover: (hit: TimelineHit, point: CGPoint)?
    @State private var position = ScrollPosition(edge: .leading)
    /// Fraction of the day at the centre of the viewport; kept stable while zooming.
    @State private var centerFraction: Double = 0.5

    private struct ScrollInfo: Equatable { var offset: CGFloat; var width: CGFloat; var visible: CGFloat }
    @Environment(\.privacyMode) private var privacyMode

    private let labelWidth: CGFloat = 168
    private let axisHeight: CGFloat = 24
    private let laneHeight: CGFloat = 34
    private let laneGap: CGFloat = 6
    private let groupGap: CGFloat = 14

    private func laneTops() -> [CGFloat] {
        var y = axisHeight + 6
        var tops: [CGFloat] = []
        for (i, lane) in model.lanes.enumerated() {
            if lane.isFirstOfDevice && i > 0 { y += groupGap }
            tops.append(y)
            y += laneHeight + laneGap
        }
        return tops
    }

    private var contentHeight: CGFloat {
        (laneTops().last ?? axisHeight) + laneHeight + 12
    }

    var body: some View {
        GeometryReader { geo in
            let tops = laneTops()
            let trackWidth = max(200, (geo.size.width - labelWidth) * zoom)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    labels(tops).frame(width: labelWidth, height: contentHeight, alignment: .topLeading)
                    ScrollView(.horizontal) {
                        canvas(tops: tops, width: trackWidth)
                            .frame(width: trackWidth, height: contentHeight)
                    }
                    .scrollIndicators(.visible)
                    .scrollPosition($position)
                    .onScrollGeometryChange(for: ScrollInfo.self) { g in
                        ScrollInfo(offset: g.contentOffset.x, width: g.contentSize.width, visible: g.containerSize.width)
                    } action: { old, new in
                        if abs(new.width - old.width) > 0.5 {
                            // Zoomed (or resized): keep the same moment in the middle.
                            let target = centerFraction * new.width - new.visible / 2
                            position.scrollTo(x: max(0, min(new.width - new.visible, target)))
                        } else if new.width > new.visible + 1 {
                            centerFraction = Double((new.offset + new.visible / 2) / max(new.width, 1))
                        }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .task(id: model.day) {
                // New day (or first appearance) while zoomed in: centre on that day's activity.
                let fraction = activityCenter()
                centerFraction = fraction
                let visible = geo.size.width - labelWidth
                if zoom > 1.01, visible > 0 {
                    position.scrollTo(x: max(0, min(trackWidth - visible, fraction * trackWidth - visible / 2)))
                }
            }
        }
    }

    /// Middle of the day's app activity (first zoom-in lands on activity, not on noon).
    private func activityCenter() -> Double {
        let apps = model.lanes.filter { $0.kind == .apps }.flatMap { $0.blocks }.filter { $0.style == 0 }
        guard let first = apps.map(\.start).min(), let last = apps.map(\.end).max() else { return 0.5 }
        let total = model.dayEnd.timeIntervalSince(model.day)
        return (first.timeIntervalSince(model.day) + last.timeIntervalSince(model.day)) / 2 / max(total, 1)
    }

    private func labels(_ tops: [CGFloat]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.lanes.enumerated()), id: \.element.id) { i, lane in
                VStack(alignment: .leading, spacing: 1) {
                    if lane.isFirstOfDevice {
                        Label(lane.deviceName, systemImage: lane.deviceSymbol)
                            .font(.caption.weight(.semibold)).lineLimit(1)
                            .sensitive(.personal)
                    }
                    Text(lane.title).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(width: labelWidth - 20, height: laneHeight, alignment: .leading)
                .offset(x: 12, y: tops[i])
            }
        }
    }

    private func x(_ date: Date, width: CGFloat) -> CGFloat {
        let total = model.dayEnd.timeIntervalSince(model.day)
        return CGFloat(date.timeIntervalSince(model.day) / total) * width
    }

    private func color(_ item: TimelineItem) -> Color {
        switch item.style {
        case 1: return Color.gray.opacity(0.35)
        case 2: return Color.gray.opacity(0.22)
        case 3: return .pink
        case 4: return .yellow.opacity(0.7)
        default: return AppColor.color(item.bundle)
        }
    }

    private func canvas(tops: [CGFloat], width: CGFloat) -> some View {
        Canvas { context, size in
            // Hour grid; label density follows the zoom.
            let hours = Int((model.dayEnd.timeIntervalSince(model.day) / 3600).rounded())
            let pxPerHour = size.width / CGFloat(max(hours, 1))
            let labelEvery = pxPerHour >= 46 ? 1 : (pxPerHour >= 23 ? 2 : (pxPerHour >= 15 ? 3 : 6))
            for h in 0...hours {
                let xx = CGFloat(h) * pxPerHour
                var line = Path()
                line.move(to: CGPoint(x: xx, y: axisHeight - 4)); line.addLine(to: CGPoint(x: xx, y: size.height))
                context.stroke(line, with: .color(.primary.opacity(h % 6 == 0 ? 0.16 : 0.07)), lineWidth: 0.5)
                if h < hours, h % labelEvery == 0 {
                    context.draw(Text(String(format: "%02d:00", h % 24)).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: xx + 3, y: 9), anchor: .leading)
                }
                if pxPerHour >= 240, h < hours {
                    for q in 1..<4 {
                        let qx = xx + pxPerHour * CGFloat(q) / 4
                        var tick = Path()
                        tick.move(to: CGPoint(x: qx, y: axisHeight - 2)); tick.addLine(to: CGPoint(x: qx, y: size.height))
                        context.stroke(tick, with: .color(.primary.opacity(0.04)), lineWidth: 0.5)
                        context.draw(Text(String(format: "%02d:%02d", h % 24, q * 15)).font(.system(size: 9)).foregroundStyle(.tertiary), at: CGPoint(x: qx + 3, y: 9), anchor: .leading)
                    }
                }
            }
            for (i, lane) in model.lanes.enumerated() {
                let top = tops[i]
                let track = CGRect(x: 0, y: top, width: size.width, height: laneHeight)
                context.fill(Path(roundedRect: track, cornerRadius: 4), with: .color(.primary.opacity(0.035)))
                for item in lane.blocks {
                    let x0 = x(item.start, width: size.width)
                    let x1 = x(item.end, width: size.width)
                    let inset: CGFloat = item.style == 0 || item.style == 3 ? 3 : 9
                    let rect = CGRect(x: x0, y: top + inset, width: max(x1 - x0, 0.75), height: laneHeight - inset * 2)
                    let isSelected = selected?.item.id == item.id
                    context.fill(Path(roundedRect: rect, cornerRadius: min(3, rect.width / 2)), with: .color(color(item).opacity(isSelected ? 1 : 0.85)))
                    if isSelected {
                        context.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4), with: .color(.primary), lineWidth: 1.5)
                    }
                    if rect.width > 46, item.style == 0 || item.style == 3, !privacyMode {
                        let text = context.resolve(Text(item.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white))
                        var clipped = context
                        clipped.clip(to: Path(rect.insetBy(dx: 3, dy: 0)))
                        clipped.draw(text, at: CGPoint(x: rect.minX + 5, y: rect.midY), anchor: .leading)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                if let hit = hitTest(p, tops: tops, width: width) { hover = (hit, p) } else { hover = nil }
            case .ended:
                hover = nil
            }
        }
        .onTapGesture(coordinateSpace: .local) { p in
            selected = hitTest(p, tops: tops, width: width)
        }
        .overlay(alignment: .topLeading) {
            if let hover {
                tooltip(hover.hit.item)
                    .offset(x: min(max(hover.point.x + 12, 0), max(0, width - 260)), y: hover.point.y + 14)
                    .allowsHitTesting(false)
            }
        }
    }

    private func hitTest(_ p: CGPoint, tops: [CGFloat], width: CGFloat) -> TimelineHit? {
        guard let laneIndex = tops.firstIndex(where: { p.y >= $0 && p.y <= $0 + laneHeight }) else { return nil }
        let lane = model.lanes[laneIndex]
        var best: TimelineItem?
        var bestDistance = CGFloat.infinity
        for item in lane.blocks {
            let x0 = x(item.start, width: width), x1 = max(x(item.end, width: width), x0 + 0.75)
            if p.x >= x0 - 2 && p.x <= x1 + 2 {
                let d = p.x < x0 ? x0 - p.x : (p.x > x1 ? p.x - x1 : 0)
                // Prefer the narrowest block under the pointer (short sessions are hard to hit).
                let score = d * 1000 + (x1 - x0)
                if score < bestDistance { bestDistance = score; best = item }
            }
        }
        return best.map { TimelineHit(lane: lane.id, item: $0) }
    }

    private func tooltip(_ item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.caption.weight(.semibold)).lineLimit(2).sensitive(item.style == 3 ? .sensitive : .personal)
            if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).sensitive(.personal) }
            Text("\(item.start.formatted(date: .omitted, time: .standard)) – \(item.end.formatted(date: .omitted, time: .standard)) · \(Format.usage(item.duration))")
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

/// Legend (top apps of the day) and the selected block's details.
struct TimelineDetailBar: View {
    let model: TimelineModel
    let selected: TimelineHit?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item = selected?.item {
                HStack(spacing: 8) {
                    if !item.bundle.isEmpty { AppIcon(bundle: item.bundle, size: 22) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(detail(item)).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                    .sensitive(item.style == 3 ? .sensitive : .personal)
                    Spacer()
                }
            } else {
                Text("\(Format.usage(model.foreground)) of foreground app time across all devices on \(DossierDate.day(model.day)). Hover a block for details, click to pin it, drag the slider to zoom.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Wraps onto further lines: a legend cut off at the window edge hides entries.
            FlowLayout(spacing: 12, lineSpacing: 5) {
                Group {
                    ForEach(model.legend, id: \.bundle) { entry in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(AppColor.color(entry.bundle)).frame(width: 10, height: 10)
                            Text(entry.name).font(.caption).lineLimit(1)
                            Text(Format.usage(entry.seconds)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    legendSwatch("Lock screen", Color.gray.opacity(0.4))
                    legendSwatch("Home screen", Color.gray.opacity(0.22))
                    legendSwatch("Display on", .yellow.opacity(0.7))
                    legendSwatch("Media playing", .pink)
                }
                .fixedSize()
                .sensitive(.personal)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func legendSwatch(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func detail(_ item: TimelineItem) -> String {
        var parts = ["\(item.start.formatted(date: .omitted, time: .standard)) – \(item.end.formatted(date: .omitted, time: .standard))", Format.usage(item.duration)]
        if !item.subtitle.isEmpty { parts.append(item.subtitle) }
        if !item.bundle.isEmpty { parts.append(item.bundle) }
        return parts.joined(separator: " · ")
    }
}
