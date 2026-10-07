// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Rosen",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Rosen", targets: ["Rosen"]),
    ],
    targets: [
        // Lógica pura (modelos, parser, cofre, comando ssh) — testável sem UI.
        .target(name: "RosenCore", path: "Sources/RosenCore"),
        // App SwiftUI.
        .executableTarget(
            name: "Rosen",
            dependencies: ["RosenCore"],
            path: "Sources/Rosen"
        ),
        .testTarget(
            name: "RosenCoreTests",
            dependencies: ["RosenCore"],
            path: "Tests/RosenCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
