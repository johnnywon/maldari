import Foundation
import AVFoundation

/// Where audio comes from. Selected in Settings and from the menu bar.
enum AudioSourceSelection: Hashable {
    case microphone
    case systemAudio            // system-wide process tap
    case process(pid: pid_t, name: String)  // tap a single process (Zoom, Chrome…)
    /// Mic AND system audio simultaneously, one STT stream each, so the
    /// transcript can attribute utterances: mic = "Me", system = "Them".
    case dual

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "System Audio"
        case .process(_, let name): return name
        case .dual: return "Mic + System"
        }
    }
}

enum AudioCaptureError: LocalizedError {
    case microphonePermissionDenied
    case systemAudioPermissionDenied(OSStatus)
    case deviceSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone, then restart Maldari."
        case .systemAudioPermissionDenied(let status):
            return "System audio capture unavailable (err \(status)). Grant access in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only."
        case .deviceSetupFailed(let detail):
            return "Audio device setup failed: \(detail)"
        }
    }
}

/// Protocol seam for the capture layer so the pipeline can be tested with a
/// canned audio source. Emits 16 kHz mono 16-bit signed PCM (LINEAR16) in
/// ~100 ms chunks.
protocol AudioCapturing: AnyObject {
    func start() async throws -> AsyncStream<Data>
    func stop()
}

/// Converts arbitrary-format PCM buffers to 16 kHz / mono / Int16 and slices
/// the result into fixed 100 ms chunks (3200 bytes).
final class AudioChunker {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    /// 100 ms at 16 kHz mono Int16.
    static let chunkBytes = 3200

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var pending = Data()
    private let lock = NSLock()

    var onChunk: ((Data) -> Void)?

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        if converter == nil || sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
        }
        guard let converter else { return }

        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity)
        else { return }

        var fed = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard convError == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return }

        pending.append(Data(bytes: channel[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size))
        while pending.count >= Self.chunkBytes {
            let chunk = pending.prefix(Self.chunkBytes)
            pending.removeFirst(Self.chunkBytes)
            onChunk?(Data(chunk))
        }
    }

    /// Emit whatever is buffered (used at stop so trailing speech isn't lost).
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return }
        onChunk?(pending)
        pending = Data()
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        pending = Data()
        converter = nil
        sourceFormat = nil
    }
}
