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
if [ "$1" = status ]; then
cat <<'STATUS'
keyboard=Razer Ornata V3 X keyboard_fw=2.0
mouse=Razer Basilisk V3 mouse_fw=1.2
dpi=1800
poll=500
scroll=tactile
kbd_brightness=255
mouse_brightness=255
STATUS
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
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    store.commandQueue.sync {}
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
func commands() -> [String] {
    (try? String(contentsOf: testDirectory.appendingPathComponent("commands.txt"), encoding: .utf8))?
        .split(separator: "\n").map(String.init).filter { $0 != "status" } ?? []
}

let actionStore = Store()
actionStore.applyEffect("static", device: "keyboard")
settle(actionStore)
check(commands() == ["effect static FF3863 --dev keyboard"])
check(actionStore.kbdEffect == "static")
actionStore.applyStatic(color: .red, device: "mouse")
actionStore.applyStatic(color: .green, device: "mouse")
actionStore.applyStatic(color: Color(red: 0, green: 0, blue: 1), device: "mouse")
check(NSColor(actionStore.mouseColor).usingColorSpace(.deviceRGB)!.blueComponent == 1)
settle(actionStore)
check(commands().suffix(1) == ["effect static 0000FF --dev mouse"])
check(commands().count == 2, "Color dragging must debounce device writes")
actionStore.setBrightness(37, device: "keyboard")
actionStore.setDpi("1800")
actionStore.setPoll("500")
actionStore.setScroll(free: true)
settle(actionStore)
check(commands().suffix(4) == ["brightness 37 --dev keyboard", "dpi 1800", "poll 500", "scroll free"])
check(actionStore.status["dpi"] == "1800")

func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    for child in view.subviews {
        if let match = descendant(type, in: child) { return match }
    }
    return nil
}
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
print("Passed: status metadata, static color arguments and debounce, device action dispatch, slider drag/commit, keyboard/AX commit, effect menu selection. No hardware accessed.")
