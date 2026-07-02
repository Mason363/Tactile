//
//  AppController.swift
//  Tactile
//

import AppKit
import Combine
import os

/// Owns the app's state and the feedback pipeline. The pipeline is torn down
/// completely whenever it shouldn't run (disabled, paused, or missing
/// permission) so an inactive Tactile costs nothing.
@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    let settings: SettingsStore
    let permission = PermissionManager()

    private let cursorMonitor = CursorMonitor()
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

    /// Arbitration state: the bridge owns feedback (and the AX path stands down)
    /// only when all of these hold.
    private var bridgeConnected = false
    private var frontmostIsBridgedBrowser = false
    private var pointerInBrowserContent = false
    private var frontmostIsExcluded = false

    /// While hot, the accessibility pipeline defers inside the browser's web
    /// content — the extension drives feedback and the AX queries are skipped.
    private var bridgeIsHot: Bool {
        settings.browserIntegrationEnabled
            && bridgeConnected
            && frontmostIsBridgedBrowser
            && pointerInBrowserContent
            && !frontmostIsExcluded
    }

    private init() {
        let settings = SettingsStore()
        self.settings = settings
        self.feedback = FeedbackController(config: settings.makeConfig())
    }

    func bootstrap() {
        cursorMonitor.onSample = { [weak self] point in
            guard let self, !self.bridgeIsHot else { return }
            self.resolver.resolve(at: point)
        }
        cursorMonitor.onScreenEdge = { [weak self] in
            self?.feedback.screenEdgeBump()
        }
        resolver.onResolve = { [weak self] point, resolved in
            guard let self, !self.bridgeIsHot else { return }
            self.feedback.handle(point: point, resolved: resolved)
        }
        feedback.onSkipRegionUpdate = { [weak self] region in
            self?.cursorMonitor.skipRegion = region
        }
        feedback.onHoverState = { [weak self] kind, frame in
            self?.indicator.setState(kind: kind, frame: frame)
        }

        bridge.onEvent = { [weak self] message in
            self?.handleBridgeEvent(message)
        }
        bridge.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            self.bridgeConnected = connected
            if !connected {
                // A hard drop (extension crash/reload) can't send a "leave", so
                // end any in-progress feel — otherwise a hover buzz would run on.
                self.pointerInBrowserContent = false
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
        updateBridge()
        updateIndicator()
    }

    private func updateIndicator() {
        indicator.circleEnabled = settings.hoverCircleEnabled
        indicator.outlineEnabled = settings.elementHighlightEnabled
        indicator.circleDiameter = settings.hoverCircleDiameter
        indicator.clickableColor = NSColor(hexString: settings.clickableColorHex) ?? .systemGreen
        indicator.dangerColor = NSColor(hexString: settings.dangerColorHex) ?? .systemRed
        cursorMonitor.onRawMove = settings.hoverCircleEnabled
            ? { [weak self] point in self?.indicator.moveCircle(to: point) }
            : nil
        if !settings.hoverCircleEnabled, !settings.elementHighlightEnabled {
            indicator.hideAll()
        }
    }

    private func startPipeline() {
        cursorMonitor.start()
    }

    private func stopPipeline() {
        cursorMonitor.stop()
        feedback.reset()
        bridge.stop()
        pointerInBrowserContent = false
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
            pointerInBrowserContent = false
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
        pointerInBrowserContent = (message.inViewport ?? true)
        feedback.handleBridge(message)
    }

    private func frontmostDidChange() {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        frontmostIsBridgedBrowser = bundleID.map(Self.bridgedBrowserIDs.contains) ?? false
        frontmostIsExcluded = bundleID.map { settings.excludedBundleIDs.contains($0) } ?? false
        if !frontmostIsBridgedBrowser {
            // Left the browser: the extension can't report, so hand everything
            // back to the AX path and forget any half-entered web element.
            pointerInBrowserContent = false
            feedback.reset()
        }
    }
}
