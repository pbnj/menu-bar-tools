// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MenuBarTools",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "GitHubAttention", targets: ["GitHubAttention"]),
    .executable(name: "AgentStatus", targets: ["AgentStatus"]),
  ],
  targets: [
    .target(name: "MenuBarCore"),
    .target(name: "MenuBarUI", dependencies: ["MenuBarCore"]),
    .executableTarget(name: "GitHubAttention", dependencies: ["MenuBarCore", "MenuBarUI"]),
    .executableTarget(name: "AgentStatus", dependencies: ["MenuBarCore", "MenuBarUI"]),
    .testTarget(name: "MenuBarCoreTests", dependencies: ["MenuBarCore"]),
  ]
)
