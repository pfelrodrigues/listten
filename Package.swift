// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Listten",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ListtenCore", targets: ["ListtenCore"]),
        .executable(name: "listten", targets: ["listten"]),
    ],
    targets: [
        .target(name: "ListtenCore", swiftSettings: strict),
        .executableTarget(name: "listten", dependencies: ["ListtenCore"], swiftSettings: strict),
        .testTarget(name: "ListtenCoreTests", dependencies: ["ListtenCore"], swiftSettings: strict),
    ]
)

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]
