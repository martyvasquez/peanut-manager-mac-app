// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LineupKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "LineupKit", targets: ["LineupKit"]),
        .library(name: "LineupAI", targets: ["LineupAI"]),
    ],
    targets: [
        // Pure domain logic: models, validator, repair, prompts, GameChanger parser. No UI, no network.
        .target(name: "LineupKit"),
        // OpenRouter client. Depends on LineupKit for the LLMClient protocol.
        .target(name: "LineupAI", dependencies: ["LineupKit"]),
        .testTarget(
            name: "LineupKitTests",
            dependencies: ["LineupKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
