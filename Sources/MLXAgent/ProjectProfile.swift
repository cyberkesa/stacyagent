import Foundation

struct ProjectProfile: Sendable {
    let topLevel: [String]
    let ecosystems: [String]
    let suggestedChecks: [String]

    static func scan(root: URL) -> ProjectProfile {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
        let filtered = names.filter { !$0.hasPrefix(".") }
        let visible = Array(filtered.prefix(80))

        var ecosystems: [String] = []
        var checks: [String] = []

        func has(_ name: String) -> Bool { names.contains(name) }

        if has("Package.swift") {
            ecosystems.append("SwiftPM")
            checks.append("swift build")
            checks.append("swift test")
        }
        if has("package.json") {
            ecosystems.append("Node.js")
            if let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let scripts = object["scripts"] as? [String: Any] {
                if scripts["test"] != nil { checks.append("npm test") }
                if scripts["build"] != nil { checks.append("npm run build") }
                if scripts["lint"] != nil { checks.append("npm run lint") }
            }
        }
        if has("pyproject.toml") || has("requirements.txt") || has("setup.py") {
            ecosystems.append("Python")
            if has("pyproject.toml") { checks.append("python3 -m pytest") }
        }
        if has("Cargo.toml") {
            ecosystems.append("Rust")
            checks.append("cargo check")
            checks.append("cargo test")
        }
        if has("go.mod") {
            ecosystems.append("Go")
            checks.append("go test ./...")
        }

        if ecosystems.isEmpty {
            let extensions = Set(names.compactMap { name -> String? in
                let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
                return ext.isEmpty ? nil : ext
            })
            if extensions.contains("py") { ecosystems.append("Python files") }
            if !extensions.isDisjoint(with: ["js", "ts", "tsx", "jsx"]) { ecosystems.append("JavaScript/TypeScript files") }
            if extensions.contains("swift") { ecosystems.append("Swift files") }
        }

        return ProjectProfile(
            topLevel: Array(visible),
            ecosystems: ecosystems,
            suggestedChecks: Array(checks.prefix(8))
        )
    }

    var promptContext: String {
        let files = topLevel.isEmpty ? "empty/unknown" : topLevel.joined(separator: ", ")
        let stack = ecosystems.isEmpty ? "not detected" : ecosystems.joined(separator: ", ")
        let checks = suggestedChecks.isEmpty ? "none inferred" : suggestedChecks.joined(separator: " | ")
        return """
        Project snapshot (already scanned once; do not list_dir just to rediscover this):
        top-level: \(files)
        detected stack: \(stack)
        candidate validation commands: \(checks)
        """
    }
}
