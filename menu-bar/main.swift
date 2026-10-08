// RazerCtl menu-bar widget — a tiny native wrapper around the `razerctl`
// Rust core. No Electron, no cloud, no login. Menu bar only (LSUIElement).

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    var colorTarget = "all" // keyboard | mouse | all

    func applicationDidFinishLaunching(_ note: Notification) {
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Razer") {
                button.image = img
            } else {
                button.title = "RZ"
            }
        }
        menu.delegate = self
        statusItem.menu = menu

        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPicked(_:)))
        panel.isContinuous = false // fire on release, not every drag tick
        refreshStatus { [weak self] in
            self?.rebuild()
        }
    }

    // ------------------------------------------------------------------ core

    /// URL of the Rust core shipped next to this app's executable.
    ///
    /// Named `razerctl-core` — NOT `razerctl` — because macOS's filesystem
    /// is case-insensitive: `razerctl` and `RazerCtl` are the same path, and
    /// bundling both under those names once caused the Swift binary to
    /// overwrite the core, so every status call re-launched the whole app
    /// (a fork bomb of menu-bar icons).
    var coreURL: URL? {
        let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let core = dir.appendingPathComponent("razerctl-core")
        return FileManager.default.isExecutableFile(atPath: core.path) ? core : nil
    }

    /// Every core invocation is logged here — ground truth from inside the
    /// GUI context (TCC privacy decisions differ from a terminal's).
    static let logURL = URL(fileURLWithPath: "/tmp/razerctl-widget.log")

    @discardableResult
    func run(_ args: [String]) -> String {
        guard let core = coreURL else {
            log("CORE MISSING at expected path")
            return "" // never spawn blind
        }
        let p = Process()
        p.executableURL = core
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        let errPipe = Pipe()
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            log("spawn failed (\(args.joined(separator: " "))): \(error)")
            return ""
        }
        p.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        log("[exit \(p.terminationStatus)] \(args.joined(separator: " "))"
            + (out.isEmpty ? "" : "\n  out: \(out.replacingOccurrences(of: "\n", with: " | "))")
            + (err.isEmpty ? "" : "\n  err: \(err.replacingOccurrences(of: "\n", with: " | "))"))
        return out + err
    }

    private func log(_ msg: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        let line = "\(stamp)  \(msg)\n"
        // FileHandle(forWritingTo:) fails if the file doesn't exist.
        if !FileManager.default.fileExists(atPath: Self.logURL.path) {
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: Self.logURL) {
            _ = try? h.seekToEnd()
            _ = try? h.write(contentsOf: line.data(using: .utf8)!)
            try? h.close()
        }
    }

    var lastStatus: [String: String] = [:]

    /// ALL device commands go through this SERIAL background queue: never
    /// the main thread (which would freeze the menu), and never more than
    /// one at a time (concurrent core processes fight over the HID
    /// devices and can wedge them).
    let commandQueue = DispatchQueue(label: "local.razerctl.widget.commands",
                                     qos: .userInitiated)

    /// Enqueue a fire-and-forget device command.
    func enqueue(_ args: [String]) {
        commandQueue.async { [weak self] in
            _ = self?.run(args)
        }
    }

    /// Refresh the cached device status on the command queue; `completion`
    /// runs on the main thread once the new status is cached.
    func refreshStatus(completion: (() -> Void)? = nil) {
        commandQueue.async { [weak self] in
            guard let self else { return }
            let out = self.run(["status"])
            var dict: [String: String] = [:]
            for line in out.split(separator: "\n") {
                let kv = line.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { dict[String(kv[0])] = String(kv[1]) }
            }
            DispatchQueue.main.async { [weak self] in
                self?.lastStatus = dict
                completion?()
            }
        }
    }

    // ------------------------------------------------------------- menu ui

    func rebuild() {
        menu.removeAllItems()
        let s = lastStatus
        let hasMouse = s["mouse"] != nil
        let hasKbd = s["keyboard"] != nil

        if !hasMouse && !hasKbd {
            let item = NSMenuItem(title: "No Razer devices found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            // If a device is present but refused communication, say why.
            for (label, key) in [("Keyboard", "keyboard_error"), ("Mouse", "mouse_error")] {
                if let err = s[key] {
                    let it = NSMenuItem(title: "⚠ \(label): \(err)", action: nil, keyEquivalent: "")
                    it.isEnabled = false
                    menu.addItem(it)
                }
            }
            menu.addItem(.separator())
        } else {
            // If one device is missing but present-and-errored, say why.
            if !hasKbd, let err = s["keyboard_error"] {
                let it = NSMenuItem(title: "⚠ Keyboard unavailable: \(err)", action: nil, keyEquivalent: "")
                it.isEnabled = false
                menu.addItem(it)
            }
            if !hasMouse, let err = s["mouse_error"] {
                let it = NSMenuItem(title: "⚠ Mouse unavailable: \(err)", action: nil, keyEquivalent: "")
                it.isEnabled = false
                menu.addItem(it)
            }
            // ============================ KEYBOARD ============================
            if hasKbd {
                let head = NSMenuItem(title: "⌨︎ KEYBOARD — \(s["keyboard"]!)  (fw \(s["keyboard_fw"] ?? "?"))",
                                      action: nil, keyEquivalent: "")
                head.isEnabled = false
                menu.addItem(head)

                // Keyboard lighting: spectrum + breath + static + off.
                // (No wave — the Ornata V3 X refuses it; verified on hardware.)
                let kfx = NSMenu(title: "Keyboard lighting")
                for (title, fx) in [
                    ("Spectrum (rainbow)", "spectrum"),
                    ("Breath (fade)", "breath"),
                ] {
                    let it = NSMenuItem(title: title, action: #selector(setEffect(_:)), keyEquivalent: "")
                    it.target = self
                    it.representedObject = "\(fx)|keyboard"
                    kfx.addItem(it)
                }
                let kStatic = NSMenuItem(title: "Static color…", action: #selector(pickColorTargeted(_:)), keyEquivalent: "")
                kStatic.target = self
                kStatic.representedObject = "keyboard"
                kfx.addItem(kStatic)
                let kOff = NSMenuItem(title: "Off", action: #selector(setEffect(_:)), keyEquivalent: "")
                kOff.target = self
                kOff.representedObject = "none|keyboard"
                kfx.addItem(kOff)
                let kfxItem = NSMenuItem(title: "Lighting", action: nil, keyEquivalent: "")
                kfxItem.submenu = kfx
                menu.addItem(kfxItem)
                menu.addItem(.separator())
            }

            // ============================== MOUSE ==============================
            if hasMouse {
                let head = NSMenuItem(title: "🖱 MOUSE — \(s["mouse"]!)  (fw \(s["mouse_fw"] ?? "?"))",
                                      action: nil, keyEquivalent: "")
                head.isEnabled = false
                menu.addItem(head)
                if let dpi = s["dpi"] {
                    let info = NSMenuItem(title: "DPI \(dpi) × \(s["dpi_y"] ?? dpi) · \(s["poll"] ?? "?") Hz · \(s["scroll"] ?? "?") scroll",
                                          action: nil, keyEquivalent: "")
                    info.isEnabled = false
                    menu.addItem(info)
                }

                // DPI picker
                let dpiMenu = NSMenu(title: "DPI")
                let stages = (s["stages"] ?? "400,800,1600,3200,6400").split(separator: ",").map(String.init)
                for v in stages {
                    let it = NSMenuItem(title: "\(v)", action: #selector(setDpi(_:)), keyEquivalent: "")
                    it.target = self
                    it.state = (v == s["dpi"] && v == s["dpi_y"]) ? .on : .off
                    dpiMenu.addItem(it)
                }
                let custom = NSMenuItem(title: "Custom…", action: #selector(customDpi(_:)), keyEquivalent: "")
                custom.target = self
                dpiMenu.addItem(custom)
                let dpiItem = NSMenuItem(title: "DPI", action: nil, keyEquivalent: "")
                dpiItem.submenu = dpiMenu
                menu.addItem(dpiItem)

                // Polling rate
                let pollMenu = NSMenu(title: "Polling rate")
                for rate in ["125", "500", "1000"] {
                    let it = NSMenuItem(title: "\(rate) Hz", action: #selector(setPoll(_:)), keyEquivalent: "")
                    it.target = self
                    it.state = (rate == s["poll"]) ? .on : .off
                    pollMenu.addItem(it)
                }
                let pollItem = NSMenuItem(title: "Polling rate", action: nil, keyEquivalent: "")
                pollItem.submenu = pollMenu
                menu.addItem(pollItem)

                // Mouse lighting: spectrum + wave + per-zone rainbow + static
                // + off. (No breath — the Basilisk V3 refuses it.)
                let mfx = NSMenu(title: "Mouse lighting")
                for (title, fx) in [
                    ("Spectrum (rainbow)", "spectrum"),
                    ("Wave (animated)", "wave"),
                ] {
                    let it = NSMenuItem(title: title, action: #selector(setEffect(_:)), keyEquivalent: "")
                    it.target = self
                    it.representedObject = "\(fx)|mouse"
                    mfx.addItem(it)
                }
                let rainbowIt = NSMenuItem(title: "Rainbow (static, per-zone)",
                                           action: #selector(runRainbow(_:)), keyEquivalent: "")
                rainbowIt.target = self
                mfx.addItem(rainbowIt)
                let mStatic = NSMenuItem(title: "Static color…", action: #selector(pickColorTargeted(_:)), keyEquivalent: "")
                mStatic.target = self
                mStatic.representedObject = "mouse"
                mfx.addItem(mStatic)
                let mOff = NSMenuItem(title: "Off", action: #selector(setEffect(_:)), keyEquivalent: "")
                mOff.target = self
                mOff.representedObject = "none|mouse"
                mfx.addItem(mOff)
                let mfxItem = NSMenuItem(title: "Lighting", action: nil, keyEquivalent: "")
                mfxItem.submenu = mfx
                menu.addItem(mfxItem)

                // Scroll mode toggle
                let scroll = NSMenuItem(title: "Free-spin scroll wheel",
                                         action: #selector(toggleScroll(_:)), keyEquivalent: "")
                scroll.target = self
                scroll.state = (s["scroll"] == "free") ? .on : .off
                menu.addItem(scroll)
            }

            menu.addItem(.separator())

            // ===================== BOTH (shared) =====================
            // Two-row view: label on top, slider beneath — nothing
            // overlapping, nothing clipped outside the view bounds.
            let sliderItem = NSMenuItem()
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
            let label = NSTextField(labelWithString: "Brightness (both devices)")
            label.frame = NSRect(x: 16, y: 36, width: 268, height: 14)
            label.font = NSFont.menuBarFont(ofSize: 0)
            view.addSubview(label)
            // Start the slider at the real device brightness (0-255 ->
            // 0-100%), preferring the mouse's value.
            let raw255 = Double(s["brightness"] ?? "") ?? Double(s["kbd_brightness"] ?? "") ?? 191
            let pct = min(100.0, max(0.0, raw255 / 2.55))
            let slider = NSSlider(value: pct, minValue: 0, maxValue: 100, target: self, action: #selector(brightnessChanged(_:)))
            slider.isContinuous = false // fire on release, not every drag tick
            slider.frame = NSRect(x: 16, y: 8, width: 268, height: 20)
            view.addSubview(slider)
            sliderItem.view = view
            menu.addItem(sliderItem)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit RazerCtl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // -------------------------------------------------------------- actions

    @objc func setDpi(_ sender: NSMenuItem) {
        enqueue(["dpi", sender.title])
        refreshSoon()
    }

    @objc func customDpi(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Custom DPI"
        alert.informativeText = "DPI for both axes (100 – 26000):"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "1800"
        alert.accessoryView = field
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let v = field.intValue
            if v >= 100 {
                enqueue(["dpi", String(v)])
                refreshSoon()
            }
        }
    }

    @objc func setPoll(_ sender: NSMenuItem) {
        let rate = sender.title.split(separator: " ").first.map(String.init) ?? "500"
        enqueue(["poll", rate])
        refreshSoon()
    }

    /// representedObject carries "effect|device" — e.g. "wave|mouse",
    /// "breath|keyboard", "none|mouse". Applies the effect to ONE device,
    /// so a keyboard-only effect never gets refused by the mouse and
    /// vice versa.
    @objc func setEffect(_ sender: NSMenuItem) {
        let spec = sender.representedObject as? String ?? "spectrum|all"
        let parts = spec.split(separator: "|").map(String.init)
        let fx = parts.first ?? "spectrum"
        let dev = parts.count > 1 ? parts[1] : nil
        var args = ["effect", fx]
        if let dev, dev != "all" { args += ["--dev", dev] }
        enqueue(args)
        refreshSoon()
    }

    @objc func pickColorTargeted(_ sender: NSMenuItem) {
        colorTarget = sender.representedObject as? String ?? "all"
        openColorPanel()
    }

    /// Lighting → Rainbow (static, per-zone): `razerctl rainbow 11`.
    @objc func runRainbow(_ sender: NSMenuItem) {
        enqueue(["rainbow", "11"])
        refreshSoon()
    }

    func openColorPanel() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPicked(_:)))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func colorPicked(_ sender: Any?) {
        guard let c = NSColorPanel.shared.color.usingColorSpace(.deviceRGB) else { return }
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        let hex = String(format: "%02X%02X%02X", r, g, b)
        switch colorTarget {
        case "keyboard": enqueue(["effect", "static", hex, "--dev", "keyboard"])
        case "mouse":   enqueue(["effect", "static", hex, "--dev", "mouse"])
        default:        enqueue(["effect", "static", hex])
        }
    }

    /// The slider is non-continuous (fires once, on release) and the
    /// command runs on the serial background queue — dragging never
    /// touches the main thread or the devices.
    @objc func brightnessChanged(_ sender: NSSlider) {
        enqueue(["brightness", String(Int(sender.intValue))])
    }

    @objc func toggleScroll(_ sender: NSMenuItem) {
        let next = (sender.state == .on) ? "tactile" : "free"
        enqueue(["scroll", next])
        refreshSoon()
    }

    func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refreshStatus { [weak self] in
                self?.rebuild()
            }
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Rebuilding while the menu is open/tracking tears down the submenus
    /// the user is interacting with (they flash closed — reads as "can't
    /// open keyboard settings"). So: never rebuild here. The menu is built
    /// at launch and rebuilt only after actions (refreshSoon).
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        if menu.items.isEmpty {
            rebuild()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()