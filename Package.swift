// swift-tools-version: 6.0
//
// BareMac — the Mac cleaner that shows its work.
//
// BareMacCore holds every scanner, model and the file engine. It has no UI imports
// and is fully unit-tested. The BareMac target is the SwiftUI app.

import PackageDescription

let package = Package(
    name: "BareMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BareMacCore", targets: ["BareMacCore"]),
        .executable(name: "BareMac", targets: ["BareMac"]),
    ],
    targets: [
        .target(
            name: "BareMacCore",
            path: "Sources/BareMacCore"
        ),
        .executableTarget(
            name: "BareMac",
            dependencies: ["BareMacCore"],
            path: "Sources/BareMac"
        ),
        .testTarget(
            name: "BareMacCoreTests",
            dependencies: ["BareMacCore"],
            path: "Tests/BareMacCoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
