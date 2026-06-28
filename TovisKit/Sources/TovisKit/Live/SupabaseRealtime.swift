import Foundation

/// Minimal, dependency-free Supabase Realtime client (Phoenix protocol over a
/// websocket) for live-sync Layer 2.
///
/// Broadcast-only: it joins one or more channels and calls `onChange` whenever a
/// `changed` broadcast arrives (see lib/live/broadcast.ts on the backend). The
/// payload carries no data — the app refetches through the normal API.
///
/// FAIL-SAFE BY DESIGN: if it can't connect (or no Supabase creds are set), the
/// app's foreground-refresh + polling already keep data fresh, so a realtime
/// outage only costs sub-poll latency — it never shows stale data indefinitely.
/// It auto-reconnects with backoff and heartbeats to stay alive.
public actor SupabaseRealtime {
    private let socketURL: URL
    private let anonKey: String

    private var channels: [String] = []
    private var onChange: (@Sendable () -> Void)?

    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var ref = 0
    private var running = false
    private var loops: [Task<Void, Never>] = []

    /// Returns nil when live-sync isn't configured (no URL / empty key).
    public init?(supabaseURL: URL?, anonKey: String?) {
        guard let supabaseURL, let anonKey, !anonKey.isEmpty else { return nil }
        guard let socketURL = Self.makeSocketURL(from: supabaseURL, anonKey: anonKey) else {
            return nil
        }
        self.socketURL = socketURL
        self.anonKey = anonKey
        self.session = URLSession(configuration: .default)
    }

    /// Begin (or restart) subscribing to `channels`, invoking `onChange` on any
    /// `changed` broadcast. Safe to call once per signed-in session.
    public func start(channels: [String], onChange: @escaping @Sendable () -> Void) {
        self.channels = channels
        self.onChange = onChange
        guard !running else { return }
        running = true
        connect()
    }

    /// Stop and tear everything down (call on logout).
    public func stop() {
        running = false
        loops.forEach { $0.cancel() }
        loops.removeAll()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: - Connection lifecycle

    private func connect() {
        guard running else { return }
        let task = session.webSocketTask(with: socketURL)
        self.task = task
        task.resume()

        for channel in channels { joinChannel(channel) }

        loops.append(Task { [weak self] in await self?.receiveLoop() })
        loops.append(Task { [weak self] in await self?.heartbeatLoop() })
    }

    private func reconnect() {
        guard running else { return }
        loops.forEach { $0.cancel() }
        loops.removeAll()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        loops.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await self?.connect()
        })
    }

    // MARK: - Phoenix protocol

    private func nextRef() -> String {
        ref &+= 1
        return String(ref)
    }

    private func joinChannel(_ channel: String) {
        // Phoenix join for a Realtime broadcast topic.
        send([
            "topic": "realtime:\(channel)",
            "event": "phx_join",
            "payload": ["config": ["broadcast": ["self": false]]],
            "ref": nextRef(),
        ])
    }

    private func heartbeatLoop() async {
        while running, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(25))
            guard running, !Task.isCancelled else { return }
            send([
                "topic": "phoenix",
                "event": "heartbeat",
                "payload": [:],
                "ref": nextRef(),
            ])
        }
    }

    private func receiveLoop() async {
        guard let task else { return }
        while running, !Task.isCancelled {
            do {
                let message = try await task.receive()
                handle(message)
            } catch {
                // Socket dropped — reconnect (unless we're shutting down).
                if running { reconnect() }
                return
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case let .string(text): data = text.data(using: .utf8)
        case let .data(raw): data = raw
        @unknown default: data = nil
        }
        guard
            let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            (json["event"] as? String) == "broadcast",
            let payload = json["payload"] as? [String: Any],
            (payload["event"] as? String) == "changed"
        else {
            return
        }
        onChange?()
    }

    private func send(_ object: [String: Any]) {
        guard
            let task,
            let data = try? JSONSerialization.data(withJSONObject: object),
            let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        task.send(.string(text)) { _ in }
    }

    // MARK: - URL

    private static func makeSocketURL(from supabaseURL: URL, anonKey: String) -> URL? {
        guard var components = URLComponents(url: supabaseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/realtime/v1/websocket"
        components.queryItems = [
            URLQueryItem(name: "apikey", value: anonKey),
            URLQueryItem(name: "vsn", value: "1.0.0"),
        ]
        return components.url
    }
}