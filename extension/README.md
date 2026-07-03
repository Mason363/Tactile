# Tactile Browser Bridge (Chrome)

Reports the clickable element under the cursor from the **real DOM**, so web
controls that never reach macOS accessibility, `<div>`/`<span>` buttons with a
click handler and `cursor: pointer` but no ARIA role, can still be felt by
[Tactile](../). The accessibility path stays the universal fallback for every
other browser and app; while Chrome is frontmost and the pointer is over page
content, Tactile listens to this extension instead.

## Load it (development)

1. Open `chrome://extensions`, enable **Developer mode** (top right).
2. **Load unpacked** → select this `extension/` folder.
3. Confirm the extension ID is `fnbpgacidfliigibfomikmdgbblccmie`. It is pinned
   by the `key` in `manifest.json`, so it stays constant across reloads and
   keeps Tactile's native-messaging manifest valid.

## Connect it to Tactile

In Tactile → Settings → **Apps**, turn on **Browser integration (Chrome)** and
approve the setup. That writes the native-messaging host manifest into
`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/`, pointing at
the helper bundled inside Tactile.app. No extra macOS permission is needed for
this path, it never touches the Accessibility API.

## Test

Open [`test-page.html`](test-page.html) in Chrome and hover the controls. The
plain-`<div>` button should tick even though it has no accessibility role; the
plain non-clickable div should stay silent.
