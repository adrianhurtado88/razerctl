import AppKit
import SwiftUI

struct MouseButtonRule: Codable, Identifiable, Equatable {
    var button: Int?
    var assignment = KeyboardShortcutRule()
    var id: UUID { assignment.id }

    static func name(for button: Int) -> String {
        switch button {
        case 2: return "Middle click"
        case 3: return "Side button 1"
        case 4: return "Side button 2"
        default: return "Mouse button \(button + 1)"
        }
    }

    static func validate(_ rule: Self, among rules: [Self]) throws {
        guard let button = rule.button, (2...31).contains(button) else {
            throw ShortcutFailure("Choose or record a middle, side or extra mouse button.")
        }
        if rule.assignment.enabled && rules.contains(where: {
            $0.id != rule.id && $0.assignment.enabled && $0.button == button
        }) {
            throw ShortcutFailure("That mouse button already has an assignment.")
        }
        try KeyboardShortcutRule.validateAction(rule.assignment)
    }
}

enum MouseButtonPhase { case down, up, drag }
struct MouseButtonInput {
    let button: Int
    let phase: MouseButtonPhase
}
struct MouseButtonDecision {
    var suppress = false
    var action: UUID?
    var captured: Int?
}

// This pure router keeps down/up pairs consistent when assignments change
// mid-click. A pause cancels the action but still consumes the matching release.
final class MouseButtonRouter {
    private struct Press {
        let action: UUID?
        let generation: UInt64
    }
    private var assignments: [Int: UUID] = [:]
    private var capturing = false
    private var presses: [Int: Press] = [:]
    private var generation: UInt64 = 0

    var needsMonitoring: Bool { !assignments.isEmpty || capturing || !presses.isEmpty }

    func configure(assignments: [Int: UUID], capturing: Bool) {
        generation &+= 1
        self.assignments = assignments
        self.capturing = capturing
    }

    func reset() { presses = [:]; configure(assignments: [:], capturing: false) }

    func handle(_ input: MouseButtonInput) -> MouseButtonDecision {
        guard (2...31).contains(input.button) else { return MouseButtonDecision() }
        switch input.phase {
        case .down:
            if presses[input.button] != nil { return MouseButtonDecision(suppress: true) }
            if capturing {
                capturing = false
                presses[input.button] = Press(action: nil, generation: generation)
                return MouseButtonDecision(suppress: true, captured: input.button)
            }
            guard let id = assignments[input.button] else { return MouseButtonDecision() }
            presses[input.button] = Press(action: id, generation: generation)
            return MouseButtonDecision(suppress: true)
        case .up:
            guard let press = presses.removeValue(forKey: input.button) else { return MouseButtonDecision() }
            let action = press.generation == generation ? press.action : nil
            return MouseButtonDecision(suppress: true, action: action)
        case .drag:
            return MouseButtonDecision(suppress: presses[input.button] != nil)
        }
    }
}

protocol MouseButtonMonitoring: AnyObject {
    var onInput: ((MouseButtonInput) -> Bool)? { get set }
    var onIssue: ((String) -> Void)? { get set }
    var isRunning: Bool { get }
    func start() throws
    func stop()
}

final class MacMouseButtonMonitor: MouseButtonMonitoring {
    var onInput: ((MouseButtonInput) -> Bool)?
    var onIssue: ((String) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() throws {
        guard AXIsProcessTrusted() else {
            throw ShortcutFailure("Allow Accessibility to customise mouse buttons.")
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return
        }
        let mask = [CGEventType.otherMouseDown, .otherMouseUp, .otherMouseDragged]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<MacMouseButtonMonitor>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if AXIsProcessTrusted(), let tap = monitor.tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                } else {
                    DispatchQueue.main.async { [weak monitor] in
                        monitor?.onIssue?("Mouse assignments stopped; check Accessibility access and choose Retry.")
                    }
                }
                return Unmanaged.passUnretained(event)
            }
            let phase: MouseButtonPhase
            switch type {
            case .otherMouseDown: phase = .down
            case .otherMouseUp: phase = .up
            case .otherMouseDragged: phase = .drag
            default: return Unmanaged.passUnretained(event)
            }
            let input = MouseButtonInput(button: Int(event.getIntegerValueField(.mouseEventButtonNumber)), phase: phase)
            return monitor.onInput?(input) == true ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw ShortcutFailure("macOS could not enable mouse assignments; check Accessibility access and choose Retry.")
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw ShortcutFailure("macOS could not start mouse button handling.")
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
    }

    deinit { stop() }
}

final class MouseButtonsStore: ObservableObject {
    @Published private(set) var rules: [MouseButtonRule] = []
    @Published private(set) var paused: Bool
    @Published private(set) var capturing = false
    @Published private(set) var capturedButton: Int?
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var monitoring = false
    @Published private(set) var monitorError: String?
    @Published private(set) var storageError: String?
    @Published private(set) var ruleErrors: [UUID: String] = [:]
    @Published var actionError: String?
    var onKeyRecordingChanged: ((Bool) -> Void)?
    private let defaults: UserDefaults
    private let monitor: MouseButtonMonitoring
    private let runner: ShortcutActionRunning
    private let router = MouseButtonRouter()
    private var started = false
    private var outputRecordingDepth = 0
    private var captureTimeout: DispatchWorkItem?
    private var generation = UUID()
    private let rulesKey = "mouseButtonRules.v1"

    init(defaults: UserDefaults = .standard,
         monitor: MouseButtonMonitoring = MacMouseButtonMonitor(),
         runner: ShortcutActionRunning = MacShortcutActionRunner()) {
        self.defaults = defaults
        self.monitor = monitor
        self.runner = runner
        paused = defaults.bool(forKey: "mouseButtonsPaused")
        accessibilityGranted = runner.accessibilityGranted
        if let data = defaults.data(forKey: rulesKey) {
            do {
                let decoded = try JSONDecoder().decode([MouseButtonRule].self, from: data)
                guard Set(decoded.map(\.id)).count == decoded.count else {
                    throw ShortcutFailure("Duplicate mouse assignment identifiers.")
                }
                rules = decoded
            } catch { storageError = "Saved mouse assignments could not be read; the original data has been kept." }
        }
        monitor.onInput = { [weak self] input in self?.handle(input) ?? false }
        monitor.onIssue = { [weak self] message in
            guard let self else { return }
            self.monitorError = message
            self.monitoring = false
            self.monitor.stop()
            self.runner.cancel()
            self.router.reset()
            self.generation = UUID()
            self.capturing = false
            self.captureTimeout?.cancel()
        }
    }

    var activeCount: Int {
        guard started, !paused, outputRecordingDepth == 0, !capturing,
              monitoring, monitorError == nil else { return 0 }
        return rules.filter { $0.assignment.enabled && ruleErrors[$0.id] == nil }.count
    }

    func start() { started = true; configure() }

    func stop() {
        started = false
        capturing = false
        captureTimeout?.cancel()
        runner.cancel()
        generation = UUID()
        router.reset()
        monitor.stop()
        monitoring = false
        while outputRecordingDepth > 0 {
            outputRecordingDepth -= 1
            onKeyRecordingChanged?(false)
        }
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        defaults.set(paused, forKey: "mouseButtonsPaused")
        cancelCapture()
    }

    func setOutputRecording(_ recording: Bool) {
        guard recording || outputRecordingDepth > 0 else { return }
        if recording { capturing = false; captureTimeout?.cancel() }
        outputRecordingDepth += recording ? 1 : -1
        onKeyRecordingChanged?(recording)
        configure()
    }

    func refreshAccess() {
        let granted = runner.accessibilityGranted
        guard granted != accessibilityGranted else { return }
        accessibilityGranted = granted
        if !granted { router.reset() }
        configure()
    }

    func retry() { accessibilityGranted = runner.accessibilityGranted; configure() }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        refreshAccess()
    }

    func beginCapture() {
        guard started, accessibilityGranted else {
            monitorError = "Allow Accessibility before recording a mouse button."
            return
        }
        capturedButton = nil
        actionError = nil
        capturing = true
        configure()
        guard monitoring else { capturing = false; configure(); return }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.capturing else { return }
            self.cancelCapture()
            self.actionError = "No mouse button detected; that control may be handled inside the mouse."
        }
        captureTimeout?.cancel()
        captureTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    func cancelCapture() {
        captureTimeout?.cancel()
        captureTimeout = nil
        capturing = false
        configure()
    }

    private func configure() {
        generation = UUID()
        runner.cancel()
        ruleErrors = [:]
        var assignments: [Int: UUID] = [:]
        if started && !paused && outputRecordingDepth == 0 && !capturing && accessibilityGranted {
            for rule in rules where rule.assignment.enabled {
                do {
                    try MouseButtonRule.validate(rule, among: rules)
                    if let button = rule.button { assignments[button] = rule.id }
                } catch { ruleErrors[rule.id] = error.localizedDescription }
            }
        }
        router.configure(assignments: assignments, capturing: started && capturing && accessibilityGranted)
        updateMonitor()
    }

    private func updateMonitor() {
        guard started, router.needsMonitoring, accessibilityGranted else {
            monitor.stop()
            monitoring = false
            if !accessibilityGranted && rules.contains(where: { $0.assignment.enabled }) {
                monitorError = "Allow Accessibility to activate mouse assignments."
            } else { monitorError = nil }
            return
        }
        do {
            if !monitor.isRunning { try monitor.start() }
            monitoring = monitor.isRunning
            monitorError = nil
        } catch {
            monitoring = false
            monitorError = error.localizedDescription
        }
    }

    private func handle(_ input: MouseButtonInput) -> Bool {
        let decision = router.handle(input)
        var needsUpdate = decision.captured != nil || decision.action != nil
        if case .up = input.phase, decision.suppress { needsUpdate = true }
        guard needsUpdate else { return decision.suppress }
        let token = generation
        // The event callback only routes the event. Actions run after it returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let button = decision.captured, self.capturing, self.generation == token {
                self.capturedButton = button
                self.cancelCapture()
            }
            if let id = decision.action, self.generation == token { self.perform(id) }
            self.updateMonitor()
        }
        return decision.suppress
    }

    private func perform(_ id: UUID) {
        guard started, !paused, !capturing, outputRecordingDepth == 0,
              let rule = rules.first(where: { $0.id == id && $0.assignment.enabled }) else { return }
        actionError = nil
        runner.run(rule.assignment) { [weak self] error in self?.actionError = error }
    }

    func save(_ rule: MouseButtonRule) throws {
        guard storageError == nil else { throw ShortcutFailure(storageError!) }
        try MouseButtonRule.validate(rule, among: rules)
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule }
        else { rules.append(rule) }
        persist()
        configure()
    }

    func remove(_ id: UUID) {
        guard storageError == nil else { return }
        rules.removeAll { $0.id == id }
        persist()
        configure()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: rulesKey) }
    }
}

// MARK: - Editor

struct MouseButtonsButton: View {
    @ObservedObject var buttons: MouseButtonsStore
    let openEditor: () -> Void

    var body: some View {
        Button(action: openEditor) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Customise buttons…", systemImage: "computermouse")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }
                if buttons.monitorError != nil || buttons.actionError != nil || !buttons.ruleErrors.isEmpty {
                    Label("A mouse assignment needs attention", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 4)
    }
}

final class MouseButtonsWindow: NSWindowController, NSWindowDelegate {
    private let buttons: MouseButtonsStore
    init(store: MouseButtonsStore) {
        buttons = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Mouse Buttons"
        window.minSize = NSSize(width: 680, height: 540)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MouseButtonsView(store: store))
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
        buttons.cancelCapture()
    }
    func windowDidResignKey(_ notification: Notification) {
        window?.makeFirstResponder(nil)
        buttons.cancelCapture()
    }
}

private struct MouseButtonsView: View {
    @ObservedObject var store: MouseButtonsStore
    @State private var selection: UUID?
    @State private var draft = MouseButtonRule()
    @State private var editing = false
    @State private var error: String?

    private var availableButtons: [Int] {
        Array(Set([2, 3, 4] + store.rules.compactMap(\.button) + [draft.button].compactMap { $0 })).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Put your mouse buttons to work").font(.title2.weight(.semibold))
                    Text("Works across Mac mice while RazerCtl is open.").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Pause assignments", isOn: Binding(get: { store.paused }, set: store.setPaused))
                    .toggleStyle(.switch).fixedSize()
            }.padding(20)
            Divider()
            if !store.accessibilityGranted || store.monitorError != nil {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "hand.raised")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.monitorError ?? "Allow Accessibility to record and customise mouse buttons.")
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Allow Accessibility…") { store.requestAccessibility() }
                            Button("Retry") { store.retry() }
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(14)
                Divider()
            }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Assignments").font(.headline)
                        Spacer()
                        Button(action: newAssignment) { Image(systemName: "plus") }
                            .accessibilityLabel("Add mouse assignment").help("Add assignment")
                            .disabled(store.storageError != nil)
                    }.padding(14)
                    if store.rules.isEmpty {
                        Text("Choose a button and give it a shortcut, app or website.")
                            .foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 14)
                    }
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(store.rules) { rule in
                                Button {
                                    store.cancelCapture()
                                    selection = rule.id; draft = rule; editing = true; error = nil
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(rule.assignment.name.isEmpty
                                                 ? rule.button.map(MouseButtonRule.name) ?? "Mouse button"
                                                 : rule.assignment.name)
                                                .fontWeight(.medium).lineLimit(1)
                                            Spacer(minLength: 4)
                                            if !rule.assignment.enabled { Text("Off").foregroundStyle(.secondary) }
                                        }
                                        Text("\(rule.button.map(MouseButtonRule.name) ?? "Unassigned") → \(rule.assignment.summary)")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        if let problem = store.ruleErrors[rule.id] {
                                            Text(problem).font(.caption).foregroundStyle(.orange)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                    .background(selection == rule.id ? Color.white.opacity(0.09) : .clear,
                                                in: RoundedRectangle(cornerRadius: 7))
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 8)
                    }
                }.frame(width: 220)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if editing { editor }
                        else {
                            Text("A button for your next action").font(.headline)
                            Text("For example, use a side button to copy, paste or open your favourite app.")
                                .foregroundStyle(.secondary)
                            Button("Add assignment", action: newAssignment).disabled(store.storageError != nil)
                        }
                        if let problem = store.storageError { Text(problem).foregroundStyle(.orange) }
                        if let problem = store.actionError {
                            Text(problem).foregroundStyle(.orange)
                            Button("Dismiss") { store.actionError = nil }
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text(store.paused ? "Mouse assignments paused" : "\(store.activeCount) active assignments")
                Text("Left and right clicks stay unchanged. DPI, scroll-mode and wheel-tilt controls that do not report button clicks cannot be assigned here.")
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.caption).foregroundStyle(.secondary).padding(14)
        }
        .frame(minWidth: 680, minHeight: 500)
        .background(Color(red: 0.141, green: 0.149, blue: 0.165))
        .environment(\.colorScheme, .dark)
        .onReceive(store.$capturedButton) { button in
            if editing, let button { draft.button = button; error = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshAccess()
        }
        .onDisappear { store.cancelCapture() }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(selection == nil ? "New assignment" : "Edit assignment").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.subheadline.weight(.medium))
                TextField("e.g. Copy", text: $draft.assignment.name)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Mouse assignment name")
            }
            VStack(alignment: .leading, spacing: 8) {
                Picker("When I click", selection: Binding(
                    get: { draft.button ?? -1 }, set: { draft.button = $0 == -1 ? nil : $0 }
                )) {
                    Text("Choose a button…").tag(-1)
                    ForEach(availableButtons, id: \.self) { button in
                        Text(MouseButtonRule.name(for: button)).tag(button)
                    }
                }
                if store.capturing {
                    Text("Click a middle, side or extra button within 10 seconds.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Cancel recording") { store.cancelCapture() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Record a mouse button…") { store.beginCapture() }
                        .disabled(!store.accessibilityGranted)
                }
            }
            ShortcutActionFields(rule: $draft.assignment, accessibilityGranted: store.accessibilityGranted,
                                 requestAccess: store.requestAccessibility,
                                 recordingChanged: store.setOutputRecording)
            Toggle("Enabled", isOn: $draft.assignment.enabled)
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            HStack {
                if selection != nil {
                    Button("Delete", role: .destructive) {
                        if let selection { store.remove(selection) }
                        store.cancelCapture()
                        editing = false; selection = nil; error = nil
                    }
                }
                Spacer()
                Button("Cancel") {
                    store.cancelCapture(); editing = false; selection = nil; error = nil
                }
                Button("Save", action: save).buttonStyle(.borderedProminent)
                    .disabled(store.storageError != nil || store.capturing)
            }
        }
    }

    private func newAssignment() {
        store.cancelCapture()
        selection = nil; draft = MouseButtonRule(); editing = true; error = nil
    }

    private func save() {
        do {
            try store.save(draft)
            selection = draft.id
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
