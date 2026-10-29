import SwiftUI
import AppKit

/// Offscreen hosting of the real UI, used by `--render-ui` to look at layout and
/// by `--selftest-ui` to check it:
/// InvoiceGen --render-ui out.png 1440 900 [invoices|customers|items|settings] [light|dark]
///
/// ImageRenderer refuses to draw a NavigationSplitView, so this hosts the real
/// view in an offscreen window. The window toolbar is bridged in (macOS 14+),
/// so toolbar items exist, take part in layout, and can be audited.
///
/// What a render can be trusted for: layout, text, alignment, widths. What it
/// can't: glass materials and the sidebar's selection, which need a live
/// window to draw and come out faint or black here. Judge those live.
@MainActor
private func waitForSecretsForCapture(_ store: AppStore) {
    let deadline = Date().addingTimeInterval(20)
    while !store.secretsLoaded, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}

enum UIShot {
    enum Selection: String { case single, multiple, trashed, none }

    /// An offscreen window still autosaves its split positions, toolbar and
    /// frame -- into the *real* app's preferences, since a render runs under the
    /// real bundle id. Left alone, rendering at 1100pt quietly changes the
    /// widths the user's own window opens with next time. This snapshots just
    /// those AppKit keys and puts them back, leaving every other preference --
    /// including anything the running app writes meanwhile -- untouched.
    static func preservingWindowState() -> () -> Void {
        guard let domain = Bundle.main.bundleIdentifier else { return {} }
        let prefixes = ["NSSplitView Subview Frames", "NSWindow Frame", "NSToolbar Configuration",
                        "NSNavPanel", "NSTableView"]
        func relevant() -> [String: Any] {
            (UserDefaults.standard.persistentDomain(forName: domain) ?? [:])
                .filter { key, _ in prefixes.contains { key.hasPrefix($0) } }
        }
        let before = relevant()
        return {
            UserDefaults.standard.synchronize()
            let after = relevant()
            for key in after.keys where before[key] == nil {
                CFPreferencesSetAppValue(key as CFString, nil, domain as CFString)
            }
            for (key, value) in before {
                CFPreferencesSetAppValue(key as CFString, value as CFPropertyList, domain as CFString)
            }
            CFPreferencesAppSynchronize(domain as CFString)
        }
    }

    /// One window configuration. Preferences it needs (preview shown, zoom) go
    /// into the volatile argument domain -- read by @AppStorage like any
    /// preference, but never written to disk -- so a test can never change the
    /// user's saved settings.
    struct Configuration: CustomStringConvertible {
        var name: String
        var width: CGFloat
        var height: CGFloat
        var section: SidebarSection = .invoices
        var dark = false
        var preview = true
        var zoom: PreviewZoom = .fitWidth
        var selection: Selection = .single

        var description: String { "\(name) (\(Int(width))×\(Int(height)))" }
    }

    @MainActor
    static func capture(path: String, width: CGFloat, height: CGFloat, screen: String) {
        if screen == "sidebar" {
            captureSidebar(path: path, width: width, height: height)
            return
        }
        let config = Configuration(
            name: screen, width: width, height: height,
            section: SidebarSection(rawValue: screen) ?? .invoices,
            dark: NSApp.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
            preview: UserDefaults.standard.object(forKey: "showInvoicePreview") as? Bool ?? true
        )
        let restore = preservingWindowState()
        defer { restore() }
        let (window, _) = host(config)
        writePNG(of: window, to: path)
        window.orderOut(nil)
    }

    /// Builds the window for a configuration and lets it settle.
    @MainActor
    static func host(_ config: Configuration) -> (NSWindow, NSView) {
        UserDefaults.standard.setVolatileDomain(
            ["showInvoicePreview": config.preview, "previewZoom": config.zoom.storage],
            forName: UserDefaults.argumentDomain
        )
        let store = AppStore.shared
        waitForSecretsForCapture(store)

        let focus = AppFocus()
        let live = store.data.invoices.filter { !$0.isTrashed }
        switch config.selection {
        case .single:
            focus.invoiceID = live.first?.id
        case .multiple:
            focus.select(Set(live.prefix(2).map(\.id)))
        case .trashed:
            focus.invoiceID = store.data.invoices.first { $0.isTrashed }?.id
        case .none:
            focus.invoiceID = nil
        }
        focus.customerID = store.data.customers.first?.id
        focus.projectID = store.data.projects.first?.id

        let root = ContentView(initialSection: config.section)
            .environmentObject(store)
            .environmentObject(focus)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: config.width, height: config.height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: config.dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: root)
        if #available(macOS 14.0, *) {
            host.sceneBridgingOptions = [.toolbars, .title]
        }
        host.frame = NSRect(x: 0, y: 0, width: config.width, height: config.height)
        window.contentView = host
        window.setContentSize(NSSize(width: config.width, height: config.height))
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()

        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        return (window, host)
    }

    /// The whole window, toolbar included, not just the content view.
    @MainActor
    static func writePNG(of window: NSWindow, to path: String) {
        guard let frameView = window.contentView?.superview ?? window.contentView,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// The left column on its own: inside a real NavigationSplitView its
    /// material background defeats cacheDisplay.
    @MainActor
    private static func captureSidebar(path: String, width: CGFloat, height: CGFloat) {
        let restore = preservingWindowState()
        defer { restore() }
        let store = AppStore.shared
        waitForSecretsForCapture(store)
        let focus = AppFocus()
        focus.invoiceID = store.data.invoices.first?.id
        let root = SidebarView(
            section: .constant(.invoices), search: .constant(""), statusFilter: .constant(nil)
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .environmentObject(store)
        .environmentObject(focus)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        writePNG(of: window, to: path)
        window.orderOut(nil)
    }
}
