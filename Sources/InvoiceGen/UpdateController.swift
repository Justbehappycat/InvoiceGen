import Foundation
import SwiftUI
import AppKit

/// Drives the update UI. Finding an update never installs it — the download
/// only starts once you say so, and the signature check still has to pass
/// after that.
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    @Published private(set) var isBusy = false

    /// Off switch for the background check. The manual "Check for Updates…"
    /// menu item ignores this — asking is always allowed.
    @AppStorage("automaticUpdateChecks") var automaticChecks = true
    @AppStorage("lastUpdateCheck") private var lastCheck: Double = 0

    private let checkInterval: TimeInterval = 60 * 60 * 24

    // MARK: - Entry points

    /// The menu item. Reports the outcome either way, including "you're current".
    func checkManually() {
        guard !isBusy else { return }
        run(announcingNoUpdate: true)
    }

    /// Called at launch. Silent unless there is something to report, and
    /// rate-limited to once a day so it is not a GitHub request per launch.
    func checkInBackgroundIfDue() {
        guard automaticChecks, !isBusy else { return }
        guard Date().timeIntervalSince1970 - lastCheck > checkInterval else { return }
        run(announcingNoUpdate: false)
    }

    // MARK: - The flow

    private func run(announcingNoUpdate: Bool) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let release = try await Updater.checkForUpdate()
                lastCheck = Date().timeIntervalSince1970
                offer(release)
            } catch Updater.Failure.notNewer(let version) {
                lastCheck = Date().timeIntervalSince1970
                if announcingNoUpdate { informUpToDate(version) }
            } catch {
                // A background check that cannot reach GitHub stays quiet; an
                // offline app should not nag about being offline.
                if announcingNoUpdate { report(error) }
            }
        }
    }

    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "InvoiceGen \(release.version) is available"
        alert.informativeText = notesSummary(release.notes,
                                             current: AppVersion.marketing)
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        install(release)
    }

    private func install(_ release: Release) {
        isBusy = true
        Task {
            do {
                let installed = try await Updater.downloadAndInstall(release)
                isBusy = false
                Updater.relaunch(at: installed)
            } catch {
                isBusy = false
                report(error)
            }
        }
    }

    // MARK: - Messages

    private func notesSummary(_ notes: String, current: String) -> String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = "You have \(current)."
        guard !trimmed.isEmpty else { return header }
        let clipped = trimmed.count > 800 ? String(trimmed.prefix(800)) + "…" : trimmed
        return header + "\n\n" + clipped
    }

    private func informUpToDate(_ version: String) {
        let alert = NSAlert()
        alert.messageText = "InvoiceGen is up to date"
        alert.informativeText = "You are running \(AppVersion.display)."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func report(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not update"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private typealias Release = Updater.Release
