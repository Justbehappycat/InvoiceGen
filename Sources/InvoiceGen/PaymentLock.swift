import SwiftUI
import LocalAuthentication
import AppKit

/// Payment details are read-only until you authenticate. That is what stops a
/// silent change: anything editing them has to get past Touch ID or your login
/// password first, and the attempt is visible on screen.
@MainActor
final class PaymentLock: ObservableObject {
    static let shared = PaymentLock()

    @Published private(set) var isUnlocked = false
    @Published private(set) var lastFailure: String?

    /// How long an unlock lasts before it re-locks itself.
    private let window: TimeInterval = 5 * 60
    private var relockTimer: Timer?

    func unlock(reason: String = "edit your saved payment details") {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, authError in
                Task { @MainActor in
                    if success {
                        self.grantAccess()
                    } else {
                        let code = (authError as? LAError)?.code
                        self.lastFailure = (code == .userCancel || code == .appCancel)
                            ? nil
                            : "Authentication failed."
                    }
                }
            }
            return
        }

        // No Touch ID and no password policy available (rare, but possible on an
        // unsigned build). Fall back to an explicit confirmation and say so.
        let alert = NSAlert()
        alert.messageText = "Unlock payment details?"
        alert.informativeText = """
        This Mac didn't offer Touch ID or a password prompt, so this is only a \
        confirmation, not an authentication check.
        """
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { grantAccess() }
    }

    func lock() {
        isUnlocked = false
        relockTimer?.invalidate()
        relockTimer = nil
    }

    private func grantAccess() {
        lastFailure = nil
        isUnlocked = true
        relockTimer?.invalidate()
        relockTimer = Timer.scheduledTimer(withTimeInterval: window, repeats: false) { _ in
            Task { @MainActor in self.lock() }
        }
    }

    /// Masks a stored value for display while locked: enough to recognise the
    /// entry, not enough to use it.
    static func mask(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        if value.contains("@") {
            let parts = value.split(separator: "@", maxSplits: 1)
            let name = String(parts[0])
            let head = name.prefix(1)
            return "\(head)•••@\(parts.count > 1 ? String(parts[1]) : "")"
        }
        if value.count <= 4 { return String(repeating: "•", count: value.count) }
        return String(repeating: "•", count: max(4, value.count - 4)) + value.suffix(4)
    }
}
