// Tactile browser bridge - background service worker.
//
// Holds the native-messaging port to Tactile's helper host and relays hover /
// leave events from the page content scripts to it. The port is opened lazily
// and reopened whenever it drops (the service worker is torn down when idle, so
// the port must be re-established on demand).

const HOST_NAME = "com.masonchen.tactile.bridge";

let port = null;

function ensurePort() {
  if (port) return port;
  try {
    port = chrome.runtime.connectNative(HOST_NAME);
  } catch (_) {
    port = null;
    return null;
  }
  port.onDisconnect.addListener(() => {
    // lastError is expected here when Tactile isn't running or the integration
    // is off; swallow it and let the next event try to reconnect.
    void chrome.runtime.lastError;
    port = null;
  });
  // The app may push messages back (e.g. an enabled-categories snapshot for
  // pre-filtering); nothing depends on them yet.
  port.onMessage.addListener(() => {});
  return port;
}

chrome.runtime.onMessage.addListener((msg) => {
  const p = ensurePort();
  if (!p) return;
  try {
    p.postMessage(msg);
  } catch (_) {
    port = null;
  }
});
