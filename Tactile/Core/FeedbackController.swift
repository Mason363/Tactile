//
//  FeedbackController.swift
//  Tactile
//

import AppKit
import os
import QuartzCore

/// Decides whether a resolved element deserves a tick, and fires the engines.
///
/// Feedback fires once per element *enter* — never continuously — and only
/// when the element's category is enabled, its app isn't excluded, the rate
/// limit allows it, and any dwell delay has elapsed. Optionally, leaving an
/// element that ticked also ticks, unless the cursor moved straight onto
/// another ticking element (then the enter tick alone marks the transition).
@MainActor
final class FeedbackController {
    var config: FeedbackConfig

    /// Feeds the cursor monitor's skip region after each resolution.
    var onSkipRegionUpdate: ((CGRect?) -> Void)?

    private let haptics = SystemHapticEngine()
    private let audio = AudioFeedbackEngine()

    private var lastElement: AXUIElement?
    /// Category the current element ticked with, if it did — the exit tick
    /// reuses it so hover-out feels consistent with hover-in.
    private var firedCategory: FeedbackCategory?
    private var lastTickTime: CFTimeInterval = 0
    private var dwellTimer: Timer?
    private var vibrateTimer: Timer?
    private var vibrateStep = 0

    /// Enhanced haptics when enabled and supported, public engine otherwise.
    private var hapticEngine: FeedbackEngine {
        if config.useEnhancedHaptics, let actuator = ActuatorHapticEngine.shared {
            return actuator
        }
        return haptics
    }

    private let log = Logger(subsystem: "com.masonchen.Tactile", category: "feedback")

    init(config: FeedbackConfig) {
        self.config = config
    }

    func handle(point: CGPoint, resolved: ResolvedElement?) {
        guard let resolved else {
            onSkipRegionUpdate?(Self.jitterBox(around: point))
            leaveCurrentElement(enteringFiringElement: false)
            lastElement = nil
            return
        }

        let category = ClickabilityClassifier.classify(
            role: resolved.role,
            subrole: resolved.subrole,
            actions: resolved.actions
        )

        log.debug("hit role=\(resolved.role, privacy: .public) subrole=\(resolved.subrole ?? "-", privacy: .public) category=\(category?.rawValue ?? "none", privacy: .public) app=\(resolved.bundleID ?? "?", privacy: .public)")

        // Clickable leaf elements can cache their whole frame — the cursor
        // can't reveal anything deeper inside them. Anything else (groups,
        // windows, text) only gets a small box around the cursor: containers
        // report frames that span their children, and caching those would
        // blind the pipeline to controls inside them.
        if category != nil, let frame = resolved.frame, !frame.isEmpty {
            onSkipRegionUpdate?(frame)
        } else {
            onSkipRegionUpdate?(Self.jitterBox(around: point))
        }

        // Same element as last time — nothing to do. This is what makes
        // feedback fire on enter (and exit) only.
        if let lastElement, CFEqual(lastElement, resolved.element) { return }

        let firesOnEnter = category.map { willFire($0, resolved: resolved) } ?? false
        leaveCurrentElement(enteringFiringElement: firesOnEnter)
        lastElement = resolved.element

        guard firesOnEnter, let category else { return }

        if config.dwellDelay > 0 {
            dwellTimer = Timer.scheduledTimer(withTimeInterval: config.dwellDelay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.fire(category)
                    self.firedCategory = category
                    self.startVibrationIfEnabled(category)
                }
            }
        } else {
            fire(category)
            firedCategory = category
            startVibrationIfEnabled(category)
        }
    }

    /// Forgets the current element so re-entering it ticks again.
    func reset() {
        lastElement = nil
        firedCategory = nil
        dwellTimer?.invalidate()
        dwellTimer = nil
        stopVibration()
    }

    private func willFire(_ category: FeedbackCategory, resolved: ResolvedElement) -> Bool {
        resolved.enabled
            && config.enabledCategories.contains(category)
            && !isExcluded(resolved.bundleID)
    }

    /// Ends the current element, firing the hover-out tick when configured.
    /// The exit tick is skipped when the cursor lands directly on another
    /// ticking element — one transition, one tick.
    private func leaveCurrentElement(enteringFiringElement: Bool) {
        dwellTimer?.invalidate()
        dwellTimer = nil
        stopVibration()
        if config.hapticOnExit, !enteringFiringElement, let firedCategory {
            fire(firedCategory)
        }
        firedCategory = nil
    }

    // MARK: - Hover vibration

    /// A stream of rapid pulses reads as a continuous buzz. Pulses go
    /// straight to the actuator with their own strength setting — the rate
    /// limit governs discrete ticks, and the click sound stays out of it
    /// entirely. The vibration mode shapes the gaps between pulses.
    private func startVibrationIfEnabled(_ category: FeedbackCategory) {
        guard config.vibrateOnHover else { return }
        stopVibration()
        scheduleNextVibratePulse()
    }

    private func scheduleNextVibratePulse() {
        let gaps = config.vibrationMode.gaps(base: max(config.vibrateInterval, 0.03))
        let gap = gaps[vibrateStep % gaps.count]
        vibrateStep += 1

        let timer = Timer(timeInterval: gap, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.vibrateTimer != nil else { return }
                self.hapticEngine.tick(self.config.vibratePattern)
                self.scheduleNextVibratePulse()
            }
        }
        // .common keeps the buzz alive during menu and drag tracking.
        RunLoop.main.add(timer, forMode: .common)
        vibrateTimer = timer
    }

    private func stopVibration() {
        vibrateTimer?.invalidate()
        vibrateTimer = nil
        vibrateStep = 0
    }

    private func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return config.excludedBundleIDs.contains(bundleID)
    }

    private func fire(_ category: FeedbackCategory) {
        let now = CACurrentMediaTime()
        guard now - lastTickTime >= config.rateLimitInterval else { return }
        lastTickTime = now

        let pattern = config.patterns[category] ?? category.defaultPattern
        hapticEngine.tick(pattern)
        if config.audioEnabled {
            audio.volume = config.audioVolume
            audio.soundName = config.audioSoundName
            audio.tick(pattern)
        }
    }

    /// Minimal hysteresis for positions that didn't resolve to a clickable
    /// element — absorbs jitter without hiding nearby controls.
    private static func jitterBox(around point: CGPoint) -> CGRect {
        CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
    }
}
