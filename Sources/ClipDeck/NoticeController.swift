import AppKit

private final class NoticePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A short-lived, non-interactive message. It never changes the active app.
@MainActor
final class NoticeController {
    private let panel: NoticePanel
    private let contentView: NSView
    private let surface: ThemedSurfaceView
    private let label: NSTextField
    private var generation = 0

    init() {
        contentView = NSView(frame: .zero)
        surface = ThemedSurfaceView(hostedView: contentView, cornerRadius: 14)

        label = NSTextField(wrappingLabelWithString: "")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.isSelectable = false
        label.maximumNumberOfLines = 4
        contentView.addSubview(label)

        panel = NoticePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "ClipDeck"
        panel.contentView = surface
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        applyTheme(.current)
    }

    func applyTheme(_ theme: AppearanceTheme) {
        panel.appearance = theme.preferredAppearance
        surface.applyTheme(theme)
        label.textColor = theme == .current
            ? NSColor.white.withAlphaComponent(0.93) : theme.primaryTextColor
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
    }

    func show(_ text: String, on screen: NSScreen) {
        generation += 1
        let thisGeneration = generation
        let visible = screen.visibleFrame
        let maxWidth = min(560, max(160, visible.width - 48))
        let font = label.font ?? NSFont.systemFont(ofSize: 12)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        let singleLineWidth = (text as NSString).size(withAttributes: attributes).width
        let width = min(maxWidth, max(240, singleLineWidth.rounded(.up) + 40))
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: width - 40, height: 120),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let textHeight = min(64, max(18, measured.height.rounded(.up)))
        let height = textHeight + 28
        panel.setFrame(
            NSRect(x: visible.midX - width / 2, y: visible.minY + 28, width: width, height: height),
            display: true
        )
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        label.stringValue = text
        label.frame = NSRect(x: 20, y: 14, width: width - 40, height: textHeight)
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
            guard let self, self.generation == thisGeneration else { return }
            self.hide()
        }
    }

    func hide() {
        generation += 1
        panel.orderOut(nil)
        label.stringValue = ""
    }
}
