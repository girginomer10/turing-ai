// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "RetrievalBench",
  platforms: [.macOS(.v14)],
  dependencies: [.package(path: "../../../Packages/MosaicCore")],
  targets: [
    .executableTarget(
      name: "RetrievalBench",
      dependencies: [.product(name: "MosaicCore", package: "MosaicCore")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
