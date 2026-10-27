// swift-tools-version: 6.0

import PackageDescription

// MOSAIC_CORE_PATH lets the same harness run against another checkout of MosaicCore, e.g. a git
// worktree of an earlier commit, for before/after comparisons.
let corePath = Context.environment["MOSAIC_CORE_PATH"] ?? "../../../Packages/MosaicCore"

let package = Package(
  name: "MemoryBench",
  platforms: [.macOS(.v14)],
  dependencies: [.package(path: corePath)],
  targets: [
    .executableTarget(
      name: "MemoryBench",
      dependencies: [.product(name: "MosaicCore", package: "MosaicCore")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
