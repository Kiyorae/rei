// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Rei",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ReiLogging", targets: ["ReiLogging"]),
        .library(name: "ReiUI", targets: ["ReiUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Innei/MarkdownView.git", revision: "757b6fcc4b3095e84f4c0613f4b98147f49dcd09")
    ],
    targets: [
        .target(name: "ReiLogging"),

        // Domain model and storage. Knows nothing about any wire protocol.
        .target(name: "ReiCore"),

        // Transports: WebSocket server/client and a minimal HTTP/1.1 server,
        // all on Network.framework.
        .target(name: "ReiTransport", dependencies: ["ReiCore"]),

        // The protocol-neutral implementation contract shared by OneBot and Milky.
        .target(name: "ReiProtocol", dependencies: ["ReiCore", "ReiTransport", .target(name: "CSilk")]),

        // Peer protocol implementations.
        .target(name: "ReiOneBot", dependencies: ["ReiProtocol"]),
        .target(name: "ReiMilky", dependencies: ["ReiProtocol"]),

        // AppKit user interface.
        .target(
            name: "ReiUI",
            dependencies: [
                "ReiCore", "ReiProtocol", "ReiOneBot", "ReiMilky", "ReiLogging",
                .product(name: "MarkdownView", package: "MarkdownView"),
            ],
            resources: [.copy("Resources/Showcase"), .copy("Resources/Licenses")]
        ),

        .testTarget(
            name: "ReiTests",
            dependencies: [
                "ReiCore", "ReiTransport", "ReiProtocol", "ReiOneBot", "ReiMilky",
                "ReiLogging",
                .target(name: "ReiUI"),
            ]
        ),
        .target(
            name: "CSilk",
            exclude: ["LICENSE", "NOTICE.md"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("interface"), .headerSearchPath("src")]
        ),
    ]
)
