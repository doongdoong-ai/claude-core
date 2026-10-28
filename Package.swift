// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DoongdoongClaude",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DoongdoongClaude", targets: ["DoongdoongClaude"])],
    dependencies: [.package(url: "https://github.com/doongdoong-ai/codex-core.git", exact: "0.3.0")],
    targets: [.target(name: "DoongdoongClaude", dependencies: [.product(name: "DoongdoongAI", package: "codex-core")]),
              .testTarget(name: "DoongdoongClaudeTests", dependencies: ["DoongdoongClaude", .product(name: "DoongdoongAI", package: "codex-core")])],
    swiftLanguageModes: [.v5]
)
