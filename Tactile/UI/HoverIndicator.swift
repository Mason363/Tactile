//
//  HoverIndicator.swift
//  Tactile
//
//  Visual companions to the haptics, for low-vision use: a ring that rides
//  under the cursor (green over clickable, red over destructive, dim over
//  disabled), an outline around the hovered element's frame, full-screen
//  crosshair guides through the cursor, a floating caption naming the
//  hovered element, and a one-shot ripple that echoes each haptic fire.
//  Everything lives in click-through overlay windows above normal content,
//  joining every Space, and costs nothing while disabled — the pipeline
//  doesn't even compute positions for aids that are off.
//

import AppKit
import QuartzCore

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
    var crosshairEnabled = false { didSet { if !crosshairEnabled { crosshairWindow?.orderOut(nil) } } }
    var captionEnabled = false { didSet { if !captionEnabled { captionWindow?.orderOut(nil) } } }
    var fireFlashEnabled = false { didSet { if !fireFlashEnabled { flashWindow?.orderOut(nil) } } }

    var circleDiameter: CGFloat = 22
    /// Ring style: outline by default so it never covers what's underneath;
    /// optionally filled for those who prefer the solid dot.
    var circleFilled = false
    var circleStrokeWidth: CGFloat = 3
    var outlineWidth: CGFloat = 3
    var crosshairWidth: CGFloat = 2
    var clickableColor: NSColor = .systemGreen
    var dangerColor: NSColor = .systemRed

    private var circleWindow: NSWindow?
    private var circleView: CircleView?
    private var outlineWindow: NSWindow?
    private var outlineView: OutlineView?
    private var crosshairWindow: NSWindow?
    private var crosshairView: CrosshairView?
    private var captionWindow: NSWindow?
    private var captionView: CaptionView?
    private var flashWindow: NSWindow?
    private var flashView: FlashView?
    private var kind: HoverKind = .none

    /// Whether the pipeline needs raw cursor positions at all.
    var wantsRawMoves: Bool { circleEnabled || crosshairEnabled || captionEnabled }

    /// Follows the cursor. Called on every mouse event while any
    /// cursor-tracking aid is on, so it does nothing but move windows.
    func moveCircle(to point: CGPoint) {
        if circleEnabled {
            let window = ensureCircleWindow()
            let d = circleDiameter + circleStrokeWidth
            window.setFrame(
                CGRect(x: point.x - d / 2, y: Self.flip(point.y) - d / 2, width: d, height: d),
                display: false
            )
        }
        if crosshairEnabled {
            moveCrosshair(to: point)
        }
        if captionEnabled {
            moveCaption(to: point)
        }
    }

    /// Recolors the cursor aids and moves the outline/caption when the
    /// hovered element changes. `frame` is in accessibility (top-left)
    /// coordinates; `caption` is what the element is ("Save — Button").
    func setState(kind: HoverKind, frame: CGRect?, caption: String?) {
        self.kind = kind
        let color = color(for: kind)

        if circleEnabled {
            let view = ensureCircleView()
            view.color = color
            view.filled = circleFilled
            view.strokeWidth = circleStrokeWidth
            view.needsDisplay = true
        }

        if crosshairEnabled {
            crosshairView?.color = color
            crosshairView?.needsDisplay = true
        }

        if captionEnabled {
            setCaption(kind == .none ? nil : caption)
        }

        guard outlineEnabled else { return }
        if kind == .none || frame == nil || frame!.isEmpty {
            outlineWindow?.orderOut(nil)
            return
        }
        let f = frame!
        let window = ensureOutlineWindow()
        let outset = outlineWidth + 4 // room for the glow
        window.setFrame(
            CGRect(x: f.minX - outset, y: Self.flip(f.maxY) - outset,
                   width: f.width + outset * 2, height: f.height + outset * 2),
            display: true
        )
        outlineView?.color = color
        outlineView?.strokeWidth = outlineWidth
        outlineView?.needsDisplay = true
        window.orderFrontRegardless()
    }

    /// One-shot expanding ripple at the cursor — the visual echo of a haptic
    /// fire, so feedback is perceivable without a finger on the trackpad.
    func flashFire() {
        guard fireFlashEnabled else { return }
        // NSEvent.mouseLocation is already in AppKit (bottom-left) space.
        let p = NSEvent.mouseLocation
        let d = max(circleDiameter * 2.2, 44)
        let window = ensureFlashWindow()
        window.setFrame(CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d), display: false)
        window.orderFrontRegardless()
        flashView?.ripple(color: color(for: kind == .none ? .clickable : kind))
    }

    func hideAll() {
        circleWindow?.orderOut(nil)
        outlineWindow?.orderOut(nil)
        crosshairWindow?.orderOut(nil)
        captionWindow?.orderOut(nil)
        flashWindow?.orderOut(nil)
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

    // MARK: - Crosshair

    private func moveCrosshair(to point: CGPoint) {
        let appKitPoint = CGPoint(x: point.x, y: Self.flip(point.y))
        guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(appKitPoint) })
            ?? NSScreen.screens.first else { return }
        let window = ensureCrosshairWindow()
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: false)
        }
        if !window.isVisible { window.orderFrontRegardless() }
        crosshairView?.cursor = CGPoint(x: appKitPoint.x - screen.frame.minX, y: appKitPoint.y - screen.frame.minY)
        crosshairView?.lineWidth = crosshairWidth
        crosshairView?.color = color(for: kind)
        crosshairView?.needsDisplay = true
    }

    // MARK: - Caption

    private var captionText: String?

    private func setCaption(_ text: String?) {
        captionText = text
        guard let text, !text.isEmpty else {
            captionWindow?.orderOut(nil)
            return
        }
        let window = ensureCaptionWindow()
        captionView?.text = text
        captionView?.sizeToFitText()
        if let size = captionView?.fittedSize {
            var frame = window.frame
            frame.size = size
            window.setFrame(frame, display: true)
        }
        window.orderFrontRegardless()
    }

    private func moveCaption(to point: CGPoint) {
        guard captionText != nil, let window = captionWindow, window.isVisible else { return }
        // Below-right of the pointer, clear of the circle; flips above when
        // it would run off the bottom of the screen.
        var origin = CGPoint(x: point.x + 16, y: Self.flip(point.y) - 22 - window.frame.height)
        let appKitPoint = CGPoint(x: point.x, y: Self.flip(point.y))
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) }) {
            if origin.y < screen.frame.minY { origin.y = Self.flip(point.y) + 22 }
            if origin.x + window.frame.width > screen.frame.maxX {
                origin.x = point.x - 16 - window.frame.width
            }
        }
        window.setFrameOrigin(origin)
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
        view.filled = circleFilled
        view.strokeWidth = circleStrokeWidth
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

    private func ensureCrosshairWindow() -> NSWindow {
        if let crosshairWindow { return crosshairWindow }
        let window = Self.makeOverlayWindow()
        let view = CrosshairView()
        window.contentView = view
        crosshairWindow = window
        crosshairView = view
        return window
    }

    private func ensureCaptionWindow() -> NSWindow {
        if let captionWindow { return captionWindow }
        let window = Self.makeOverlayWindow()
        let view = CaptionView()
        window.contentView = view
        captionWindow = window
        captionView = view
        return window
    }

    private func ensureFlashWindow() -> NSWindow {
        if let flashWindow { return flashWindow }
        let window = Self.makeOverlayWindow()
        let view = FlashView()
        window.contentView = view
        flashWindow = window
        flashView = view
        return window
    }

    // MARK: - Views

    private final class CircleView: NSView {
        var color: NSColor = .systemGray
        var filled = false
        var strokeWidth: CGFloat = 3

        override func draw(_ dirtyRect: NSRect) {
            let inset = strokeWidth / 2 + 0.5
            let path = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))
            if filled {
                color.withAlphaComponent(0.55).setFill()
                path.fill()
            }
            color.setStroke()
            path.lineWidth = strokeWidth
            path.stroke()
        }
    }

    private final class OutlineView: NSView {
        var color: NSColor = .systemGreen
        var strokeWidth: CGFloat = 3

        override func draw(_ dirtyRect: NSRect) {
            let inset = strokeWidth / 2 + 4
            let rect = bounds.insetBy(dx: inset, dy: inset)
            let radius = strokeWidth + 3
            // Soft glow behind the stroke keeps it readable on busy content.
            let glow = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            glow.lineWidth = strokeWidth + 5
            color.withAlphaComponent(0.28).setStroke()
            glow.stroke()

            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.lineWidth = strokeWidth
            color.setStroke()
            path.stroke()
        }
    }

    private final class CrosshairView: NSView {
        var cursor: CGPoint = .zero
        var color: NSColor = .systemGray
        var lineWidth: CGFloat = 2
        /// Radius of the clear gap around the pointer, so the hairlines
        /// guide the eye to the cursor without covering what's under it.
        private let gap: CGFloat = 18

        override func draw(_ dirtyRect: NSRect) {
            let c = color.withAlphaComponent(0.6)
            c.setFill()
            // Horizontal, split around the gap.
            NSRect(x: 0, y: cursor.y - lineWidth / 2, width: max(cursor.x - gap, 0), height: lineWidth).fill()
            NSRect(x: cursor.x + gap, y: cursor.y - lineWidth / 2,
                   width: max(bounds.width - cursor.x - gap, 0), height: lineWidth).fill()
            // Vertical, split around the gap.
            NSRect(x: cursor.x - lineWidth / 2, y: 0, width: lineWidth, height: max(cursor.y - gap, 0)).fill()
            NSRect(x: cursor.x - lineWidth / 2, y: cursor.y + gap,
                   width: lineWidth, height: max(bounds.height - cursor.y - gap, 0)).fill()
        }
    }

    private final class CaptionView: NSView {
        var text = ""
        private(set) var fittedSize: CGSize = .zero

        private var attributes: [NSAttributedString.Key: Any] {
            [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
        }

        func sizeToFitText() {
            let textSize = (text as NSString).size(withAttributes: attributes)
            fittedSize = CGSize(width: ceil(textSize.width) + 20, height: ceil(textSize.height) + 10)
        }

        override func draw(_ dirtyRect: NSRect) {
            let background = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            NSColor.black.withAlphaComponent(0.78).setFill()
            background.fill()
            (text as NSString).draw(at: CGPoint(x: 10, y: 5), withAttributes: attributes)
        }
    }

    /// One-shot expanding ring, animated on its CAShapeLayer so it costs
    /// nothing between fires.
    private final class FlashView: NSView {
        private let ring = CAShapeLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            ring.fillColor = nil
            ring.lineWidth = 3
            layer?.addSublayer(ring)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            ring.frame = bounds
            ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil)
        }

        func ripple(color: NSColor) {
            ring.strokeColor = color.cgColor
            ring.removeAllAnimations()

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.35
            scale.toValue = 1.0

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.9
            fade.toValue = 0.0

            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 0.4
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.isRemovedOnCompletion = true

            ring.opacity = 0 // rest state: invisible
            ring.add(group, forKey: "ripple")
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
