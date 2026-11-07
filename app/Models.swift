// Model catalog (models.json) and local model files: status, download with progress, delete.
// Models live in the standard Hugging Face cache, so ones fetched by other tools are picked up too.
import Foundation

struct ModelInfo: Decodable, Identifiable {
    let id, name, engine, repo, speed, accuracy, note: String
    let size: Int64
    let languages, recommended: [String]

    func supports(_ lang: String) -> Bool { lang == "auto" || languages.contains("*") || languages.contains(lang) }
    func isRecommended(for lang: String) -> Bool {
        recommended.contains("*") || (lang != "auto" && recommended.contains(lang))
    }
    var languagesText: String {
        if languages.contains("*") { return "99 languages" }
        if languages.count == 1 { return "\(languageName(languages[0])) only" }
        return "\(languages.count) languages"
    }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    /// huggingface_hub cache layout: models--org--name/{blobs,snapshots,refs}
    var cacheDir: String { hubDir + "/models--" + repo.replacingOccurrences(of: "/", with: "--") }
}

let hubDir = NSHomeDirectory() + "/.cache/huggingface/hub"

let catalog: [ModelInfo] = {
    struct File: Decodable { let models: [ModelInfo] }
    guard let data = FileManager.default.contents(atPath: root + "/models.json"),
          let file = try? JSONDecoder().decode(File.self, from: data) else {
        log("models.json missing or invalid at \(root)")
        return []
    }
    return file.models
}()

func modelInfo(_ id: String) -> ModelInfo? { catalog.first { $0.id == id } }

enum ModelState: Equatable {
    case missing
    case partial(Double)      // an interrupted download; files already fetched are kept
    case downloading(Double)
    case installed
    case failed(String)
}

final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    @Published private(set) var states: [String: ModelState] = [:]
    @Published private(set) var active = Pref.model
    /// Called when the model the server should run changed (picked, downloaded or deleted).
    var onActiveChange: (() -> Void)?

    private var downloads: [String: Process] = [:]
    private var failures: [String: String] = [:]
    private var timer: Timer?

    init() { refresh() }

    var activeInstalled: Bool { states[active] == .installed }

    private func folderBytes(_ dir: String) -> Int64 {
        guard let e = FileManager.default.enumerator(atPath: dir) else { return 0 }
        var total: Int64 = 0
        while let rel = e.nextObject() as? String {
            // Snapshot entries are symlinks into blobs/: measure what they point at.
            let url = URL(fileURLWithPath: dir + "/" + rel).resolvingSymlinksInPath()
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Downloaded bytes (blobs/, growing during a download) and complete files (snapshots/ only
    /// links a file once it is fully fetched). A cache copied without symlinks has no blobs/ at all.
    private func scan(_ m: ModelInfo) -> (downloaded: Int64, complete: Int64) {
        let blobs = folderBytes(m.cacheDir + "/blobs"), snaps = folderBytes(m.cacheDir + "/snapshots")
        return (max(blobs, snaps), snaps)
    }

    /// `hf download` restarts a half-fetched file under a new temp name instead of resuming it:
    /// drop leftovers from a cancelled run so they neither linger nor inflate the progress bar.
    private func removeLeftovers(_ m: ModelInfo) {
        let blobs = m.cacheDir + "/blobs"
        for n in (try? FileManager.default.contentsOfDirectory(atPath: blobs)) ?? [] where n.hasSuffix(".incomplete") {
            try? FileManager.default.removeItem(atPath: blobs + "/" + n)
        }
    }

    func refresh() {
        var s: [String: ModelState] = [:]
        for m in catalog {
            let (bytes, complete) = scan(m)
            let progress = min(1, Double(bytes) / Double(max(m.size, 1)))
            if downloads[m.id] != nil { s[m.id] = .downloading(progress) }
            else if let f = failures[m.id] { s[m.id] = .failed(f) }
            // Catalog sizes are the repo totals; a few % slack covers README/.gitattributes revisions.
            else if Double(complete) >= 0.97 * Double(m.size) { s[m.id] = .installed }
            else if bytes > 1_000_000 { s[m.id] = .partial(progress) }
            else { s[m.id] = .missing }
        }
        if s != states { states = s }
    }

    func use(_ id: String) {
        guard id != active else { return }
        Pref.model = id
        active = id
        log("model -> \(id)")
        onActiveChange?()
    }

    func download(_ m: ModelInfo) {
        guard downloads[m.id] == nil else { return }
        failures[m.id] = nil
        removeLeftovers(m)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: root + "/.venv/bin/hf")
        p.arguments = ["download", m.repo]
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = nil
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        // Plain HTTP writes straight into blobs/, so the folder size is a live progress bar
        // (the Xet backend assembles files elsewhere and they appear at the end).
        env["HF_HUB_DISABLE_XET"] = "1"
        p.environment = env
        let out = logDir + "/downloads.log"
        if !FileManager.default.fileExists(atPath: out) { FileManager.default.createFile(atPath: out, contents: nil) }
        if let h = FileHandle(forWritingAtPath: out) { h.seekToEndOfFile(); p.standardOutput = h; p.standardError = h }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.finished(m, proc) }
        }
        do {
            try p.run()
            downloads[m.id] = p
            log("download started: \(m.repo)")
        } catch {
            failures[m.id] = "Couldn't start the downloader: \(error.localizedDescription)"
        }
        startTimer()
        refresh()
    }

    private func finished(_ m: ModelInfo, _ proc: Process) {
        downloads[m.id] = nil
        let cancelled = proc.terminationReason == .uncaughtSignal
        log("download \(m.repo): exit \(proc.terminationStatus)\(cancelled ? " (cancelled)" : "")")
        if proc.terminationStatus != 0 && !cancelled {
            failures[m.id] = "Download failed. Check your connection; details in downloads.log."
        }
        refresh()
        if states[m.id] == .installed && (m.id == active || !activeInstalled) {
            // The first model the user gets becomes the one in use; re-downloading the active one restarts it.
            if m.id == active { onActiveChange?() } else { use(m.id) }
        }
    }

    func cancel(_ m: ModelInfo) { downloads[m.id]?.terminate() }

    func delete(_ m: ModelInfo) {
        cancel(m)
        do { try FileManager.default.removeItem(atPath: m.cacheDir) } catch { log("delete \(m.repo): \(error)") }
        log("deleted \(m.repo)")
        failures[m.id] = nil
        refresh()
        if m.id == active { onActiveChange?() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            self.refresh()
            if self.downloads.isEmpty { t.invalidate(); self.timer = nil }
        }
    }

    func cancelAll() { downloads.values.forEach { $0.terminate() } }
}
