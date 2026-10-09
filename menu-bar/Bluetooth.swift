import Foundation
import CoreBluetooth

// Native Bluetooth transport. USB HID reports must never be reused here.
// Wire format reference: OpenSnek docs/protocol/BLE_PROTOCOL.md (Apache-2.0).
// This is an independent, deliberately limited implementation of that protocol.

struct BluetoothScan {
    var devices: [DetectedDevice] = []
    var error: String?
    var signature: String {
        devices.map { "\($0.id):\($0.name)" }.sorted().joined(separator: "|") + (error ?? "")
    }
}

protocol BluetoothBackend: AnyObject {
    func inventory() -> BluetoothScan
    func detect() -> BluetoothScan
    func command(_ args: [String], id: String) -> (output: String, exitCode: Int32)
}

enum BluetoothFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

struct BluetoothProfile {
    let name: String
    let pid: UInt16
    let dpiMax: Int
    let zones: [UInt8]

    static let all = [
        BluetoothProfile(name: "Razer Basilisk V3 X HyperSpeed", pid: 0x00BA, dpiMax: 18000, zones: []),
        BluetoothProfile(name: "Razer Basilisk V3 Pro", pid: 0x00AC, dpiMax: 30000, zones: [1, 4, 10]),
    ]

    // Exact aliases only: a similar name does not establish protocol support.
    static func named(_ name: String) -> BluetoothProfile? {
        let normalized = name.lowercased().split { !$0.isLetter && !$0.isNumber }
            .filter { $0 != "razer" }.joined(separator: " ")
        switch normalized {
        case "basilisk v3 x hyperspeed", "bsk v3 x hyperspeed", "bsk v3 x hs": return all[0]
        case "basilisk v3 pro", "bsk v3 pro": return all[1]
        default: return nil
        }
    }
}

enum BluetoothWire {
    static let service = CBUUID(string: "52401523-F97C-7F90-0E7F-6C6F4E36DB1C")
    static let write = CBUUID(string: "52401524-F97C-7F90-0E7F-6C6F4E36DB1C")
    static let notify = CBUUID(string: "52401525-F97C-7F90-0E7F-6C6F4E36DB1C")
    static let dpiRead: [UInt8] = [0x0B, 0x84, 1, 0]
    static let dpiWrite: [UInt8] = [0x0B, 0x04, 1, 0]

    static func writes(request: UInt8, key: [UInt8], payload: [UInt8] = []) -> [Data] {
        precondition(key.count == 4 && payload.count <= 255)
        var frames = [Data([request, UInt8(payload.count), 0, 0] + key)]
        for offset in stride(from: 0, to: payload.count, by: 20) {
            frames.append(Data(payload[offset..<min(offset + 20, payload.count)]))
        }
        return frames
    }

    struct Reply {
        let request: UInt8
        var length: Int?
        var payload: [UInt8] = []

        mutating func consume(_ frame: Data) throws -> [UInt8]? {
            let bytes = Array(frame)
            if length == nil {
                guard bytes.count >= 8, bytes[0] == request,
                      bytes[2...6].allSatisfy({ $0 == 0 }),
                      [2, 3, 5].contains(bytes[7]) else { return nil }
                guard bytes[7] == 2 else {
                    throw BluetoothFailure.message("The Bluetooth device rejected the command (status \(bytes[7])).")
                }
                length = Int(bytes[1])
                // Both documented header forms (8 and 20 bytes) carry no payload.
            } else {
                payload += bytes
            }
            guard let length, payload.count >= length else { return nil }
            return Array(payload.prefix(length))
        }
    }

    struct DPIStages {
        var active: UInt8
        let count: Int
        var entries: [[UInt8]]
        var activeIndex: Int {
            entries.prefix(count).firstIndex(where: { $0[0] == active })
                ?? ((1...count).contains(Int(active)) ? Int(active) - 1 : min(Int(active), count - 1))
        }
        func x(_ index: Int) -> Int { Int(entries[index][1]) | Int(entries[index][2]) << 8 }
        func y(_ index: Int) -> Int { Int(entries[index][3]) | Int(entries[index][4]) << 8 }

        init(_ bytes: [UInt8], maximum: Int) throws {
            guard bytes.count >= 2, (1...5).contains(Int(bytes[1])) else {
                throw BluetoothFailure.message("The Bluetooth device returned an invalid DPI table.")
            }
            active = bytes[0]
            count = Int(bytes[1])
            entries = []
            for index in 0..<5 {
                let offset = 2 + index * 7
                if bytes.count >= offset + 5 {
                    var entry = Array(bytes[offset..<min(offset + 7, bytes.count)])
                    entry += Array(repeating: 0, count: 7 - entry.count)
                    entries.append(entry)
                } else if index < count {
                    throw BluetoothFailure.message("The Bluetooth DPI table was incomplete.")
                } else {
                    // Missing slots are inactive; keep the visible stage table intact.
                    var entry = entries.last!
                    entry[0] = UInt8(index + 1)
                    entries.append(entry)
                }
            }
            guard Set(entries.prefix(count).map { $0[0] }).count == count,
                  (0..<count).allSatisfy({ (100...maximum).contains(x($0)) && (100...maximum).contains(y($0)) }) else {
                throw BluetoothFailure.message("The Bluetooth DPI values are outside this model's range.")
            }
        }

        mutating func selectOrSet(_ value: Int, maximum: Int) throws {
            guard (100...maximum).contains(value) else {
                throw BluetoothFailure.message("Choose a DPI between 100 and \(maximum).")
            }
            if let index = (0..<count).first(where: { x($0) == value && y($0) == value }) {
                active = entries[index][0]
            } else {
                let index = activeIndex
                active = entries[index][0]
                entries[index][1] = UInt8(value & 255)
                entries[index][2] = UInt8(value >> 8)
                entries[index][3] = UInt8(value & 255)
                entries[index][4] = UInt8(value >> 8)
            }
        }

        var encoded: [UInt8] { [active, UInt8(count)] + entries.flatMap { $0 } + [0] }
    }
}

/// All public operations run on Store's serial worker queue, never the main
/// thread. CoreBluetooth callbacks run on a separate queue so waits cannot
/// block the UI or the callbacks needed to complete an operation.
final class BluetoothController: NSObject, BluetoothBackend, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let queue = DispatchQueue(label: "local.razerctl.bluetooth")
    private var central: CBCentralManager?
    private var stateChanged: (() -> Void)?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var ready: [UUID: (CBCharacteristic, CBCharacteristic)] = [:]
    private var connectingID: UUID?
    private var connected: ((Result<Void, Error>) -> Void)?
    private var reply: BluetoothWire.Reply?
    private var frames: [Data] = []
    private var acknowledged = false
    private var response: [UInt8]?
    private var exchangeID: UUID?
    private var exchanged: ((Result<[UInt8], Error>) -> Void)?
    private var request: UInt8 = 0x30

    private func wait<T>(timeout: Double = 5, _ operation: @escaping (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
        precondition(!Thread.isMainThread, "Bluetooth operations must run on the device queue")
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        queue.async {
            var finished = false
            let complete: (Result<T, Error>) -> Void = { value in
                guard !finished else { return }
                finished = true
                result = value
                semaphore.signal()
            }
            self.queue.asyncAfter(deadline: .now() + timeout) {
                complete(.failure(BluetoothFailure.message("Bluetooth timed out. Wake the device and click Detect.")))
            }
            operation(complete)
        }
        semaphore.wait()
        return try result!.get()
    }

    private func poweredOn() throws {
        try wait(timeout: 2) { done in
            let check = {
                guard let central = self.central else { return }
                switch central.state {
                case .poweredOn: done(.success(()))
                case .unauthorized:
                    done(.failure(BluetoothFailure.message("Allow RazerCtl in System Settings > Privacy & Security > Bluetooth, then click Detect.")))
                case .poweredOff: done(.failure(BluetoothFailure.message("Bluetooth is off. Turn it on and click Detect.")))
                case .unsupported: done(.failure(BluetoothFailure.message("Bluetooth isn't available on this Mac.")))
                default: break
                }
            }
            self.stateChanged = check
            if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: self.queue,
                    options: [CBCentralManagerOptionShowPowerAlertKey: false])
            }
            check()
        } as Void
    }

    private func connectedDevices() throws -> [CBPeripheral] {
        try poweredOn()
        return try wait { done in
            let found = self.central!.retrieveConnectedPeripherals(withServices: [BluetoothWire.service])
            for peripheral in found { self.peripherals[peripheral.identifier] = peripheral }
            let present = Set(found.map(\.identifier))
            for id in Array(self.ready.keys) where !present.contains(id) { self.ready.removeValue(forKey: id) }
            self.peripherals = self.peripherals.filter { present.contains($0.key) }
            done(.success(found.sorted { $0.identifier.uuidString < $1.identifier.uuidString }))
        }
    }

    private func device(_ peripheral: CBPeripheral, query: Bool) -> DetectedDevice {
        let name = peripheral.name ?? "Razer Bluetooth device"
        let profile = BluetoothProfile.named(name)
        let id = "ble:\(peripheral.identifier.uuidString)"
        var capabilities = DeviceCapabilities()
        var settings: [String: String] = [:]
        var problems: [String] = []
        if let profile, query {
            settings["mouse"] = profile.name
            do { try checkActiveProfile(id: peripheral.identifier, profile: profile) }
            catch {
                return DetectedDevice(id: id, name: profile.name, kind: "mouse",
                    usb_id: String(format: "068E:%04X", profile.pid), supported: true,
                    capabilities: capabilities, settings: settings, error: error.localizedDescription,
                    transport: "bluetooth")
            }
            do {
                let table = try readStages(id: peripheral.identifier, profile: profile)
                capabilities.dpi_min = 100
                capabilities.dpi_max = profile.dpiMax
                capabilities.dpi_stages = true
                let x = table.x(table.activeIndex), y = table.y(table.activeIndex)
                settings["dpi"] = x == y ? String(x) : "\(x) × \(y)"
                settings["stages"] = (0..<table.count).map { String(table.x($0)) }.joined(separator: ",")
            } catch { problems.append(error.localizedDescription) }
            do {
                let brightness = try readBrightness(id: peripheral.identifier, profile: profile)
                capabilities.brightness = true
                settings["mouse_brightness"] = String(brightness)
                // Static color uses separate, capture-backed paths per model.
                // Enable it only after the corresponding state can be read.
                _ = try readLighting(id: peripheral.identifier, profile: profile)
                capabilities.effects = ["static"]
            } catch { problems.append(error.localizedDescription) }
        }
        return DetectedDevice(id: id, name: profile?.name ?? name,
            kind: profile == nil ? "device" : "mouse",
            usb_id: profile.map { String(format: "068E:%04X", $0.pid) } ?? "",
            supported: profile != nil, capabilities: capabilities, settings: settings,
            error: problems.isEmpty ? nil : problems.joined(separator: " "), transport: "bluetooth")
    }

    func inventory() -> BluetoothScan {
        do { return BluetoothScan(devices: try connectedDevices().map { device($0, query: false) }) }
        catch { return BluetoothScan(error: error.localizedDescription) }
    }

    func detect() -> BluetoothScan {
        do { return BluetoothScan(devices: try connectedDevices().map { device($0, query: true) }) }
        catch { return BluetoothScan(error: error.localizedDescription) }
    }

    private func connect(_ id: UUID) throws {
        do {
            try wait { done in
                guard let peripheral = self.peripherals[id] else {
                    done(.failure(BluetoothFailure.message("This Bluetooth device disconnected. Click Detect.")))
                    return
                }
                if self.ready[id] != nil, peripheral.state == .connected {
                    done(.success(())); return
                }
                self.connected = done
                self.connectingID = id
                self.ready.removeValue(forKey: id)
                peripheral.delegate = self
                // A system connection still requires a connection for this app.
                if peripheral.state == .connected {
                    peripheral.discoverServices([BluetoothWire.service])
                } else {
                    self.central!.connect(peripheral)
                }
            } as Void
        } catch {
            queue.sync {
                self.connected = nil
                self.connectingID = nil
                self.ready.removeValue(forKey: id)
                if let peripheral = self.peripherals[id] { self.central?.cancelPeripheralConnection(peripheral) }
            }
            throw error
        }
    }

    private func exchange(_ id: UUID, key: [UInt8], payload: [UInt8] = []) throws -> [UInt8] {
        try connect(id)
        do {
            return try wait { done in
                guard self.exchanged == nil, let peripheral = self.peripherals[id],
                      let (write, _) = self.ready[id] else {
                    done(.failure(BluetoothFailure.message("The Bluetooth control connection is unavailable.")))
                    return
                }
                self.request &+= 1
                self.reply = BluetoothWire.Reply(request: self.request)
                self.frames = BluetoothWire.writes(request: self.request, key: key, payload: payload)
                self.exchanged = done
                self.exchangeID = id
                self.response = nil
                self.acknowledged = false
                peripheral.writeValue(self.frames.removeFirst(), for: write, type: .withResponse)
            }
        } catch {
            queue.sync {
                self.finishExchange(.failure(error))
                self.ready.removeValue(forKey: id)
                if let peripheral = self.peripherals[id] { self.central?.cancelPeripheralConnection(peripheral) }
            }
            throw error
        }
    }

    private func finishExchange(_ value: Result<[UInt8], Error>) {
        let completion = exchanged
        exchanged = nil; exchangeID = nil; reply = nil; response = nil; frames = []
        completion?(value)
    }

    private func readStages(id: UUID, profile: BluetoothProfile) throws -> BluetoothWire.DPIStages {
        try BluetoothWire.DPIStages(exchange(id, key: BluetoothWire.dpiRead), maximum: profile.dpiMax)
    }

    private func checkActiveProfile(id: UUID, profile: BluetoothProfile) throws {
        if profile.pid == 0x00AC {
            let active = try exchange(id, key: [0x03, 0x82, 0, 0])
            // The mapped setting reads use the live/projection bank (1).
            // Other onboard banks can diverge after a physical profile switch.
            guard active == [1] else {
                throw BluetoothFailure.message("Bluetooth customization for this onboard profile isn't supported yet. Select the default profile or use USB, then click Detect.")
            }
        }
    }

    private func readBrightness(id: UUID, profile: BluetoothProfile) throws -> UInt8 {
        var values: [UInt8] = []
        for zone in profile.zones.isEmpty ? [UInt8(1)] : profile.zones {
            let value = try exchange(id, key: [0x10, 0x85, 1, zone])
            guard value.count == 1 else { throw BluetoothFailure.message("Bluetooth brightness couldn't be read.") }
            values.append(value[0])
        }
        // The single slider must not claim a shared brightness when zones differ.
        guard Set(values).count == 1 else {
            throw BluetoothFailure.message("Lighting zones have different brightness levels; a shared Bluetooth brightness control isn't available.")
        }
        return values[0]
    }

    private func readLighting(id: UUID, profile: BluetoothProfile) throws -> [[UInt8]] {
        if profile.zones.isEmpty {
            let value = try exchange(id, key: [0x10, 0x84, 0, 0])
            guard value.count == 4 || (value.count == 8 && Array(value.prefix(4)) == [4, 0, 0, 0]) else {
                throw BluetoothFailure.message("Bluetooth color couldn't be read.")
            }
            return [Array(value.suffix(3))]
        } else {
            var colors: [[UInt8]] = []
            for zone in profile.zones {
                let value = try exchange(id, key: [0x10, 0x83, 0, zone])
                guard value.count == 10 else {
                    throw BluetoothFailure.message("Bluetooth zone color couldn't be read.")
                }
                colors.append(Array(value[4...6]))
            }
            return colors
        }
    }

    func command(_ args: [String], id: String) -> (output: String, exitCode: Int32) {
        do {
            guard id.hasPrefix("ble:"), let uuid = UUID(uuidString: String(id.dropFirst(4))) else {
                throw BluetoothFailure.message("Invalid Bluetooth device selection.")
            }
            // Resolve the exact UUID anew. Never fall back to another device.
            guard let peripheral = try connectedDevices().first(where: { $0.identifier == uuid }),
                  let profile = BluetoothProfile.named(peripheral.name ?? "") else {
                throw BluetoothFailure.message("The selected Bluetooth device is unavailable or unsupported.")
            }
            try checkActiveProfile(id: uuid, profile: profile)
            switch args.first {
            case "dpi":
                guard args.count >= 2, let value = Int(args[1]), (100...profile.dpiMax).contains(value) else {
                    throw BluetoothFailure.message("Choose a DPI between 100 and \(profile.dpiMax).")
                }
                var table = try readStages(id: uuid, profile: profile)
                try table.selectOrSet(value, maximum: profile.dpiMax)
                _ = try exchange(uuid, key: BluetoothWire.dpiWrite, payload: table.encoded)
                let checked = try readStages(id: uuid, profile: profile)
                guard checked.x(checked.activeIndex) == value, checked.y(checked.activeIndex) == value else {
                    throw BluetoothFailure.message("The Bluetooth DPI change couldn't be confirmed. Click Detect to read the current setting.")
                }
            case "brightness":
                guard args.count >= 2, let percent = Int(args[1]), (0...100).contains(percent) else {
                    throw BluetoothFailure.message("Choose a brightness between 0 and 100.")
                }
                _ = try readBrightness(id: uuid, profile: profile)
                let value = UInt8((percent * 255 + 50) / 100)
                for zone in profile.zones.isEmpty ? [UInt8(0)] : profile.zones {
                    _ = try exchange(uuid, key: [0x10, 0x05, 1, zone], payload: [value])
                }
                guard try readBrightness(id: uuid, profile: profile) == value else {
                    throw BluetoothFailure.message("The Bluetooth brightness change couldn't be confirmed. Click Detect.")
                }
            case "effect":
                guard args.count >= 3, args[1] == "static", args[2].count == 6,
                      let rgb = UInt32(args[2], radix: 16) else {
                    throw BluetoothFailure.message("Only static color is supported over Bluetooth on this model.")
                }
                _ = try readLighting(id: uuid, profile: profile)
                let color: [UInt8] = [UInt8((rgb >> 16) & 255), UInt8((rgb >> 8) & 255), UInt8(rgb & 255)]
                if profile.zones.isEmpty {
                    _ = try exchange(uuid, key: [0x10, 0x04, 0, 0], payload: [4, 0, 0, 0, 0] + color)
                } else {
                    for zone in profile.zones {
                        _ = try exchange(uuid, key: [0x10, 0x03, 0, zone], payload: [1, 0, 0, 1] + color + [0, 0, 0])
                    }
                }
                guard try readLighting(id: uuid, profile: profile).allSatisfy({ $0 == color }) else {
                    throw BluetoothFailure.message("The Bluetooth color change couldn't be confirmed. Click Detect.")
                }
            default:
                throw BluetoothFailure.message("This control isn't supported over Bluetooth on this model.")
            }
            return ("", 0)
        } catch { return (error.localizedDescription, 1) }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        stateChanged?()
        if central.state != .poweredOn {
            ready.removeAll()
            connected?(.failure(BluetoothFailure.message("The Bluetooth connection was interrupted.")))
            connected = nil; connectingID = nil
            finishExchange(.failure(BluetoothFailure.message("The Bluetooth connection was interrupted.")))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard connectingID == peripheral.identifier else { return }
        peripheral.discoverServices([BluetoothWire.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        disconnected(peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        disconnected(peripheral, error: error)
    }

    private func disconnected(_ peripheral: CBPeripheral, error: Error?) {
        let problem = error ?? BluetoothFailure.message("The Bluetooth device disconnected. Wake it and click Detect.")
        ready.removeValue(forKey: peripheral.identifier)
        if connectingID == peripheral.identifier { connected?(.failure(problem)); connected = nil; connectingID = nil }
        if exchangeID == peripheral.identifier { finishExchange(.failure(problem)) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard connectingID == peripheral.identifier else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == BluetoothWire.service }) else {
            disconnected(peripheral, error: error ?? BluetoothFailure.message("This device doesn't expose a supported Bluetooth control service."))
            return
        }
        peripheral.discoverCharacteristics([BluetoothWire.write, BluetoothWire.notify], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard connectingID == peripheral.identifier else { return }
        guard error == nil,
              let write = service.characteristics?.first(where: { $0.uuid == BluetoothWire.write && $0.properties.contains(.write) }),
              let notify = service.characteristics?.first(where: { $0.uuid == BluetoothWire.notify && $0.properties.contains(.notify) }) else {
            disconnected(peripheral, error: error ?? BluetoothFailure.message("The Bluetooth control characteristics are unavailable."))
            return
        }
        ready[peripheral.identifier] = (write, notify)
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard connectingID == peripheral.identifier, characteristic.uuid == BluetoothWire.notify else { return }
        guard error == nil, characteristic.isNotifying else { disconnected(peripheral, error: error); return }
        let done = connected
        connected = nil; connectingID = nil
        done?(.success(()))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard exchangeID == peripheral.identifier, characteristic.uuid == BluetoothWire.write else { return }
        if let error { finishExchange(.failure(error)); return }
        if !frames.isEmpty, let (write, _) = ready[peripheral.identifier] {
            peripheral.writeValue(frames.removeFirst(), for: write, type: .withResponse)
        } else {
            acknowledged = true
            if let response { finishExchange(.success(response)) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard exchangeID == peripheral.identifier, characteristic.uuid == BluetoothWire.notify else { return }
        if let error { finishExchange(.failure(error)); return }
        guard let value = characteristic.value else { return }
        do {
            if let response = try reply?.consume(value) {
                self.response = response
                if acknowledged { finishExchange(.success(response)) }
            }
        } catch { finishExchange(.failure(error)) }
    }
}
