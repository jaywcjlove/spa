// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "spa",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "spa", targets: ["spa"])
    ],
    targets: [
        .executableTarget(name: "spa")
    ]
)
