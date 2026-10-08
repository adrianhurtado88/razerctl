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

// Exercise status changes without enabling secure input or reading keys.
let commandsBeforePrivacy = commands()
var reportedSecureInput = false
var privacyChecks = 0
let privacyStore = Store(secureInputStatus: {
    check(Thread.isMainThread, "Secure-input queries must stay on the main thread")
    privacyChecks += 1
    return reportedSecureInput
})
check(privacyStore.secureKeyboardEntryEnabled == nil)
privacyStore.startKeyboardPrivacyMonitoring()
check(privacyStore.secureKeyboardEntryEnabled == false)
reportedSecureInput = true
RunLoop.main.run(until: Date().addingTimeInterval(1.4))
check(privacyStore.secureKeyboardEntryEnabled == true, "An open panel should detect secure input becoming active")
reportedSecureInput = false
RunLoop.main.run(until: Date().addingTimeInterval(1.4))
check(privacyStore.secureKeyboardEntryEnabled == false, "An open panel should detect secure input becoming inactive")
privacyStore.stopKeyboardPrivacyMonitoring()
check(privacyStore.secureKeyboardEntryEnabled == nil, "A closed panel must not retain a stale status")
let checksAtClose = privacyChecks
RunLoop.main.run(until: Date().addingTimeInterval(1.4))
check(privacyChecks == checksAtClose, "Closing the panel should stop status queries")
reportedSecureInput = true
privacyStore.startKeyboardPrivacyMonitoring()
check(privacyStore.secureKeyboardEntryEnabled == true, "Reopening should immediately read fresh status")
privacyStore.stopKeyboardPrivacyMonitoring()
check(commands() == commandsBeforePrivacy, "Privacy checks must not send device commands")

// All mode tests use a fake API: none enables secure input on this Mac.
final class SecureInputFixture {
    var uptime: TimeInterval = 100
    var otherAppActive = false
    var requests = 0
    var enableCalls = 0
    var disableCalls = 0
    var enableResult: OSStatus = noErr
    var disableResult: OSStatus = noErr
    func status() -> Bool { otherAppActive || requests > 0 }
    func enable() -> OSStatus {
        check(Thread.isMainThread)
        enableCalls += 1
        if enableResult == noErr { requests += 1 }
        return enableResult
    }
    func disable() -> OSStatus {
        check(Thread.isMainThread)
        disableCalls += 1
        check(requests == 1, "Release must balance our single request, not another app's")
        if disableResult == noErr { requests -= 1 }
        return disableResult
    }
    func makeStore() -> Store {
        Store(secureInputStatus: status, enableSecureInput: enable,
              disableSecureInput: disable, privacyUptime: { self.uptime })
    }
}
let temporaryInput = SecureInputFixture()
temporaryInput.otherAppActive = true
let temporaryStore = temporaryInput.makeStore()
temporaryStore.startKeyboardPrivacyMonitoring()
temporaryStore.setTemporaryKeyboardPrivacyEnabled(false)
check(temporaryInput.disableCalls == 0, "An active status from another app must not grant ownership")
temporaryStore.setTemporaryKeyboardPrivacyEnabled(true)
temporaryStore.setTemporaryKeyboardPrivacyEnabled(true)
check(temporaryInput.enableCalls == 1 && temporaryInput.requests == 1,
      "Repeated On actions must not acquire extra requests")
check(temporaryStore.temporaryKeyboardPrivacySecondsRemaining == 600)
temporaryInput.uptime += 61
temporaryStore.startKeyboardPrivacyMonitoring()
check(temporaryStore.temporaryKeyboardPrivacySecondsRemaining == 539,
      "Opening the panel must not extend the session")
temporaryStore.stopKeyboardPrivacyMonitoring()
check(temporaryStore.temporaryKeyboardPrivacyEnabled, "Closing the panel must leave the temporary mode running")
temporaryInput.uptime += 539
RunLoop.main.run(until: Date().addingTimeInterval(1.4))
check(!temporaryStore.temporaryKeyboardPrivacyEnabled && temporaryInput.requests == 0,
      "Automatic shutoff must work while the panel is closed")
check(temporaryInput.disableCalls == 1)
temporaryStore.startKeyboardPrivacyMonitoring()
check(temporaryStore.secureKeyboardEntryEnabled == true,
      "Releasing our request must leave another app's secure-input status intact")
temporaryInput.otherAppActive = false
temporaryStore.startKeyboardPrivacyMonitoring()
check(temporaryStore.secureKeyboardEntryEnabled == false)
temporaryStore.setTemporaryKeyboardPrivacyEnabled(true)
temporaryStore.setTemporaryKeyboardPrivacyEnabled(false)
temporaryStore.setTemporaryKeyboardPrivacyEnabled(false)
check(temporaryInput.enableCalls == 2 && temporaryInput.disableCalls == 2,
      "Manual Off and repeated cleanup must balance exactly one request")
temporaryStore.stopKeyboardPrivacyMonitoring()

let failingInput = SecureInputFixture()
failingInput.enableResult = -1
let failingPrivacyStore = failingInput.makeStore()
failingPrivacyStore.startKeyboardPrivacyMonitoring()
failingPrivacyStore.setTemporaryKeyboardPrivacyEnabled(true)
check(!failingPrivacyStore.temporaryKeyboardPrivacyEnabled && failingPrivacyStore.keyboardPrivacyError != nil,
      "A failed enable must not show the switch as on")
failingPrivacyStore.setTemporaryKeyboardPrivacyEnabled(false)
check(failingInput.disableCalls == 0, "A failed enable must not create a request to release")
failingInput.enableResult = noErr
failingPrivacyStore.setTemporaryKeyboardPrivacyEnabled(true)
failingInput.disableResult = -1
failingPrivacyStore.setTemporaryKeyboardPrivacyEnabled(false)
check(failingPrivacyStore.temporaryKeyboardPrivacyEnabled && failingPrivacyStore.keyboardPrivacyError != nil,
      "A failed disable must keep the switch on and expose a recovery action")
failingInput.uptime += 600
failingPrivacyStore.startKeyboardPrivacyMonitoring()
check(failingPrivacyStore.temporaryKeyboardPrivacyEnabled && failingPrivacyStore.temporaryKeyboardPrivacySecondsRemaining == 0)
failingInput.disableResult = noErr
RunLoop.main.run(until: Date().addingTimeInterval(1.4))
check(!failingPrivacyStore.temporaryKeyboardPrivacyEnabled && failingInput.requests == 0,
      "An expired session should retry a failed release")
check(failingPrivacyStore.keyboardPrivacyError == nil)
failingPrivacyStore.stopKeyboardPrivacyMonitoring()

let cleanupInput = SecureInputFixture()
var cleanupStore: Store? = cleanupInput.makeStore()
cleanupStore?.setTemporaryKeyboardPrivacyEnabled(true)
cleanupStore = nil
check(cleanupInput.requests == 0 && cleanupInput.disableCalls == 1,
      "Destroying the owner must release its outstanding request")
check(commands() == commandsBeforePrivacy, "Temporary privacy must not send device commands")

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
print("Passed: status metadata, static color arguments and debounce, device action dispatch, slider drag/commit, keyboard/AX commit, effect menu selection, secure-input transitions, temporary privacy ownership/timeout/failure/cleanup. No hardware accessed; secure-input enable/disable APIs were faked.")
