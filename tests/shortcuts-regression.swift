// These checks use fake shortcut registration and action execution. They never
// reserve global keys, post keystrokes, open apps, or request permissions.
final class FakeShortcutRegistrar: ShortcutRegistering {
    var onPress: ((UUID) -> Void)?
    var registered: [UUID: KeyboardShortcutRule] = [:]
    var rejectedKeyCode: UInt32?
    func register(_ rule: KeyboardShortcutRule) throws {
        if rule.trigger?.keyCode == rejectedKeyCode {
            throw ShortcutFailure("Already used by another app.")
        }
        registered[rule.id] = rule
    }
    func unregister(_ id: UUID) { registered.removeValue(forKey: id) }
    func unregisterAll() { registered.removeAll() }
}

final class FakeShortcutRunner: ShortcutActionRunning {
    var accessibilityGranted = false
    var performed: [KeyboardShortcutRule] = []
    var cancellations = 0
    var failure: String?
    func run(_ rule: KeyboardShortcutRule, completion: @escaping (String?) -> Void) {
        performed.append(rule)
        completion(failure)
    }
    func cancel() { cancellations += 1 }
}

func rejectsShortcut(_ message: String, _ operation: () throws -> Void) {
    do {
        try operation()
        check(false, message)
    } catch {}
}

let shortcutsSuite = "local.razerctl.shortcuts.tests.\(UUID().uuidString)"
let shortcutsDefaults = UserDefaults(suiteName: shortcutsSuite)!
defer { shortcutsDefaults.removePersistentDomain(forName: shortcutsSuite) }
let registrar = FakeShortcutRegistrar()
let runner = FakeShortcutRunner()
let shortcuts = KeyboardShortcutsStore(defaults: shortcutsDefaults, registrar: registrar, runner: runner)
check(shortcuts.rules.isEmpty && registrar.registered.isEmpty)
check(shortcuts.activeCount == 0)

let cmdC = KeyChord(keyCode: 8, modifiers: UInt32(cmdKey), keyName: "C")
let f6 = KeyChord(keyCode: 97, modifiers: 0, keyName: "F6")
let f7 = KeyChord(keyCode: 98, modifiers: 0, keyName: "F7")
let f8 = KeyChord(keyCode: 100, modifiers: 0, keyName: "F8")
let plainA = KeyChord(keyCode: 0, modifiers: 0, keyName: "A")
let shiftA = KeyChord(keyCode: 0, modifiers: UInt32(shiftKey), keyName: "A")
check(f6.validTrigger && cmdC.validTrigger)
check(!plainA.validTrigger && !shiftA.validTrigger, "Do not capture normal typing")
check(!KeyChord(keyCode: 55, modifiers: UInt32(cmdKey), keyName: "Command").validKey)
check(cmdC.matches(KeyChord(keyCode: 8, modifiers: UInt32(cmdKey), keyName: "Different label")))
check(KeyChord(keyCode: 0, modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey), keyName: "A").display == "⌃⌥⇧⌘A")
check(cmdC.eventFlags == .maskCommand)
let invalidChord = try JSONDecoder().decode(KeyChord.self,
    from: Data(#"{"keyCode":8,"modifiers":4294967295,"keyName":"C"}"#.utf8))
check(!invalidChord.validKey, "Validate modifiers loaded from storage")

check(KeyboardShortcutRule.websiteURL("https://example.com/path") != nil)
check(KeyboardShortcutRule.websiteURL(" http://example.com ") != nil)
for address in ["example.com", "file:///tmp/test", "javascript:alert(1)", "https://"] {
    check(KeyboardShortcutRule.websiteURL(address) == nil, "Only complete HTTP(S) websites")
}

var rule = KeyboardShortcutRule()
rule.name = "Copy"
rule.trigger = f6
rule.output = cmdC
try shortcuts.save(rule)
check(registrar.registered.isEmpty, "Saving before startup must not register global keys")
shortcuts.start()
check(registrar.registered[rule.id] == rule && shortcuts.activeCount == 1)
registrar.onPress?(rule.id)
check(runner.performed == [rule])
runner.failure = "Accessibility is required."
registrar.onPress?(rule.id)
check(shortcuts.actionError == runner.failure, "Action failures must remain visible")

var duplicate = rule
duplicate.id = UUID()
rejectsShortcut("Duplicate triggers must fail") { try shortcuts.save(duplicate) }
var selfTrigger = rule
selfTrigger.output = f6
rejectsShortcut("Self-triggering output must fail") { try shortcuts.save(selfTrigger) }
var typingTrigger = rule
typingTrigger.trigger = plainA
rejectsShortcut("Normal typing must not become a global shortcut") { try shortcuts.save(typingTrigger) }

var second = KeyboardShortcutRule()
second.trigger = f7
second.output = f6
rejectsShortcut("Output cannot trigger an existing rule") { try shortcuts.save(second) }
second.output = KeyChord(keyCode: 9, modifiers: UInt32(cmdKey), keyName: "V")
try shortcuts.save(second)
var reverseLoop = rule
reverseLoop.trigger = second.output
rejectsShortcut("New trigger cannot be another rule's output") { try shortcuts.save(reverseLoop) }
check(shortcuts.rules.count == 2)

// Rejected edits keep the old saved rule and restore its registration.
registrar.rejectedKeyCode = f8.keyCode
var edited = rule
edited.trigger = f8
rejectsShortcut("Registration conflicts must fail") { try shortcuts.save(edited) }
check(shortcuts.rules.first == rule && registrar.registered[rule.id] == rule)

shortcuts.setPaused(true)
check(registrar.registered.isEmpty && shortcuts.activeCount == 0)
let beforePause = runner.performed.count
registrar.onPress?(rule.id)
check(runner.performed.count == beforePause, "Paused rules cannot run")
try shortcuts.save(edited)
check(shortcuts.rules.first == edited && registrar.registered.isEmpty)
shortcuts.setPaused(false)
check(shortcuts.errors[rule.id] != nil && shortcuts.activeCount == 1)
registrar.onPress?(rule.id)
check(runner.performed.count == beforePause, "Failed registrations cannot run")
registrar.rejectedKeyCode = nil
try shortcuts.save(rule)
check(shortcuts.errors[rule.id] == nil && shortcuts.activeCount == 2)

// Recording suspends every assignment, including nested recorders.
shortcuts.setRecording(true)
shortcuts.setRecording(true)
check(registrar.registered.isEmpty && shortcuts.activeCount == 0)
registrar.onPress?(rule.id)
check(runner.performed.count == beforePause)
shortcuts.setRecording(false)
check(registrar.registered.isEmpty)
shortcuts.setRecording(false)
check(registrar.registered.count == 2)

var disabled = rule
disabled.enabled = false
try shortcuts.save(disabled)
check(registrar.registered[rule.id] == nil && shortcuts.activeCount == 1)
registrar.onPress?(rule.id)
check(runner.performed.count == beforePause, "Disabled assignments cannot run")
let reloaded = KeyboardShortcutsStore(defaults: shortcutsDefaults,
                                      registrar: FakeShortcutRegistrar(), runner: FakeShortcutRunner())
check(reloaded.rules == shortcuts.rules, "Assignments must survive relaunch")
shortcuts.remove(second.id)
check(shortcuts.rules.count == 1 && registrar.registered.isEmpty)
shortcuts.stop()
check(shortcuts.activeCount == 0)

let damagedSuite = shortcutsSuite + ".damaged"
let damagedDefaults = UserDefaults(suiteName: damagedSuite)!
defer { damagedDefaults.removePersistentDomain(forName: damagedSuite) }
let damaged = Data("invalid saved data".utf8)
damagedDefaults.set(damaged, forKey: "keyboardShortcutRules.v1")
let damagedStore = KeyboardShortcutsStore(defaults: damagedDefaults,
                                          registrar: FakeShortcutRegistrar(), runner: FakeShortcutRunner())
check(damagedStore.storageError != nil)
rejectsShortcut("Unreadable saved data must not be overwritten") { try damagedStore.save(rule) }
check(damagedDefaults.data(forKey: "keyboardShortcutRules.v1") == damaged)

// Exercise the recorder's real event-to-chord path without posting events.
private let recordButton = ShortcutRecorderButton()
var recordingStates: [Bool] = []
var recorded: KeyChord?
recordButton.title = "Record keys…"
recordButton.recordingChanged = { recordingStates.append($0) }
recordButton.changed = { recorded = $0 }
recordButton.performClick(nil)
check(recordButton.recording)
let recordedEvent = NSEvent.keyEvent(with: .keyDown, location: .zero,
    modifierFlags: [.command, .option], timestamp: 0, windowNumber: 0,
    context: nil, characters: "s", charactersIgnoringModifiers: "s",
    isARepeat: false, keyCode: 1)!
check(recordButton.performKeyEquivalent(with: recordedEvent))
check(recorded?.keyCode == 1 && recorded?.modifiers == UInt32(cmdKey | optionKey))
check(recordingStates == [true, false] && !recordButton.recording)
recordButton.performClick(nil)
let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
    timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}",
    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
recordButton.keyDown(with: escape)
check(recorded?.keyCode == 1 && !recordButton.recording, "Escape must cancel without replacing the shortcut")
recordButton.performClick(nil)
_ = recordButton.resignFirstResponder()
check(!recordButton.recording && recordingStates.suffix(2) == [true, false],
      "Losing focus must end recording and restore assignments")

print("Passed: shortcut capture, validation, conflicts and rollback, loop prevention, pause/recording/disable, dispatch, persistence, and unreadable-data preservation. No global shortcuts registered or keystrokes posted.")
