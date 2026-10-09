import Foundation
import Security

enum AppUpdate {
    enum Failure: LocalizedError {
        case invalidSignature
        case missingExecutable
        case rollbackFailed(backup: URL)

        var errorDescription: String? {
            switch self {
            case .invalidSignature:
                return "the downloaded app is damaged or does not match this app's signing identity"
            case .missingExecutable:
                return "the downloaded app is missing an executable controller or interface"
            case .rollbackFailed(let backup):
                return "the update failed and the working app could not be restored; it is preserved at \(backup.path)"
            }
        }
    }

    private static let pendingKey = "pendingSelfUpdate.v1"
    private static let backupPrefix = "RazerCtl.previous-"

    private struct Pending: Codable {
        var installedPath: String
        var backupPath: String
        var version: String
    }

    /// An update must satisfy the running app's signing identity as well as
    /// validate every sealed resource, nested executable, and architecture.
    static func verifySignature(at candidate: URL, matching current: URL) throws {
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        var currentCode: SecStaticCode?
        var candidateCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(current as CFURL, [], &currentCode) == errSecSuccess,
              let currentCode,
              SecStaticCodeCheckValidity(currentCode, flags, nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(currentCode, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode) == errSecSuccess,
              let candidateCode,
              SecStaticCodeCheckValidity(candidateCode, flags, requirement) == errSecSuccess else {
            throw Failure.invalidSignature
        }
    }

    static func requireExecutables(at bundle: URL) throws {
        guard ["RazerCtl", "razerctl-core"].allSatisfy({
            FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("Contents/MacOS/" + $0).path)
        }) else { throw Failure.missingExecutable }
    }

    /// Retain the original until the successor confirms its own startup.
    /// The injected operations allow failure checks without launching an app.
    static func install(staged: URL, current: URL, version: String,
                        defaults: UserDefaults = .standard,
                        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
                        launch: (URL) throws -> Void) throws {
        try requireExecutables(at: staged)
        let files = FileManager.default
        let installed = current.standardizedFileURL
        let backup = installed.deletingLastPathComponent()
            .appendingPathComponent(backupPrefix + UUID().uuidString + ".app")
        let pending = Pending(installedPath: installed.path, backupPath: backup.path, version: version)
        let marker = try JSONEncoder().encode(pending)
        try move(installed, backup)
        do {
            try move(staged, installed)
            defaults.set(marker, forKey: pendingKey)
            try launch(installed)
        } catch {
            if defaults.data(forKey: pendingKey) == marker { defaults.removeObject(forKey: pendingKey) }
            do {
                if files.fileExists(atPath: installed.path) { try files.removeItem(at: installed) }
                try move(backup, installed)
            } catch {
                throw Failure.rollbackFailed(backup: backup)
            }
            throw error
        }
    }

    /// Only the intended successor can retire its transaction's backup.
    static func finishInstallation(current: URL, version: String,
                                   defaults: UserDefaults = .standard) -> String? {
        guard let data = defaults.data(forKey: pendingKey),
              let pending = try? JSONDecoder().decode(Pending.self, from: data) else { return nil }
        let installed = current.standardizedFileURL
        let backup = URL(fileURLWithPath: pending.backupPath).standardizedFileURL
        let name = backup.deletingPathExtension().lastPathComponent
        guard pending.installedPath == installed.path, pending.version == version,
              backup != installed,
              backup.deletingLastPathComponent() == installed.deletingLastPathComponent(),
              backup.pathExtension == "app", name.hasPrefix(backupPrefix),
              UUID(uuidString: String(name.dropFirst(backupPrefix.count))) != nil else { return nil }
        try? FileManager.default.removeItem(at: backup)
        defaults.removeObject(forKey: pendingKey)
        return pending.version
    }
}
