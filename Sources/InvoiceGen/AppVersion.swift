import Foundation

/// What build is this? `build.sh` stamps the marketing version from `VERSION`,
/// the build number from the commit count, and the short commit hash (with a
/// trailing `+` when the tree was dirty) into Info.plist.
enum AppVersion {
    static var marketing: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    static var commit: String {
        Bundle.main.infoDictionary?["InvoiceGenCommit"] as? String ?? "unbuilt"
    }

    /// "0.5.0 (build 7 · a1b2c3d)" — or "dev build" when running from `swift run`.
    static var display: String {
        guard Bundle.main.infoDictionary?["CFBundleShortVersionString"] != nil else {
            return "dev build (run from source)"
        }
        return "\(marketing) (build \(build) · \(commit))"
    }
}
