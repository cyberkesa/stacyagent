import Foundation
import Darwin

public enum UnixSocketError: Error, CustomStringConvertible, Sendable {
    case system(operation: String, code: Int32)
    case pathTooLong
    case alreadyRunning
    case notConnected

    public var description: String {
        switch self {
        case .system(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        case .pathTooLong: return "Unix socket path is too long"
        case .alreadyRunning: return "runtime already owns this workspace socket"
        case .notConnected: return "runtime client is not connected"
        }
    }
}

public final class WorkspaceRuntimeLock: @unchecked Sendable {
    public let lockURL: URL
    private let lock = NSLock()
    private var fd: Int32

    public init(workspaceURL: URL) throws {
        lockURL = WorkspaceIdentity.lockURL(for: workspaceURL)
        let directory = lockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(directory.path, 0o700)
        let opened = Darwin.open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard opened >= 0 else {
            throw UnixSocketError.system(operation: "open runtime lock", code: errno)
        }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(opened)
            if code == EWOULDBLOCK { throw UnixSocketError.alreadyRunning }
            throw UnixSocketError.system(operation: "lock runtime", code: code)
        }
        fd = opened
        _ = ftruncate(opened, 0)
        let metadata = Data("pid=\(getpid())\n".utf8)
        try? UnixSocketSupport.sendAll(fd: opened, data: metadata)
        _ = chmod(lockURL.path, 0o600)
    }

    public func release() {
        let value = lock.withLock { () -> Int32 in
            let value = fd
            fd = -1
            return value
        }
        if value >= 0 {
            _ = flock(value, LOCK_UN)
            Darwin.close(value)
        }
    }

    deinit { release() }
}

private enum UnixSocketSupport {
    static func address(path: String) throws -> (sockaddr_un, socklen_t) {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count + 1 <= capacity else { throw UnixSocketError.pathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { target in
                target.initialize(repeating: 0, count: capacity)
                for (index, byte) in bytes.enumerated() { target[index] = byte }
            }
        }
        let offset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path) ?? 2
        return (address, socklen_t(offset + bytes.count + 1))
    }

    static func socketFD() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.system(operation: "socket", code: errno) }
        var enabled: Int32 = 1
        _ = withUnsafePointer(to: &enabled) {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        return fd
    }

    static func connect(fd: Int32, path: String) throws {
        var (address, length) = try address(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        guard result == 0 else { throw UnixSocketError.system(operation: "connect", code: errno) }
    }

    static func sendAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw UnixSocketError.system(operation: "write", code: errno)
                }
                sent += count
            }
        }
    }
}

public final class IPCServerConnection: @unchecked Sendable, Hashable {
    public static func == (lhs: IPCServerConnection, rhs: IPCServerConnection) -> Bool {
        lhs === rhs
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    private let fd: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var closed = false

    fileprivate init(fd: Int32) { self.fd = fd }

    public func send(_ envelope: IPCEnvelope) throws {
        let frame = try IPCFrameCodec.encode(envelope)
        try writeLock.withLock {
            guard stateLock.withLock({ !closed }) else { throw IPCProtocolError.disconnected }
            try UnixSocketSupport.sendAll(fd: fd, data: frame)
        }
    }

    public func close() {
        let shouldClose = stateLock.withLock { () -> Bool in
            if closed { return false }
            closed = true
            return true
        }
        if shouldClose {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }
}

public final class UnixSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (IPCEnvelope, IPCServerConnection) async -> IPCEnvelope?

    public let socketURL: URL
    private let handler: Handler
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var connections: Set<IPCServerConnection> = []
    private var stopped = false
    private let acceptQueue = DispatchQueue(label: "slta.ipc.accept")

    public init(socketURL: URL, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    public func start() throws {
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(directory.path, 0o700)

        if FileManager.default.fileExists(atPath: socketURL.path) {
            if let probe = try? UnixSocketSupport.socketFD() {
                defer { Darwin.close(probe) }
                if (try? UnixSocketSupport.connect(fd: probe, path: socketURL.path)) != nil {
                    throw UnixSocketError.alreadyRunning
                }
            }
            try FileManager.default.removeItem(at: socketURL)
        }

        let fd = try UnixSocketSupport.socketFD()
        do {
            var (address, length) = try UnixSocketSupport.address(path: socketURL.path)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, length)
                }
            }
            guard bound == 0 else { throw UnixSocketError.system(operation: "bind", code: errno) }
            guard Darwin.listen(fd, 16) == 0 else {
                throw UnixSocketError.system(operation: "listen", code: errno)
            }
            _ = chmod(socketURL.path, 0o600)
            lock.withLock {
                listenerFD = fd
                stopped = false
            }
        } catch {
            Darwin.close(fd)
            throw error
        }

        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        let state = lock.withLock { () -> (Int32, [IPCServerConnection]) in
            if stopped { return (-1, []) }
            stopped = true
            let fd = listenerFD
            listenerFD = -1
            let active = Array(connections)
            connections.removeAll()
            return (fd, active)
        }
        if state.0 >= 0 {
            Darwin.shutdown(state.0, SHUT_RDWR)
            Darwin.close(state.0)
        }
        state.1.forEach { $0.close() }
        try? FileManager.default.removeItem(at: socketURL)
    }

    public func broadcast(_ envelope: IPCEnvelope) {
        let active = lock.withLock { Array(connections) }
        for connection in active {
            do { try connection.send(envelope) }
            catch { remove(connection) }
        }
    }

    private func acceptLoop() {
        while true {
            let fd = lock.withLock { listenerFD }
            guard fd >= 0 else { return }
            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                if lock.withLock({ stopped }) { return }
                continue
            }
            var enabled: Int32 = 1
            _ = withUnsafePointer(to: &enabled) {
                setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
            }
            let connection = IPCServerConnection(fd: clientFD)
            _ = lock.withLock { connections.insert(connection) }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.readLoop(connection: connection, fd: clientFD)
            }
        }
    }

    private func readLoop(connection: IPCServerConnection, fd: Int32) {
        var decoder = IPCFrameDecoder()
        var storage = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = storage.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            do {
                let frames = try decoder.append(Data(storage[0..<count]))
                for frame in frames {
                    let envelope = try IPCFrameCodec.decode(frame, as: IPCEnvelope.self)
                    Task { [handler] in
                        if let response = await handler(envelope, connection) {
                            try? connection.send(response)
                        }
                    }
                }
            } catch {
                let response = IPCEnvelope(
                    requestID: UUID(), workspaceID: "", kind: .error,
                    payload: .error(.init(code: "malformed_frame", message: String(describing: error)))
                )
                try? connection.send(response)
                break
            }
        }
        remove(connection)
    }

    private func remove(_ connection: IPCServerConnection) {
        _ = lock.withLock { connections.remove(connection) }
        connection.close()
    }

    deinit { stop() }
}

public final class RuntimeClient: @unchecked Sendable {
    public typealias EventHandler = @Sendable (RuntimeEvent) -> Void

    public let workspaceURL: URL
    public let workspaceID: String
    public let socketURL: URL
    private let requestLock = NSLock()
    private let stateLock = NSLock()
    private var fd: Int32 = -1
    private var decoder = IPCFrameDecoder()
    private var pendingFrames: [IPCEnvelope] = []
    private var eventHandler: EventHandler?

    public init(workspaceURL: URL, eventHandler: EventHandler? = nil) {
        self.workspaceURL = URL(fileURLWithPath: WorkspaceIdentity.canonicalPath(workspaceURL))
        self.workspaceID = WorkspaceIdentity.stableID(for: workspaceURL)
        self.socketURL = WorkspaceIdentity.socketURL(for: workspaceURL)
        self.eventHandler = eventHandler
    }

    public func setEventHandler(_ handler: EventHandler?) {
        stateLock.withLock { eventHandler = handler }
    }

    public func connect(
        clientName: String = "mlxagent",
        protocolVersion: Int = SLTAIPCProtocolVersion
    ) async throws {
        try await Task.detached { [self] in
            try requestLock.withLock {
                closeLocked()
                let socket = try UnixSocketSupport.socketFD()
                do { try UnixSocketSupport.connect(fd: socket, path: socketURL.path) }
                catch { Darwin.close(socket); throw error }
                stateLock.withLock { fd = socket; decoder = IPCFrameDecoder(); pendingFrames = [] }
                do {
                    let response = try performLocked(
                        kind: .handshake,
                        payload: .handshake(.init(
                            clientName: clientName, supportedVersion: protocolVersion
                        )),
                        protocolVersion: protocolVersion
                    )
                    guard case .response(let value) = response.payload, value.accepted else {
                        throw IPCProtocolError.invalidPayload("handshake rejected")
                    }
                } catch {
                    closeLocked()
                    throw error
                }
            }
        }.value
    }

    public func openWorkspace() async throws -> RuntimeSnapshot? {
        let response = try await request(
            kind: .openWorkspace,
            payload: .openWorkspace(.init(canonicalPath: workspaceURL.path))
        )
        guard case .response(let value) = response.payload else {
            throw IPCProtocolError.invalidPayload("openWorkspace response")
        }
        return value.snapshot
    }

    public func submit(_ text: String) async throws -> RuntimeSnapshot? {
        let response = try await request(
            kind: .submitTurn, payload: .submitTurn(.init(text: text))
        )
        guard case .response(let value) = response.payload else {
            throw IPCProtocolError.invalidPayload("submit response")
        }
        return value.snapshot
    }

    public func snapshot() async throws -> RuntimeSnapshot {
        let response = try await request(kind: .getSnapshot, payload: .getSnapshot)
        guard case .response(let value) = response.payload, let snapshot = value.snapshot else {
            throw IPCProtocolError.invalidPayload("snapshot response")
        }
        return snapshot
    }

    public func ping() async throws {
        let response = try await request(kind: .ping, payload: .ping)
        guard response.kind == .pong else { throw IPCProtocolError.invalidPayload("pong") }
    }

    /// Uses a short-lived second connection so cancellation is not queued behind submit.
    public func cancel(taskID: String) async throws {
        let side = RuntimeClient(workspaceURL: workspaceURL)
        try await side.connect(clientName: "mlxagent-cancel")
        defer { side.close() }
        let response = try await side.request(
            kind: .cancelTask, payload: .cancelTask(.init(taskID: taskID))
        )
        guard case .response(let value) = response.payload, value.accepted else {
            throw IPCProtocolError.invalidPayload("cancel rejected")
        }
    }

    public func shutdown() async throws {
        _ = try await request(kind: .shutdown, payload: .shutdown)
    }

    public func reconnect(clientName: String = "mlxagent") async throws -> RuntimeSnapshot {
        close()
        try await connect(clientName: clientName)
        return try await snapshot()
    }

    public func close() {
        requestLock.withLock { closeLocked() }
    }

    private func request(kind: IPCMessageKind, payload: IPCPayload) async throws -> IPCEnvelope {
        try await Task.detached { [self] in
            try requestLock.withLock { try performLocked(kind: kind, payload: payload) }
        }.value
    }

    private func performLocked(
        kind: IPCMessageKind,
        payload: IPCPayload,
        protocolVersion: Int = SLTAIPCProtocolVersion
    ) throws -> IPCEnvelope {
        let socket = stateLock.withLock { fd }
        guard socket >= 0 else { throw UnixSocketError.notConnected }
        let request = IPCEnvelope(
            protocolVersion: protocolVersion,
            workspaceID: workspaceID, kind: kind, payload: payload
        )
        try UnixSocketSupport.sendAll(fd: socket, data: try IPCFrameCodec.encode(request))
        while true {
            if let index = pendingFrames.firstIndex(where: { $0.requestID == request.requestID }) {
                return try validate(pendingFrames.remove(at: index))
            }
            let envelopes = try receive(fd: socket)
            var matchingResponse: IPCEnvelope?
            for envelope in envelopes {
                if envelope.kind == .event, case .event(let event) = envelope.payload {
                    stateLock.withLock { eventHandler }?(event)
                } else if envelope.requestID == request.requestID {
                    matchingResponse = envelope
                } else {
                    pendingFrames.append(envelope)
                }
            }
            if let matchingResponse { return try validate(matchingResponse) }
        }
    }

    private func validate(_ envelope: IPCEnvelope) throws -> IPCEnvelope {
        if case .error(let error) = envelope.payload {
            if error.code == "version_mismatch" {
                throw IPCProtocolError.versionMismatch(
                    expected: SLTAIPCProtocolVersion,
                    received: envelope.protocolVersion
                )
            }
            throw IPCProtocolError.remote(error)
        }
        return envelope
    }

    private func receive(fd: Int32) throws -> [IPCEnvelope] {
        var storage = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = storage.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw IPCProtocolError.disconnected }
            let frames = try decoder.append(Data(storage[0..<count]))
            if !frames.isEmpty {
                return try frames.map { try IPCFrameCodec.decode($0, as: IPCEnvelope.self) }
            }
        }
    }

    private func closeLocked() {
        let socket = stateLock.withLock { () -> Int32 in
            let value = fd
            fd = -1
            pendingFrames = []
            decoder = IPCFrameDecoder()
            return value
        }
        if socket >= 0 {
            Darwin.shutdown(socket, SHUT_RDWR)
            Darwin.close(socket)
        }
    }

    deinit {
        let socket = stateLock.withLock { fd }
        if socket >= 0 { Darwin.close(socket) }
    }
}
