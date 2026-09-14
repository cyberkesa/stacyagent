import Foundation

// MARK: - v0.29 Persistent runtime store
//
// Versioned per-project truth snapshot: artifact graph metadata + revision
// records, typed evidence journal, active task spec + specialized
// requirements, continuity needed for restore. File contents are NOT
// duplicated here — EditEngine snapshot files stay the content source;
// revision records (with content hashes) re-anchor evidence after restart.
//
// Layout reuses the SessionPersistence project-key scheme
// (projectName-fnv1a) under ~/.stacyagent/runtime/<key>/ — no conflict with
// ~/.stacyagent/sessions/ or ~/.stacyagent/edit-history/.

struct PersistedRuntimeState: Codable, Sendable {
    var schemaVersion: Int
    var projectID: String
    var projectPath: String
    var savedAt: Date
    var spec: TaskSpec?
    /// Specialized (exact-target) requirements: the live runtime truth,
    /// not the freshly compiled (.any) form.
    var requirements: [TaskRequirement]
    /// 1:1 with rebuilt legacy items; revision linkage for freshness.
    var records: [EvidenceRecord]
    var itemRevisions: [UUID?]
    var current: [String: UUID]
    var lastFailure: String?
    var artifacts: PersistedArtifactGraph
}

struct RuntimePersistence: Sendable {
    static let schemaVersion = 1
    let directory: URL
    let stateURL: URL

    init(projectPath: String) {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".stacyagent", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
        let projectName = URL(fileURLWithPath: projectPath)
            .lastPathComponent
            .replacingOccurrences(
                of: #"[^A-Za-z0-9._-]+"#,
                with: "-",
                options: .regularExpression
            )
        let key = projectName + "-" + Self.fnv1a(projectPath)
        directory = base.appendingPathComponent(key, isDirectory: true)
        stateURL = directory.appendingPathComponent("runtime-state.json")
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load() -> PersistedRuntimeState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        let decoder = JSONDecoder()
        guard let state = try? decoder.decode(PersistedRuntimeState.self, from: data),
              state.schemaVersion == Self.schemaVersion else {
            return nil
        }
        return state
    }

    func save(_ state: PersistedRuntimeState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: stateURL)
    }

    static func fnv1a(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
