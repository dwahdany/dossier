import SwiftUI
import AppKit
import DossierCore

/// 46-pt header strip at the top of a section: optional mode picker on the left,
/// a one-line plain-English explanation of the store next to it.
///
/// The strip adapts to the width it is given, in this order: full controls plus the
/// explanation text; full controls plus an info button that shows the explanation in a
/// popover; compact controls (``ModePicker`` becomes a pop-up menu) plus the text; compact
/// controls plus the info button. Its minimum width is therefore that of the last form,
/// not of a segmented control that cannot shrink.
struct SectionStrip<Leading: View>: View {
    let explanation: String
    let leading: Leading

    init(_ explanation: String, @ViewBuilder leading: () -> Leading) {
        self.explanation = explanation
        self.leading = leading()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false, showsText: true)
            row(compact: false, showsText: false)
            row(compact: true, showsText: true)
            row(compact: true, showsText: false)
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func row(compact: Bool, showsText: Bool) -> some View {
        HStack(spacing: 12) {
            leading.environment(\.sectionStripCompact, compact)
            if showsText {
                Image(systemName: "info.circle").foregroundStyle(.tertiary).imageScale(.small)
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    // A readable minimum; below it the strip switches to the info button.
                    .frame(minWidth: SectionStripMetrics.minTextWidth, idealWidth: SectionStripMetrics.minTextWidth, maxWidth: .infinity, alignment: .leading)
                    .help(explanation)
            } else {
                Spacer(minLength: 0)
                ExplanationButton(explanation: explanation)
            }
        }
    }
}

private enum SectionStripMetrics {
    static let minTextWidth: CGFloat = 250
}

/// Info button standing in for the strip's explanation text when there is no room for it.
private struct ExplanationButton: View {
    let explanation: String
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .help(explanation)
        .accessibilityLabel("About this view")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(explanation)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 320, alignment: .leading)
                .padding(14)
        }
    }
}

private struct SectionStripCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the enclosing ``SectionStrip`` has no room for full-width controls.
    var sectionStripCompact: Bool {
        get { self[SectionStripCompactKey.self] }
        set { self[SectionStripCompactKey.self] = newValue }
    }
}

extension SectionStrip where Leading == EmptyView {
    init(_ explanation: String) { self.init(explanation) { EmptyView() } }
}

/// Mode picker used in section strips: a segmented control, or a pop-up menu when the
/// strip is too narrow for the segments.
struct ModePicker<Mode: Hashable & Identifiable>: View {
    let modes: [Mode]
    let title: (Mode) -> String
    @Binding var selection: Mode
    @Environment(\.sectionStripCompact) private var compact

    var body: some View {
        let picker = Picker("", selection: $selection) {
            ForEach(modes) { mode in Text(title(mode)).tag(mode) }
        }
        .labelsHidden()
        if compact {
            picker.pickerStyle(.menu).fixedSize()
        } else {
            picker.pickerStyle(.segmented).fixedSize()
        }
    }
}

/// Thin proportional bar (score / share visualisation in lists and cells).
struct ScoreBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint.opacity(0.85)).frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}

/// "Contributing documents" list for inspectors.
struct DocumentList: View {
    let documents: [PortraitDocument]
    var showsAlgorithm: ((Int) -> String)?
    var limitNote: Int = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(documents) { document in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        AppLabel(bundle: document.bundle).font(.callout)
                        Spacer(minLength: 4)
                        Text(DossierDate.short(document.date)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack(spacing: 6) {
                        let origin = PortraitLabels.origin(bundle: document.bundle, group: document.group)
                        if origin != AppNames.name(document.bundle) {
                            Text(origin).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let showsAlgorithm, document.algorithm != 0 {
                            Text(showsAlgorithm(document.algorithm)).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        if !document.language.isEmpty {
                            Text(ProfileFormat.language(document.language)).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    Text("Document " + document.docID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .sensitive(.personal)
                }
                .padding(.vertical, 5)
                Divider()
            }
            if documents.count >= limitNote {
                Text("Showing the \(limitNote) most recent documents.").font(.caption).foregroundStyle(.tertiary).padding(.top, 6)
            }
        }
    }
}

/// Small coloured dot + text for categorical cells.
struct DotLabel: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).lineLimit(1)
        }
    }
}

/// Warning capsule (sensitive / flagged content).
struct FlagLabel: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"
    var tint: Color = .orange
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).imageScale(.small)
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Explanation paragraph card used at the top of dashboard pages and inspectors.
struct Explainer: View {
    let text: String
    var symbol = "info.circle"
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A secret value that stays masked until the user reveals it.
struct RevealableSecret: View {
    let value: String
    @State private var revealed = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(revealed ? value : ProfileFormat.mask(value))
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(revealed ? 6 : 1)
                .sensitive(.sensitive)
            Button(revealed ? "Hide" : "Reveal") { revealed.toggle() }
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}

/// Parsed `rgb(r, g, b)` colour of a Wallet pass.
struct PassColor {
    let red: Double, green: Double, blue: Double

    init?(_ text: String?) {
        guard let text else { return nil }
        let numbers = text.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
        guard numbers.count >= 3 else { return nil }
        red = min(numbers[0], 255) / 255; green = min(numbers[1], 255) / 255; blue = min(numbers[2], 255) / 255
    }

    var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    var color: Color { Color(red: red, green: green, blue: blue) }

    /// Black or white, whichever is readable on this colour.
    var readableText: Color { luminance > 0.55 ? .black : .white }

    func contrasts(with other: PassColor) -> Bool { abs(luminance - other.luminance) > 0.3 }
}

extension Color {
    /// Parses the `rgb(r, g, b)` colour strings used in Wallet pass definitions.
    init?(passColor: String?) {
        guard let passColor else { return nil }
        let numbers = passColor.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
        guard numbers.count >= 3 else { return nil }
        self.init(red: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255)
    }
}

/// Splits a deep-link payload of the form `"<mode>\t<rest>"`.
func splitPayload(_ payload: String) -> (mode: String, rest: String) {
    guard let tab = payload.firstIndex(of: "\t") else { return (payload, "") }
    return (String(payload[..<tab]), String(payload[payload.index(after: tab)...]))
}
