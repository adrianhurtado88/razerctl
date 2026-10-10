// Optional offscreen renders of production SwiftUI views with fixture data.
// No app windows are shown, and no real HID, shortcuts or input are used.
if let renderPath = ProcessInfo.processInfo.environment["WIDGET_RENDER_DIR"] {
    let output = URL(fileURLWithPath: renderPath)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var fixture = fixtureDevice("render-keyboard", kind: "keyboard", name: "Razer Ornata V3 X",
                                effects: ["none", "static", "spectrum", "breath", "breath-single"],
                                settings: ["keyboard":"Razer Ornata V3 X", "keyboard_fw":"2.0", "kbd_brightness":"255", "gaming_mode":"0", "macro_recording":"0"])
    var capabilities = fixture["capabilities"] as! [String: Any]
    capabilities["gaming_mode"] = true; capabilities["macro_indicator"] = true
    fixture["capabilities"] = capabilities
    try writeDevices([fixture])
    let renderStore = Store(readKeyboardLocks: { _ in [1:false,2:false,3:false] }, secureInputStatus: { false })
    renderStore.refresh(); settle(renderStore)
    renderStore.startKeyboardPrivacyMonitoring()
    let keyboard = renderStore.deviceStores[0]
    keyboard.kbdEffect = "static"
    func render(_ name: String) throws {
        let host = NSHostingView(rootView: ContentView().environmentObject(renderStore))
        host.appearance = NSAppearance(named: .darkAqua)
        host.setFrameSize(NSSize(width: 360, height: 800))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let size = host.fittingSize
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        if name == "two-devices-expanded" { check(size.height <= 700, "Expanded keyboard and mouse must use a bounded scroll area") }
        print("Rendered \(name): \(size.width) × \(size.height) points, \(bitmap.pixelsWide) × \(bitmap.pixelsHigh) pixels")
    }
    try render("collapsed")
    keyboard.keyboardControls.expanded = true
    try render("expanded")
    keyboard.keyboardControls.apply(settings: [:], gamingAvailable: false, macroAvailable: false)
    try render("unavailable")
    keyboard.keyboardControls.apply(settings: ["gaming_mode":"0", "macro_recording":"0"], gamingAvailable: true, macroAvailable: true)
    keyboard.keyboardControls.setGaming(true)
    settle(renderStore) // The CLI stub returns no state, so confirmation fails.
    try render("mode-error")
    shortcuts.actionError = nil
    let editor = KeyboardShortcutsWindow(store: shortcuts, indicators: keyboard.keyboardControls, createMacro: true)
    if let host = editor.window?.contentView {
        host.setFrameSize(NSSize(width: 700, height: 620))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("macro-editor.png"))
    }
    try writeDevices([fixture, mouseFixture])
    renderStore.refresh(); settle(renderStore)
    try render("two-devices-expanded")
    check(renderStore.deviceStores.count == 2, "Two-device expanded preview needs both fixtures")
    renderStore.stopKeyboardPrivacyMonitoring()
    renderStore.shutdownKeyboardControls()
}
