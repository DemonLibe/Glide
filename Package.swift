// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Glide",
    platforms: [.macOS(.v14)],
    targets: [
        // libmpv from Homebrew (`brew install mpv`): MKV, WebM and everything FFmpeg can read.
        .systemLibrary(
            name: "Cmpv",
            path: "Sources/Cmpv",
            pkgConfig: "mpv",
            providers: [.brew(["mpv"])]
        ),
        .executableTarget(
            name: "Glide",
            dependencies: ["Cmpv"],
            path: "Sources/Glide"
        ),
    ]
)
