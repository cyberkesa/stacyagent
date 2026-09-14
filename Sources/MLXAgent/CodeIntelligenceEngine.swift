import Foundation

// MARK: - v0.30 CodeIntelligenceEngine
//
// Deterministic semantic operations over exact revision snapshots.
// May interact with: Workspace, ArtifactGraph, CodeIntelligenceProvider,
// SemanticFactStore. NEVER calls ModelProvider (no such reference).
// NEVER writes files, NEVER creates EditTransactions: it produces
// validated SemanticWorkspaceEdit plans; the runtime (ToolRegistry +
// Workspace.applySemanticPlan) applies them through EditEngine.

struct ResolvedCandidate: Sendable {
    var provider: CodeIntelligenceProviderID
    var symbol: CodeSymbol
}

enum RenamePlanResult: Sendable {
    case ready(SemanticWorkspaceEdit)
    case ambiguous([ResolvedCandidate])
    case notFound(String)
    case unavailable(String)
    case invalid(String)
}

struct SemanticOperationTelemetry: Sendable {
    var provider: String
    var operation: String
    var durationMs: Double
    var cacheHit: Bool
    var resultCount: Int
    var basisEpoch: UInt64
}

final class CodeIntelligenceEngine: @unchecked Sendable {
    private let workspace: Workspace
    private let providers: [any CodeIntelligenceProvider]
    private let events: EventBus
    private let store: SemanticFactStore

    init(
        workspace: Workspace,
        providers: [any CodeIntelligenceProvider],
        events: EventBus,
        store: SemanticFactStore = SemanticFactStore()
    ) {
        self.workspace = workspace
        self.providers = providers
        self.events = events
        self.store = store
    }

    var factStore: SemanticFactStore { store }

    // MARK: - Snapshots (exact revision content, no task evidence)

    func snapshot(path: String) throws -> CodeDocumentSnapshot {
        let (content, revision) = try workspace.readSnapshot(path: path)
        return CodeDocumentSnapshot(
            path: workspace.canonicalKey(path),
            revision: revision.id,
            revisionNumber: revision.number,
            contentHash: revision.contentHash ?? ArtifactHash.sha256(content),
            languageID: Self.languageID(for: path),
            content: content
        )
    }

    static func languageID(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "swift": return "swift"
        case "c", "h": return "c"
        case "cpp", "hpp", "cc": return "cpp"
        case "py": return "python"
        case "js", "mjs", "cjs": return "javascript"
        case "ts", "tsx": return "typescript"
        default: return "plaintext"
        }
    }

    // MARK: - Symbol resolution (lazy, exact-name, never first-result)

    /// All providers, exact name match. Empty when nothing matches.
    func resolve(symbol name: String, path: String?) async -> [ResolvedCandidate] {
        var out: [ResolvedCandidate] = []
        for provider in providers {
            // Path-scoped: single document query.
            if let path {
                guard provider.capabilities.documentSymbols else { continue }
                do {
                    let snap = try snapshot(path: path)
                    let key = SemanticFactKey(
                        kind: .documentSymbols, path: snap.path,
                        subject: "doc", provider: "\(provider.providerID)"
                    )
                    let symbols = try await cachedSymbols(
                        key: key, provider: provider,
                        snapshot: snap, epoch: workspace.graph.semanticGeneration()
                    )
                    for symbol in symbols where symbol.name == name {
                        if spanTextEquals(symbol: symbol, snapshot: snap) {
                            out.append(ResolvedCandidate(
                                provider: provider.providerID, symbol: symbol
                            ))
                        }
                    }
                } catch {
                    continue
                }
                continue
            }
            // Workspace scope: provider index first, then exact per-file pass,
            // PLUS textual discovery fallback. Rationale: server-side rename
            // is computed from open documents/syntax and is complete even on
            // a cold index, but workspace/symbol (index-only) may lag and
            // return nothing. A rename based on a lagging index alone could
            // silently miss occurrences, so candidate discovery unions the
            // index with a cheap textual search (ripgrep); exact spans always
            // come from per-file documentSymbols on exact snapshots.
            if provider.capabilities.workspaceSymbols {
                do {
                    let started = ContinuousClock.now
                    let wsKey = SemanticFactKey(
                        kind: .workspaceSymbols, path: nil,
                        subject: name, provider: "\(provider.providerID)"
                    )
                    let epoch = workspace.graph.semanticGeneration()
                    if let cached = store.lookup(wsKey),
                       case .fresh = store.workspaceFreshness(of: cached, epoch: epoch) {
                        // Epoch-fresh implies every basis revision is current
                        // (any revision change bumps the epoch).
                        await emitFinished(
                            provider: provider, operation: "workspaceSymbols",
                            durationMs: 0, cacheHit: true,
                            resultCount: cached.symbols.count
                        )
                        out.append(contentsOf: cached.symbols.map {
                            ResolvedCandidate(provider: provider.providerID, symbol: $0)
                        })
                        continue
                    }
                    if store.lookup(wsKey) != nil {
                        await events.emit(.semanticFactBecameStale(
                            kind: "workspaceSymbols", path: ""
                        ))
                    }
                    await events.emit(.codeIntelligenceStarted(
                        provider: "\(provider.providerID)",
                        operation: "workspaceSymbols"
                    ))
                    let result = try await provider.query(.workspaceSymbols(name))
                    let elapsed = Self.ms(ContinuousClock.now - started)
                    guard case .workspaceSymbols(let items) = result else { continue }
                    await emitFinished(
                        provider: provider, operation: "workspaceSymbols",
                        durationMs: elapsed, cacheHit: false,
                        resultCount: items.count
                    )
                    let before = out.count
                    for item in items where item.name == name {
                        let resolved = await resolveInFile(
                            provider: provider, pathHint: item.path, name: name
                        )
                        out.append(contentsOf: resolved)
                    }
                    // Cache the resolved (snapshot-bound) symbols only.
                    store.store(CachedSemanticFact(
                        key: wsKey,
                        symbols: out[before...].map(\.symbol),
                        locations: [], diagnostics: [],
                        basisRevisions: workspace.graph.currentMap(),
                        basisEpoch: epoch, createdAt: Date()
                    ))
                    await events.emit(.semanticFactRecorded(
                        kind: "workspaceSymbols", path: "",
                        revision: "epoch-\(epoch)"
                    ))
                    // Textual discovery fallback: files mentioning the name
                    // that the index did not report (cold/lagging index).
                    // Bounded, name-filtered, exact-resolved per file below.
                    for path in textualCandidateFiles(
                        symbol: name,
                        known: Set(out.map(\.symbol.path))
                    ) {
                        let resolved = await resolveInFile(
                            provider: provider, pathHint: path, name: name
                        )
                        out.append(contentsOf: resolved)
                    }
                } catch {
                    continue
                }
            } else if provider.capabilities.documentSymbols {
                // No index: engine cannot enumerate files for this provider.
                continue
            }
        }
        // Distinct candidates only (provider, path, span).
        var seen = Set<String>()
        return out.filter { candidate in
            let key = "\(candidate.provider)#\(candidate.symbol.path)#\(candidate.symbol.nameSpan.startByte)"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    /// Textual candidate discovery (index fallback): files mentioning
    /// the symbol name, bounded and Swift-scoped. Exact spans always come
    /// from per-file documentSymbols on exact snapshots — text only
    /// discovers CANDIDATE files, never facts.
    private func textualCandidateFiles(symbol: String, known: Set<String>) -> [String] {
        guard symbol.count >= 2,
              symbol.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return []
        }
        guard let output = try? workspace.search(symbol, path: ".") else {
            return []
        }
        if output == "no matches" { return [] }
        var out: [String] = []
        for line in output.split(separator: "\n") {
            // search format: "path:line:content".
            guard let colon = line.firstIndex(of: ":") else { continue }
            let raw = String(line[..<colon])
            let key = workspace.canonicalKey(raw)
            guard !key.isEmpty, !known.contains(key), !out.contains(key),
                  key.hasSuffix(".swift") else {
                continue
            }
            out.append(key)
            if out.count >= 100 { break }
        }
        return out
    }

    private func resolveInFile(
        provider: any CodeIntelligenceProvider,
        pathHint: String,
        name: String
    ) async -> [ResolvedCandidate] {
        // pathHint may be a URI (LSP) or a path (Fake): normalize to a
        // workspace-relative path or skip when outside the workspace.
        let path: String
        if pathHint.hasPrefix("file://"),
           let url = URL(string: pathHint),
           url.path.hasPrefix(workspace.root.path + "/") {
            path = String(url.path.dropFirst(workspace.root.path.count + 1))
        } else if workspace.contains(path: pathHint) {
            path = workspace.canonicalKey(pathHint)
        } else {
            return []
        }
        do {
            let snap = try snapshot(path: path)
            let key = SemanticFactKey(
                kind: .documentSymbols, path: snap.path,
                subject: "doc", provider: "\(provider.providerID)"
            )
            let symbols = try await cachedSymbols(
                key: key, provider: provider,
                snapshot: snap, epoch: workspace.graph.semanticGeneration()
            )
            return symbols.filter {
                $0.name == name && spanTextEquals(symbol: $0, snapshot: snap)
            }.map { ResolvedCandidate(provider: provider.providerID, symbol: $0) }
        } catch {
            return []
        }
    }

    /// Symbol span text must equal the symbol name on the EXACT snapshot.
    /// Guards against stale/placeholder spans ever reaching a mutation.
    private func spanTextEquals(symbol: CodeSymbol, snapshot: CodeDocumentSnapshot) -> Bool {
        let span = symbol.nameSpan
        guard span.revision == snapshot.revision,
              span.startByte >= 0, span.endByte <= snapshot.content.utf8.count,
              span.startByte <= span.endByte else {
            return false
        }
        let view = snapshot.content.utf8
        guard let lower = view.index(view.startIndex, offsetBy: span.startByte, limitedBy: view.endIndex),
              let upper = view.index(lower, offsetBy: span.endByte - span.startByte, limitedBy: view.endIndex) else {
            return false
        }
        return String(bytes: Array(view[lower..<upper]), encoding: .utf8) == symbol.name
    }

    private func cachedSymbols(
        key: SemanticFactKey,
        provider: any CodeIntelligenceProvider,
        snapshot: CodeDocumentSnapshot,
        epoch: UInt64
    ) async throws -> [CodeSymbol] {
        if let cached = store.lookup(key) {
            let current = workspace.graph.currentMap()
            if case .fresh = store.freshness(of: cached, currentRevisions: current) {
                await emitFinished(
                    provider: provider, operation: "documentSymbols",
                    durationMs: 0, cacheHit: true,
                    resultCount: cached.symbols.count
                )
                return cached.symbols
            }
            await events.emit(.semanticFactBecameStale(
                kind: "documentSymbols", path: snapshot.path
            ))
        }
        await events.emit(.codeIntelligenceStarted(
            provider: "\(provider.providerID)", operation: "documentSymbols"
        ))
        let started = ContinuousClock.now
        let result = try await provider.query(.documentSymbols(snapshot))
        let elapsed = Self.ms(ContinuousClock.now - started)
        guard case .symbols(let symbols) = result else {
            throw CodeIntelligenceError.providerFailure("no symbols returned")
        }
        store.store(CachedSemanticFact(
            key: key, symbols: symbols, locations: [], diagnostics: [],
            basisRevisions: [snapshot.path: snapshot.revision],
            basisEpoch: epoch, createdAt: Date()
        ))
        await events.emit(.semanticFactRecorded(
            kind: "documentSymbols", path: snapshot.path,
            revision: "\(snapshot.revision)"
        ))
        await emitFinished(
            provider: provider, operation: "documentSymbols",
            durationMs: elapsed, cacheHit: false, resultCount: symbols.count
        )
        return symbols
    }

    // MARK: - Rename pipeline (plan only; runtime applies)

    func planRename(
        symbol name: String,
        newName: String,
        path: String?,
        taskID: String
    ) async -> RenamePlanResult {
        guard !providers.isEmpty else {
            return .unavailable("no code intelligence providers configured")
        }
        let candidates = await resolve(symbol: name, path: path)
        let scoped: [ResolvedCandidate]
        if let path {
            let key = workspace.canonicalKey(path)
            scoped = candidates.filter { $0.symbol.path == key }
            if scoped.isEmpty {
                return .notFound("\(name) not found in \(key)")
            }
        } else {
            scoped = candidates
        }
        // Ambiguity: never pick, never first-result (§13).
        let distinctPaths = Set(scoped.map(\.symbol.path))
        if scoped.count > 1 || distinctPaths.count > 1 {
            await events.emit(.semanticAmbiguityDetected(
                symbol: name,
                candidates: scoped.map { "\($0.symbol.path):\($0.symbol.name)" }
            ))
            return .ambiguous(scoped)
        }
        guard let target = scoped.first else {
            return .notFound(path.map { "\(name) not found in \($0)" } ?? "\(name) not found")
        }
        guard let provider = providers.first(where: {
            "\($0.providerID)" == "\(target.provider)"
        }) else {
            return .unavailable("resolving provider went away")
        }
        do {
            let snap: CodeDocumentSnapshot
            do {
                snap = try snapshot(path: target.symbol.path)
            } catch {
                return .invalid("cannot snapshot \(target.symbol.path): \(error)")
            }
            // The resolved span must belong to the live snapshot.
            guard target.symbol.nameSpan.revision == snap.revision,
                  spanTextEquals(symbol: target.symbol, snapshot: snap) else {
                return .invalid("candidate span is stale for \(target.symbol.path)")
            }
            let offset = target.symbol.nameSpan.startByte
            if provider.capabilities.prepareRename {
                let prepared = try await provider.query(.prepareRename(snap, byteOffset: offset))
                if case .renameRange(let range) = prepared, let range {
                    guard range.startByte <= offset, offset <= range.endByte else {
                        return .invalid("prepareRename range rejects offset")
                    }
                }
            }
            guard provider.capabilities.rename else {
                return .unavailable("\(provider.providerID) cannot rename")
            }
            // Lazy related-file discovery: references of the target reveal
            // every file the rename may touch. Snapshot them all so the
            // provider can only base cross-file edits on engine-supplied
            // exact content (stale files fail closed, never guessed).
            var involved: [String] = [snap.path]
            if provider.capabilities.references {
                if case .locations(let locs) = try? await provider.query(
                    .references(snap, byteOffset: offset)
                ) {
                    for loc in locs where !involved.contains(loc.path) {
                        involved.append(loc.path)
                    }
                }
            }
            var context: [CodeDocumentSnapshot] = []
            for path in involved where path != snap.path {
                do {
                    context.append(try snapshot(path: path))
                } catch {
                    return .invalid("cannot snapshot related file \(path): \(error)")
                }
            }
            let renamed = try await provider.query(
                .rename(snap, byteOffset: offset, newName: newName, context: context)
            )
            guard case .workspaceEdit(let edit) = renamed else {
                return .invalid("rename returned no edit plan")
            }
            let validated = try validatePlan(edit, taskID: taskID)
            await events.emit(.semanticEditPlanned(
                taskID: taskID, files: validated.edits.map(\.path),
                edits: validated.edits.count
            ))
            return .ready(validated)
        } catch let error as CodeIntelligenceError {
            switch error {
            case .staleBasis(let reason): return .invalid("stale basis: \(reason)")
            case .unavailable(let reason): return .unavailable(reason)
            default: return .invalid("\(error)")
            }
        } catch {
            return .invalid("\(error)")
        }
    }

    /// Plan validation (§12): canonical paths, in-workspace, expected base
    /// still current, byte ranges valid on CURRENT content, non-overlapping,
    /// sorted. Any violation rejects the WHOLE plan (no partial apply).
    func validatePlan(
        _ edit: SemanticWorkspaceEdit,
        taskID: String
    ) throws -> SemanticWorkspaceEdit {
        guard !edit.edits.isEmpty else {
            throw CodeIntelligenceError.providerFailure("empty edit plan")
        }
        let current = workspace.graph.currentMap()
        var byFile: [String: [SemanticTextEdit]] = [:]
        for item in edit.edits {
            let key = workspace.canonicalKey(item.path)
            guard workspace.contains(path: key) else {
                throw CodeIntelligenceError.providerFailure(
                    "edit outside workspace: \(item.path)"
                )
            }
            guard current[key] == item.baseRevision else {
                throw CodeIntelligenceError.staleBasis(
                    "\(key) moved past plan basis"
                )
            }
            byFile[key, default: []].append(item)
        }
        // Ranges valid against live content + non-overlapping per file.
        for (key, items) in byFile {
            let content: String
            do {
                content = try String(
                    contentsOf: workspace.root.appendingPathComponent(key),
                    encoding: .utf8
                )
            } catch {
                throw CodeIntelligenceError.staleBasis("cannot reread \(key)")
            }
            let count = content.utf8.count
            let sorted = items.sorted { $0.startByteOffset < $1.startByteOffset }
            var cursor = 0
            for item in sorted {
                guard item.startByteOffset >= 0,
                      item.endByteOffset <= count,
                      item.startByteOffset <= item.endByteOffset,
                      item.startByteOffset >= cursor else {
                    throw CodeIntelligenceError.providerFailure(
                        "invalid/overlapping range in \(key)"
                    )
                }
                cursor = item.endByteOffset
            }
        }
        // Canonical sorted plan (files + descending offsets per file apply).
        let normalized = byFile.flatMap { key, items in
            items.sorted { $0.startByteOffset > $1.startByteOffset }.map { item in
                SemanticTextEdit(
                    path: key,
                    baseRevision: item.baseRevision,
                    startByteOffset: item.startByteOffset,
                    endByteOffset: item.endByteOffset,
                    replacement: item.replacement
                )
            }
        }.sorted { $0.path < $1.path }
        return SemanticWorkspaceEdit(
            edits: normalized, source: edit.source,
            provider: edit.provider, basis: edit.basis
        )
    }

    // MARK: - Diagnostics as facts (never evidence, never authority)

    func diagnostics(path: String) async -> [DiagnosticFact] {
        do {
            let snap = try snapshot(path: path)
            for provider in providers where provider.capabilities.diagnostics {
                if case .diagnostics(let items) = try await provider.query(.diagnostics(snap)) {
                    let fresh = items.filter { $0.revision == snap.revision }
                    if !fresh.isEmpty { return fresh }
                }
            }
        } catch {}
        return []
    }

    // MARK: - Telemetry (no tokens, no cost — queries only)

    private func emitFinished(
        provider: any CodeIntelligenceProvider,
        operation: String,
        durationMs: Double,
        cacheHit: Bool,
        resultCount: Int
    ) async {
        await events.emit(.codeIntelligenceFinished(
            provider: "\(provider.providerID)",
            operation: operation,
            durationMs: durationMs,
            cacheHit: cacheHit,
            resultCount: resultCount
        ))
    }

    private static func ms(_ duration: Duration) -> Double {
        let c = duration.components
        return (Double(c.seconds) + Double(c.attoseconds) / 1e18) * 1000
    }
}
