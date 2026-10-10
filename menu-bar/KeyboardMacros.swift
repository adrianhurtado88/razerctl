import AppKit
import Carbon
import SwiftUI

// A macro stores key codes, display names, modifier flags and relative timing.
// Only the focused recorder receives events; there is no global event monitor.
struct MacroKeyEvent: Codable, Equatable {
    var chord: KeyChord
    var down: Bool
    var delay: Double
}

enum KeyboardMacro {
    static let maximumEvents = 512
    static let maximumDuration = 60.0
    static func validate(_ events: [MacroKeyEvent]) throws {
        guard !events.isEmpty, events.count <= maximumEvents else {
            throw ShortcutFailure("Record a macro of at most 512 key events.")
        }
        var held: [UInt32: KeyChord] = [:]
        var duration = 0.0
        for event in events {
            guard event.chord.validKey, event.delay.isFinite, event.delay >= 0,
                  event.delay <= maximumDuration else { throw ShortcutFailure("The macro contains an invalid key or delay.") }
            duration += event.delay
            if event.down {
                guard held[event.chord.keyCode] == nil else { throw ShortcutFailure("The macro contains a repeated key-down.") }
                held[event.chord.keyCode] = event.chord
            } else {
                guard held.removeValue(forKey: event.chord.keyCode)?.matches(event.chord) == true else {
                    throw ShortcutFailure("The macro contains an unmatched key-up.")
                }
            }
        }
        guard held.isEmpty, duration <= maximumDuration else {
            throw ShortcutFailure("Release each key and keep the macro within 60 seconds.")
        }
    }
}

struct MacroCapture {
    private(set) var events: [MacroKeyEvent] = []
    private var held: [UInt32: KeyChord] = [:]
    private var lastTime: TimeInterval?
    mutating func append(_ chord: KeyChord, down: Bool, time: TimeInterval) -> Bool {
        guard chord.validKey, events.count + held.count < KeyboardMacro.maximumEvents else { return false }
        let actual: KeyChord
        if down {
            guard held[chord.keyCode] == nil else { return true } // Ignore auto-repeat.
            actual = chord; held[chord.keyCode] = chord
        } else {
            guard let original = held.removeValue(forKey: chord.keyCode) else { return true }
            actual = original
        }
        events.append(MacroKeyEvent(chord: actual, down: down, delay: lastTime.map { max(0, time - $0) } ?? 0))
        lastTime = time
        return true
    }
    mutating func finish() -> [MacroKeyEvent] {
        for code in held.keys.sorted() {
            events.append(MacroKeyEvent(chord: held[code]!, down: false, delay: 0))
        }
        held.removeAll()
        return events
    }
}

// Injectable event output makes cancellation and release behavior testable
// without posting any keys to the user's Mac.
final class MacroPlayer {
    private var pending: DispatchWorkItem?
    private var generation = UUID()
    private var held: [UInt32: KeyChord] = [:]
    private let ready: () -> String?
    private let emit: (MacroKeyEvent) -> Bool
    init(ready: @escaping () -> String?, emit: @escaping (MacroKeyEvent) -> Bool) {
        self.ready = ready; self.emit = emit
    }
    func cancel() {
        generation = UUID(); pending?.cancel(); pending = nil
        for code in held.keys.sorted() {
            _ = emit(MacroKeyEvent(chord: held[code]!, down: false, delay: 0))
        }
        held.removeAll()
    }
    func play(_ events: [MacroKeyEvent], completion: @escaping (String?) -> Void) {
        cancel()
        do { try KeyboardMacro.validate(events) }
        catch { completion(error.localizedDescription); return }
        schedule(events, index: 0, token: generation, completion: completion)
    }
    private func schedule(_ events: [MacroKeyEvent], index: Int, token: UUID,
                          completion: @escaping (String?) -> Void) {
        guard token == generation else { return }
        guard index < events.count else { pending = nil; completion(nil); return }
        let event = events[index]
        let work = DispatchWorkItem { [weak self] in
            guard let self, token == self.generation else { return }
            if let error = self.ready() { self.cancel(); completion(error); return }
            guard self.emit(event) else { self.cancel(); completion("macOS could not send the macro."); return }
            if event.down { self.held[event.chord.keyCode] = event.chord }
            else { self.held.removeValue(forKey: event.chord.keyCode) }
            self.schedule(events, index: index + 1, token: token, completion: completion)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + event.delay, execute: work)
    }
    deinit { cancel() }
}

struct MacroRecorder: NSViewRepresentable {
    @Binding var events: [MacroKeyEvent]?
    let recordingChanged: (Bool) -> Void
    var indicators: KeyboardControlsStore? = nil
    func makeNSView(context: Context) -> MacroRecorderButton {
        let button = MacroRecorderButton()
        button.bezelStyle = .rounded
        return button
    }
    func updateNSView(_ button: MacroRecorderButton, context: Context) {
        button.changed = { events = $0 }
        button.recordingChanged = recordingChanged
        button.indicators = indicators
        indicators?.cancelRecorder = { [weak button] in button?.finish(save: false) }
        if !button.recording { button.title = events == nil ? "Record macro…" : "Record again…" }
        button.setAccessibilityLabel("Record macro keys")
    }
    static func dismantleNSView(_ button: MacroRecorderButton, coordinator: ()) { button.finish(save: false) }
}

final class MacroRecorderButton: NSButton {
    var changed: (([MacroKeyEvent]) -> Void)?
    var recordingChanged: ((Bool) -> Void)?
    var indicators: KeyboardControlsStore?
    private(set) var recording = false
    private var capturing = false
    private var capture = MacroCapture()
    private var timer: Timer?
    private var deadline = 0.0
    private var observers: [NSObjectProtocol] = []
    private let secureInput: () -> Bool
    private let canCapture: (() -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    init(secureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() }, canCapture: (() -> Bool)? = nil) {
        self.secureInput = secureInput; self.canCapture = canCapture
        super.init(frame: .zero)
        target = self; action = #selector(toggleRecording)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.finish(save: false) })
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggleRecording() {
        if recording { finish(save: true); return }
        guard !secureInput() else {
            title = "Turn off Secure Keyboard Entry first"; return
        }
        recording = true; recordingChanged?(true)
        title = "Starting recorder…"
        window?.makeFirstResponder(self)
        let begin: (String?) -> Void = { [weak self] error in
            guard let self, self.recording else { return }
            if let error { self.finish(save: false); self.title = error; return }
            guard !self.secureInput() else { self.finish(save: false); self.title = "Turn off Secure Keyboard Entry first"; return }
            guard self.canCapture?() ?? (self.window?.isKeyWindow == true && self.window?.firstResponder === self) else {
                self.finish(save: false); return
            }
            self.capturing = true; self.capture = MacroCapture()
            self.deadline = ProcessInfo.processInfo.systemUptime + KeyboardMacro.maximumDuration
            self.title = "Recording · click to stop · Esc cancels"
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.secureInput() { self.finish(save: false) }
                else if ProcessInfo.processInfo.systemUptime >= self.deadline { self.finish(save: true) }
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        if let indicators { indicators.beginRecording(completion: begin) }
        else { begin(nil) }
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if secureInput() || event.keyCode == 53 { finish(save: false); return }
        guard capturing, !event.isARepeat else { return }
        if !capture.append(KeyChord(event: event), down: true, time: ProcessInfo.processInfo.systemUptime) { finish(save: true) }
    }
    override func keyUp(with event: NSEvent) {
        guard recording else { super.keyUp(with: event); return }
        guard !secureInput() else { finish(save: false); return }
        guard capturing else { return }
        if !capture.append(KeyChord(event: event), down: false, time: ProcessInfo.processInfo.systemUptime) { finish(save: true) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func resignFirstResponder() -> Bool { finish(save: false); return super.resignFirstResponder() }
    override func viewDidMoveToWindow() { if window == nil { finish(save: false) }; super.viewDidMoveToWindow() }
    func finish(save: Bool) {
        guard recording else { return }
        let wasCapturing = capturing
        recording = false; capturing = false
        timer?.invalidate(); timer = nil
        if save && wasCapturing {
            let result = capture.finish()
            if (try? KeyboardMacro.validate(result)) != nil { changed?(result) }
        }
        capture = MacroCapture()
        indicators?.endRecording()
        recordingChanged?(false)
        title = "Record macro…"
    }
    deinit {
        finish(save: false)
        timer?.invalidate()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
}
