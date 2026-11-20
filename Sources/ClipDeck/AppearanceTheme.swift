import AppKit

/// Stable raw values are stored in UserDefaults; availability affects rendering
/// without changing the user's saved choice.
enum AppearanceTheme: String, CaseIterable {
    case current
    case liquidGlass
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .current: return "Текущая"
        case .liquidGlass: return "Liquid Glass"
        case .system: return "Системная"
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        }
    }

    @MainActor
    var isAvailable: Bool {
        guard self == .liquidGlass else { return true }
        // build.sh enables native glass only for its explicitly selected SDK
        // when that SDK is macOS 26 or later. Older SDKs/toolchains remain valid.
        #if CLIPDECK_HAS_GLASS && compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    @MainActor
    var effectiveTheme: AppearanceTheme {
        self == .liquidGlass && !isAvailable ? .system : self
    }

    @MainActor
    var preferredAppearance: NSAppearance? {
        switch effectiveTheme {
        case .current, .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        case .system, .liquidGlass: return nil
        }
    }

    @MainActor
    var primaryTextColor: NSColor {
        effectiveTheme == .current ? .white : .labelColor
    }

    @MainActor
    var secondaryTextColor: NSColor {
        effectiveTheme == .current ? NSColor.white.withAlphaComponent(0.6) : .secondaryLabelColor
    }

    @MainActor
    func accent(isCopy: Bool) -> NSColor {
        guard effectiveTheme == .current else { return isCopy ? .systemGreen : .systemBlue }
        return isCopy
            ? NSColor(srgbRed: 0.38, green: 0.91, blue: 0.69, alpha: 1)
            : NSColor(srgbRed: 0.48, green: 0.72, blue: 1.0, alpha: 1)
    }
}
