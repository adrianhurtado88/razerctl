// Compiled with the production Store and views by check-widget.sh.
// Offscreen controls and a CLI stub keep these checks away from hardware.
func check(_ condition: @autoclosure () -> Bool, _ message: String = "", line: Int = #line) {
    if !condition() {
        fputs("Widget check failed at line \(line): \(message)\n", stderr)
        exit(1)
    }
}
let testApp = NSApplication.shared
testApp.setActivationPolicy(.prohibited)
testApp.appearance = NSAppearance(named: .darkAqua)
let testDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let stubURL = testDirectory.appendingPathComponent("razerctl-core")
let stub = #"""
#!/bin/sh
printf '%s\n' "$*" >> "$(dirname "$0")/commands.txt"
if [ "$1" = inventory ] || [ "$1" = detect ]; then
    cat "$(dirname "$0")/devices.json"
elif [ -f "$(dirname "$0")/fail-command" ]; then
    echo 'error: selected device is unavailable' >&2
    exit 1
fi
"""#
try stub.write(to: stubURL, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubURL.path)

let parsed = Store.parseStatus("keyboard=Razer Ornata V3 X keyboard_fw=2.0\nmouse=Razer Basilisk V3 mouse_fw=1.2\ndpi=1800\n")
check(parsed["keyboard"] == "Razer Ornata V3 X")
check(parsed["keyboard_fw"] == "2.0")
check(parsed["mouse"] == "Razer Basilisk V3")
check(parsed["mouse_fw"] == "1.2")
check(parsed["dpi"] == "1800")
check(Store.parseStatus("keyboard=Razer Ornata V3 X\nkeyboard_fw=2.0\n")["keyboard_fw"] == "2.0")
check(Store.parseStatus("mouse_error=Razer Basilisk V3: failed=not permitted\n")["mouse_error"] == "Razer Basilisk V3: failed=not permitted")
check(Store.parseStatus("not a status line\n").isEmpty)

func settle(_ store: Store) {
    for _ in 0..<3 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        store.commandQueue.sync {}
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
func commands() -> [String] {
    (try? String(contentsOf: testDirectory.appendingPathComponent("commands.txt"), encoding: .utf8))?
        .split(separator: "\n").map(String.init).filter { $0 != "status" && $0 != "detect" && $0 != "inventory" } ?? []
}

func fixtureDevice(_ id: String, kind: String, name: String,
                   effects: [String] = [], settings: [String: String] = [:],
                   dpi: Int = 0, scroll: Bool = false, zones: Int = 0,
                   supported: Bool = true, error: String? = nil) -> [String: Any] {
    ["id": id, "kind": kind, "name": name, "usb_id": "1532:FFFF", "supported": supported,
     "error": error as Any? ?? NSNull(), "settings": settings,
     "capabilities": ["effects": effects, "brightness": settings["kbd_brightness"] != nil || settings["mouse_brightness"] != nil,
                      "dpi_max": dpi, "dpi_stages": dpi > 0, "poll_rates": dpi > 0 ? [125, 500, 1000] : [],
                      "scroll": scroll, "zones": zones]]
}
let keyboardFixture = fixtureDevice("kbd-1", kind: "keyboard", name: "Razer Ornata V3 X",
    effects: ["spectrum", "breath", "static", "none"],
    settings: ["keyboard": "Razer Ornata V3 X", "keyboard_fw": "2.0", "kbd_brightness": "255"])
let mouseFixture = fixtureDevice("mouse-1", kind: "mouse", name: "Razer Basilisk V3",
    effects: ["spectrum", "wave", "rainbow", "static", "none"],
    settings: ["mouse": "Razer Basilisk V3", "mouse_fw": "1.2", "mouse_brightness": "255",
               "dpi": "1800", "poll": "500", "scroll": "tactile"], dpi: 26000, scroll: true, zones: 11)
let viperFixture = fixtureDevice("mouse-2", kind: "mouse", name: "Razer Viper V2 Pro",
    settings: ["mouse": "Razer Viper V2 Pro", "dpi": "1600", "poll": "1000"], dpi: 30000)
let unknownFixture = fixtureDevice("unknown-1", kind: "device", name: "New Razer Model", supported: false)
func writeDevices(_ devices: [[String: Any]]) throws {
    try JSONSerialization.data(withJSONObject: ["devices": devices], options: [.sortedKeys])
        .write(to: testDirectory.appendingPathComponent("devices.json"), options: .atomic)
}
try writeDevices([keyboardFixture, mouseFixture, viperFixture, unknownFixture])
let discoveryStore = Store()
discoveryStore.startDetection()
check(discoveryStore.isDetecting, "Startup should scan immediately")
settle(discoveryStore)
check(discoveryStore.deviceStores.count == 4)
check(discoveryStore.hasDetected && !discoveryStore.isDetecting && discoveryStore.detectionError == nil)
check(commands().isEmpty, "Detection must not change device settings")
let actionStore = discoveryStore.deviceStores[0]
let detectedMouseStore = discoveryStore.deviceStores[1]
let viperStore = discoveryStore.deviceStores[2]
let unknownStore = discoveryStore.deviceStores[3]
check(actionStore.kbdBrightness == 100 && detectedMouseStore.mouseBrightness == 100)
check(actionStore.kbdEffect.isEmpty, "Detection must not pretend to read the current effect")
check(viperStore.capabilities.effects.isEmpty && !viperStore.capabilities.scroll)
check(viperStore.capabilities.dpi_max == 30000)
check(actionStore.shortcuts === discoveryStore.shortcuts && detectedMouseStore.mouseButtons === discoveryStore.mouseButtons,
      "Device sections must share the app's existing shortcut and mouse assignment stores")
check(!discoveryStore.deviceStores[3].detectedDevice!.supported)
actionStore.applyEffect("static", device: "keyboard")
settle(actionStore)
check(commands() == ["effect static FF3863 --dev keyboard --id kbd-1"])
check(actionStore.kbdEffect == "static")
detectedMouseStore.applyStatic(color: .red, device: "mouse")
detectedMouseStore.applyStatic(color: .green, device: "mouse")
detectedMouseStore.applyStatic(color: Color(red: 0, green: 0, blue: 1), device: "mouse")
check(NSColor(detectedMouseStore.mouseColor).usingColorSpace(.deviceRGB)!.blueComponent == 1)
settle(detectedMouseStore)
check(commands().suffix(1) == ["effect static 0000FF --dev mouse --id mouse-1"])
check(commands().count == 2, "Color dragging must debounce device writes")
actionStore.setBrightness(37, device: "keyboard")
detectedMouseStore.setDpi("1800")
detectedMouseStore.setPoll("500")
detectedMouseStore.setScroll(free: true)
settle(actionStore)
check(commands().suffix(4) == ["brightness 37 --dev keyboard --id kbd-1", "dpi 1800 --id mouse-1", "poll 500 --id mouse-1", "scroll free --id mouse-1"])
check(detectedMouseStore.status["dpi"] == "1800")
viperStore.setDpi("30000")
settle(viperStore)
check(commands().last == "dpi 30000 --id mouse-2", "Second mouse must retain its exact target")
check(discoveryStore.deviceStores[1] === detectedMouseStore, "Rescans should preserve local device interactions")
check(detectedMouseStore.mouseEffect == "static")
detectedMouseStore.applyEffect("rainbow", device: "mouse")
settle(detectedMouseStore)
check(commands().last == "rainbow 11 --id mouse-1")

// A stable inventory does not cause repeated control reads.
let commandsFile = testDirectory.appendingPathComponent("commands.txt")
let beforeStableCheck = try String(contentsOf: commandsFile, encoding: .utf8).split(separator: "\n").filter { $0 == "detect" }.count
discoveryStore.checkForDeviceChanges()
settle(discoveryStore)
let afterStableCheck = try String(contentsOf: commandsFile, encoding: .utf8).split(separator: "\n").filter { $0 == "detect" }.count
check(afterStableCheck == beforeStableCheck)

// Let the actual automatic timer notice a new device list.
try writeDevices([keyboardFixture, viperFixture])
RunLoop.main.run(until: Date().addingTimeInterval(3.2))
settle(discoveryStore)
check(discoveryStore.deviceStores.map(\.id) == ["kbd-1", "mouse-2"], "Automatic scan should notice disconnects")
discoveryStore.stopDetection()
try writeDevices([])
discoveryStore.refresh()
settle(discoveryStore)
check(discoveryStore.deviceStores.isEmpty && discoveryStore.detectionError == nil)
let denied = fixtureDevice("kbd-1", kind: "keyboard", name: "Razer Ornata V3 X",
                          error: "HID open failed: not permitted")
try writeDevices([denied, unknownFixture])
discoveryStore.refresh()
settle(discoveryStore)
check(discoveryStore.deviceStores[0].status["keyboard_error"]!.contains("not permitted"))
check(discoveryStore.deviceStores[0].status["keyboard"] == nil)
check(discoveryStore.deviceStores.count == 2, "Unknown hardware must remain visible")
try "bad JSON".write(to: testDirectory.appendingPathComponent("devices.json"), atomically: true, encoding: .utf8)
discoveryStore.refresh()
settle(discoveryStore)
check(discoveryStore.detectionError != nil && discoveryStore.deviceStores.count == 2,
      "Failed detection must keep the last inventory and surface an error")
try writeDevices([mouseFixture])
discoveryStore.refresh()
settle(discoveryStore)
let recoveredMouse = discoveryStore.deviceStores[0]
try "".write(to: testDirectory.appendingPathComponent("fail-command"), atomically: true, encoding: .utf8)
recoveredMouse.setDpi("800")
settle(discoveryStore)
check(recoveredMouse.commandError?.contains("unavailable") == true, "Command failures must be visible")
try FileManager.default.removeItem(at: testDirectory.appendingPathComponent("fail-command"))

func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    for child in view.subviews {
        if let match = descendant(type, in: child) { return match }
    }
    return nil
}
private let unknownHost = NSHostingView(rootView: DetectedDeviceGroup(
    deviceStore: unknownStore
).environmentObject(unknownStore).frame(width: 324))
unknownHost.layoutSubtreeIfNeeded()
check(descendant(NSSlider.self, in: unknownHost) == nil)
check(descendant(NSPopUpButton.self, in: unknownHost) == nil, "Unknown hardware must not offer setting writes")
private let viperHost = NSHostingView(rootView: DetectedDeviceGroup(
    deviceStore: viperStore
).environmentObject(viperStore).frame(width: 324))
viperHost.layoutSubtreeIfNeeded()
check(descendant(NSSlider.self, in: viperHost) == nil)
check(descendant(NSPopUpButton.self, in: viperHost) == nil, "A mouse without RGB must not show lighting")
try writeDevices([keyboardFixture, mouseFixture, viperFixture, unknownFixture])
discoveryStore.refresh()
settle(discoveryStore)
private let panelHost = NSHostingView(rootView: ContentView().environmentObject(discoveryStore))
panelHost.setFrameSize(NSSize(width: 360, height: 800))
panelHost.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
check(panelHost.fittingSize.width == 360)
check(panelHost.fittingSize.height >= 550 && panelHost.fittingSize.height <= 800,
      "Several devices need a visible, bounded scroll area")
var sliderValue = 100.0
var sliderCommits: [Double] = []
private let sliderHost = NSHostingView(rootView: BrightnessSlider(
    value: Binding(get: { sliderValue }, set: { sliderValue = $0 }),
    accent: .systemPink, label: "Keyboard brightness", commit: { sliderCommits.append($0) }
).frame(width: 240, height: 20))
sliderHost.setFrameSize(NSSize(width: 240, height: 20))
sliderHost.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
let slider = descendant(NSSlider.self, in: sliderHost)!
private let sliderCell = slider.cell as! BrightnessSliderCell
sliderCell.isEditing = true
for value in [60.0, 37.2] {
    slider.doubleValue = value
    slider.sendAction(slider.action, to: slider.target)
}
check(sliderValue == 37)
check(sliderCommits.isEmpty, "Dragging should not write to the device")
sliderCell.stopTracking(last: .zero, current: .zero, in: slider, mouseIsUp: true)
check(sliderCommits == [37], "Release should commit once")
slider.doubleValue = 38
slider.sendAction(slider.action, to: slider.target)
check(sliderValue == 38 && sliderCommits == [37, 38], "Keyboard/AX actions must commit")

var selectedEffect = "spectrum"
private let menuHost = NSHostingView(rootView: EffectMenu(
    selection: Binding(get: { selectedEffect }, set: { selectedEffect = $0 }),
    effects: [("spectrum", "Spectrum"), ("static", "Static"), ("none", "Off")], label: "Keyboard lighting"
).frame(width: 112, height: 28))
menuHost.setFrameSize(NSSize(width: 112, height: 28))
menuHost.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
let effectMenu = descendant(NSPopUpButton.self, in: menuHost)!
check(effectMenu.itemTitles == ["Spectrum", "Static", "Off"])
effectMenu.selectItem(at: 1)
effectMenu.sendAction(effectMenu.action, to: effectMenu.target)
check(selectedEffect == "static")
print("Passed: automatic/manual discovery, capability gates, multiple device targets, reconnects, empty/unknown/permission/failure states, static colors and debounce, device actions, slider/keyboard/AX commits, effect menus. No hardware accessed.")
