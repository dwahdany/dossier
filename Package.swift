// swift-tools-version: 6.0
import PackageDescription

/// All targets use the Swift 5 language mode (no strict-concurrency churn), but code is
/// written with async/await and explicit confinement.
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

/// Feature modules: (target name, module id). Each gets a library target in
/// `Sources/<TargetName>` and a dev executable `dossier-dev-<id>` in `Sources/Dev/<id>`.
let featureModules: [(target: String, id: String)] = [
    ("GraphModule", "graph"),
    ("CommsModule", "comms"),
    ("ActivityModule", "activity"),
    ("EnvironmentModule", "environment"),
    ("ProfileModule", "profile"),
    ("PhotosModule", "photos"),
    ("MailSearchModule", "mailsearch"),
    ("BiomeModule", "biome"),
    ("RawModule", "raw"),
]

var targets: [Target] = [
    .target(
        name: "DossierCore",
        swiftSettings: swift5,
        linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .executableTarget(
        name: "DossierApp",
        dependencies: ["DossierCore"] + featureModules.map { .target(name: $0.target) },
        swiftSettings: swift5
    ),
]

for module in featureModules {
    targets.append(.target(name: module.target, dependencies: ["DossierCore"], swiftSettings: swift5))
    targets.append(.executableTarget(
        name: "dossier-dev-\(module.id)",
        dependencies: ["DossierCore", .target(name: module.target)],
        path: "Sources/Dev/\(module.id)",
        swiftSettings: swift5
    ))
}

let package = Package(
    name: "Dossier",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Dossier", targets: ["DossierApp"]),
        .library(name: "DossierCore", targets: ["DossierCore"]),
    ],
    targets: targets
)
