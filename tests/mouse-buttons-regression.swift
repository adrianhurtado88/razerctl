// Pure event routing plus fake monitoring: no real mouse input is intercepted.
final class FakeMouseMonitor: MouseButtonMonitoring {
    var onInput: ((MouseButtonInput) -> Bool)?
    var onIssue: ((String) -> Void)?
    var isRunning = false
    var starts = 0
    var failStart = false
    var enableOnStart = true
    func start() throws {
        starts += 1
        if failStart { throw ShortcutFailure("Mouse monitoring unavailable.") }
        isRunning = enableOnStart
    }
    func stop() { isRunning = false }
    @discardableResult
    func input(_ button: Int, _ phase: MouseButtonPhase) -> Bool {
        onInput?(MouseButtonInput(button: button, phase: phase)) ?? false
    }
}

func settleMouseActions() { RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }

let routerCheck = MouseButtonRouter()
let mouseActionID = UUID()
routerCheck.configure(assignments: [3: mouseActionID], capturing: false)
for button in [0, 1, 2, 32] {
    for phase in [MouseButtonPhase.down, .drag, .up] {
        check(!routerCheck.handle(MouseButtonInput(button: button, phase: phase)).suppress,
              "Primary and unassigned clicks must pass through")
    }
}
check(routerCheck.handle(MouseButtonInput(button: 3, phase: .down)).suppress)
check(routerCheck.handle(MouseButtonInput(button: 3, phase: .down)).action == nil,
      "Repeated downs cannot run the action twice")
check(routerCheck.handle(MouseButtonInput(button: 3, phase: .drag)).suppress)
let completedClick = routerCheck.handle(MouseButtonInput(button: 3, phase: .up))
check(completedClick.suppress && completedClick.action == mouseActionID)
check(!routerCheck.handle(MouseButtonInput(button: 3, phase: .up)).suppress)

_ = routerCheck.handle(MouseButtonInput(button: 3, phase: .down))
routerCheck.configure(assignments: [:], capturing: false)
check(routerCheck.needsMonitoring, "Keep monitoring to finish a consumed click during pause")
let pausedRelease = routerCheck.handle(MouseButtonInput(button: 3, phase: .up))
check(pausedRelease.suppress && pausedRelease.action == nil)
check(!routerCheck.needsMonitoring)

check(!routerCheck.handle(MouseButtonInput(button: 4, phase: .down)).suppress)
routerCheck.configure(assignments: [4: mouseActionID], capturing: false)
check(!routerCheck.handle(MouseButtonInput(button: 4, phase: .up)).suppress,
      "Never swallow a release when the original down passed through")
routerCheck.configure(assignments: [:], capturing: true)
check(!routerCheck.handle(MouseButtonInput(button: 0, phase: .down)).suppress)
let capturedClick = routerCheck.handle(MouseButtonInput(button: 7, phase: .down))
check(capturedClick.suppress && capturedClick.captured == 7)
check(!routerCheck.handle(MouseButtonInput(button: 8, phase: .down)).suppress,
      "Capture only one button per recording")
let captureRelease = routerCheck.handle(MouseButtonInput(button: 7, phase: .up))
check(captureRelease.suppress && captureRelease.action == nil)
check(!routerCheck.needsMonitoring)

let mouseSuite = "local.razerctl.mouse.tests.\(UUID().uuidString)"
let mouseDefaults = UserDefaults(suiteName: mouseSuite)!
defer { mouseDefaults.removePersistentDomain(forName: mouseSuite) }
let mouseMonitor = FakeMouseMonitor()
let mouseRunner = FakeShortcutRunner()
let mouseStore = MouseButtonsStore(defaults: mouseDefaults, monitor: mouseMonitor, runner: mouseRunner)
mouseStore.start()
check(!mouseMonitor.isRunning && mouseMonitor.starts == 0 && mouseStore.activeCount == 0,
      "No mappings means no event monitoring")
mouseStore.retry()
check(!mouseStore.accessibilityGranted && mouseStore.monitorError?.contains("quit and reopen") == true,
      "A denied Retry must explain how to recover an already-enabled permission")

var mouseRule = MouseButtonRule()
mouseRule.button = 3
mouseRule.assignment.name = "Copy"
mouseRule.assignment.output = cmdC
try mouseStore.save(mouseRule)
check(!mouseMonitor.isRunning && mouseStore.monitorError != nil,
      "Save without permission, but do not intercept input")
mouseStore.beginCapture()
check(!mouseStore.capturing, "Recording requires Accessibility")
mouseStore.startCheckingAccess()
mouseRunner.accessibilityGranted = true
RunLoop.main.run(until: Date().addingTimeInterval(0.6))
check(mouseMonitor.isRunning && mouseStore.activeCount == 1 && mouseStore.monitorError == nil)
check(mouseStore.accessibilityGranted,
      "Granting access in System Settings must recover without an app activation or Retry")
let cancellationsBeforeAccessCheck = mouseRunner.cancellations
let startsBeforeAccessCheck = mouseMonitor.starts
RunLoop.main.run(until: Date().addingTimeInterval(0.6))
check(mouseRunner.cancellations == cancellationsBeforeAccessCheck && mouseMonitor.starts == startsBeforeAccessCheck,
      "Unchanged permission checks must not cancel actions or restart a healthy listener")
mouseStore.stopCheckingAccess()
mouseRunner.accessibilityGranted = false
RunLoop.main.run(until: Date().addingTimeInterval(0.6))
check(mouseStore.accessibilityGranted, "Closing the editor must stop its permission checks")
mouseStore.startCheckingAccess()
check(!mouseStore.accessibilityGranted && !mouseMonitor.isRunning,
      "Reopening the editor must immediately refresh permission and stop a revoked listener")
mouseStore.stopCheckingAccess()
mouseRunner.accessibilityGranted = true
mouseStore.refreshAccess()
check(mouseMonitor.input(3, .down) && mouseMonitor.input(3, .drag))
settleMouseActions()
check(mouseRunner.performed.isEmpty, "Do not execute before release")
check(mouseMonitor.input(3, .up))
settleMouseActions()
check(mouseRunner.performed == [mouseRule.assignment])
check(!mouseMonitor.input(4, .down) && !mouseMonitor.input(4, .up))

// Pause mid-click cancels the action and drains its release before stopping.
check(mouseMonitor.input(3, .down))
mouseStore.setPaused(true)
check(mouseMonitor.isRunning && mouseStore.activeCount == 0)
check(mouseMonitor.input(3, .up))
settleMouseActions()
check(!mouseMonitor.isRunning && mouseRunner.performed.count == 1)
check(!mouseMonitor.input(3, .down))
mouseStore.setPaused(false)
check(mouseMonitor.isRunning)

// Editing or deleting a pressed button cannot fire its old or new action.
check(mouseMonitor.input(3, .down))
var changedMouseRule = mouseRule
changedMouseRule.assignment.output = KeyChord(keyCode: 9, modifiers: UInt32(cmdKey), keyName: "V")
try mouseStore.save(changedMouseRule)
check(mouseMonitor.input(3, .up))
settleMouseActions()
check(mouseRunner.performed.count == 1)
check(mouseMonitor.input(3, .down) && mouseMonitor.input(3, .up))
settleMouseActions()
check(mouseRunner.performed.last == changedMouseRule.assignment)
check(mouseMonitor.input(3, .down))
mouseStore.remove(mouseRule.id)
check(mouseMonitor.isRunning && mouseMonitor.input(3, .up))
settleMouseActions()
check(!mouseMonitor.isRunning && mouseRunner.performed.count == 2)
try mouseStore.save(mouseRule)

// A queued action must also be cancelled if paused before execution.
check(mouseMonitor.input(3, .down) && mouseMonitor.input(3, .up))
mouseStore.setPaused(true)
settleMouseActions()
check(mouseRunner.performed.count == 2)
mouseStore.setPaused(false)

var keyRecordingStates: [Bool] = []
mouseStore.onKeyRecordingChanged = { keyRecordingStates.append($0) }
mouseStore.setOutputRecording(true)
check(!mouseMonitor.isRunning && mouseStore.activeCount == 0)
check(!mouseMonitor.input(3, .down))
mouseStore.setOutputRecording(false)
check(mouseMonitor.isRunning && keyRecordingStates == [true, false])

mouseStore.beginCapture()
check(mouseStore.capturing && mouseStore.activeCount == 0)
check(!mouseMonitor.input(0, .down), "Left click must work during recording")
check(mouseMonitor.input(8, .down))
settleMouseActions()
check(mouseStore.capturedButton == 8 && !mouseStore.capturing)
check(mouseMonitor.input(8, .up))
settleMouseActions()
check(mouseRunner.performed.count == 2)
mouseStore.beginCapture()
mouseStore.cancelCapture()
check(!mouseStore.capturing && mouseStore.activeCount == 1)

var duplicateMouseRule = mouseRule
duplicateMouseRule.assignment.id = UUID()
rejectsShortcut("Mouse button assignments must be unique") { try mouseStore.save(duplicateMouseRule) }
var primaryMouseRule = mouseRule
primaryMouseRule.button = 0
rejectsShortcut("Left click must not be reassigned") { try mouseStore.save(primaryMouseRule) }
primaryMouseRule.button = 1
rejectsShortcut("Right click must not be reassigned") { try mouseStore.save(primaryMouseRule) }
var invalidMouseAction = mouseRule
invalidMouseAction.assignment.action = .openWebsite
invalidMouseAction.assignment.destination = "file:///tmp/test"
rejectsShortcut("Invalid mouse actions must not be saved") { try mouseStore.save(invalidMouseAction) }

mouseRunner.failure = "Could not run this action."
_ = mouseMonitor.input(3, .down)
_ = mouseMonitor.input(3, .up)
settleMouseActions()
check(mouseStore.actionError == mouseRunner.failure)

mouseRunner.accessibilityGranted = false
mouseStore.refreshAccess()
check(!mouseMonitor.isRunning && mouseStore.activeCount == 0 && mouseStore.monitorError != nil)
mouseRunner.accessibilityGranted = true
mouseMonitor.failStart = true
mouseStore.retry()
check(!mouseStore.monitoring && mouseStore.monitorError != nil)
mouseMonitor.failStart = false
mouseMonitor.enableOnStart = false
mouseStore.retry()
check(!mouseStore.monitoring && mouseStore.monitorError != nil,
      "A tap that stays disabled must not be reported as a successful Retry")
mouseMonitor.enableOnStart = true
mouseStore.retry()
check(mouseStore.monitoring && mouseStore.monitorError == nil)
let startsBeforeRetry = mouseMonitor.starts
mouseStore.retry()
check(mouseMonitor.starts == startsBeforeRetry + 1 && mouseStore.monitoring,
      "Explicit Retry must rebuild the listener instead of reusing a stale tap")
mouseMonitor.onIssue?("Accessibility access was removed.")
check(!mouseMonitor.isRunning && !mouseStore.monitoring && mouseStore.monitorError != nil)
mouseStore.retry()
check(mouseStore.monitoring && mouseStore.monitorError == nil)

var disabledMouseRule = mouseRule
disabledMouseRule.assignment.enabled = false
try mouseStore.save(disabledMouseRule)
check(!mouseMonitor.isRunning && mouseStore.activeCount == 0)
let restoredMouseStore = MouseButtonsStore(defaults: mouseDefaults,
                                          monitor: FakeMouseMonitor(), runner: FakeShortcutRunner())
check(restoredMouseStore.rules == mouseStore.rules, "Mouse assignments must survive relaunch")
mouseStore.setPaused(true)
let pausedMouseStore = MouseButtonsStore(defaults: mouseDefaults,
                                        monitor: FakeMouseMonitor(), runner: FakeShortcutRunner())
check(pausedMouseStore.paused, "Pause state must survive relaunch")
mouseStore.stop()
check(!mouseMonitor.isRunning)
mouseStore.start()
mouseStore.setOutputRecording(true)
mouseStore.stop()
let statesAfterStop = keyRecordingStates.count
mouseStore.setOutputRecording(false)
check(keyRecordingStates.count == statesAfterStop && keyRecordingStates.last == false,
      "Shutdown must balance recording suspension without an extra resume")

let damagedMouseSuite = mouseSuite + ".damaged"
let damagedMouseDefaults = UserDefaults(suiteName: damagedMouseSuite)!
defer { damagedMouseDefaults.removePersistentDomain(forName: damagedMouseSuite) }
let damagedMouseData = Data("not valid JSON".utf8)
damagedMouseDefaults.set(damagedMouseData, forKey: "mouseButtonRules.v1")
let damagedMouseStore = MouseButtonsStore(defaults: damagedMouseDefaults,
                                         monitor: FakeMouseMonitor(), runner: FakeShortcutRunner())
check(damagedMouseStore.storageError != nil)
rejectsShortcut("Unreadable mouse settings must be preserved") { try damagedMouseStore.save(mouseRule) }
check(damagedMouseDefaults.data(forKey: "mouseButtonRules.v1") == damagedMouseData)

// The first assignment can fail during recording before there are any saved rules.
let captureFailureSuite = mouseSuite + ".capture"
let captureFailureDefaults = UserDefaults(suiteName: captureFailureSuite)!
defer { captureFailureDefaults.removePersistentDomain(forName: captureFailureSuite) }
let captureFailureMonitor = FakeMouseMonitor()
captureFailureMonitor.failStart = true
let captureFailureRunner = FakeShortcutRunner()
captureFailureRunner.accessibilityGranted = true
let captureFailureStore = MouseButtonsStore(defaults: captureFailureDefaults,
                                          monitor: captureFailureMonitor, runner: captureFailureRunner)
captureFailureStore.start()
captureFailureStore.beginCapture()
check(!captureFailureStore.capturing && captureFailureStore.monitorError != nil,
      "A failed first recording must keep its error visible so the user can retry")
captureFailureMonitor.failStart = false
captureFailureStore.retry()
captureFailureStore.beginCapture()
check(captureFailureStore.capturing && captureFailureStore.monitoring)
captureFailureStore.cancelCapture()
captureFailureStore.startCheckingAccess()
captureFailureStore.stop()
captureFailureRunner.accessibilityGranted = false
RunLoop.main.run(until: Date().addingTimeInterval(0.6))
check(captureFailureStore.accessibilityGranted,
      "Stopping the store must invalidate the editor's permission checks")

print("Passed: mouse click pairing, routing, capture, edit/delete during click, queued-action cancellation, pause/disable, permission/retry handling, validation and persistence. No mouse events intercepted or actions posted.")
