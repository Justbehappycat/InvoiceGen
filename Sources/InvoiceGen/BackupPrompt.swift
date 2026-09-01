import AppKit

/// A backup is the easiest file in the world to mail to the wrong person, so
/// payment details are left out unless you say otherwise — and saying otherwise
/// costs an authentication.
@MainActor
enum BackupPrompt {
    static func run(store: AppStore) {
        let alert = NSAlert()
        alert.messageText = "Include payment details in the backup?"
        alert.informativeText = """
        Payment details are normally kept out of backups: the backup file is \
        plain JSON, unlike the encrypted vault they live in. Everything else \
        (invoices, customers, items, templates) is included either way.
        """
        alert.addButton(withTitle: "Exclude payment details")
        alert.addButton(withTitle: "Include them")
        alert.addButton(withTitle: "Cancel")

        let choice = alert.runModal()
        if choice == .alertThirdButtonReturn { return }

        var includeSecrets = false
        if choice == .alertSecondButtonReturn {
            if !PaymentLock.shared.isUnlocked {
                PaymentLock.shared.unlock(reason: "include payment details in a backup")
            }
            guard PaymentLock.shared.isUnlocked else { return }
            includeSecrets = true
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "InvoiceGen-Backup-\(Fmt.fileDate(Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.exportBackup(to: url, includePaymentDetails: includeSecrets)
    }
}
