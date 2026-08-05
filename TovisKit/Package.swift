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
        // The Objective-C exception catcher. Swift cannot `@catch`, and every
        // AVFoundation device write validates by raising — so the app's only
        // way to survive one is to cross into ObjC for the write. Kept as its
        // own tiny target because it is the ONE place in the codebase allowed
        // to contain `@try`. See TovisObjCException.h.
        .target(name: "TovisObjC"),
        .target(name: "TovisKit", dependencies: ["TovisObjC"]),
        .testTarget(
            name: "TovisKitTests",
            dependencies: ["TovisKit"],
            // The Fixtures/*.json are the SINGLE source of wire-shape truth:
            // decoded here AND validated against the backend schema by
            // scripts/contract/validate-fixtures.mjs.
            resources: [.process("Fixtures")]
        ),
    ]
)