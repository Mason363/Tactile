//
//  AppController.swift
//  Tactile
//

import AppKit
import Combine
import os
import QuartzCore

/// Owns the app's state and the feedback pipeline. The pipeline is torn down
/// completely whenever it shouldn't run (disabled, paused, or missing
/// permission) so an inactive Tactile costs nothing.
@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    let settings: SettingsStore
    let permission = PermissionManager()

    private let cursorMonitor = CursorMonitor()
    private let keyboardMonitor = KeyboardMonitor()
    private let resolver = ElementResolver()
    private let feedback: FeedbackController
    private let bridge = BrowserBridgeServer()
    private let indicator = HoverIndicator()

    @Published private(set) var isActive = false
    @Published private(set) var pausedUntil: Date?

    private var resumeTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private let log = Logger(subsystem: "com.masonchen.Tactile", category: "app")

    /// Bundle IDs whose web content the browser bridge owns. Chrome only for now.
    private static let bridgedBrowserIDs: Set<String> = ["com.google.Chrome"]

    /// Bridge state. The extension is a *supplement*, never an exclusive
    /// owner: the accessibility path always runs, and the two are deduped
    /// against each other by the shared fire region in FeedbackController
    /// (the extension reports each element's screen rect for exactly this).
    /// Exclusive ownership was tried and abandoned - the extension sees less
    /// than the accessibility tree in places (oversized rows, uninstrumented
    /// chrome:// pages) and its service worker adds wake-up latency, so
    /// gating the AX path on it caused dead spots and lag.
    private var bridgeConnected = false
    private var frontmostIsBridgedBrowser = false
    private var frontmostIsExcluded = false

    private init() {
        let settings = SettingsStore()
        self.settings = settings
        self.feedback = FeedbackController(config: settings.makeConfig())
    }

    func bootstrap() {
        cursorMonitor.onSample = { [weak self] point in
            self?.resolver.resolve(at: point)
        }
        cursorMonitor.onScreenEdge = { [weak self] in
            self?.feedback.screenEdgeBump()
        }
        resolver.onResolve = { [weak self] point, resolved in
            self?.feedback.handle(point: point, resolved: resolved)
        }
        feedback.onSkipRegionUpdate = { [weak self] region in
            self?.cursorMonitor.skipRegion = region
        }
        feedback.onHoverState = { [weak self] kind, frame, caption in
            self?.indicator.setState(kind: kind, frame: frame, caption: caption)
        }
        feedback.onFire = { [weak self] in
            self?.indicator.flashFire()
        }
        cursorMonitor.onClick = { [weak self] point in
            // Clicks change the UI under the cursor (menus open, pages
            // navigate) - cached frames stop meaning anything.
            self?.feedback.invalidateAfterClick(at: point)
        }

        // Keyboard haptics. A recorded combo wins and plays its own waveform;
        // otherwise the shortcut / every-key / modifier settings decide.
        // Events are compared and discarded; nothing is stored (see monitor docs).
        keyboardMonitor.onKeyDown = { [weak self] keyCode, modifiers in
            guard let self else { return }
            if let combo = self.settings.keyCombos.first(where: { $0.matches(keyCode: keyCode, modifiers: modifiers) }) {
                self.feedback.keyboardFire(combo.waveform)
                return
            }
            let isShortcut = !modifiers.intersection([.command, .option, .control]).isEmpty
            if self.settings.keyboardAllKeys || (self.settings.keyboardShortcuts && isShortcut) {
                self.feedback.keyboardFire()
            }
        }
        keyboardMonitor.onModifierDown = { [weak self] in
            guard let self, self.settings.keyboardModifierKeys else { return }
            self.feedback.keyboardFire()
        }

        bridge.onEvent = { [weak self] message in
            self?.handleBridgeEvent(message)
        }
        bridge.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            self.bridgeConnected = connected
            if !connected {
                // A hard drop (extension crash/reload) can't send a "leave", so
                // end any in-progress feel - otherwise a hover buzz would run on.
                self.feedback.reset()
            }
        }

        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.settingsDidChange() }
            .store(in: &cancellables)

        permission.$isTrusted
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPipelineState() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.frontmostDidChange() }
            .store(in: &cancellables)

        frontmostDidChange()
        refreshPipelineState()
    }

    func pause(for interval: TimeInterval) {
        pausedUntil = Date().addingTimeInterval(interval)
        resumeTimer?.invalidate()
        resumeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.resume() }
        }
        refreshPipelineState()
    }

    func resume() {
        pausedUntil = nil
        resumeTimer?.invalidate()
        resumeTimer = nil
        refreshPipelineState()
    }

    private func settingsDidChange() {
        pushConfig()
        refreshPipelineState()
    }

    private func refreshPipelineState() {
        let shouldRun = settings.isEnabled && permission.isTrusted && pausedUntil == nil
        guard shouldRun != isActive else { return }
        isActive = shouldRun
        if shouldRun {
            pushConfig()
            startPipeline()
        } else {
            stopPipeline()
        }
    }

    // MARK: - Pipeline

    private func pushConfig() {
        feedback.config = settings.makeConfig()
        cursorMonitor.sampleInterval = 1.0 / max(settings.pollingHz, 1)
        cursorMonitor.unthrottled = settings.noLagMode
        cursorMonitor.screenEdgesEnabled = settings.screenEdgesEnabled
        resolver.wantsWindow = settings.windowBoundsEnabled
        resolver.wantsFocusedWindow = settings.focusedWindowButtonsOnly
        // The exclusion list may have just changed - re-evaluate the app
        // that's already frontmost, not only the next one to activate.
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        frontmostIsExcluded = bundleID.map { settings.excludedBundleIDs.contains($0) } ?? false
        updateBridge()
        updateIndicator()
        updateKeyboardMonitor()
    }

    /// Runs the key monitor only while the pipeline is active and the feature
    /// is on. No key observation exists when keyboard haptics are off.
    private func updateKeyboardMonitor() {
        let shouldRun = isActive && settings.keyboardHapticsEnabled
        if shouldRun, !keyboardMonitor.isRunning {
            keyboardMonitor.start()
        } else if !shouldRun, keyboardMonitor.isRunning {
            keyboardMonitor.stop()
        }
    }

    /// Quiets the key monitor while a shortcut recorder is capturing, so
    /// recording a combo doesn't fire haptics mid-press.
    func setKeyboardCaptureSuspended(_ suspended: Bool) {
        keyboardMonitor.suspended = suspended
    }

    private func updateIndicator() {
        indicator.circleEnabled = settings.hoverCircleEnabled
        indicator.outlineEnabled = settings.elementHighlightEnabled
        indicator.crosshairEnabled = settings.crosshairEnabled
        indicator.captionEnabled = settings.hoverCaptionEnabled
        indicator.fireFlashEnabled = settings.fireFlashEnabled
        indicator.circleDiameter = settings.hoverCircleDiameter
        indicator.circleFilled = settings.hoverCircleFilled
        indicator.circleStrokeWidth = settings.hoverCircleStrokeWidth
        indicator.outlineWidth = settings.elementHighlightWidth
        indicator.crosshairWidth = settings.crosshairWidth
        indicator.clickableColor = NSColor(hexString: settings.clickableColorHex) ?? .systemGreen
        indicator.dangerColor = NSColor(hexString: settings.dangerColorHex) ?? .systemRed
        // Raw moves feed every cursor-tracking aid; nil when none is on so an
        // aid-free setup costs nothing per mouse event.
        cursorMonitor.onRawMove = indicator.wantsRawMoves
            ? { [weak self] point in self?.indicator.moveCircle(to: point) }
            : nil
        if !indicator.wantsRawMoves, !settings.elementHighlightEnabled, !settings.fireFlashEnabled {
            indicator.hideAll()
        }
    }

    private func startPipeline() {
        cursorMonitor.start()
    }

    private func stopPipeline() {
        cursorMonitor.stop()
        keyboardMonitor.stop()
        feedback.reset()
        bridge.stop()
        indicator.hideAll()
    }

    // MARK: - Browser bridge

    /// Starts or stops the local socket server to match the setting and pipeline
    /// state, installing the native-messaging manifest the first time it's
    /// enabled so Chrome can find the host.
    private func updateBridge() {
        let shouldRun = isActive && settings.browserIntegrationEnabled
        log.debug("updateBridge shouldRun=\(shouldRun, privacy: .public) isActive=\(self.isActive, privacy: .public) setting=\(self.settings.browserIntegrationEnabled, privacy: .public) running=\(self.bridge.isRunning, privacy: .public)")
        if shouldRun, !bridge.isRunning {
            NativeMessagingManifest.install()
            bridge.start()
        } else if !shouldRun, bridge.isRunning {
            bridge.stop()
        }
    }

    /// Re-writes the native-messaging manifest (e.g. after moving the app) and
    /// ensures the socket server is up. Surfaced by the Settings "set up" action.
    func reinstallBrowserBridge() {
        NativeMessagingManifest.install()
        updateBridge()
    }

    var browserBridgeInstalled: Bool { NativeMessagingManifest.isInstalled }

    private func handleBridgeEvent(_ message: BridgeMessage) {
        guard settings.browserIntegrationEnabled, frontmostIsBridgedBrowser, !frontmostIsExcluded else { return }
        // Hovers without a rect come from an outdated extension build. They
        // can't be deduped against the accessibility path, so rather than
        // risk doubled feedback they're dropped - the AX path covers Chrome
        // fully on its own until the extension is reloaded.
        if message.type == "hover", message.cgRect == nil { return }
        guard message.type != "ping" else { return }
        feedback.handleBridge(message)
    }

    private func frontmostDidChange() {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        frontmostIsBridgedBrowser = bundleID.map(Self.bridgedBrowserIDs.contains) ?? false
        frontmostIsExcluded = bundleID.map { settings.excludedBundleIDs.contains($0) } ?? false
        if !frontmostIsBridgedBrowser {
            // Left the browser: forget any half-entered web element.
            feedback.reset()
        }
    }
}
