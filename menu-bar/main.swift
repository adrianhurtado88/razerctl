// RazerCtl — native macOS menu-bar control panel for Razer peripherals.
//
// Popover UI (SwiftUI) + Rust core (`razerctl-core`, adjacent binary).
// All device commands run on a serial background queue: the UI never
// blocks and commands never overlap.

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
                if let s = self, !s.seededBrightness,
                   let v = Double(dict["kbd_brightness"] ?? "") {
                    s.kbdBrightness = min(100, max(0, v / 2.55))
                    s.seededBrightness = true
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
}

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        // Fixed width; height is whatever the content needs (see
        // AppDelegate: sizingStyle .preferredContentSize means the
        // popover adopts this view's ideal height). No scroll: the
        // whole panel always fits, regardless of which cards show.
        VStack(spacing: 16) {
            HeaderView()
                .padding(.horizontal, 2)
            if store.status["keyboard"] != nil || store.status["keyboard_error"] != nil {
                KeyboardCard()
            }
            if store.status["mouse"] != nil || store.status["mouse_error"] != nil {
                MouseCard()
            }
            if store.status["keyboard"] == nil && store.status["mouse"] == nil
                && store.status["keyboard_error"] == nil && store.status["mouse_error"] == nil {
                NotFoundCard()
            }
            FooterView()
                .padding(.horizontal, 2)
        }
        .padding(16)
        .frame(width: 380)
    }
}

// MARK: - Header / Footer

private struct HeaderView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("RazerCtl")
                    .font(.system(size: 15, weight: .semibold))
                Text("Local control · no Synapse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill((store.status["keyboard"] != nil && store.status["mouse"] != nil)
                      ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 4)
    }
}

private struct FooterView: View {
    var body: some View {
        HStack {
            Text("v1.0")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit RazerCtl") {
                NSApp.terminate(nil)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 4)
    }
}

private struct NotFoundCard: View {
    var body: some View {
        GroupBox {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("No Razer devices detected — plug them in and reopen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared rows

private struct EffectRow: View {
    @EnvironmentObject var store: Store
    let device: String
    let effects: [(String, String)]   // (raw command, display name)

    private let labelWidth: CGFloat = 92

    var body: some View {
        HStack(spacing: 12) {
            Text("Effect")
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Picker("Effect", selection: selectionBinding) {
                ForEach(effects, id: \.0) { fx in
                    Text(fx.1).tag(fx.0)
                }
            }
            // Menu style: segmented pickers refuse to compress below their
            // ideal width (4 long labels ~360pt) and overflow the card;
            // menu pickers always fit the width they're given.
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .lineLimit(1)
        }
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

private struct ColorRow: View {
    @EnvironmentObject var store: Store
    let device: String

    private let labelWidth: CGFloat = 92

    var body: some View {
        HStack(spacing: 12) {
            Text("Static color")
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(maxWidth: .infinity)
        }
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
        HStack(spacing: 12) {
            Text("Brightness")
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Slider(value: sliderValue, in: 0...100, step: 1, onEditingChanged: { editing in
                if !editing { store.setBrightness(value, device: device) }
            })
            Text("\(Int(value))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
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

private struct DeviceCaption: View {
    let name: String?
    let fw: String?
    let error: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(name ?? "Unavailable")
                .font(.system(size: 13, weight: .semibold))
            if let fw {
                Text("fw \(fw)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(error)
            }
        }
    }
}

// MARK: - Card components

/// A macOS-style card: soft background, 14pt padding, roomy corners.
private struct Card<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// A labelled group of rows inside a card, separated by a divider.
private struct CardSection: View {
    let label: LocalizedStringKey
    @ViewBuilder let content: AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            content
        }
        .padding(.vertical, 2)
    }
}

/// Thin divider used between card sections.
private struct CardDivider: View {
    var body: some View {
        Divider().padding(.vertical, 6)
    }
}

// MARK: - Keyboard card

private struct KeyboardCard: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Card(title: "Keyboard", icon: "keyboard") {
            VStack(alignment: .leading, spacing: 10) {
                DeviceCaption(
                    name: store.status["keyboard"],
                    fw: store.status["keyboard_fw"],
                    error: store.status["keyboard_error"]
                )
                if store.status["keyboard"] != nil {
                    CardSection(label: "Lighting") {
                        AnyView(
                            VStack(spacing: 10) {
                                EffectRow(device: "keyboard", effects: [
                                    ("spectrum", "Spectrum"),
                                    ("breath", "Breath"),
                                    ("none", "Off"),
                                ])
                                ColorRow(device: "keyboard")
                            }
                        )
                    }
                    CardDivider()
                    BrightnessRow(device: "keyboard")
                } else if let err = store.status["keyboard_error"] {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Mouse card

private struct MouseCard: View {
    @EnvironmentObject var store: Store
    @State private var customDpi = ""
    @FocusState private var dpiFieldFocused: Bool

    private var stages: [String] {
        (store.status["stages"] ?? "400,800,1600,3200,6400")
            .split(separator: ",").map(String.init)
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
        Card(title: "Mouse", icon: "computermouse") {
            VStack(alignment: .leading, spacing: 10) {
                DeviceCaption(
                    name: store.status["mouse"],
                    fw: store.status["mouse_fw"],
                    error: store.status["mouse_error"]
                )

                if store.status["mouse"] != nil {
                    // DPI
                    CardSection(label: "Sensitivity") {
                        AnyView(
                            VStack(spacing: 8) {
                                HStack(spacing: 12) {
                                    Text("DPI").foregroundStyle(.secondary)
                                        .frame(width: 92, alignment: .leading)
                                    Picker("DPI", selection: dpiSelection) {
                                        ForEach(stages, id: \.self) { Text($0).tag($0) }
                                        Text("Custom").tag("custom")
                                    }
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: .infinity)
                                }
                                if dpiSelection.wrappedValue == "custom" {
                                    HStack(spacing: 8) {
                                        Spacer()
                                        Text("Custom value:")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        TextField("e.g. 1800", text: $customDpi)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 96)
                                            .focused($dpiFieldFocused)
                                            .onSubmit(applyCustomDpi)
                                        Button("Apply", action: applyCustomDpi)
                                            .controlSize(.small)
                                    }
                                }
                                HStack(spacing: 12) {
                                    Text("Polling").foregroundStyle(.secondary)
                                        .frame(width: 92, alignment: .leading)
                                    Picker("Polling rate", selection: pollSelection) {
                                        Text("125").tag("125")
                                        Text("500").tag("500")
                                        Text("1000").tag("1000")
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(maxWidth: .infinity)
                                }
                                .help("Report rate in Hz — higher means snappier cursor.")
                            }
                        )
                    }

                    CardDivider()

                    // Lighting
                    CardSection(label: "Lighting") {
                        AnyView(
                            VStack(spacing: 10) {
                                EffectRow(device: "mouse", effects: [
                                    ("spectrum", "Spectrum"),
                                    ("wave", "Wave"),
                                    ("rainbow", "Rainbow"),
                                    ("none", "Off"),
                                ])
                                ColorRow(device: "mouse")
                            }
                        )
                    }

                    CardDivider()

                    BrightnessRow(device: "mouse")

                    CardDivider()

                    Toggle("Free-spin scroll wheel", isOn: scrollBinding)
                } else if let err = store.status["mouse_error"] {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

// MARK: - App bootstrap

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var hosting: NSHostingController<AnyView>?

    /// Keep the popover sized to the SwiftUI content's ideal size.
    /// Status loads asynchronously (~30 ms) after launch — the panel would
    /// otherwise lock its size to the empty skeleton and CLIP the cards
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
        // cards appearing must grow the popover, never clip it.
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
