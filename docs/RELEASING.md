# Releasing

How to produce a signed iOS or macOS archive and upload it to TestFlight. Nothing here is account-specific: no Apple Team ID is checked in. Export `DEVELOPMENT_TEAM=<team id>` in your shell and the commands below pass it to `xcodebuild`.

## Before archiving

1. Bump `CURRENT_PROJECT_VERSION` in `project.yml` and keep `MARKETING_VERSION` consistent with the App Store Connect record. All three Apple targets (main app, Watch, Share Extension) must report the same version and build.
2. Regenerate the Xcode project: `xcodegen generate --spec project.yml`.
3. Run the package tests and build the Simulator app:

   ```sh
   swift test --package-path Packages/MosaicCore
   swift test --package-path Packages/TuringVoice
   xcodebuild -project Mosaic.xcodeproj -scheme Mosaic-iOS -destination 'generic/platform=iOS Simulator' build
   ```

4. Visually check any UI the release touches in the Simulator (light/dark, larger Dynamic Type). Use a signed Simulator build: `CODE_SIGNING_ALLOWED=NO` makes real Keychain operations fail even though the UI launches.

## Archive

```sh
xcodebuild -project Mosaic.xcodeproj -scheme Mosaic-iOS \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/release -archivePath build/Turing.xcarchive \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" -allowProvisioningUpdates archive
```

Use `-scheme Mosaic-macOS` and `-destination 'generic/platform=macOS'` for the Mac app. The iOS archive embeds the Watch app and the Share Extension. Verify the archive with `codesign --verify --deep --strict` on the embedded app bundle and confirm that every target reports the expected version.

Provisioning is automatic. If `xcodebuild` reports "No Accounts" or a missing App Group / iCloud entitlement, open the project in Xcode once so Signing & Capabilities downloads the managed profiles; do not remove entitlements or change the team to work around it. The Share Extension has only the App Group entitlement, not the main app's CloudKit or Keychain access.

## Export and upload

Create an export options plist with `method: app-store-connect`, `signingStyle: automatic`, `teamID: $DEVELOPMENT_TEAM`, `uploadSymbols: true` and `manageAppVersionAndBuildNumber: false`. Export first to inspect the package, then upload:

```sh
xcodebuild -exportArchive -archivePath build/Turing.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export    # destination: export
xcodebuild -exportArchive -archivePath build/Turing.xcarchive \
  -exportOptionsPlist ExportOptions.plist -destination upload           # destination: upload
```

An app record for the exact bundle identifier must already exist in App Store Connect; the command-line upload cannot create one. The command-line upload can also fail with `Failed to Use Accounts` when Xcode itself has a valid session; in that case use Xcode Organizer, Distribute App, then TestFlight Internal Only (or App Store Connect for an external group).

After upload, wait for Apple processing to finish, then add the build to the intended TestFlight group. Upload success and TestFlight availability are separate checks; installation on a physical device is a third.

## Keep out of Git

Signed archives, exported IPAs, provisioning profiles, export options containing a team ID, and distribution logs. Distribution logs can contain account and session information; never publish them raw.

## Encryption metadata

`ITSAppUsesNonExemptEncryption` is false. The app uses Apple's URLSession transport, Keychain storage and CryptoKit SHA-256 hashes; it does not bundle or implement a separate encryption algorithm. Reassess this value if encryption dependencies change. See Apple's [encryption export guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations).

## Android

Android release builds are covered in [ANDROID.md](ANDROID.md): `./gradlew :app:assembleRelease` with a release keystore referenced from a properties file outside Git.
