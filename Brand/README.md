# Turing AI identity

The public product name is **Turing AI** on iPhone, Apple Watch, Mac, Android, share sheets, permission prompts, notifications, recovery screens, and exported backup filenames.

`TuringIcon.png` is the 1024x1024 master. App asset catalogs contain opaque PNG exports at their required sizes; `TuringBrand` in MosaicCore's resource bundle supplies the same mark inside the app. The dark full-bleed square keeps the monogram safely inside the circular Watch mask; the system applies platform corner masking. Scale exports with `sips`, and do not substitute a different symbol on one platform. Inspect any replacement icon at Watch size before shipping it.

The icon was generated from the prompt below and then packaged at the required sizes; no external logo or reference image was used.

## Generation prompt

Use case: logo-brand. Create one finished premium app icon for Turing AI, a native personal AI conversation and voice app for iPhone, Mac, and Apple Watch. Square 1024x1024 full-bleed opaque canvas. Single bold, exceptionally simple abstract T monogram formed by one broad horizontal ribbon and a centered vertical ribbon which gently curves at the bottom, suggesting a continuous conversation and a Turing tape. Warm ivory monogram on a nearly black deep ink background, with a very restrained pale cool blue edge accent within the mark. Calm, sophisticated, distinctive, timeless editorial technology identity. Strong silhouette, optically centered, generous 22 percent clear space on all sides so it survives circular Watch cropping and reads at 24 pixels. Flat clean sharply defined graphic shapes, subtle tonal color only. No words, no small text, no AI lettering, no robots, no brain, no sparkle, no circuitry, no knot, no ChatGPT or other existing logo resemblance. No border, no pre-rounded canvas corners, no outer frame, no mockup, no perspective, no shadows or glow. Artwork fills the square edge to edge with the dark opaque background.

## Compatibility boundary

The product was renamed from Mosaic to Turing AI. Bundle IDs, App Group/CloudKit containers, Keychain services, storage directories, SwiftData schema identities, saved preference keys, protocol version identifiers, Swift/Kotlin type names and the `.mosaicbackup` extension keep their Mosaic identifiers: they are compatibility identifiers for existing installations and are not part of visual branding. New backup filenames and file-type descriptions use Turing AI while old backups remain readable. Historical user-authored messages are never rewritten.
