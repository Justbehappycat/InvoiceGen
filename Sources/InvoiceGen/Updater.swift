import Foundation
import Security
import AppKit

/// Checking GitHub for a newer build, and installing it.
///
/// An update is remote code execution: whatever we download gets to run as you,
/// on a machine holding your payment details. So the only thing standing
/// between a hostile release and your Mac is the signature check in
/// `verifySignature(of:)`. It runs *before* anything is installed, and it pins
/// the download to this app's own signing identity — read from the running
/// bundle rather than written down here, so the two can never drift apart.
enum Updater {
    static let repository = "Justbehappycat/InvoiceGen"

    enum Failure: LocalizedError {
        case network(String)
        case noRelease
        case malformed(String)
        case notNewer(String)
        case unsigned
        case wrongIdentity(String)
        case extractionFailed(String)
        case notWritable(String)

        var errorDescription: String? {
            switch self {
            case .network(let detail):      return "Could not reach GitHub: \(detail)"
            case .noRelease:                return "No published release was found."
            case .malformed(let detail):    return "The release could not be read: \(detail)"
            case .notNewer(let version):    return "You already have the newest version (\(version))."
            case .unsigned:
                return "This copy of InvoiceGen is not signed with a Developer ID, "
                     + "so an update cannot be verified. Rebuild with build.sh."
            case .wrongIdentity(let detail):
                return "The downloaded app is NOT signed by you — it was rejected and "
                     + "nothing was installed. (\(detail))"
            case .extractionFailed(let d):  return "The download could not be unpacked: \(d)"
            case .notWritable(let path):
                return "No permission to replace \(path). Move InvoiceGen to /Applications "
                     + "with your own account, or update by hand."
            }
        }
    }

    // MARK: - Versions

    /// Compares dotted numeric versions: 0.15.0 > 0.9.3, and 1.0 == 1.0.0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    struct Release {
        var version: String      // "0.15.0" — the tag with any leading "v" removed
        var notes: String
        var downloadURL: URL
    }

    // MARK: - Checking

    static func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("InvoiceGen/\(AppVersion.marketing)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw Failure.network(error.localizedDescription) }

        guard let http = response as? HTTPURLResponse else { throw Failure.network("no response") }
        if http.statusCode == 404 { throw Failure.noRelease }
        guard http.statusCode == 200 else { throw Failure.network("HTTP \(http.statusCode)") }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String
        else { throw Failure.malformed("no tag_name") }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let notes = (root["body"] as? String) ?? ""

        // The asset must be the zipped app, served from GitHub over HTTPS.
        guard let assets = root["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let urlString = asset["browser_download_url"] as? String,
              let url = URL(string: urlString),
              url.scheme == "https",
              (url.host ?? "").hasSuffix("github.com")
        else { throw Failure.malformed("no .zip asset served from github.com") }

        return Release(version: version, notes: notes, downloadURL: url)
    }

    /// Returns the release only when it is genuinely newer than what is running.
    static func checkForUpdate() async throws -> Release {
        let release = try await latestRelease()
        guard isNewer(release.version, than: AppVersion.marketing) else {
            throw Failure.notNewer(AppVersion.marketing)
        }
        return release
    }

    // MARK: - The signature check

    /// The code requirement the download must satisfy, derived from the running
    /// app so it tracks the real signing identity instead of a copied-out
    /// constant. Returns nil for an unsigned or ad-hoc build, which is why a
    /// dev build refuses to self-update rather than installing unchecked code.
    static func expectedRequirement() -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return nil }
        var staticSelf: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &staticSelf) == errSecSuccess,
              let staticSelf else { return nil }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticSelf, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let dict = info as? [String: Any],
              let identifier = dict[kSecCodeInfoIdentifier as String] as? String,
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty
        else { return nil }

        // anchor apple generic + the Developer ID leaf OID + our team: this is
        // the same shape codesign prints as the designated requirement.
        return """
        identifier "\(identifier)" and anchor apple generic \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ \
        and certificate leaf[subject.OU] = "\(team)"
        """
    }

    /// Throws unless `bundle` is intact, unmodified, and signed by us.
    static func verifySignature(of bundle: URL) throws {
        guard let requirementText = expectedRequirement() else { throw Failure.unsigned }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
                == errSecSuccess, let requirement
        else { throw Failure.wrongIdentity("could not build the requirement") }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code
        else { throw Failure.wrongIdentity("the download is not code we can read") }

        // kSecCSCheckNestedCode makes this check everything inside the bundle,
        // not just the main executable; CheckAllArchitectures covers each slice.
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            throw Failure.wrongIdentity(message)
        }
    }

    // MARK: - Download and install

    /// Downloads, verifies, and swaps the bundle in place. Returns the installed
    /// location. Nothing is installed unless `verifySignature` passed.
    static func downloadAndInstall(_ release: Release) async throws -> URL {
        let target = Bundle.main.bundleURL

        // Fail early and clearly rather than half-way through the swap.
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw Failure.notWritable(target.path)
        }

        // A replacement directory sits on the same volume as the target, which
        // is what lets the final swap be an atomic rename rather than a copy.
        let work = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let zip = work.appendingPathComponent("InvoiceGen.zip")
        do {
            let (downloaded, response) = try await URLSession.shared.download(from: release.downloadURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw Failure.network("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            try FileManager.default.moveItem(at: downloaded, to: zip)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.network(error.localizedDescription)
        }

        // ditto, not unzip: unzip discards the extended attributes that carry
        // the code signature, which would make every download look tampered.
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try runDitto(["-x", "-k", zip.path, unpacked.path])

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: unpacked, includingPropertiesForKeys: nil)) ?? []
        guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
            throw Failure.extractionFailed("no .app inside the archive")
        }

        // ---- Nothing below this line runs if the signature is wrong. ----
        try verifySignature(of: newApp)

        // Belt and braces: the bundle we just verified must also *claim* to be
        // the newer version, so a replayed older release cannot be installed.
        let plist = newApp.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: plist),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let shipped = info["CFBundleShortVersionString"] as? String,
           !isNewer(shipped, than: AppVersion.marketing) {
            throw Failure.notNewer(shipped)
        }

        _ = try FileManager.default.replaceItemAt(target, withItemAt: newApp)
        return target
    }

    private static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() } catch { throw Failure.extractionFailed(error.localizedDescription) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure.extractionFailed(text.isEmpty ? "ditto exited \(process.terminationStatus)" : text)
        }
    }

    /// Relaunches the freshly installed copy and quits this one.
    @MainActor
    static func relaunch(at url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
