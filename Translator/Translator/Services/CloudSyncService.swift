import Foundation

/// Uploads each session's markdown transcript to the Maldari Worker
/// (`PUT /api/sessions/<id>`), so every meeting is readable on your own site
/// minutes after it starts and survives anything that happens to this Mac.
///
/// Debounced: live snapshots coalesce to one upload per `debounce` window;
/// the final upload on session end always goes out (with finalized=true).
/// Failures are logged and retried on the next snapshot — the local
/// SessionRecorder copy is the source of truth, the cloud is a mirror.
@MainActor
final class CloudSyncService {
    struct Payload {
        let sessionID: String
        let markdown: String
        let startedAt: Date
        let utterances: Int
        let durationS: Int
        let finalized: Bool
    }

    private let session: URLSession
    private let debounce: TimeInterval
    private var pendingTask: Task<Void, Never>?

    /// Seams for tests.
    var endpointProvider: () -> String = { AppSettings.shared.cloudEndpoint }
    var tokenProvider: () -> String? = { Credentials.get(.maldariUploadToken) }
    var enabledProvider: () -> Bool = { AppSettings.shared.cloudSyncEnabled }

    init(session: URLSession = .shared, debounce: TimeInterval = 20) {
        self.session = session
        self.debounce = debounce
    }

    /// Coalesces live-snapshot uploads; the latest payload wins.
    func scheduleUpload(_ payload: Payload) {
        guard isConfigured else { return }
        pendingTask?.cancel()
        pendingTask = Task { [debounce] in
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.upload(payload)
        }
    }

    /// Session end: cancel any pending live upload and push the final state
    /// immediately, with one retry.
    func uploadFinal(_ payload: Payload) {
        guard isConfigured else { return }
        pendingTask?.cancel()
        pendingTask = nil
        Task {
            if await self.upload(payload) { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            _ = await self.upload(payload)
        }
    }

    private var isConfigured: Bool {
        // Hard safety gate: never upload to the live worker from a test run,
        // even if a real token is in the Keychain. (Regression: the pipeline
        // failure test pushed a test session to production.)
        guard !AppEnvironment.isTesting else { return false }
        guard enabledProvider() else { return false }
        guard let token = tokenProvider(), !token.isEmpty else {
            DiagnosticLog.shared.warn("cloud", "not_configured",
                                      ["reason": "missing upload token"])
            return false
        }
        return true
    }

    @discardableResult
    private func upload(_ payload: Payload) async -> Bool {
        guard let token = tokenProvider(),
              let request = Self.makeRequest(
                endpoint: endpointProvider(), token: token, payload: payload)
        else { return false }

        let started = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 200 {
                DiagnosticLog.shared.info("cloud", "uploaded", [
                    "id": payload.sessionID,
                    "bytes": payload.markdown.utf8.count,
                    "finalized": payload.finalized,
                    "ms": Int(Date().timeIntervalSince(started) * 1000),
                ])
                return true
            }
            DiagnosticLog.shared.error("cloud", "upload_rejected", [
                "id": payload.sessionID, "status": status,
            ])
        } catch {
            DiagnosticLog.shared.error("cloud", "upload_failed", [
                "id": payload.sessionID, "error": error.localizedDescription,
            ])
        }
        return false
    }

    /// Static + nonisolated so tests can assert the exact wire format.
    nonisolated static func makeRequest(
        endpoint: String, token: String, payload: Payload
    ) -> URLRequest? {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: "\(base)/api/sessions/\(payload.sessionID)"),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/markdown; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(ISO8601DateFormatter().string(from: payload.startedAt),
                         forHTTPHeaderField: "x-maldari-started-at")
        request.setValue(String(payload.utterances), forHTTPHeaderField: "x-maldari-utterances")
        request.setValue(String(payload.durationS), forHTTPHeaderField: "x-maldari-duration")
        request.setValue(payload.finalized ? "true" : "false",
                         forHTTPHeaderField: "x-maldari-finalized")
        request.httpBody = Data(payload.markdown.utf8)
        return request
    }
}
