import SwiftUI
import AppKit

/// SwiftUI's `Settings` scene depends on a menu selector whose name has moved
/// between macOS releases, so the window is owned directly instead. ⌘, and the
/// sidebar's gear both come through here.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(store: AppStore, focus: AppFocus) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let size = NSSize(width: 1120, height: 780)
        // The hosting controller reports a near-zero fitting size for a split
        // view of scroll views, and AppKit will happily shrink the window to it
        // — hence the explicit frame on the root view and on the window.
        let root = SettingsView()
            .environmentObject(store)
            .environmentObject(focus)
            .frame(minWidth: 900, idealWidth: size.width, minHeight: 620, idealHeight: size.height)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        let hosting = NSHostingController(rootView: root)
        hosting.view.frame = NSRect(origin: .zero, size: size)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.contentMinSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        AppStore.shared.saveNow()
    }
}
