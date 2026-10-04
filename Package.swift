// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "nfs.swift",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1)],
    products: [
        .library(name: "NFS", targets: ["NFS"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.98.0")
    ],
    targets: [
        .target(
            name: "NFS",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio")
            ]
        ),
        .testTarget(
            name: "NFSTests",
            dependencies: [
                "NFS",
                .product(name: "NIOEmbedded", package: "swift-nio")
            ]
        )
    ]
)
