#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
# Everything lives under the per-user temporary directory, so no other account
# on the Mac can reach the build tree or the Debug dylib the state test loads.
TACTILE_TMP="${TMPDIR:-/tmp}"
TACTILE_BUILD="${TACTILE_BUILD:-${TACTILE_TMP%/}/tactile-localization-build}"
TACTILE_PRODUCTS="$TACTILE_BUILD/DerivedData/Build/Products/Debug"
TACTILE_TEST_OUTPUT=$(mktemp -d "${TACTILE_TMP%/}/tactile-localization-tests.XXXXXX")
trap 'rm -rf "$TACTILE_TEST_OUTPUT"' EXIT

swift scripts/validate_localizations.swift
swift scripts/validate_localizations.swift --self-test
xcodebuild -quiet -project Tactile.xcodeproj -scheme Tactile \
  -configuration Debug -sdk macosx -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$TACTILE_BUILD/DerivedData" \
  -clonedSourcePackagesDirPath "$TACTILE_BUILD/SourcePackages" \
  -packageCachePath "$TACTILE_BUILD/PackageCache" -disablePackageRepositoryCache \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

xcrun swiftc -module-cache-path "$TACTILE_BUILD/ModuleCache" \
  Tactile/Localization/LanguageIdentifierMatcher.swift \
  Tactile/Localization/LanguagePack.swift scripts/test_localization_runtime.swift \
  -o "$TACTILE_TEST_OUTPUT/runtime"
"$TACTILE_TEST_OUTPUT/runtime"
"$TACTILE_TEST_OUTPUT/runtime" "$TACTILE_PRODUCTS/Tactile.app/Contents/Resources"

xcrun swiftc -parse-as-library -module-cache-path "$TACTILE_BUILD/ModuleCache" \
  -I "$TACTILE_PRODUCTS" -F "$TACTILE_PRODUCTS" \
  -Xlinker -rpath -Xlinker "$TACTILE_PRODUCTS" \
  -Xlinker -rpath -Xlinker "$TACTILE_PRODUCTS/Tactile.app/Contents/MacOS" \
  scripts/test_localization_state.swift \
  "$TACTILE_PRODUCTS/Tactile.app/Contents/MacOS/Tactile.debug.dylib" \
  -o "$TACTILE_TEST_OUTPUT/state"
"$TACTILE_TEST_OUTPUT/state" "$TACTILE_PRODUCTS/Tactile.app"
printf '%s\n' 'Localization checks passed.'
