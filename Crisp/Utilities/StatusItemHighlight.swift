import AppKit

/// The lit pill behind Crisp's menu bar icon while the panel or the banner is
/// up. `NSStatusBarButton.highlight(_:)` paints nothing on macOS 27, so there
/// the pill is drawn here instead, in the button's own layer.
/// See docs/panel-resize.md (StatusItemHighlight) for the measured shape and colors.
enum StatusItemHighlight {
    private static let barInset: CGFloat = 3
    private static let overhang: CGFloat = 2

    private static let lift: CGFloat = 11

    @MainActor
    static func apply(_ lit: Bool, to button: NSStatusBarButton?) {
        guard let button else { return }
        guard SystemLook.isMacOS27OrLater else {
            button.highlight(lit)
            return
        }
        draw(lit, on: button)
    }

    /// True over the item's whole window (the press area), not the button's own
    /// smaller rect.
    @MainActor
    static func isPointerOver(_ button: NSStatusBarButton?) -> Bool {
        guard let window = button?.window else { return false }
        return window.frame.contains(NSEvent.mouseLocation)
    }

    @MainActor
    private static func draw(_ lit: Bool, on button: NSStatusBarButton) {
        button.wantsLayer = true
        guard let host = button.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard lit, let frame = frame(in: button) else {
            pill(in: host)?.removeFromSuperlayer()
            return
        }
        let layer = pill(in: host) ?? add(to: host)
        layer.frame = frame
        layer.cornerRadius = frame.height / 2
    }

    /// The pill's frame in the button's own coordinates, sized off the menu bar
    /// (not the button: a notched bar is a different height). Falls back to
    /// `NSStatusBar.system.thickness` in full-screen Spaces where visibleFrame == frame.
    @MainActor
    private static func frame(in button: NSStatusBarButton) -> CGRect? {
        guard let window = button.window, let screen = window.screen else { return nil }
        let rawBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let usesFallback = rawBarHeight <= 2 * barInset
        let barHeight = usesFallback ? NSStatusBar.system.thickness : rawBarHeight
        guard barHeight > 2 * barInset else { return nil }
        let height = barHeight - 2 * barInset
        let top: CGFloat
        if usesFallback {
            top = (button.bounds.height - height) / 2
        } else {
            let buttonTop = window.convertToScreen(button.convert(button.bounds, to: nil)).maxY
            top = buttonTop - (screen.frame.maxY - barInset)
        }
        return CGRect(x: 0,
                      y: button.layer?.isGeometryFlipped == true ? top : button.bounds.height - top - height,
                      width: button.bounds.width,
                      height: height)
    }

    /// Resets cached widening geometry before a status-item layout mode or length change.
    @MainActor
    static func resetLayoutState() {
        layoutState = nil
    }

    /// Widens the item's window by the overhang once per natural width so the pill
    /// isn't clipped. Safe to call after dynamic width changes (switching between
    /// icon and CPU temperature modes) without compounding overhangs.
    @MainActor
    static func makeRoom(for button: NSStatusBarButton?, baseLength: CGFloat? = nil) {
        guard SystemLook.isMacOS27OrLater, let button, let window = button.window else { return }
        let windowWidth = window.frame.width
        let intrinsicWidth = button.intrinsicContentSize.width
        guard windowWidth > 0 else { return }
        if let state = layoutState,
           abs(windowWidth - state.widenedWidth) < 0.5,
           state.matches(baseLength: baseLength, intrinsicWidth: intrinsicWidth) {
            syncButtonFrame(button, width: windowWidth)
            refreshPillFrameIfLit(on: button)
            return
        }
        if let baseLength, baseLength > 0, windowWidth >= baseLength + 2 * overhang - 0.5 {
            layoutState = LayoutState(baseLength: baseLength, intrinsicWidth: intrinsicWidth, widenedWidth: windowWidth)
            syncButtonFrame(button, width: windowWidth)
            refreshPillFrameIfLit(on: button)
            return
        }
        var frame = window.frame
        frame.origin.x -= overhang
        frame.size.width += 2 * overhang
        window.setFrame(frame, display: false)
        layoutState = LayoutState(baseLength: baseLength, intrinsicWidth: intrinsicWidth, widenedWidth: frame.width)
        syncButtonFrame(button, width: frame.width)
        refreshPillFrameIfLit(on: button)
    }

    @MainActor
    private static func syncButtonFrame(_ button: NSStatusBarButton, width: CGFloat) {
        if abs(button.frame.origin.x) > 0.5 || abs(button.frame.width - width) > 0.5 {
            button.frame = NSRect(x: 0, y: button.frame.minY, width: width, height: button.frame.height)
        }
    }

    @MainActor
    private static func refreshPillFrameIfLit(on button: NSStatusBarButton) {
        guard let host = button.layer, pill(in: host) != nil else { return }
        draw(true, on: button)
    }

    private struct LayoutState {
        let baseLength: CGFloat?
        let intrinsicWidth: CGFloat
        let widenedWidth: CGFloat

        func matches(baseLength: CGFloat?, intrinsicWidth: CGFloat) -> Bool {
            if let lhs = self.baseLength, let rhs = baseLength {
                return abs(lhs - rhs) < 0.5
            }
            return self.baseLength == nil && baseLength == nil && abs(self.intrinsicWidth - intrinsicWidth) < 0.5
        }
    }

    /// Last measured intrinsic & widened widths so widening happens once per layout state.
    @MainActor private static var layoutState: LayoutState?

    private static let name = "crisp.statusItemHighlight"

    private static func pill(in host: CALayer) -> CALayer? {
        host.sublayers?.first { $0.name == name }
    }

    private static func add(to host: CALayer) -> CALayer {
        let layer = CALayer()
        layer.name = name
        layer.backgroundColor = NSColor(white: 1, alpha: lift / 255).cgColor
        layer.compositingFilter = "plusL"
        host.addSublayer(layer)
        return layer
    }
}
