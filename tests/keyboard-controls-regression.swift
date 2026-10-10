// All mode operations and event output are fakes. No hardware writes or input posting.
let macroEvents = [MacroKeyEvent(chord: plainA, down: true, delay: 0),
                   MacroKeyEvent(chord: plainA, down: false, delay: 0.02),
                   MacroKeyEvent(chord: cmdC, down: true, delay: 0.03),
                   MacroKeyEvent(chord: cmdC, down: false, delay: 0.01)]
try KeyboardMacro.validate(macroEvents)
for invalid in [[], [macroEvents[0]], [macroEvents[1]],
                [macroEvents[0], macroEvents[0], macroEvents[1]],
                [MacroKeyEvent(chord: plainA, down: true, delay: .infinity), macroEvents[1]],
                [MacroKeyEvent(chord: plainA, down: true, delay: -1), macroEvents[1]],
                [MacroKeyEvent(chord: plainA, down: true, delay: 60), MacroKeyEvent(chord: plainA, down: false, delay: 1)],
                Array(repeating: macroEvents, count: 129).flatMap { $0 }] {
    rejectsShortcut("Malformed, unbalanced or unbounded macros must fail") { try KeyboardMacro.validate(invalid) }
}
var macroCapture = MacroCapture()
check(macroCapture.append(cmdC, down: true, time: 10))
check(macroCapture.append(cmdC, down: true, time: 10.1))
check(macroCapture.append(plainA, down: false, time: 11))
let balancedCapture = macroCapture.finish()
check(balancedCapture.count == 2 && balancedCapture[0].delay == 0 && !balancedCapture[1].down)
try KeyboardMacro.validate(balancedCapture)
var macroRule = KeyboardShortcutRule()
macroRule.trigger = f7; macroRule.action = .playMacro; macroRule.macro = macroEvents
try KeyboardShortcutRule.validate(macroRule, among: [])
macroRule.macro = [MacroKeyEvent(chord: f7, down: true, delay: 0), MacroKeyEvent(chord: f7, down: false, delay: 0)]
rejectsShortcut("Macros must not trigger themselves") { try KeyboardShortcutRule.validate(macroRule, among: []) }
macroRule.macro = macroEvents
var inverseMacro = rule; inverseMacro.trigger = cmdC
rejectsShortcut("An existing macro's output must not become another trigger") {
    try KeyboardShortcutRule.validate(inverseMacro, among: [macroRule])
}
var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as! [String: Any]
legacyJSON.removeValue(forKey: "macro")
let legacyRule = try JSONDecoder().decode(KeyboardShortcutRule.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
check(legacyRule.macro == nil && legacyRule.output == rule.output, "Old assignments must decode without losing their output")
try shortcuts.save(macroRule)
let macroReloaded = KeyboardShortcutsStore(defaults: shortcutsDefaults, registrar: FakeShortcutRegistrar(), runner: FakeShortcutRunner())
check(macroReloaded.rules.contains(macroRule), "Macro events and timing must persist")

var emitted: [MacroKeyEvent] = []
var playbackReady: String?
let player = MacroPlayer(ready: { playbackReady }, emit: { emitted.append($0); return true })
let slowMacro = [MacroKeyEvent(chord: cmdC, down: true, delay: 0), MacroKeyEvent(chord: cmdC, down: false, delay: 0.15)]
var playbackResult: String?
player.play(slowMacro) { playbackResult = $0 }
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
check(emitted.count == 1 && emitted[0].down)
player.cancel()
check(emitted.count == 2 && !emitted[1].down, "Cancellation must release a posted key")
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
check(emitted.count == 2, "Cancelled scheduled events must not run")
emitted = []
player.play(slowMacro) { playbackResult = $0 }
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
playbackReady = "Secure input or focus changed"
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
check(playbackResult == playbackReady && emitted.count == 2 && !emitted[1].down,
      "Focus/access changes must stop playback and release held keys")
emitted = []; playbackReady = "Accessibility required"
player.play(macroEvents) { playbackResult = $0 }
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
check(emitted.isEmpty && playbackResult == playbackReady, "Denied playback must post nothing")

final class FakeKeyboardModes {
    var calls: [[String]] = []
    var callbacks: [(Result<[String: String], ShortcutFailure>) -> Void] = []
    func execute(_ args: [String], completion: @escaping (Result<[String: String], ShortcutFailure>) -> Void) {
        calls.append(args); callbacks.append(completion)
    }
    func reply(_ result: Result<[String: String], ShortcutFailure>) { callbacks.removeFirst()(result) }
}
let modesBackend = FakeKeyboardModes()
let modes = KeyboardControlsStore(id: "physical-keyboard-A", execute: modesBackend.execute, readLocks: { _ in [1:false,2:true,3:false] })
modes.apply(settings: ["gaming_mode":"0", "macro_recording":"0"], gamingAvailable: true, macroAvailable: true)
check(!modes.expanded && modesBackend.calls.isEmpty, "Discovery and default collapsed state must not write modes")
modes.setGaming(true)
check(modes.busy && modes.gaming == false, "A requested mode must not appear confirmed before read-back")
check(modesBackend.calls.last == ["keyboard-mode","gaming","on","expected-off"])
modesBackend.reply(.success(["gaming_mode":"1"]))
check(modes.gaming == true && !modes.busy)
modes.setGaming(false); modesBackend.reply(.failure(ShortcutFailure("disconnected")))
check(modes.gaming == nil && modes.error == "disconnected", "Failed writes must not fabricate a state")
var captureStarted: String?
modes.beginRecording { captureStarted = $0 }
var cleaned = 0
modes.shutdown { cleaned += 1 }
check(cleaned == 0 && modesBackend.calls.last == ["keyboard-mode","macro","on","expected-off"])
modesBackend.reply(.success(["macro_recording":"1"]))
check(cleaned == 0 && modesBackend.calls.last == ["keyboard-mode","macro","off","expected-on"],
      "A cancelled pending acquisition must release only after it succeeded")
modes.shutdown { cleaned += 1 }
check(cleaned == 0, "Repeated shutdown must wait for the one in-flight release")
modesBackend.reply(.success(["macro_recording":"0"]))
check(cleaned == 2 && modes.macro == false)
let callsBeforeForeign = modesBackend.calls.count
modes.beginRecording { captureStarted = $0 }
modesBackend.reply(.failure(ShortcutFailure("another recorder owns the lamp")))
check(modesBackend.calls.count == callsBeforeForeign + 1 && captureStarted != nil,
      "A failed acquisition must not clear a foreign recorder's indicator")
modes.monitor(true)
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
check(modes.locks == [1:false,2:true,3:false] && modesBackend.calls.count == callsBeforeForeign + 1,
      "Lock monitoring is read-only and distinguishes Caps, Num and Scroll")
modes.monitor(false)
check(modes.locks.isEmpty)
check(KeyboardLockReader.registryID("02a2:4465765372767349443a34323935313335363735") == 4295135675)
for id in ["02a2:00", "02a2:0", "0294:4465765372767349443a31", "02a2:zz", "keyboard-A"] {
    check(KeyboardLockReader.registryID(id) == nil, "Invalid identity must not select another keyboard")
}
print("Passed: bounded macro capture, storage compatibility, recursion rejection, playback cancellation/key release, exact indicator ownership, pending cleanup, confirmed mode state and read-only lock monitoring.")
var recorderSecureInput = false
let macroButton = MacroRecorderButton(secureInput: { recorderSecureInput }, canCapture: { true })
var macroRecordingStates: [Bool] = []
var buttonMacro: [MacroKeyEvent]?
macroButton.recordingChanged = { macroRecordingStates.append($0) }
macroButton.changed = { buttonMacro = $0 }
macroButton.indicators = modes
macroButton.performClick(nil)
check(macroButton.recording && macroRecordingStates == [true])
modesBackend.reply(.success(["macro_recording":"1"]))
macroButton.keyDown(with: recordedEvent)
let macroUp = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
    windowNumber: 0, context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)!
macroButton.keyUp(with: macroUp)
macroButton.performClick(nil)
check(!macroButton.recording && buttonMacro?.count == 2 && macroRecordingStates == [true,false])
check(buttonMacro?.first?.chord.modifiers == UInt32(cmdKey | optionKey)
      && buttonMacro?.last?.chord.modifiers == UInt32(cmdKey | optionKey), "Release must retain the recorded chord's modifiers")
modesBackend.reply(.success(["macro_recording":"0"]))
macroButton.performClick(nil); modesBackend.reply(.success(["macro_recording":"1"]))
macroButton.keyDown(with: escape)
check(!macroButton.recording && buttonMacro?.count == 2, "Escape discards the new take")
modesBackend.reply(.success(["macro_recording":"0"]))
macroButton.performClick(nil); modesBackend.reply(.success(["macro_recording":"1"]))
_ = macroButton.resignFirstResponder()
check(!macroButton.recording, "Focus loss must end capture")
modesBackend.reply(.success(["macro_recording":"0"]))
let beforeSecureRecord = modesBackend.calls.count
recorderSecureInput = true
macroButton.performClick(nil)
check(!macroButton.recording && modesBackend.calls.count == beforeSecureRecord, "Secure input must prevent recording before any indicator change")
print("Passed: native recorder key-down/up capture, explicit stop, Escape/focus cancellation, modifier preservation, and secure-input rejection. No global input captured.")

modes.beginRecording { _ in }
modesBackend.reply(.success(["macro_recording":"1"]))
var failedCleanupCompleted = false
modes.shutdown { failedCleanupCompleted = true }
modesBackend.reply(.failure(ShortcutFailure("device unavailable")))
check(failedCleanupCompleted && modes.cleanupNeeded && modes.macro == nil,
      "A cleanup failure must allow quit, retain a retry, and avoid claiming Off")
modes.endRecording()
modesBackend.reply(.success(["macro_recording":"0"]))
check(!modes.cleanupNeeded && modes.macro == false, "Cleanup retry must release the retained acquisition")
