// swift-tools-version: 6.0

import PackageDescription

// MOSAIC_CORE_PATH lets the harness run against another checkout of MosaicCore (same convention as
// benchmarks/memory/Bench).
let corePath = Context.environment["MOSAIC_CORE_PATH"] ?? "../../../Packages/MosaicCore"

let package = Package(
  name: "MemoryValidate",
  platforms: [.macOS(.v14)],
  dependencies: [.package(path: corePath)],
  targets: [
    .executableTarget(
      name: "MemoryValidate",
      dependencies: [.product(name: "MosaicCore", package: "MosaicCore")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
