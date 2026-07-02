//
//  AppController.swift
//  Tactile
//

import AppKit
import Combine

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

    @Published private(set) var isActive = false
    @Published private(set) var pausedUntil: Date?

    private var resumeTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let settings = SettingsStore()
        self.settings = settings
        self.feedback = FeedbackController(config: settings.makeConfig())
    }

    var menuBarSymbol: String {
        if !permission.isTrusted { return "cursorarrow.slash" }
        return isActive ? "cursorarrow.rays" : "cursorarrow"
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

        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.settingsDidChange() }
            .store(in: &cancellables)

        permission.$isTrusted
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPipelineState() }
            .store(in: &cancellables)

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
    }

    private func startPipeline() {
        cursorMonitor.start()
    }

    private func stopPipeline() {
        cursorMonitor.stop()
        feedback.reset()
    }
}
