// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CicloKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // Lógica pura: bytes ↔ structs, física, entrenos. Sin CoreBluetooth.
        .library(name: "CicloKit", targets: ["CicloKit"]),
        // Capa fina de CoreBluetooth que usa CicloKit.
        .library(name: "CicloBluetooth", targets: ["CicloBluetooth"]),
        // Servidor de red OpenBikeControl (Bonjour + TCP) para mandar los mandos a otras apps.
        .library(name: "CicloNetwork", targets: ["CicloNetwork"]),
    ],
    targets: [
        .target(name: "CicloKit"),
        .target(name: "CicloBluetooth", dependencies: ["CicloKit"]),
        .target(name: "CicloNetwork", dependencies: ["CicloKit"]),
        .testTarget(name: "CicloKitTests", dependencies: ["CicloKit"]),
    ]
)
