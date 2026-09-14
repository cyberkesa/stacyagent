import Foundation

enum ProjectInstructions {
    static func load(root: URL) -> String {
        let candidates = ["STACY_AGENT.md", ".stacyagent.md", "AGENTS.md"]
        var sections: [String] = []
        var remaining = 32_000

        for name in candidates {
            guard remaining > 0 else { break }
            let url = root.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { continue }
            let clipped = String(text.prefix(remaining))
            sections.append("## \(name)\n\(clipped)")
            remaining -= clipped.count
        }

        return sections.joined(separator: "\n\n")
    }
}
