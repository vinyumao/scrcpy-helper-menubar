// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScrcpyHelper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ScrcpyHelperCore", targets: ["ScrcpyHelperCore"])
    ],
    targets: [
        .target(
            name: "ScrcpyHelperCore",
            path: "Sources/ScrcpyHelperCore"
        ),
        .testTarget(
            name: "ScrcpyHelperCoreTests",
            dependencies: ["ScrcpyHelperCore"],
            path: "Tests/ScrcpyHelperCoreTests"
        )
    ]
)
