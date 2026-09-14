import Foundation

// MARK: - v0.30 Code Intelligence Foundation (provider-neutral core)
//
// Deterministic knowledge about code. No MLX imports, no LSP types,
// no ModelProvider/RuntimeState/EditEngine/ToolRegistry references.
// A provider receives data snapshots + queries and returns data results.
// Files are NEVER written by a provider; the runtime applies edits through
// the existing EditEngine (Workspace.applySemanticPlan).
//
// Internal text coordinates are ALWAYS UTF-8 byte offsets bound to an
// exact ArtifactRevisionID. LSP line/character (UTF-16) positions are
// converted on the provider boundary (UTF8SpanConverter below).

// MARK: - Identity

struct CodeIntelligenceProviderID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }
}

struct CodeIntelligenceCapabilities: Sendable {
    var documentSymbols: Bool
    var workspaceSymbols: Bool
    var definition: Bool
    var references: Bool
    var prepareRename: Bool
    var rename: Bool
    var diagnostics: Bool

    static let none = CodeIntelligenceCapabilities(
        documentSymbols: false, workspaceSymbols: false, definition: false,
        references: false, prepareRename: false, rename: false, diagnostics: false
    )
    static let full = CodeIntelligenceCapabilities(
        documentSymbols: true, workspaceSymbols: true, definition: true,
        references: true, prepareRename: true, rename: true, diagnostics: true
    )
}

// MARK: - Snapshots & facts

/// Exact document state a query runs against. Content travels WITH the
/// query so providers never read the disk behind the runtime's back.
struct CodeDocumentSnapshot: Sendable {
    /// Canonical workspace-relative path.
    var path: String
    var revision: ArtifactRevisionID
    /// EditEngine revision number (monotonic per path; LSP doc version).
    var revisionNumber: Int
    var contentHash: String
    var languageID: String
    var content: String
}

/// Revision-scoped symbol. The id is unique per (provider, revision).
struct CodeSymbol: Sendable, Hashable {
    var id: String
    var name: String
    var kind: CodeSymbolKind
    /// Canonical path of the defining document.
    var path: String
    /// Name span (UTF-8 byte offsets in the snapshot content).
    var nameSpan: CodeSpan
    /// Full declaration span, if known.
    var fullSpan: CodeSpan?
    var container: String?
    var detail: String?
    /// Opaque provider tag (e.g. "lsp:23"). Never interpreted by runtime.
    var providerTag: String?
}

enum CodeSymbolKind: String, Sendable, Codable {
    case `class`, interface, `struct`, `enum`, function, method, property
    case variable, constant, typeParameter, namespace, other
}

/// UTF-8 byte span bound to an exact revision. Half-open [start, end).
struct CodeSpan: Sendable, Hashable, Codable {
    var revision: ArtifactRevisionID
    var startByte: Int
    var endByte: Int
}

struct CodeLocation: Sendable, Hashable {
    var path: String
    var revision: ArtifactRevisionID
    var span: CodeSpan
}

/// Explicitly unresolved location: server coordinates preserved, but NO
/// revision is claimed (a fake revision would be a lie). The engine
/// snapshots the target file and binds the real revision before any use.
struct UnresolvedLocation: Sendable, Hashable {
    var path: String
    var startLine: Int?
    var startCharacter: Int?
    var endLine: Int?
    var endCharacter: Int?
}

/// Explicitly unresolved workspace symbol: identity without spans.
/// The engine re-resolves per file for exact snapshot-bound spans.
struct UnresolvedSymbol: Sendable, Hashable {
    var name: String
    var kind: CodeSymbolKind
    var path: String
    var container: String?
    var startLine: Int?
    var startCharacter: Int?
    var endLine: Int?
    var endCharacter: Int?
}

/// One replacement on an exact base revision.
struct SemanticTextEdit: Sendable {
    var path: String
    var baseRevision: ArtifactRevisionID
    var startByteOffset: Int
    var endByteOffset: Int
    var replacement: String
}

enum SemanticEditSource: String, Sendable {
    case rename
}

/// Multi-file edit plan. The runtime validates and applies it through
/// EditEngine; the provider NEVER writes.
struct SemanticWorkspaceEdit: Sendable {
    var edits: [SemanticTextEdit]
    var source: SemanticEditSource
    var provider: CodeIntelligenceProviderID
    /// Symbol-level basis, e.g. "rename UserManager->AccountManager".
    var basis: String
}

/// Provider diagnostic bound to the revision it was computed for.
struct DiagnosticFact: Sendable {
    var path: String
    var revision: ArtifactRevisionID
    var message: String
    var severity: String
}

// MARK: - Queries & results

enum SemanticQuery: Sendable {
    case documentSymbols(CodeDocumentSnapshot)
    case workspaceSymbols(String)
    case definition(CodeDocumentSnapshot, byteOffset: Int)
    case references(CodeDocumentSnapshot, byteOffset: Int)
    case prepareRename(CodeDocumentSnapshot, byteOffset: Int)
    /// Rename with additional file snapshots as context: the provider may
    /// only base cross-file edits on snapshots the engine supplied.
    /// Edits for files outside target+context are stale by construction.
    case rename(CodeDocumentSnapshot, byteOffset: Int, newName: String, context: [CodeDocumentSnapshot] = [])
    case diagnostics(CodeDocumentSnapshot)
}

enum SemanticQueryResult: Sendable {
    /// Snapshot-bound symbols (document queries with exact content).
    case symbols([CodeSymbol])
    /// Index hits without snapshot basis (paths + server ranges only).
    case workspaceSymbols([UnresolvedSymbol])
    /// Reference/definition hits without snapshot basis.
    case locations([UnresolvedLocation])
    case renameRange(CodeSpan?)
    case workspaceEdit(SemanticWorkspaceEdit)
    case diagnostics([DiagnosticFact])
    case unsupported(String)
}

enum CodeIntelligenceError: Error, Sendable {
    case unsupported(String)
    case unavailable(String)
    case staleBasis(String)
    case invalidQuery(String)
    case providerFailure(String)
}

// MARK: - Provider boundary

/// Deterministic semantic backend. Implementations MUST NOT reference
/// RuntimeCoordinator, ProtocolEngine, RuntimeState, EvidenceStore,
/// SessionContext, EditEngine, ToolRegistry or ModelProvider.
/// They receive snapshots/queries and return structured facts.
protocol CodeIntelligenceProvider: Sendable {
    var providerID: CodeIntelligenceProviderID { get }
    var capabilities: CodeIntelligenceCapabilities { get }
    func query(_ query: SemanticQuery) async throws -> SemanticQueryResult
}

// MARK: - UTF-8 span converter (boundary coordinate model)
//
// LSP positions are line/character in an encoding negotiated per server
// (default UTF-16). The runtime core NEVER sees them: providers convert to
// UTF-8 byte offsets against the EXACT snapshot content before returning.

enum UTF8SpanConverter {
    /// LSP (line, character-in-encoding) -> UTF-8 byte offset.
    /// Returns nil when out of bounds (caller rejects the plan).
    static func byteOffset(
        content: String,
        line: Int,
        character: Int,
        encoding: LSPPositionEncoding
    ) -> Int? {
        var remaining = content[...]
        var currentLine = 0
        while currentLine < line {
            guard let newline = remaining.firstIndex(of: "\n") else { return nil }
            remaining = remaining[remaining.index(after: newline)...]
            currentLine += 1
        }
        let lineText: Substring
        if let newline = remaining.firstIndex(of: "\n") {
            lineText = remaining[..<newline]
        } else {
            lineText = remaining
        }
        // Strip a trailing \r so \r\n files behave (offsets stay consistent
        // as long as conversion and application share the same content).
        let effective = lineText.hasSuffix("\r") ? lineText.dropLast() : lineText[...]
        guard let byteCount = utf8PrefixBytes(of: String(effective), units: character, encoding: encoding) else {
            return nil
        }
        let lineStart = content.utf8.count - remaining.utf8.count
        return lineStart + byteCount
    }

    private static func utf8PrefixBytes(of line: String, units: Int, encoding: LSPPositionEncoding) -> Int? {
        guard units >= 0 else { return nil }
        var consumedUnits = 0
        var bytes = 0
        for scalar in line.unicodeScalars {
            let width: Int
            switch encoding {
            case .utf16: width = scalar.value >= 0x10000 ? 2 : 1
            case .utf8: width = 1
            case .utf32: width = 1
            }
            if consumedUnits + width > units { break }
            consumedUnits += width
            bytes += scalar.utf8.count
        }
        guard consumedUnits == units else { return nil }
        return bytes
    }

    /// Inverse (for diagnostics display only, never for edits).
    static func lineAndCharacter(
        content: String,
        byteOffset: Int,
        encoding: LSPPositionEncoding
    ) -> (line: Int, character: Int)? {
        guard byteOffset >= 0, byteOffset <= content.utf8.count else { return nil }
        let prefix = content.utf8.prefix(byteOffset)
        guard let text = String(bytes: Array(prefix), encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let line = lines.count - 1
        let last = String(lines.last ?? "")
        var units = 0
        for scalar in last.unicodeScalars {
            switch encoding {
            case .utf16: units += scalar.value >= 0x10000 ? 2 : 1
            case .utf8: units += scalar.utf8.count
            case .utf32: units += 1
            }
        }
        return (line, units)
    }
}

enum LSPPositionEncoding: String, Sendable {
    case utf8 = "utf-8"
    case utf16 = "utf-16"
    case utf32 = "utf-32"
}

// MARK: - Explicit rename intent (§15 narrow deterministic recognizer)
//
// Matches ONLY unambiguous structural commands:
//   rename symbol UserManager to AccountManager
//   rename UserManager to AccountManager
//   переименуй UserManager в AccountManager
//   rename UserManager -> AccountManager
// with an optional `in <file>` scope. Anything else -> nil (normal flow
// may then ask the model). Swift identifier shape enforced.

struct SemanticRenameIntent: Sendable {
    var symbol: String
    var newName: String
    var path: String?

    private static let identifier = "[A-Za-z_][A-Za-z0-9_]*"

    static func parse(_ text: String) -> SemanticRenameIntent? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 300 else { return nil }
        let patterns = [
            #"(?i)^\s*rename\s+(?:symbol\s+|class\s+|struct\s+|func(?:tion)?\s+)?(\#(identifier))\s+to\s+(\#(identifier))(?:\s+in\s+(\S+))?\s*$"#,
            #"^\s*переименуй\s+(\#(identifier))\s+в\s+(\#(identifier))(?:\s+в\s+(?:файле\s+)?(\S+))?\s*$"#,
            #"(?i)^\s*rename\s+(\#(identifier))\s*->\s*(\#(identifier))(?:\s+in\s+(\S+))?\s*$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: trimmed,
                    range: NSRange(trimmed.startIndex..., in: trimmed)
                  ),
                  match.numberOfRanges >= 3,
                  let sRange = Range(match.range(at: 1), in: trimmed),
                  let nRange = Range(match.range(at: 2), in: trimmed) else {
                continue
            }
            let symbol = String(trimmed[sRange])
            let newName = String(trimmed[nRange])
            guard symbol != newName else { return nil }
            var path: String?
            if match.numberOfRanges >= 4,
               match.range(at: 3).location != NSNotFound,
               let pRange = Range(match.range(at: 3), in: trimmed) {
                path = String(trimmed[pRange]).trimmingCharacters(
                    in: CharacterSet(charactersIn: "`'\"")
                )
            }
            return SemanticRenameIntent(symbol: symbol, newName: newName, path: path)
        }
        return nil
    }
}
