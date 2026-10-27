// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TuringVoice", platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
  products: [.library(name: "TuringVoice", targets: ["TuringVoice"])],
  targets: [
    .target(name: "TuringVoice"),
    .testTarget(name: "TuringVoiceTests", dependencies: ["TuringVoice"]),
  ],
  swiftLanguageModes: [.v6])
