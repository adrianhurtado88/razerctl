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

// MARK: - Title bar

private struct TitleBar: View {
    var body: some View {
        HStack {
            Text("RazerCtl")
                .font(.system(size: 13, weight: .semibold))
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
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem?.button {
            store.refresh()
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
