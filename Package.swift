// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mergeport",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Mergeport", targets: ["Mergeport"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "MergeportCore"),
        .executableTarget(
            name: "Mergeport",
            dependencies: ["MergeportCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle ships as a framework inside Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "MergeportCoreTests", dependencies: ["MergeportCore"])
    ]
)
