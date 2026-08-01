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
        .target(name: "ListtenCore"),
        .executableTarget(name: "listten", dependencies: ["ListtenCore"]),
        .testTarget(name: "ListtenCoreTests", dependencies: ["ListtenCore"]),
    ]
)
