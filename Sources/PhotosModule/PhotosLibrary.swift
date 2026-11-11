import Foundation
import SwiftUI
import AppKit
import DossierCore

/// One Photos library bundle (`*.photoslibrary`) and the stores inside it that this module reads.
struct PhotosLibrary: Sendable, Hashable, Identifiable {
    let root: URL
    var id: String { root.path }
    var name: String { root.deletingPathExtension().lastPathComponent }

    var databaseDirectory: URL { root.appendingPathComponent("database", isDirectory: true) }
    /// Core Data store with assets, people, faces, moments, memories, highlights, scene classifications.
    var photosDB: URL { databaseDirectory.appendingPathComponent("Photos.sqlite") }
    /// Legacy search index ("PSI"); newer systems keep the index inside Photos.sqlite (ZLEO* tables).
    var psiDB: URL { databaseDirectory.appendingPathComponent("search/psi.sqlite") }
    var privateDirectory: URL { root.appendingPathComponent("private", isDirectory: true) }
    var photoAnalysisDirectory: URL { privateDirectory.appendingPathComponent("com.apple.photoanalysisd", isDirectory: true) }
    var mediaAnalysisDirectory: URL { privateDirectory.appendingPathComponent("com.apple.mediaanalysisd", isDirectory: true) }

    /// `private/com.apple.photoanalysisd/**/photosgraph.kgdb` — the PhotosGraph knowledge graph.
    var graphDB: URL? { PhotosLibraryLocator.find(in: photoAnalysisDirectory, key: id + "|graph") { name in name == "photosgraph.kgdb" } }
    /// `private/com.apple.mediaanalysisd/**/MediaAnalysis.sqlite` — per-asset media analysis results.
    var mediaAnalysisDB: URL? { PhotosLibraryLocator.find(in: mediaAnalysisDirectory, key: id + "|media") { name in name.lowercased() == "mediaanalysis.sqlite" } }

    /// Expected location shown in "missing" states when discovery finds nothing.
    var expectedGraphDB: URL { photoAnalysisDirectory.appendingPathComponent("caches/graph/PhotosGraph/photosgraph.kgdb") }
    var expectedMediaAnalysisDB: URL { mediaAnalysisDirectory.appendingPathComponent("MediaAnalysis/MediaAnalysis.sqlite") }
}

/// Finds Photos libraries without prompting: the system library, other bundles in ~/Pictures,
/// and a user-chosen one (remembered in UserDefaults; `DOSSIER_PHOTOS_LIBRARY` overrides for tests).
enum PhotosLibraryLocator {
    static let defaultsKey = "dossier.photos.libraryPath"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var discovered: [String: URL?] = [:]

    /// The library all sections currently read.
    static func current() -> PhotosLibrary? {
        if let forced = ProcessInfo.processInfo.environment["DOSSIER_PHOTOS_LIBRARY"], !forced.isEmpty {
            return PhotosLibrary(root: URL(fileURLWithPath: (forced as NSString).expandingTildeInPath, isDirectory: true))
        }
        if let chosen = UserDefaults.standard.string(forKey: defaultsKey), !chosen.isEmpty,
           FileManager.default.fileExists(atPath: chosen) {
            return PhotosLibrary(root: URL(fileURLWithPath: chosen, isDirectory: true))
        }
        return systemLibrary()
    }

    /// The system Photos library: the path photolibraryd recorded, else the standard bundle in ~/Pictures.
    static func systemLibrary() -> PhotosLibrary? {
        let prefs = Paths.library.appendingPathComponent("Containers/com.apple.photolibraryd/Data/Library/Preferences/com.apple.photolibraryd.plist")
        if let data = try? Data(contentsOf: prefs),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let path = plist["SystemLibraryPath"] as? String, FileManager.default.fileExists(atPath: path) {
            return PhotosLibrary(root: URL(fileURLWithPath: path, isDirectory: true))
        }
        return Paths.photosLibrary.map { PhotosLibrary(root: $0) }
    }

    /// System library first, then every other `*.photoslibrary` bundle in ~/Pictures.
    static func candidates() -> [PhotosLibrary] {
        var out: [PhotosLibrary] = []
        if let system = systemLibrary() { out.append(system) }
        let pictures = Paths.home.appendingPathComponent("Pictures", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: pictures, includingPropertiesForKeys: nil)) ?? []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where item.pathExtension == "photoslibrary" {
            let lib = PhotosLibrary(root: item)
            if !out.contains(where: { $0.root.standardizedFileURL.path == lib.root.standardizedFileURL.path }) { out.append(lib) }
        }
        if let cur = current(), !out.contains(where: { $0.root.standardizedFileURL.path == cur.root.standardizedFileURL.path }) { out.append(cur) }
        return out
    }

    /// Bounded recursive search for a file below `directory` (depth ≤ 5); the largest match wins.
    static func find(in directory: URL, key: String, matching: (String) -> Bool) -> URL? {
        lock.lock()
        if let cached = discovered[key] { lock.unlock(); return cached }
        lock.unlock()
        var best: (url: URL, size: Int)?
        if let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsPackageDescendants]) {
            for case let url as URL in walker {
                if walker.level > 5 { walker.skipDescendants(); continue }
                guard matching(url.lastPathComponent) else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if best == nil || size > best!.size { best = (url, size) }
            }
        }
        lock.lock(); discovered[key] = .some(best?.url); lock.unlock()
        return best?.url
    }

    static func resetDiscovery() {
        lock.lock(); discovered.removeAll(); lock.unlock()
    }
}

/// Observable selection shared by all sections so that choosing another library reloads them.
@MainActor
final class PhotosLibrarySelection: ObservableObject {
    static let shared = PhotosLibrarySelection()
    @Published private(set) var current: PhotosLibrary? = PhotosLibraryLocator.current()
    @Published private(set) var candidates: [PhotosLibrary] = PhotosLibraryLocator.candidates()

    func select(_ library: PhotosLibrary?) {
        if let library, library != PhotosLibraryLocator.systemLibrary() {
            UserDefaults.standard.set(library.root.path, forKey: PhotosLibraryLocator.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PhotosLibraryLocator.defaultsKey)
        }
        PhotosLibraryLocator.resetDiscovery()
        current = PhotosLibraryLocator.current()
        candidates = PhotosLibraryLocator.candidates()
        Task { await PhotosCaches.shared.reset() }
    }

    /// Lets the user pick any `.photoslibrary` bundle (read-only use; nothing is modified).
    func chooseWithPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Photos Library"
        panel.message = "Dossier only reads the library’s databases. Nothing is modified."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Paths.home.appendingPathComponent("Pictures", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url, url.pathExtension == "photoslibrary" {
            select(PhotosLibrary(root: url))
        }
    }
}

/// Header-strip menu: shows the active library and lets the user switch.
struct LibraryMenu: View {
    @ObservedObject private var selection = PhotosLibrarySelection.shared

    var body: some View {
        Menu {
            ForEach(selection.candidates) { lib in
                Button {
                    selection.select(lib)
                } label: {
                    if lib == selection.current { Label(lib.name, systemImage: "checkmark") } else { Text(lib.name) }
                }
            }
            Divider()
            Button("Choose Library…") { selection.chooseWithPanel() }
            if selection.current != PhotosLibraryLocator.systemLibrary() {
                Button("Use System Library") { selection.select(nil) }
            }
        } label: {
            Label(selection.current?.name ?? "No Library", systemImage: "photo.on.rectangle.angled")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Photos library being inspected")
    }
}

// MARK: - Shared helpers

enum PhotosError {
    static func noLibrary() -> DossierError { .missing("No Photos library was found in ~/Pictures. Choose one from the library menu.") }
}

extension PhotosLibrary {
    /// Opens a store of this library read-only, mapping absence to a "missing" placeholder.
    func open(_ url: URL?, _ what: String) async throws -> SQLiteDB {
        guard let url else { throw DossierError.missing("\(what) does not exist in this library.") }
        switch Paths.probe(url) {
        case .missing: throw DossierError.missing("\(what) does not exist in this library.")
        case .inaccessible(let reason): throw DossierError.inaccessible(reason)
        case .available: break
        }
        return try await SQLiteDB.shared(url)
    }

    func photos() async throws -> SQLiteDB { try await open(photosDB, "Photos.sqlite") }
}

extension SQLiteDB {
    /// Columns of `table` that exist, out of `wanted` (schema differs per macOS version).
    func existing(_ table: String, _ wanted: [String]) async -> Set<String> {
        let all = await columnNames(of: table)
        let upper = Set(all.map { $0.uppercased() })
        return Set(wanted.filter { upper.contains($0.uppercased()) })
    }
}

/// `expr` if the column exists, else a literal fallback — keeps SELECT lists stable across schema versions.
func sqlColumn(_ existing: Set<String>, _ name: String, prefix: String = "", fallback: String = "NULL") -> String {
    existing.contains(name) ? prefix + name : fallback
}

/// PhotosGraph stores dates either as Unix or as Cocoa seconds depending on the attribute; pick the plausible one.
func graphDate(_ seconds: Double?) -> Date? {
    guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
    let unix = Date(timeIntervalSince1970: seconds)
    let year = Calendar(identifier: .gregorian).component(.year, from: unix)
    if year >= 2001 && unix < Date().addingTimeInterval(5 * 365 * 86_400) { return unix }
    let cocoa = Date(timeIntervalSinceReferenceDate: seconds)
    return DossierDate.isPlausible(cocoa) ? cocoa : nil
}
