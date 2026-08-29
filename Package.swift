// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Limitly",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LimitlyCore", targets: ["LimitlyCore"]),
        .executable(name: "LimitlyApp", targets: ["LimitlyApp"])
    ],
    targets: [
        .target(name: "LimitlyCore"),
        .executableTarget(
            name: "LimitlyApp",
            dependencies: ["LimitlyCore"],
            exclude: ["Info.plist", "Resources"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/LimitlyApp/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "LimitlyCoreTests",
            dependencies: ["LimitlyCore"],
            resources: [.process("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v5]
)
