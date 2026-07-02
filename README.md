# Tactile

Feel the interface, not just see it.

Tactile is a macOS menu bar utility that taps the Force Touch trackpad's haptic motor whenever your cursor passes over something clickable — in any app, system-wide. Built as an accessibility aid for people with visual impairments: instead of relying on the subtle hover color change most apps use, you feel a physical tick under your finger when the cursor reaches a button, link, checkbox, menu, or tab.

## How it works

Tactile uses the same macOS Accessibility tree that VoiceOver reads. A global mouse monitor watches cursor movement, a background hit-tester asks the system what element is under the cursor, and when the cursor enters a clickable element, the trackpad ticks once.

The pipeline is fully event-driven: when the mouse is still, Tactile does nothing at all (0% CPU). While moving, sampling is throttled and cached per-element, so continuous use stays under a few percent of one core.

## Features

- **Works everywhere** — native apps, browsers, Electron apps; anything that exposes an accessibility tree.
- **Per-element triggers** — choose which kinds of elements tick (buttons, links, checkboxes & switches, menus, tabs, sliders, text fields, and custom pressable controls), each with its own haptic pattern (Light / Standard / Firm).
- **Per-app exclusions** — silence Tactile in games, drawing canvases, or anything that gets noisy.
- **Rate limiting** — set a minimum time between ticks so sweeping across a toolbar doesn't buzz.
- **Dwell delay** — optionally require the cursor to rest on an element before it ticks; helps with steady targeting and reduces noise.
- **Click sound fallback** — an optional quiet click for external-mouse users, who can't feel trackpad haptics.
- **Pause & launch at login** — one-click 15-minute pause from the menu bar; starts with your Mac if you want it to.

## Requirements

- A Mac with a Force Touch trackpad (built-in on MacBook Pro/Air, or a Magic Trackpad). Haptics are felt while a finger rests on the trackpad — which is naturally the case while using it. External mice can use the click sound instead.
- macOS 14.6 or later.
- The **Accessibility** permission (System Settings → Privacy & Security → Accessibility). Tactile walks you through this on first launch. Everything runs on-device; Tactile only inspects the *type* of element under the cursor, never your content.

## Building

Open `Tactile.xcodeproj` in Xcode and run. The app is unsandboxed (the system-wide Accessibility API requires it), so it is not App Store distributable; distribute with Developer ID signing and notarization.

## Privacy

Tactile makes no network connections, collects nothing, and stores only its own settings. The Accessibility permission is used solely to identify the kind of UI element under the cursor.

## License

See [LICENSE](LICENSE).
