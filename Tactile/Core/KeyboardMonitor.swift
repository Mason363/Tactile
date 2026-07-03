//
//  KeyboardMonitor.swift
//  Tactile
//

import AppKit

/// Watches key presses so Tactile can tick the trackpad as you type: on
/// shortcuts, on every key, on modifiers, or on recorded key combinations.
///
/// **Privacy:** events are compared against the user's settings on-device and
/// immediately discarded. Nothing about keystrokes is stored, logged, or sent
/// anywhere, and the monitors are observe-only; they cannot alter input.
///
/// Uses NSEvent monitors rather than a CGEventTap: key-event monitors are
/// documented to work with Accessibility trust (which Tactile has), while
/// keyboard event taps can additionally require Input Monitoring on recent
/// macOS, silently receiving nothing without it. The global monitor covers
/// other apps; the local monitor covers Tactile's own windows.
final class KeyboardMonitor {
    /// A key went down (autorepeat filtered out). Carries the key code and
    /// the significant modifiers so the caller can match shortcuts and
    /// recorded combinations. Both are discarded after the comparison.
    var onKeyDown: ((_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Void)?

    /// A modifier key (⌘⇧⌥⌃) was just pressed down; releases don't fire.
    var onModifierDown: (() -> Void)?

    /// True while a shortcut recorder is capturing; the monitor stays quiet
    /// so recording a combo doesn't also fire haptics mid-capture.
    var suspended = false

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastModifiers: NSEvent.ModifierFlags = []

    static let significantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    var isRunning: Bool { globalMonitor != nil }

    func start() {
        guard !isRunning else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        lastModifiers = []
    }

    private func handle(_ event: NSEvent) {
        guard !suspended else { return }
        switch event.type {
        case .keyDown:
            guard !event.isARepeat else { return }
            onKeyDown?(event.keyCode, event.modifierFlags.intersection(Self.significantModifiers))
        case .flagsChanged:
            let current = event.modifierFlags.intersection(Self.significantModifiers)
            // Rising edge only: a modifier is down now that wasn't before.
            let pressedNew = !current.subtracting(lastModifiers).isEmpty
            lastModifiers = current
            if pressedNew { onModifierDown?() }
        default:
            break
        }
    }
}
