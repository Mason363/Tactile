# Releasing

Automatic updates use Sparkle and are driven by
[`appcast.xml`](../appcast.xml) at the repo root (the feed URL is set in
`Info.plist` → `SUFeedURL`). One-time setup, then per-release steps:

**One time: signing keys**

1. Run Sparkle's `generate_keys` (bundled with the Sparkle package /
   [release tools](https://github.com/sparkle-project/Sparkle/releases)). It
   stores a private key in your login Keychain and prints a public key.
2. Paste that public key into `Info.plist` → `SUPublicEDKey`, and commit.

Ship the public key in a release that keeps the previous Apple code-signing
identity. Existing installations do not trust a newly added Sparkle key until
they have installed it once. If the Apple code-signing identity must change at
the same time, first publish a bridge update signed with the old identity and
containing the new public key. Add `sparkle:minimumAutoupdateVersion` to the
later update so older builds install the bridge first.

**Each release**

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the project.
2. Archive, export with Developer ID, **notarize**, and zip the `.app`.
3. Sign the zip: `sign_update Tactile-x.y.z.zip` → copies an `edSignature`.
4. Add an `<item>` to `appcast.xml` with `<enclosure url="…" length="…"
   sparkle:edSignature="…"/>` pointing at the zip on the GitHub release, bump
   `sparkle:version`/`shortVersionString`, and push.

Users then get the update in-app via **Check for Updates…** or the background
check.
