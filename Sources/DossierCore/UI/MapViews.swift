import SwiftUI
import MapKit

/// One located value for ``PointMapView``.
public struct MapPoint: Identifiable, Sendable, Hashable {
    public var id: String
    public var latitude: Double
    public var longitude: Double
    /// Short label shown under the marker when it is not merged into a cluster.
    public var title: String
    /// How much this point counts (visits, photos, events); clusters add weights up.
    public var weight: Double
    /// Optional radius in metres (geofences, location uncertainty) drawn as a circle.
    public var radius: Double?

    public init(id: String? = nil, latitude: Double, longitude: Double, title: String = "", weight: Double = 1, radius: Double? = nil) {
        self.id = id ?? "\(latitude),\(longitude)|\(title)"
        self.latitude = latitude; self.longitude = longitude
        self.title = title; self.weight = weight; self.radius = radius
    }

    /// False for (0, 0), NaN and out-of-range coordinates, which stores use for "unknown".
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
            && !(latitude == 0 && longitude == 0)
    }
}

/// A group of nearby ``MapPoint``s drawn as one marker.
public struct MapCluster: Identifiable, Sendable, Hashable {
    public var id: String
    public var latitude: Double
    public var longitude: Double
    public var weight: Double
    /// Member points (all of them — use for the inspector / a filtered table).
    public var points: [MapPoint]

    public var title: String { points.count == 1 ? points[0].title : "" }

    /// Merges points into at most `limit` clusters by snapping them to a latitude /
    /// longitude grid that is coarsened until the limit is met. O(n) per pass; safe for
    /// hundreds of thousands of points, but call it off the main actor for large inputs.
    public static func make(from points: [MapPoint], limit: Int = 150) -> [MapCluster] {
        let valid = points.filter(\.isValid)
        guard !valid.isEmpty else { return [] }
        if valid.count <= limit {
            return valid.map { MapCluster(id: $0.id, latitude: $0.latitude, longitude: $0.longitude, weight: $0.weight, points: [$0]) }
        }
        var cell = 0.0005   // degrees, roughly 50 m
        while true {
            var buckets: [SIMD2<Int32>: [MapPoint]] = [:]
            for p in valid {
                let key = SIMD2(Int32((p.latitude / cell).rounded(.down)), Int32((p.longitude / cell).rounded(.down)))
                buckets[key, default: []].append(p)
            }
            if buckets.count <= limit || cell > 90 {
                return buckets.map { key, members in
                    let total = members.reduce(0) { $0 + max($1.weight, 0) }
                    let divisor = total > 0 ? total : Double(members.count)
                    let lat = members.reduce(0) { $0 + $1.latitude * (total > 0 ? max($1.weight, 0) : 1) } / divisor
                    let lon = members.reduce(0) { $0 + $1.longitude * (total > 0 ? max($1.weight, 0) : 1) } / divisor
                    return MapCluster(id: "\(key.x):\(key.y):\(cell)", latitude: lat, longitude: lon, weight: total, points: members)
                }
                .sorted { $0.weight > $1.weight }
            }
            cell *= 2
        }
    }
}

/// A MapKit map of weighted points, clustered so that it never draws more than
/// `maxMarkers` annotations however many points it is given.
///
/// ```swift
/// PointMapView(places.map { MapPoint(latitude: $0.lat, longitude: $0.lon, title: $0.name, weight: Double($0.visits)) },
///              tint: .red) { cluster in selectedPlaces = cluster.points }
///     .frame(height: 360)
/// ```
///
/// * Give the view an explicit height (or let it fill a pane).
/// * Locations are `.sensitive` by default: in Privacy Mode the map is replaced by a
///   placeholder (blurring does not reliably apply to MapKit's GPU-backed layer).
/// * In `--snapshot` runs an interactive `Map` cannot be captured (its Metal layer is
///   invisible to the offscreen capture, and annotations never are), so this view renders
///   a static `MKMapSnapshotter` image with the same markers instead. A hand-written `Map`
///   shows up blank or half-drawn in snapshots — prefer this view.
/// * Map tiles are fetched by MapKit from Apple for the visible region; no point data
///   leaves the process.
public struct PointMapView: View {
    private let clusters: [MapCluster]
    private let tint: Color
    private let sensitivity: Sensitivity
    private let valueLabel: (Double) -> String
    private let onSelect: ((MapCluster) -> Void)?
    @State private var selectedID: String?
    @Environment(\.privacyMode) private var privacyMode

    /// - Parameters:
    ///   - points: any number of points; invalid coordinates are dropped.
    ///   - maxMarkers: upper bound on drawn annotations (points are clustered to fit).
    ///   - valueLabel: formats a cluster weight for its badge.
    ///   - onSelect: called when a marker is clicked, with the cluster and all its points.
    public init(
        _ points: [MapPoint], maxMarkers: Int = 150, tint: Color = .accentColor,
        sensitivity: Sensitivity = .sensitive,
        valueLabel: @escaping (Double) -> String = { Format.compact(Int($0)) },
        onSelect: ((MapCluster) -> Void)? = nil
    ) {
        self.init(clusters: MapCluster.make(from: points, limit: maxMarkers), tint: tint, sensitivity: sensitivity, valueLabel: valueLabel, onSelect: onSelect)
    }

    /// For clusters computed off the main actor with ``MapCluster/make(from:limit:)``.
    public init(
        clusters: [MapCluster], tint: Color = .accentColor, sensitivity: Sensitivity = .sensitive,
        valueLabel: @escaping (Double) -> String = { Format.compact(Int($0)) },
        onSelect: ((MapCluster) -> Void)? = nil
    ) {
        self.clusters = clusters; self.tint = tint; self.sensitivity = sensitivity
        self.valueLabel = valueLabel; self.onSelect = onSelect
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous) }

    public var body: some View {
        if clusters.isEmpty {
            StatePlaceholder(title: "No Locations", symbol: "mappin.slash")
                .frame(minHeight: 120)
        } else if privacyMode && sensitivity >= .personal {
            VStack(spacing: 6) {
                Image(systemName: "eye.slash").font(.title2).foregroundStyle(.secondary)
                Text("Map hidden in Privacy Mode").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 120)
            .background(Color.primary.opacity(0.06), in: shape)
        } else if SnapshotReadiness.isSnapshotting {
            StaticClusterMap(clusters: clusters, maxWeight: maxWeight, tint: tint, valueLabel: valueLabel)
                .clipShape(shape)
        } else {
            let maxWeight = maxWeight
            Map(initialPosition: .region(PointMapView.region(for: clusters))) {
                ForEach(clusters) { cluster in
                    let center = CLLocationCoordinate2D(latitude: cluster.latitude, longitude: cluster.longitude)
                    if cluster.points.count == 1, let radius = cluster.points[0].radius, radius > 0 {
                        MapCircle(center: center, radius: radius)
                            .foregroundStyle(tint.opacity(0.15))
                            .stroke(tint.opacity(0.7), lineWidth: 1)
                    }
                    Annotation(cluster.title, coordinate: center, anchor: .center) {
                        ClusterMarker(cluster: cluster, maxWeight: maxWeight, tint: tint, selected: selectedID == cluster.id, valueLabel: valueLabel)
                            .onTapGesture {
                                selectedID = cluster.id
                                onSelect?(cluster)
                            }
                            .help(cluster.points.count == 1 ? cluster.title : "\(Format.count(cluster.points.count)) places")
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .mapControls {
                MapZoomStepper()
                MapCompass()
                MapScaleView()
            }
            .clipShape(shape)
        }
    }

    private var maxWeight: Double { max(clusters.map(\.weight).max() ?? 1, 1) }

    /// The region that shows every cluster with some margin.
    ///
    /// - Parameter aspect: width / height of the view the region will be shown in. MapKit
    ///   fits a region so that *both* spans are visible, but for the static snapshot the
    ///   span has to be widened by hand, in Mercator space, or markers near the top and
    ///   bottom edges are cropped at high latitudes.
    public static func region(for clusters: [MapCluster], aspect: Double? = nil) -> MKCoordinateRegion {
        let lats = clusters.map(\.latitude), lons = clusters.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() else {
            return MKCoordinateRegion(.world)
        }
        // Work in Web-Mercator units (x: degrees of longitude, y: projected latitude in
        // the same unit) so that the centre and margins are right at any latitude.
        func mercator(_ lat: Double) -> Double {
            let clamped = min(max(lat, -85), 85) * .pi / 180
            return log(tan(.pi / 4 + clamped / 2)) * 180 / .pi
        }
        func latitude(_ y: Double) -> Double { (2 * atan(exp(y * .pi / 180)) - .pi / 2) * 180 / .pi }
        let y0 = mercator(minLat), y1 = mercator(maxLat)
        var width = max((maxLon - minLon) * 1.3, 0.01)
        var height = max((y1 - y0) * 1.3, 0.01)
        if let aspect, aspect.isFinite, aspect > 0 {
            if width / height < aspect { width = height * aspect } else { height = width / aspect }
        }
        width = min(width, 350)
        let centerY = (y0 + y1) / 2
        let top = latitude(min(centerY + height / 2, mercator(85))), bottom = latitude(max(centerY - height / 2, mercator(-85)))
        let span = MKCoordinateSpan(latitudeDelta: min(max(top - bottom, 0.005), 170), longitudeDelta: width)
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: latitude(centerY), longitude: (minLon + maxLon) / 2), span: span)
    }
}

/// The dot drawn for one cluster: area grows with weight, badge shows the weight.
private struct ClusterMarker: View {
    let cluster: MapCluster
    let maxWeight: Double
    let tint: Color
    let selected: Bool
    let valueLabel: (Double) -> String

    var body: some View {
        // Unweighted points (every weight 1, nothing merged) are plain pins: small, so they
        // do not cover the map's own labels. Otherwise the area grows with the weight.
        let plain = maxWeight <= 1 && cluster.points.count <= 1
        let size = plain ? 13 : 16 + 22 * (max(cluster.weight, 0) / maxWeight).squareRoot()
        ZStack {
            Circle().fill(tint.opacity(selected ? 0.95 : 0.75))
            Circle().strokeBorder(.white.opacity(0.9), lineWidth: selected ? 2.5 : 1)
            if cluster.weight > 1 || cluster.points.count > 1 {
                Text(valueLabel(cluster.weight))
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}

/// Non-interactive stand-in used for offscreen snapshots: an `MKMapSnapshotter` image
/// with the cluster markers drawn on top.
private struct StaticClusterMap: View {
    let clusters: [MapCluster]
    let maxWeight: Double
    let tint: Color
    let valueLabel: (Double) -> String

    private struct Rendered {
        let image: NSImage
        let positions: [String: CGPoint]
    }

    @State private var rendered: Rendered?
    @State private var failed = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let rendered {
                    // Until the snapshot for a new size arrives the old image is stretched to
                    // the new frame; the marker positions are stretched with it, so they
                    // stay on the places they belong to.
                    let size = rendered.image.size
                    let sx = size.width > 0 ? geo.size.width / size.width : 1
                    let sy = size.height > 0 ? geo.size.height / size.height : 1
                    Image(nsImage: rendered.image).resizable().frame(width: geo.size.width, height: geo.size.height)
                    ForEach(clusters) { cluster in
                        if let raw = rendered.positions[cluster.id] {
                            let point = CGPoint(x: raw.x * sx, y: raw.y * sy)
                            VStack(spacing: 1) {
                                ClusterMarker(cluster: cluster, maxWeight: maxWeight, tint: tint, selected: false, valueLabel: valueLabel)
                                if !cluster.title.isEmpty, clusters.count <= 12 {
                                    Text(cluster.title).font(.caption2.weight(.medium)).lineLimit(1).fixedSize()
                                        .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 1.5)
                                }
                            }
                            .position(x: point.x, y: point.y)
                        }
                    }
                } else if failed {
                    StatePlaceholder(title: "Map Unavailable", symbol: "map", message: "Map tiles could not be loaded.")
                } else {
                    LoadingPlaceholder()
                }
            }
            .task(id: "\(Int(geo.size.width))x\(Int(geo.size.height))|\(colorScheme == .dark)") {
                guard geo.size.width > 10, geo.size.height > 10 else { return }
                await SnapshotReadiness.track {
                    let options = MKMapSnapshotter.Options()
                    options.region = PointMapView.region(for: clusters, aspect: Double(geo.size.width / geo.size.height))
                    options.size = geo.size
                    options.pointOfInterestFilter = .excludingAll
                    options.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
                    do {
                        let snapshot = try await MKMapSnapshotter(options: options).start()
                        var positions: [String: CGPoint] = [:]
                        for cluster in clusters {
                            // AppKit image coordinates: origin at the bottom-left.
                            let p = snapshot.point(for: CLLocationCoordinate2D(latitude: cluster.latitude, longitude: cluster.longitude))
                            positions[cluster.id] = CGPoint(x: p.x, y: snapshot.image.size.height - p.y)
                        }
                        // A render for a size the view no longer has must not replace a newer one.
                        if Task.isCancelled { return }
                        rendered = Rendered(image: snapshot.image, positions: positions)
                        failed = false
                    } catch {
                        if Task.isCancelled { return }
                        if rendered == nil { failed = true }
                    }
                }
            }
        }
    }
}
