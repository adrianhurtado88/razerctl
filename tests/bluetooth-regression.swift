// Pure packet fixtures and an injected backend. No Bluetooth manager is
// created, no permission prompt is shown, and no hardware is accessed.
let bleProfile = BluetoothProfile.named("Razer Basilisk V3 X HyperSpeed")!
check(bleProfile.pid == 0x00BA && bleProfile.dpiMax == 18000)
check(BluetoothProfile.named("BSK V3 Pro")?.zones == [1, 4, 10])
check(BluetoothProfile.named("Razer Basilisk V3 Pro 35K") == nil,
      "Similar model names must not inherit Bluetooth control support")
check(BluetoothProfile.named("Razer BlackWidow V3 Pro") == nil)

// Capture-documented read table: token 9 selects the second entry, despite
// its value not being a stage index. X/Y and reserved bytes must survive.
let bleTable: [UInt8] = [9, 3,
    4, 0x90, 1, 0x90, 1, 0x11, 0,
    9, 0x20, 3, 0xB0, 4, 0x22, 0,
    2, 0x40, 6, 0x40, 6, 0x33, 0,
    6, 0x80, 12, 0x80, 12, 0x44, 0,
    7, 0, 25, 0, 25, 0x55, 0xAB]
var bleStages = try BluetoothWire.DPIStages(bleTable, maximum: 18000)
check(bleStages.activeIndex == 1 && bleStages.x(1) == 800 && bleStages.y(1) == 1200)
try bleStages.selectOrSet(1600, maximum: 18000)
check(bleStages.active == 2 && bleStages.activeIndex == 2)
check(bleStages.entries == Array(stride(from: 2, to: bleTable.count, by: 7)).map { Array(bleTable[$0..<$0 + 7]) },
      "Selecting a preset must preserve every stage and reserved byte")
try bleStages.selectOrSet(900, maximum: 18000)
check(bleStages.x(2) == 900 && bleStages.y(2) == 900 && bleStages.x(0) == 400)
check(bleStages.encoded.count == 38 && bleStages.encoded[36] == 0xAB && bleStages.encoded.last == 0)
let beforeInvalidDPI = bleStages.encoded
do { try bleStages.selectOrSet(18001, maximum: 18000); check(false) } catch {}
do { try bleStages.selectOrSet(99, maximum: 18000); check(false) } catch {}
check(bleStages.encoded == beforeInvalidDPI)
for bad in [[UInt8](), [0, 0], [0, 6], [1, 2, 1, 1, 0, 1, 0], [1, 1, 1, 0, 0, 0, 0]] {
    do { _ = try BluetoothWire.DPIStages(bad, maximum: 18000); check(false) } catch {}
}
// A short final marker is allowed, while missing DPI data is rejected.
let shortTable = try BluetoothWire.DPIStages(Array(bleTable.prefix(22)), maximum: 18000)
check(shortTable.count == 3 && shortTable.x(2) == 1600 && shortTable.encoded.count == 38)

let bleFrames = BluetoothWire.writes(request: 0x31, key: BluetoothWire.dpiWrite, payload: bleStages.encoded)
check(bleFrames.map(\.count) == [8, 20, 18])
check(Array(bleFrames[0]) == [0x31, 0x26, 0, 0, 0x0B, 4, 1, 0])
check(Array(bleFrames.dropFirst().flatMap { $0 }) == bleStages.encoded)
check(BluetoothWire.writes(request: 0x32, key: BluetoothWire.dpiRead) == [Data([0x32, 0, 0, 0, 0x0B, 0x84, 1, 0])])

for headerLength in [8, 20] {
    var reply = BluetoothWire.Reply(request: 0x31)
    let wrongID = try reply.consume(Data([0x30, 1, 0, 0, 0, 0, 0, 2]))
    check(wrongID == nil)
    var header: [UInt8] = [0x31, 37, 0, 0, 0, 0, 0, 2]
    header += Array(repeating: 0, count: headerLength - 8)
    let headerResult = try reply.consume(Data(header))
    check(headerResult == nil, "Header padding isn't DPI payload")
    let partial = try reply.consume(Data(bleTable.prefix(20)))
    check(partial == nil)
    let complete = try reply.consume(Data(bleTable.dropFirst(20)))
    check(complete == bleTable)
}
var refusedReply = BluetoothWire.Reply(request: 0x31)
do { _ = try refusedReply.consume(Data([0x31, 0, 0, 0, 0, 0, 0, 5])); check(false) } catch {}
var emptyReply = BluetoothWire.Reply(request: 0x31)
let emptyResponse = try emptyReply.consume(Data([0x31, 0, 0, 0, 0, 0, 0, 2]))
check(emptyResponse == [])

final class FakeBluetooth: BluetoothBackend {
    var scan = BluetoothScan()
    var calls: [(String, [String])] = []
    var failure: String?
    func inventory() -> BluetoothScan { scan }
    func detect() -> BluetoothScan { scan }
    func command(_ args: [String], id: String) -> (output: String, exitCode: Int32) {
        calls.append((id, args))
        return failure.map { ($0, 1) } ?? ("", 0)
    }
}
func fakeBluetoothDevice(_ id: String, productID: String = "068E:00BA", name: String = "Razer Basilisk V3 X HyperSpeed") -> DetectedDevice {
    var capabilities = DeviceCapabilities()
    capabilities.dpi_max = 18000
    capabilities.dpi_stages = true
    capabilities.effects = ["static"]
    capabilities.brightness = true
    return DetectedDevice(id: id, name: name, kind: "mouse", usb_id: productID, supported: true,
        capabilities: capabilities, settings: ["mouse": name, "dpi": "800", "stages": "400,800,1600", "mouse_brightness": "128"],
        error: nil, transport: "bluetooth")
}
let fakeBluetooth = FakeBluetooth()
let bleFirstID = "ble:00000000-0000-0000-0000-000000000001"
let bleSecondID = "ble:00000000-0000-0000-0000-000000000002"
fakeBluetooth.scan.devices = [fakeBluetoothDevice(bleFirstID), fakeBluetoothDevice(bleSecondID)]
var bluetoothHID = fixtureDevice("hid-ble", kind: "device", name: "Razer Basilisk V3 X HyperSpeed", supported: false)
bluetoothHID["transport"] = "bluetooth"
bluetoothHID["usb_id"] = "068E:00BA"
var wiredSamePID = bluetoothHID
wiredSamePID["id"] = "usb-same-pid"
wiredSamePID["transport"] = "usb"
try writeDevices([keyboardFixture, bluetoothHID, wiredSamePID])
let bluetoothStore = Store(bluetooth: fakeBluetooth)
bluetoothStore.refresh()
settle(bluetoothStore)
check(bluetoothStore.deviceStores.map(\.id) == ["kbd-1", "usb-same-pid", bleFirstID, bleSecondID],
      "Native UUID entries replace duplicate Bluetooth HID rows but retain USB connections")
check(bluetoothStore.deviceStores[2].detectedDevice?.connectionLabel == "Bluetooth")
check(bluetoothStore.deviceStores[2].dpiMinimum == 100 && bluetoothStore.deviceStores[0].dpiMinimum == 1)
check(bluetoothStore.deviceStores[2].capabilities.poll_rates.isEmpty)
check(!bluetoothStore.deviceStores[2].capabilities.scroll)
let priorUSBCommands = commands()
bluetoothStore.deviceStores[3].setDpi("1600")
settle(bluetoothStore)
check(fakeBluetooth.calls.count == 1 && fakeBluetooth.calls[0].0 == bleSecondID && fakeBluetooth.calls[0].1.first == "dpi")
check(commands() == priorUSBCommands, "Bluetooth commands must not reach the USB core")
fakeBluetooth.failure = "The selected Bluetooth device disconnected"
bluetoothStore.deviceStores[2].setDpi("800")
settle(bluetoothStore)
check(bluetoothStore.deviceStores[2].commandError?.contains("disconnected") == true)
check(fakeBluetooth.calls.last?.0 == bleFirstID, "Never redirect a disconnected device's commands")

fakeBluetooth.scan = BluetoothScan(error: "Bluetooth access denied")
bluetoothStore.checkForDeviceChanges()
settle(bluetoothStore)
check(bluetoothStore.bluetoothError == "Bluetooth access denied" && bluetoothStore.detectionError == nil)
check(bluetoothStore.deviceStores.contains { $0.id == "kbd-1" }, "Bluetooth permission denial must keep USB devices usable")
fakeBluetooth.scan = BluetoothScan(devices: [fakeBluetoothDevice(bleFirstID)])
bluetoothStore.checkForDeviceChanges()
settle(bluetoothStore)
check(bluetoothStore.bluetoothError == nil && bluetoothStore.deviceStores.last?.id == bleFirstID)

print("Passed: Bluetooth packet framing, response correlation, DPI token/axis/marker preservation, invalid data rejection, exact device targeting, connection labels, duplicate handling, permission recovery and USB isolation. No Bluetooth hardware accessed.")
