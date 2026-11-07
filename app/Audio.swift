// Microphone: device list (CoreAudio) and a recorder that hands back 16 kHz mono samples.
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Input device
// The choice only steers our own recorder; the system input/output devices are never changed.
// Preference (UserDefaults "input_device"): "builtin" (default) = MacBook mic, "system" = whatever
// macOS picked, otherwise a device UID (stable across reconnects, unlike AudioDeviceID).

struct InputDevice { let id: AudioDeviceID; let uid: String; let name: String; let builtIn: Bool }

func caString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func caUInt32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func inputDevices() -> [InputDevice] {
    let sys = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var n: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &n) == noErr, n > 0,  // has input streams
              let uid = caString(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return InputDevice(id: id, uid: uid, name: caString(id, kAudioObjectPropertyName) ?? uid,
                           builtIn: caUInt32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn)
    }
}

func systemInputName() -> String {
    let id = caUInt32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) ?? 0
    return caString(id, kAudioObjectPropertyName) ?? "?"
}

let inputPrefKey = "input_device"
var inputPref: String {
    get { UserDefaults.standard.string(forKey: inputPrefKey) ?? "builtin" }
    set { UserDefaults.standard.set(newValue, forKey: inputPrefKey) }
}

/// device nil = record from the system input. fallback = the preferred device is missing.
func resolveInput(_ pref: String = inputPref) -> (device: InputDevice?, fallback: Bool) {
    if pref == "system" { return (nil, false) }
    let all = inputDevices()
    if pref != "builtin", let d = all.first(where: { $0.uid == pref }) { return (d, false) }
    // Chosen device unplugged (or "builtin"): MacBook mic, then the system input.
    if let b = all.first(where: { $0.builtIn }) { return (b, pref != "builtin") }
    return (nil, true)
}

// MARK: - Recorder: mic -> 16 kHz mono Float32
// AudioQueue, not AVAudioEngine: a fresh AVAudioEngine whose input unit gets a non-default device
// (kAudioOutputUnitProperty_CurrentDevice) sometimes failed with 'nope' on quick repeated presses, and
// then hung forever inside -[AVAudioEngine inputNode] on the main thread (2026-11-04, app froze).
// An AudioQueue takes the device UID up front and converts to 16 kHz mono itself.
// Not thread-safe: call start/stop from one serial queue (AppDelegate.audio).

struct AudioError: LocalizedError {
    let call: String; let status: OSStatus
    var errorDescription: String? {
        let b = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian) { Array($0) }
        let fourCC = b.allSatisfy { $0 >= 32 && $0 < 127 } ? " '\(String(decoding: b, as: UTF8.self))'" : ""
        return "\(call): \(status)\(fourCC)"
    }
}

func check(_ status: OSStatus, _ call: String) throws { if status != noErr { throw AudioError(call: call, status: status) } }

final class Recorder {
    private var queue: AudioQueueRef?
    private var samples: [Float] = []
    private var lastRMS: Float = 0
    private let lock = NSLock()

    /// Loudness of the latest 50 ms buffer for the HUD meter, 0...1. Any thread.
    /// dB scale from the room's noise floor (-55 dB) to loud speech (-20 dB); the square root
    /// lifts quiet speech so the bars visibly move even when talking softly or far from the mic.
    var level: Float {
        lock.lock(); defer { lock.unlock() }
        guard lastRMS > 0 else { return 0 }
        return max(0, min(1, (20 * log10(lastRMS) + 55) / 35)).squareRoot()
    }

    /// uid nil = system input.
    func start(uid: String?) throws {
        _ = stop()
        lock.lock(); samples.removeAll(keepingCapacity: true); lastRMS = 0; lock.unlock()
        var fmt = AudioStreamBasicDescription(mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                              mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var q: AudioQueueRef?
        // Callbacks on AudioQueue's own thread (nil run loop).
        try check(AudioQueueNewInput(&fmt, { user, q, buf, _, _, _ in
            let me = Unmanaged<Recorder>.fromOpaque(user!).takeUnretainedValue()
            let n = Int(buf.pointee.mAudioDataByteSize) / 4
            let ptr = buf.pointee.mAudioData.assumingMemoryBound(to: Float.self)
            let chunk = UnsafeBufferPointer(start: ptr, count: n)
            let rms = n > 0 ? (chunk.reduce(0) { $0 + $1 * $1 } / Float(n)).squareRoot() : 0
            me.lock.lock(); me.samples.append(contentsOf: chunk); me.lastRMS = rms; me.lock.unlock()
            AudioQueueEnqueueBuffer(q, buf, 0, nil)  // fails harmlessly once the queue is stopped
        }, Unmanaged.passUnretained(self).toOpaque(), nil, nil, 0, &q), "AudioQueueNewInput")
        guard let q else { throw AudioError(call: "AudioQueueNewInput", status: -1) }
        do {
            if let uid {
                let cf = uid as CFString  // the property takes a CFStringRef
                var ref = Unmanaged.passUnretained(cf)
                try withExtendedLifetime(cf) {
                    try check(AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, &ref, UInt32(MemoryLayout<CFString>.size)), "set device")
                }
            }
            // 4 x 50 ms buffers: little audio is lost when the key is released (immediate stop).
            for _ in 0..<4 {
                var buf: AudioQueueBufferRef?
                try check(AudioQueueAllocateBuffer(q, 800 * 4, &buf), "AudioQueueAllocateBuffer")
                try check(AudioQueueEnqueueBuffer(q, buf!, 0, nil), "AudioQueueEnqueueBuffer")
            }
            try check(AudioQueueStart(q, nil), "AudioQueueStart")
        } catch {
            AudioQueueDispose(q, true)
            throw error
        }
        queue = q
    }

    func stop() -> [Float] {
        if let q = queue {
            AudioQueueStop(q, true)  // no callbacks after it returns
            AudioQueueDispose(q, true)
            queue = nil
        }
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}

func wav(_ samples: [Float]) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    let bytes = UInt32(samples.count * 2)
    d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVEfmt ".data(using: .ascii)!)
    u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
    d.append("data".data(using: .ascii)!); u32(bytes)
    var pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767).littleEndian }
    d.append(Data(bytes: &pcm, count: pcm.count * 2))
    return d
}

func describe(_ pick: (device: InputDevice?, fallback: Bool)) -> String {
    let what = pick.device.map { "\($0.name) [\($0.uid)]" } ?? "system input \(systemInputName())"
    return pick.fallback ? "\(what) (fallback: \(inputPref) is missing)" : what
}
