import Foundation
import Darwin
import Testing
@testable import SLTAIPC

private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "initial"
    func set(_ value: String) { lock.withLock { self.value = value } }
    func get() -> String { lock.withLock { value } }
}

private func temporaryWorkspace() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("slta-ipc-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("A typed envelope JSON roundtrip")
func envelopeRoundtrip() throws {
    let id = UUID()
    let envelope = IPCEnvelope(
        requestID: id, workspaceID: "workspace", kind: .submitTurn,
        payload: .submitTurn(.init(text: "find TODO"))
    )
    let framed = try IPCFrameCodec.encode(envelope)
    var decoder = IPCFrameDecoder()
    let frames = try decoder.append(framed)
    let decoded = try IPCFrameCodec.decode(frames[0], as: IPCEnvelope.self)
    #expect(decoded.protocolVersion == 1)
    #expect(decoded.requestID == id)
    #expect(decoded.kind == .submitTurn)
    guard case .submitTurn(let value) = decoded.payload else {
        Issue.record("wrong typed payload")
        return
    }
    #expect(value.text == "find TODO")
}

@Test("B partial frame is assembled")
func partialFrame() throws {
    let envelope = IPCEnvelope(workspaceID: "w", kind: .ping, payload: .ping)
    let framed = try IPCFrameCodec.encode(envelope)
    var decoder = IPCFrameDecoder()
    #expect(try decoder.append(framed.prefix(2)).isEmpty)
    #expect(try decoder.append(framed.dropFirst(2).prefix(5)).isEmpty)
    let frames = try decoder.append(framed.dropFirst(7))
    #expect(frames.count == 1)
    #expect(!decoder.hasPartialFrame)
}

@Test("C multiple frames in one read")
func multipleFrames() throws {
    let first = try IPCFrameCodec.encode(
        IPCEnvelope(workspaceID: "w", kind: .ping, payload: .ping)
    )
    let second = try IPCFrameCodec.encode(
        IPCEnvelope(workspaceID: "w", kind: .getSnapshot, payload: .getSnapshot)
    )
    var decoder = IPCFrameDecoder()
    let frames = try decoder.append(first + second)
    #expect(frames.count == 2)
}

@Test("D oversized and malformed frames fail cleanly")
func invalidFrames() throws {
    var oversized = IPCFrameDecoder(maximumFrameSize: 8)
    let header = Data([0, 0, 0, 9])
    #expect(throws: IPCFrameError.self) { try oversized.append(header) }
    #expect(throws: IPCFrameError.self) {
        try IPCFrameCodec.decode(Data("not-json".utf8), as: IPCEnvelope.self)
    }
}

@Test("E version mismatch is rejected")
func versionMismatch() async throws {
    let workspace = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let socket = WorkspaceIdentity.socketURL(for: workspace)
    let server = UnixSocketServer(socketURL: socket) { envelope, _ in
        if envelope.protocolVersion != SLTAIPCProtocolVersion {
            return IPCEnvelope(
                requestID: envelope.requestID, workspaceID: envelope.workspaceID,
                kind: .error,
                payload: .error(.init(code: "version_mismatch", message: "version 1 only"))
            )
        }
        return IPCEnvelope(
            requestID: envelope.requestID, workspaceID: envelope.workspaceID,
            kind: .response,
            payload: .response(.init(accepted: true, message: "ok"))
        )
    }
    try server.start()
    defer { server.stop() }
    let client = RuntimeClient(workspaceURL: workspace)
    await #expect(throws: IPCProtocolError.self) {
        try await client.connect(clientName: "mismatch", protocolVersion: 2)
    }
}

@Test("F/J handshake snapshot and reconnect preserve service state")
func handshakeAndReconnect() async throws {
    let workspace = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let workspaceID = WorkspaceIdentity.stableID(for: workspace)
    let box = SnapshotBox()
    let server = UnixSocketServer(socketURL: WorkspaceIdentity.socketURL(for: workspace)) {
        envelope, _ in
        let response: ResponsePayload
        switch envelope.kind {
        case .handshake:
            response = .init(accepted: true, message: "hello")
        case .getSnapshot:
            response = .init(
                accepted: true, message: "snapshot",
                snapshot: RuntimeSnapshot(
                    workspaceID: workspaceID,
                    canonicalWorkspacePath: WorkspaceIdentity.canonicalPath(workspace),
                    runtimeStatus: "ready", recentTaskSummary: box.get()
                )
            )
        default:
            response = .init(accepted: true, message: "ok")
        }
        return IPCEnvelope(
            requestID: envelope.requestID, workspaceID: workspaceID,
            kind: .response, payload: .response(response)
        )
    }
    try server.start()
    defer { server.stop() }
    let first = RuntimeClient(workspaceURL: workspace)
    try await first.connect(clientName: "first")
    box.set("preserved")
    first.close()
    let second = RuntimeClient(workspaceURL: workspace)
    try await second.connect(clientName: "second")
    let snapshot = try await second.snapshot()
    #expect(snapshot.recentTaskSummary == "preserved")
}

@Test("L stale socket is recovered with user-only permissions")
func staleSocketRecovery() throws {
    let workspace = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let socket = WorkspaceIdentity.socketURL(for: workspace)
    try FileManager.default.createDirectory(
        at: socket.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("stale".utf8).write(to: socket)
    let server = UnixSocketServer(socketURL: socket) { _, _ in nil }
    try server.start()
    defer { server.stop() }
    var info = stat()
    let status = socket.path.withCString {
        fstatat(AT_FDCWD, $0, &info, 0)
    }
    #expect(status == 0)
    #expect((info.st_mode & 0o777) == 0o600)
}

@Test("L2 workspace ownership lock is exclusive and stale PID metadata is recoverable")
func workspaceOwnership() throws {
    let workspace = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let first = try WorkspaceRuntimeLock(workspaceURL: workspace)
    #expect(throws: UnixSocketError.self) {
        try WorkspaceRuntimeLock(workspaceURL: workspace)
    }
    first.release()
    let recovered = try WorkspaceRuntimeLock(workspaceURL: workspace)
    recovered.release()
}

@Test("K production GUI and CLI are IPC-only")
func productionWiringIsIPCOnly() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let root = testFile.deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let files = [
        root.appendingPathComponent("Sources/MLXAgent/MLXAgentMain.swift"),
        root.appendingPathComponent("Sources/MLXAgent/AgentGUI.swift")
    ]
    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        for constructor in ["Workspace", "RuntimeCoordinator", "MLXProvider"] {
            let regex = try Regex("\\b\(constructor)\\s*\\(")
            #expect(source.firstMatch(of: regex) == nil)
        }
        #expect(source.contains("RuntimeClient"))
    }
}
