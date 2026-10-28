import Foundation
import SwiftUI

/// Keeps the customer list — and only the customer list — in iCloud Drive.
///
/// Invoices stay local, and payment details stay in the local encrypted vault.
/// That is deliberate: the vault's key lives in this Mac's Keychain and does
/// not travel, so a synced vault would be undecryptable on the other Mac, and
/// making the key travel would weaken the one thing the vault exists to do.
/// Customers carry no secrets, so they are the part that is safe to share.
///
/// This writes straight into the user's iCloud Drive rather than an app
/// container, which needs no iCloud entitlement and no provisioning profile —
/// the app is not sandboxed, so the path is simply readable.
@MainActor
final class CustomerSync: ObservableObject {
    static let shared = CustomerSync()

    @AppStorage("syncCustomersToICloud") var isEnabled = false {
        willSet { objectWillChange.send() }
    }

    @Published private(set) var lastSynced: Date?
    @Published private(set) var lastError: String?

    private var watchTask: Task<Void, Never>?
    private var lastSeenModification: Date?

    /// ~/Library/Mobile Documents/com~apple~CloudDocs — present only when the
    /// user actually has iCloud Drive turned on.
    static var iCloudDriveURL: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var isAvailable: Bool { iCloudDriveURL != nil }

    var folderURL: URL? {
        Self.iCloudDriveURL?.appendingPathComponent("InvoiceGen", isDirectory: true)
    }

    var fileURL: URL? {
        folderURL?.appendingPathComponent("customers.json")
    }

    // MARK: - The file on disk

    private struct Payload: Codable {
        var customers: [Customer] = []
        /// id -> when it was deleted. Without these a merge would resurrect
        /// every customer deleted on the other Mac, since "missing here,
        /// present there" is indistinguishable from "new there".
        var deleted: [String: Date] = [:]
        var writtenAt: Date = Date()
        var writtenBy: String = Host.current().localizedName ?? "a Mac"
    }

    private func read() -> Payload? {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        // The file may be evicted to iCloud and present only as a placeholder.
        try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Payload.self, from: data)
    }

    @discardableResult
    private func write(_ payload: Payload) -> Bool {
        guard let folderURL, let fileURL else { return false }
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
            lastSeenModification = modificationDate()
            lastSynced = Date()
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func modificationDate() -> Date? {
        guard let fileURL else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    // MARK: - Merging

    /// Union by id. Where both sides know a customer, the later `changedAt`
    /// wins; where a tombstone is newer than the customer, it stays deleted.
    /// Field-level merging is deliberately not attempted — for a contact
    /// record, a half-local half-remote address is worse than either one.
    static func merge(local: [Customer], remote: [Customer], deleted: [String: Date]) -> [Customer] {
        var byID: [UUID: Customer] = [:]
        for customer in local { byID[customer.id] = customer }
        for customer in remote {
            if let mine = byID[customer.id] {
                if customer.changedAt > mine.changedAt { byID[customer.id] = customer }
            } else {
                byID[customer.id] = customer
            }
        }
        for (key, when) in deleted {
            guard let id = UUID(uuidString: key), let customer = byID[id] else { continue }
            // An edit made after the delete wins: the customer was brought back.
            if customer.changedAt <= when { byID.removeValue(forKey: id) }
        }
        return byID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: - Public operations

    /// Reads iCloud, merges, writes the union back. Returns the merged list,
    /// or nil when nothing should change.
    @discardableResult
    func sync(local: [Customer]) -> [Customer]? {
        guard isEnabled, Self.isAvailable else { return nil }
        let remote = read()
        let merged = Self.merge(
            local: local,
            remote: remote?.customers ?? [],
            deleted: remote?.deleted ?? [:]
        )
        var payload = remote ?? Payload()
        payload.customers = merged
        payload.writtenAt = Date()
        payload.writtenBy = Host.current().localizedName ?? "a Mac"
        write(payload)
        return merged
    }

    /// Records a deletion so it propagates instead of being undone by the
    /// other Mac's copy on the next merge.
    func recordDeletion(of id: UUID) {
        guard isEnabled, Self.isAvailable else { return }
        var payload = read() ?? Payload()
        payload.deleted[id.uuidString] = Date()
        payload.customers.removeAll { $0.id == id }
        payload.writtenAt = Date()
        write(payload)
    }

    /// True when the iCloud file changed since we last looked.
    func hasRemoteChanges() -> Bool {
        guard isEnabled, Self.isAvailable else { return false }
        guard let current = modificationDate() else { return false }
        guard let seen = lastSeenModification else {
            lastSeenModification = current
            return true
        }
        return current > seen
    }

    func noteSeen() { lastSeenModification = modificationDate() }

    /// Polls for remote edits. NSMetadataQuery is the canonical mechanism, but
    /// it is a lot of machinery for a file that changes when someone types a
    /// customer's address — a slow poll costs nothing and cannot get stuck.
    func startWatching(_ onChange: @escaping () -> Void) {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.isEnabled, !Task.isCancelled else { continue }
                if self.hasRemoteChanges() {
                    self.noteSeen()
                    onChange()
                }
            }
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }
}
