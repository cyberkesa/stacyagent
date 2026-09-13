import Foundation

/// Все магические лимиты/таймауты/пути в одном месте.
/// Значения по умолчанию = текущие хардкоды из Workspace/TaskSemantics/EditEngine.
public struct SLTALimits: Sendable {
    public var listDirMaxEntries = 300
    public var fileMaxBytes = 1_500_000
    public var searchMaxHits = 300
    public var searchFallbackMaxBytes = 750_000
    public var searchOutputMaxChars = 32_000
    public var runOutputHeadBytes = 4096
    public var runOutputTailBytes = 12_288
    public var maxCheckpoints = 500
    public var maxTransactions = 2000
    public var sessionLedgerBound = 256
    public var searchTimeoutSeconds = 20
    public var swiftcTimeoutSeconds = 60
    public var validateTimeoutSeconds = 30
    public var openTimeoutSeconds = 15
    public var shellPath = "/bin/zsh"
    public var openBinaryPath = "/usr/bin/open"

    public init() {}

    /// Переопределение через env `SLTA_*` без смены CLI.
    public static func fromEnvironment(_ base: SLTALimits = SLTALimits()) -> SLTALimits {
        var out = base
        let env = ProcessInfo.processInfo.environment
        func int(_ key: String, _ cur: Int) -> Int {
            guard let v = env[key], let n = Int(v), n > 0 else { return cur }
            return n
        }
        out.listDirMaxEntries = int("SLTA_LIST_MAX", out.listDirMaxEntries)
        out.fileMaxBytes = int("SLTA_FILE_MAX_BYTES", out.fileMaxBytes)
        out.searchMaxHits = int("SLTA_SEARCH_MAX", out.searchMaxHits)
        out.searchTimeoutSeconds = int("SLTA_SEARCH_TIMEOUT", out.searchTimeoutSeconds)
        out.swiftcTimeoutSeconds = int("SLTA_SWIFTC_TIMEOUT", out.swiftcTimeoutSeconds)
        out.validateTimeoutSeconds = int("SLTA_VALIDATE_TIMEOUT", out.validateTimeoutSeconds)
        if let p = env["SLTA_SHELL"], !p.isEmpty { out.shellPath = p }
        return out
    }
}
