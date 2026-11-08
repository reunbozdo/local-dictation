// `--demo <state>`: show one UI state and stay up, for screenshots and design review.
// Records nothing, pastes nothing, starts no server.
// States: recording, transcribing, any Notice case (noModel, copied, …), menu-ready, menu-loading,
// menu-nomodel, menu-noax, settings-general, settings-models.
import Carbon
import Cocoa

extension AppDelegate {
    func demo(_ state: String) {
        buildMenu()
        setIdle()
        if let n = Notice(rawValue: state) { n.show(on: hud); return }
        let model = modelInfo(models.active)?.name ?? "Whisper Large v3"
        switch state {
        case "recording":
            setIcon("mic.fill", "Recording…", tint: .systemRed)
            hud.showRecording {  // speech-like wobble instead of the mic
                let t = Date().timeIntervalSinceReferenceDate
                return Float(max(0, min(1, 0.5 + 0.4 * sin(t * 7) * sin(t * 1.7) + .random(in: -0.15...0.15))))
            }
        case "transcribing":
            setIcon("ellipsis.circle", "Transcribing…")
            hud.show("Transcribing…", busy: true)
        case "settings-general": SettingsWindow.shared.show(.general)
        case "settings-models": SettingsWindow.shared.show(.models)
        case "menu-ready": axOverride = true; ready = "Ready · \(model)"; setIdle(); openMenu()
        case "menu-loading": axOverride = true; setIcon("mic", "Loading \(model)…"); openMenu()
        case "menu-nomodel": axOverride = true; demoNoModel = true; setIcon("arrow.down.circle", "No model yet: download one in Settings"); openMenu()
        case "menu-noax": axOverride = false; setIdle(); openMenu()
        default: log("demo: unknown state \(state)"); exit(2)
        }
    }

    private func openMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.status.button?.performClick(nil) }
    }
}

// `--probe-keys "d 0.1 u 3 d 0.1 u"`: press (d) and release (u) the chosen hotkey with pauses in
// seconds, or click the HUD's "stop" / "cancel" button, as synthetic key events. The running app sees them like real presses: a test of the
// hold / tap / toggle logic without a human at the keyboard.
func probeKeys(_ script: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    let key = Pref.hotkey
    for step in script.split(separator: " ") {
        if let s = Double(step) { Thread.sleep(forTimeInterval: s); continue }
        if step == "stop" || step == "cancel" {  // click a HUD button (geometry as in HUD.showRecording)
            guard let vis = NSScreen.main?.visibleFrame, let full = NSScreen.screens.first?.frame else { continue }
            let width: CGFloat = 202
            let x = vis.midX - width / 2 + (step == "stop" ? 184 : 19)
            let p = CGPoint(x: x, y: full.height - (vis.minY + 60 + 17))
            for t in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            log("probe-keys: click \(step)"); continue
        }
        let down = step == "d"
        let e: CGEvent?
        if key == .combo {
            let c = Combo.saved
            e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(c.keyCode), keyDown: down)
            var f: CGEventFlags = []
            if c.mods & UInt32(cmdKey) != 0 { f.insert(.maskCommand) }
            if c.mods & UInt32(optionKey) != 0 { f.insert(.maskAlternate) }
            if c.mods & UInt32(controlKey) != 0 { f.insert(.maskControl) }
            if c.mods & UInt32(shiftKey) != 0 { f.insert(.maskShift) }
            e?.flags = f
        } else {
            e = CGEvent(keyboardEventSource: src, virtualKey: key.keyCode, keyDown: down)
            let generic: CGEventFlags = switch key {
            case .rightOption: .maskAlternate
            case .rightCommand: .maskCommand
            case .rightControl: .maskControl
            case .rightShift: .maskShift
            default: .maskSecondaryFn
            }
            e?.flags = down ? CGEventFlags(rawValue: generic.rawValue | UInt64(key.mask)) : []
        }
        e?.post(tap: .cghidEventTap)
        log("probe-keys: \(step)")
    }
}
