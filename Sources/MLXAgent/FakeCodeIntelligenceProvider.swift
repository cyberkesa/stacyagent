import Foundation

// MARK: - v0.30 Fake code intelligence provider (deterministic tests)
//
// In-memory scripted backend. Positions are LSP-style (line, UTF-16
// character) so the EXACT same UTF8SpanConverter path is exercised as
// with the real LSP provider. Never reads or writes files.

struct FakeSymbolDef: Sendable {
    var name: String
    var kind: CodeSymbolKind
    var path: String
    /// LSP-style UTF-16 name span (line-based, 0-based).
    var line: Int
    var utf16Start: Int
    var utf16End: Int
    var container: String?
}

struct FakeEditDef: Sendable {
    var path: String
    var startLine: Int
    var startChar: Int
    var endLine: Int
    var endChar: Int
    var newText: String
}

struct FakeRefDef: Sendable {
    var path: String
    var line: Int
    var utf16Start: Int
    var utf16End: Int
}

final class FakeCodeIntelligenceProvider: CodeIntelligenceProvider, @unchecked Sendable {
    let providerID: CodeIntelligenceProviderID
    let capabilities: CodeIntelligenceCapabilities

    private let lock = NSLock()
    private var symbols: [FakeSymbolDef] = []
    private var contents: [String: String] = [:]
    private var renameEdits: [String: [FakeEditDef]] = [:]
    private var referenceTable: [String: [FakeRefDef]] = [:]
    private var diagnostics: [String: [DiagnosticFact]] = [:]
    private(set) var queryCount = 0
    private(set) var renameQueryCount = 0

    init(
        id: String = "fake-codeintel",
        capabilities: CodeIntelligenceCapabilities = .full
    ) {
        self.providerID = CodeIntelligenceProviderID(id)
        self.capabilities = capabilities
    }

    func define(contents: [String: String]) {
        lock.withLock { self.contents = contents }
    }

    func define(symbols: [FakeSymbolDef]) {
        lock.withLock { self.symbols = symbols }
    }

    func defineRename(symbol: String, newName: String, edits: [FakeEditDef]) {
        lock.withLock { self.renameEdits["\(symbol)->\(newName)"] = edits }
    }

    func defineReferences(symbol: String, refs: [FakeRefDef]) {
        lock.withLock { self.referenceTable[symbol] = refs }
    }

    func defineDiagnostics(_ items: [DiagnosticFact]) {
        lock.withLock {
            for item in items {
                self.diagnostics[item.path, default: []].append(item)
            }
        }
    }

    private func content(for path: String) -> String? {
        lock.withLock { contents[path] }
    }

    /// Diagnostics with their scripted revisions preserved verbatim:
    /// staleness is decided by the engine, never by the provider.
    func diagnosticsFor(path: String, revision: ArtifactRevisionID) -> [DiagnosticFact] {
        _ = revision
        return lock.withLock { diagnostics[path] ?? [] }
    }

    func query(_ query: SemanticQuery) async throws -> SemanticQueryResult {
        lock.withLock { queryCount += 1 }
        switch query {
        case .diagnostics(let snapshot):
            return .diagnostics(diagnosticsFor(
                path: snapshot.path, revision: snapshot.revision
            ))
        case .documentSymbols(let snapshot):
            let defs = lock.withLock { symbols.filter { $0.path == snapshot.path } }
            var out: [CodeSymbol] = []
            for def in defs {
                guard let start = UTF8SpanConverter.byteOffset(
                    content: snapshot.content, line: def.line,
                    character: def.utf16Start, encoding: .utf16
                ),
                let end = UTF8SpanConverter.byteOffset(
                    content: snapshot.content, line: def.line,
                    character: def.utf16End, encoding: .utf16
                ), start <= end else {
                    throw CodeIntelligenceError.providerFailure(
                        "fake symbol out of bounds: \(def.name)"
                    )
                }
                out.append(CodeSymbol(
                    id: "fake#\(def.path)#\(def.name)",
                    name: def.name,
                    kind: def.kind,
                    path: def.path,
                    nameSpan: CodeSpan(
                        revision: snapshot.revision,
                        startByte: start,
                        endByte: end
                    ),
                    fullSpan: nil,
                    container: def.container,
                    detail: nil,
                    providerTag: "fake"
                ))
            }
            return .symbols(out)

        case .workspaceSymbols(let pattern):
            let defs = lock.withLock {
                symbols.filter { $0.name.localizedCaseInsensitiveContains(pattern) }
            }
            // Explicitly unresolved: identity + server-style coordinates.
            // The engine re-resolves per file for snapshot-bound spans.
            var out: [UnresolvedSymbol] = []
            for def in defs {
                out.append(UnresolvedSymbol(
                    name: def.name,
                    kind: def.kind,
                    path: def.path,
                    container: def.container,
                    startLine: def.line, startCharacter: def.utf16Start,
                    endLine: def.line, endCharacter: def.utf16End
                ))
            }
            return .workspaceSymbols(out)

        case .definition(let snapshot, let byteOffset):
            // Explicitly unresolved: identity + server-style coordinates.
            // The engine snapshots and binds revisions before any use.
            let defs = lock.withLock { symbols.filter { $0.path == snapshot.path } }
            var out: [UnresolvedLocation] = []
            for def in defs {
                guard let start = UTF8SpanConverter.byteOffset(
                    content: snapshot.content, line: def.line,
                    character: def.utf16Start, encoding: .utf16
                ),
                let end = UTF8SpanConverter.byteOffset(
                    content: snapshot.content, line: def.line,
                    character: def.utf16End, encoding: .utf16
                ),
                start <= byteOffset, byteOffset <= end else {
                    continue
                }
                out.append(UnresolvedLocation(
                    path: def.path,
                    startLine: def.line, startCharacter: def.utf16Start,
                    endLine: def.line, endCharacter: def.utf16End
                ))
            }
            return .locations(out)

        case .references(let snapshot, let byteOffset):
            // Scripted reference table (models an index over usages).
            // Explicitly unresolved: coordinates preserved, no revision
            // claimed. The engine snapshots and binds before any use.
            var refsOut: [UnresolvedLocation] = []
            let target = lock.withLock { symbols }.first { def in
                guard def.path == snapshot.path,
                      let start = UTF8SpanConverter.byteOffset(
                        content: snapshot.content, line: def.line,
                        character: def.utf16Start, encoding: .utf16
                      ),
                      let end = UTF8SpanConverter.byteOffset(
                        content: snapshot.content, line: def.line,
                        character: def.utf16End, encoding: .utf16
                      ) else { return false }
                return start <= byteOffset && byteOffset <= end
            }
            for ref in lock.withLock({ target.flatMap { referenceTable[$0.name] } ?? [] }) {
                guard content(for: ref.path) != nil else { continue }
                refsOut.append(UnresolvedLocation(
                    path: ref.path,
                    startLine: ref.line, startCharacter: ref.utf16Start,
                    endLine: ref.line, endCharacter: ref.utf16End
                ))
            }
            return .locations(refsOut)

        case .prepareRename(let snapshot, let byteOffset):
            let text = String(
                snapshot.content.utf8.prefix(byteOffset)
                    .suffix(64)
            )
            _ = text
            let defs = lock.withLock { symbols.filter { $0.path == snapshot.path } }
            for def in defs {
                guard let start = UTF8SpanConverter.byteOffset(
                    content: snapshot.content, line: def.line,
                    character: def.utf16Start, encoding: .utf16
                ),
                let end = UTF8SpanConverter.byteOffset(
                    content: snapshot.content, line: def.line,
                    character: def.utf16End, encoding: .utf16
                ),
                start <= byteOffset, byteOffset <= end else {
                    continue
                }
                return .renameRange(CodeSpan(
                    revision: snapshot.revision,
                    startByte: start,
                    endByte: end
                ))
            }
            return .renameRange(nil)

        case .rename(let snapshot, let byteOffset, let newName, let context):
            lock.withLock { renameQueryCount += 1 }
            // Cross-file bases come ONLY from engine-supplied snapshots
            // (target + context). A file the engine never snapshotted is
            // stale by construction: refuse instead of guessing.
            var basis: [String: (revision: ArtifactRevisionID, content: String)] = [
                snapshot.path: (snapshot.revision, snapshot.content)
            ]
            for extra in context {
                basis[extra.path] = (extra.revision, extra.content)
            }
            // Find the scripted symbol at the offset, then its rename table.
            let atOffset: [FakeSymbolDef] = lock.withLock { symbols }.filter { def in
                guard def.path == snapshot.path,
                      let start = UTF8SpanConverter.byteOffset(
                        content: snapshot.content, line: def.line,
                        character: def.utf16Start, encoding: .utf16
                      ),
                      let end = UTF8SpanConverter.byteOffset(
                        content: snapshot.content, line: def.line,
                        character: def.utf16End, encoding: .utf16
                      ) else {
                    return false
                }
                return start <= byteOffset && byteOffset <= end
            }
            guard let target = atOffset.first else {
                throw CodeIntelligenceError.providerFailure(
                    "fake: no scripted symbol at offset \(byteOffset)"
                )
            }
            let table: [FakeEditDef]? = lock.withLock {
                renameEdits["\(target.name)->\(newName)"]
            }
            guard let table else {
                throw CodeIntelligenceError.providerFailure(
                    "fake: no scripted rename \(target.name)->\(newName)"
                )
            }
            var edits: [SemanticTextEdit] = []
            for def in table {
                guard let known = basis[def.path],
                      let start = UTF8SpanConverter.byteOffset(
                        content: known.content, line: def.startLine,
                        character: def.startChar, encoding: .utf16
                      ),
                      let end = UTF8SpanConverter.byteOffset(
                        content: known.content, line: def.endLine,
                        character: def.endChar, encoding: .utf16
                      ), start <= end else {
                    throw CodeIntelligenceError.staleBasis(
                        "fake: no engine snapshot basis for \(def.path)"
                    )
                }
                edits.append(SemanticTextEdit(
                    path: def.path,
                    baseRevision: known.revision,
                    startByteOffset: start,
                    endByteOffset: end,
                    replacement: def.newText
                ))
            }
            return .workspaceEdit(SemanticWorkspaceEdit(
                edits: edits, source: .rename, provider: providerID,
                basis: "rename \(target.name)->\(newName)"
            ))
        }
    }
}
