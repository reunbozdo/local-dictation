// Settings window (SwiftUI): General (shortcut, microphone, dictionary, history, permissions)
// and Models (spoken language + local models ranked for it).
import AVFoundation
import Combine
import ServiceManagement
import SwiftUI

enum SettingsTab: Int { case general, models }

/// Native preferences window: tab icons in the toolbar (NSTabViewController .toolbar style),
/// each tab a SwiftUI form. SwiftUI's TabView draws a boxed segmented control here instead.
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let tabs = NSTabViewController()

    func show(_ tab: SettingsTab? = nil) {
        if window == nil {
            tabs.tabStyle = .toolbar
            tabs.addTabViewItem(item("General", "gearshape", GeneralView()))
            tabs.addTabViewItem(item("Models", "waveform", ModelsView()))
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.toolbarStyle = .preference
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        if let tab { tabs.selectedTabViewItemIndex = tab.rawValue }
        // A menu bar app has no Dock icon; show one while Settings is open so it can be Cmd-Tabbed to.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func item<V: View>(_ label: String, _ symbol: String, _ view: V) -> NSTabViewItem {
        let host = NSHostingController(rootView: view.frame(width: 580, height: 620))
        host.title = label  // the window title follows the selected tab
        host.preferredContentSize = NSSize(width: 580, height: 620)  // NSTabViewController sizes the window from this
        let it = NSTabViewItem(viewController: host)
        it.label = label
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return it
    }

    func windowWillClose(_ n: Notification) { NSApp.setActivationPolicy(.accessory) }
}

// MARK: - General

struct GeneralView: View {
    @AppStorage("hotkey") private var hotkey: Hotkey = .rightOption
    @AppStorage(inputPrefKey) private var input = "builtin"
    @AppStorage("save_history") private var saveHistory = false
    @State private var devices = inputDevices()
    @State private var micOK = false
    @State private var axOK = false
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !micOK || !axOK {
                Section {
                    permissionRow("Microphone", ok: micOK, why: "to hear you while the key is held") {
                        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                            AVCaptureDevice.requestAccess(for: .audio) { _ in }
                        } else { openPrivacyPane("Privacy_Microphone") }
                    }
                    permissionRow("Accessibility", ok: axOK, why: "to notice the key in other apps and paste the text") {
                        openPrivacyPane("Privacy_Accessibility")
                    }
                } header: { Text("Permissions needed") }
            }

            Section {
                Picker("Hold to dictate", selection: $hotkey) {
                    ForEach(Hotkey.allCases) { Text($0.title).tag($0) }
                }
                Text(hotkey == .fn
                     ? "Hold Fn, speak, release. Set System Settings → Keyboard → “Press 🌐 key to” → “Do Nothing”, or macOS reacts to it too."
                     : "Hold the key, speak, release: the text is pasted where the cursor is. A quick tap, or using the key in a shortcut, does nothing.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Shortcut") }

            Section {
                Picker("Record from", selection: $input) {
                    Text("System default (\(systemInputName()))").tag("system")
                    Divider()
                    ForEach(devices, id: \.uid) { d in
                        Text(d.name).tag(d.builtIn ? "builtin" : d.uid)
                    }
                    if input != "system" && input != "builtin" && !devices.contains(where: { $0.uid == input }) {
                        Text("\(UserDefaults.standard.string(forKey: "input_device_name") ?? input) (not connected)").tag(input)
                    }
                }
                .onChange(of: input) { _, v in
                    if let d = devices.first(where: { $0.uid == v }) { UserDefaults.standard.set(d.name, forKey: "input_device_name") }
                }
                Text("Only Local Dictation uses this choice; the system input stays as it is. If the chosen mic is unplugged, Local Dictation records from the built-in one.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Microphone") }

            Section {
                LabeledContent("Custom words") {
                    Button("Edit Dictionary…") { NSWorkspace.shared.open(URL(fileURLWithPath: dictionaryPath)) }
                }
                Text("Names, product terms and spellings the model should know. One per line, or “heard => written” for fixes. Changes apply to the next dictation.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Dictionary") }

            Section {
                Toggle("Keep recent recordings", isOn: $saveHistory)
                HStack {
                    Text("Stores the last 200 dictations (audio and text) on this Mac, to tune the dictionary or compare models. Off by default.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(URL(fileURLWithPath: historyDir))
                    }
                }
            } header: { Text("History") }

            Section {
                Toggle("Launch at login", isOn: $loginOn)
                    .onChange(of: loginOn) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { log("login item: \(error)") }
                        loginOn = SMAppService.mainApp.status == .enabled
                    }
                if micOK && axOK {
                    LabeledContent("Permissions") { Text("Microphone and Accessibility granted").foregroundStyle(.secondary) }
                }
            } header: { Text("System") }
        }
        .formStyle(.grouped)
        .onAppear(perform: update)
        .onReceive(tick) { _ in update() }  // headphones come and go, permissions get granted
    }

    private func update() {
        devices = inputDevices()
        micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axOK = AXIsProcessTrusted()
    }

    private func permissionRow(_ name: String, ok: Bool, why: String, fix: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading) {
                Text(name)
                Text("Needed \(why).").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { Button("Open Settings…", action: fix) }
        }
    }
}

// MARK: - Models

struct ModelsView: View {
    @ObservedObject private var store = ModelStore.shared
    @AppStorage("language") private var language = "auto"
    @State private var confirmDelete: ModelInfo?

    private var groups: [(title: String, models: [ModelInfo])] {
        let supported = catalog.filter { $0.supports(language) }
        let lang = languageName(language)
        return [
            (language == "auto" ? "Recommended" : "Recommended for \(lang)", supported.filter { $0.isRecommended(for: language) }),
            ("Other models", supported.filter { !$0.isRecommended(for: language) }),
            ("Don't support \(lang)", catalog.filter { !$0.supports(language) }),
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        Form {
            Section {
                Picker("Spoken language", selection: $language) {
                    Text(languageName("auto")).tag("auto")
                    Divider()
                    ForEach(languageCodes.sorted { languageName($0) < languageName($1) }, id: \.self) {
                        Text(languageName($0)).tag($0)
                    }
                }
                Text(language == "auto"
                     ? "Auto-detect works, but naming your language is faster and avoids mistakes on short phrases."
                     : "Models are ranked for \(languageName(language)). Words in other languages inside your speech are still recognised by Whisper.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Language") } footer: {
                Text("Everything runs on this Mac; audio is never uploaded. Models are downloaded once from Hugging Face.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.title) { g in
                Section {
                    ForEach(g.models) { m in
                        ModelRow(model: m, state: store.states[m.id] ?? .missing, active: store.active == m.id,
                                 unsupported: !m.supports(language), onDelete: { confirmDelete = m })
                    }
                } header: { Text(g.title) }
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refresh() }
        .confirmationDialog("Delete \(confirmDelete?.name ?? "")?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete \(confirmDelete?.sizeText ?? "")", role: .destructive) {
                if let m = confirmDelete { store.delete(m) }
            }
        } message: { Text("You can download it again later.") }
    }
}

struct ModelRow: View {
    let model: ModelInfo
    let state: ModelState
    let active: Bool
    let unsupported: Bool
    let onDelete: () -> Void
    private var store: ModelStore { .shared }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name).font(.headline)
                    if active && state == .installed { Badge(text: "In use", color: .accentColor) }
                }
                Text("\(model.sizeText) · \(model.speed) · \(model.accuracy) accuracy · \(model.languagesText)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .failed(let msg) = state { Text(msg).font(.caption).foregroundStyle(.red) }
            }
            .opacity(unsupported ? 0.6 : 1)
            Spacer(minLength: 8)
            controls
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var controls: some View {
        switch state {
        case .missing:
            Button("Download") { store.download(model) }
        case .failed:
            Button("Retry") { store.download(model) }
        case .partial(let p):
            HStack {
                Text("\(Int(p * 100))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button("Resume") { store.download(model) }
                deleteButton
            }
        case .downloading(let p):
            HStack {
                ProgressView(value: p).frame(width: 90)
                Text("\(Int(p * 100))%").font(.caption).monospacedDigit().frame(width: 32, alignment: .trailing)
                Button { store.cancel(model) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("Cancel (the download resumes later)")
            }
        case .installed:
            HStack {
                if active {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3).help("In use")
                } else {
                    Button("Use") { store.use(model.id) }
                }
                deleteButton
            }
        }
    }

    private var deleteButton: some View {
        Button(action: onDelete) { Image(systemName: "trash") }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete from this Mac")
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
