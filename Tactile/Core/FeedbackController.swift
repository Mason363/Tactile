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
/// limit allows it, and any dwell delay has elapsed.
@MainActor
final class FeedbackController {
    var config: FeedbackConfig

    /// Feeds the cursor monitor's skip region after each resolution.
    var onSkipRegionUpdate: ((CGRect?) -> Void)?

    private let haptics = SystemHapticEngine()
    private let audio = AudioFeedbackEngine()

    private var lastElement: AXUIElement?
    private var lastTickTime: CFTimeInterval = 0
    private var dwellTimer: Timer?

    private let log = Logger(subsystem: "com.masonchen.Tactile", category: "feedback")

    init(config: FeedbackConfig) {
        self.config = config
    }

    func handle(point: CGPoint, resolved: ResolvedElement?) {
        guard let resolved else {
            onSkipRegionUpdate?(Self.jitterBox(around: point))
            enterElement(nil)
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
        // feedback fire on enter only.
        if let lastElement, CFEqual(lastElement, resolved.element) { return }
        enterElement(resolved.element)

        guard let category,
              resolved.enabled,
              config.enabledCategories.contains(category),
              !isExcluded(resolved.bundleID)
        else { return }

        if config.dwellDelay > 0 {
            dwellTimer = Timer.scheduledTimer(withTimeInterval: config.dwellDelay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.fire(category) }
            }
        } else {
            fire(category)
        }
    }

    /// Forgets the current element so re-entering it ticks again.
    func reset() {
        enterElement(nil)
    }

    private func enterElement(_ element: AXUIElement?) {
        lastElement = element
        dwellTimer?.invalidate()
        dwellTimer = nil
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
        haptics.tick(pattern)
        if config.audioEnabled {
            audio.volume = config.audioVolume
            audio.tick(pattern)
        }
    }

    /// Minimal hysteresis for positions that didn't resolve to a clickable
    /// element — absorbs jitter without hiding nearby controls.
    private static func jitterBox(around point: CGPoint) -> CGRect {
        CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
    }
}
