import AppKit

/// Keep this file named ClipDeckMain.swift: a file named main.swift selects
/// top-level entry-point mode and conflicts with the @main declaration.
@main
@MainActor
enum ClipDeckMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)

        // NSApplication.delegate is weak. Keep the delegate alive for the
        // complete synchronous AppKit event loop, including release builds.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
