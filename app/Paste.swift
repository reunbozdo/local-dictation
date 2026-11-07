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

/// Live mic meter: the last few tenths of a second of loudness as bars scrolling right to left.
final class LevelView: NSView {
    static let bars = 18
    private(set) var levels = [CGFloat](repeating: 0, count: LevelView.bars)
    var color = NSColor.systemRed

    func push(_ level: CGFloat) {
        // Fast attack, slower release: speech reads as a lively wave, not flicker.
        let v = level > (levels.last ?? 0) ? level : max(level, (levels.last ?? 0) * 0.6)
        levels.removeFirst(); levels.append(v)
        needsDisplay = true
    }

    func reset() { levels = .init(repeating: 0, count: Self.bars); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let w: CGFloat = 3, gap: CGFloat = 2, minH: CGFloat = 3
        color.setFill()
        for (i, l) in levels.enumerated() {
            let h = minH + (bounds.height - minH) * l
            let r = NSRect(x: CGFloat(i) * (w + gap), y: (bounds.height - h) / 2, width: w, height: h)
            NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
        }
    }
}

final class HUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let meter = LevelView()
    private let clock = NSTextField(labelWithString: "")
    private var tick: Timer?

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
        label.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        clock.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        clock.textColor = .secondaryLabelColor
        clock.alignment = .right
        [label, icon, spinner, meter, clock].forEach(bg.addSubview)
        panel.contentView = bg
    }

    private func place(width w: CGFloat) {
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: screen.midX - w / 2, y: screen.minY + 60, width: w, height: 34), display: true)
        }
        panel.orderFrontRegardless()
    }

    /// A status line: an SF Symbol in `tint`, or a spinner while something is in progress, then the text.
    func show(_ text: String, symbol: String? = nil, tint: NSColor = .secondaryLabelColor, busy: Bool = false) {
        stopMeter()
        meter.isHidden = true; clock.isHidden = true; label.isHidden = false
        icon.isHidden = symbol == nil || busy
        spinner.isHidden = !busy
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        if let symbol, !busy {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
            icon.contentTintColor = tint
        }
        let glyph = symbol != nil || busy
        icon.frame = NSRect(x: 16, y: 8, width: 18, height: 18)
        spinner.frame = NSRect(x: 17, y: 9, width: 16, height: 16)
        label.stringValue = text
        label.textColor = .labelColor
        let x: CGFloat = glyph ? 42 : 18
        let textW = min(ceil(label.attributedStringValue.size().width) + 4, 520)
        label.frame = NSRect(x: x, y: 8, width: textW, height: 18)
        place(width: x + textW + 16)
    }

    /// Recording: level bars fed from `level` (0...1) and the elapsed time, refreshed 20x a second.
    func showRecording(level: @escaping () -> Float) {
        stopMeter()
        label.isHidden = true; icon.isHidden = true; spinner.isHidden = true; spinner.stopAnimation(nil)
        meter.isHidden = false; clock.isHidden = false
        meter.reset()
        let barsW = CGFloat(LevelView.bars) * 5 - 2
        meter.frame = NSRect(x: 18, y: 8, width: barsW, height: 18)
        clock.frame = NSRect(x: 18 + barsW + 8, y: 8, width: 42, height: 18)
        clock.stringValue = "0:00"
        place(width: 18 + barsW + 8 + 42 + 16)
        let start = Date()
        tick = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.meter.push(CGFloat(level()))
            let s = Int(Date().timeIntervalSince(start))
            self.clock.stringValue = String(format: "%d:%02d", s / 60, s % 60)
        }
    }

    private func stopMeter() { tick?.invalidate(); tick = nil }

    func hide() { stopMeter(); panel.orderOut(nil) }
}
