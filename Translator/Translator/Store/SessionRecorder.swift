import Foundation

/// Persists the live session to disk as it happens, so a crash or restart
/// loses nothing:
///   ~/Library/Application Support/Maldari/sessions/session-<stamp>/
///     events.jsonl    — append-only: every finalized Korean line and every
///                       completed translation, written the moment it lands
///     transcript.md   — rolling markdown snapshot (debounced ~2s)
///
/// Each snapshot also feeds CloudSyncService, which mirrors the markdown to
/// your Maldari site (debounced ~20s, final push on session end).
///
/// Recovery after a crash: open the newest session folder; transcript.md has
/// everything up to the last completed translation.
@MainActor
final class SessionRecorder {
    static let sessionsRoot: URL = {
        let fm = FileManager.default
        // Tests must never write into the user's real Application Support.
        if AppEnvironment.isTesting {
            return fm.temporaryDirectory.appendingPathComponent("Maldari-test/sessions", isDirectory: true)
        }
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = appSupport.appendingPathComponent("Maldari/sessions", isDirectory: true)
        // One-time migration from the pre-rename (Translator) location.
        let legacy = appSupport.appendingPathComponent("Translator/sessions", isDirectory: true)
        if fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: root.path) {
            try? fm.createDirectory(at: root.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? fm.moveItem(at: legacy, to: root)
        }
        return root
    }()

    private(set) var sessionDirectory: URL?
    private(set) var sessionID: String?
    private var startedAt: Date?
    private let cloudSync = CloudSyncService()
    private var eventsHandle: FileHandle?
    private var snapshotTask: Task<Void, Never>?
    private let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Lifecycle

    func begin() {
        end()
        let now = Date()
        let nameFormatter = DateFormatter()
        nameFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = nameFormatter.string(from: now)
        let dir = Self.sessionsRoot
            .appendingPathComponent("session-\(stamp)", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let eventsURL = dir.appendingPathComponent("events.jsonl")
            fm.createFile(atPath: eventsURL.path, contents: nil)
            eventsHandle = try FileHandle(forWritingTo: eventsURL)
            sessionDirectory = dir
            sessionID = stamp
            startedAt = now
            append(["type": "session_start"])
            DiagnosticLog.shared.info("session", "recording_started", ["dir": dir.path])
        } catch {
            sessionDirectory = nil
            eventsHandle = nil
            sessionID = nil
            startedAt = nil
            DiagnosticLog.shared.error("session", "recording_failed", ["error": error.localizedDescription])
        }
    }

    func end(finalSnapshotOf store: TranscriptStore? = nil) {
        snapshotTask?.cancel()
        snapshotTask = nil
        if let store, sessionDirectory != nil {
            let markdown = store.exportMarkdown()
            writeSnapshot(markdown)
            append(["type": "session_end"])
            if let payload = payload(markdown: markdown, store: store, finalized: true) {
                cloudSync.uploadFinal(payload)
            }
        }
        try? eventsHandle?.close()
        eventsHandle = nil
        sessionDirectory = nil
        sessionID = nil
        startedAt = nil
    }

    // MARK: - Events

    func recordFinal(_ utterance: Utterance) {
        var event: [String: Any] = [
            "type": "korean_final",
            "id": utterance.id,
            "korean": utterance.korean,
        ]
        if let speaker = utterance.speaker {
            event["speaker"] = speaker.rawValue
        }
        append(event)
    }

    func recordTranslation(id: Int, english: String, failed: Bool) {
        append([
            "type": failed ? "translation_failed" : "translation_done",
            "id": id,
            "english": english,
        ])
    }

    /// Rewrites transcript.md no more than once per 2s burst, and mirrors
    /// the fresh markdown to the cloud (further debounced by CloudSync).
    func scheduleSnapshot(of store: TranscriptStore) {
        guard sessionDirectory != nil else { return }
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self, weak store] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, let store else { return }
            let markdown = store.exportMarkdown()
            self.writeSnapshot(markdown)
            if let payload = self.payload(markdown: markdown, store: store, finalized: false) {
                self.cloudSync.scheduleUpload(payload)
            }
        }
    }

    private func payload(
        markdown: String, store: TranscriptStore, finalized: Bool
    ) -> CloudSyncService.Payload? {
        guard let sessionID, let startedAt else { return nil }
        return CloudSyncService.Payload(
            sessionID: sessionID,
            markdown: markdown,
            startedAt: startedAt,
            utterances: store.utterances.count,
            durationS: Int(Date().timeIntervalSince(startedAt)),
            finalized: finalized)
    }

    // MARK: - Internals

    private func append(_ event: [String: Any]) {
        guard let eventsHandle else { return }
        var line = event
        line["ts"] = timestampFormatter.string(from: Date())
        guard let json = try? JSONSerialization.data(withJSONObject: line) else { return }
        eventsHandle.write(json)
        eventsHandle.write(Data("\n".utf8))
    }

    private func writeSnapshot(_ markdown: String) {
        guard let dir = sessionDirectory else { return }
        let url = dir.appendingPathComponent("transcript.md")
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }
}
