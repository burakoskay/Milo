import Foundation
import Network

enum MiloLoopbackServerError: Error, LocalizedError {
    case listenerFailed
    case invalidListenerPort
    case invalidLocalURL

    var errorDescription: String? {
        switch self {
        case .listenerFailed, .invalidListenerPort, .invalidLocalURL:
            return "Milo could not create its private local update-feed bridge."
        }
    }
}

/// Identifies one concrete listener generation so delayed cleanup cannot stop a newer bridge.
public struct MiloLoopbackAppcastEndpoint: Sendable, Equatable {
    public let url: URL
    fileprivate let identifier: UUID
}

/// Serves hash-verified appcast bytes over a short-lived, tokenized, IPv4-loopback-only endpoint.
/// All mutable state and Network.framework callbacks are confined to `queue`.
/// SAFETY: every mutable field is read or written only on `queue`, enforced by
/// dispatch preconditions at callback boundaries; public methods enqueue work.
public final class MiloLoopbackAppcastServer: @unchecked Sendable {
    private static let maximumRequestByteCount = 16_384
    private static let maximumConcurrentConnections = 8
    private static let maximumSuccessfulRequests = 3
    private static let requestTimeout: TimeInterval = 5
    private static let startupTimeout: TimeInterval = 10
    private static let lifetime: TimeInterval = 120

    private let queue = DispatchQueue(label: "com.monomacaw.milo.update-feed-loopback")
    private var listener: NWListener?
    private var expiryWorkItem: DispatchWorkItem?
    private var startContinuation: CheckedContinuation<MiloLoopbackAppcastEndpoint, Error>?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var requestExpiryWorkItems: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var payload = Data()
    private var expectedPath = ""
    private var expectedHost = ""
    private var successfulRequestCount = 0
    private var currentIdentifier: UUID?
    private var expiryIdentifier: UUID?

    /// Creates an idle loopback bridge with no open listener or retained appcast.
    public init() {}

    /// Starts a new listener and invalidates any prior listener owned by this instance.
    public func start(appcast: MiloVerifiedAppcast) async throws -> MiloLoopbackAppcastEndpoint {
        let identifier = UUID()
        try Task.checkCancellation()
        do {
            let endpoint = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    queue.async { [self] in
                        stopOnQueue(resumingWith: MiloLoopbackServerError.listenerFailed)
                        do {
                            let parameters = NWParameters.tcp
                            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                            parameters.allowLocalEndpointReuse = false
                            parameters.includePeerToPeer = false

                            let newListener = try NWListener(using: parameters)
                            payload = appcast.bytes
                            expectedPath = "/milo-update/\(makeToken())/appcast.xml"
                            successfulRequestCount = 0
                            currentIdentifier = identifier
                            startContinuation = continuation
                            listener = newListener

                            newListener.stateUpdateHandler = { [weak self] state in
                                self?.handleListenerState(state, identifier: identifier)
                            }
                            newListener.newConnectionHandler = { [weak self] connection in
                                self?.accept(connection, identifier: identifier)
                            }
                            newListener.start(queue: queue)
                            scheduleStop(after: Self.startupTimeout, listenerIdentifier: identifier)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: { [weak self] in
                Task {
                    await self?.stop(identifier: identifier)
                }
            }
            try Task.checkCancellation()
            return endpoint
        } catch {
            await stop(identifier: identifier)
            throw error
        }
    }

    /// Stops only the listener generation represented by `endpoint`.
    public func stop(endpoint: MiloLoopbackAppcastEndpoint) async {
        await stop(identifier: endpoint.identifier)
    }

    /// Cancels the listener and every accepted connection, then clears the verified bytes.
    public func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                stopOnQueue(resumingWith: MiloLoopbackServerError.listenerFailed)
                continuation.resume()
            }
        }
    }

    private func stop(identifier: UUID) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if currentIdentifier == identifier {
                    stopOnQueue(resumingWith: MiloLoopbackServerError.listenerFailed)
                }
                continuation.resume()
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State, identifier: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard currentIdentifier == identifier else {
            return
        }
        switch state {
        case .ready:
            guard let port = listener?.port else {
                stopOnQueue(resumingWith: MiloLoopbackServerError.invalidListenerPort)
                return
            }
            expectedHost = "127.0.0.1:\(port.rawValue)"
            guard let localURL = URL(string: "http://\(expectedHost)\(expectedPath)") else {
                stopOnQueue(resumingWith: MiloLoopbackServerError.invalidLocalURL)
                return
            }
            startContinuation?.resume(returning: MiloLoopbackAppcastEndpoint(
                url: localURL,
                identifier: identifier
            ))
            startContinuation = nil
            scheduleStop(after: Self.lifetime, listenerIdentifier: identifier)
        case .failed:
            stopOnQueue(resumingWith: MiloLoopbackServerError.listenerFailed)
        case .cancelled:
            stopOnQueue(resumingWith: MiloLoopbackServerError.listenerFailed)
        case .setup, .waiting:
            break
        @unknown default:
            stopOnQueue(resumingWith: MiloLoopbackServerError.listenerFailed)
        }
    }

    private func accept(_ connection: NWConnection, identifier: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard listener != nil, currentIdentifier == identifier else {
            connection.cancel()
            return
        }
        guard activeConnections.count < Self.maximumConcurrentConnections else {
            connection.cancel()
            return
        }
        let connectionID = ObjectIdentifier(connection)
        activeConnections[connectionID] = connection
        let requestExpiryWorkItem = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else {
                return
            }
            finish(connection)
        }
        requestExpiryWorkItems[connectionID] = requestExpiryWorkItem
        queue.asyncAfter(deadline: .now() + Self.requestTimeout, execute: requestExpiryWorkItem)
        connection.start(queue: queue)
        receiveRequest(from: connection, accumulated: Data())
    }

    private func receiveRequest(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            dispatchPrecondition(condition: .onQueue(queue))
            guard activeConnections[ObjectIdentifier(connection)] != nil else {
                connection.cancel()
                return
            }

            var requestData = accumulated
            if let data {
                requestData.append(data)
            }
            guard requestData.count <= Self.maximumRequestByteCount else {
                sendError(status: "431 Request Header Fields Too Large", connection: connection)
                return
            }
            if requestData.range(of: Data("\r\n\r\n".utf8)) != nil {
                handleRequest(requestData, connection: connection)
                return
            }
            if error != nil || isComplete {
                finish(connection)
                return
            }
            receiveRequest(from: connection, accumulated: requestData)
        }
    }

    private func handleRequest(_ requestData: Data, connection: NWConnection) {
        guard let request = String(data: requestData, encoding: .utf8) else {
            sendError(status: "400 Bad Request", connection: connection)
            return
        }
        let headerLines = request.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else {
            sendError(status: "400 Bad Request", connection: connection)
            return
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard requestParts.count == 3,
              requestParts[0] == "GET",
              requestParts[1] == Substring(expectedPath),
              requestParts[2] == "HTTP/1.1" || requestParts[2] == "HTTP/1.0",
              hasExpectedHost(in: headerLines) else {
            sendError(status: "404 Not Found", connection: connection)
            return
        }
        guard successfulRequestCount < Self.maximumSuccessfulRequests else {
            sendError(status: "404 Not Found", connection: connection)
            return
        }

        let responseHead = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/rss+xml",
            "Content-Length: \(payload.count)",
            "Cache-Control: no-store, max-age=0",
            "X-Content-Type-Options: nosniff",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        var response = Data(responseHead.utf8)
        response.append(payload)
        successfulRequestCount += 1
        let listenerIdentifier = currentIdentifier
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            guard let self else {
                connection.cancel()
                return
            }
            dispatchPrecondition(condition: .onQueue(queue))
            finish(connection)
            if currentIdentifier == listenerIdentifier,
               successfulRequestCount >= Self.maximumSuccessfulRequests {
                stopOnQueue(resumingWith: MiloLoopbackServerError.listenerFailed)
            }
        })
    }

    private func hasExpectedHost(in headerLines: [String]) -> Bool {
        let hostValues = headerLines.dropFirst().compactMap { line -> String? in
            guard let separator = line.firstIndex(of: ":") else {
                return nil
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "host" else {
                return nil
            }
            return line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        return hostValues.count == 1 && hostValues[0] == expectedHost
    }

    private func sendError(status: String, connection: NWConnection) {
        let response = Data(
            "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8
        )
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            guard let self else {
                connection.cancel()
                return
            }
            finish(connection)
        })
    }

    private func finish(_ connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        requestExpiryWorkItems.removeValue(forKey: connectionID)?.cancel()
        activeConnections.removeValue(forKey: connectionID)
        connection.cancel()
    }

    private func scheduleStop(after interval: TimeInterval, listenerIdentifier: UUID) {
        expiryWorkItem?.cancel()
        let scheduledExpiryIdentifier = UUID()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  currentIdentifier == listenerIdentifier,
                  expiryIdentifier == scheduledExpiryIdentifier else {
                return
            }
            stopOnQueue(resumingWith: MiloLoopbackServerError.listenerFailed)
        }
        expiryIdentifier = scheduledExpiryIdentifier
        expiryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    private func stopOnQueue(resumingWith error: Error) {
        dispatchPrecondition(condition: .onQueue(queue))
        expiryWorkItem?.cancel()
        expiryWorkItem = nil
        expiryIdentifier = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in activeConnections.values {
            connection.cancel()
        }
        for workItem in requestExpiryWorkItems.values {
            workItem.cancel()
        }
        requestExpiryWorkItems.removeAll(keepingCapacity: false)
        activeConnections.removeAll(keepingCapacity: false)
        payload.removeAll(keepingCapacity: false)
        expectedPath = ""
        expectedHost = ""
        successfulRequestCount = 0
        currentIdentifier = nil
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: error)
        }
    }

    private func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let randomBytes = (0 ..< 32).map { _ in UInt8.random(in: UInt8.min ... UInt8.max, using: &generator) }
        return randomBytes.map { String(format: "%02x", $0) }.joined()
    }
}
