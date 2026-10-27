// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MosaicCore",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "MosaicCore", targets: ["MosaicCore"])
  ],
  dependencies: [
    .package(path: "../TuringVoice"),
    .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
  ],
  targets: [
    .target(
      name: "MosaicCore",
      dependencies: [
        .product(name: "Markdown", package: "swift-markdown"),
        .product(name: "TuringVoice", package: "TuringVoice"),
      ],
      resources: [.process("Resources")]
    ),
    .testTarget(
      name: "MosaicCoreTests",
      dependencies: ["MosaicCore"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
