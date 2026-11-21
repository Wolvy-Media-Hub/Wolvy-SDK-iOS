// swift-tools-version:5.9
// The Wolvy iOS SDK: plays Wolvy's FairPlay-protected video in your own app.
import PackageDescription

let package = Package(
    name: "WolvyPlayer",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "WolvyPlayer", targets: ["WolvyPlayer"]),
    ],
    targets: [
        .target(name: "WolvyPlayer", path: "Sources/WolvyPlayer"),
        .testTarget(name: "WolvyPlayerTests", dependencies: ["WolvyPlayer"], path: "Tests/WolvyPlayerTests"),
    ]
)
