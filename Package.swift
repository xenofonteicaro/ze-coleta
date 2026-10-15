// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZeColeta",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ColetaCore", targets: ["ColetaCore"]),
        .executable(name: "ZeColeta", targets: ["ZeColeta"])
    ],
    targets: [
        .target(name: "ColetaCore"),
        .executableTarget(name: "ZeColeta", dependencies: ["ColetaCore"]),
        .testTarget(name: "ColetaCoreTests", dependencies: ["ColetaCore"])
    ]
)
