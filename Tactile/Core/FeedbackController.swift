//
//  FeedbackController.swift
//  Tactile
//

import AppKit
import os
import QuartzCore

/// Decides what a resolved element should feel like, and plays it.
///
/// Feedback fires once per element *enter* - never continuously - and only
/// when the element's category is enabled, its app isn't excluded, the rate
/// limit allows it, and any dwell delay has elapsed. What plays is a
/// waveform chosen by context: the category's own waveform, the danger
/// waveform for destructive controls, with an extra confirmation pulse for
/// checked/selected state. Leaving a fired element can play an exit
/// waveform, and window-boundary crossings and screen edges have theirs.
@MainActor
final class FeedbackController {
    var config: FeedbackConfig {
        didSet { ActuatorHapticEngine.shared?.target = config.hapticDevice }
    }

    /// Feeds the cursor monitor's skip region after each resolution.
    var onSkipRegionUpdate: ((CGRect?) -> Void)?

    /// Tells the visual hover indicator what the cursor is over (and where,
    /// in accessibility coordinates), plus a short caption naming it
    /// ("Save - Button"). Only called when the hovered element changes.
    var onHoverState: ((HoverKind, CGRect?, String?) -> Void)?

    /// Fires with every haptic activation - drives the fire-flash visual
    /// echo, so feedback stays perceivable without a finger on the trackpad.
    var onFire: (() -> Void)?

    private let haptics = SystemHapticEngine()
    private let audio = AudioFeedbackEngine()
    private let player = WaveformPlayer()
    /// A separate player for keyboard ticks so typing never cancels an
    /// in-flight hover waveform (and vice versa).
    private let keyPlayer = WaveformPlayer()
    private var lastKeyTickTime: CFTimeInterval = 0
    /// Lines scrolled since the last scroll tick.
    private var scrollAccumulator: Double = 0

    private var lastElement: AXUIElement?
    private var lastWindow: AXUIElement?
    /// Set when the current element fired, so hover-out knows to play.
    private var firedForCurrentElement = false
    /// The control that last fired, remembered by frame while the cursor
    /// stays inside it. This is the single dedupe memory for BOTH feedback
    /// paths: web apps re-render controls on hover (minting new accessibility
    /// and DOM nodes for the same visual control), and the accessibility path
    /// and the browser extension can each report the same control moments
    /// apart. Anything that nests with the fired frame is still the same
    /// control: no re-fire, no hover-out. `pid` is nil for bridge-reported
    /// controls (the extension has no pid, and its frames are approximate).
    private struct FireRegion {
        var frame: CGRect
        var pid: pid_t?
    }

    private var activeFireRegion: FireRegion?
    /// The destination of the last fired link. Search-result cards repeat
    /// one destination across several sibling links; crossing between them
    /// is one logical target, one feel. Sticky across the gaps between the
    /// fragments; replaced by the next fire, cleared by clicks and resets.
    private var lastFiredLinkURL: String?
    private var lastTickTime: CFTimeInterval = 0
    private var dwellTimer: Timer?
    private var vibrateTimer: Timer?
    private var vibrateStep = 0
    /// True while the actuator's continuous buzz thread is running.
    private var buzzing = false

    /// Enhanced haptics when enabled and supported, public engine otherwise.
    /// A specific device choice also routes through the actuator: the public
    /// API always reaches every connected trackpad at once.
    private var hapticEngine: FeedbackEngine {
        if let actuator = ActuatorHapticEngine.shared,
           config.useEnhancedHaptics || config.hapticDevice != .all {
            return actuator
        }
        return haptics
    }

    private let log = Logger(subsystem: "com.masonchen.Tactile", category: "feedback")

    init(config: FeedbackConfig) {
        self.config = config
        ActuatorHapticEngine.shared?.target = config.hapticDevice
    }

    func handle(point: CGPoint, resolved: ResolvedElement?) {
        // Whether the cursor is still inside the fired frame. Bridge-reported
        // frames (pid == nil) carry a little error - browser chrome offset,
        // page zoom - so they get the same generous slack the bridge dedupe
        // uses; clearing them on a 2px miss re-armed the control and doubled
        // feedback. The region itself is NOT cleared here: leaving a fired
        // fragment's frame while staying inside its enclosing control must
        // still read as the same control (see the identity check below).
        let pointInRegion = activeFireRegion.map { region in
            region.frame.insetBy(dx: -Self.regionSlack(region), dy: -Self.regionSlack(region)).contains(point)
        } ?? false

        guard let resolved else {
            // A transient hit-test failure while still inside the fired
            // control (common while web apps re-render on hover) is not an
            // exit - keep the current feel.
            if pointInRegion { return }
            activeFireRegion = nil
            onSkipRegionUpdate?(Self.jitterBox(around: point))
            onHoverState?(.none, nil, nil)
            leaveCurrentElement(enteringFiringElement: false)
            lastElement = nil
            return
        }

        handleWindowBoundary(resolved)

        let rawCategory = ClickabilityClassifier.classify(
            role: resolved.role,
            subrole: resolved.subrole,
            actions: resolved.actions
        )

        log.debug("hit role=\(resolved.role, privacy: .public) subrole=\(resolved.subrole ?? "-", privacy: .public) category=\(rawCategory?.rawValue ?? "none", privacy: .public) app=\(resolved.bundleID ?? "?", privacy: .public)")

        // Reject "clickable" elements that are clearly containers: Electron
        // and web apps mark window-sized groups as pressable, and treating
        // one as a control both fires a bogus tick and - worse - caches a
        // window-sized skip region that silences the whole app until the
        // cursor leaves it.
        let controlSized = resolved.frame.map(Self.isControlSized) ?? false
        let category = controlSized ? rawCategory : nil

        // Clickable leaf elements can cache their whole frame - the cursor
        // can't reveal anything deeper inside them. Anything else (groups,
        // windows, text) only gets a small box around the cursor: containers
        // report frames that span their children, and caching those would
        // blind the pipeline to controls inside them.
        if category != nil, let frame = resolved.frame, !frame.isEmpty {
            onSkipRegionUpdate?(frame)
        } else {
            onSkipRegionUpdate?(Self.jitterBox(around: point))
        }

        // Same element as last time - nothing to do. This is what makes
        // feedback fire on enter (and exit) only.
        if let lastElement, CFEqual(lastElement, resolved.element) { return }

        // The same control the last fire covered - its own label, an inert
        // overlay, a re-rendered wrapper, a container spanning it, or the
        // control itself with its frame shifted by a hover animation: stay
        // quiet. The region grows to the union so a control absorbs ALL its
        // fragments - when a small badge fires first and its enclosing tab
        // comes next (even after the cursor has moved past the badge's own
        // frame), the region becomes the whole tab, and every further
        // fragment inside it stays quiet too.
        if let region = activeFireRegion, region.pid == nil || region.pid == resolved.pid,
           Self.isSameControl(frame: resolved.frame, category: category, region: region, pointInRegion: pointInRegion) {
            // Grow only by clickable, control-sized frames: a window-sized
            // container also spans the fired control, but absorbing it would
            // silence the window; an inert toolbar spanning the fired button
            // would silence its siblings.
            if category != nil, let frame = resolved.frame, Self.isControlSized(frame) {
                activeFireRegion?.frame = region.frame.union(frame)
            }
            lastElement = resolved.element
            return
        }
        // Genuinely somewhere else: the fired control's dedupe memory is done.
        if !pointInRegion { activeFireRegion = nil }

        // Same destination as the link that just fired: a sibling fragment
        // of the same result (title, snippet, byline), not a new target.
        if let url = resolved.url, url == lastFiredLinkURL {
            if let frame = resolved.frame, Self.isControlSized(frame),
               let region = activeFireRegion {
                activeFireRegion?.frame = region.frame.union(frame)
            }
            lastElement = resolved.element
            return
        }

        emitHoverState(category: category, resolved: resolved)

        let firesOnEnter = category.map { willFire($0, resolved: resolved) } ?? false
        leaveCurrentElement(enteringFiringElement: firesOnEnter)
        lastElement = resolved.element

        guard let category, !isExcluded(resolved.bundleID) else { return }

        // Disabled controls: optional single light pulse instead of silence,
        // so you can feel that something is there but inactive.
        if !resolved.enabled {
            if config.feelDisabled, config.enabledCategories.contains(category), passesFocusFilter(category, resolved) {
                play(.single(.alignment), reason: "disabled", sound: categorySound(category))
            }
            return
        }

        guard firesOnEnter else { return }

        let waveform = styledWaveform(for: category, resolved: resolved)
        let sound = categorySound(category)
        let firedRegion = resolved.frame.map { FireRegion(frame: $0, pid: resolved.pid) }
        // Only a fire that HAS a destination replaces the link memory: an
        // interleaved generic fire (a card's pressable wrapper) must not
        // re-arm the card's own link fragments.
        let firedURL = resolved.url
        if config.dwellDelay > 0 {
            dwellTimer = Timer.scheduledTimer(withTimeInterval: config.dwellDelay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.play(waveform, sound: sound)
                    self.firedForCurrentElement = true
                    self.activeFireRegion = firedRegion
                    if let firedURL { self.lastFiredLinkURL = firedURL }
                    self.startVibrationIfEnabled()
                }
            }
        } else {
            play(waveform, sound: sound)
            log.debug("fired-geom path=ax cat=\(category.rawValue, privacy: .public) frame=\(resolved.frame.map(Self.geom) ?? "-", privacy: .public) point=\(Int(point.x)),\(Int(point.y), privacy: .public)")
            firedForCurrentElement = true
            activeFireRegion = firedRegion
            if let firedURL { lastFiredLinkURL = firedURL }
            startVibrationIfEnabled()
        }
    }

    /// Compact rect for debug logs.
    private static func geom(_ r: CGRect) -> String {
        "\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.width))x\(Int(r.height))"
    }

    // MARK: - Browser bridge

    /// Feedback driven by the Chrome extension instead of the accessibility
    /// tree. The extension reports the real DOM, so it reaches `<div>` controls
    /// AX never sees, and it already emits one event per element enter - so
    /// this reuses the same waveform selection, playback, vibration, and
    /// hover-out as the AX path, just fed from semantics rather than an
    /// `AXUIElement`. AppController suppresses the AX path while this is hot, so
    /// the two never both fire.
    func handleBridge(_ message: BridgeMessage) {
        let rect = message.cgRect
        log.debug("bridge msg type=\(message.type, privacy: .public) el=\(message.el ?? "-", privacy: .public) rect=\(rect.map(Self.geom) ?? "-", privacy: .public) inViewport=\(message.inViewport.map(String.init) ?? "-", privacy: .public)")

        // Geometry sanity: a hover's rect must contain the pointer - the
        // extension is claiming the cursor is over this element. When it
        // doesn't (an outdated extension build mis-converting viewport
        // coordinates: side panels, dev tools, page zoom), every rect is
        // shifted off the real control, the cross-path dedupe can't work,
        // and every control double-fires. Dropping inconsistent hovers
        // degrades safely to accessibility-only coverage instead. The slack
        // absorbs message latency while the cursor is still moving.
        if message.type == "hover", let rect,
           let cursor = CGEvent(source: nil)?.location,
           !rect.insetBy(dx: -24, dy: -24).contains(cursor) {
            log.debug("bridge hover dropped: rect=\(Self.geom(rect), privacy: .public) cursor=\(Int(cursor.x)),\(Int(cursor.y), privacy: .public)")
            return
        }

        guard message.type == "hover",
              let raw = message.el,
              let category = FeedbackCategory(rawValue: raw)
        else {
            // "leave" (or a malformed hover): end the current element, playing
            // the hover-out waveform if one fired.
            onHoverState?(.none, nil, nil)
            leaveCurrentElement(enteringFiringElement: false)
            lastElement = nil
            // NO leave message may clear the fire region - ever. The region's
            // lifecycle belongs to the accessibility path's real cursor
            // tracking (handle() clears it when the point actually leaves the
            // frame), which runs everywhere including browser chrome. Web
            // pages generate spurious exit reports constantly (tooltip
            // unmounts, child-boundary crossings, DOM churn); honoring them
            // wiped the dedupe memory while the pointer sat still on a
            // control, and the very next hover re-fired it.
            return
        }

        // The same control the last fire covered - whether that fire came
        // from this path or the accessibility path (both run concurrently
        // and report the same controls moments apart). One control, one
        // feel. Heavy overlap counts too: hover animations shift the frame
        // between reports. The region grows to the union so the control
        // absorbs all its fragments.
        if let rect, let region = activeFireRegion,
           Self.roughlyNests(rect, region.frame) || Self.heavilyOverlaps(rect, region.frame) {
            if Self.isControlSized(rect) {
                activeFireRegion?.frame = region.frame.union(rect)
            }
            let kind: HoverKind = !(message.enabled ?? true) ? .disabled
                : ((message.danger ?? false) ? .danger : .clickable)
            onHoverState?(kind, rect, Self.caption(category: category, label: message.label))
            return
        }

        // Container-sized "controls" are wrappers, not targets - same sanity
        // the accessibility path applies. (No rect means an older extension;
        // fail open.)
        if let rect, !Self.isControlSized(rect) {
            onHoverState?(.none, nil, nil)
            leaveCurrentElement(enteringFiringElement: false)
            return
        }

        let enabled = message.enabled ?? true
        let passes = config.enabledCategories.contains(category)
            && bridgeFocusOK(category)
            && bridgeSimpleOK(message)
        leaveCurrentElement(enteringFiringElement: enabled && passes)

        if passes {
            let kind: HoverKind = !enabled ? .disabled : ((message.danger ?? false) ? .danger : .clickable)
            onHoverState?(kind, rect, Self.caption(category: category, label: message.label))
        } else {
            onHoverState?(.none, nil, nil)
        }

        guard passes else { return }

        if !enabled {
            if config.feelDisabled { play(.single(.alignment), reason: "disabled", sound: categorySound(category)) }
            return
        }

        let waveform = bridgeWaveform(category: category, isOn: message.on, isDanger: message.danger ?? false)
        let sound = categorySound(category)
        let firedRegion = rect.map { FireRegion(frame: $0, pid: nil) }
        if config.dwellDelay > 0 {
            dwellTimer = Timer.scheduledTimer(withTimeInterval: config.dwellDelay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.play(waveform, reason: "bridge", sound: sound)
                    self.firedForCurrentElement = true
                    self.activeFireRegion = firedRegion
                    if let rect { self.onSkipRegionUpdate?(rect) }
                    self.startVibrationIfEnabled()
                }
            }
        } else {
            play(waveform, reason: "bridge", sound: sound)
            log.debug("fired-geom path=bridge el=\(raw, privacy: .public) rect=\(rect.map(Self.geom) ?? "-", privacy: .public)")
            firedForCurrentElement = true
            activeFireRegion = firedRegion
            // Let the cursor monitor skip re-sampling inside the fired
            // control - the accessibility path runs concurrently and doesn't
            // need to re-resolve what the extension already identified.
            if let rect { onSkipRegionUpdate?(rect) }
            startVibrationIfEnabled()
        }
    }

    /// After a click the UI under the cursor usually changes (menus open,
    /// pages navigate), so the last fired control's *frame* no longer means
    /// anything - forget it rather than suppress whatever appears there.
    /// Element identity is deliberately kept: if the click changed nothing,
    /// the same element resolving again must stay quiet, not re-fire.
    func invalidateAfterClick(at point: CGPoint) {
        // Shrink - don't clear - the fire region to a small box at the click
        // point. The clicked control re-renders with a fresh node identity in
        // web apps, but its frame still contains this point, so it reads as
        // the same control instead of a fresh tick. New UI appearing around
        // the point (menu items, the next page) extends past the box and
        // fires normally.
        activeFireRegion = FireRegion(
            frame: CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24),
            pid: nil
        )
        lastFiredLinkURL = nil
    }

    /// Approximate frame equality/containment for bridge-reported frames,
    /// which carry a little error (browser chrome offset, page zoom).
    private static func roughlyNests(_ a: CGRect, _ b: CGRect) -> Bool {
        let slack: CGFloat = 12
        return b.insetBy(dx: -slack, dy: -slack).contains(a)
            || a.insetBy(dx: -slack, dy: -slack).contains(b)
    }

    /// Danger and checked-state styling for a bridge element, mirroring
    /// `styledWaveform` but from the extension's precomputed flags.
    private func bridgeWaveform(category: FeedbackCategory, isOn: Bool?, isDanger: Bool) -> HapticWaveform {
        if config.dangerEnabled, isDanger { return config.dangerWaveform }
        var waveform = config.waveforms[category] ?? .single(category.defaultPattern)
        if config.stateAware, isOn == true, var last = waveform.steps.last {
            last.gapMs = max(last.gapMs, 110)
            waveform.steps[waveform.steps.count - 1] = last
            waveform.steps.append(WaveformStep(strength: .alignment, gapMs: 0))
        }
        return waveform
    }

    /// The focused-window quiet mode, applied to web content: the page is the
    /// frontmost window's content, so only the button restriction is meaningful.
    private func bridgeFocusOK(_ category: FeedbackCategory) -> Bool {
        guard config.focusedWindowButtonsOnly else { return true }
        return category == .button
    }

    /// Simple mode for web content: the extension decides which targets are
    /// primary (result-title links, prominent labeled controls) from the real
    /// DOM, so here we just honor its flag. Fail *open* - if an older,
    /// not-yet-reloaded extension doesn't report `primary`, keep firing rather
    /// than going silent; the filtering starts once the extension is updated.
    private func bridgeSimpleOK(_ message: BridgeMessage) -> Bool {
        guard config.simpleMode else { return true }
        return message.primary ?? true
    }

    /// Called by the pipeline when the cursor touches an outer screen edge.
    func screenEdgeBump() {
        guard config.screenEdgesEnabled else { return }
        play(config.edgeWaveform, reason: "edge")
    }

    /// Plays a waveform for a keypress: the given one (a recorded combo's
    /// own) or the default keyboard waveform. Independent of the hover
    /// pipeline: its own player and a light debounce so a fast key storm
    /// can't overwhelm the actuator. Which keys qualify is decided upstream
    /// in AppController from the settings.
    func keyboardFire(_ waveform: HapticWaveform? = nil) {
        let now = CACurrentMediaTime()
        guard now - lastKeyTickTime >= 0.02 else { return }
        lastKeyTickTime = now
        let chosen = waveform ?? config.keyboardWaveform
        log.debug("fire reason=keyboard steps=\(chosen.steps.count, privacy: .public)")
        keyPlayer.play(chosen, on: hapticEngine)
        onFire?()
        if let sound = resolvedSound(assigned: config.keyboardSound) {
            playSound(sound, strength: chosen.steps.first?.effectiveStrength ?? .generic)
        }
    }

    /// Scroll haptics: accumulates scroll distance in lines and ticks each
    /// time it crosses the configured stride.
    func handleScrollDelta(_ lines: Double) {
        guard config.scrollEnabled else { return }
        scrollAccumulator += abs(lines)
        let stride = max(config.scrollLines, 0.5)
        guard scrollAccumulator >= stride else { return }
        scrollAccumulator = scrollAccumulator.truncatingRemainder(dividingBy: stride)
        play(config.scrollWaveform, reason: "scroll", sound: .some(nil))
    }

    /// Forgets the current element so re-entering it ticks again.
    func reset() {
        log.debug("reset")
        lastElement = nil
        lastWindow = nil
        firedForCurrentElement = false
        activeFireRegion = nil
        lastFiredLinkURL = nil
        dwellTimer?.invalidate()
        dwellTimer = nil
        stopVibration()
        player.cancel()
        keyPlayer.cancel()
        scrollAccumulator = 0
    }

    // MARK: - Waveform selection

    /// Danger context overrides the category waveform; checked/selected
    /// state appends a confirmation pulse.
    private func styledWaveform(for category: FeedbackCategory, resolved: ResolvedElement) -> HapticWaveform {
        if config.dangerEnabled, ContextDetector.isDanger(title: resolved.title, subrole: resolved.subrole, category: category) {
            return config.dangerWaveform
        }

        var waveform = config.waveforms[category] ?? .single(category.defaultPattern)
        if config.stateAware, resolved.isOn == true, var last = waveform.steps.last {
            last.gapMs = max(last.gapMs, 110)
            waveform.steps[waveform.steps.count - 1] = last
            waveform.steps.append(WaveformStep(strength: .alignment, gapMs: 0))
        }
        return waveform
    }

    /// Reduces a resolution to what the visual indicator shows: nothing,
    /// clickable, destructive, or disabled - plus the caption naming it.
    private func emitHoverState(category: FeedbackCategory?, resolved: ResolvedElement) {
        guard let onHoverState else { return }
        guard let category, config.enabledCategories.contains(category), passesSimpleMode(category, resolved) else {
            onHoverState(.none, nil, nil)
            return
        }
        let kind: HoverKind
        if !resolved.enabled {
            kind = .disabled
        } else if ContextDetector.isDanger(title: resolved.title, subrole: resolved.subrole, category: category) {
            kind = .danger
        } else {
            kind = .clickable
        }
        onHoverState(kind, resolved.frame, Self.caption(category: category, label: resolved.title))
    }

    /// "Save - Button", or just "Button" when the element has no usable name.
    private static func caption(category: FeedbackCategory, label: String?) -> String {
        let name = (label ?? "").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return category.captionName }
        return "\(name.count > 40 ? String(name.prefix(39)) + "…" : name) · \(category.captionName)"
    }

    private func willFire(_ category: FeedbackCategory, resolved: ResolvedElement) -> Bool {
        resolved.enabled
            && config.enabledCategories.contains(category)
            && !isExcluded(resolved.bundleID)
            && passesFocusFilter(category, resolved)
            && passesSimpleMode(category, resolved)
    }

    /// Quiet mode: when on, only buttons in the focused window get through.
    private func passesFocusFilter(_ category: FeedbackCategory, _ resolved: ResolvedElement) -> Bool {
        guard config.focusedWindowButtonsOnly else { return true }
        return category == .button && resolved.isInFocusedWindow
    }

    /// Simple mode: cut the noise to the primary targets. Fire only for
    /// well-labeled, reasonably sized links, buttons, tabs, toggles, and menu
    /// items - dropping icon-only controls (three-dot menus, favicons),
    /// sliders, text fields, and the ambiguous generic-pressable bucket. The
    /// browser extension makes a sharper call for web pages (see handleBridge);
    /// this is the best the accessibility tree alone allows.
    private func passesSimpleMode(_ category: FeedbackCategory, _ resolved: ResolvedElement) -> Bool {
        guard config.simpleMode else { return true }
        switch category {
        case .slider, .textField, .genericPressable:
            return false
        case .link, .button, .tab, .toggle, .menuItem, .menuBarItem, .dockItem:
            break
        }
        // Must carry a real text label - this is what drops icon-only controls.
        let label = (resolved.title ?? "").unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        guard label >= 2 else { return false }
        // And not be a tiny control.
        if let f = resolved.frame, min(f.width, f.height) < 14 { return false }
        return true
    }

    private func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return config.excludedBundleIDs.contains(bundleID)
    }

    // MARK: - Transitions

    /// Ends the current element, playing the hover-out waveform when
    /// configured. Skipped when the cursor lands directly on another firing
    /// element - one transition, one feel.
    private func leaveCurrentElement(enteringFiringElement: Bool) {
        dwellTimer?.invalidate()
        dwellTimer = nil
        stopVibration()
        if config.hapticOnExit, !enteringFiringElement, firedForCurrentElement {
            play(config.exitWaveform, reason: "exit")
        }
        firedForCurrentElement = false
    }

    /// A window change under the cursor is a spatial boundary worth feeling.
    private func handleWindowBoundary(_ resolved: ResolvedElement) {
        guard config.windowBoundsEnabled else { return }
        defer { if resolved.window != nil { lastWindow = resolved.window } }
        guard let window = resolved.window, let lastWindow, !CFEqual(lastWindow, window) else { return }
        play(config.boundaryWaveform, reason: "boundary")
    }

    // MARK: - Playback

    /// `sound`: outer nil means the global default (the Sound pane); inner
    /// nil means explicitly silent; a name plays that sound.
    private func play(_ waveform: HapticWaveform, reason: StaticString = "enter", sound: String?? = nil) {
        let now = CACurrentMediaTime()
        guard config.rateLimitInterval == 0 || now - lastTickTime >= config.rateLimitInterval else { return }
        lastTickTime = now
        log.debug("fire reason=\(reason, privacy: .public) steps=\(waveform.steps.count, privacy: .public)")

        player.play(waveform, on: hapticEngine)
        onFire?()

        let soundName: String?
        switch sound {
        case .none: soundName = config.audioEnabled ? config.audioSoundName : nil
        case .some(let assigned): soundName = assigned
        }
        if let soundName {
            playSound(soundName, strength: waveform.steps.first?.effectiveStrength ?? .generic)
        }
    }

    private func playSound(_ name: String, strength: FeedbackPattern) {
        audio.volume = config.audioVolume
        audio.soundName = name
        audio.pitch = config.audioPitch
        audio.varyTone = config.audioToneVariation
        audio.tick(strength)
    }

    /// Resolves an assigned sound: "default" follows the Sound pane, "none"
    /// is silent, anything else plays regardless of the master toggle.
    private func resolvedSound(assigned: String) -> String? {
        switch assigned {
        case "default": return config.audioEnabled ? config.audioSoundName : nil
        case "none": return nil
        default: return assigned
        }
    }

    private func categorySound(_ category: FeedbackCategory) -> String? {
        resolvedSound(assigned: config.categorySounds[category] ?? "default")
    }

    // MARK: - Hover vibration

    /// A stream of rapid pulses reads as a continuous buzz. Pulses go
    /// straight to the actuator with their own strength setting - the rate
    /// limit governs discrete events, and the click sound stays out of it
    /// entirely. The vibration mode shapes the gaps between pulses.
    private func startVibrationIfEnabled() {
        guard config.vibrateOnHover else { return }
        stopVibration()
        // With the actuator available, the buzz runs on its own thread - the
        // only way to hold pulse rates high enough (up to 250/sec) to feel
        // like one continuous vibration instead of a series of taps.
        if let actuator = hapticEngine as? ActuatorHapticEngine {
            let gaps = config.vibrationMode.gaps(base: max(config.vibrateInterval, 0.004))
            actuator.startBuzz(config.vibratePattern, gaps: gaps)
            buzzing = true
            return
        }
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
        if buzzing {
            ActuatorHapticEngine.shared?.stopBuzz()
            buzzing = false
        }
        vibrateTimer?.invalidate()
        vibrateTimer = nil
        vibrateStep = 0
    }

    /// Minimal hysteresis for positions that didn't resolve to a clickable
    /// element - absorbs jitter without hiding nearby controls.
    private static func jitterBox(around point: CGPoint) -> CGRect {
        CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
    }

    /// Plausible bounds for an individual control (shared with the resolver).
    private static func isControlSized(_ frame: CGRect) -> Bool {
        ClickabilityClassifier.isControlSized(frame)
    }

    /// Geometry tolerance for a fire region. Bridge-reported frames
    /// (pid == nil) are approximate - browser chrome offset, page zoom -
    /// so they need the same generous slack `roughlyNests` uses; treating
    /// them with accessibility-grade precision re-armed controls the bridge
    /// had already fired and doubled feedback.
    private static func regionSlack(_ region: FireRegion) -> CGFloat {
        region.pid == nil ? 12 : 2
    }

    /// Whether a newly resolved frame is the *same control* the fire region
    /// remembers. Nesting either way is identity (a label inside the fired
    /// control, or a wrapper spanning it). So is heavy mutual overlap: hover
    /// animations translate and scale controls, and hover-reactive sites
    /// re-render mid-animation, so the same control routinely comes back
    /// with a shifted frame that no longer nests. Once the cursor has left
    /// the fired frame, only a *clickable, control-sized* enclosing frame
    /// (the tab whose badge fired first) or heavy overlap still counts -
    /// an inert window-spanning container must end the feel, not extend it.
    private static func isSameControl(frame: CGRect?, category: FeedbackCategory?, region: FireRegion, pointInRegion: Bool) -> Bool {
        // A transient frame-less resolution inside the fired control is the
        // same control re-rendering; outside it, it's an exit.
        guard let frame else { return pointInRegion }
        let slack = regionSlack(region)
        let grownRegion = region.frame.insetBy(dx: -slack, dy: -slack)
        let grownFrame = frame.insetBy(dx: -slack, dy: -slack)
        if pointInRegion {
            return grownRegion.contains(frame)
                || grownFrame.contains(region.frame)
                || heavilyOverlaps(frame, region.frame)
        }
        guard category != nil else { return false }
        return (isControlSized(frame) && grownFrame.contains(region.frame))
            || heavilyOverlaps(frame, region.frame)
    }

    /// Intersection-over-union identity: frames that mostly cover each other
    /// are one control mid-animation or re-render; neighbouring controls
    /// share edges, not area, so they never come close.
    private static func heavilyOverlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return false }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = a.width * a.height + b.width * b.height - intersectionArea
        return unionArea > 0 && intersectionArea / unionArea >= 0.6
    }
}
