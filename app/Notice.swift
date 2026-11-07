// Every short message the HUD can show besides the recording meter, in one place
// (the app flashes them; `--demo` shows each one for screenshots).
import Cocoa

enum Notice: String, CaseIterable {
    case loading, noModel, nothing, noField, copied, password, micFailed, micStuck, failed

    var text: String {
        switch self {
        case .loading: "Model is still loading…"
        case .noModel: "No model yet: open Settings → Models"
        case .nothing: "Didn't catch that"
        case .noField: "No text field in focus: copied, press ⌘V"
        case .copied: "Copied: press ⌘V (allow Accessibility to paste)"
        case .password: "Password field: copied, press ⌘V"
        case .micFailed: "Microphone isn't working"
        case .micStuck: "Microphone not responding"
        case .failed: "Couldn't transcribe, see Logs"
        }
    }
    var symbol: String? {
        switch self {
        case .loading: nil
        case .noModel: "arrow.down.circle"
        case .nothing: "ear"
        case .copied, .noField: "doc.on.clipboard"
        case .password: "lock.fill"
        case .micFailed, .micStuck: "mic.slash"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
    /// Blue = the text is safe, act on it; orange = needs setup; red = something broke.
    var tint: NSColor {
        switch self {
        case .loading, .nothing: .secondaryLabelColor
        case .copied, .noField, .password: .systemBlue
        case .noModel, .failed: .systemOrange
        case .micFailed, .micStuck: .systemRed
        }
    }
    var seconds: Double {
        switch self {
        case .nothing: 1.5
        case .loading: 2
        case .copied, .noField, .password: 4
        default: 3
        }
    }

    func show(on hud: HUD) { hud.show(text, symbol: symbol, tint: tint, busy: self == .loading) }
}
