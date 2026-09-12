#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
TACTILE_REPOSITORY=$(pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
TACTILE_SIGNED_BUILD_ROOT="${TACTILE_SIGNED_BUILD_ROOT:-$TACTILE_REPOSITORY/build/local-signed}"

# Keep machine-specific certificate names, hashes, and team IDs out of source
# control. Only identities backed by an accessible private key are eligible.
TACTILE_VALID_IDENTITIES=$(security find-identity -v -p codesigning)
TACTILE_IDENTITY_PATTERN='^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"([^"]+)"'
TACTILE_MATCHING_HASHES=()
TACTILE_MATCHING_NAMES=()
while IFS= read -r TACTILE_IDENTITY_LINE; do
    if [[ "$TACTILE_IDENTITY_LINE" =~ $TACTILE_IDENTITY_PATTERN ]]; then
        TACTILE_IDENTITY_HASH="${BASH_REMATCH[1]}"
        TACTILE_IDENTITY_NAME="${BASH_REMATCH[2]}"
        if [[ -n "${TACTILE_SIGNING_IDENTITY:-}" ]]; then
            if [[ "$TACTILE_SIGNING_IDENTITY" != "$TACTILE_IDENTITY_HASH" &&
                  "$TACTILE_SIGNING_IDENTITY" != "$TACTILE_IDENTITY_NAME" ]]; then
                continue
            fi
        elif [[ "$TACTILE_IDENTITY_NAME" != "Apple Development: "* ]]; then
            continue
        fi
        TACTILE_MATCHING_HASHES+=("$TACTILE_IDENTITY_HASH")
        TACTILE_MATCHING_NAMES+=("$TACTILE_IDENTITY_NAME")
    fi
done <<< "$TACTILE_VALID_IDENTITIES"

if [[ ${#TACTILE_MATCHING_HASHES[@]} -ne 1 ]]; then
    printf '%s\n' 'A single valid Apple Development identity is required.' >&2
    printf '%s\n' 'If several identities exist, set TACTILE_SIGNING_IDENTITY to the full certificate name or SHA-1 from:' >&2
    printf '%s\n' '  security find-identity -v -p codesigning' >&2
    printf '%s\n' 'No unsigned or ad-hoc fallback will be built.' >&2
    exit 1
fi

TACTILE_SIGNING_HASH="${TACTILE_MATCHING_HASHES[0]}"
TACTILE_SIGNING_NAME="${TACTILE_MATCHING_NAMES[0]}"
printf 'Signing local Debug build with: %s\n' "$TACTILE_SIGNING_NAME"

# Manual signing uses the selected certificate directly. Clear the upstream
# team for this invocation only; the shared project/release settings stay intact.
# No provisioning updates, certificate creation, or keychain changes are made.
xcodebuild -quiet -project Tactile.xcodeproj -scheme Tactile \
    -configuration Debug -sdk macosx -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$TACTILE_SIGNED_BUILD_ROOT/DerivedData" \
    -clonedSourcePackagesDirPath "$TACTILE_SIGNED_BUILD_ROOT/SourcePackages" \
    -packageCachePath "$TACTILE_SIGNED_BUILD_ROOT/PackageCache" \
    -disablePackageRepositoryCache \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$TACTILE_SIGNING_HASH" \
    DEVELOPMENT_TEAM= \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES build

TACTILE_SIGNED_APP="$TACTILE_SIGNED_BUILD_ROOT/DerivedData/Build/Products/Debug/Tactile.app"
codesign --verify --deep --strict "$TACTILE_SIGNED_APP"
TACTILE_SIGNATURE=$(codesign -d --verbose=4 "$TACTILE_SIGNED_APP" 2>&1)
if [[ "$TACTILE_SIGNATURE" == *"Signature=adhoc"* ||
      "$TACTILE_SIGNATURE" != *"Authority="* ]]; then
    printf '%s\n' 'The resulting app is not certificate-signed.' >&2
    exit 1
fi

printf '\nCertificate-signed app: %s\n' "$TACTILE_SIGNED_APP"
printf '%s\n' 'Keep using this path and certificate for subsequent builds.'
printf '%s\n' 'The first transition from an ad-hoc build may require one new Accessibility approval.'
printf '%s\n' 'This development build is not a notarized public release.'
