// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConversationRules",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [
        .library(name: "ConversationRules", targets: ["ConversationRules"]),
        .library(name: "AssistantCore", targets: ["AssistantCore"]),
        .library(name: "LocalData", targets: ["LocalData"])
    ],
    targets: [
        .target(name: "ConversationRules"),
        .testTarget(name: "ConversationRulesTests", dependencies: ["ConversationRules"]),
        .target(name: "AssistantCore"),
        .target(name: "LocalData", dependencies: ["AssistantCore"]),
        .testTarget(name: "LocalDataTests", dependencies: ["LocalData", "AssistantCore"]),
        .target(name: "ProviderSettings", dependencies: ["AssistantCore"]),
        .testTarget(name: "ProviderSettingsTests", dependencies: ["ProviderSettings", "AssistantCore"]),
        .testTarget(name: "AssistantCoreTests", dependencies: ["AssistantCore"])
    ]
)
