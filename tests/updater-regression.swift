import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

func sign(_ url: URL, identifier: String? = nil) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["--force", "--sign", "-"]
        + (identifier.map { ["--identifier", $0] } ?? []) + [url.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    check(process.terminationStatus == 0, "Fixture signing failed")
}

let files = FileManager.default
let directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let current = directory.appendingPathComponent("Current.app")
let executable = "Contents/MacOS/RazerCtl"
let core = "Contents/MacOS/razerctl-core"
try files.createDirectory(at: current.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
try files.createDirectory(at: current.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
let plist: [String: Any] = ["CFBundleExecutable": "RazerCtl", "CFBundleIdentifier": "local.razerctl.update-test",
                            "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    .write(to: current.appendingPathComponent("Contents/Info.plist"))
for path in [executable, core] {
    try files.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: current.appendingPathComponent(path))
    try sign(current.appendingPathComponent(path))
}
try Data("sealed resource".utf8).write(to: current.appendingPathComponent("Contents/Resources/resource.txt"))
try sign(current)

func copyCandidate(_ name: String) throws -> URL {
    let candidate = directory.appendingPathComponent(name + ".app")
    try files.copyItem(at: current, to: candidate)
    return candidate
}

func rejected(_ candidate: URL) -> Bool {
    do { try AppUpdate.verifySignature(at: candidate, matching: current); return false }
    catch { return true }
}

let valid = try copyCandidate("Valid")
try AppUpdate.verifySignature(at: valid, matching: current)
let changedCore = try copyCandidate("ChangedCore")
try files.removeItem(at: changedCore.appendingPathComponent(core))
try Data("#!/bin/sh\nexit 0\n".utf8).write(to: changedCore.appendingPathComponent(core))
check(rejected(changedCore), "A replaced nested controller must fail validation")
let changedResource = try copyCandidate("ChangedResource")
try Data("changed".utf8).write(to: changedResource.appendingPathComponent("Contents/Resources/resource.txt"))
check(rejected(changedResource), "A modified sealed resource must fail validation")
let wrongIdentity = try copyCandidate("WrongIdentity")
try sign(wrongIdentity, identifier: "local.razerctl.other")
check(rejected(wrongIdentity), "A valid signature with another identity must be rejected")
let unsigned = try copyCandidate("Unsigned")
try files.removeItem(at: unsigned.appendingPathComponent("Contents/_CodeSignature"))
check(rejected(unsigned), "A bundle missing its resource seal must be rejected")
print("Passed: intact update, altered nested controller/resource, wrong identity, and missing seal. Temporary fixtures only; no app launched.")

let suite = "razerctl.update-tests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
enum Injected: Error { case failed }

func transaction(_ name: String) throws -> (URL, URL) {
    let root = directory.appendingPathComponent(name)
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    let installed = root.appendingPathComponent("RazerCtl.app")
    let staged = root.appendingPathComponent("Staged.app")
    try files.copyItem(at: current, to: installed)
    try files.copyItem(at: valid, to: staged)
    try Data("original".utf8).write(to: installed.appendingPathComponent("original-marker"))
    return (installed, staged)
}

func expectFailure(_ body: () throws -> Void) {
    do { try body(); fatalError("Expected installation failure") } catch {}
}

let (permissionCurrent, permissionStaged) = try transaction("Permissions")
try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: permissionStaged.appendingPathComponent(executable).path)
expectFailure {
    try AppUpdate.install(staged: permissionStaged, current: permissionCurrent, version: "2", defaults: defaults) { _ in
        fatalError("A nonexecutable app must not reach launch")
    }
}
check(files.fileExists(atPath: permissionCurrent.appendingPathComponent("original-marker").path), "Preflight must preserve current app")

for failingMove in [1, 2] {
    let (installed, staged) = try transaction("Move\(failingMove)")
    var moves = 0
    expectFailure {
        try AppUpdate.install(staged: staged, current: installed, version: "2", defaults: defaults, move: { from, to in
            moves += 1
            if moves == failingMove { throw Injected.failed }
            try files.moveItem(at: from, to: to)
        }) { _ in fatalError("A failed move must not reach launch") }
    }
    check(files.fileExists(atPath: installed.appendingPathComponent("original-marker").path), "Move failure must preserve/restore original")
}

let (launchCurrent, launchStaged) = try transaction("Launch")
expectFailure {
    try AppUpdate.install(staged: launchStaged, current: launchCurrent, version: "2", defaults: defaults) { _ in throw Injected.failed }
}
check(files.fileExists(atPath: launchCurrent.appendingPathComponent("original-marker").path), "Launch failure must restore original")
check(defaults.data(forKey: "pendingSelfUpdate.v1") == nil, "Failure must clear its update marker")

let (rollbackCurrent, rollbackStaged) = try transaction("Rollback")
var rollbackMoves = 0
var recoveryMessage = ""
do {
    try AppUpdate.install(staged: rollbackStaged, current: rollbackCurrent, version: "2", defaults: defaults, move: { from, to in
        rollbackMoves += 1
        if rollbackMoves == 3 { throw Injected.failed }
        try files.moveItem(at: from, to: to)
    }) { _ in throw Injected.failed }
    fatalError("Expected rollback failure")
} catch { recoveryMessage = error.localizedDescription }
let recovery = try files.contentsOfDirectory(at: rollbackCurrent.deletingLastPathComponent(), includingPropertiesForKeys: nil)
    .first { $0.lastPathComponent.hasPrefix("RazerCtl.previous-") }!
check(files.fileExists(atPath: recovery.appendingPathComponent("original-marker").path), "Rollback failure must retain working backup")
check(recoveryMessage.contains(recovery.standardizedFileURL.path), "Rollback error must identify the recovery path: \(recoveryMessage)")

let (successCurrent, successStaged) = try transaction("Success")
try AppUpdate.install(staged: successStaged, current: successCurrent, version: "2", defaults: defaults) { _ in }
let backup = try files.contentsOfDirectory(at: successCurrent.deletingLastPathComponent(), includingPropertiesForKeys: nil)
    .first { $0.lastPathComponent.hasPrefix("RazerCtl.previous-") }!
check(files.fileExists(atPath: backup.path), "Successful spawn must retain backup until startup")
check(AppUpdate.finishInstallation(current: backup, version: "2", defaults: defaults) == nil, "Launching the backup must not delete itself")
check(AppUpdate.finishInstallation(current: successCurrent, version: "1", defaults: defaults) == nil, "Wrong version must not retire backup")
check(AppUpdate.finishInstallation(current: current, version: "2", defaults: defaults) == nil, "Another app copy must not retire backup")
check(files.fileExists(atPath: backup.path), "Unrelated startup must preserve backup")
check(AppUpdate.finishInstallation(current: successCurrent, version: "2", defaults: defaults) == "2", "Successor should confirm update")
check(!files.fileExists(atPath: backup.path), "Confirmed successor should retire only its backup")
check(files.fileExists(atPath: recovery.path), "Other transactions' recovery backups must remain untouched")
check(defaults.data(forKey: "pendingSelfUpdate.v1") == nil, "Confirmed transaction marker should clear")
print("Passed: executable preflight, move/launch rollback, recovery-path preservation, and successor-only cleanup. No app launched.")
