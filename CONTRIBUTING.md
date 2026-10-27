# Contributing

Thanks for taking a look. This is a personal project, so expect a small maintainer bandwidth, but issues and pull requests are welcome.

## Before you start

- Open an issue for anything larger than a small fix so the approach can be agreed first.
- Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/INTERNALS.md](docs/INTERNALS.md). Most non-obvious code exists to enforce a rule described there.

## Development setup

Apple platforms need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen); Android needs JDK 21 and the Android SDK. The [README](README.md#getting-started) has the build commands.

`Mosaic.xcodeproj` is generated. Edit `project.yml` and run `xcodegen generate`, then commit both.

## Rules the codebase follows

- **Never drop user data silently.** Messages are not truncated or deleted; anything omitted from a request shows up in its receipt.
- **Every provider request is bounded.** New request paths need an explicit size ceiling and a usage record.
- **Storage changes are additive.** SwiftData schemas are versioned (`MosaicSchemaV*`); Room schema JSON under `Apps/Android/data/schemas` is frozen once shipped. Add a new version and a migration; never edit an exported schema in place.
- **Keys never leave the keychain.** No provider credential may be written to the database, logs, backups, or test fixtures.
- **Identifiers stay.** Bundle IDs, Keychain service names, the `MosaicCore` package, and the `.mosaicbackup` format keep their original names for compatibility.

## Style

Swift follows `swift format` defaults (2 spaces, 100 columns) and Swift 6 strict concurrency. Kotlin uses 2-space indentation and imports rather than inline fully-qualified names. An `.editorconfig` is checked in.

## Tests

Run the package suite before opening a pull request:

```sh
swift test --package-path Packages/MosaicCore
```

Add or update tests next to the behaviour you change. CI runs the suite plus compile checks for macOS, iOS Simulator, and an Android debug build.

## Pull requests

Keep them focused. The PR template asks which platforms you touched and how you verified the change. Do not include signing material, team IDs, or personal identifiers.
