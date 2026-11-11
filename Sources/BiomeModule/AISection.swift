import SwiftUI
import Charts
import DossierCore

/// (5) Generative / AI telemetry: what the on-device models were asked to do, model
/// availability, the analytics task ledger and the (often empty) transcript streams.
struct AISection: View {
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.navigate) private var navigate

    var body: some View {
        let token = refreshToken
        AsyncContent(reloadKey: token, emptyTitle: "No AI Telemetry", emptySymbol: "sparkles") {
            let snapshot = try await CatalogueSection.load(token: token).snapshot
            return await AIStore.shared.load(token: token, catalog: snapshot)
        } content: { data in
            page(data)
        }
    }

    private func shorten(_ identifier: String) -> String {
        var s = identifier
        for prefix in ["com.apple.generativefunction.", "com.apple.", "ole.com.apple."] where s.hasPrefix(prefix) { s.removeFirst(prefix.count); break }
        return s
    }

    @ViewBuilder
    private func page(_ data: AITelemetry) -> some View {
        let transparency = data.transcripts.first { $0.name == "GenerativeExperiences.TransparencyLog" }
        let latest = data.availability.first
        ScrollPage {
            StatTileRow([
                Stat("Model Events", Format.compact(data.instrumentationRecords),
                     caption: data.instrumentationRange.map { DossierDate.range($0) } ?? "no instrumentation recorded", symbol: "waveform.path", tint: .pink),
                Stat("Use Cases", "\(data.useCases.count)", caption: "\(Format.compact(data.requests)) attributed events", symbol: "sparkles", tint: .purple),
                Stat("Model Assets", "\(data.models.count)", caption: "referenced by inference events", symbol: "shippingbox", tint: .orange),
                Stat("Errors", Format.compact(data.errors.reduce(0) { $0 + $1.count }), caption: data.errors.first.map { shorten($0.name) } ?? "none recorded", symbol: "exclamationmark.triangle", tint: .red),
                Stat("Analytics Tasks", "\(data.tasks.count)", caption: "\(Format.compact(data.ledgerRecords)) ledger records", symbol: "checklist", tint: .gray),
                Stat("Transparency Log", transparency.map { $0.records > 0 ? Format.compact($0.records) : "Empty" } ?? "Absent",
                     caption: "prompts & responses", symbol: "doc.text.magnifyingglass", tint: .teal),
            ], minTileWidth: 165)

            SectionHeader("On-Device Model Activity",
                          subtitle: "Instrumentation events per \(data.timelineUnit == .hour ? "hour" : "day"), by use case. The stream records that a model ran and for which feature — never the prompt or the output.",
                          symbol: "chart.bar.xaxis")
            if data.timeline.isEmpty {
                StatePlaceholder(title: "No Model Activity Recorded", symbol: "sparkles",
                                 message: "GenerativeModels.GenerativeFunctions.Instrumentation holds no records. Either no on-device generative model has run, or the system has already purged the stream.")
                    .frame(height: 180).card()
            } else {
                LineChartView(data.timeline.map { ChartPoint($0.date, $0.value, series: shorten($0.series)) }, style: .bars, unit: data.timelineUnit)
                    .frame(height: 230)
                    .card()
            }

            if !data.useCases.isEmpty || !data.events.isEmpty {
                // Side by side when each chart gets a readable width, stacked otherwise.
                BalancedGrid(minItemWidth: 400, spacing: Metrics.blockSpacing) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader("Use Cases", subtitle: "Which features invoked a model")
                        BarChartView(data.useCases.prefix(12).map { ChartBar(shorten($0.name), Double($0.count)) }, tint: .purple).card()
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader("Event Types", subtitle: "Pipeline stages that were instrumented")
                        BarChartView(data.events.prefix(12).map { ChartBar(shorten($0.name), Double($0.count)) }, tint: .pink).card()
                    }
                }
                // Side by side when each chart gets a readable width, stacked otherwise.
                BalancedGrid(minItemWidth: 400, spacing: Metrics.blockSpacing) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader("Model Assets", subtitle: "Assets named by inference events")
                        BarChartView(data.models.prefix(10).map { ChartBar(shorten($0.name), Double($0.count)) }, tint: .orange).card()
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader("Providers, Clients & Errors")
                        countList([
                            ("Inference providers", data.providers), ("Client apps", data.clients), ("Errors", data.errors),
                        ])
                    }
                }
            }

            SectionHeader("Apple Intelligence Availability",
                          subtitle: "Each change of the availability state. The flags are shown raw: their meaning is not documented.",
                          symbol: "apple.intelligence")
            if let latest {
                VStack(alignment: .leading, spacing: 10) {
                    KeyValueGrid([
                        KeyValueItem("Latest state", DossierDate.medium(latest.date)),
                        KeyValueItem("Languages", latest.languages.isEmpty ? "—" : latest.languages),
                        KeyValueItem("Flags", latest.flags, monospaced: true),
                        KeyValueItem("History", "\(data.availability.count) state records since \(DossierDate.day(data.availability.last?.date))"),
                    ])
                    if data.availability.count > 1 {
                        Divider()
                        ForEach(data.availability.prefix(8)) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(DossierDate.sortable(row.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(row.languages).font(.caption).frame(width: 60, alignment: .leading)
                                Text(row.flags).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            } else {
                StatePlaceholder(title: "No Availability Records", symbol: "apple.intelligence",
                                 message: "AppleIntelligence.Availability is empty on this Mac.")
                    .frame(height: 140).card()
            }

            if !data.subscribers.isEmpty {
                SectionHeader("Model Catalogue Subscribers",
                              subtitle: "Features that asked the model catalogue for assets (\(Format.count(data.assetLogRecords)) asset-delivery log records)",
                              symbol: "shippingbox")
                BarChartView(data.subscribers.prefix(16).map { ChartBar(shorten($0.name), Double($0.count)) }, tint: .orange).card()
            }

            SectionHeader("Transcripts & Transparency",
                          subtitle: "Streams that would hold the content of assistant sessions. They stay empty until the corresponding feature is used (or enabled in Settings › Privacy › Apple Intelligence Report).",
                          symbol: "text.bubble")
            VStack(spacing: 0) {
                ForEach(Array(data.transcripts.enumerated()), id: \.element.id) { index, stream in
                    if index > 0 { Divider() }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: stream.records > 0 ? "circle.fill" : "circle")
                            .font(.system(size: 7)).foregroundStyle(stream.records > 0 ? Color.green : Color.secondary.opacity(0.6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stream.name).font(.callout)
                            Text(stream.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        if stream.records > 0 {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(Format.count(stream.records)) records").font(.callout).monospacedDigit()
                                Text("last " + DossierDate.short(stream.last)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let navigate {
                                Button("Open") { navigate(DeepLink(sectionID: "biome.stream", payload: stream.name)) }.controlSize(.small)
                            }
                        } else {
                            Text(stream.deleted > 0 ? "empty · \(Format.count(stream.deleted)) deleted" : (stream.bytes > 0 ? "empty" : "never written"))
                                .font(.callout).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 7)
                }
            }
            .card()

            SectionHeader("Analytics Task Ledger",
                          subtitle: "Lighthouse ledger: on-device analytics, learning and upload tasks that ran in the background, by status changes",
                          symbol: "checklist")
            if data.tasks.isEmpty {
                StatePlaceholder(title: "No Ledger Records", symbol: "checklist", message: "The Lighthouse ledger streams are empty.")
                    .frame(height: 140).card()
            } else {
                PagedTable(
                    rows: data.tasks,
                    columns: [
                        PagedColumn<AITelemetry.TaskRow>("Task", id: "name", width: 300, min: 200) { $0.name },
                        PagedColumn("Status Events", id: "events", width: 100, alignment: .trailing) { Format.count($0.events) },
                        PagedColumn("Completed", id: "completed", width: 86, alignment: .trailing) { countOrDash($0.completed) },
                        PagedColumn("Failed", id: "failed", width: 66, alignment: .trailing) { countOrDash($0.failed) },
                        PagedColumn("Errors", id: "errors", width: 66, alignment: .trailing) { countOrDash($0.errors) },
                        PagedColumn("Last Status", id: "lastStatus", width: 170, secondary: true) { $0.lastStatus },
                        PagedColumn("Last Seen", id: "last", width: 150, secondary: true) { DossierDate.sortable($0.last) },
                    ],
                    searchPrompt: "Filter tasks",
                    reloadKey: data.tasks.count,
                    exportName: "lighthouse-tasks"
                )
                .frame(height: 340)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
            }

            Text("Scanned in \(String(format: "%.2f", data.scanSeconds)) s from \(Format.tildePath(Paths.biomeRestrictedStreams)) · read-only")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func countList(_ groups: [(String, [AITelemetry.Count])]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groups, id: \.0) { title, items in
                VStack(alignment: .leading, spacing: 4) {
                    InspectorGroupTitle(title)
                    if items.isEmpty {
                        Text("None recorded").font(.callout).foregroundStyle(.tertiary)
                    }
                    ForEach(items.prefix(5)) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(shorten(item.name)).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(Format.count(item.count)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
