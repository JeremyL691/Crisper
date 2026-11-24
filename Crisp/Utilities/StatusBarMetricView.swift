import AppKit
import CoreText
import QuartzCore

/// Snapshot of every visual input needed to paint Crisper's menu bar status item.
struct StatusItemRenderState: Equatable {
    let mode: MenuBarDisplayMode
    let tempStyle: MenuBarTemperatureStyle
    let symbol: String
    let unit: TemperatureUnit
    let showDecimal: Bool
    let thermalZone: ThermalColorZone
    let tempText: String
}

/// Geometry-defining properties of the menu bar status item.
/// Two temperature readings with the same layout key (e.g. `49.8°C` -> `49.9°C`)
/// share an identical tight fixed width so updating digits never triggers layout or flicker.
struct StatusItemLayoutKey: Equatable {
    let mode: MenuBarDisplayMode
    let tempStyle: MenuBarTemperatureStyle
    let symbol: String
    let unit: TemperatureUnit
    let showDecimal: Bool
    let isThreeDigit: Bool

    static func from(_ state: StatusItemRenderState) -> StatusItemLayoutKey {
        let numeric = state.tempText.replacingOccurrences(of: state.unit.symbol, with: "")
        let integerCount = numeric.split(separator: ".").first?.count ?? 0
        return StatusItemLayoutKey(
            mode: state.mode,
            tempStyle: state.mode == .cpuTemperature ? state.tempStyle : .compact,
            symbol: state.mode == .cpuTemperature ? "" : state.symbol,
            unit: state.unit,
            showDecimal: state.showDecimal,
            isThreeDigit: state.mode != .iconOnly && integerCount >= 3
        )
    }

    /// Tight fixed width matching `exelban/stats` & `eul` menu bar ergonomics
    /// (minimal 2pt internal padding so macOS's own inter-item spacing isn't doubled).
    @MainActor
    var reservedLength: CGFloat {
        let sampleDigits = isThreeDigit ? (showDecimal ? "188.8" : "188") : (showDecimal ? "88.8" : "88")
        let sample = sampleDigits + unit.symbol
        let horizontalPadding: CGFloat = 2

        switch mode {
        case .cpuTemperature:
            switch tempStyle {
            case .stacked:
                let valueWidth = StatusBarMetricView.measureTemperatureWidth(sample, font: StatusBarMetricView.stackedValueFont)
                let labelWidth = StatusBarMetricView.measureMicroLabelWidth("CPU")
                return max(valueWidth, labelWidth).rounded(.up) + horizontalPadding
            case .verticalTag:
                let valueWidth = StatusBarMetricView.measureTemperatureWidth(sample, font: StatusBarMetricView.inlineValueFont)
                return (StatusBarMetricView.verticalTagWidth + StatusBarMetricView.verticalTagSpacing + valueWidth).rounded(.up)
                    + horizontalPadding
            case .compact:
                let valueWidth = StatusBarMetricView.measureTemperatureWidth(sample, font: StatusBarMetricView.compactValueFont)
                return valueWidth.rounded(.up) + horizontalPadding
            }
        case .iconAndTemperature:
            let valueWidth = StatusBarMetricView.measureTemperatureWidth(sample, font: StatusBarMetricView.inlineValueFont)
            return (StatusBarMetricView.iconPointWidth + StatusBarMetricView.iconSpacing + valueWidth).rounded(.up)
                + horizontalPadding
        case .iconOnly:
            return 22
        }
    }
}

/// Click-transparent, custom CoreText-drawn subview hosted inside `NSStatusBarButton`.
/// Draws vector glyphs with font smoothing and vibrancy disabled so stroke weight stays
/// uniformly thin across light/dark Spaces and 1x/2x monitors, with tight native spacing
/// inspired by `exelban/stats` (Mini / Vertical Tag) and `eul` (Compact Inline).
@MainActor
final class StatusBarMetricView: NSView {
    static let stackedLabelFont = appleMenuBarFont(size: 7.0, weight: .medium, tabularDigits: false)
    static let stackedValueFont = appleMenuBarFont(size: 11.5, weight: .regular, tabularDigits: true)
    static let verticalTagFont = appleMenuBarFont(size: 5.5, weight: .medium, tabularDigits: false)
    static let inlineValueFont = appleMenuBarFont(size: 12.5, weight: .regular, tabularDigits: true)
    static let compactValueFont = appleMenuBarFont(size: 13.0, weight: .regular, tabularDigits: true)

    static let verticalTagWidth: CGFloat = 6.5
    static let verticalTagSpacing: CGFloat = 2.0
    static let iconPointWidth: CGFloat = 13.5
    static let iconSpacing: CGFloat = 2.5

    private static let iconMaxHeight: CGFloat = 13.5
    private static let stackedRowGap: CGFloat = 2.0
    private static let verticalTagGap: CGFloat = 1.0
    private static let microLabelKern: CGFloat = 0.5
    private static let symbolWeightConfig = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .regular)

    /// Builds Apple's official macOS menu bar font (San Francisco Pro / `.AppleSystemUIFont`)
    /// at the requested size and weight, optionally with tabular digits so width stays stable.
    private static func appleMenuBarFont(size: CGFloat, weight: NSFont.Weight, tabularDigits: Bool) -> NSFont {
        let base = NSFont.menuBarFont(ofSize: size)
        var attributes: [NSFontDescriptor.AttributeName: Any] = [
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
        ]
        if tabularDigits {
            attributes[.featureSettings] = [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
            ]]
        }
        let descriptor = base.fontDescriptor.addingAttributes(attributes)
        return NSFont(descriptor: descriptor, size: size)
            ?? (tabularDigits
                ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight))
    }

    private var style: MenuBarTemperatureStyle = .stacked
    private var showIcon = false
    private var symbolImage: NSImage?
    private var temperatureText = ""
    private var thermalZone: ThermalColorZone = .normal

    override var allowsVibrancy: Bool { false }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Pass every mouse event straight through to the parent `NSStatusBarButton`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncBackingScaleAndRedraw()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncBackingScaleAndRedraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncBackingScaleAndRedraw()
    }

    func configureLayout(style: MenuBarTemperatureStyle, showIcon: Bool, image: NSImage?) {
        let nextImage = showIcon ? image : nil
        guard self.style != style || self.showIcon != showIcon || self.symbolImage !== nextImage else { return }
        self.style = style
        self.showIcon = showIcon
        self.symbolImage = nextImage
        needsDisplay = true
    }

    func updateContent(text: String, thermalZone: ThermalColorZone) {
        guard temperatureText != text || self.thermalZone != thermalZone else { return }
        temperatureText = text
        self.thermalZone = thermalZone
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        needsDisplay = true
        CATransaction.commit()
    }

    // MARK: - Measurement Helpers

    static func measureTemperatureWidth(_ text: String, font: NSFont) -> CGFloat {
        let line = makeTemperatureLine(text, font: font, color: NSColor.black.cgColor)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    static func measureMicroLabelWidth(_ text: String) -> CGFloat {
        let line = makeMicroLabelLine(text, font: stackedLabelFont, color: NSColor.black.cgColor, kern: microLabelKern)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func makeTemperatureLine(_ text: String, font: NSFont, color: CGColor) -> CTLine {
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ]
        )
        return CTLineCreateWithAttributedString(attributed)
    }

    private static func makeMicroLabelLine(_ text: String, font: NSFont, color: CGColor, kern: CGFloat) -> CTLine {
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        if kern != 0 {
            attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = kern
        }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let nsContext = NSGraphicsContext.current else { return }
        let ctx = nsContext.cgContext
        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSmoothFonts(false)
        ctx.setShouldSubpixelPositionFonts(true)

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let baseColor = NSColor.labelColor
            let valueColor = resolvedValueColor(base: baseColor)
            let secondaryColor = baseColor.withAlphaComponent(0.72)

            if showIcon {
                drawIconAndTemp(in: ctx, baseColor: baseColor, valueColor: valueColor, scale: scale)
                return
            }
            switch style {
            case .stacked:
                drawStacked(in: ctx, labelColor: secondaryColor, valueColor: valueColor, scale: scale)
            case .verticalTag:
                drawVerticalTag(in: ctx, labelColor: secondaryColor, valueColor: valueColor, scale: scale)
            case .compact:
                drawCompact(in: ctx, valueColor: valueColor, scale: scale)
            }
        }
    }

    private func drawStacked(in ctx: CGContext, labelColor: NSColor, valueColor: NSColor, scale: CGFloat) {
        let labelLine = Self.makeMicroLabelLine(
            "CPU",
            font: Self.stackedLabelFont,
            color: labelColor.cgColor,
            kern: Self.microLabelKern
        )
        let valueLine = Self.makeTemperatureLine(
            temperatureText,
            font: Self.stackedValueFont,
            color: valueColor.cgColor
        )
        let labelWidth = CGFloat(CTLineGetTypographicBounds(labelLine, nil, nil, nil))
        let valueWidth = CGFloat(CTLineGetTypographicBounds(valueLine, nil, nil, nil))

        let valueCap = Self.stackedValueFont.capHeight
        let labelCap = Self.stackedLabelFont.capHeight
        let stackHeight = valueCap + Self.stackedRowGap + labelCap
        let bottomBaselineY = alignToPixel((bounds.height - stackHeight) / 2.0, scale: scale)
        let topBaselineY = alignToPixel(bottomBaselineY + valueCap + Self.stackedRowGap, scale: scale)

        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(
            x: alignToPixel((bounds.width - labelWidth) / 2.0, scale: scale),
            y: topBaselineY
        )
        CTLineDraw(labelLine, ctx)

        ctx.textPosition = CGPoint(
            x: alignToPixel((bounds.width - valueWidth) / 2.0, scale: scale),
            y: bottomBaselineY
        )
        CTLineDraw(valueLine, ctx)
    }

    private func drawVerticalTag(in ctx: CGContext, labelColor: NSColor, valueColor: NSColor, scale: CGFloat) {
        let valueLine = Self.makeTemperatureLine(
            temperatureText,
            font: Self.inlineValueFont,
            color: valueColor.cgColor
        )
        let valueWidth = CGFloat(CTLineGetTypographicBounds(valueLine, nil, nil, nil))
        let totalWidth = Self.verticalTagWidth + Self.verticalTagSpacing + valueWidth
        let startX = alignToPixel((bounds.width - totalWidth) / 2.0, scale: scale)

        let letters = ["U", "P", "C"] // bottom-to-top in non-flipped AppKit coordinates
        let letterCap = Self.verticalTagFont.capHeight
        let tagHeight = letterCap * 3.0 + Self.verticalTagGap * 2.0
        let tagBottomY = alignToPixel((bounds.height - tagHeight) / 2.0, scale: scale)

        ctx.textMatrix = .identity
        for (index, letter) in letters.enumerated() {
            let line = Self.makeMicroLabelLine(letter, font: Self.verticalTagFont, color: labelColor.cgColor, kern: 0)
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let x = alignToPixel(startX + (Self.verticalTagWidth - w) / 2.0, scale: scale)
            let y = alignToPixel(tagBottomY + CGFloat(index) * (letterCap + Self.verticalTagGap), scale: scale)
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
        }

        let valueBaselineY = alignToPixel((bounds.height - Self.inlineValueFont.capHeight) / 2.0, scale: scale)
        ctx.textPosition = CGPoint(
            x: alignToPixel(startX + Self.verticalTagWidth + Self.verticalTagSpacing, scale: scale),
            y: valueBaselineY
        )
        CTLineDraw(valueLine, ctx)
    }

    private func drawCompact(in ctx: CGContext, valueColor: NSColor, scale: CGFloat) {
        let valueLine = Self.makeTemperatureLine(
            temperatureText,
            font: Self.compactValueFont,
            color: valueColor.cgColor
        )
        let textWidth = CGFloat(CTLineGetTypographicBounds(valueLine, nil, nil, nil))
        let baselineY = alignToPixel((bounds.height - Self.compactValueFont.capHeight) / 2.0, scale: scale)

        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(
            x: alignToPixel((bounds.width - textWidth) / 2.0, scale: scale),
            y: baselineY
        )
        CTLineDraw(valueLine, ctx)
    }

    private func drawIconAndTemp(in ctx: CGContext, baseColor: NSColor, valueColor: NSColor, scale: CGFloat) {
        let valueLine = Self.makeTemperatureLine(
            temperatureText,
            font: Self.inlineValueFont,
            color: valueColor.cgColor
        )
        let textWidth = CGFloat(CTLineGetTypographicBounds(valueLine, nil, nil, nil))
        let styledIcon = configuredSymbol()
        let iconSize = styledIcon.map(fittedIconSize) ?? .zero
        let hasIcon = styledIcon != nil && iconSize.width > 0
        let totalWidth = hasIcon ? iconSize.width + Self.iconSpacing + textWidth : textWidth

        var cursorX = alignToPixel((bounds.width - totalWidth) / 2.0, scale: scale)
        if let icon = styledIcon, hasIcon {
            let iconY = alignToPixel((bounds.height - iconSize.height) / 2.0, scale: scale)
            let iconRect = NSRect(origin: NSPoint(x: cursorX, y: iconY), size: iconSize)
            drawIcon(icon, in: iconRect, tint: baseColor, context: ctx, scale: scale)
            cursorX += iconSize.width + Self.iconSpacing
        }

        let baselineY = alignToPixel((bounds.height - Self.inlineValueFont.capHeight) / 2.0, scale: scale)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: alignToPixel(cursorX, scale: scale), y: baselineY)
        CTLineDraw(valueLine, ctx)
    }

    private func resolvedValueColor(base: NSColor) -> NSColor {
        switch thermalZone {
        case .normal: return base
        case .warm: return .systemOrange
        case .hot: return .systemRed
        }
    }

    private func syncBackingScaleAndRedraw() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if layer?.contentsScale != scale {
            layer?.contentsScale = scale
        }
        needsDisplay = true
    }

    private func configuredSymbol() -> NSImage? {
        guard let base = symbolImage else { return nil }
        return base.withSymbolConfiguration(Self.symbolWeightConfig) ?? base
    }

    private func fittedIconSize(for image: NSImage) -> NSSize {
        let raw = image.size
        guard raw.width > 0, raw.height > 0 else { return .zero }
        let ratio = min(1.0, min(Self.iconPointWidth / raw.width, Self.iconMaxHeight / raw.height))
        return NSSize(width: raw.width * ratio, height: raw.height * ratio)
    }

    private func drawIcon(
        _ icon: NSImage,
        in rect: NSRect,
        tint: NSColor,
        context ctx: CGContext,
        scale: CGFloat
    ) {
        var proposed = rect
        guard let cgImage = icon.cgImage(forProposedRect: &proposed, context: NSGraphicsContext.current, hints: nil) else {
            return
        }
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let targetRect: NSRect
        if imageWidth > 0, imageHeight > 0 {
            let fitScale = min(rect.width / imageWidth, rect.height / imageHeight)
            let drawWidth = imageWidth * fitScale
            let drawHeight = imageHeight * fitScale
            targetRect = NSRect(
                x: alignToPixel(rect.midX - drawWidth / 2.0, scale: scale),
                y: alignToPixel(rect.midY - drawHeight / 2.0, scale: scale),
                width: drawWidth,
                height: drawHeight
            )
        } else {
            targetRect = NSRect(
                x: alignToPixel(rect.midX - proposed.width / 2.0, scale: scale),
                y: alignToPixel(rect.midY - proposed.height / 2.0, scale: scale),
                width: proposed.width,
                height: proposed.height
            )
        }
        ctx.saveGState()
        ctx.clip(to: targetRect, mask: cgImage)
        ctx.setFillColor(tint.cgColor)
        ctx.fill(targetRect)
        ctx.restoreGState()
    }

    private func alignToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }
}
