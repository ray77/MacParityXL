import AppKit

/// Round toolbar button drawn by the app instead of the system's glass bezel, so that
/// disabled items stay crisp and hovering gives clear feedback in light and dark mode.
final class ToolbarCircleButton: NSButton {
    private static let side: CGFloat = 34

    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { isHovered = false }
            needsDisplay = true
        }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    init(image: NSImage?, label: String, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side + 6, height: Self.side))
        self.image = image
        self.action = action
        title = ""
        imagePosition = .imageOnly
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.side + 6, height: Self.side)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        if isEnabled { isHovered = true }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let accent = NSColor.controlAccentColor
        let circle = NSRect(x: bounds.midX - Self.side / 2 + 1, y: bounds.midY - Self.side / 2 + 1,
                            width: Self.side - 2, height: Self.side - 2)
        let path = NSBezierPath(ovalIn: circle)

        // Background.
        let fill: NSColor
        if !isEnabled {
            fill = isDark ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 0, alpha: 0.035)
        } else if isHighlighted {
            fill = accent.withAlphaComponent(isDark ? 0.55 : 0.32)
        } else if isHovered {
            fill = accent.withAlphaComponent(isDark ? 0.38 : 0.2)
        } else {
            fill = isDark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.07)
        }
        fill.setFill()
        path.fill()

        // Outline: a hairline normally, the accent color while hovered.
        if isEnabled && (isHovered || isHighlighted) {
            accent.withAlphaComponent(isDark ? 0.9 : 0.75).setStroke()
            path.lineWidth = 1.5
        } else {
            (isDark ? NSColor(white: 1, alpha: isEnabled ? 0.12 : 0.06) : NSColor(white: 0, alpha: isEnabled ? 0.1 : 0.05)).setStroke()
            path.lineWidth = 1
        }
        path.stroke()

        // Symbol.
        guard let image else { return }
        let tint: NSColor
        if !isEnabled {
            tint = isDark ? NSColor(white: 1, alpha: 0.28) : NSColor(white: 0, alpha: 0.24)
        } else if isHovered || isHighlighted {
            tint = isDark ? .white : accent.blended(withFraction: 0.25, of: .black) ?? accent
        } else {
            tint = .labelColor
        }
        let size = image.size
        let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        // Tint with the opaque color and apply its alpha when drawing; a translucent
        // tint would let the template's black show through.
        Self.tinted(image, with: tint.withAlphaComponent(1))
            .draw(in: rect, from: .zero, operation: .sourceOver, fraction: tint.alphaComponent, respectFlipped: true, hints: nil)
    }

    private static func tinted(_ image: NSImage, with color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// Toolbar item whose custom button follows the responder chain's validation,
/// like a bordered item does on its own.
final class ValidatedToolbarItem: NSToolbarItem {
    // The toolbar also sets this itself (e.g. while a sheet is open); keep the button in sync.
    override var isEnabled: Bool {
        didSet { (view as? NSButton)?.isEnabled = isEnabled }
    }

    override func validate() {
        guard let action, let button = view as? NSButton else { return }
        let target = NSApp.target(forAction: action, to: nil, from: self)
        var enabled = target != nil
        if let validator = target as? NSUserInterfaceValidations {
            enabled = validator.validateUserInterfaceItem(self)
        }
        isEnabled = enabled
        button.isEnabled = enabled
    }
}
