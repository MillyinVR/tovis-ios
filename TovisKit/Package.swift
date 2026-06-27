// swift-tools-version: 6.0
import PackageDescription

// TovisKit — the reusable, UI-free core for the Tovis iOS app.
// Networking, secure token storage, and typed models that mirror the
// backend's /api/v1 wire contract (schema/api/tovis-api.schema.json in
// the tovis-app repo). Add this to the Xcode app as a LOCAL package.
let package = Package(
    name: "TovisKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TovisKit", targets: ["TovisKit"]),
    ],
    targets: [
        .target(name: "TovisKit"),
        .testTarget(name: "TovisKitTests", dependencies: ["TovisKit"]),
    ]
)