// swift-tools-version:5.9
import PackageDescription

// HopDriver — the THIN Apple platform driver: it composes a Hop node (libhop) + HopRuntime + the
// bearer packages this build wants, and runs the pump loop. It owns NO transport code and NO beacon
// code — just the wiring. The app depends on this + chooses which bearers to pull in.
let package = Package(
    name: "HopDriver",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HopDriver", targets: ["HopDriver"]),
    ],
    dependencies: [
        .package(path: "../../../sdk/wrappers/Hop"),
        .package(path: "../../../bearers/apple/HopBearerBle"),
        .package(path: "../../../bearers/apple/HopBearerLan"),
        .package(path: "../../../bearers/apple/HopBearerMultipeer"),
        .package(path: "../../../bearers/apple/HopBearerRelay"),
    ],
    targets: [
        .target(name: "HopDriver", dependencies: [
            .product(name: "Hop", package: "Hop"),
            .product(name: "HopBearerBle", package: "HopBearerBle"),
            .product(name: "HopBearerLan", package: "HopBearerLan"),
            .product(name: "HopBearerMultipeer", package: "HopBearerMultipeer"),
            .product(name: "HopBearerRelay", package: "HopBearerRelay"),
        ]),
    ]
)
