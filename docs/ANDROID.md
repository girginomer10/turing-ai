# Turing AI for Android

Native Kotlin/Jetpack Compose port of the iOS app, in `Apps/Android`. Application ID
`com.omergirgin.mosaic` (same as the iOS bundle ID); product name Turing AI. Feature behavior,
copy and limits follow the Swift sources in `Packages/MosaicCore`; the docs in this folder remain
the product reference for both platforms.

## Modules

```text
:app   Compose UI (Material 3), activities, share target, OAuth redirect, voice capture
:data  Room (main + rebuildable vector index), Keystore secrets, DataStore settings,
       repositories, ChatEngine, WorkManager tasks, backup, connections, documents/OCR
:core  Pure Kotlin: provider catalog and bundled model/price JSON, HTTP/SSE/WebSocket
       clients, context planning, compaction, retrieval, memory rules, backup codec
```

`DataContainer.create` wires the data layer; screens read it through `LocalAppContainer`.

## Build

Requires JDK 21 and the Android SDK (platform 37, build-tools 37). With a Homebrew JDK:

```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
cd Apps/Android
./gradlew :app:assembleDebug
./gradlew :app:assembleRelease
```

Release builds are R8-minified and split per ABI; phones use `app-arm64-v8a-release.apk`.
Signing reads `~/.android/turing-release.properties` (or the path in `TURING_SIGNING_PROPERTIES`)
pointing at a release keystore such as `~/.android/turing-release.jks`. Both live outside Git;
losing the keystore prevents in-place updates of installed builds. Without the properties file,
release APKs are unsigned.

## Room schema policy

Exported schemas live in `data/schemas`. Every schema version that has reached a device is frozen
(v1 through v3 have shipped). Never edit an exported JSON; add entities, bump `version`, and add a
migration (`AutoMigration` for additive changes). Builds regenerate the current version's JSON, so
restore it from Git before bumping.

## Platform differences

- Keys: Android Keystore AES-256-GCM, bound to adapter + endpoint (GCM associated data).
- Scheduled prompts run in the background through WorkManager (iOS only reminds).
- OCR: ML Kit bundled Latin recognizer, on-device; its usage-metrics upload backend is removed
  from the merged manifest. Keep the R8 rule for ML Kit component registrars.
- Device connections: Android Calendar and Contacts providers. No Reminders equivalent.
- Not on Android: iCloud sync, Watch app, Google connections (no Android OAuth client yet),
  Microsoft/Dropbox sign-in (developer registration pending on both platforms).
- Claude 5 and gpt-6 models are treated as photo-capable and Claude 5 web search is offered;
  the iOS heuristics predate those models.
