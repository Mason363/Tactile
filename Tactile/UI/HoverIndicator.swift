//
//  HoverIndicator.swift
//  Tactile
//
//  Visual companions to the haptics, for low-vision use: a colored circle
//  that rides under the cursor (green over clickable, red over destructive,
//  dim over disabled) and an outline around the hovered element's frame.
//  Both live in click-through overlay windows above normal content, joining
//  every Space, and cost nothing while disabled — the pipeline doesn't even
//  compute positions for them.
//

import AppKit

/// What the cursor is over, reduced to what a glance needs to convey.
enum HoverKind {
    case none
    case clickable
    case danger
    case disabled
}

@MainActor
final class HoverIndicator {
    var circleEnabled = false { didSet { if !circleEnabled { circleWindow?.orderOut(nil) } } }
    var outlineEnabled = false { didSet { if !outlineEnabled { outlineWindow?.orderOut(nil) } } }
    var circleDiameter: CGFloat = 22
    var clickableColor: NSColor = .systemGreen
    var dangerColor: NSColor = .systemRed

    private var circleWindow: NSWindow?
    private var circleView: CircleView?
    private var outlineWindow: NSWindow?
    private var outlineView: OutlineView?
    private var kind: HoverKind = .none

    /// Follows the cursor. Called on every mouse event while the circle is
    /// on, so it does nothing but move a window.
    func moveCircle(to point: CGPoint) {
        guard circleEnabled else { return }
        let window = ensureCircleWindow()
        let d = circleDiameter
        window.setFrame(
            CGRect(x: point.x - d / 2, y: Self.flip(point.y) - d / 2, width: d, height: d),
            display: false
        )
    }

    /// Recolors the circle and moves the outline when the hovered element
    /// changes. `frame` is in accessibility (top-left) coordinates.
    func setState(kind: HoverKind, frame: CGRect?) {
        self.kind = kind

        if circleEnabled {
            let view = ensureCircleView()
            view.color = color(for: kind)
            view.needsDisplay = true
        }

        guard outlineEnabled else { return }
        if kind == .none || frame == nil || frame!.isEmpty {
            outlineWindow?.orderOut(nil)
            return
        }
        let f = frame!
        let window = ensureOutlineWindow()
        let outset: CGFloat = 3
        window.setFrame(
            CGRect(x: f.minX - outset, y: Self.flip(f.maxY) - outset,
                   width: f.width + outset * 2, height: f.height + outset * 2),
            display: true
        )
        outlineView?.color = color(for: kind)
        outlineView?.needsDisplay = true
        window.orderFrontRegardless()
    }

    func hideAll() {
        circleWindow?.orderOut(nil)
        outlineWindow?.orderOut(nil)
        kind = .none
    }

    private func color(for kind: HoverKind) -> NSColor {
        switch kind {
        case .none: return NSColor.systemGray.withAlphaComponent(0.45)
        case .clickable: return clickableColor
        case .danger: return dangerColor
        case .disabled: return NSColor.systemGray.withAlphaComponent(0.8)
        }
    }

    // MARK: - Windows

    /// AX coordinates hang from the top-left of the primary display; AppKit
    /// windows grow from its bottom-left.
    private static func flip(_ y: CGFloat) -> CGFloat {
        (NSScreen.screens.first?.frame.maxY ?? 0) - y
    }

    private static func makeOverlayWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 10, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isReleasedWhenClosed = false
        return window
    }

    private func ensureCircleWindow() -> NSWindow {
        if let circleWindow {
            if !circleWindow.isVisible { circleWindow.orderFrontRegardless() }
            return circleWindow
        }
        let window = Self.makeOverlayWindow()
        let view = CircleView()
        view.color = color(for: kind)
        window.contentView = view
        window.orderFrontRegardless()
        circleWindow = window
        circleView = view
        return window
    }

    private func ensureCircleView() -> CircleView {
        _ = ensureCircleWindow()
        return circleView!
    }

    private func ensureOutlineWindow() -> NSWindow {
        if let outlineWindow { return outlineWindow }
        let window = Self.makeOverlayWindow()
        let view = OutlineView()
        window.contentView = view
        outlineWindow = window
        outlineView = view
        return window
    }

    // MARK: - Views

    private final class CircleView: NSView {
        var color: NSColor = .systemGray

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            color.withAlphaComponent(0.55).setFill()
            path.fill()
            color.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    private final class OutlineView: NSView {
        var color: NSColor = .systemGreen

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            path.lineWidth = 3
            color.setStroke()
            path.stroke()
        }
    }
}

// MARK: - Hex color persistence

extension NSColor {
    /// "#RRGGBB" in sRGB, how indicator colors are stored in settings.
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        guard let srgb = usingColorSpace(.sRGB) else { return "#34C759" }
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
