# Stable local code signing

The shared Xcode project already enables automatic signing for the upstream
release team. The unsigned localization test workflow deliberately overrides
that setting, so its Debug app is suitable for automated checks but not for
keeping macOS Accessibility approval across rebuilds.

For day-to-day local use, build with an existing certificate:

```bash
bash scripts/build_local_signed.sh
```

The script automatically selects a single valid Apple Development identity
from the keychain. It refuses to fall back to ad-hoc signing. If there are
multiple identities, choose one explicitly:

```bash
security find-identity -v -p codesigning
TACTILE_SIGNING_IDENTITY="<full certificate name or SHA-1>" \
  bash scripts/build_local_signed.sh
```

The certificate and its private key must already be installed and accessible.
The script does not create certificates, change keychain permissions, reset
macOS privacy permissions, or register an app with a developer account. It
does not store personal certificate names, hashes, or team IDs in the project.
Xcode may request permission to use the signing key.

The app is written to a fixed, git-ignored path:

```text
build/local-signed/DerivedData/Build/Products/Debug/Tactile.app
```

Launch it from the repository root:

```bash
open -n build/local-signed/DerivedData/Build/Products/Debug/Tactile.app
```

Use the same path and certificate for future builds. The first move from the
unsigned app to the signed app is a new code identity and may need one new
Accessibility approval. Certificate replacement, revoked permissions, or a
different installed copy can still require reauthorization; this does not
promise permanent permission. Avoid alternating between the unsigned test app,
this signed app, and another installed Tactile with the same bundle identifier.

This is a local development signature, not Developer ID distribution or Apple
notarization. Public releases must continue to use the upstream release team
and its release process. The script only overrides signing for its own build
invocation and leaves the shared project/release settings unchanged.

`TACTILE_SIGNED_BUILD_ROOT` can override the output root. Use an absolute,
stable path if overriding it. Keep certificate files, private keys, and built
apps out of version control.
