import AppKit
import Carbon
import SwiftUI

// Shortcuts belong to this Mac, not the keyboard firmware. Carbon registers
// only the chosen combinations; the app does not record general keyboard input.
struct KeyChord: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyName: String

    static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    static let functionKeys: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    init(keyCode: UInt32, modifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
        self.keyName = keyName
    }

    init(event: NSEvent) {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let code = UInt32(event.keyCode)
        let special: [UInt32: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
            76: "Enter", 117: "Forward Delete", 123: "←", 124: "→", 125: "↓",
            126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        ]
        self.init(keyCode: code, modifiers: modifiers,
                  keyName: Self.functionKeys[code] ?? special[code]
                    ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(code)")
    }

    func matches(_ other: KeyChord) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    var display: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + keyName
    }

    var validKey: Bool {
        keyCode <= 126 && ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode)
            && modifiers & ~Self.modifierMask == 0
    }

    var validTrigger: Bool {
        validKey && (Self.functionKeys[keyCode] != nil
            || modifiers & UInt32(cmdKey | optionKey | controlKey) != 0)
    }

    var eventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        return flags
    }
}

enum ShortcutAction: String, Codable, CaseIterable, Identifiable {
    case sendShortcut, openApplication, openWebsite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sendShortcut: return "Send a shortcut"
        case .openApplication: return "Open an app"
        case .openWebsite: return "Open a website"
        }
    }
}

struct KeyboardShortcutRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var trigger: KeyChord?
    var action = ShortcutAction.sendShortcut
    var output: KeyChord?
    var destination = ""
    var enabled = true

    var summary: String {
        switch action {
        case .sendShortcut: return output?.display ?? "Choose a shortcut"
        case .openApplication:
            return URL(fileURLWithPath: destination).deletingPathExtension().lastPathComponent
        case .openWebsite: return destination
        }
    }

    static func websiteURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static func validate(_ rule: Self, among rules: [Self]) throws {
        guard let trigger = rule.trigger, trigger.validTrigger else {
            throw ShortcutFailure("Choose an F key, or include Command, Control or Option.")
        }
        let others = rules.filter { $0.id != rule.id && $0.enabled }
        if rule.enabled && others.contains(where: { $0.trigger?.matches(trigger) == true }) {
            throw ShortcutFailure("That key combination already has an assignment.")
        }
        try validateAction(rule)
        if rule.enabled, rule.action == .sendShortcut, let output = rule.output,
           ([rule] + others).contains(where: { $0.trigger?.matches(output) == true }) {
            throw ShortcutFailure("The output cannot trigger another assignment, including itself.")
        }
        if rule.enabled && others.contains(where: {
            $0.action == .sendShortcut && $0.output?.matches(trigger) == true
        }) {
            throw ShortcutFailure("Another assignment sends that combination; choose a different trigger.")
        }
    }

    static func validateAction(_ rule: Self) throws {
        switch rule.action {
        case .sendShortcut:
            guard let output = rule.output, output.validKey else {
                throw ShortcutFailure("Record the shortcut you want to send.")
            }
        case .openApplication:
            guard rule.destination.hasPrefix("/"), rule.destination.hasSuffix(".app"),
                  FileManager.default.fileExists(atPath: rule.destination) else {
                throw ShortcutFailure("Choose an installed app.")
            }
        case .openWebsite:
            guard websiteURL(rule.destination) != nil else {
                throw ShortcutFailure("Enter a complete website address starting with https:// or http://.")
            }
        }
    }
}

struct ShortcutFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

protocol ShortcutRegistering: AnyObject {
    var onPress: ((UUID) -> Void)? { get set }
    func register(_ rule: KeyboardShortcutRule) throws
    func unregister(_ id: UUID)
    func unregisterAll()
}

final class MacShortcutRegistrar: ShortcutRegistering {
    var onPress: ((UUID) -> Void)?
    private var handler: EventHandlerRef?
    private var registrations: [UUID: (UInt32, EventHotKeyRef)] = [:]
    private var pressed: Set<UInt32> = []
    private var nextID: UInt32 = 0
    private static let signature: OSType = 0x525A4354 // RZCT

    private func installHandler() throws {
        guard handler == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == MacShortcutRegistrar.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let registrar = Unmanaged<MacShortcutRegistrar>.fromOpaque(context).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                registrar.pressed.remove(id.id)
                return noErr
            }
            guard registrar.pressed.insert(id.id).inserted else { return noErr }
            if let ruleID = registrar.registrations.first(where: { $0.value.0 == id.id })?.key {
                registrar.onPress?(ruleID)
            }
            return noErr
        }, 2, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else {
            throw ShortcutFailure("macOS could not start keyboard shortcuts (\(result)).")
        }
    }

    func register(_ rule: KeyboardShortcutRule) throws {
        guard let chord = rule.trigger else { throw ShortcutFailure("Choose a trigger first.") }
        var systemKeys: Unmanaged<CFArray>?
        if CopySymbolicHotKeys(&systemKeys) == noErr,
           let keys = systemKeys?.takeRetainedValue() as? [[String: Any]],
           keys.contains(where: {
               ($0[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                   && ($0[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == chord.keyCode
                   && (($0[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value ?? 0)
                       & KeyChord.modifierMask == chord.modifiers
           }) {
            throw ShortcutFailure("macOS already uses that shortcut; choose a different combination.")
        }
        try installHandler()
        nextID += 1
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(chord.keyCode, chord.modifiers,
                                        EventHotKeyID(signature: Self.signature, id: nextID),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive),
                                        &reference)
        guard result == noErr, let reference else {
            throw ShortcutFailure("That shortcut is unavailable or used by another app (\(result)).")
        }
        registrations[rule.id] = (nextID, reference)
    }

    func unregister(_ id: UUID) {
        if let registration = registrations.removeValue(forKey: id) {
            UnregisterEventHotKey(registration.1)
            pressed.remove(registration.0)
        }
    }

    func unregisterAll() {
        for id in Array(registrations.keys) { unregister(id) }
    }

    deinit {
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
    }
}

protocol ShortcutActionRunning: AnyObject {
    var accessibilityGranted: Bool { get }
    func run(_ rule: KeyboardShortcutRule, completion: @escaping (String?) -> Void)
    func cancel()
}

final class MacShortcutActionRunner: ShortcutActionRunning {
    private var pending: DispatchWorkItem?
    private var generation = UUID()
    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    func cancel() {
        pending?.cancel()
        pending = nil
        generation = UUID()
    }

    func run(_ rule: KeyboardShortcutRule, completion: @escaping (String?) -> Void) {
        cancel()
        switch rule.action {
        case .openApplication:
            let requestID = generation
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: rule.destination),
                                                configuration: .init()) { [weak self] _, error in
                DispatchQueue.main.async {
                    guard self?.generation == requestID else { return }
                    completion(error.map { "Could not open the app: \($0.localizedDescription)" })
                }
            }
        case .openWebsite:
            guard let url = KeyboardShortcutRule.websiteURL(rule.destination),
                  NSWorkspace.shared.open(url) else {
                completion("Could not open that website.")
                return
            }
            completion(nil)
        case .sendShortcut:
            guard accessibilityGranted else {
                completion("Allow RazerCtl in System Settings → Privacy & Security → Accessibility to send shortcuts.")
                return
            }
            guard let output = rule.output else { completion("No output shortcut saved."); return }
            let target = NSWorkspace.shared.frontmostApplication?.processIdentifier
            sendAfterRelease(output, target: target, deadline: Date().addingTimeInterval(3),
                             completion: completion)
        }
    }

    // Wait for physical modifiers to be released, so a held trigger modifier
    // cannot leak into the outgoing shortcut. Cancel if focus changes meanwhile.
    private func sendAfterRelease(_ chord: KeyChord, target: pid_t?, deadline: Date,
                                  completion: @escaping (String?) -> Void) {
        guard AXIsProcessTrusted() else { completion("Accessibility access is required."); return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target else {
            completion("Shortcut cancelled because the active app changed.")
            return
        }
        let held = CGEventSource.flagsState(.hidSystemState)
            .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if !held.isEmpty {
            guard Date() < deadline else { completion("Release the modifier keys and try again."); return }
            let work = DispatchWorkItem { [weak self] in
                self?.sendAfterRelease(chord, target: target, deadline: deadline, completion: completion)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
            return
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(chord.keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(chord.keyCode), keyDown: false) else {
            completion("macOS could not create the shortcut.")
            return
        }
        down.flags = chord.eventFlags
        up.flags = chord.eventFlags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        pending = nil
        completion(nil)
    }
}

final class KeyboardShortcutsStore: ObservableObject {
    @Published private(set) var rules: [KeyboardShortcutRule] = []
    @Published private(set) var paused: Bool
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var storageError: String?
    @Published var actionError: String?
    @Published var accessibilityGranted = false
    private let defaults: UserDefaults
    private let registrar: ShortcutRegistering
    private let runner: ShortcutActionRunning
    private var started = false
    private var recordingDepth = 0
    private let rulesKey = "keyboardShortcutRules.v1"

    init(defaults: UserDefaults = .standard,
         registrar: ShortcutRegistering = MacShortcutRegistrar(),
         runner: ShortcutActionRunning = MacShortcutActionRunner()) {
        self.defaults = defaults
        self.registrar = registrar
        self.runner = runner
        paused = defaults.bool(forKey: "keyboardShortcutsPaused")
        if let data = defaults.data(forKey: rulesKey) {
            do {
                let decoded = try JSONDecoder().decode([KeyboardShortcutRule].self, from: data)
                guard Set(decoded.map(\.id)).count == decoded.count else {
                    throw ShortcutFailure("Duplicate shortcut identifiers.")
                }
                rules = decoded
            } catch {
                storageError = "Saved shortcuts could not be read; the original data has been kept."
            }
        }
        registrar.onPress = { [weak self] id in self?.perform(id) }
        refreshAccess()
    }

    var activeCount: Int {
        guard started, !paused, recordingDepth == 0 else { return 0 }
        return rules.filter { $0.enabled && errors[$0.id] == nil }.count
    }

    func start() {
        started = true
        synchronize()
    }

    func stop() {
        started = false
        registrar.unregisterAll()
        runner.cancel()
    }

    func setPaused(_ value: Bool) {
        paused = value
        defaults.set(value, forKey: "keyboardShortcutsPaused")
        synchronize()
    }

    func setRecording(_ recording: Bool) {
        recordingDepth = max(0, recordingDepth + (recording ? 1 : -1))
        synchronize()
    }

    private func synchronize() {
        registrar.unregisterAll()
        runner.cancel()
        errors = [:]
        guard started, !paused, recordingDepth == 0 else { return }
        for rule in rules where rule.enabled {
            do {
                try KeyboardShortcutRule.validate(rule, among: rules)
                try registrar.register(rule)
            } catch { errors[rule.id] = error.localizedDescription }
        }
    }

    func save(_ rule: KeyboardShortcutRule) throws {
        guard storageError == nil else { throw ShortcutFailure(storageError!) }
        try KeyboardShortcutRule.validate(rule, among: rules)
        let old = rules.first { $0.id == rule.id }
        if started && !paused && recordingDepth == 0 {
            registrar.unregister(rule.id)
            do {
                if rule.enabled { try registrar.register(rule) }
            } catch {
                if let old, old.enabled {
                    do { try registrar.register(old) }
                    catch { errors[old.id] = error.localizedDescription }
                }
                throw error
            }
        }
        runner.cancel()
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule }
        else { rules.append(rule) }
        errors.removeValue(forKey: rule.id)
        persist()
    }

    func remove(_ id: UUID) {
        guard storageError == nil else { return }
        registrar.unregister(id)
        runner.cancel()
        rules.removeAll { $0.id == id }
        errors.removeValue(forKey: id)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: rulesKey) }
    }

    func refreshAccess() { accessibilityGranted = runner.accessibilityGranted }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        refreshAccess()
    }

    private func perform(_ id: UUID) {
        guard started, !paused, recordingDepth == 0, errors[id] == nil,
              let rule = rules.first(where: { $0.id == id && $0.enabled }) else { return }
        actionError = nil
        runner.run(rule) { [weak self] error in
            self?.actionError = error
            self?.refreshAccess()
        }
    }
}

// MARK: - Native shortcut recorder

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var chord: KeyChord?
    let label: String
    let recordingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.bezelStyle = .rounded
        button.recordingChanged = recordingChanged
        button.changed = { chord = $0 }
        button.setAccessibilityLabel(label)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.changed = { chord = $0 }
        button.recordingChanged = recordingChanged
        if !button.recording { button.title = chord?.display ?? "Record keys…" }
        button.setAccessibilityValue(chord?.display ?? "Unassigned")
    }

    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) {
        button.finishRecording()
    }
}

final class ShortcutRecorderButton: NSButton {
    var changed: ((KeyChord) -> Void)?
    var recordingChanged: ((Bool) -> Void)?
    private(set) var recording = false
    private var previousTitle = ""
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        target = self
        action = #selector(beginRecording)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func beginRecording() {
        guard !recording else { return }
        previousTitle = title
        recording = true
        recordingChanged?(true)
        title = "Press keys… (Esc cancels)"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode != 53 || !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            let chord = KeyChord(event: event)
            changed?(chord)
            previousTitle = chord.display
        }
        finishRecording()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        finishRecording()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        if window == nil { finishRecording() }
        super.viewDidMoveToWindow()
    }

    func finishRecording() {
        guard recording else { return }
        recording = false
        title = previousTitle
        recordingChanged?(false)
    }
}

// MARK: - Editor window

struct KeyboardShortcutsButton: View {
    @ObservedObject var shortcuts: KeyboardShortcutsStore
    let openEditor: () -> Void

    var body: some View {
        Button(action: openEditor) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Customise shortcuts…", systemImage: "command")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }
                if shortcuts.actionError != nil || !shortcuts.errors.isEmpty {
                    Label("A shortcut needs attention", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }
}

final class KeyboardShortcutsWindow: NSWindowController, NSWindowDelegate {
    init(store: KeyboardShortcutsStore) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 550),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Keyboard Shortcuts"
        window.minSize = NSSize(width: 660, height: 500)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: KeyboardShortcutsView(store: store))
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
    func windowWillClose(_ notification: Notification) { window?.makeFirstResponder(nil) }
    func windowDidResignKey(_ notification: Notification) { window?.makeFirstResponder(nil) }
}

private struct KeyboardShortcutsView: View {
    @ObservedObject var store: KeyboardShortcutsStore
    @State private var selection: UUID?
    @State private var draft = KeyboardShortcutRule()
    @State private var editing = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Make your keys useful").font(.title2.weight(.semibold))
                    Text("Works across Mac keyboards while RazerCtl is open.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Pause shortcuts", isOn: Binding(get: { store.paused }, set: store.setPaused))
                    .toggleStyle(.switch).fixedSize()
            }
            .padding(20)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Assignments").font(.headline)
                        Spacer()
                        Button(action: newAssignment) { Image(systemName: "plus") }
                            .accessibilityLabel("Add assignment")
                            .help("Add assignment")
                            .disabled(store.storageError != nil)
                    }.padding(14)
                    if store.rules.isEmpty {
                        Text("Open an app, visit a website, or send a shortcut with your chosen keys.")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14).padding(.bottom, 14)
                    }
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(store.rules) { rule in
                                Button {
                                    selection = rule.id; draft = rule; editing = true; error = nil
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(rule.name.isEmpty ? rule.action.title : rule.name)
                                                .fontWeight(.medium).lineLimit(1)
                                            Spacer(minLength: 4)
                                            if !rule.enabled { Text("Off").foregroundStyle(.secondary) }
                                        }
                                        Text("\(rule.trigger?.display ?? "Unassigned") → \(rule.summary)")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        if let problem = store.errors[rule.id] {
                                            Text(problem).font(.caption).foregroundStyle(.orange)
                                                .fixedSize(horizontal: false, vertical: true)
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
                        if editing {
                            editor
                        } else {
                            Text("Your shortcuts, your workflow").font(.headline)
                            Text("Choose a function key such as F6, or a combination such as ⌃⌥S.")
                                .foregroundStyle(.secondary)
                            Button("Add assignment", action: newAssignment)
                                .disabled(store.storageError != nil)
                        }
                        if let problem = store.storageError {
                            Text(problem).foregroundStyle(.orange)
                        }
                        if let problem = store.actionError {
                            Text(problem).foregroundStyle(.orange)
                            Button("Dismiss") { store.actionError = nil }
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack {
                Text(store.paused ? "Shortcuts paused" : "\(store.activeCount) active assignments")
                Spacer()
                Text("F1–F12 may require holding Fn.")
            }.font(.caption).foregroundStyle(.secondary).padding(14)
        }
        .frame(minWidth: 660, minHeight: 460)
        .background(Color(red: 0.141, green: 0.149, blue: 0.165))
        .environment(\.colorScheme, .dark)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshAccess()
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(selection == nil ? "New assignment" : "Edit assignment").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.subheadline.weight(.medium))
                TextField("e.g. Open Safari", text: $draft.name)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Assignment name")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("When I press").font(.subheadline.weight(.medium))
                ShortcutRecorder(chord: $draft.trigger, label: "Trigger keys", recordingChanged: store.setRecording)
                    .frame(height: 28)
                Text("Use an F key, or include ⌘, ⌃ or ⌥.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ShortcutActionFields(rule: $draft, accessibilityGranted: store.accessibilityGranted,
                                 requestAccess: store.requestAccessibility, recordingChanged: store.setRecording)
            Toggle("Enabled", isOn: $draft.enabled)
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            HStack {
                if selection != nil {
                    Button("Delete", role: .destructive) {
                        if let selection { store.remove(selection) }
                        editing = false; selection = nil; error = nil
                    }
                }
                Spacer()
                Button("Cancel") { editing = false; selection = nil; error = nil }
                Button("Save", action: save).buttonStyle(.borderedProminent)
                    .disabled(store.storageError != nil)
            }
        }
    }

    private func newAssignment() {
        selection = nil; draft = KeyboardShortcutRule(); editing = true; error = nil
    }

    private func save() {
        do {
            try store.save(draft)
            selection = draft.id
            error = nil
        } catch { self.error = error.localizedDescription }
    }

}

// Shared by keyboard shortcuts and mouse button assignments.
struct ShortcutActionFields: View {
    @Binding var rule: KeyboardShortcutRule
    let accessibilityGranted: Bool
    let requestAccess: () -> Void
    let recordingChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Do this", selection: $rule.action) {
                ForEach(ShortcutAction.allCases) { action in Text(action.title).tag(action) }
            }
            switch rule.action {
            case .sendShortcut:
                ShortcutRecorder(chord: $rule.output, label: "Shortcut to send", recordingChanged: recordingChanged)
                    .frame(height: 28)
                if !accessibilityGranted {
                    Text("Sending shortcuts needs Accessibility access.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Allow Accessibility…", action: requestAccess)
                }
            case .openApplication:
                HStack {
                    Text(rule.destination.isEmpty ? "No app selected" : rule.summary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose app…", action: chooseApplication)
                }
            case .openWebsite:
                TextField("https://example.com", text: $rule.destination)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Website address")
            }
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an app"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { rule.destination = url.path }
    }
}
