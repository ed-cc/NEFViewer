// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NEFViewerCore",
    // No platform restriction so Foundation-only code compiles on Linux CI.
    // AppKit-dependent types are guarded with #if canImport(AppKit).
    products: [
        .library(name: "NEFViewerCore", targets: ["NEFViewerCore"]),
    ],
    targets: [
        .target(
            name: "NEFViewerCore",
            path: "Sources/NEFViewerCore"
        ),
        .testTarget(
            name: "NEFViewerCoreTests",
            dependencies: ["NEFViewerCore"],
            path: "Tests/NEFViewerCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
