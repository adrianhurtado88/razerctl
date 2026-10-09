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
