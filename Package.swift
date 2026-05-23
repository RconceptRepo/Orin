// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Orin",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Orin", targets: ["Orin"])
    ],
    targets: [
        .executableTarget(
            name: "Orin",
            path: "Sources/Orin"
        )
    ]
)
