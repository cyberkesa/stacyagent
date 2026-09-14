import Foundation

struct PersistedSessionTurn: Codable, Sendable {
    let user: String
    let assistant: String
    let mode: String
    let status: String
}

struct PersistedArtifactProjection: Codable, Sendable {
    let id: String
    let path: String
    let type: String
    let originTask: String?
    let revision: Int
    let wasRead: Bool
    let wasMutated: Bool
    let wasValidated: Bool
    let wasOpened: Bool
    let minimumLineCount: Int?
}

struct PersistedSessionState: Codable, Sendable {
    let schemaVersion: Int
    let projectPath: String
    let eventCount: Int
    let turns: [PersistedSessionTurn]
    let lastProjectRequest: String?
    let lastOperationalRequest: String?
    let lastProjectMode: String?
    let lastTaskID: String?
    let lastTaskKinds: [String]
    let artifacts: [PersistedArtifactProjection]
    let artifactOrder: [String]
    let lastArtifact: String?
    let lastOpenedArtifact: String?
    let lastExternalURL: String?
    let previousRequiredLaunch: Bool
    let previousTaskComplete: Bool
    let lastTaskMutationCount: Int
    let lastFailure: String?
}

struct SessionPersistence: Sendable {
    let directory: URL
    let stateURL: URL
    let eventsURL: URL

    init(projectPath: String) {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".stacyagent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)

        let projectName = URL(fileURLWithPath: projectPath)
            .lastPathComponent
            .replacingOccurrences(
                of: #"[^A-Za-z0-9._-]+"#,
                with: "-",
                options: .regularExpression
            )

        let key = projectName + "-" + Self.fnv1a(projectPath)
        directory = base.appendingPathComponent(key, isDirectory: true)
        stateURL = directory.appendingPathComponent("state.json")
        eventsURL = directory.appendingPathComponent("events.jsonl")

        try? fm.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func load() -> PersistedSessionState? {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(
                  PersistedSessionState.self,
                  from: data
              ) else {
            return nil
        }
        return state
    }

    func save(_ state: PersistedSessionState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(state) else {
            return
        }

        try? data.write(to: stateURL, options: .atomic)
    }

    func appendEvent(
        kind: String,
        fields: [String: String] = [:]
    ) {
        var object = fields
        object["kind"] = kind
        object["timestamp"] = ISO8601DateFormatter().string(from: Date())

        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys]
              ) else {
            return
        }

        data.append(0x0A)

        if !FileManager.default.fileExists(atPath: eventsURL.path) {
            _ = FileManager.default.createFile(
                atPath: eventsURL.path,
                contents: data
            )
            return
        }

        guard let handle = try? FileHandle(forWritingTo: eventsURL) else {
            return
        }
        defer { try? handle.close() }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }

    func clearState() {
        try? FileManager.default.removeItem(at: stateURL)
        appendEvent(kind: "session.clear")
    }

    private static func fnv1a(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
