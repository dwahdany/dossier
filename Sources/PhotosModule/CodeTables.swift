import Foundation
import DossierCore

/// How sure we are about the human-readable meaning of a stored integer code.
enum CodeCertainty: Sendable {
    /// Verified against the data itself (correlated columns, matching counts) or a documented enum.
    case established
    /// Consistent with the data but not provable from the store alone.
    case probable
}

struct CodeLabel: Sendable {
    let name: String
    let certainty: CodeCertainty
    init(_ name: String, _ certainty: CodeCertainty = .established) { self.name = name; self.certainty = certainty }
}

/// A coded integer column and what is known about its values. Unknown values are shown as "code N".
struct CodeTable: Sendable {
    let labels: [Int: CodeLabel]

    func label(_ code: Int?) -> String {
        guard let code else { return "—" }
        guard let l = labels[code] else { return "code \(code)" }
        switch l.certainty {
        case .established: return "\(l.name) (\(code))"
        case .probable: return "\(l.name)? (\(code))"
        }
    }

    func isProbable(_ code: Int) -> Bool { labels[code]?.certainty == .probable }

    func shortLabel(_ code: Int?) -> String {
        guard let code else { return "—" }
        guard let l = labels[code] else { return "code \(code)" }
        return l.certainty == .probable ? l.name + "?" : l.name
    }
}

/// One coded face attribute column of ZDETECTEDFACE.
struct FaceAttribute: Sendable, Identifiable {
    let column: String
    let title: String
    let table: CodeTable
    /// Why the labels are (or are not) trusted — shown under the chart.
    let note: String
    var id: String { column }
}

/// Code tables for Photos.sqlite. Labels are only given where the meaning can be justified:
/// either the store itself confirms it (e.g. ZEYESSTATE = 1 coincides exactly with both
/// "eye closed" flags) or the value is part of the long-documented PhotoKit / Photos schema
/// (favourite / hidden person types, media subtypes). Everything else stays "code N".
enum PhotosCodes {
    static let notAnalysed = CodeLabel("Not analysed")

    static let faceAttributes: [FaceAttribute] = [
        FaceAttribute(column: "ZAGETYPE", title: "Age bracket", table: CodeTable(labels: [
            0: notAnalysed, 1: CodeLabel("Baby"), 2: CodeLabel("Child"), 3: CodeLabel("Young adult"),
            4: CodeLabel("Senior", .probable), 5: CodeLabel("Adult", .probable),
        ]), note: "Codes 1–3 follow the documented face-age enum; 4 and 5 are marked uncertain."),
        FaceAttribute(column: "ZGENDERTYPE", title: "Gender", table: CodeTable(labels: [
            0: notAnalysed, 1: CodeLabel("Male"), 2: CodeLabel("Female"),
        ]), note: "Documented enum (1 male, 2 female). The classifier’s guess per face, not a statement about the person."),
        FaceAttribute(column: "ZETHNICITYTYPE", title: "Ethnicity", table: CodeTable(labels: [0: notAnalysed]),
                      note: "The store holds a 5-way ethnicity class per face. The code order is not derivable from the data, so values are shown raw."),
        FaceAttribute(column: "ZSKINTONETYPE", title: "Skin tone", table: CodeTable(labels: [0: notAnalysed]),
                      note: "A 6-level skin-tone class per face; the direction of the scale is not stored, values are shown raw."),
        FaceAttribute(column: "ZGLASSESTYPE", title: "Glasses", table: CodeTable(labels: [
            0: notAnalysed, 1: CodeLabel("Eyeglasses", .probable), 2: CodeLabel("Sunglasses", .probable), 3: CodeLabel("None", .probable),
        ]), note: "Labels follow the documented glasses enum; treat as probable."),
        FaceAttribute(column: "ZFACIALHAIRTYPE", title: "Facial hair", table: CodeTable(labels: [0: notAnalysed, 1: CodeLabel("None", .probable)]),
                      note: "Five classes; only the “no facial hair” class is labelled (probable), the others are shown raw."),
        FaceAttribute(column: "ZHAIRCOLORTYPE", title: "Hair colour", table: CodeTable(labels: [0: notAnalysed]),
                      note: "Six hair-colour classes; the code order is not derivable from the data."),
        FaceAttribute(column: "ZHEADGEARTYPE", title: "Headgear", table: CodeTable(labels: [0: notAnalysed]),
                      note: "Five headgear classes, shown raw."),
        FaceAttribute(column: "ZHASFACEMASK", title: "Face mask", table: CodeTable(labels: [0: CodeLabel("No / not analysed"), 1: CodeLabel("Mask detected")]),
                      note: "Boolean column."),
        FaceAttribute(column: "ZFACEEXPRESSIONTYPE", title: "Expression", table: CodeTable(labels: [0: notAnalysed]),
                      note: "Six expression classes, shown raw."),
        FaceAttribute(column: "ZSMILETYPE", title: "Smile type", table: CodeTable(labels: [0: notAnalysed]),
                      note: "Two classes, shown raw (ZHASSMILE is the separate boolean)."),
        FaceAttribute(column: "ZHASSMILE", title: "Has smile", table: CodeTable(labels: [0: CodeLabel("No"), 1: CodeLabel("Yes")]),
                      note: "Boolean column."),
        FaceAttribute(column: "ZEYESSTATE", title: "Eyes", table: CodeTable(labels: [0: notAnalysed, 1: CodeLabel("Closed"), 2: CodeLabel("Open")]),
                      note: "Verified in the data: code 1 coincides with both “eye closed” flags."),
        FaceAttribute(column: "ZGAZETYPE", title: "Gaze", table: CodeTable(labels: [0: notAnalysed]),
                      note: "Five gaze classes, shown raw."),
        FaceAttribute(column: "ZPOSETYPE", title: "Head pose", table: CodeTable(labels: [0: notAnalysed]),
                      note: "Five pose classes, shown raw."),
        FaceAttribute(column: "ZEYEMAKEUPTYPE", title: "Eye make-up", table: CodeTable(labels: [0: notAnalysed]), note: "Shown raw."),
        FaceAttribute(column: "ZLIPMAKEUPTYPE", title: "Lip make-up", table: CodeTable(labels: [0: notAnalysed]), note: "Shown raw."),
        FaceAttribute(column: "ZHAIRTYPE", title: "Hair type", table: CodeTable(labels: [0: notAnalysed]), note: "Shown raw."),
    ]

    /// ZPERSON.ZTYPE
    static let personType = CodeTable(labels: [-1: CodeLabel("Hidden"), 0: CodeLabel("Normal"), 1: CodeLabel("Favourite")])
    /// ZPERSON.ZVERIFIEDTYPE — -2 occurs exactly on the rows that have a merge target.
    static let verifiedType = CodeTable(labels: [-2: CodeLabel("Merged away"), 0: CodeLabel("Unverified"), 1: CodeLabel("Confirmed by user"), 2: CodeLabel("Confirmed by graph", .probable)])
    /// ZPERSON.ZDETECTIONTYPE / ZDETECTEDFACE.ZDETECTIONTYPE — 1 is the human class; persons with
    /// other codes are the ones the search index lists as pets.
    static let detectionType = CodeTable(labels: [1: CodeLabel("Human"), 3: CodeLabel("Pet (dog class)", .probable), 4: CodeLabel("Pet (cat class)", .probable)])

    /// ZASSET.ZKIND
    static let assetKind = CodeTable(labels: [0: CodeLabel("Photo"), 1: CodeLabel("Video")])
    /// ZASSET.ZKINDSUBTYPE
    static let assetSubtype = CodeTable(labels: [
        0: CodeLabel("Standard"), 1: CodeLabel("Panorama"), 2: CodeLabel("Live Photo"), 10: CodeLabel("Screenshot"),
        100: CodeLabel("Video (code 100)"), 101: CodeLabel("Slo-mo"), 102: CodeLabel("Time-lapse"), 103: CodeLabel("Screen recording", .probable),
    ])

    /// ZPHOTOSHIGHLIGHT.ZKIND — verified by the date spans stored with each kind.
    static let highlightKind = CodeTable(labels: [0: CodeLabel("Day"), 1: CodeLabel("Month"), 2: CodeLabel("Year"), 3: CodeLabel("Day group")])

    /// ZPHOTOSHIGHLIGHT.ZTYPE for day groups (ZKIND = 3) — matches the LongTrip / ShortTrip nodes
    /// of the PhotosGraph one to one.
    static func highlightType(kind: Int, type: Int) -> String {
        switch (kind, type) {
        case (3, 1): return "Long trip"
        case (3, 2): return "Short trip"
        case (0, 5): return "Day of a trip"
        case (_, 0): return "Regular"
        default: return "type \(type)"
        }
    }

    /// ZSHAREPARTICIPANT.ZPARTICIPANTROLE / ZSHARE.ZSCOPETYPE are shown raw except for the obvious owner flag.
}

/// Categories of the Photos search index. Two generations exist:
/// the "Leo" lexicon inside Photos.sqlite (ZLEOLEXEME, 4-digit codes in steps of 10) and the
/// older psi.sqlite (`groups.category`). Names are inferred from the terms stored under each
/// code on real libraries (months under 1010, countries under 2160, …); unknown codes stay raw.
enum SearchCategories {
    struct Info: Sendable {
        let name: String
        let group: String
        /// Free text taken from the user's content (OCR tokens, titles, file names): revealed per row only.
        var reveal: Bool = false
        var sensitivity: Sensitivity = .personal
    }

    static let leo: [Int: Info] = [
        1000: Info(name: "Date bucket", group: "Time", sensitivity: .low),
        1010: Info(name: "Month", group: "Time", sensitivity: .low),
        1020: Info(name: "Year", group: "Time", sensitivity: .low),
        1030: Info(name: "Holiday", group: "Time"),
        1040: Info(name: "Season", group: "Time", sensitivity: .low),
        1050: Info(name: "Part of day", group: "Time", sensitivity: .low),
        1060: Info(name: "Part of week", group: "Time", sensitivity: .low),
        1070: Info(name: "Weekday", group: "Time", sensitivity: .low),
        2010: Info(name: "Home", group: "Places", sensitivity: .sensitive),
        2020: Info(name: "Work", group: "Places", sensitivity: .sensitive),
        2030: Info(name: "Place type", group: "Places"),
        2050: Info(name: "Street", group: "Places", sensitivity: .sensitive),
        2060: Info(name: "Place name", group: "Places", sensitivity: .sensitive),
        2070: Info(name: "Neighbourhood", group: "Places", sensitivity: .sensitive),
        2080: Info(name: "Area of interest", group: "Places", sensitivity: .sensitive),
        2090: Info(name: "City", group: "Places", sensitivity: .sensitive),
        2100: Info(name: "Sub-locality", group: "Places", sensitivity: .sensitive),
        2110: Info(name: "County / region", group: "Places", sensitivity: .sensitive),
        2120: Info(name: "Borough / locality", group: "Places", sensitivity: .sensitive),
        2130: Info(name: "Named area", group: "Places", sensitivity: .sensitive),
        2140: Info(name: "State / province", group: "Places", sensitivity: .sensitive),
        2150: Info(name: "State abbreviation", group: "Places", sensitivity: .sensitive),
        2160: Info(name: "Country", group: "Places", sensitivity: .sensitive),
        2170: Info(name: "Country synonym", group: "Places", sensitivity: .sensitive),
        2180: Info(name: "Subcontinent", group: "Places"),
        2190: Info(name: "Continent", group: "Places"),
        2210: Info(name: "Body of water", group: "Places", sensitivity: .sensitive),
        2220: Info(name: "Business", group: "Places", sensitivity: .sensitive),
        2230: Info(name: "Business category", group: "Places"),
        2240: Info(name: "Public event", group: "Places", sensitivity: .sensitive),
        2250: Info(name: "Performer", group: "Places", sensitivity: .sensitive),
        2260: Info(name: "Event category", group: "Places"),
        3000: Info(name: "Person", group: "People", sensitivity: .sensitive),
        3001: Info(name: "Unverified person", group: "People"),
        3010: Info(name: "Pet", group: "People", sensitivity: .sensitive),
        3020: Info(name: "Shared-library contributor", group: "People", sensitivity: .sensitive),
        3030: Info(name: "Age group", group: "People"),
        4000: Info(name: "Scene", group: "Content"),
        4010: Info(name: "Visual Look Up label", group: "Content"),
        4020: Info(name: "Landmark", group: "Content", sensitivity: .sensitive),
        4050: Info(name: "Audio class", group: "Content"),
        4060: Info(name: "Human action", group: "Content"),
        4070: Info(name: "Sticker category", group: "Content", sensitivity: .low),
        4080: Info(name: "Utility class", group: "Content"),
        4090: Info(name: "Meaning", group: "Content"),
        4100: Info(name: "Trip", group: "Content"),
        4110: Info(name: "Has text", group: "Content", sensitivity: .low),
        4120: Info(name: "Text in image (OCR)", group: "Content", reveal: true, sensitivity: .sensitive),
        4130: Info(name: "Document class", group: "Content"),
        5000: Info(name: "Media type: photo", group: "Media", sensitivity: .low),
        5010: Info(name: "Media type: video", group: "Media", sensitivity: .low),
        5020: Info(name: "Media type: RAW", group: "Media", sensitivity: .low),
        5030: Info(name: "Media type: Cinematic", group: "Media", sensitivity: .low),
        5050: Info(name: "Media type: Slo-mo", group: "Media", sensitivity: .low),
        5060: Info(name: "Media type: Live Photo", group: "Media", sensitivity: .low),
        5070: Info(name: "Media type: screenshot", group: "Media", sensitivity: .low),
        5080: Info(name: "Media type: panorama", group: "Media", sensitivity: .low),
        5090: Info(name: "Media type: time-lapse", group: "Media", sensitivity: .low),
        5100: Info(name: "Media type: screen recording", group: "Media", sensitivity: .low),
        5120: Info(name: "Media type: animated", group: "Media", sensitivity: .low),
        5130: Info(name: "Media type: burst", group: "Media", sensitivity: .low),
        5140: Info(name: "Media type: portrait", group: "Media", sensitivity: .low),
        5150: Info(name: "Media type: selfie", group: "Media", sensitivity: .low),
        5180: Info(name: "Media type: Live + depth", group: "Media", sensitivity: .low),
        5190: Info(name: "Media type: spatial", group: "Media", sensitivity: .low),
        5200: Info(name: "Photographic style", group: "Media", sensitivity: .low),
        6000: Info(name: "Camera", group: "Media"),
        6060: Info(name: "Flash", group: "Media", sensitivity: .low),
        7000: Info(name: "Title", group: "Library", reveal: true, sensitivity: .sensitive),
        7010: Info(name: "Album", group: "Library"),
        7020: Info(name: "Memory / highlight title", group: "Library"),
        7030: Info(name: "Shared album", group: "Library"),
        8000: Info(name: "Favourite", group: "Library", sensitivity: .low),
        8020: Info(name: "Edited", group: "Library", sensitivity: .low),
        8030: Info(name: "Personal library", group: "Library", sensitivity: .low),
        8040: Info(name: "Shared library", group: "Library", sensitivity: .low),
        8050: Info(name: "File name", group: "Library", reveal: true, sensitivity: .personal),
        8051: Info(name: "File type", group: "Library", sensitivity: .low),
        8060: Info(name: "Saved from app", group: "Library"),
        8080: Info(name: "Description", group: "Library", reveal: true, sensitivity: .sensitive),
        8110: Info(name: "Asset identifier", group: "Library", sensitivity: .low),
        8170: Info(name: "Captured by", group: "Library"),
    ]

    static let psi: [Int: Info] = [
        0: Info(name: "Holiday synonym", group: "Time"),
        1: Info(name: "Place name", group: "Places", sensitivity: .sensitive),
        2: Info(name: "Street", group: "Places", sensitivity: .sensitive),
        3: Info(name: "Neighbourhood", group: "Places", sensitivity: .sensitive),
        4: Info(name: "Area of interest", group: "Places", sensitivity: .sensitive),
        5: Info(name: "City", group: "Places", sensitivity: .sensitive),
        6: Info(name: "Sub-locality", group: "Places", sensitivity: .sensitive),
        7: Info(name: "County / region", group: "Places", sensitivity: .sensitive),
        8: Info(name: "Borough / locality", group: "Places", sensitivity: .sensitive),
        9: Info(name: "Named area", group: "Places", sensitivity: .sensitive),
        10: Info(name: "State / province", group: "Places", sensitivity: .sensitive),
        11: Info(name: "State abbreviation", group: "Places", sensitivity: .sensitive),
        12: Info(name: "Country", group: "Places", sensitivity: .sensitive),
        14: Info(name: "Body of water", group: "Places", sensitivity: .sensitive),
        1000: Info(name: "Home", group: "Places", sensitivity: .sensitive),
        1001: Info(name: "Work", group: "Places", sensitivity: .sensitive),
        1100: Info(name: "Month", group: "Time", sensitivity: .low),
        1101: Info(name: "Year", group: "Time", sensitivity: .low),
        1103: Info(name: "Holiday", group: "Time"),
        1104: Info(name: "Season", group: "Time", sensitivity: .low),
        1105: Info(name: "Season synonym", group: "Time", sensitivity: .low),
        1106: Info(name: "Part of day", group: "Time", sensitivity: .low),
        1107: Info(name: "Part of week", group: "Time", sensitivity: .low),
        1108: Info(name: "Part-of-day synonym", group: "Time", sensitivity: .low),
        1109: Info(name: "Part-of-week synonym", group: "Time", sensitivity: .low),
        1201: Info(name: "Title", group: "Library", reveal: true, sensitivity: .sensitive),
        1202: Info(name: "Description", group: "Library", reveal: true, sensitivity: .sensitive),
        1203: Info(name: "Text in image (OCR)", group: "Content", reveal: true, sensitivity: .sensitive),
        1205: Info(name: "Has text", group: "Content", sensitivity: .low),
        1300: Info(name: "Person", group: "People", sensitivity: .sensitive),
        1320: Info(name: "Shared-library contributor", group: "People", sensitivity: .sensitive),
        1321: Info(name: "Contributor synonym", group: "People", sensitivity: .sensitive),
        1330: Info(name: "Pet", group: "People", sensitivity: .sensitive),
        1331: Info(name: "Pet synonym", group: "People"),
        1400: Info(name: "Album", group: "Library"),
        1401: Info(name: "Memory / highlight title", group: "Library"),
        1500: Info(name: "Scene", group: "Content"),
        1501: Info(name: "Scene synonym", group: "Content"),
        1510: Info(name: "Visual Look Up label", group: "Content"),
        1520: Info(name: "Landmark", group: "Content", sensitivity: .sensitive),
        1600: Info(name: "Meaning", group: "Content"),
        1601: Info(name: "Meaning synonym", group: "Content"),
        1610: Info(name: "Trip", group: "Content"),
        1611: Info(name: "Trip synonym", group: "Content"),
        1700: Info(name: "Business", group: "Places", sensitivity: .sensitive),
        1701: Info(name: "Business category", group: "Places"),
        1800: Info(name: "Public event", group: "Places", sensitivity: .sensitive),
        1801: Info(name: "Performer", group: "Places", sensitivity: .sensitive),
        1802: Info(name: "Event category", group: "Places"),
        1803: Info(name: "Event category synonym", group: "Places"),
        2000: Info(name: "Favourite", group: "Library", sensitivity: .low),
        2100: Info(name: "File name", group: "Library", reveal: true, sensitivity: .personal),
        2200: Info(name: "Saved from app", group: "Library"),
        2300: Info(name: "Camera", group: "Media"),
        2400: Info(name: "Shared library", group: "Library", sensitivity: .low),
        2401: Info(name: "Personal library", group: "Library", sensitivity: .low),
        2500: Info(name: "Audio class", group: "Content"),
        2501: Info(name: "Audio class synonym", group: "Content"),
        2600: Info(name: "Human action", group: "Content"),
        2601: Info(name: "Human action synonym", group: "Content"),
        2700: Info(name: "Sticker category", group: "Content", sensitivity: .low),
        2800: Info(name: "Utility class", group: "Content"),
    ]

    static func info(_ code: Int, backend: SearchBackend) -> Info {
        switch backend {
        case .leo:
            return leo[code] ?? Info(name: "Category \(code)", group: "Other")
        case .psi:
            if let i = psi[code] { return i }
            if (1900...1999).contains(code) { return Info(name: "Media type", group: "Media", sensitivity: .low) }
            return Info(name: "Category \(code)", group: "Other")
        }
    }
}

enum SearchBackend: String, Sendable, Hashable, CaseIterable, Identifiable {
    case leo, psi
    var id: String { rawValue }
    var title: String {
        switch self {
        case .leo: return "Photos.sqlite (current index)"
        case .psi: return "psi.sqlite (legacy index)"
        }
    }
    /// Category codes that play the same role in both generations.
    var countryCode: Int { self == .leo ? 2160 : 12 }
    var stateCode: Int { self == .leo ? 2140 : 10 }
    var cityCode: Int { self == .leo ? 2090 : 5 }
    var neighbourhoodCode: Int { self == .leo ? 2070 : 3 }
    var streetCode: Int { self == .leo ? 2050 : 2 }
    var sceneCode: Int { self == .leo ? 4000 : 1500 }
    var ocrCode: Int { self == .leo ? 4120 : 1203 }
    var utilityCode: Int { self == .leo ? 4080 : 2800 }
    var documentCode: Int? { self == .leo ? 4130 : nil }
    var personCode: Int { self == .leo ? 3000 : 1300 }
    var businessCode: Int { self == .leo ? 2220 : 1700 }
    var cameraCode: Int { self == .leo ? 6000 : 2300 }
    var appCode: Int { self == .leo ? 8060 : 2200 }
}
