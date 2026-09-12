# Tactile localization and language packs

[简体中文](localization.zh-Hans.md)

Tactile uses extensible language packs. Each language is a self-contained
BCP-47 resource folder that the app discovers in its main bundle at launch, so
adding a language needs no Swift enum, list, or branch.

## Layout

```text
Tactile/Localization/
├── en.lproj/
│   ├── Localizable.strings
│   └── Localizable.stringsdict
└── zh-Hans.lproj/
    ├── Localizable.strings
    └── Localizable.stringsdict
```

Every shipped pack provides `Localizable.strings`. English has plural keys, so
every pack also provides a `Localizable.stringsdict` with the same plural keys.
Each pack names itself in its own language:

```text
"language.pack.display-name" = "English";
```

(`简体中文` for Simplified Chinese.) The name is never translated through
another pack: it is how the language picker labels the language.

`en` is the only key baseline. Every pack's ordinary keys and plural keys must
match English exactly, with no duplicate keys and no empty values. Lookups fall
back per key (selected pack, then English, then the caller's default, then the
key itself), so one missing translation never blanks the UI.

## Choosing the language

The choice is stored in UserDefaults under `languageSelection`:

```text
system
pack:<identifier>
```

`system` follows macOS; `pack:<identifier>` pins a pack. The choice is global:
it is not part of profiles, `SettingsSnapshot`, exported profile JSON, or the
per-app baseline. The resolved pack identifier only travels in `FeedbackConfig`
so hover captions can be localized. If a pinned pack is removed, the choice
normalizes to `pack:en`.

With `system`, Tactile asks Foundation the question AppKit asks for the app
bundle: `Bundle.preferredLocalizations(from:forPreferences:)` over the whole
preferred-language list. Tactile's own strings therefore match the system
panels, menus, and Sparkle windows around them. (macOS settles an app's
language at launch, so after the list changes while Tactile runs, the two can
differ until Tactile relaunches.) For example:

- `zh-Hans-CN`, `zh-CN`, and `zh-SG` use `zh-Hans`.
- `zh-Hant`, `zh-TW`, `zh-HK`, and `zh-MO` never borrow `zh-Hans`: the next
  language in the list decides, and English is the last resort.
- `[fr-FR, zh-Hans-CN, en-US]` uses `zh-Hans` until a French pack exists.
- `en-US` and `en-GB` use `en`.
- Regional fallbacks are macOS's call too: on current macOS, `fr-FR` uses an
  `fr-CA` pack when it is the only French one.
- Unicode extensions (for example `-u-ca-gregory`) are ignored for matching.

A pinned pack is not affected by system changes. With `system`, a system
locale change re-resolves the pack and refreshes the UI.

Times and dates follow the user's region settings, 24-hour clock included, not
the language pack's locale.

## Keys

Keys name stable UI meaning; never hard-code user-visible English or Chinese
text in Swift. Current namespaces:

```text
language.*
window.*
menu.*
onboarding.*
settings.<pane>.*
feedback.category.*
feedback.pattern.*
waveform.*
dialog.*
format.*
a11y.*
error.*
```

All app text goes through `Localizer`, including short SwiftUI labels, so the
per-key English fallback and the in-app choice always agree. Resolved text is
shown with `Text(verbatim:)` or control initializers that take a `String`, so it
is never localized twice. Keys built from enum cases come from the enum's key
property (for example `FeedbackCategory.nameLocalizationKey`); the state test
checks every case against every pack.

Format strings keep the English printf type of every argument. Positional
markers may reorder or repeat arguments: `%d %@` can become `%2$@ %1$d`, and a
translation may print `%1$@` twice, but `%1$@ %2$d` (a type swap) is rejected.
Star width and precision arguments are type-checked too.

Plurals use `.stringsdict`; never build `pulse/pulses` or `line/lines` in Swift.
Each plural key's `NSStringLocalizedFormatKey`, variable names, format keys,
plural categories, and placeholder signatures must be compatible with English.

## Adding a language

1. Create `<identifier>.lproj` with a BCP-47 name, for example `fr.lproj` or
   `pt-BR.lproj`.
2. Add `Localizable.strings`, plus `Localizable.stringsdict` for the plural
   keys.
3. Translate every English key and set `language.pack.display-name` to the
   language's own name.
4. Add the Xcode region to `knownRegions` in `Tactile.xcodeproj/project.pbxproj`.
   The filesystem-synchronized group picks up the `.lproj` automatically.
5. Run the validator and the full test script below.

Don't add Swift language lists, language branches, UserDefaults formats, or
matching rules. A new language is resources plus Xcode region metadata only.

## Verifying

From the repository root:

```bash
swift scripts/validate_localizations.swift
```

The validator scans every `.lproj` and checks `.strings` syntax, duplicate
keys, empty values, the English key set, display names, printf placeholders,
and `.stringsdict` plural structure. It checks each value as Foundation decodes
it at runtime, so an escape that would not show as written is reported. It also
compiles the production `LanguageIdentifierMatcher.swift` and runs a fixed
matching matrix. It exits non-zero on any problem.

The whole suite, including an unsigned Debug build, runs with:

```bash
bash scripts/test_localization.sh
```

It compiles the production `Localizer` against both the source resources and
the built app's resources (plurals, argument reordering, per-key fallback, pack
discovery), then links the real Debug module to check language state, system
notifications, removed-pack normalization, profile JSON, shortcut
compatibility, enum-derived keys, and that hover captions refresh without extra
haptics. It uses its own temporary bundle and UserDefaults suite, never starts
the feedback pipeline, and never touches your settings. Build products go under
the per-user temporary directory (`$TMPDIR`).

The validator's own fixtures run with:

```bash
swift scripts/validate_localizations.swift --self-test
```

The unsigned build is for automated checks only. To keep a local build's
Accessibility permission across rebuilds, use the
[stable local signing build](local-signing.md): `bash scripts/build_local_signed.sh`.

After a build, the app's resources contain:

```text
Tactile.app/Contents/Resources/en.lproj
Tactile.app/Contents/Resources/zh-Hans.lproj
```

## Scope and verbatim content

Language packs cover the native app: the menu bar menu, onboarding, settings,
sheets, panels, accessibility labels, dynamic errors, and hover captions. A
language switch refreshes open windows and menus immediately, without
restarting the feedback pipeline. The Chrome extension's own UI is outside this
runtime.

These stay verbatim: the names `Tactile`, `Coast`, `Chrome`, and
`Magic Trackpad`; URLs, bundle IDs, app names, user names, profile names, file
names, user input, and other apps' control titles. Never send them through a
key or localize them twice.

Danger detection matches English labels only for now, so the Chinese Playground
button reads "删除（Delete）" and the demo still plays the danger waveform.

Sparkle's update windows and other system-owned UI follow macOS's own language
choice. With `system` selected that is Tactile's language too; with a pinned
pack they can differ.
