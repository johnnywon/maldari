import Foundation
import AVFoundation

/// Microphone capture via AVAudioEngine, converted to LINEAR16 @ 16 kHz mono.
final class MicrophoneCaptureService: AudioCapturing {
    private let engine = AVAudioEngine()
    private let chunker = AudioChunker()
    private var continuation: AsyncStream<Data>.Continuation?

    func start() async throws -> AsyncStream<Data> {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw AudioCaptureError.microphonePermissionDenied
            }
        default:
            throw AudioCaptureError.microphonePermissionDenied
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw AudioCaptureError.deviceSetupFailed("no input device available")
        }

        // Bounded buffer (~5 s): if the websocket stalls, drop the oldest
        // audio instead of growing memory and replaying stale speech after
        // recovery — live captions should resume from "now".
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self, bufferingPolicy: .bufferingNewest(50))
        self.continuation = continuation
        chunker.reset()
        chunker.onChunk = { continuation.yield($0) }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [chunker] buffer, _ in
            chunker.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.deviceSetupFailed(error.localizedDescription)
        }
        return stream
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        chunker.flush()
        continuation?.finish()
        continuation = nil
    }
}
