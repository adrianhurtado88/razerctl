// RazerCtl — native macOS menu-bar control panel for Razer peripherals.
//
// Popover UI (SwiftUI) + Rust core (`razerctl-core`, adjacent binary).
// All device commands run on a serial background queue: the UI never
// blocks and commands never overlap.
//
// Lighting-first panel: one shared charcoal surface, wide brightness
// controls, and mouse performance settings behind a disclosure.

import SwiftUI
import AppKit
import Carbon

// MARK: - Store

struct DeviceCapabilities: Decodable {
    var effects: [String] = []
    var brightness = false
    var dpi_min: Int? = nil
    var dpi_max = 0
    var dpi_stages = false
    var poll_rates: [Int] = []
    var scroll = false
    var zones = 0

    var hasPerformance: Bool { dpi_max > 0 || !poll_rates.isEmpty || scroll }
    var lightingEffects: [(String, String)] {
        effects.map { ($0, $0 == "none" ? "Off" : $0.capitalized) }
    }
}

struct DetectedDevice: Decodable, Identifiable {
    let id: String
    let name: String
    let kind: String
    let usb_id: String
    let supported: Bool
    let capabilities: DeviceCapabilities
    let settings: [String: String]
    let error: String?
    var transport: String? = nil

    var connectionLabel: String { transport == "bluetooth" ? "Bluetooth" : (transport == "unknown" ? "Connection unknown" : "USB") }
}

private struct DetectionResult: Decodable {
    let devices: [DetectedDevice]
}

final class Store: ObservableObject, Identifiable {
    @Published var status: [String: String] = [:]
    private lazy var ownShortcuts = KeyboardShortcutsStore()
    private lazy var ownMouseButtons = MouseButtonsStore()
    var shortcuts: KeyboardShortcutsStore { discoveryStore?.shortcuts ?? ownShortcuts }
    var mouseButtons: MouseButtonsStore { discoveryStore?.mouseButtons ?? ownMouseButtons }
    // Secure input belongs to the app, not to any detected keyboard.
    // Observe the root directly so every section displays the same session.
    var keyboardPrivacyStore: Store { discoveryStore?.keyboardPrivacyStore ?? self }
    private var shortcutsWindow: KeyboardShortcutsWindow?
    private var mouseButtonsWindow: MouseButtonsWindow?

    @Published var deviceStores: [Store] = []
    @Published var detectedDevice: DetectedDevice?
    @Published var isDetecting = false
    @Published var hasDetected = false
    @Published var detectionError: String?
    @Published var bluetoothError: String?
    @Published var commandError: String?
    private let targetID: String?
    var id: String { targetID ?? "discovery" }
    var capabilities: DeviceCapabilities { detectedDevice?.capabilities ?? DeviceCapabilities() }
    var dpiMinimum: Int { capabilities.dpi_min ?? 100 }
    private weak var discoveryStore: Store?
    private var detectionTimer: Timer?
    private var inventorySignature: String?
    private var inventoryChecking = false
    private var scanPending = false
    private let bluetooth: BluetoothBackend?

    init(targetID: String? = nil, commandQueue: DispatchQueue? = nil, bluetooth: BluetoothBackend? = nil,
         secureInputStatus: @escaping () -> Bool = { IsSecureEventInputEnabled() },
         enableSecureInput: @escaping () -> OSStatus = { EnableSecureEventInput() },
         disableSecureInput: @escaping () -> OSStatus = { DisableSecureEventInput() },
         privacyUptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         beginPrivacyActivity: @escaping (ProcessInfo.ActivityOptions) -> NSObjectProtocol = {
             ProcessInfo.processInfo.beginActivity(options: $0, reason: "Turn off temporary keyboard privacy on time")
         },
         endPrivacyActivity: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.targetID = targetID
        self.bluetooth = bluetooth
        self.commandQueue = commandQueue ?? DispatchQueue(label: "local.razerctl.widget.commands", qos: .userInitiated)
        self.secureInputStatus = secureInputStatus
        self.enableSecureInput = enableSecureInput
        self.disableSecureInput = disableSecureInput
        self.privacyUptime = privacyUptime
        self.beginPrivacyActivity = beginPrivacyActivity
        self.endPrivacyActivity = endPrivacyActivity
        if targetID == nil {
            Self.coordinateRecording(keyboard: shortcuts, mouse: mouseButtons)
        }
    }

    static func coordinateRecording(keyboard: KeyboardShortcutsStore, mouse: MouseButtonsStore) {
        mouse.onKeyRecordingChanged = { [weak keyboard] recording in keyboard?.setRecording(recording) }
        keyboard.onRecordingChanged = { [weak mouse] recording in mouse?.setKeyboardRecording(recording) }
        mouse.setKeyboardRecording(keyboard.isRecording)
    }

    /// nil means the panel is not currently checking macOS's secure-input
    /// status. This query returns a system-wide flag, not keyboard events.
    @Published private(set) var secureKeyboardEntryEnabled: Bool?
    @Published private(set) var temporaryKeyboardPrivacyEnabled = false
    @Published private(set) var temporaryKeyboardPrivacySecondsRemaining = 0
    @Published private(set) var keyboardPrivacyError: String?
    static let keyboardPrivacyDuration: TimeInterval = 10 * 60
    private let secureInputStatus: () -> Bool
    private let enableSecureInput: () -> OSStatus
    private let disableSecureInput: () -> OSStatus
    private let privacyUptime: () -> TimeInterval
    private let beginPrivacyActivity: (ProcessInfo.ActivityOptions) -> NSObjectProtocol
    private let endPrivacyActivity: (NSObjectProtocol) -> Void
    private var keyboardPrivacyActivity: NSObjectProtocol?
    private var keyboardPrivacyTimer: Timer?
    private var keyboardPrivacyPanelVisible = false
    private var keyboardPrivacyDeadline: TimeInterval?

    deinit {
        detectionTimer?.invalidate()
        keyboardPrivacyTimer?.invalidate()
        if temporaryKeyboardPrivacyEnabled {
            // Release exactly the request owned by this Store. Carbon's
            // secure-input APIs must be called on the main thread.
            let release = disableSecureInput
            let activity = keyboardPrivacyActivity
            let endActivity = endPrivacyActivity
            let cleanup = {
                _ = release()
                if let activity { endActivity(activity) }
            }
            if Thread.isMainThread { cleanup() }
            else { DispatchQueue.main.async(execute: cleanup) }
        }
    }

    func startKeyboardPrivacyMonitoring() {
        precondition(Thread.isMainThread)
        guard targetID == nil else {
            discoveryStore?.startKeyboardPrivacyMonitoring()
            return
        }
        keyboardPrivacyPanelVisible = true
        refreshKeyboardPrivacy()
    }

    func stopKeyboardPrivacyMonitoring() {
        precondition(Thread.isMainThread)
        guard targetID == nil else {
            discoveryStore?.stopKeyboardPrivacyMonitoring()
            return
        }
        keyboardPrivacyPanelVisible = false
        refreshKeyboardPrivacy()
    }

    func setTemporaryKeyboardPrivacyEnabled(_ enabled: Bool) {
        precondition(Thread.isMainThread)
        guard targetID == nil else {
            discoveryStore?.setTemporaryKeyboardPrivacyEnabled(enabled)
            return
        }
        keyboardPrivacyError = nil
        if enabled {
            // Enable/disable are reference counted by macOS. Acquiring
            // once and releasing only our own request preserves other apps.
            guard !temporaryKeyboardPrivacyEnabled else { return }
            guard enableSecureInput() == noErr else {
                keyboardPrivacyError = "Couldn't turn on temporary privacy. Try again."
                refreshKeyboardPrivacy()
                return
            }
            // The shutoff must keep running after the panel closes. Prevent
            // App Nap while we own secure input, without preventing Mac sleep.
            keyboardPrivacyActivity = beginPrivacyActivity(.userInitiatedAllowingIdleSystemSleep)
            temporaryKeyboardPrivacyEnabled = true
            keyboardPrivacyDeadline = privacyUptime() + Self.keyboardPrivacyDuration
        } else {
            releaseTemporaryKeyboardPrivacy()
        }
        refreshKeyboardPrivacy()
    }

    private func releaseTemporaryKeyboardPrivacy() {
        guard temporaryKeyboardPrivacyEnabled else { return }
        guard disableSecureInput() == noErr else {
            keyboardPrivacyError = "Couldn't turn off temporary privacy. Try again or quit RazerCtl."
            return
        }
        if let activity = keyboardPrivacyActivity {
            endPrivacyActivity(activity)
            keyboardPrivacyActivity = nil
        }
        temporaryKeyboardPrivacyEnabled = false
        keyboardPrivacyDeadline = nil
        temporaryKeyboardPrivacySecondsRemaining = 0
        keyboardPrivacyError = nil
    }

    private func refreshKeyboardPrivacy() {
        // Carbon documents this API as not thread safe: all queries stay
        // on the main thread, including the common-mode timer callback.
        precondition(Thread.isMainThread)
        if let deadline = keyboardPrivacyDeadline {
            let remaining = max(0, Int(ceil(deadline - privacyUptime())))
            if temporaryKeyboardPrivacySecondsRemaining != remaining {
                temporaryKeyboardPrivacySecondsRemaining = remaining
            }
            if remaining == 0 { releaseTemporaryKeyboardPrivacy() }
        }
        guard keyboardPrivacyPanelVisible || temporaryKeyboardPrivacyEnabled else {
            keyboardPrivacyTimer?.invalidate()
            keyboardPrivacyTimer = nil
            secureKeyboardEntryEnabled = nil
            return
        }
        let enabled = secureInputStatus()
        if secureKeyboardEntryEnabled != enabled {
            secureKeyboardEntryEnabled = enabled
        }
        if keyboardPrivacyTimer == nil {
            // Keep the deadline running when the panel is closed. Use a
            // monotonic clock so wall-clock changes cannot extend a session.
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                self?.refreshKeyboardPrivacy()
            }
            timer.tolerance = 0.2
            keyboardPrivacyTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func showKeyboardShortcuts() {
        if let discoveryStore { discoveryStore.showKeyboardShortcuts(); return }
        if shortcutsWindow == nil { shortcutsWindow = KeyboardShortcutsWindow(store: shortcuts) }
        shortcuts.refreshAccess()
        shortcutsWindow?.show()
    }

    func showMouseButtons() {
        if let discoveryStore { discoveryStore.showMouseButtons(); return }
        if mouseButtonsWindow == nil { mouseButtonsWindow = MouseButtonsWindow(store: mouseButtons) }
        mouseButtons.refreshAccess()
        mouseButtonsWindow?.show()
    }

    // Local interaction state (the firmware can't read effects back).
    @Published var kbdEffect = ""
    @Published var mouseEffect = ""
    @Published var kbdColor = Color(red: 1.00, green: 0.22, blue: 0.39)
    @Published var mouseColor = Color(red: 0.20, green: 0.78, blue: 1.00)
    @Published var kbdBrightness = 100.0
    @Published var mouseBrightness = 75.0

    private var colorDebounces: [String: DispatchWorkItem] = [:]

    /// Serial queue: one command at a time, never the main thread.
    let commandQueue: DispatchQueue

    /// Every core call is logged here — ground truth from the GUI context.
    static let logURL = URL(fileURLWithPath: "/tmp/razerctl-widget.log")

    // MARK: Self-update state

    /// Embedded app version (bumped by publish.sh). Compared against the
    /// latest GitHub release tag.
    static let appVersion = "1.5"

    @Published var latestVersion: String?
    @Published var updating = false
    @Published var updateError: String?
    /// Set after a self-update: the new instance shows a green
    /// "Updated to vX.Y" confirmation banner.
    @Published var updateCompleted: String?
    /// Transient result of a manual "Check for Updates…" — e.g.
    /// "You're up to date (v1.2)". Auto-clears after a few seconds.
    @Published var updateCheckNote: String?
    private var assetURL: URL?
    private let repo = "adrianhurtado88/razerctl"

    /// Check GitHub for a newer release. Throttled to one call per 10 min
    /// ( UserDefaults), re-checked at launch and popover open.
    func checkForUpdates(force: Bool = false) {
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard force || Date().timeIntervalSince1970 - last > 600 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")

        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("RazerCtl", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                // Manual checks deserve visible feedback either way.
                guard let data,
                      response != nil,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = obj["tag_name"] as? String else {
                    if force { self.showCheckNote("Update check failed — no network?") }
                    return
                }
                let latest = tag.replacingOccurrences(of: "v", with: "")
                guard Self.isNewer(latest, than: Self.appVersion) else {
                    self.latestVersion = nil
                    if force { self.showCheckNote("You're up to date (v\(Self.appVersion))") }
                    return
                }
                self.latestVersion = latest
                self.updateCheckNote = nil
                if let assets = obj["assets"] as? [[String: Any]],
                   let urlStr = assets.compactMap({ $0["browser_download_url"] as? String })
                       .first(where: { $0.hasSuffix(".zip") }) {
                    self.assetURL = URL(string: urlStr)
                }
            }
        }.resume()
    }

    private func showCheckNote(_ text: String) {
        updateCheckNote = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.updateCheckNote = nil
        }
    }

    /// Numeric component compare: "1.1" > "1.0.1" etc.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// One-click self-update: download the release zip, verify it is
    /// signed by the SAME Developer ID team as this running app (tamper
    /// check — and the shared team is what keeps the Input Monitoring
    /// grant alive across updates), swap bundles, relaunch.
    func performUpdate() {
        guard !updating else { return }
        guard let assetURL else {
            updateError = "No downloadable asset found"
            return
        }
        updating = true
        updateError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                // 1. Download the zip.
                let zipURL = try Self.downloadSync(assetURL)
                // 2. Unzip to a fresh temp dir.
                let tmp = NSTemporaryDirectory() + "razerctl-update-\(UUID().uuidString)"
                try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(atPath: tmp) }
                try Self.runCmd("/usr/bin/ditto", ["-x", "-k", zipURL.path, tmp])
                let newApp = tmp + "/RazerCtl.app"
                let staged = URL(fileURLWithPath: newApp)
                guard let version = Bundle(url: staged)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
                    throw UpdateError.badArchive
                }
                try AppUpdate.requireExecutables(at: staged)
                // 3. Verify integrity and the current app's signing identity.
                try AppUpdate.verifySignature(at: URL(fileURLWithPath: newApp),
                                              matching: Bundle.main.bundleURL)
                // 4. Prepare the staged app before touching the installed one.
                try Self.runCmd("/usr/bin/xattr",
                                 ["-dr", "com.apple.quarantine", newApp])
                // 5. Restore the original on failure; retain its backup until
                //    the new instance confirms startup at the installed path.
                try AppUpdate.install(staged: staged, current: Bundle.main.bundleURL, version: version) { bundle in
                    let process = Process()
                    process.executableURL = bundle.appendingPathComponent("Contents/MacOS/RazerCtl")
                    try process.run()
                }
                DispatchQueue.main.async { NSApp.terminate(nil) }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.updating = false
                    self?.updateError = "Update failed: \(error.localizedDescription.isEmpty ? "\(error)" : error.localizedDescription)"
                }
            }
        }
    }

    enum UpdateError: LocalizedError {
        case badArchive
        var errorDescription: String? {
            switch self {
            case .badArchive: return "the release zip has no RazerCtl.app"
            }
        }
    }

    /// Blocking download with a completion handler API (Swift 5 friendly).
    private static func downloadSync(_ url: URL) throws -> URL {
        var result: URL?
        var failure: Error?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.downloadTask(with: url) { u, _, e in
            result = u; failure = e; sem.signal()
        }.resume()
        sem.wait()
        if let e = failure { throw e }
        guard let u = result else { throw URLError(.badServerResponse) }
        return u
    }

    /// Run a command; throw on non-zero exit.
    private static func runCmd(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError.badArchive
        }
    }

    var coreURL: URL? {
        let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let core = dir.appendingPathComponent("razerctl-core")
        return FileManager.default.isExecutableFile(atPath: core.path) ? core : nil
    }

    @discardableResult
    func run(_ args: [String]) -> String {
        runResult(args).output
    }

    private func runResult(_ args: [String]) -> (output: String, exitCode: Int32) {
        if let targetID, targetID.hasPrefix("ble:") {
            guard let bluetooth else { return ("The Bluetooth controller is unavailable.", -1) }
            return bluetooth.command(args, id: targetID)
        }
        guard let core = coreURL else {
            log("CORE MISSING at expected path")
            return ("The device controller is missing. Reinstall RazerCtl.", -1)
        }
        let p = Process()
        p.executableURL = core
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = outPipe
        do {
            try p.run()
        } catch {
            log("spawn failed (\(args.joined(separator: " "))): \(error)")
            return ("Couldn't start the device controller: \(error.localizedDescription)", -1)
        }
        // Drain while the process runs: a large device inventory can fill
        // the pipe buffer and otherwise deadlock waitUntilExit().
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        if args.first != "inventory" {
            log("[exit \(p.terminationStatus)] \(args.joined(separator: " "))"
                + (out.isEmpty ? "" : "  out: " + out.replacingOccurrences(of: "\n", with: " | ")))
        }
        return (out, p.terminationStatus)
    }

    private func log(_ msg: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        let line = "\(stamp)  \(msg)\n"
        if !FileManager.default.fileExists(atPath: Self.logURL.path) {
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: Self.logURL) {
            _ = try? h.seekToEnd()
            _ = try? h.write(contentsOf: line.data(using: .utf8)!)
            try? h.close()
        }
    }

    /// Fire a device command, then refresh status.
    func command(_ args: [String]) {
        // A child Store owns one physical control path and shares the
        // root's serial queue, so identical models cannot cross-control.
        guard let targetID else { return }
        commandError = nil
        commandQueue.async { [weak self] in
            guard let self else { return }
            let result = self.runResult(args + ["--id", targetID])
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.commandError = result.exitCode == 0 ? nil : result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.discoveryStore?.refresh()
            }
        }
    }

    /// Initial scan and the manual Detect button share the same path.
    /// Coalesce requests; never overlap HID access or lose a post-command scan.
    func refresh() {
        if let discoveryStore { discoveryStore.refresh(); return }
        guard !isDetecting else { scanPending = true; return }
        isDetecting = true
        detectionError = nil
        commandQueue.async { [weak self] in
            guard let self else { return }
            let inventory = self.runResult(["inventory"])
            let result = self.runResult(["detect"])
            let bluetoothInventory = self.bluetooth?.inventory() ?? BluetoothScan()
            let bluetoothResult = self.bluetooth?.detect() ?? BluetoothScan()
            let decoded = result.exitCode == 0
                ? try? JSONDecoder().decode(DetectionResult.self, from: Data(result.output.utf8)) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isDetecting = false
                self.hasDetected = true
                self.bluetoothError = bluetoothResult.error
                if let decoded {
                    self.inventorySignature = inventory.exitCode == 0 ? inventory.output + bluetoothInventory.signature : nil
                    let previous = Dictionary(uniqueKeysWithValues: self.deviceStores.map { ($0.id, $0) })
                    let devices = Self.mergeDevices(decoded.devices, bluetooth: bluetoothResult.devices)
                    let newIDs = Set(devices.map(\.id))
                    for store in self.deviceStores where !newIDs.contains(store.id) {
                        store.colorDebounces.values.forEach { $0.cancel() }
                    }
                    self.deviceStores = devices.map { device in
                        let store = previous[device.id] ?? Store(targetID: device.id, commandQueue: self.commandQueue, bluetooth: self.bluetooth)
                        store.discoveryStore = self
                        store.detectedDevice = device
                        var status = device.settings
                        if let error = device.error {
                            status["\(device.kind)_error"] = error.hasPrefix("\(device.name):")
                                ? error : "\(device.name): \(error)"
                        }
                        store.status = status
                        if let value = Double(status["kbd_brightness"] ?? "") {
                            store.kbdBrightness = min(100, max(0, value / 2.55))
                        }
                        if let value = Double(status["mouse_brightness"] ?? "") {
                            store.mouseBrightness = min(100, max(0, value / 2.55))
                        }
                        return store
                    }
                } else {
                    self.detectionError = result.exitCode == 0 ? "Couldn't read the device list. Click Detect to try again."
                        : result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                NotificationCenter.default.post(
                    name: Notification.Name("razerctlStatusUpdated"), object: nil)
                if self.scanPending { self.scanPending = false; self.refresh() }
            }
        }
    }

    func startDetection() {
        guard detectionTimer == nil else { return }
        refresh()
        // Enumeration opens no devices and writes no reports. Re-query
        // capabilities only when something is attached or removed.
        detectionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.checkForDeviceChanges()
        }
    }

    func stopDetection() { detectionTimer?.invalidate(); detectionTimer = nil }

    static func mergeDevices(_ hid: [DetectedDevice], bluetooth: [DetectedDevice]) -> [DetectedDevice] {
        // Native Bluetooth UUIDs provide independent identities, even for
        // identical models. Remove only their duplicate Bluetooth HID rows;
        // retain wired USB connections and unknown Bluetooth products.
        let nativeIDs = Set(bluetooth.filter { !$0.usb_id.isEmpty }.map { String($0.usb_id.suffix(4)) })
        return hid.filter { !($0.transport == "bluetooth" && nativeIDs.contains(String($0.usb_id.suffix(4)))) } + bluetooth
    }

    func checkForDeviceChanges() {
        guard !isDetecting, !inventoryChecking else { return }
        inventoryChecking = true
        commandQueue.async { [weak self] in
            guard let self else { return }
            let result = self.runResult(["inventory"])
            let bluetoothInventory = self.bluetooth?.inventory() ?? BluetoothScan()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inventoryChecking = false
                if result.exitCode != 0 || result.output + bluetoothInventory.signature != self.inventorySignature {
                    self.refresh()
                }
            }
        }
    }

    /// Device names and firmware share a line in the existing CLI format.
    /// Split that metadata without splitting the spaces in device names.
    static func parseStatus(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = String(pair[0])
            let value = String(pair[1])
            if (key == "keyboard" || key == "mouse"),
               let metadata = value.range(of: " \(key)_fw=") {
                result[key] = String(value[..<metadata.lowerBound])
                result["\(key)_fw"] = String(value[metadata.upperBound...])
            } else {
                result[key] = value
            }
        }
        return result
    }

    // MARK: Device actions

    func applyEffect(_ name: String, device: String) {
        // A newer effect replaces any pending static-color write.
        colorDebounces.removeValue(forKey: device)?.cancel()
        if name == "static" {
            applyStatic(color: device == "keyboard" ? kbdColor : mouseColor, device: device)
        } else if name == "rainbow" {
            command(["rainbow", String(capabilities.zones)])
        } else {
            command(["effect", name, "--dev", device])
        }
    }

    func applyStatic(color: Color, device: String) {
        if device == "keyboard" { kbdColor = color }
        else { mouseColor = color }
        // The native color picker fires continuously while dragging;
        // debounce so the device gets the final color, not one per tick.
        colorDebounces[device]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
            let r = Int(round(ns.redComponent * 255))
            let g = Int(round(ns.greenComponent * 255))
            let b = Int(round(ns.blueComponent * 255))
            self.command(["effect", "static",
                          String(format: "%02X%02X%02X", r, g, b),
                          "--dev", device])
            if device == "keyboard" { self.kbdEffect = "static" }
            else { self.mouseEffect = "static" }
        }
        colorDebounces[device] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func setBrightness(_ pct: Double, device: String) {
        command(["brightness", String(Int(pct)), "--dev", device])
    }

    func validatedDpi(_ text: String) -> Int? {
        guard capabilities.dpi_max > 0,
              let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value >= dpiMinimum, value <= capabilities.dpi_max else { return nil }
        return value
    }

    func setDpi(_ value: String) {
        guard let dpi = validatedDpi(value) else {
            commandError = capabilities.dpi_max > 0
                ? "Choose a DPI between \(dpiMinimum) and \(capabilities.dpi_max)."
                : "DPI controls are unavailable for this device."
            return
        }
        command(["dpi", String(dpi)])
    }

    func setPoll(_ hz: String) {
        command(["poll", hz])
    }

    func setScroll(free: Bool) {
        command(["scroll", free ? "free" : "tactile"])
    }

    // MARK: App actions

    /// Deep link to Privacy & Security › Input Monitoring, where the
    /// keyboard's control collection is gated.
    static func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    static func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}

// MARK: - Lighting-first theme

private enum Theme {
    static let background = Color(red: 0.141, green: 0.149, blue: 0.165)
    static let secondary = Color(red: 0.72, green: 0.73, blue: 0.76)
    static let separator = Color.white.opacity(0.15)
    static let keyboardAccent = Color(red: 1.00, green: 0.22, blue: 0.39)
    static let mouseAccent = Color(red: 0.20, green: 0.78, blue: 1.00)
}

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var store: Store

    private var deviceList: some View {
        VStack(spacing: 0) {
            ForEach(store.deviceStores) { deviceStore in
                if deviceStore.id != store.deviceStores.first?.id { PanelDivider() }
                DetectedDeviceGroup(deviceStore: deviceStore)
                    .environmentObject(deviceStore)
                    .disabled(store.isDetecting || store.detectionError != nil)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
                .padding(.bottom, 12)
            PanelDivider()
            if let error = store.detectionError {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 10)
            }
            if let error = store.bluetoothError {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.deviceStores.isEmpty {
                EmptyDevices()
            } else if store.deviceStores.count > 2 {
                ScrollView { deviceList }.frame(height: 550)
            } else {
                deviceList
            }
            PanelDivider()
            UpdateFooter()
                .padding(.top, 14)
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: PanelSizeKey.self, value: geometry.size)
        })
        .onPreferenceChange(PanelSizeKey.self) { size in
            // SwiftUI state changes (including the disclosure and errors)
            // must resize the actual popover as well as its content.
            NotificationCenter.default.post(
                name: Notification.Name("razerctlPanelSizeChanged"), object: nil,
                userInfo: ["size": size])
        }
    }
}

private struct PanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct PanelDivider: View {
    var body: some View {
        Rectangle().fill(Theme.separator).frame(height: 1)
            .accessibilityHidden(true)
    }
}

// MARK: - Keyboard privacy

private struct KeyboardPrivacySection: View {
    @ObservedObject var privacyStore: Store
    @State private var showsDetails = false

    private var statusText: String {
        if privacyStore.temporaryKeyboardPrivacyEnabled {
            let seconds = privacyStore.temporaryKeyboardPrivacySecondsRemaining
            if seconds == 0 { return "Turning off…" }
            return String(format: "On · %d:%02d remaining", seconds / 60, seconds % 60)
        }
        switch privacyStore.secureKeyboardEntryEnabled {
        case true?: return "Enabled by another app"
        case false?: return "Off · 10-minute limit"
        case nil: return "Checking status…"
        }
    }

    private var temporaryPrivacy: Binding<Bool> {
        Binding(get: { privacyStore.temporaryKeyboardPrivacyEnabled },
                set: { privacyStore.setTemporaryKeyboardPrivacyEnabled($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelDivider()
            HStack(spacing: 8) {
                Image(systemName: privacyStore.secureKeyboardEntryEnabled == true ? "lock.fill" : "lock.open")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(privacyStore.secureKeyboardEntryEnabled == true ? Color.white : Theme.secondary)
                    .frame(width: 20, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Secure Keyboard Entry")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(statusText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Secure Keyboard Entry")
                .accessibilityValue(statusText)
                Button { showsDetails.toggle() } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .accessibilityLabel("About keyboard privacy")
                .help("About keyboard privacy")
                .popover(isPresented: $showsDetails, arrowEdge: .trailing) {
                    KeyboardPrivacyDetails()
                }
                Toggle("Temporary keyboard privacy", isOn: temporaryPrivacy)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityHint("Enables Secure Keyboard Entry for up to ten minutes. Open About keyboard privacy for limitations.")
                    .help("Enable temporary keyboard privacy for ten minutes")
            }
            .frame(minHeight: 40)

            if let error = privacyStore.keyboardPrivacyError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KeyboardPrivacyDetails: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About keyboard privacy")
                .font(.system(size: 14, weight: .semibold))
            Text("RazerCtl cannot guarantee completely untraceable typing. The app receiving your typing can still read or save it, including in command history.")
            Text("Temporary mode enables macOS Secure Keyboard Entry for up to 10 minutes. It stays on when this panel closes and turns off on sleep, user switching or quitting RazerCtl.")
            Text("It may interrupt keyboard shortcuts, remapping and accessibility tools. Turn it off if they stop working.")
            Text("Turning off this switch releases only RazerCtl’s request. Protection enabled by another app can remain active.")
            Text("RazerCtl does not keep a typing log. Apple recommends enabling secure input in the app receiving sensitive typing; in Terminal, choose Terminal → Secure Keyboard Entry.")
            Link("Read Apple’s guide", destination: URL(string: "https://support.apple.com/guide/terminal/use-secure-keyboard-entry-trml109/mac")!)
        }
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 310, alignment: .leading)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Header and update footer

private struct TitleBar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack {
            Text("RazerCtl")
                .font(.system(size: 18, weight: .semibold))
            Spacer()
            Button { store.refresh() } label: {
                Label(store.isDetecting ? "Detecting…" : "Detect", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(store.isDetecting)
            .accessibilityLabel("Detect Razer devices")
            .help("Scan connected Razer keyboards and mice for available settings")
            Menu {
                if store.temporaryKeyboardPrivacyEnabled {
                    Button("Turn Off Temporary Privacy") { store.setTemporaryKeyboardPrivacyEnabled(false) }
                    Divider()
                }
                Button("Check for Updates…") { store.checkForUpdates(force: true) }
                Button("Keyboard Shortcuts…") { store.showKeyboardShortcuts() }
                Button("Mouse Buttons…") { store.showMouseButtons() }
                Divider()
                Button("About RazerCtl") { Store.showAbout() }
                Divider()
                Button("Quit RazerCtl") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .background(Color.white.opacity(0.07), in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.13)))
            .accessibilityLabel("More")
            .help("More")
        }
        .frame(height: 26)
    }
}

private struct UpdateFooter: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let version = store.updateCompleted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Updated to v\(version)")
                } else if let version = store.latestVersion {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14)).foregroundStyle(.yellow)
                    Text("v\(version) available").fontWeight(.semibold)
                    Spacer()
                    if store.updating {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Installing update")
                    } else {
                        Button("Update") { store.performUpdate() }
                            .controlSize(.regular)
                    }
                } else if let note = store.updateCheckNote {
                    Image(systemName: "info.circle").foregroundStyle(Theme.secondary)
                    Text(note).foregroundStyle(Theme.secondary)
                } else {
                    Text("v\(Store.appVersion)")
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Check for Updates…") { store.checkForUpdates(force: true) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .frame(minHeight: 24)
            if let error = store.updateError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Device lighting

private enum ProductArtwork {
    // Match complete model names so a different generation keeps its
    // generic symbol instead of showing the wrong product photo.
    private static let filenames = [
        "Razer Ornata V3 X": "ornata-v3-x",
        "Razer Basilisk V3": "basilisk-v3",
    ]

    private static let images: [String: NSImage] = filenames.reduce(into: [:]) { images, entry in
        guard let url = Bundle.main.url(forResource: entry.value, withExtension: "png",
                                        subdirectory: "Devices"),
              let image = NSImage(contentsOf: url), image.isValid else { return }
        image.isTemplate = false
        images[entry.key] = image
    }

    static func image(for modelName: String) -> NSImage? {
        images[modelName]
    }
}

private struct DeviceHeader: View {
    let icon: String
    let name: String
    let kind: String
    let firmware: String?

    private var displayName: String {
        name.hasPrefix("Razer ") ? String(name.dropFirst(6)) : name
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = ProductArtwork.image(for: name) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 25, weight: .regular))
                }
            }
            .frame(width: 64, height: 52)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(kind)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .help(firmware.map { "\(name) · Firmware \($0)" } ?? name)
    }
}

private struct LightingControls: View {
    @EnvironmentObject var store: Store
    let device: String
    let effects: [(String, String)]

    private var isStatic: Bool {
        (device == "keyboard" ? store.kbdEffect : store.mouseEffect) == "static"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("Lighting")
                Spacer(minLength: 12)
                EffectMenu(selection: selection, effects: effects,
                           label: "\(device.capitalized) lighting")
                    .frame(width: isStatic ? 112 : 150, height: 28)
                if isStatic {
                    ColorWell(device: device)
                        .frame(width: 26, height: 26)
                }
            }
            .frame(height: 28)
            if store.capabilities.brightness { BrightnessControl(device: device) }
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: { device == "keyboard" ? store.kbdEffect : store.mouseEffect },
            set: { effect in
                if device == "keyboard" { store.kbdEffect = effect }
                else { store.mouseEffect = effect }
                store.applyEffect(effect, device: device)
            }
        )
    }
}

/// NSPopUpButton preserves native menu selection and keyboard support;
/// its cell places the current effect and disclosure glyph at each end.
private struct EffectMenu: NSViewRepresentable {
    @Binding var selection: String
    let effects: [(String, String)]
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.cell = EffectMenuCell(textCell: "", pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.autoenablesItems = false
        button.setAccessibilityLabel(label)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let placeholder = selection.isEmpty ? ["Choose…"] : []
        if button.itemTitles != placeholder + effects.map(\.1) {
            button.removeAllItems()
            if selection.isEmpty {
                button.addItem(withTitle: "Choose…")
                button.lastItem?.isEnabled = false
            }
            for (value, title) in effects {
                button.addItem(withTitle: title)
                button.lastItem?.representedObject = value
            }
        }
        if let index = effects.firstIndex(where: { $0.0 == selection }) {
            button.selectItem(at: index + placeholder.count)
        } else if selection.isEmpty {
            button.selectItem(at: 0)
        }
        button.needsDisplay = true
    }

    final class Coordinator: NSObject {
        var parent: EffectMenu
        init(_ parent: EffectMenu) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) {
            if let effect = sender.selectedItem?.representedObject as? String {
                parent.selection = effect
            }
        }
    }
}

private final class EffectMenuCell: NSPopUpButtonCell {
    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        let surface = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: 6, yRadius: 6)
        NSColor.white.withAlphaComponent(isHighlighted ? 0.13 : 0.07).setFill()
        surface.fill()
        NSColor.white.withAlphaComponent(0.13).setStroke()
        surface.lineWidth = 1
        surface.stroke()
        let text = title as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: frame.minX + 10, y: frame.midY - size.height / 2),
                  withAttributes: attributes)
        let arrow = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))?
            .withSymbolConfiguration(.init(paletteColors: [.white]))
        arrow?.draw(in: NSRect(x: frame.maxX - 18, y: frame.midY - 6, width: 8, height: 12))
    }

    override func drawFocusRingMask(withFrame frame: NSRect, in controlView: NSView) {
        NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
    }
}

/// The system color well keeps the native color panel and keyboard/AX
/// behavior; its minimal swatch fits beside the effect selector.
private struct ColorWell: NSViewRepresentable {
    @EnvironmentObject var store: Store
    let device: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CompactColorWell {
        let well = CompactColorWell(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        if #available(macOS 13.0, *) { well.colorWellStyle = .minimal }
        well.isBordered = false
        well.wantsLayer = true
        well.layer?.cornerRadius = 13
        well.layer?.masksToBounds = true
        well.layer?.borderWidth = 1.5
        well.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        well.target = context.coordinator
        well.action = #selector(Coordinator.changed(_:))
        well.setAccessibilityLabel("\(device.capitalized) static color")
        return well
    }

    func updateNSView(_ well: CompactColorWell, context: Context) {
        context.coordinator.parent = self
        well.color = NSColor(device == "keyboard" ? store.kbdColor : store.mouseColor)
    }

    final class Coordinator: NSObject {
        var parent: ColorWell
        init(_ parent: ColorWell) { self.parent = parent }
        @objc func changed(_ sender: NSColorWell) {
            parent.store.applyStatic(color: Color(nsColor: sender.color), device: parent.device)
        }
    }
}

private final class CompactColorWell: NSColorWell {
    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 26) }
}

private struct BrightnessControl: View {
    @EnvironmentObject var store: Store
    let device: String

    private var value: Double {
        device == "keyboard" ? store.kbdBrightness : store.mouseBrightness
    }
    private var accent: Color {
        let effect = device == "keyboard" ? store.kbdEffect : store.mouseEffect
        if effect == "static" {
            return device == "keyboard" ? store.kbdColor : store.mouseColor
        }
        return device == "keyboard" ? Theme.keyboardAccent : Theme.mouseAccent
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("Brightness")
                Spacer()
                Text("\(Int(value))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            BrightnessSlider(value: sliderValue, accent: NSColor(accent),
                             label: "\(device.capitalized) brightness") { value in
                store.setBrightness(value, device: device)
            }
            .frame(height: 16)
        }
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { value },
            set: { value in
                if device == "keyboard" { store.kbdBrightness = value }
                else { store.mouseBrightness = value }
            }
        )
    }
}

/// NSSlider retains native keyboard, mouse and accessibility behavior.
/// The cell supplies the selected color; system SwiftUI sliders on macOS
/// ignore the tint and display a tick for every percentage step.
private struct BrightnessSlider: NSViewRepresentable {
    @Binding var value: Double
    let accent: NSColor
    let label: String
    let commit: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: 0, maxValue: 100,
                              target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        let cell = BrightnessSliderCell()
        slider.cell = cell
        slider.minValue = 0
        slider.maxValue = 100
        slider.doubleValue = value
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel(label)
        cell.trackingEnded = { [weak coordinator = context.coordinator] slider in
            coordinator?.parent.commit(slider.doubleValue.rounded())
        }
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.doubleValue = value
        (slider.cell as? BrightnessSliderCell)?.accent = accent
        slider.needsDisplay = true
    }

    final class Coordinator: NSObject {
        var parent: BrightnessSlider
        init(_ parent: BrightnessSlider) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) {
            let value = slider.doubleValue.rounded()
            slider.doubleValue = value
            parent.value = value
            // Keyboard and accessibility changes commit immediately;
            // pointer drags publish live UI and commit once on release.
            if (slider.cell as? BrightnessSliderCell)?.isEditing != true {
                parent.commit(value)
            }
        }
    }
}

private final class BrightnessSliderCell: NSSliderCell {
    var accent = NSColor.controlAccentColor
    var isEditing = false
    var trackingEnded: ((NSSlider) -> Void)?

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = NSRect(x: rect.minX, y: rect.midY - 2.5, width: rect.width, height: 5)
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2.5, yRadius: 2.5).fill()
        let fraction = (doubleValue - minValue) / max(1, maxValue - minValue)
        let filled = NSRect(x: bar.minX, y: bar.minY, width: bar.width * fraction, height: bar.height)
        accent.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2.5, yRadius: 2.5).fill()
    }

    override func drawKnob(_ rect: NSRect) {
        let knob = NSRect(x: rect.midX - 8, y: rect.midY - 8, width: 16, height: 16)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
    }

    override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
        let started = super.startTracking(at: startPoint, in: controlView)
        isEditing = started
        return started
    }

    override func stopTracking(last lastPoint: NSPoint, current stopPoint: NSPoint,
                               in controlView: NSView, mouseIsUp flag: Bool) {
        super.stopTracking(last: lastPoint, current: stopPoint, in: controlView, mouseIsUp: flag)
        isEditing = false
        if flag, let slider = controlView as? NSSlider { trackingEnded?(slider) }
    }
}

private struct KeyboardGroup: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DeviceHeader(icon: "keyboard", name: deviceName("keyboard", in: store.status),
                         kind: "Keyboard · \(store.detectedDevice?.connectionLabel ?? "USB")", firmware: store.status["keyboard_fw"])
            if store.status["keyboard"] != nil {
                LightingControls(device: "keyboard", effects: store.capabilities.lightingEffects)
                KeyboardShortcutsButton(shortcuts: store.shortcuts, openEditor: store.showKeyboardShortcuts)
            } else if let error = store.status["keyboard_error"] {
                DeviceProblem(error: error)
            }
            KeyboardPrivacySection(privacyStore: store.keyboardPrivacyStore)
        }
    }
}

private struct MouseGroup: View {
    @EnvironmentObject var store: Store
    @State private var performanceExpanded = false

    private var summary: String {
        var items: [String] = []
        if let dpi = store.status["dpi"] { items.append("\(dpi) DPI") }
        if let rate = store.status["poll"] { items.append("\(rate) Hz") }
        if let scroll = store.status["scroll"] {
            items.append(scroll == "free" ? "Free-spin" : "Tactile")
        }
        return items.isEmpty ? "Available settings" : items.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                DeviceHeader(icon: "computermouse", name: deviceName("mouse", in: store.status),
                             kind: "Mouse · \(store.detectedDevice?.connectionLabel ?? "USB")", firmware: store.status["mouse_fw"])
                if store.status["mouse"] != nil {
                    if !store.capabilities.effects.isEmpty {
                        LightingControls(device: "mouse", effects: store.capabilities.lightingEffects)
                    } else if store.capabilities.brightness {
                        BrightnessControl(device: "mouse")
                    }
                    if store.capabilities.effects.isEmpty && !store.capabilities.hasPerformance {
                        Text("Settings couldn't be read. Click Detect to retry.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    MouseButtonsButton(buttons: store.mouseButtons, openEditor: store.showMouseButtons)
                } else if let error = store.status["mouse_error"] {
                    DeviceProblem(error: error)
                }
                if store.status["mouse"] != nil, let error = store.status["mouse_error"] {
                    Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 13)
            if store.status["mouse"] != nil && store.capabilities.hasPerformance {
                PanelDivider()
                Button {
                    performanceExpanded.toggle()
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: performanceExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Mouse performance")
                                .font(.system(size: 13, weight: .semibold))
                            Text(summary)
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Theme.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mouse performance")
                .accessibilityValue(performanceExpanded ? "Expanded, \(summary)" : "Collapsed, \(summary)")
                .accessibilityHint("Show or hide DPI, polling rate and scroll settings")
                if performanceExpanded {
                    MousePerformance()
                        .padding(.top, 2)
                        .padding(.bottom, 16)
                }
            }
        }
    }
}

// MARK: - Mouse performance

private struct MousePerformance: View {
    @EnvironmentObject var store: Store
    @State private var customDpi = ""
    @State private var editingCustomDpi = false
    @FocusState private var dpiFieldFocused: Bool

    private var stages: [String] {
        (store.status["stages"] ?? "400,800,1600,3200,6400")
            .split(separator: ",").map(String.init).filter { store.validatedDpi($0) != nil }
    }
    private var isCustomDpi: Bool { !stages.contains(store.status["dpi"] ?? "") }
    private var validCustomDpi: Bool {
        store.validatedDpi(customDpi) != nil
    }

    var body: some View {
        VStack(spacing: 12) {
            if store.capabilities.dpi_max > 0 {
                HStack {
                    Text("DPI")
                    Spacer()
                    Picker("Mouse DPI preset", selection: dpiSelection) {
                        ForEach(stages, id: \.self) { Text($0).tag($0) }
                        Divider()
                        Text("Custom…").tag("custom")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                if editingCustomDpi || isCustomDpi {
                    HStack(spacing: 8) {
                        TextField("Custom DPI", text: $customDpi)
                            .textFieldStyle(.roundedBorder)
                            .focused($dpiFieldFocused)
                            .onSubmit(applyCustomDpi)
                            .accessibilityLabel("Custom mouse DPI")
                        Button("Apply", action: applyCustomDpi)
                            .disabled(!validCustomDpi)
                    }
                    .help("Enter a DPI between \(store.dpiMinimum) and \(store.capabilities.dpi_max)")
                }
            }
            if !store.capabilities.poll_rates.isEmpty {
                HStack {
                    Text("Polling rate")
                    Spacer()
                    Picker("Mouse polling rate", selection: pollSelection) {
                        ForEach(store.capabilities.poll_rates, id: \.self) { rate in
                            Text("\(rate) Hz").tag(String(rate))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 192)
                    .help("Report rate — higher means a snappier cursor.")
                }
            }
            if store.capabilities.scroll {
                HStack {
                    Text("Free-spin scroll")
                    Spacer()
                    Toggle("Free-spin scroll", isOn: scrollBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
        .onReceive(store.$status) { status in
            if !dpiFieldFocused { customDpi = status["dpi"] ?? "" }
        }
    }

    private var dpiSelection: Binding<String> {
        Binding(
            get: { editingCustomDpi || isCustomDpi ? "custom" : store.status["dpi"] ?? "custom" },
            set: { value in
                editingCustomDpi = value == "custom"
                if editingCustomDpi {
                    customDpi = store.status["dpi"] ?? ""
                    dpiFieldFocused = true
                } else {
                    store.setDpi(value)
                }
            }
        )
    }
    private var pollSelection: Binding<String> {
        Binding(get: { store.status["poll"] ?? "500" }, set: { store.setPoll($0) })
    }
    private var scrollBinding: Binding<Bool> {
        Binding(get: { store.status["scroll"] == "free" }, set: { store.setScroll(free: $0) })
    }
    private func applyCustomDpi() {
        guard validCustomDpi else { return }
        store.setDpi(customDpi.trimmingCharacters(in: .whitespaces))
        editingCustomDpi = false
        dpiFieldFocused = false
    }
}

// MARK: - Device and empty states

private struct DetectedDeviceGroup: View {
    @ObservedObject var deviceStore: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let device = deviceStore.detectedDevice {
                if !device.supported {
                    VStack(alignment: .leading, spacing: 8) {
                        DeviceHeader(icon: "cable.connector", name: device.name,
                                     kind: "\(device.connectionLabel)\(device.usb_id.isEmpty ? "" : " · \(device.usb_id)")", firmware: nil)
                        Text(device.transport == "bluetooth"
                            ? "Bluetooth customization for this model isn't supported yet. Try its USB cable or wireless USB receiver."
                            : "Customization for this model isn't supported yet.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 13)
                } else if device.kind == "keyboard" {
                    KeyboardGroup()
                        .padding(.vertical, 13)
                } else {
                    MouseGroup()
                }
            }
            if let error = deviceStore.commandError {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
            }
        }
    }
}

private func deviceName(_ device: String, in status: [String: String]) -> String {
    if let name = status[device] { return name }
    if let error = status["\(device)_error"], error.hasPrefix("Razer "),
       let colon = error.firstIndex(of: ":") {
        return String(error[..<colon])
    }
    return device.capitalized
}

private struct DeviceProblem: View {
    let error: String

    private var needsInputMonitoring: Bool {
        error.localizedCaseInsensitiveContains("not permitted")
            || error.localizedCaseInsensitiveContains("HID open failed")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(needsInputMonitoring ? "Input Monitoring required" : "Can't reach this device",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text(needsInputMonitoring
                 ? "Allow RazerCtl in Privacy & Security to control this device."
                 : error)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if needsInputMonitoring {
                Button("Open System Settings…") { Store.openInputMonitoringSettings() }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(error)
    }
}

private struct EmptyDevices: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.secondary)
            Text(store.isDetecting || !store.hasDetected ? "Looking for Razer devices…" : "No Razer devices detected")
                .font(.system(size: 14, weight: .semibold))
            Text("Connect by USB or its receiver, or pair your device in macOS Bluetooth settings. RazerCtl scans automatically; click Detect to try again.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

// MARK: - App bootstrap

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store = Store(bluetooth: BluetoothController())
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var hosting: NSHostingController<AnyView>?
    private var privacyCleanupObservers: [NSObjectProtocol] = []

    /// Keep the popover sized to the SwiftUI content's ideal size.
    /// Status loads asynchronously (~30 ms) after launch — the panel would
    /// otherwise lock its size to the empty skeleton and CLIP the groups
    /// once they appear ("sides cut out"). Re-sync on every status update.
    private func syncSize() {
        guard let hosting else { return }
        popover.contentSize = hosting.preferredContentSize
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "keyboard",
                                   accessibilityDescription: "RazerCtl")
            button.action = #selector(togglePopover)
            button.target = self
        }
        statusItem = item

        // .applicationDefined: stays open when focus moves elsewhere —
        // .transient auto-dismisses on ANY focus change, which made the
        // panel vanish the instant a screenshot tool (or any other app)
        // took focus. Close via the menu-bar button, Esc, or clicking it
        // again.
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingController(
            rootView: AnyView(ContentView().environmentObject(store))
        )
        // .preferredContentSize: the popover sizes itself to the SwiftUI
        // content's ideal size — no fixed height, no scroll.
        host.sizingOptions = .preferredContentSize
        host.view.appearance = NSAppearance(named: .darkAqua)
        hosting = host
        popover.contentViewController = host

        // Resize whenever the status (and thus panel content) changes:
        // groups appearing must grow the popover, never clip it.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("razerctlStatusUpdated"),
            object: nil, queue: .main) { [weak self] _ in
            self?.syncSize()
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name("razerctlPanelSizeChanged"),
            object: nil, queue: .main) { [weak self] notification in
            guard let size = notification.userInfo?["size"] as? CGSize,
                  size.width > 0, size.height > 0 else { return }
            self?.popover.contentSize = size
        }

        store.startDetection()
        store.checkForUpdates()
        store.shortcuts.start()
        store.mouseButtons.start()

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            privacyCleanupObservers.append(workspaceNotifications.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.store.setTemporaryKeyboardPrivacyEnabled(false)
                })
        }

        // If this instance was just installed by a self-update, show the
        // confirmation and open the panel automatically.
        if let confirmed = AppUpdate.finishInstallation(current: Bundle.main.bundleURL, version: Store.appVersion) {
            UserDefaults.standard.set(confirmed, forKey: "didSelfUpdateTo")
        }
        if let updatedTo = UserDefaults.standard.string(forKey: "didSelfUpdateTo") {
            UserDefaults.standard.removeObject(forKey: "didSelfUpdateTo")
            store.updateCompleted = updatedTo
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showPanel()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.setTemporaryKeyboardPrivacyEnabled(false)
        store.stopKeyboardPrivacyMonitoring()
        for observer in privacyCleanupObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        store.shortcuts.stop()
        store.mouseButtons.stop()
        store.stopDetection()
    }

    func popoverWillShow(_ notification: Notification) {
        store.startKeyboardPrivacyMonitoring()
    }

    func popoverDidClose(_ notification: Notification) {
        store.stopKeyboardPrivacyMonitoring()
    }

    /// Show the popover (used by the post-update confirmation).
    private func showPanel() {
        guard !popover.isShown, let button = statusItem?.button else { return }
        store.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.syncSize()
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            store.updateCompleted = nil // confirmation shows once
        } else if let button = statusItem?.button {
            store.refresh()
            store.checkForUpdates()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // The fresh status lands a moment after show — grow to fit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.syncSize()
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
