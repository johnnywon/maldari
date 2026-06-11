import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import AppKit

/// System / per-process audio capture via a Core Audio process tap
/// (CATapDescription + AudioHardwareCreateProcessTap, macOS 14.4+).
///
/// Flow: create tap → wrap it in a private aggregate device → install an IO
/// proc on the aggregate → convert each callback buffer to LINEAR16 16 kHz
/// mono via AudioChunker.
final class SystemAudioCaptureService: AudioCapturing {
    private let selection: AudioSourceSelection
    private let chunker = AudioChunker()
    private var continuation: AsyncStream<Data>.Continuation?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    init(selection: AudioSourceSelection) {
        self.selection = selection
    }

    func start() async throws -> AsyncStream<Data> {
        // 1. Tap description: a specific process, or system-wide
        //    (global stereo tap excluding nothing).
        let description: CATapDescription
        if case .process(let pid, _) = selection {
            guard let processObject = Self.processObjectID(forPID: pid) else {
                throw AudioCaptureError.deviceSetupFailed("process \(pid) has no audio object")
            }
            description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        } else {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        description.uuid = UUID()
        description.name = "Maldari-Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        // 2. Create the tap. This triggers the System Audio Recording TCC
        //    prompt on first run; a denial comes back as an OSStatus error.
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            throw AudioCaptureError.systemAudioPermissionDenied(status)
        }
        tapID = newTapID

        // 3. Read the tap's stream format so we can hand typed buffers to the converter.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &asbd)
        guard status == noErr, let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            teardown()
            throw AudioCaptureError.deviceSetupFailed("could not read tap format (err \(status))")
        }

        // 4. Build a private aggregate device containing the tap. The default
        //    output device is included as a sub-device so the aggregate's IO
        //    clock runs.
        let outputUID = Self.defaultOutputDeviceUID() ?? ""
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Maldari-Tap-Aggregate",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: description.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey as String: true]
            ],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr else {
            teardown()
            throw AudioCaptureError.deviceSetupFailed("aggregate device failed (err \(status))")
        }

        // 5. IO proc: every callback delivers tap audio in `inInputData`.
        // Bounded buffer (~5 s): if the websocket stalls, drop the oldest
        // audio instead of growing memory and replaying stale speech.
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self, bufferingPolicy: .bufferingNewest(50))
        self.continuation = continuation
        chunker.reset()
        chunker.onChunk = { continuation.yield($0) }

        let chunker = self.chunker
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            _, inInputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: tapFormat, bufferListNoCopy: inInputData, deallocator: nil)
            else { return }
            chunker.append(buffer)
        }
        guard status == noErr, let ioProcID else {
            teardown()
            throw AudioCaptureError.deviceSetupFailed("IO proc failed (err \(status))")
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            teardown()
            throw AudioCaptureError.deviceSetupFailed("device start failed (err \(status))")
        }
        return stream
    }

    func stop() {
        teardown()
        chunker.flush()
        continuation?.finish()
        continuation = nil
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Core Audio process enumeration

    /// Running processes that are currently producing audio output — feeds
    /// the per-process picker in the menu bar.
    static func runningAudioProcesses() -> [(pid: pid_t, name: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr
        else { return [] }

        var results: [(pid: pid_t, name: String)] = []
        for object in objects {
            guard let pid: pid_t = property(object, kAudioProcessPropertyPID) else { continue }
            let running: UInt32 = property(object, kAudioProcessPropertyIsRunningOutput) ?? 0
            guard running != 0 else { continue }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? processName(forPID: pid)
                ?? "PID \(pid)"
            if !results.contains(where: { $0.pid == pid }) {
                results.append((pid: pid, name: name))
            }
        }
        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func processObjectID(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pidValue = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidValue) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &object)
        }
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown
        else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString? = nil
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
        }
        guard status == noErr else { return nil }
        return uid as String?
    }

    /// Fixed-size scalar property read.
    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func processName(forPID pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
