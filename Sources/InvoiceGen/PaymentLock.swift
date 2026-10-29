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


/// The single control for locking and unlocking protected values.
///
/// Everywhere that hides something behind the lock uses this, so locking and
/// unlocking are the same button, in the same place, at the same size. They
/// used to be two different controls in two different corners -- a full-size
/// "Unlock to edit" below the list when locked, and a small borderless "Lock
/// now" above it when unlocked -- which meant the control moved out from under
/// the pointer the moment you used it.
struct LockButton: View {
    @ObservedObject private var lock = PaymentLock.shared

    /// Shown in the system's authentication prompt: "… wants to <reason>".
    var unlockReason: String
    /// What the lock is protecting here, shown while locked.
    var lockedHint: String
    var unlockedHint: String = "Unlocked — re-locks after 5 minutes."

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if lock.isUnlocked { lock.lock() } else { lock.unlock(reason: unlockReason) }
            } label: {
                Label(lock.isUnlocked ? "Lock" : "Unlock",
                      systemImage: lock.isUnlocked ? "lock.open.fill" : "lock.fill")
                    // Fixed width so the button does not resize as the word
                    // changes and slide out from under the pointer.
                    .frame(minWidth: 72, alignment: .leading)
            }
            if let failure = lock.lastFailure, !lock.isUnlocked {
                Text(failure).font(.caption).foregroundStyle(.orange)
            } else {
                Text(lock.isUnlocked ? unlockedHint : lockedHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
