// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LumaRing",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LumaRing", targets: ["LumaRing"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [
        .target(name: "TrackpadInput", linkerSettings: [.linkedFramework("CoreFoundation")]),
        .target(name: "LumaRingCore"),
        .executableTarget(name: "LumaRing", dependencies: ["LumaRingCore", "TrackpadInput", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ScreenCaptureKit"),
                                           .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "LumaRingCoreTests", dependencies: ["LumaRingCore"]),
        .testTarget(name: "LumaRingAppTests", dependencies: ["LumaRing", "TrackpadInput"])
    ]
)
