// RazerCtl — native macOS menu-bar control panel for Razer peripherals.
//
// Popover UI (SwiftUI) + Rust core (`razerctl-core`, adjacent binary).
// All device commands run on a serial background queue: the UI never
// blocks and commands never overlap.
//
// The panel follows the macOS grouped-settings idiom: one inset group per
// device, label-left / control-right rows separated by hairlines, no cards,
// no shadows, system accent on controls only.

import SwiftUI
import AppKit

// MARK: - Store

final class Store: ObservableObject {
    @Published var status: [String: String] = [:]

    // Local interaction state (the firmware can't read effects back).
    @Published var kbdEffect = "spectrum"
    @Published var mouseEffect = "spectrum"
    @Published var kbdColor = Color(red: 1.00, green: 0.22, blue: 0.39)
    @Published var mouseColor = Color(red: 0.20, green: 0.78, blue: 1.00)
    @Published var kbdBrightness = 100.0
    @Published var mouseBrightness = 75.0

    private var seededBrightness = false
    private var colorDebounces: [String: DispatchWorkItem] = [:]

    /// Serial queue: one command at a time, never the main thread.
    let commandQueue = DispatchQueue(label: "local.razerctl.widget.commands",
                                     qos: .userInitiated)

    /// Every core call is logged here — ground truth from the GUI context.
    static let logURL = URL(fileURLWithPath: "/tmp/razerctl-widget.log")

    // MARK: Self-update state

    /// Embedded app version (bumped by publish.sh). Compared against the
    /// latest GitHub release tag.
    static let appVersion = "1.2"

    @Published var latestVersion: String?
    @Published var updating = false
    @Published var updateError: String?
    /// Set after a self-update: the new instance shows a green
    /// "Updated to vX.Y" confirmation banner.
    @Published var updateCompleted: String?
    private var assetURL: URL?
    private let repo = "adrianhurtado88/razerctl"

    /// Check GitHub for a newer release. Throttled to one call per 10 min
    /// ( UserDefaults), re-checked at launch and popover open.
    func checkForUpdates() {
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 600 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")

        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("RazerCtl", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self,
                  let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return }
            let latest = tag.replacingOccurrences(of: "v", with: "")
            DispatchQueue.main.async {
                guard Self.isNewer(latest, than: Self.appVersion) else {
                    self.latestVersion = nil
                    return
                }
                self.latestVersion = latest
                if let assets = obj["assets"] as? [[String: Any]],
                   let urlStr = assets.compactMap({ $0["browser_download_url"] as? String })
                       .first(where: { $0.hasSuffix(".zip") }) {
                    self.assetURL = URL(string: urlStr)
                }
            }
        }.resume()
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
                try Self.runCmd("/usr/bin/ditto", ["-x", "-k", zipURL.path, tmp])
                let newApp = tmp + "/RazerCtl.app"
                guard FileManager.default.fileExists(atPath: newApp + "/Contents/MacOS/RazerCtl") else {
                    throw UpdateError.badArchive
                }
                // 3. Signature check: same code-signing team as us.
                guard let newTeam = Self.teamIdentifier(of: newApp),
                      let curTeam = Self.teamIdentifier(of: Bundle.main.bundlePath),
                      newTeam == curTeam else {
                    throw UpdateError.signatureMismatch
                }
                // 4. Swap: current -> .old, new -> current. The running
                //    process keeps its image; macOS allows this.
                let bundle = Bundle.main.bundlePath
                let parent = (bundle as NSString).deletingLastPathComponent
                let old = parent + "/RazerCtl.old.app"
                try? FileManager.default.removeItem(atPath: old)
                try FileManager.default.moveItem(atPath: bundle, toPath: old)
                try FileManager.default.moveItem(atPath: newApp, toPath: bundle)
                // 5. The downloaded file is quarantined; this app is not
                //    notarized, so clear it or Gatekeeper blocks relaunch.
                try Self.runCmd("/usr/bin/xattr",
                                 ["-dr", "com.apple.quarantine", bundle])
                // 6. Launch the new version, then exit this one. The new
                //    instance deletes the .old bundle, clears the download
                //    temp dir, and shows an "Updated" confirmation.
                UserDefaults.standard.set(self?.latestVersion ?? Self.appVersion,
                                          forKey: "didSelfUpdateTo")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bundle + "/Contents/MacOS/RazerCtl")
                try p.run()
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
        case badArchive, signatureMismatch
        var errorDescription: String? {
            switch self {
            case .badArchive: return "the release zip has no RazerCtl.app"
            case .signatureMismatch: return "downloaded app is signed by a different team"
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

    /// The bundle's code-signing team identifier (e.g. "YC4FHM93C5").
    private static func teamIdentifier(of bundlePath: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-dv", "--verbose=4", bundlePath]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n")
            .first { $0.hasPrefix("TeamIdentifier=") }?
            .replacingOccurrences(of: "TeamIdentifier=", with: "")
            .trimmingCharacters(in: .whitespaces)
    }


    var coreURL: URL? {
        let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let core = dir.appendingPathComponent("razerctl-core")
        return FileManager.default.isExecutableFile(atPath: core.path) ? core : nil
    }

    @discardableResult
    func run(_ args: [String]) -> String {
        guard let core = coreURL else {
            log("CORE MISSING at expected path")
            return ""
        }
        let p = Process()
        p.executableURL = core
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            log("spawn failed (\(args.joined(separator: " "))): \(error)")
            return ""
        }
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        log("[exit \(p.terminationStatus)] \(args.joined(separator: " "))"
            + (out.isEmpty ? "" : "  out: " + out.replacingOccurrences(of: "\n", with: " | "))
            + (err.isEmpty ? "" : "  err: " + err.replacingOccurrences(of: "\n", with: " | ")))
        return out + err
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
        commandQueue.async { [weak self] in
            _ = self?.run(args)
        }
        refresh()
    }

    /// Read `status` off-main; results publish on the main thread.
    func refresh() {
        commandQueue.async { [weak self] in
            guard let self else { return }
            let out = self.run(["status"])
            var dict: [String: String] = [:]
            for line in out.split(separator: "\n") {
                let kv = line.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { dict[String(kv[0])] = String(kv[1]) }
            }
            DispatchQueue.main.async { [weak self] in
                self?.status = dict
                // Seed both brightness sliders from the devices' real
                // values (0-255 -> 0-100%) on the first read. The mouse
                // value comes from a per-zone read (led=all is refused
                // for reads on the Basilisk V3) — see Store.refresh.
                if let s = self, !s.seededBrightness {
                    if let v = Double(dict["kbd_brightness"] ?? "") {
                        s.kbdBrightness = min(100, max(0, v / 2.55))
                    }
                    if let v = Double(dict["mouse_brightness"] ?? "") {
                        s.mouseBrightness = min(100, max(0, v / 2.55))
                    }
                    if dict["kbd_brightness"] != nil || dict["mouse_brightness"] != nil {
                        s.seededBrightness = true
                    }
                }
                NotificationCenter.default.post(
                    name: Notification.Name("razerctlStatusUpdated"), object: nil)
            }
        }
    }

    // MARK: Device actions

    func applyEffect(_ name: String, device: String) {
        if name == "rainbow" {
            command(["rainbow", "11"])
        } else {
            command(["effect", name, "--dev", device])
        }
    }

    func applyStatic(color: Color, device: String) {
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

    func setDpi(_ value: String) {
        command(["dpi", value])
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

// MARK: - Theme

/// The few colours the panel paints itself. Text, controls and the popover
/// ground are the system's; only the group fill and hairline are ours.
private enum Theme {
    static let groupRadius: CGFloat = 8

    static func groupFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color.white
    }

    static func separator(_ scheme: ColorScheme) -> Color {
        Color(nsColor: .separatorColor)
    }
}

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var store: Store

    private var hasKeyboard: Bool {
        store.status["keyboard"] != nil || store.status["keyboard_error"] != nil
    }
    private var hasMouse: Bool {
        store.status["mouse"] != nil || store.status["mouse_error"] != nil
    }

    var body: some View {
        // Fixed width; height is whatever the content needs (see
        // AppDelegate: sizingStyle .preferredContentSize means the
        // popover adopts this view's ideal height). No scroll: the
        // whole panel always fits, regardless of which groups show.
        VStack(spacing: 10) {
            TitleBar()
            if let v = store.updateCompleted {
                UpdatedBanner()
                let _ = v // shown once per session
            } else if store.latestVersion != nil {
                UpdateBanner()
            }
            if !hasKeyboard && !hasMouse {
                EmptyGroup()
            } else {
                if hasKeyboard { KeyboardGroup() }
                if hasMouse { MouseGroup() }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
        .frame(width: 340)
    }
}

// MARK: - Update banner

/// "vX.Y available" group, in the panel's grouped-settings idiom: inset,
/// hairline-outlined, yellow accent. One click: download, verify
/// signature, swap bundles, relaunch.
private struct UpdateBanner: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("v\(store.latestVersion ?? "") available")
                    .font(.system(size: 12, weight: .semibold))
                if let err = store.updateError {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            if store.updating {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Update Now") { store.performUpdate() }
                    .controlSize(.small)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(
            RoundedRectangle(cornerRadius: Theme.groupRadius)
                .fill(Color.yellow.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.groupRadius)
                .stroke(Color.yellow.opacity(0.30), lineWidth: 1)
        )
    }
}

// MARK: - Update confirmation

/// Green "Updated to vX.Y" banner shown by the instance that was just
/// installed by a self-update. Auto-clears when the panel is closed.
private struct UpdatedBanner: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.green)
            Text("Updated to v\(store.updateCompleted ?? "")")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(
            RoundedRectangle(cornerRadius: Theme.groupRadius)
                .fill(Color.green.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.groupRadius)
                .stroke(Color.green.opacity(0.30), lineWidth: 1)
        )
    }
}

// MARK: - Title bar

private struct TitleBar: View {
    var body: some View {
        HStack {
            Text("RazerCtl")
                .font(.system(size: 13, weight: .semibold))
            Text("v\(Store.appVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("About RazerCtl") { Store.showAbout() }
                Divider()
                Button("Quit RazerCtl") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .frame(height: 24)
        .padding(.leading, 4)
    }
}

// MARK: - Group building blocks

/// An inset settings group: rounded, hairline-outlined, rows inside.
private struct SettingsGroup<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.groupRadius, style: .continuous)
                .fill(Theme.groupFill(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.groupRadius, style: .continuous)
                .strokeBorder(Theme.separator(scheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.groupRadius, style: .continuous))
    }
}

/// The first row of a device group: glyph, device name, firmware.
private struct GroupHeader: View {
    @Environment(\.colorScheme) private var scheme
    let icon: String
    let name: String
    let detail: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 32)
            .padding(.horizontal, 12)
            Rectangle()
                .fill(Theme.separator(scheme))
                .frame(height: 1)
        }
    }
}

/// Hairline between two rows, inset from the leading edge like a list.
private struct RowDivider: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(Theme.separator(scheme))
            .frame(height: 1)
            .padding(.leading, 12)
    }
}

/// One settings row: label at the leading edge, control at the trailing edge.
private struct SettingRow<Control: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let control: Control

    init(_ label: LocalizedStringKey, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .lineLimit(1)
            Spacer(minLength: 12)
            control
        }
        .frame(height: 34)
        .padding(.horizontal, 12)
    }
}

// MARK: - Shared rows

private struct EffectPicker: View {
    @EnvironmentObject var store: Store
    let device: String
    let effects: [(String, String)]   // (raw command, display name)

    var body: some View {
        // Menu style: four long labels would overflow a segmented control.
        Picker("Lighting", selection: selectionBinding) {
            ForEach(effects, id: \.0) { fx in
                Text(fx.1).tag(fx.0)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 124)
    }

    private var selectionBinding: Binding<String> {
        let device = device
        let store = store
        return Binding(
            get: { device == "keyboard" ? store.kbdEffect : store.mouseEffect },
            set: { raw in
                if device == "keyboard" { store.kbdEffect = raw }
                else { store.mouseEffect = raw }
                store.applyEffect(raw, device: device)
            }
        )
    }
}

private struct ColorWell: View {
    @EnvironmentObject var store: Store
    let device: String

    var body: some View {
        ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
            .labelsHidden()
    }

    private var colorBinding: Binding<Color> {
        let device = device
        let store = store
        return Binding(
            get: { device == "keyboard" ? store.kbdColor : store.mouseColor },
            set: { store.applyStatic(color: $0, device: device) }
        )
    }
}

private struct BrightnessRow: View {
    @EnvironmentObject var store: Store
    let device: String

    var body: some View {
        HStack(spacing: 8) {
            Text("Brightness")
                .frame(width: 84, alignment: .leading)
            Image(systemName: "sun.min")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            // Commits on release only: every command is ~100 ms of device I/O.
            Slider(value: sliderValue, in: 0...100, step: 1, onEditingChanged: { editing in
                if !editing { store.setBrightness(value, device: device) }
            })
            Image(systemName: "sun.max")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("\(Int(value))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .frame(height: 34)
        .padding(.horizontal, 12)
    }

    private var value: Double {
        device == "keyboard" ? store.kbdBrightness : store.mouseBrightness
    }

    private var sliderValue: Binding<Double> {
        let device = device
        let store = store
        return Binding(
            get: { device == "keyboard" ? store.kbdBrightness : store.mouseBrightness },
            set: { v in
                if device == "keyboard" { store.kbdBrightness = v }
                else { store.mouseBrightness = v }
            }
        )
    }
}

/// Shown inside a device group when the device is present but the core
/// could not talk to it. A refused HID open on macOS means the Input
/// Monitoring grant is missing; anything else shows the core's message.
private struct DeviceProblem: View {
    let error: String

    private var needsInputMonitoring: Bool {
        error.localizedCaseInsensitiveContains("not permitted")
            || error.localizedCaseInsensitiveContains("HID open failed")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(needsInputMonitoring ? "Input Monitoring required" : "Can't reach this device")
                        .font(.system(size: 13, weight: .semibold))
                    Text(needsInputMonitoring
                         ? "macOS blocks control of this device until RazerCtl is allowed under Privacy & Security."
                         : error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if needsInputMonitoring {
                    Button("Open System Settings…") { Store.openInputMonitoringSettings() }
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
        .help(error)
    }
}

/// The core's error lines start with the device's name ("Razer Basilisk V3: …").
private func deviceName(fromError error: String) -> String? {
    guard error.hasPrefix("Razer "), let colon = error.firstIndex(of: ":") else { return nil }
    return String(error[..<colon])
}

// MARK: - Keyboard group

private struct KeyboardGroup: View {
    @EnvironmentObject var store: Store

    private var name: String {
        store.status["keyboard"]
            ?? store.status["keyboard_error"].flatMap(deviceName(fromError:))
            ?? "Keyboard"
    }

    var body: some View {
        SettingsGroup {
            GroupHeader(icon: "keyboard", name: name,
                        detail: store.status["keyboard_fw"].map { "fw \($0)" })
            if store.status["keyboard"] != nil {
                SettingRow("Lighting") {
                    EffectPicker(device: "keyboard", effects: [
                        ("spectrum", "Spectrum"),
                        ("breath", "Breath"),
                        ("none", "Off"),
                    ])
                }
                RowDivider()
                SettingRow("Color") {
                    ColorWell(device: "keyboard")
                }
                RowDivider()
                BrightnessRow(device: "keyboard")
            } else if let err = store.status["keyboard_error"] {
                DeviceProblem(error: err)
            }
        }
    }
}

// MARK: - Mouse group

private struct MouseGroup: View {
    @EnvironmentObject var store: Store
    @State private var customDpi = ""
    @FocusState private var dpiFieldFocused: Bool

    private var name: String {
        store.status["mouse"]
            ?? store.status["mouse_error"].flatMap(deviceName(fromError:))
            ?? "Mouse"
    }

    private var stages: [String] {
        (store.status["stages"] ?? "400,800,1600,3200,6400")
            .split(separator: ",").map(String.init)
    }

    private var isCustomDpi: Bool {
        let dpi = store.status["dpi"] ?? ""
        return !stages.contains(dpi)
    }

    private var dpiSelection: Binding<String> {
        let stages = stages
        let store = store
        return Binding(
            get: {
                let dpi = store.status["dpi"] ?? ""
                return stages.contains(dpi) ? dpi : "custom"
            },
            set: { raw in
                if raw != "custom" { store.setDpi(raw) }
            }
        )
    }

    private var pollSelection: Binding<String> {
        let store = store
        return Binding(
            get: { store.status["poll"] ?? "500" },
            set: { store.setPoll($0) }
        )
    }

    private var scrollBinding: Binding<Bool> {
        let store = store
        return Binding(
            get: { store.status["scroll"] == "free" },
            set: { store.setScroll(free: $0) }
        )
    }

    var body: some View {
        SettingsGroup {
            GroupHeader(icon: "computermouse", name: name,
                        detail: store.status["mouse_fw"].map { "fw \($0)" })

            if store.status["mouse"] != nil {
                SettingRow("DPI") {
                    Picker("DPI", selection: dpiSelection) {
                        ForEach(stages, id: \.self) { Text($0).tag($0) }
                        Divider()
                        Text("Custom…").tag("custom")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 124)
                }
                if isCustomDpi {
                    RowDivider()
                    SettingRow("Custom DPI") {
                        HStack(spacing: 8) {
                            // Placeholder = the value the device reports now.
                            TextField(store.status["dpi"] ?? "e.g. 1800", text: $customDpi)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 96)
                                .focused($dpiFieldFocused)
                                .onSubmit(applyCustomDpi)
                            Button("Apply", action: applyCustomDpi)
                                .controlSize(.small)
                        }
                    }
                }
                RowDivider()
                SettingRow("Polling rate") {
                    Picker("Polling rate", selection: pollSelection) {
                        Text("125 Hz").tag("125")
                        Text("500 Hz").tag("500")
                        Text("1000 Hz").tag("1000")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 186)
                    .help("Report rate — higher means a snappier cursor.")
                }
                RowDivider()
                SettingRow("Lighting") {
                    EffectPicker(device: "mouse", effects: [
                        ("spectrum", "Spectrum"),
                        ("wave", "Wave"),
                        ("rainbow", "Rainbow"),
                        ("none", "Off"),
                    ])
                }
                RowDivider()
                SettingRow("Color") {
                    ColorWell(device: "mouse")
                }
                RowDivider()
                BrightnessRow(device: "mouse")
                RowDivider()
                SettingRow("Free-spin scroll wheel") {
                    Toggle("Free-spin scroll wheel", isOn: scrollBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            } else if let err = store.status["mouse_error"] {
                DeviceProblem(error: err)
            }
        }
    }

    private func applyCustomDpi() {
        let v = customDpi.trimmingCharacters(in: .whitespaces)
        guard Int(v) != nil else { return }
        store.setDpi(v)
        dpiFieldFocused = false
    }
}

// MARK: - Empty state

private struct EmptyGroup: View {
    var body: some View {
        SettingsGroup {
            VStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                Text("No Razer devices detected")
                    .font(.system(size: 13, weight: .semibold))
                Text("Plug in your Razer keyboard or mouse, then open RazerCtl again.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: 28, leading: 20, bottom: 28, trailing: 20))
        }
    }
}

// MARK: - App bootstrap

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var hosting: NSHostingController<AnyView>?

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

        // Self-update housekeeping: remove the replaced bundle left by a
        // previous update (this instance is already running from it) and
        // any download temp dirs.
        let oldBundle = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
            + "/RazerCtl.old.app"
        try? FileManager.default.removeItem(atPath: oldBundle)
        let tmp = NSTemporaryDirectory()
        if let leftovers = try? FileManager.default.contentsOfDirectory(atPath: tmp) {
            for item in leftovers where item.hasPrefix("razerctl-update-") {
                try? FileManager.default.removeItem(atPath: tmp + item)
            }
        }

        // .applicationDefined: stays open when focus moves elsewhere —
        // .transient auto-dismisses on ANY focus change, which made the
        // panel vanish the instant a screenshot tool (or any other app)
        // took focus. Close via the menu-bar button, Esc, or clicking it
        // again.
        popover.behavior = .applicationDefined
        popover.animates = true
        let host = NSHostingController(
            rootView: AnyView(ContentView().environmentObject(store))
        )
        // .preferredContentSize: the popover sizes itself to the SwiftUI
        // content's ideal size — no fixed height, no scroll.
        host.sizingOptions = .preferredContentSize
        hosting = host
        popover.contentViewController = host

        // Resize whenever the status (and thus panel content) changes:
        // groups appearing must grow the popover, never clip it.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("razerctlStatusUpdated"),
            object: nil, queue: .main) { [weak self] _ in
            self?.syncSize()
        }

        store.refresh()
        store.checkForUpdates()

        // If this instance was just installed by a self-update, show the
        // confirmation and open the panel automatically.
        if let updatedTo = UserDefaults.standard.string(forKey: "didSelfUpdateTo") {
            UserDefaults.standard.removeObject(forKey: "didSelfUpdateTo")
            store.updateCompleted = updatedTo
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showPanel()
            }
        }
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
