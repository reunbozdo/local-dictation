// Paths, logging and preferences shared by the whole app.
import Cocoa

/// Repo checkout the app was built from (Info.plist AppRoot, set by build.sh): .venv, server/, models.json.
let root: String = Bundle.main.object(forInfoDictionaryKey: "AppRoot") as? String
    ?? FileManager.default.currentDirectoryPath
let port = 47620  // the server gets it as --port
let supportDir = NSHomeDirectory() + "/Library/Application Support/Local Dictation"
let logDir = NSHomeDirectory() + "/Library/Logs/Local Dictation"
let dictionaryPath = supportDir + "/dictionary.txt"
let historyDir = supportDir + "/history"

// O_APPEND: lines from different threads (and the --probe instance) can't overwrite each other.
func log(_ s: String) {
    let fd = open(logDir + "/app.log", O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    let line = Array("\(Date()) \(s)\n".utf8)
    _ = line.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    close(fd)
}

/// Creates the support folders and seeds the user's dictionary from the repo example on first run.
func prepareSupportFiles() {
    let fm = FileManager.default
    for dir in [supportDir, logDir] { try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    if !fm.fileExists(atPath: dictionaryPath) {
        try? fm.copyItem(atPath: root + "/terms.example.txt", toPath: dictionaryPath)
    }
}

// MARK: - Preferences (UserDefaults: the single source of truth; the server gets them per launch/request)

enum Pref {
    static let d = UserDefaults.standard
    static let defaultModel = "whisper-large-v3-turbo"
    static var hotkey: Hotkey { Hotkey(rawValue: d.string(forKey: "hotkey") ?? "") ?? .rightOption }
    static var mode: ActivationMode { ActivationMode(rawValue: d.string(forKey: "mode") ?? "") ?? .holdOrTap }
    static var language: String { d.string(forKey: "language") ?? defaultLanguage }
    static let defaultLanguage = "en"
    static var model: String {
        get { d.string(forKey: "model") ?? defaultModel }
        set { d.set(newValue, forKey: "model") }
    }
    /// Off by default: keeping audio is a privacy choice the user makes.
    static var saveHistory: Bool { d.bool(forKey: "save_history") }
}

// MARK: - Languages offered in Settings (codes understood by Whisper; other engines map or ignore them)

let languageCodes = ["en", "es", "fr", "de", "it", "pt", "nl", "ru", "uk", "pl", "cs", "sk", "sl", "hr", "bg",
                     "ro", "hu", "el", "tr", "sv", "da", "no", "fi", "et", "lv", "lt", "ar", "he", "fa", "hi",
                     "zh", "yue", "ja", "ko", "vi", "th", "id", "ms"]

func languageName(_ code: String) -> String {
    if code == "auto" { return "Auto-detect" }
    if code == "yue" { return "Cantonese" }
    return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
}

func openPrivacyPane(_ anchor: String) {  // "Privacy_Microphone", "Privacy_Accessibility"
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
}
