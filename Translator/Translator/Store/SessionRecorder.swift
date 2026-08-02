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
            writeSnapshotNow(markdown)
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

    /// A source transcript locked. `lang` and `english` are additive — readers
    /// that only look at "korean" keep working, and `lang` records which language
    /// was actually spoken now that a session can carry both.
    ///
    /// The event type stays `korean_final` rather than becoming `source_final`:
    /// existing tooling matches on it, and renaming would break transcripts
    /// already on disk for no gain.
    func recordFinal(_ utterance: Utterance) {
        append([
            "type": "korean_final",
            "id": utterance.id,
            "korean": utterance.korean,
            "english": utterance.english,
            "lang": utterance.sourceLanguage.rawValue,
        ])
    }

    /// Only *settled* translations reach this — speculative revisions are never
    /// persisted, so a transcript on disk never contains a guess that was later
    /// corrected. `language` is the language the translation is written in.
    func recordTranslation(id: Int, text: String, language: Language, failed: Bool) {
        append([
            "type": failed ? "translation_failed" : "translation_done",
            "id": id,
            "english": text,
            "lang": language.rawValue,
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

    /// Snapshot writes go to a background queue.
    ///
    /// This is a whole-file atomic write of the entire transcript, which by the end of
    /// a long meeting is ~100 KB, and it ran on the main actor every two seconds. An
    /// atomic write is a write plus a rename, and its tail latency is not bounded by
    /// anything this process controls — Spotlight indexing, FileVault, or Time Machine
    /// contention can turn a 1 ms write into tens of milliseconds. On the main thread
    /// that is dropped frames and a stuttering pointer, and it gets worse as the
    /// meeting goes on because the file only grows.
    ///
    /// Serial so snapshots cannot land out of order and leave an older transcript on
    /// disk than the one already uploaded.
    private static let snapshotQueue = DispatchQueue(
        label: "translator.session-snapshot", qos: .utility)

    private func writeSnapshot(_ markdown: String) {
        guard let dir = sessionDirectory else { return }
        let url = dir.appendingPathComponent("transcript.md")
        Self.snapshotQueue.async {
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Same write, but synchronous — for `end()`, where the process may be about to
    /// go away and an async write could simply never happen.
    private func writeSnapshotNow(_ markdown: String) {
        guard let dir = sessionDirectory else { return }
        let url = dir.appendingPathComponent("transcript.md")
        Self.snapshotQueue.sync {
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
