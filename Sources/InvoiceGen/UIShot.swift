import SwiftUI
import AppKit

/// Offscreen capture of the real UI, so layout can be checked without a display:
/// InvoiceGen --render-ui out.png 1440 900 [invoices|customers|items|settings]
///
/// ImageRenderer refuses to draw a NavigationSplitView, so this hosts the real
/// view in an offscreen window and caches its display instead.
@MainActor
private func waitForSecretsForCapture(_ store: AppStore) {
    let deadline = Date().addingTimeInterval(20)
    while !store.secretsLoaded, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}

enum UIShot {
    @MainActor
    static func capture(path: String, width: CGFloat, height: CGFloat, screen: String) {
        let section = SidebarSection(rawValue: screen) ?? .invoices
        let store = AppStore.shared
        waitForSecretsForCapture(store)
        let focus = AppFocus()
        focus.invoiceID = store.data.invoices.first?.id
        focus.customerID = store.data.customers.first?.id
        focus.projectID = store.data.projects.first?.id

        // "sidebar" captures the left column on its own: inside a real
        // NavigationSplitView its material background defeats cacheDisplay.
        let root = Group {
            if screen == "sidebar" {
                SidebarView(
                    section: .constant(.invoices), search: .constant(""), statusFilter: .constant(nil)
                )
                .background(Color(nsColor: .windowBackgroundColor))
            } else {
                ContentView(initialSection: section)
            }
        }
        .environmentObject(store)
        .environmentObject(focus)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()

        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
    }
}
