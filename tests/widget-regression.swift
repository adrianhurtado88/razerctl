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
let updatingStore = Store()
updatingStore.updating = true
updatingStore.updateError = "existing transaction"
updatingStore.performUpdate()
check(updatingStore.updating && updatingStore.updateError == "existing transaction",
      "A repeated update request must not start or disturb an in-flight transaction")
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

// A later effect selection must replace pending static-color writes.
let beforeRapidEffectSwitch = commands().count
actionStore.kbdEffect = "static"
actionStore.applyEffect("static", device: "keyboard")
actionStore.kbdEffect = "spectrum"
actionStore.applyEffect("spectrum", device: "keyboard")
settle(discoveryStore)
check(Array(commands().dropFirst(beforeRapidEffectSwitch)) == ["effect spectrum --dev keyboard --id kbd-1"],
      "Static then Spectrum within the debounce must send only Spectrum")
check(actionStore.kbdEffect == "spectrum", "A stale color callback must not restore Static")

let beforeColorToOff = commands().count
actionStore.kbdEffect = "static"
actionStore.applyStatic(color: .red, device: "keyboard")
detectedMouseStore.applyStatic(color: .red, device: "mouse")
detectedMouseStore.applyStatic(color: .green, device: "mouse")
detectedMouseStore.applyStatic(color: Color(red: 0, green: 0, blue: 1), device: "mouse")
actionStore.kbdEffect = "none"
actionStore.applyEffect("none", device: "keyboard")
settle(discoveryStore)
check(Array(commands().dropFirst(beforeColorToOff)) == [
    "effect none --dev keyboard --id kbd-1", "effect static 0000FF --dev mouse --id mouse-1"
], "Turning off one device must cancel its color while preserving another device's final drag color")
check(actionStore.kbdEffect == "none" && detectedMouseStore.mouseEffect == "static",
      "Independent device selections must retain their latest effects")

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
    var activity: NSObjectProtocol?
    var activityBegins = 0
    var activityEnds = 0
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
        check(activity != nil, "The shutoff must stay protected from App Nap until secure input is released")
        if disableResult == noErr { requests -= 1 }
        return disableResult
    }
    func beginActivity(_ options: ProcessInfo.ActivityOptions) -> NSObjectProtocol {
        check(Thread.isMainThread)
        check(requests == 1 && activity == nil, "Only an owned secure-input request needs an activity")
        check(options == .userInitiatedAllowingIdleSystemSleep,
              "Temporary privacy must prevent App Nap while still allowing system sleep")
        activityBegins += 1
        let token = NSObject()
        activity = token
        return token
    }
    func endActivity(_ token: NSObjectProtocol) {
        check(Thread.isMainThread)
        check(requests == 0, "Keep App Nap protection during a failed release so the timer can retry")
        check(activity === token, "End exactly the activity owned by this session")
        activityEnds += 1
        activity = nil
    }
    func makeStore(targetID: String? = nil) -> Store {
        Store(targetID: targetID, secureInputStatus: status, enableSecureInput: enable,
              disableSecureInput: disable, privacyUptime: { self.uptime },
              beginPrivacyActivity: beginActivity, endPrivacyActivity: endActivity)
    }
}
let temporaryInput = SecureInputFixture()
temporaryInput.otherAppActive = true
let temporaryStore = temporaryInput.makeStore()
temporaryStore.startKeyboardPrivacyMonitoring()
temporaryStore.setTemporaryKeyboardPrivacyEnabled(false)
check(temporaryInput.disableCalls == 0, "An active status from another app must not grant ownership")
check(temporaryInput.activityBegins == 0, "Monitoring another app's status must not prevent App Nap")
temporaryStore.setTemporaryKeyboardPrivacyEnabled(true)
temporaryStore.setTemporaryKeyboardPrivacyEnabled(true)
check(temporaryInput.enableCalls == 1 && temporaryInput.requests == 1,
      "Repeated On actions must not acquire extra requests")
check(temporaryInput.activityBegins == 1 && temporaryInput.activityEnds == 0,
      "Repeated On actions must hold exactly one App Nap activity")
check(temporaryStore.temporaryKeyboardPrivacySecondsRemaining == 600)
temporaryInput.uptime += 61
temporaryStore.startKeyboardPrivacyMonitoring()
check(temporaryStore.temporaryKeyboardPrivacySecondsRemaining == 539,
      "Opening the panel must not extend the session")
temporaryStore.stopKeyboardPrivacyMonitoring()
check(temporaryStore.temporaryKeyboardPrivacyEnabled, "Closing the panel must leave the temporary mode running")
check(temporaryInput.activity != nil && temporaryInput.activityEnds == 0,
      "Closing the panel must retain App Nap protection for the shutoff")
temporaryInput.uptime += 539
RunLoop.main.run(until: Date().addingTimeInterval(1.4))
check(!temporaryStore.temporaryKeyboardPrivacyEnabled && temporaryInput.requests == 0,
      "Automatic shutoff must work while the panel is closed")
check(temporaryInput.disableCalls == 1)
check(temporaryInput.activity == nil && temporaryInput.activityEnds == 1,
      "Automatic shutoff must release its App Nap activity")
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
check(temporaryInput.activityBegins == 2 && temporaryInput.activityEnds == 2,
      "Manual Off and repeated cleanup must balance the activity across sessions")
temporaryStore.stopKeyboardPrivacyMonitoring()

let failingInput = SecureInputFixture()
failingInput.enableResult = -1
let failingPrivacyStore = failingInput.makeStore()
failingPrivacyStore.startKeyboardPrivacyMonitoring()
failingPrivacyStore.setTemporaryKeyboardPrivacyEnabled(true)
check(!failingPrivacyStore.temporaryKeyboardPrivacyEnabled && failingPrivacyStore.keyboardPrivacyError != nil,
      "A failed enable must not show the switch as on")
check(failingInput.activityBegins == 0, "A failed enable must not create an App Nap activity")
failingPrivacyStore.setTemporaryKeyboardPrivacyEnabled(false)
check(failingInput.disableCalls == 0, "A failed enable must not create a request to release")
failingInput.enableResult = noErr
failingPrivacyStore.setTemporaryKeyboardPrivacyEnabled(true)
failingInput.disableResult = -1
failingPrivacyStore.setTemporaryKeyboardPrivacyEnabled(false)
check(failingPrivacyStore.temporaryKeyboardPrivacyEnabled && failingPrivacyStore.keyboardPrivacyError != nil,
      "A failed disable must keep the switch on and expose a recovery action")
check(failingInput.activity != nil && failingInput.activityEnds == 0,
      "A failed disable must retain App Nap protection for release retries")
failingInput.uptime += 600
failingPrivacyStore.startKeyboardPrivacyMonitoring()
check(failingPrivacyStore.temporaryKeyboardPrivacyEnabled && failingPrivacyStore.temporaryKeyboardPrivacySecondsRemaining == 0)
failingInput.disableResult = noErr
RunLoop.main.run(until: Date().addingTimeInterval(1.4))
check(!failingPrivacyStore.temporaryKeyboardPrivacyEnabled && failingInput.requests == 0,
      "An expired session should retry a failed release")
check(failingInput.activity == nil && failingInput.activityEnds == 1,
      "A successful release retry must end the activity")
check(failingPrivacyStore.keyboardPrivacyError == nil)
failingPrivacyStore.stopKeyboardPrivacyMonitoring()

let cleanupInput = SecureInputFixture()
var cleanupStore: Store? = cleanupInput.makeStore()
cleanupStore?.setTemporaryKeyboardPrivacyEnabled(true)
cleanupStore = nil
check(cleanupInput.requests == 0 && cleanupInput.disableCalls == 1,
      "Destroying the owner must release its outstanding request")
check(cleanupInput.activity == nil && cleanupInput.activityEnds == 1,
      "Destroying the owner must release its App Nap activity")
check(commands() == commandsBeforePrivacy, "Temporary privacy must not send device commands")

// Device sections and app lifecycle callbacks must control the same request.
let sharedPrivacyInput = SecureInputFixture()
let sharedPrivacyStore = sharedPrivacyInput.makeStore()
let secondKeyboardFixture = fixtureDevice("kbd-2", kind: "keyboard", name: "Razer Huntsman V2",
    effects: ["spectrum", "static", "none"],
    settings: ["keyboard": "Razer Huntsman V2", "kbd_brightness": "255"])
try writeDevices([keyboardFixture, secondKeyboardFixture])
sharedPrivacyStore.refresh()
settle(sharedPrivacyStore)
var firstPrivacyKeyboard: Store? = sharedPrivacyStore.deviceStores[0]
var secondPrivacyKeyboard: Store? = sharedPrivacyStore.deviceStores[1]
check(firstPrivacyKeyboard!.keyboardPrivacyStore === sharedPrivacyStore
      && secondPrivacyKeyboard!.keyboardPrivacyStore === sharedPrivacyStore,
      "Both keyboard sections must observe the app's single privacy owner")
sharedPrivacyStore.startKeyboardPrivacyMonitoring()
check(firstPrivacyKeyboard!.keyboardPrivacyStore.secureKeyboardEntryEnabled == false)
sharedPrivacyInput.otherAppActive = true
sharedPrivacyStore.startKeyboardPrivacyMonitoring()
check(secondPrivacyKeyboard!.keyboardPrivacyStore.secureKeyboardEntryEnabled == true,
      "Root monitoring must update the status observed by device sections")
sharedPrivacyInput.otherAppActive = false
firstPrivacyKeyboard!.startKeyboardPrivacyMonitoring()
check(sharedPrivacyStore.secureKeyboardEntryEnabled == false,
      "A child monitoring request must refresh the root owner")
firstPrivacyKeyboard!.setTemporaryKeyboardPrivacyEnabled(true)
secondPrivacyKeyboard!.setTemporaryKeyboardPrivacyEnabled(true)
sharedPrivacyStore.setTemporaryKeyboardPrivacyEnabled(true)
check(sharedPrivacyInput.enableCalls == 1 && sharedPrivacyInput.requests == 1
      && sharedPrivacyInput.activityBegins == 1,
      "Enabling from different keyboard sections must acquire one request and activity")
sharedPrivacyInput.uptime += 61
secondPrivacyKeyboard!.startKeyboardPrivacyMonitoring()
check(firstPrivacyKeyboard!.keyboardPrivacyStore.temporaryKeyboardPrivacyEnabled
      && secondPrivacyKeyboard!.keyboardPrivacyStore.temporaryKeyboardPrivacySecondsRemaining == 539,
      "Device sections must share the existing root session and deadline")
secondPrivacyKeyboard!.stopKeyboardPrivacyMonitoring()
check(sharedPrivacyStore.temporaryKeyboardPrivacyEnabled,
      "Closing a device section must not release the app's privacy request")
sharedPrivacyStore.refresh()
settle(sharedPrivacyStore)
check(sharedPrivacyStore.deviceStores[0] === firstPrivacyKeyboard
      && sharedPrivacyStore.deviceStores[1] === secondPrivacyKeyboard,
      "A rescan must preserve the existing device sections")
check(sharedPrivacyInput.requests == 1 && sharedPrivacyInput.activityBegins == 1
      && sharedPrivacyInput.activityEnds == 0,
      "Rescanning must not change privacy ownership")
weak var removedFirstPrivacyKeyboard = firstPrivacyKeyboard
weak var removedSecondPrivacyKeyboard = secondPrivacyKeyboard
try writeDevices([])
sharedPrivacyStore.refresh()
settle(sharedPrivacyStore)
check(sharedPrivacyStore.deviceStores.isEmpty)
firstPrivacyKeyboard = nil
secondPrivacyKeyboard = nil
check(removedFirstPrivacyKeyboard == nil && removedSecondPrivacyKeyboard == nil,
      "Removed device stores should be released independently of the privacy owner")
check(sharedPrivacyStore.temporaryKeyboardPrivacyEnabled && sharedPrivacyInput.requests == 1
      && sharedPrivacyInput.disableCalls == 0 && sharedPrivacyInput.activityEnds == 0,
      "Removing the last keyboard must leave the root session and its shutoff active")
try writeDevices([keyboardFixture, secondKeyboardFixture])
sharedPrivacyStore.refresh()
settle(sharedPrivacyStore)
let replacementPrivacyKeyboard = sharedPrivacyStore.deviceStores[0]
check(replacementPrivacyKeyboard.keyboardPrivacyStore === sharedPrivacyStore
      && replacementPrivacyKeyboard.keyboardPrivacyStore.temporaryKeyboardPrivacySecondsRemaining == 539,
      "Recreated device sections must reconnect to the existing privacy owner")
replacementPrivacyKeyboard.setTemporaryKeyboardPrivacyEnabled(true)
check(sharedPrivacyInput.enableCalls == 1 && sharedPrivacyInput.activityBegins == 1,
      "Reconnecting a keyboard must not acquire another privacy request")
sharedPrivacyStore.setTemporaryKeyboardPrivacyEnabled(false)
check(!replacementPrivacyKeyboard.keyboardPrivacyStore.temporaryKeyboardPrivacyEnabled
      && sharedPrivacyInput.requests == 0 && sharedPrivacyInput.disableCalls == 1
      && sharedPrivacyInput.activityEnds == 1,
      "Root cleanup must release the request enabled through a device section")
sharedPrivacyStore.setTemporaryKeyboardPrivacyEnabled(true)
replacementPrivacyKeyboard.setTemporaryKeyboardPrivacyEnabled(false)
check(!sharedPrivacyStore.temporaryKeyboardPrivacyEnabled && sharedPrivacyInput.requests == 0
      && sharedPrivacyInput.disableCalls == 2 && sharedPrivacyInput.activityEnds == 2,
      "A device section's Off action must release the root owner's request")
sharedPrivacyStore.stopKeyboardPrivacyMonitoring()
let orphanPrivacyInput = SecureInputFixture()
let orphanPrivacyKeyboard = orphanPrivacyInput.makeStore(targetID: "orphan-kbd")
orphanPrivacyKeyboard.startKeyboardPrivacyMonitoring()
orphanPrivacyKeyboard.setTemporaryKeyboardPrivacyEnabled(true)
check(!orphanPrivacyKeyboard.temporaryKeyboardPrivacyEnabled
      && orphanPrivacyKeyboard.secureKeyboardEntryEnabled == nil
      && orphanPrivacyInput.enableCalls == 0 && orphanPrivacyInput.activityBegins == 0,
      "A device store without an app owner must not acquire secure input")
check(commands() == commandsBeforePrivacy, "Shared privacy ownership must not send device commands")
try writeDevices([mouseFixture])

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
print("Passed: automatic/manual discovery, capability gates, multiple device targets, reconnects, empty/unknown/permission/failure states, static colors and debounce, device actions, slider/keyboard/AX commits, effect menus, secure-input transitions, temporary privacy ownership/timeout/failure/cleanup, shared privacy across device rescans/removal/reconnection. No hardware accessed; secure-input enable/disable APIs were faked.")
