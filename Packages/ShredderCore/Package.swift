// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ShredderCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ShredderCore", targets: ["ShredderCore"]),
    ],
    targets: [
        .target(
            name: "ShredderCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "ShredderCoreTests",
            dependencies: ["ShredderCore"]
        ),
    ]
)
