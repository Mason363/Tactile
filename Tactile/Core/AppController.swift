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

    let settings = SettingsStore()
    let permission = PermissionManager()

    @Published private(set) var isActive = false
    @Published private(set) var pausedUntil: Date?

    private var resumeTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    var menuBarSymbol: String {
        if !permission.isTrusted { return "cursorarrow.slash" }
        return isActive ? "cursorarrow.rays" : "cursorarrow"
    }

    func bootstrap() {
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

    // MARK: - Pipeline (wired up in the core milestone)

    private func pushConfig() {
    }

    private func startPipeline() {
    }

    private func stopPipeline() {
    }
}
