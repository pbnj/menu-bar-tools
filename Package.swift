// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MenuBarTools",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "GitHubAttention", targets: ["GitHubAttention"]),
    .executable(name: "ClaudeStatus", targets: ["ClaudeStatus"]),
  ],
  targets: [
    .target(name: "MenuBarCore"),
    .target(name: "MenuBarUI", dependencies: ["MenuBarCore"]),
    .executableTarget(name: "GitHubAttention", dependencies: ["MenuBarCore", "MenuBarUI"]),
    .executableTarget(name: "ClaudeStatus", dependencies: ["MenuBarCore", "MenuBarUI"]),
    .testTarget(name: "MenuBarCoreTests", dependencies: ["MenuBarCore"]),
  ]
)
