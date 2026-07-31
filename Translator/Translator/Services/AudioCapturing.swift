import Foundation
import AVFoundation

/// Where audio comes from. Selected in Settings and from the menu bar.
enum AudioSourceSelection: Hashable {
    case microphone
    case systemAudio            // system-wide process tap
    case process(pid: pid_t, name: String)  // tap a single process (Zoom, Chrome…)

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "System Audio"
        case .process(_, let name): return name
        }
    }
}

/// How many languages and channels a session runs.
enum CaptureMode: String, Equatable, Sendable, CaseIterable {
    /// The original behaviour: one source, RTZR only, Korean in / English out.
    case koreanOnly

    /// One audio source, both engines listening to it, direction detected per
    /// utterance. This is the in-person case — a MacBook on the table, everyone
    /// on the same microphone.
    case bidirectionalSingle

    /// Two sources: the microphone is the operator speaking English, system
    /// audio is the remote guests speaking Korean. Direction is known by
    /// channel, so no detection is needed. This is the video-call case.
    case bidirectionalDual

    var isBidirectional: Bool { self != .koreanOnly }

    var displayName: String {
        switch self {
        case .koreanOnly: return "Korean only"
        case .bidirectionalSingle: return "Bidirectional — one microphone"
        case .bidirectionalDual: return "Bidirectional — mic + system audio"
        }
    }

    var detail: String {
        switch self {
        case .koreanOnly:
            return "Korean speech in, English out. One engine, lowest cost."
        case .bidirectionalSingle:
            return "Everyone on one microphone. Both engines listen and the better transcript wins."
        case .bidirectionalDual:
            return "Your mic is English, the call's audio is Korean. Direction is known, not guessed."
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
/// canned audio source. Emits mono 16-bit signed PCM (LINEAR16) in ~100 ms
/// chunks at the rate the consuming engine requires — 16 kHz for RTZR, 24 kHz
/// for the OpenAI Realtime API. The rate is chosen per capture instance, so a
/// dual-channel session runs two captures at two rates.
protocol AudioCapturing: AnyObject {
    func start() async throws -> AsyncStream<Data>
    func stop()
}

/// Converts arbitrary-format PCM buffers to mono / Int16 at a target rate and
/// slices the result into fixed 100 ms chunks.
final class AudioChunker {
    /// RTZR's streaming endpoint is configured for 16 kHz LINEAR16.
    static let rtzrSampleRate: Double = 16_000
    /// The OpenAI Realtime API's `pcm16` input format is 24 kHz mono
    /// little-endian. Feeding it 16 kHz produces transcripts that read as if
    /// the speaker were slowed down.
    static let openAISampleRate: Double = 24_000

    let targetFormat: AVAudioFormat
    /// 100 ms of mono Int16 at `targetFormat.sampleRate`.
    let chunkBytes: Int

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var pending = Data()
    private let lock = NSLock()

    var onChunk: ((Data) -> Void)?

    /// RMS of each emitted chunk, 0...1. Drives the Presentation header's level
    /// meter. Computed here because the samples are already converted and in
    /// hand — a separate tap would duplicate the conversion.
    var onLevel: ((Float) -> Void)?

    init(sampleRate: Double = AudioChunker.rtzrSampleRate) {
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
            channels: 1, interleaved: true)!
        self.chunkBytes = Int(sampleRate / 10) * MemoryLayout<Int16>.size
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        if converter == nil || sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
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
        while pending.count >= chunkBytes {
            let chunk = Data(pending.prefix(chunkBytes))
            pending.removeFirst(chunkBytes)
            if onLevel != nil { onLevel?(Self.rms(of: chunk)) }
            onChunk?(chunk)
        }
    }

    /// Root-mean-square amplitude of little-endian Int16 samples, 0...1.
    static func rms(of chunk: Data) -> Float {
        guard chunk.count >= 2 else { return 0 }
        var sumSquares: Double = 0
        var count = 0
        chunk.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples {
                let normalized = Double(Int16(littleEndian: sample)) / 32768.0
                sumSquares += normalized * normalized
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        return Float((sumSquares / Double(count)).squareRoot())
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
