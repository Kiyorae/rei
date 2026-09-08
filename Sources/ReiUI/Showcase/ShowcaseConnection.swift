import Foundation
import Observation
import ReiCore
import ReiProtocol

/// A real loopback Milky consumer for the isolated showcase. API timing belongs
/// to this client, not to Milky's push-only event socket or the protocol service.
@Observable
@MainActor
final class ShowcaseConnection {
    enum State { case idle, connecting, connected, failed }

    private(set) var state: State = .idle
    private(set) var roundTripTime: Duration?
    private(set) var receivedEvents = 0
    private(set) var errorMessage: String?
    private let environment: AppEnvironment
    private var task: Task<Void, Never>?

    var isActive: Bool { task != nil }

    init(environment: AppEnvironment) { self.environment = environment }

    func connect() {
        guard task == nil else { return }
        state = .connecting
        errorMessage = nil
        roundTripTime = nil
        receivedEvents = 0
        task = Task {
            do {
                try await consumeService()
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
            await environment.disconnect()
            roundTripTime = nil
            state = errorMessage == nil ? .idle : .failed
            task = nil
        }
    }

    func disconnect() async {
        let running = task
        running?.cancel()
        await running?.value
    }

    func toggle() async {
        if isActive { await disconnect() } else { connect() }
    }

    private func consumeService() async throws {
        let token = UUID().uuidString
        environment.selectedProtocol = .milky
        environment.settings = ConnectionSettings(
            transport: .milkyService, host: "127.0.0.1", port: 0, accessToken: token
        )
        guard await environment.connect() else {
            throw ConnectionError.startFailed(environment.lastError ?? "Unable to start the demo service")
        }
        // State updates are delivered asynchronously after the listener starts.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var listeningPort: UInt16?
        while clock.now < deadline {
            try Task.checkCancellation()
            if case .ready(let port) = environment.sessionState, port != 0 {
                listeningPort = port
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let port = listeningPort else { throw URLError(.timedOut) }
        environment.settings.port = port

        let client = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/event")!)
        request.timeoutInterval = 4
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = client.webSocketTask(with: request)
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            client.invalidateAndCancel()
        }
        try await withTaskCancellationHandler {
            socket.resume()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                socket.sendPing { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.receiveEvents(from: socket) }
                group.addTask { try await self.measureAPI(client: client, port: port, token: token) }
                defer { group.cancelAll() }
                do {
                    try await group.next()
                } catch {
                    socket.cancel(with: .goingAway, reason: nil)
                    client.invalidateAndCancel()
                    throw error
                }
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
            client.invalidateAndCancel()
        }
    }

    private func receiveEvents(from socket: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .data(let bytes): data = bytes
            case .string(let text): data = Data(text.utf8)
            @unknown default: throw URLError(.cannotParseResponse)
            }
            let payload = try JSONValue.decode(from: data)
            guard payload["self_id"]?.stringValue == environment.botUserID,
                payload["event_type"]?.stringValue != nil
            else { throw URLError(.cannotParseResponse) }
            receivedEvents += 1
        }
    }

    private func measureAPI(client: URLSession, port: UInt16, token: String) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/get_login_info")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let start = clock.now
            let (data, response) = try await client.data(for: request)
            let duration = start.duration(to: clock.now)
            let payload = try JSONValue.decode(from: data)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                payload["status"]?.stringValue == "ok",
                payload["data"]?["uin"]?.stringValue == environment.botUserID
            else { throw URLError(.badServerResponse) }
            try Task.checkCancellation()
            roundTripTime = duration
            state = .connected
            try await Task.sleep(for: .seconds(4))
        }
    }

    private enum ConnectionError: LocalizedError {
        case startFailed(String)
        var errorDescription: String? {
            switch self {
            case .startFailed(let reason): return reason
            }
        }
    }
}
