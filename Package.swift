// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Pasteboard",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Pasteboard", targets: ["PasteMac"]),
               .executable(name: "PasteboardMCP", targets: ["PasteCLI"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "PasteCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "PasteCLI", dependencies: ["PasteCore"]),
        .executableTarget(name: "PasteMac", dependencies: ["PasteCore", "CSQLite"]),
        .testTarget(name: "PasteCoreTests", dependencies: ["PasteCore"])
    ]
)
