//
//  KeyboardMonitor.swift
//  Tactile
//

import AppKit

/// Watches global key events so Tactile can tick the trackpad when you type —
/// a keyboard shortcut, any key, or a modifier engaging.
///
/// **Privacy:** this reads only the *event type* and *modifier flags* (the
/// state of ⌘⇧⌥⌃), never the key code or the character. It cannot — and does
/// not — tell which key was pressed; it only knows that *a* key went down and
/// whether a modifier was held. Nothing about keystrokes is stored, logged, or
/// sent anywhere. The tap is listen-only, so it can't alter or block input.
///
/// Like `CursorMonitor` it uses a listen-only `CGEventTap` (rather than an
/// `NSEvent` global monitor) so it keeps working inside nested tracking loops,
/// and its run-loop source lives on the main run loop so callbacks arrive on
/// the main thread.
final class KeyboardMonitor {
    /// A key was pressed. `shortcut` is true when a command, control, or
    /// option modifier was held — i.e. this keypress is part of a shortcut
    /// rather than plain typing. Autorepeat (holding a key) is filtered out.
    var onKeyDown: ((_ shortcut: Bool) -> Void)?

    /// A modifier key (⌘⇧⌥⌃) was just pressed down — a rising edge in the
    /// modifier flags. Releases don't fire.
    var onModifierDown: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// The significant modifiers we track, so a rising edge means one actually
    /// engaged (ignoring caps-lock and hardware-specific bits).
    private static let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
    private static let shortcutMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]

    /// Which tracked modifiers were down at the last flagsChanged, to tell a
    /// press (new modifier) from a release.
    private var lastModifiers: CGEventFlags = []

    var isRunning: Bool { eventTap != nil }

    func start() {
        guard !isRunning else { return }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                    monitor.handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
        lastModifiers = []
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .keyDown:
            // Ignore auto-repeat so holding a key doesn't machine-gun the
            // haptic. (This field is a repeat flag, not key content.)
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
            let shortcut = !event.flags.intersection(Self.shortcutMask).isEmpty
            onKeyDown?(shortcut)

        case .flagsChanged:
            let current = event.flags.intersection(Self.modifierMask)
            // Fire only on a rising edge: a modifier is now down that wasn't
            // before. Releases (bits clearing) stay silent.
            let pressedNew = !current.subtracting(lastModifiers).isEmpty
            lastModifiers = current
            if pressedNew { onModifierDown?() }

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }

        default:
            break
        }
    }
}
