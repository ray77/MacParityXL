// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ParityKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ParityKit", targets: ["ParityKit"]),
    ],
    targets: [
        .target(name: "ParityKit"),
        .testTarget(
            name: "ParityKitTests",
            dependencies: ["ParityKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
