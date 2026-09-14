import Foundation
import Darwin

public enum IPCFrameError: Error, CustomStringConvertible, Sendable {
    case emptyFrame
    case oversizedFrame(Int)
    case malformedJSON

    public var description: String {
        switch self {
        case .emptyFrame: return "empty IPC frame"
        case .oversizedFrame(let size): return "IPC frame exceeds limit: \(size)"
        case .malformedJSON: return "malformed IPC JSON frame"
        }
    }
}

public struct IPCFrameCodec: Sendable {
    public static let defaultMaximumFrameSize = 8 * 1024 * 1024

    public static func encode<T: Encodable>(
        _ value: T,
        maximumFrameSize: Int = defaultMaximumFrameSize,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        let payload = try encoder.encode(value)
        guard !payload.isEmpty else { throw IPCFrameError.emptyFrame }
        guard payload.count <= maximumFrameSize else {
            throw IPCFrameError.oversizedFrame(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        framed.append(payload)
        return framed
    }

    public static func decode<T: Decodable>(
        _ payload: Data,
        as type: T.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        do { return try decoder.decode(type, from: payload) }
        catch { throw IPCFrameError.malformedJSON }
    }
}

public struct IPCFrameDecoder: Sendable {
    private var buffer = Data()
    public let maximumFrameSize: Int

    public init(maximumFrameSize: Int = IPCFrameCodec.defaultMaximumFrameSize) {
        self.maximumFrameSize = maximumFrameSize
    }

    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let size = Int(length)
            guard size > 0 else { throw IPCFrameError.emptyFrame }
            guard size <= maximumFrameSize else { throw IPCFrameError.oversizedFrame(size) }
            guard buffer.count >= 4 + size else { break }
            frames.append(buffer.subdata(in: 4..<(4 + size)))
            buffer.removeSubrange(0..<(4 + size))
        }
        return frames
    }

    public var hasPartialFrame: Bool { !buffer.isEmpty }
}

public enum WorkspaceIdentity {
    /// True realpath canonicalization for existing paths.
    /// Rationale: URL.resolvingSymlinksInPath().standardizedFileURL is NOT
    /// stable across equivalent spellings on Darwin (observed: an existing
    /// /tmp/x stays /tmp/x while /private/tmp/x collapses to /tmp/x, but
    /// missing paths are left untouched). IPC identity must be
    /// byte-identical on both ends, so both Swift and TypeScript use
    /// realpath(3) semantics here. Falls back to the legacy form only when
    /// the path does not exist (never the case for connect/open flows).
    public static func canonicalPath(_ url: URL) -> String {
        let path = url.path
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        if Darwin.realpath(path, &resolved) != nil {
            return String(cString: resolved)
        }
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    public static func stableID(for url: URL) -> String {
        stableID(forCanonicalPath: canonicalPath(url))
    }

    public static func stableID(forCanonicalPath path: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    public static func socketURL(for url: URL) -> URL {
        let run = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".stacyagent/run", isDirectory: true)
        return run.appendingPathComponent(stableID(for: url) + ".sock")
    }

    public static func lockURL(for url: URL) -> URL {
        let run = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".stacyagent/run", isDirectory: true)
        return run.appendingPathComponent(stableID(for: url) + ".lock")
    }
}
