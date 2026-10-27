#!/bin/zsh

set -euo pipefail

script_directory="${0:A:h}"
repository_root="${script_directory:h}"
derived_data_path="${MOSAIC_DERIVED_DATA_PATH:-/tmp/mosaic-macos-local}"
app_path="${derived_data_path}/Build/Products/Debug/Mosaic-macOS.app"
mosaic_process_pattern='(^|/).*Mosaic-macOS[.]app/Contents/MacOS/Mosaic-macOS([[:space:]]|$)'

refuse_if_mosaic_is_running() {
  if /usr/bin/pgrep -f "${mosaic_process_pattern}" >/dev/null 2>&1; then
    print -u2 "Another Mosaic app is running. Quit every local Mosaic copy before continuing."
    return 1
  else
    local pgrep_status=$?
    if (( pgrep_status != 1 )); then
      print -u2 "Could not verify whether another Mosaic app is running (pgrep ${pgrep_status})."
      return "${pgrep_status}"
    fi
  fi
}

cd "${repository_root}"

refuse_if_mosaic_is_running
xcodegen generate --spec project.yml
xcodebuild \
  -project Mosaic.xcodeproj \
  -scheme Mosaic-macOS \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${derived_data_path}" \
  CODE_SIGNING_ALLOWED=NO \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MOSAIC_LOCAL_ADHOC_KEYCHAIN' \
  build \
  -quiet

refuse_if_mosaic_is_running
if [[ ! -x "${app_path}/Contents/MacOS/Mosaic-macOS" ]]; then
  print -u2 "The expected Mosaic executable was not produced at ${app_path}."
  exit 1
fi
built_bundle_identifier=$(
  /usr/bin/plutil -extract CFBundleIdentifier raw "${app_path}/Contents/Info.plist"
)
if [[ "${built_bundle_identifier}" != "com.omergirgin.mosaic.macos" ]]; then
  print -u2 "Refusing to sign an unexpected bundle identifier: ${built_bundle_identifier}"
  exit 1
fi

# This is a local test signature, not a Developer ID or App Store distribution signature. It
# applies the checked-in sandbox entitlements so double-click testing matches the app target. The
# explicit compilation condition permits a local-only fallback to the traditional macOS Keychain;
# Release builds without a valid Apple application identifier continue to fail closed.
/usr/bin/codesign \
  --force \
  --deep \
  --sign - \
  --entitlements Apps/macOS/Mosaic-macOS.entitlements \
  --timestamp=none \
  "${app_path}"
/usr/bin/codesign --verify --deep --strict "${app_path}"

refuse_if_mosaic_is_running
/usr/bin/open "${app_path}"
print "Opened ${app_path}"
