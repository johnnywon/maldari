import Foundation

/// Append-only JSONL diagnostics, one file per app launch, written to
/// ~/Library/Logs/Maldari/. Built for offline bug-hunting: every layer
/// (audio, websocket, stt, translate, queue, session, cloud) logs structured
/// events with timestamps so a failed 40-minute meeting can be reconstructed
/// line by line after the fact.
///
/// Line shape:
///   {"ts":"2026-06-11T12:01:54.123Z","cat":"translate","level":"error",
///    "event":"request_failed","data":{…}}
///
/// Writes happen on a serial utility queue, so any thread or actor can log
/// without awaiting. Files older than the newest 30 are pruned at launch.
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()

    enum Level: String { case info, warn, error }

    static let directory: URL = {
        let fm = FileManager.default
        let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        let dir = logs.appendingPathComponent("Maldari", isDirectory: true)
        // One-time migration from the pre-rename (Translator) location.
        let legacy = logs.appendingPathComponent("Translator", isDirectory: true)
        if fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: dir.path) {
            try? fm.moveItem(at: legacy, to: dir)
        }
        return dir
    }()

    let fileURL: URL

    private let queue = DispatchQueue(label: "translator.diagnostic-log", qos: .utility)
    private var handle: FileHandle?
    private let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        let nameFormatter = DateFormatter()
        nameFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        fileURL = Self.directory
            .appendingPathComponent("maldari-\(nameFormatter.string(from: Date())).jsonl")
        queue.async { [self] in
            openFile()
            pruneOldLogs(keep: 30)
        }
    }

    // MARK: - Public API

    func info(_ cat: String, _ event: String, _ data: [String: Any] = [:]) {
        write(.info, cat, event, data)
    }

    func warn(_ cat: String, _ event: String, _ data: [String: Any] = [:]) {
        write(.warn, cat, event, data)
    }

    func error(_ cat: String, _ event: String, _ data: [String: Any] = [:]) {
        write(.error, cat, event, data)
    }

    // MARK: - Internals

    private func write(_ level: Level, _ cat: String, _ event: String, _ data: [String: Any]) {
        let ts = timestampFormatter.string(from: Date())
        queue.async { [self] in
            var line: [String: Any] = [
                "ts": ts,
                "cat": cat,
                "level": level.rawValue,
                "event": event,
            ]
            if !data.isEmpty { line["data"] = sanitize(data) }
            guard let json = try? JSONSerialization.data(withJSONObject: line) else { return }
            handle?.write(json)
            handle?.write(Data("\n".utf8))
        }
    }

    /// JSONSerialization rejects non-plist values (errors, enums…); stringify
    /// anything that isn't a JSON scalar so a bad value never drops the line.
    private func sanitize(_ data: [String: Any]) -> [String: Any] {
        data.mapValues { value in
            switch value {
            case let v as String: return v
            case let v as Int: return v
            case let v as Double: return v
            case let v as Bool: return v
            case let v as [String: Any]: return sanitize(v)
            default: return String(describing: value)
            }
        }
    }

    private func openFile() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        fm.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    private func pruneOldLogs(keep: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: [.creationDateKey])
        else { return }
        let logs = files
            .filter { $0.pathExtension == "jsonl" }
            .sorted { (lhs, rhs) in
                let l = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return l > r
            }
        for stale in logs.dropFirst(keep) {
            try? fm.removeItem(at: stale)
        }
    }
}
