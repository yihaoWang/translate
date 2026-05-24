// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacLiveTranslator",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacLiveTranslator", targets: ["MacLiveTranslator"])
    ],
    targets: [
        .executableTarget(
            name: "MacLiveTranslator",
            path: "Sources/MacLiveTranslator"
        )
    ]
)
