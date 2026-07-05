# Publishing the Tactile Browser Bridge to the Chrome Web Store

This walks through getting the extension in `extension/` onto the Chrome Web
Store and keeping the native-messaging link to the Tactile app working.

## The one thing that will trip you up

The extension talks to the Tactile app through Chrome Native Messaging. The app
writes a host manifest whose `allowed_origins` lists the extension IDs allowed
to connect. Chrome assigns a **new, permanent ID** to your item when you first
create it in the Web Store, and that ID is almost never the same as the
unpacked-development ID (`fnbpgacidfliigibfomikmdgbblccmie`). You cannot choose
it to match.

So the store version will not reach the app until the app allows the store ID.
The app is now built to allow a list of IDs, so this is a one-line change:

1. Create the store item (below) and copy the **Item ID** the dashboard shows.
2. Add it to `extensionIDs` in `Tactile/Bridge/BridgeProtocol.swift`:
   ```swift
   static let extensionIDs = [
       "fnbpgacidfliigibfomikmdgbblccmie",   // unpacked development build
       "PASTE_THE_STORE_ID_HERE",            // Chrome Web Store build
   ]
   ```
3. Ship a new app build (a point release, e.g. 1.0.1). Both the store copy and a
   locally loaded copy then connect.

Keeping the development ID in the list means you can still load the folder
unpacked for testing after the extension is published.

## Before you upload

1. **Developer account.** Sign in at
   https://chrome.google.com/webstore/devconsole with the Google account you want
   to own the listing and pay the one-time 5 USD registration fee.
2. **Bump the version.** In `extension/manifest.json`, raise `"version"` (for the
   first public listing, `"1.0.0"` reads better than `"0.1.0"`). Every later
   upload must increase it.
3. **Add store icons (recommended).** The manifest has no `icons` yet. Add a
   128x128 PNG (and 48/16 if you have them) and reference them so the browser and
   listing show real artwork:
   ```json
   "icons": { "16": "icon16.png", "48": "icon48.png", "128": "icon128.png" }
   ```
   You still upload a separate 128x128 store icon in the dashboard.
4. **Zip the runtime files only.** Include `manifest.json`, `background.js`,
   `content.js`, and any icons. Do **not** include `README.md`, `PUBLISHING.md`,
   `test-page.html`, or the private `.pem` signing key. Zip the files at the
   top level of the archive (no wrapping folder):
   ```sh
   cd extension
   zip -r ../tactile-bridge.zip manifest.json background.js content.js icon*.png
   ```

## Create and submit the listing

1. In the developer console, click **Add new item** and upload
   `tactile-bridge.zip`.
2. Copy the **Item ID** shown for the new item. This is the ID you add to the app
   (see the section above).
3. Fill in the store listing: name, a short and a detailed description, category
   (Accessibility or Productivity fits), language, and at least one screenshot
   (1280x800 or 640x400). A screenshot of a page with the Tactile hover aid on
   works well.
4. **Privacy tab (this extension needs care here).** It requests the
   `nativeMessaging` permission and runs a content script on `<all_urls>`, so the
   Web Store requires a privacy policy URL and permission justifications:
   - Single purpose: "Report the type of clickable element under the cursor to
     the Tactile desktop app so it can be felt on the trackpad."
   - `nativeMessaging`: "Send the hovered element's type and on-screen rectangle
     to the Tactile app over a local channel."
   - Host access (`<all_urls>`): "Clickable controls appear on any site, so the
     content script must run everywhere to detect them."
   - Data use: declare that it does **not** collect or transmit personal or
     browsing data. Tactile only reads the element type and geometry and sends it
     to a local app over a Unix socket; nothing leaves the machine.
   - Privacy policy URL: host a short policy (a page on the Tactile site or a
     GitHub Pages/Markdown file) stating the above.
5. Set visibility (Public or Unlisted) and submit for review. Extensions with
   `<all_urls>` plus native messaging draw extra scrutiny, so review can take a
   few days.

## After it is approved

1. Confirm the app allows the store Item ID (the one-line change above) and cut
   the point release that carries it.
2. Update the install instructions in the repo `README.md` and the Tactile site
   to point at the Web Store link instead of "load unpacked".
3. A user then: installs the extension from the store, runs Tactile with browser
   integration on (it now writes the native-messaging host manifest that allows
   the store ID), and the two connect automatically.

## Sanity check the link

With the app running and the extension installed, hover a `<div>`-style button
that has no ARIA role (the demo in `test-page.html`). If Tactile fires on it, the
bridge is connected. If only native controls fire, the extension is not reaching
the app: re-check that the store Item ID is in `extensionIDs`, that browser
integration is on, and that the host manifest at
`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.masonchen.tactile.bridge.json`
lists the store origin.
