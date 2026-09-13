import Foundation

struct EmptyInput: Codable, Sendable {}
struct TextOutput: Codable, Sendable { let result: String }

struct PathInput: Codable, Sendable { let path: String }
struct ReadFileRangeInput: Codable, Sendable {
    let path: String
    let start_line: Double
    let end_line: Double
}
struct WriteFileInput: Codable, Sendable { let path: String; let content: String }
struct EditFileInput: Codable, Sendable { let path: String; let old: String; let new: String }
struct EditFileRangeInput: Codable, Sendable {
    let path: String
    let start_line: Double
    let end_line: Double
    let replacement: String
}
struct SearchInput: Codable, Sendable { let query: String; let path: String? }
struct ShellInput: Codable, Sendable { let command: String }
struct URLInput: Codable, Sendable { let url: String }
struct MCPServerInput: Codable, Sendable { let server: String }
struct MCPCallInput: Codable, Sendable {
    let server: String
    let tool: String
    let arguments_json: String
}
