import AppKit
import DossierCore
import SwiftUI

// MARK: - String interning

/// Shares storage between equal strings (titles, bundle ids repeat thousands of times).
struct StringInterner {
    private var table: [String: String] = [:]
    mutating func callAsFunction(_ s: String) -> String {
        if let existing = table[s] { return existing }
        table[s] = s
        return s
    }
}

// MARK: - App names and icons

/// Bundle identifier → app name; the shared resolver lives in `DossierCore.AppDirectory`
/// (as do the `AppIcon` and `AppLabel` views).
enum AppNames {
    static func name(_ bundle: String) -> String { AppDirectory.name(bundle) }
    static func appURL(_ bundle: String) -> URL? { AppDirectory.appURL(bundle) }
    static func isSystemSurface(_ bundle: String) -> Bool { AppDirectory.isSystemSurface(bundle) }
    static func isLockSurface(_ bundle: String) -> Bool { AppDirectory.isLockSurface(bundle) }
}

// MARK: - Stable colours per app

enum AppColor {
    /// Deterministic palette colour for a bundle id (FNV-1a, so it is stable across runs,
    /// unlike `hashValue`).
    static func color(_ bundle: String) -> Color {
        var h: UInt32 = 2_166_136_261
        for b in bundle.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return palette[Int(h % UInt32(palette.count))]
    }

    static let palette: [Color] = [
        .blue, .orange, .green, .purple, .pink, .teal, .yellow, .indigo, .brown, .mint, .cyan, .red,
    ]
}

// MARK: - Small shared views

/// Plain-English provenance note shown under headers.
struct ExplainerText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 900, alignment: .leading)
    }
}

/// A horizontal proportion bar used in ranked lists.
struct ProportionBar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(tint.gradient).frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
    }
}

extension Format {
    /// Hours:minutes clock label for a fractional hour (wraps past midnight).
    static func clock(_ hour: Double) -> String {
        let total = Int((hour * 60).rounded())
        let h = ((total / 60) % 24 + 24) % 24
        return String(format: "%02d:%02d", h, total % 60)
    }

    /// Usage duration that never rolls over into days: "52h 10m", "4m 05s", "12s".
    static func usage(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0s" }
        let s = Int(seconds.rounded())
        if s >= 3600 { return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m" }
        if s >= 60 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        if s >= 1 { return "\(s)s" }
        return "<1s"
    }
}
