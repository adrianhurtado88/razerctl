import AppKit
import IOKit.hid
import SwiftUI

// Read the OS's LED output elements; never rewrite Caps/Num/Scroll state.
// Bind the selected control collection to a physical USB location before
// looking for its keyboard collection, including with identical models.
enum KeyboardLockReader {
    static func registryID(_ id: String) -> UInt64? {
        let parts = id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == "02a2", parts[1].count % 2 == 0 else { return nil }
        let bytes = Array(parts[1].utf8)
        var data = Data()
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let byte = UInt8(String(decoding: bytes[index..<index+2], as: UTF8.self), radix: 16) else { return nil }
            data.append(byte)
        }
        guard let path = String(data: data, encoding: .utf8), path.hasPrefix("DevSrvsID:") else { return nil }
        return UInt64(path.dropFirst("DevSrvsID:".count))
    }
    static func read(id: String) -> [Int: Bool] {
        guard let registry = registryID(id) else { return [:] }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, ["VendorID": 0x1532, "ProductID": 0x02A2] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return [:] }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [:] }
        func number(_ device: IOHIDDevice, _ key: String) -> Int? {
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
        }
        guard let control = devices.first(where: { device in
            var entry: UInt64 = 0
            return IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entry) == kIOReturnSuccess
                && entry == registry && number(device, "PrimaryUsagePage") == 1 && number(device, "PrimaryUsage") == 2
                && (IOHIDDeviceGetProperty(device, "Transport" as CFString) as? String) == "USB"
        }), let location = number(control, "LocationID"), location != 0 else { return [:] }
        var result: [Int: Bool] = [:]
        for device in devices where number(device, "LocationID") == location
            && number(device, "PrimaryUsagePage") == 1 && number(device, "PrimaryUsage") == 6 {
            guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { continue }
            for element in elements where IOHIDElementGetType(element) == kIOHIDElementTypeOutput
                && IOHIDElementGetReportID(element) == 0 && IOHIDElementGetReportSize(element) == 1
                && IOHIDElementGetUsagePage(element) == 8 && (1...3).contains(IOHIDElementGetUsage(element)) {
                let seed = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0)
                var value = Unmanaged.passUnretained(seed)
                if IOHIDDeviceGetValue(device, element, &value) == kIOReturnSuccess {
                    let integer = IOHIDValueGetIntegerValue(value.takeUnretainedValue())
                    if integer == 0 || integer == 1 { result[Int(IOHIDElementGetUsage(element))] = integer == 1 }
                }
            }
        }
        return result
    }
}

final class KeyboardControlsStore: ObservableObject {
    typealias Execute = ([String], @escaping (Result<[String: String], ShortcutFailure>) -> Void) -> Void
    @Published var expanded = false
    @Published private(set) var locks: [Int: Bool] = [:]
    @Published private(set) var gaming: Bool?
    @Published private(set) var macro: Bool?
    @Published private(set) var gamingAvailable = false
    @Published private(set) var macroAvailable = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var cleanupNeeded = false
    var cancelRecorder: (() -> Void)?
    private let id: String
    private let execute: Execute
    private let readLocks: (String) -> [Int: Bool]
    private let readQueue = DispatchQueue(label: "local.razerctl.keyboard.leds")
    private var timer: Timer?
    private var readingLocks = false
    private var recordingRequested = false
    private var ownsMacro = false
    private var startingMacro = false
    private var releasingMacro = false
    private var cleanupWaiters: [() -> Void] = []
    init(id: String, execute: @escaping Execute, readLocks: @escaping (String) -> [Int: Bool] = KeyboardLockReader.read) {
        self.id = id; self.execute = execute; self.readLocks = readLocks
    }
    func apply(settings: [String: String], gamingAvailable: Bool, macroAvailable: Bool) {
        self.gamingAvailable = gamingAvailable
        self.macroAvailable = macroAvailable
        if !busy { gaming = Self.state(settings["gaming_mode"]) }
        if !startingMacro && !ownsMacro { macro = Self.state(settings["macro_recording"]) }
        if !busy && !startingMacro && !releasingMacro && !ownsMacro && !cleanupNeeded,
           gaming != nil, macro != nil { error = nil }
    }
    static func state(_ value: String?) -> Bool? { value == "1" ? true : (value == "0" ? false : nil) }
    func monitor(_ enabled: Bool) {
        timer?.invalidate(); timer = nil
        guard enabled else { locks = [:]; return }
        refreshLocks()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshLocks() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func refreshLocks() {
        guard !readingLocks else { return }
        readingLocks = true
        readQueue.async { [weak self] in
            guard let self else { return }
            let values = self.readLocks(self.id)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readingLocks = false
                if self.timer != nil { self.locks = values }
            }
        }
    }
    func setGaming(_ enabled: Bool) {
        guard gamingAvailable, !busy, let current = gaming, current != enabled else { return }
        busy = true; error = nil
        execute(["keyboard-mode", "gaming", enabled ? "on" : "off", current ? "expected-on" : "expected-off"]) { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let values):
                self.gaming = Self.state(values["gaming_mode"])
                if self.gaming != enabled { self.error = "Gaming Mode could not be confirmed. Click Detect to retry." }
            case .failure(let problem): self.error = problem.message; self.gaming = nil
            }
            self.completeCleanup()
        }
    }
    func beginRecording(completion: @escaping (String?) -> Void) {
        guard macroAvailable, !startingMacro, !ownsMacro, !releasingMacro else {
            completion("Macro indicator unavailable; click Detect to retry."); return
        }
        recordingRequested = true; startingMacro = true; error = nil
        execute(["keyboard-mode", "macro", "on", "expected-off"]) { [weak self] result in
            guard let self else { return }
            self.startingMacro = false
            switch result {
            case .success(let values):
                guard Self.state(values["macro_recording"]) == true else {
                    self.recordingRequested = false; self.error = "Macro recording could not be confirmed."
                    completion(self.error); self.completeCleanup(); return
                }
                self.ownsMacro = true; self.macro = true
                if self.recordingRequested { completion(nil) }
                else { self.endRecording() }
            case .failure(let problem):
                self.recordingRequested = false; self.error = problem.message
                completion(problem.message); self.completeCleanup()
            }
        }
    }
    func endRecording(completion: (() -> Void)? = nil) {
        if let completion { cleanupWaiters.append(completion) }
        recordingRequested = false
        guard !startingMacro else { return } // Start completion will release its own acquisition.
        guard !releasingMacro else { return }
        guard ownsMacro else { completeCleanup(); return }
        releasingMacro = true
        ownsMacro = false // Coalesce cancellation, focus loss, sleep and window close.
        execute(["keyboard-mode", "macro", "off", "expected-on"]) { [weak self] result in
            guard let self else { return }
            self.releasingMacro = false
            switch result {
            case .success(let values):
                self.macro = Self.state(values["macro_recording"])
                self.cleanupNeeded = self.macro != false
                self.ownsMacro = self.cleanupNeeded
                if self.cleanupNeeded { self.error = "Macro indicator cleanup could not be confirmed." }
            case .failure(let problem):
                self.ownsMacro = true; self.cleanupNeeded = true
                self.macro = nil; self.error = "Couldn't release the macro indicator: \(problem.message)"
            }
            self.completeCleanup()
        }
    }
    private func completeCleanup() { guard !startingMacro, !releasingMacro, !busy else { return }; let callbacks = cleanupWaiters; cleanupWaiters = []; callbacks.forEach { $0() } }
    func shutdown(completion: @escaping () -> Void = {}) {
        cancelRecorder?(); monitor(false); endRecording(completion: completion)
    }
    deinit { timer?.invalidate() }
}

struct KeyboardControlsSection: View {
    @ObservedObject var controls: KeyboardControlsStore
    @ObservedObject var shortcuts: KeyboardShortcutsStore
    let openShortcuts: () -> Void
    let openMacros: () -> Void
    private func stateText(_ state: Bool?) -> String { state.map { $0 ? "On" : "Off" } ?? "Unknown" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Button { controls.expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: controls.expanded ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold))
                    Text("Keyboard controls").font(.system(size: 13, weight: .semibold))
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("Keyboard controls")
                .accessibilityValue(controls.expanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Show or hide status lights, Gaming Mode and macros")
            if controls.expanded {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Status lights").fontWeight(.medium)
                        HStack(spacing: 12) {
                            indicator("C", label: "Caps Lock", value: controls.locks[2])
                            indicator("1", label: "Num Lock", value: controls.locks[1])
                            indicator("S", label: "Scroll Lock", value: controls.locks[3])
                            indicator("M", label: "Macro recording", value: controls.macro)
                            indicator(nil, label: "Gaming Mode", value: controls.gaming)
                            Spacer(minLength: 0)
                        }
                        Text("Caps \(stateText(controls.locks[2])) · Num \(stateText(controls.locks[1])) · Scroll \(stateText(controls.locks[3]))")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Gaming Mode").fontWeight(.medium)
                            Text("Limit accidental system shortcuts.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Toggle("Gaming Mode", isOn: Binding(get: { controls.gaming == true }, set: controls.setGaming))
                            .labelsHidden().toggleStyle(.switch)
                            .help("Uses the keyboard’s Gaming Mode. Check Command-key behavior on your Mac.")
                            .disabled(!controls.gamingAvailable || controls.gaming == nil || controls.busy)
                    }
                    if !controls.gamingAvailable {
                        Text("Gaming Mode is unavailable for this keyboard. Click Detect to retry.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Macros").fontWeight(.medium)
                            Text("Record keys, then assign a shortcut.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Button("Record macro…", action: openMacros).disabled(!controls.macroAvailable || controls.cleanupNeeded)
                    }
                    if let error = controls.error {
                        Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if controls.cleanupNeeded { Button("Retry indicator cleanup") { controls.endRecording() } }
                    Divider()
                    KeyboardShortcutsButton(shortcuts: shortcuts, openEditor: openShortcuts,
                                            title: "Keyboard shortcuts…", showsIcon: false, prominent: true)
                }
            }
        }
        .onAppear { controls.monitor(controls.expanded) }
        .onChange(of: controls.expanded) { controls.monitor($0) }
        .onDisappear { controls.monitor(false) }
    }
    private func indicator(_ glyph: String?, label: String, value: Bool?) -> some View {
        Group {
            if let glyph { Text(glyph).font(.system(size: 12, weight: .semibold)) }
            else { Image(systemName: "gamecontroller").font(.system(size: 12, weight: .semibold)) }
        }
        .frame(width: 30, height: 30)
        .foregroundStyle(value == true ? Color(red: 1, green: 0.22, blue: 0.39) : Color.secondary)
        .background(Color.white.opacity(0.035), in: Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
        .accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityValue(stateText(value))
        .help("\(label): \(stateText(value))")
    }
}
