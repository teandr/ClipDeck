import AppKit

/// Hosts the same content view in either a visual-effect material or native
/// Liquid Glass. The content retains its own coordinate system and callbacks.
@MainActor
final class ThemedSurfaceView: NSView {
    private let hostedView: NSView
    private let surfaceCornerRadius: CGFloat
    private var surfaceView: NSView?
    private var appliedTheme: AppearanceTheme?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(hostedView: NSView, cornerRadius: CGFloat) {
        self.hostedView = hostedView
        self.surfaceCornerRadius = max(CGFloat(0), cornerRadius)
        super.init(frame: hostedView.frame)
        autoresizesSubviews = true
        applyTheme(.current)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(hostedView:cornerRadius:)") }

    func applyTheme(_ theme: AppearanceTheme) {
        let effectiveTheme = theme.effectiveTheme
        appearance = effectiveTheme.preferredAppearance
        // Inheritance is essential when switching back from a forced light or
        // dark theme to the system's live appearance.
        hostedView.appearance = nil
        guard appliedTheme != effectiveTheme || surfaceView == nil else {
            updateBorder()
            return
        }
        appliedTheme = effectiveTheme
        detachSurface()

        #if CLIPDECK_HAS_GLASS && compiler(>=6.2)
        if #available(macOS 26.0, *), effectiveTheme == .liquidGlass {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = surfaceCornerRadius
            // Apple guarantees placement inside glass only for contentView,
            // not for arbitrary subviews added directly to NSGlassEffectView.
            glass.contentView = hostedView
            install(glass)
            return
        }
        #endif

        let material = NSVisualEffectView(frame: bounds)
        material.material = effectiveTheme == .current ? .hudWindow : .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = surfaceCornerRadius
        material.layer?.masksToBounds = true
        material.layer?.borderWidth = 1
        material.addSubview(hostedView)
        install(material)
    }

    override func layout() {
        super.layout()
        resizeContents()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
        hostedView.needsDisplay = true
    }

    private func detachSurface() {
        #if CLIPDECK_HAS_GLASS && compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = surfaceView as? NSGlassEffectView {
            glass.contentView = nil
        }
        #endif
        // Our strong reference keeps hostedView alive while the old surface
        // releases it. It is never attached to both surfaces at once.
        hostedView.removeFromSuperview()
        surfaceView?.removeFromSuperview()
        surfaceView = nil
    }

    private func install(_ surface: NSView) {
        surfaceView = surface
        surface.appearance = nil
        surface.autoresizingMask = [.width, .height]
        hostedView.autoresizingMask = [.width, .height]
        addSubview(surface)
        resizeContents()
        updateBorder()
        needsLayout = true
        hostedView.needsLayout = true
        hostedView.needsDisplay = true
    }

    private func resizeContents() {
        guard let surface = surfaceView else { return }
        surface.frame = bounds
        hostedView.frame = surface.bounds
    }

    private func updateBorder() {
        guard let material = surfaceView as? NSVisualEffectView else { return }
        // CGColor is a resolved value, so refresh it under this view's actual
        // appearance whenever macOS changes between light and dark.
        material.effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = appliedTheme == .current
                ? NSColor.white.withAlphaComponent(0.16)
                : NSColor.separatorColor
            material.layer?.borderColor = color.cgColor
        }
    }
}
