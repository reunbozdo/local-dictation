// `--demo <state>`: show one UI state and stay up, for screenshots and design review.
// Records nothing, pastes nothing, starts no server.
// States: recording, transcribing, any Notice case (noModel, copied, …), menu-ready, menu-loading,
// menu-nomodel, menu-noax, settings-general, settings-models.
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
