// Output: paste the text into the focused app, and the small status pill (HUD).
import Carbon  // IsSecureEventInputEnabled
import Cocoa

// MARK: - Paste into the focused app

/// nil = Cmd+V sent; otherwise why it can't be, and the text should stay on the clipboard.
func pasteBlocker() -> String? {
    if !AXIsProcessTrusted() { return "no accessibility" }
    // A password field has secure input on: macOS drops synthetic keys, the text would be lost.
    if IsSecureEventInputEnabled() { return "secure input is on" }
    return nil
}

func leaveOnClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func paste(_ text: String) {
    let pb = NSPasteboard.general
    // Keep whatever the user had on the clipboard and put it back after the paste.
    let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
        item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
    }
    pb.clearContents()
    pb.setString(text, forType: .string)
    pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))  // clipboard managers skip it
    let ours = pb.changeCount

    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)  // 9 = V
    let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
    down?.flags = .maskCommand; up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        guard pb.changeCount == ours else { return }  // user copied something new meanwhile
        pb.clearContents()
        let items = saved.map { pairs -> NSPasteboardItem in
            let it = NSPasteboardItem(); pairs.forEach { it.setData($0.1, forType: $0.0) }; return it
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}

// MARK: - HUD: small pill at the bottom of the screen, never takes focus

final class HUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 170, height: 34),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let bg = NSVisualEffectView(frame: panel.contentView!.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.material = .hudWindow; bg.state = .active; bg.wantsLayer = true; bg.layer?.cornerRadius = 17
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 8, width: 170, height: 18)
        bg.addSubview(label)
        panel.contentView = bg
    }

    func show(_ text: String, color: NSColor = .labelColor) {
        label.stringValue = text; label.textColor = color
        let w = max(170, ceil(label.attributedStringValue.size().width) + 36)
        label.frame = NSRect(x: 0, y: 8, width: w, height: 18)
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: screen.midX - w / 2, y: screen.minY + 60, width: w, height: 34), display: true)
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
