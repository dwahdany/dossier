import SwiftUI
import Charts

/// One labelled value for ``BarChartView``.
public struct ChartBar: Identifiable, Sendable, Hashable {
    public var id: String { label }
    public var label: String
    public var value: Double
    public init(_ label: String, _ value: Double) { self.label = label; self.value = value }
}

/// One time-series point for ``LineChartView``.
public struct ChartPoint: Identifiable, Sendable, Hashable {
    public var id: String { "\(series)|\(date.timeIntervalSinceReferenceDate)" }
    public var date: Date
    public var value: Double
    /// Series name; points of different series get different colours and a legend.
    public var series: String
    public init(_ date: Date, _ value: Double, series: String = "") { self.date = date; self.value = value; self.series = series }
}

/// Horizontal (default) or vertical ranked bar chart over Swift Charts.
///
/// ```swift
/// BarChartView(topApps.map { ChartBar($0.name, Double($0.seconds)) }, valueLabel: Format.duration)
/// ```
public struct BarChartView: View {
    private let bars: [ChartBar]
    private let horizontal: Bool
    private let tint: Color
    private let sensitivity: Sensitivity
    private let valueLabel: (Double) -> String

    public init(
        _ bars: [ChartBar], horizontal: Bool = true, tint: Color = .accentColor,
        labelSensitivity: Sensitivity = .low,
        valueLabel: @escaping (Double) -> String = { Format.count(Int($0)) }
    ) {
        self.bars = bars; self.horizontal = horizontal; self.tint = tint
        self.sensitivity = labelSensitivity; self.valueLabel = valueLabel
    }

    public var body: some View {
        if bars.isEmpty {
            ChartEmpty()
        } else if horizontal {
            Chart(bars) { bar in
                BarMark(x: .value("Value", bar.value), y: .value("Label", bar.label))
                    .foregroundStyle(tint.gradient)
                    .cornerRadius(3)
                    .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                        Text(valueLabel(bar.value)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
            }
            .chartYScale(domain: bars.map(\.label))
            .chartXAxis { AxisMarks(position: .bottom) { _ in AxisGridLine().foregroundStyle(.quaternary) } }
            .chartYAxis {
                AxisMarks(preset: .aligned, position: .leading) { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label).font(.caption).lineLimit(1).frame(maxWidth: 190, alignment: .trailing).sensitive(sensitivity)
                        }
                    }
                }
            }
            .frame(height: CGFloat(bars.count) * 24 + 12)
        } else {
            Chart(bars) { bar in
                BarMark(x: .value("Label", bar.label), y: .value("Value", bar.value))
                    .foregroundStyle(tint.gradient)
                    .cornerRadius(2)
            }
            .chartXScale(domain: bars.map(\.label))
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let v = value.as(Double.self) { Text(valueLabel(v)).font(.caption2) } }
                }
            }
            .frame(minHeight: 160)
        }
    }
}

/// Time-series chart (line, area or bars per bucket) over Swift Charts.
///
/// ```swift
/// LineChartView(daily.map { ChartPoint($0.day, Double($0.count)) }, style: .bars, unit: .day)
/// ```
public struct LineChartView: View {
    public enum Style: Sendable { case line, area, bars }

    private let points: [ChartPoint]
    private let style: Style
    private let unit: Calendar.Component
    private let tint: Color
    private let valueLabel: (Double) -> String

    public init(
        _ points: [ChartPoint], style: Style = .line, unit: Calendar.Component = .day, tint: Color = .accentColor,
        valueLabel: @escaping (Double) -> String = { Format.compact(Int($0)) }
    ) {
        self.points = points; self.style = style; self.unit = unit; self.tint = tint; self.valueLabel = valueLabel
    }

    private var multiSeries: Bool { Set(points.map(\.series)).count > 1 }

    public var body: some View {
        if points.isEmpty {
            ChartEmpty()
        } else {
            Chart(points) { point in
                switch style {
                case .line:
                    LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Series", point.series))
                case .area:
                    AreaMark(x: .value("Date", point.date), y: .value("Value", point.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Series", point.series))
                        .opacity(0.35)
                    LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Series", point.series))
                case .bars:
                    BarMark(x: .value("Date", point.date, unit: unit), y: .value("Value", point.value))
                        .foregroundStyle(by: .value("Series", point.series))
                }
            }
            .chartForegroundStyleScale(range: multiSeries ? ChartPalette.colors : [tint])
            .chartLegend(multiSeries ? .visible : .hidden)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let v = value.as(Double.self) { Text(valueLabel(v)).font(.caption2) } }
                }
            }
            .frame(minHeight: 160)
        }
    }
}

/// Categorical palette shared by multi-series charts.
public enum ChartPalette {
    public static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .yellow, .indigo, .brown, .mint]
    public static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }
}

private struct ChartEmpty: View {
    var body: some View {
        Text("No data")
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 80)
    }
}

// MARK: - Heatmap

/// Row-labelled grid of intensities with 24 hour-of-day columns.
public struct HeatmapData: Sendable {
    public var rowLabels: [String]
    /// `values[row][hour]`, 24 entries per row.
    public var values: [[Double]]

    public init(rowLabels: [String], values: [[Double]]) { self.rowLabels = rowLabels; self.values = values }

    public var maxValue: Double { values.flatMap { $0 }.max() ?? 0 }
    public var total: Double { values.flatMap { $0 }.reduce(0, +) }

    /// Weekday (Mon…Sun, locale-aware first weekday) × hour-of-day histogram of dates.
    public static func weekdayByHour(_ dates: some Sequence<Date>, calendar: Calendar = .current) -> HeatmapData {
        var grid = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        for date in dates {
            let c = calendar.dateComponents([.weekday, .hour], from: date)
            guard let weekday = c.weekday, let hour = c.hour else { continue }
            let row = (weekday - calendar.firstWeekday + 7) % 7
            grid[row][hour] += 1
        }
        let symbols = calendar.shortWeekdaySymbols
        let labels = (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
        return HeatmapData(rowLabels: labels, values: grid)
    }

    /// Same as ``weekdayByHour(_:calendar:)`` but from pre-aggregated
    /// `(weekday 1...7 as in Calendar, hour 0...23, weight)` triples (e.g. a SQL GROUP BY).
    public static func weekdayByHour(bins: some Sequence<(weekday: Int, hour: Int, weight: Double)>, calendar: Calendar = .current) -> HeatmapData {
        var grid = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        for bin in bins where (1...7).contains(bin.weekday) && (0..<24).contains(bin.hour) {
            grid[(bin.weekday - calendar.firstWeekday + 7) % 7][bin.hour] += bin.weight
        }
        let symbols = calendar.shortWeekdaySymbols
        let labels = (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
        return HeatmapData(rowLabels: labels, values: grid)
    }

    /// One row per calendar day (most recent `days` days that contain data) × hour.
    public static func dayByHour(_ dates: some Sequence<Date>, days: Int = 28, calendar: Calendar = .current) -> HeatmapData {
        var byDay: [Date: [Double]] = [:]
        for date in dates {
            let day = calendar.startOfDay(for: date)
            let hour = calendar.component(.hour, from: date)
            byDay[day, default: Array(repeating: 0, count: 24)][hour] += 1
        }
        let keys = byDay.keys.sorted().suffix(days)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return HeatmapData(rowLabels: keys.map(formatter.string(from:)), values: keys.map { byDay[$0]! })
    }
}

/// Hour-of-day × day heatmap ("when does this happen").
///
/// ```swift
/// TimelineHeatmap(.weekdayByHour(events.map(\.date)), tint: .blue) { Format.count(Int($0)) }
/// ```
public struct TimelineHeatmap: View {
    private let data: HeatmapData
    private let tint: Color
    private let valueLabel: (Double) -> String
    @State private var hovered: (row: Int, hour: Int)?

    public init(_ data: HeatmapData, tint: Color = .accentColor, valueLabel: @escaping (Double) -> String = { Format.count(Int($0)) }) {
        self.data = data; self.tint = tint; self.valueLabel = valueLabel
    }

    private let cell: CGFloat = 16
    private let gap: CGFloat = 2

    public var body: some View {
        let maxValue = max(data.maxValue, 1)
        VStack(alignment: .leading, spacing: gap) {
            ForEach(Array(data.rowLabels.enumerated()), id: \.offset) { rowIndex, label in
                HStack(spacing: gap) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                        .padding(.trailing, 4)
                    ForEach(0..<24, id: \.self) { hour in
                        let value = rowIndex < data.values.count && hour < data.values[rowIndex].count ? data.values[rowIndex][hour] : 0
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(value <= 0 ? Color.primary.opacity(0.06) : tint.opacity(0.18 + 0.82 * (value / maxValue).squareRoot()))
                            .frame(minWidth: 8, maxWidth: 26)
                            .frame(height: cell)
                            .onHover { inside in
                                if inside { hovered = (rowIndex, hour) } else if hovered?.row == rowIndex, hovered?.hour == hour { hovered = nil }
                            }
                            .help("\(label) \(String(format: "%02d:00", hour)) — \(valueLabel(value))")
                    }
                }
            }
            HStack(spacing: gap) {
                Color.clear.frame(width: 68, height: 1)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 3 == 0 ? String(format: "%02d", hour) : "")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 8, maxWidth: 26)
                }
            }
            HStack(spacing: 6) {
                Color.clear.frame(width: 68, height: 1)
                if let hovered, hovered.row < data.values.count {
                    Text("\(data.rowLabels[hovered.row]) \(String(format: "%02d:00", hovered.hour)) · \(valueLabel(data.values[hovered.row][hovered.hour]))")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Less").font(.caption2).foregroundStyle(.tertiary)
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2).fill(i == 0 ? Color.primary.opacity(0.06) : tint.opacity(0.18 + 0.82 * Double(i) / 4)).frame(width: 10, height: 10)
                    }
                    Text("More · peak \(valueLabel(data.maxValue))").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 14)
            .padding(.top, 2)
        }
    }
}
