// Local Dictation: menu bar app. Hold the hotkey -> record the mic; release -> the local speech-to-text server
// transcribes -> the text is pasted into the focused field (clipboard + Cmd+V, clipboard restored).
// Audio never leaves the machine: the server listens on 127.0.0.1 only.
import AVFoundation
import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var status: NSStatusItem!
    var stateLine: NSMenuItem!
    var hintLine: NSMenuItem!
    var micItem: NSMenuItem!
    var lastItem: NSMenuItem!
    var axItem: NSMenuItem!
    var modelItem: NSMenuItem!
    let recorder = Recorder()
    let hud = HUD()
    let models = ModelStore.shared
    var server: Process?
    var hotkeyDown = false
    var recording = false
    var cancelled = false
    var pressedAt = Date()
    var busy = 0
    var lastText: String?  // last dictation, kept so a paste that went nowhere can be recovered
    var quitting = false
    var ready: String?  // "Ready · <model>" once the server answers /health
    var monitors: [Any] = []
    var axOverride: Bool?  // --demo only: pretend Accessibility is granted or missing
    var axTrusted: Bool { axOverride ?? AXIsProcessTrusted() }
    var demoNoModel = false  // --demo only: pretend no model is installed

    static func main() {
        let app = NSApplication.shared
        let d = AppDelegate()
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        prepareSupportFiles()
        if CommandLine.arguments.contains("--probe-mic") { probeMic(); return }
        if CommandLine.arguments.contains("--probe-hud") { probeMic(seconds: 4, hud: true); return }
        if let i = CommandLine.arguments.firstIndex(of: "--demo") {
            demo(CommandLine.arguments.dropFirst(i + 1).first ?? ""); return
        }
        if CommandLine.arguments.contains("--probe-focus") {  // log what has focus now, for tuning focusedField()
            let (f, desc) = focusedField()
            log("probe-focus: \(f) \(desc), app \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--probe-deliver") {  // paste a test text into the focused app
            deliver(CommandLine.arguments.dropFirst(i + 1).first ?? "Local Dictation test")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }  // let the clipboard restore and HUD run
            return
        }
        if CommandLine.arguments.contains("--check-access") {  // no prompt, no server: for checking a fresh build
            log("check-access: accessibility trusted: \(AXIsProcessTrusted()), post events: \(CGPreflightPostEventAccess())")
            exit(0)
        }
        buildMenu()
        models.onActiveChange = { [weak self] in self?.restartServer() }
        startServer()
        AVCaptureDevice.requestAccess(for: .audio) { ok in log("mic access: \(ok)") }
        // Accessibility is needed both to see the hotkey in other apps and to send Cmd+V.
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        log("accessibility trusted: \(trusted)")
        installMonitors()
        if !trusted { watchTrust() }
        if !models.activeInstalled { SettingsWindow.shared.show(.models) }  // first run: pick a model
    }

    func applicationWillTerminate(_ n: Notification) {
        quitting = true
        server?.terminate()
        models.cancelAll()
    }

    // Opening the app again (Finder, Spotlight) while it runs: show Settings, there is no other window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        SettingsWindow.shared.show()
        return false
    }

    func installMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in self?.handle(e) },
            NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in self?.handle(e); return e },
        ].compactMap { $0 }
    }

    // A global monitor added before the user grants Accessibility stays deaf: re-arm it once granted.
    func watchTrust() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self, AXIsProcessTrusted() else { return }
            t.invalidate()
            log("accessibility granted")
            self.installMonitors()
            if !self.recording && self.busy == 0 { self.setIdle() }
        }
    }

    // `--probe-mic`: record 1 s from the chosen mic, log device, samples and peak, exit.
    // `--probe-hud`: the same for 4 s with the recording HUD on screen (to see the level meter).
    // Checks recording without the hotkey, the server or pasting anything.
    func probeMic(seconds: Double = 1, hud showHUD: Bool = false) {
        if showHUD { hud.showRecording { [recorder] in recorder.level } }
        let pick = resolveInput()
        log("probe: pref=\(inputPref), mic access=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        log("probe: inputs: " + inputDevices().map { "\($0.name) [\($0.uid)]" }.joined(separator: ", ") + "; system input: \(systemInputName())")
        audio.async {
            do {
                try self.recorder.start(uid: pick.device?.uid)
                Thread.sleep(forTimeInterval: seconds)
                let s = self.recorder.stop()
                log(String(format: "probe: record from: %@, %d samples, peak %.4f", describe(pick), s.count, s.map { abs($0) }.max() ?? 0))
                exit(0)
            } catch { log("probe: record failed: \(error.localizedDescription)"); exit(1) }
        }
    }

    // MARK: hotkey

    func handle(_ e: NSEvent) {
        let hotkey = Pref.hotkey  // read live: a change in Settings applies to the next press
        if e.type == .keyDown {
            // Another key while the hotkey is held = a shortcut (e.g. Option+arrow), not dictation.
            if hotkeyDown && recording { cancelled = true; log("cancelled by key \(e.keyCode)") }
            return
        }
        guard e.keyCode == hotkey.keyCode else { return }
        let down = (e.modifierFlags.rawValue & hotkey.mask) != 0
        if down == hotkeyDown { return }
        hotkeyDown = down
        down ? begin() : end()
    }

    // Audio start/stop never run on the main thread: if CoreAudio stalls, the menu and HUD stay alive.
    let audio = DispatchQueue(label: "localdictation.audio")
    var audioPending = 0        // ops queued on `audio`, main thread only
    var audioProgress = Date()  // last time one of them finished

    /// Runs `work` on the audio queue, then `done` on main. Refuses (false) if the queue looks hung.
    func onAudio<T>(_ work: @escaping () -> T, _ done: @escaping (T) -> Void) -> Bool {
        if audioPending > 0 && Date().timeIntervalSince(audioProgress) > 3 { return false }
        if audioPending == 0 { audioProgress = Date() }
        audioPending += 1
        audio.async {
            let r = work()
            DispatchQueue.main.async { self.audioPending -= 1; self.audioProgress = Date(); done(r) }
        }
        return true
    }

    func begin() {
        guard !recording else { return }
        guard ready != nil else {  // nothing to transcribe with: say why instead of recording into the void
            flash(models.activeInstalled ? .loading : .noModel)
            return
        }
        cancelled = false
        pressedAt = Date()
        recording = true
        setIcon("mic.fill", "Recording…", tint: .systemRed)
        hud.showRecording { [recorder] in recorder.level }
        let started = onAudio({ () -> (note: String?, error: Error?) in
            let pick = resolveInput()
            do {
                try self.recorder.start(uid: pick.device?.uid)
                log("record from: \(describe(pick))")
                return (nil, nil)
            } catch {
                // The chosen mic refused: record from the system input rather than not at all.
                log("record failed on \(describe(pick)): \(error.localizedDescription); retrying with system input")
                do {
                    try self.recorder.start(uid: nil)
                    log("record from: system input \(systemInputName()) (after error)")
                    return ("Recording from system input: \(pick.device?.name ?? "chosen mic") failed", nil)
                } catch {
                    log("record failed on system input: \(error.localizedDescription)")
                    return (nil, error)
                }
            }
        }) { r in
            if let e = r.error {
                self.recording = false
                self.setIcon("exclamationmark.triangle", "Microphone: \(e.localizedDescription)")
                self.flash(.micFailed)
            } else if let note = r.note, self.recording {
                self.stateLine.title = note  // the meter stays: recording works, just from another mic
            }
        }
        if !started {
            log("record refused: audio queue busy for \(Int(Date().timeIntervalSince(audioProgress)))s")
            recording = false
            setIcon("exclamationmark.triangle", "Microphone not responding: restart Local Dictation")
            flash(.micStuck)
        }
    }

    func end() {
        guard recording else { return }
        recording = false
        let held = Date().timeIntervalSince(pressedAt)
        _ = onAudio({ self.recorder.stop() }) { samples in
            if self.cancelled || held < 0.3 || samples.count < 16000 / 4 {
                self.setIdle(); return
            }
            self.transcribe(samples)
        }
    }

    /// HUD notice that stays up for its duration even if the state goes idle meanwhile.
    var hudUntil = Date.distantPast
    func flash(_ n: Notice) {
        n.show(on: hud)
        hudUntil = Date() + n.seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + n.seconds) { self.setIdle() }
    }

    // MARK: speech to text

    func transcribe(_ samples: [Float]) {
        busy += 1
        setIcon("ellipsis.circle", "Transcribing…")
        hud.show("Transcribing…", busy: true)  // until the server answers
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/transcribe")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.setValue(Pref.language, forHTTPHeaderField: "X-Language")
        if Pref.saveHistory { req.setValue(historyDir, forHTTPHeaderField: "X-History-Dir") }
        req.httpBody = wav(samples)
        let t0 = Date()
        URLSession.shared.dataTask(with: req) { data, _, err in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let text = (obj?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self.busy -= 1
                if let err = err ?? (obj?["error"] as? String).map({ NSError(domain: "server", code: 0, userInfo: [NSLocalizedDescriptionKey: $0]) }) {
                    log("asr error: \(err.localizedDescription)")
                    self.setIcon("exclamationmark.triangle", "Transcription failed, see logs")
                    self.flash(.failed)
                    return
                }
                log(String(format: "asr %.2fs, %d chars", Date().timeIntervalSince(t0), text.count))
                if text.isEmpty { self.flash(.nothing); return }
                self.deliver(text)
            }
        }.resume()
    }

    /// Put the text where the user is now, or on the clipboard if it can't go there.
    func deliver(_ text: String) {
        lastText = text
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        if let reason = pasteBlocker() {
            // Can't send Cmd+V: leave the text on the clipboard instead of losing it.
            log("paste: failed (\(reason)), \(text.count) chars left on clipboard, app \(app)")
            leaveOnClipboard(text)
            flash(reason == "no accessibility" ? .copied : .password)
            return
        }
        // The user may have switched windows or clicked away while speaking.
        let (focus, what) = focusedField()
        switch focus {
        case .notText:
            log("paste: no text field (\(what)), \(text.count) chars left on clipboard, app \(app)")
            leaveOnClipboard(text)
            flash(.noField)
        case .text, .unknown:
            paste(text + " ", restore: focus == .text)  // trailing space so consecutive dictations join cleanly
            log("paste: ok into \(what)\(focus == .unknown ? ", kept on clipboard" : ""), \(text.count) chars, app \(app)")
            setIdle()
        }
    }

    func startServer() {
        guard let m = modelInfo(models.active), models.activeInstalled else {
            ready = nil
            setIcon("arrow.down.circle", "No model yet: download one in Settings")
            return
        }
        setIcon("mic", "Loading \(m.name)…")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: root + "/.venv/bin/python")
        p.arguments = [root + "/server/asr_server.py", "--engine", m.engine, "--repo", m.repo,
                       "--terms", dictionaryPath, "--port", String(port)]
        p.currentDirectoryURL = URL(fileURLWithPath: root)
        let out = logDir + "/server.log"
        FileManager.default.createFile(atPath: out, contents: nil)
        if let h = FileHandle(forWritingAtPath: out) { p.standardOutput = h; p.standardError = h }
        p.terminationHandler = { [weak self] proc in
            log("server exited \(proc.terminationStatus)")
            DispatchQueue.main.async {
                guard let self, !self.quitting, self.server === proc else { return }
                self.ready = nil
                if proc.terminationStatus == 3 {  // port taken by another program: restarting won't help
                    self.setIcon("exclamationmark.triangle", "Port \(port) is used by another program"); return
                }
                self.setIcon("exclamationmark.triangle", "Recognition crashed, restarting…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if self.server === proc { self.startServer() } }
            }
        }
        do { try p.run(); server = p } catch { log("server start failed: \(error)") }
        waitReady(p, name: m.name, attempt: 0)
    }

    func waitReady(_ proc: Process, name: String, attempt: Int) {
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)/health")!) { data, _, _ in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                guard self.server === proc else { return }  // replaced by a restart meanwhile
                if obj?["model"] != nil {
                    self.ready = "Ready · \(name)"
                    log("server ready: \(name)")
                    if !self.recording && self.busy == 0 { self.setIdle() }
                } else if proc.isRunning && attempt < 180 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.waitReady(proc, name: name, attempt: attempt + 1) }
                } else { self.setIcon("exclamationmark.triangle", "Recognition didn't start, see logs") }
            }
        }.resume()
    }

    func restartServer() {
        let old = server
        server = nil
        old?.terminate(); old?.waitUntilExit()  // free the port before the new one binds it
        ready = nil
        startServer()
    }

    // MARK: menu

    func buildMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false  // isEnabled below is set by hand
        stateLine = NSMenuItem(title: "", action: nil, keyEquivalent: ""); stateLine.isEnabled = false
        menu.addItem(stateLine)
        hintLine = NSMenuItem(title: "", action: nil, keyEquivalent: ""); hintLine.isEnabled = false
        menu.addItem(hintLine)
        axItem = item("⚠︎ Grant Accessibility Access…") { openPrivacyPane("Privacy_Accessibility") }  // only while missing
        menu.addItem(axItem)
        modelItem = item("⬇︎ Download a Model…") { SettingsWindow.shared.show(.models) }  // only while none is installed
        menu.addItem(modelItem)
        lastItem = item("Copy Last Dictation") { [weak self] in self?.lastText.map(leaveOnClipboard) }
        menu.addItem(lastItem)
        menu.addItem(.separator())
        micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micItem.submenu = NSMenu()
        menu.addItem(micItem)
        menu.delegate = self  // device list is rebuilt on every open: headphones come and go
        menu.addItem(item("Edit Dictionary…") { NSWorkspace.shared.open(URL(fileURLWithPath: dictionaryPath)) })
        menu.addItem(.separator())
        let settings = item("Settings…") { SettingsWindow.shared.show() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(item("Show Logs") { NSWorkspace.shared.open(URL(fileURLWithPath: logDir)) })
        menu.addItem(item("Restart Recognition") { [weak self] in self?.restartServer() })
        menu.addItem(.separator())
        let quit = item("Quit Local Dictation") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        status.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === status.menu else { return }
        axItem.isHidden = axTrusted
        modelItem.isHidden = models.activeInstalled && !demoNoModel
        lastItem.isEnabled = lastText != nil
        hintLine.title = "Hold \(Pref.hotkey.short) and speak"
        let pref = inputPref, pick = resolveInput(pref)
        micItem.title = "Microphone: \(pick.device?.name ?? systemInputName())" + (pick.fallback ? " (fallback)" : "")
        let sub = micItem.submenu!
        sub.removeAllItems()
        func add(_ title: String, _ value: String?, _ state: NSControl.StateValue) {
            let it = NSMenuItem(title: title, action: value == nil ? nil : #selector(pickInput(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = value; it.state = state; it.isEnabled = value != nil
            sub.addItem(it)
        }
        add("System Default (\(systemInputName()))", "system", pref == "system" ? .on : .off)
        sub.addItem(.separator())
        for d in inputDevices() {
            let chosen = pref == (d.builtIn ? "builtin" : d.uid)
            // .mixed = not chosen, but recording goes here because the chosen one is missing.
            add(d.name, d.builtIn ? "builtin" : d.uid, chosen ? .on : (pick.fallback && pick.device?.uid == d.uid ? .mixed : .off))
        }
        if pick.fallback && pref != "builtin" {
            add("\(UserDefaults.standard.string(forKey: "input_device_name") ?? pref) (not connected)", nil, .on)
        }
    }

    @objc func pickInput(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        inputPref = value
        UserDefaults.standard.set(sender.title, forKey: "input_device_name")  // shown while it is unplugged
        log("input device -> \(value) (\(sender.title))")
    }

    var actions: [() -> Void] = []
    func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        actions.append(action)
        let it = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        it.target = self; it.tag = actions.count - 1
        return it
    }
    @objc func run(_ sender: NSMenuItem) { actions[sender.tag]() }

    func setIdle() {
        if !recording && busy == 0 && Date() >= hudUntil { hud.hide() }
        if !axTrusted { setIcon("mic.slash", "Needs Accessibility access"); return }
        if let ready { setIcon("mic", ready) }
        else if !models.activeInstalled { setIcon("arrow.down.circle", "No model yet: download one in Settings") }
        else { setIcon("mic", "Loading model…") }
    }

    func setIcon(_ symbol: String, _ line: String?, tint: NSColor? = nil) {
        var img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Local Dictation")
        if let tint, let base = img {
            img = base.withSymbolConfiguration(.init(paletteColors: [tint]))
            img?.isTemplate = false
        } else { img?.isTemplate = true }
        status?.button?.image = img  // nil in probe runs: no menu bar item
        if let line { stateLine?.title = line }
    }
}
