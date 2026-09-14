import Foundation
import Darwin

let ownURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .standardizedFileURL.resolvingSymlinksInPath()
let runtimeURL = ownURL.deletingLastPathComponent().appendingPathComponent("mlxagent")
let bundleName = "mlx-swift_Cmlx.bundle"
let buildDirectory = ownURL.deletingLastPathComponent()
let bundleURL = buildDirectory.appendingPathComponent(bundleName)
let metalLibraryURL = bundleURL.appendingPathComponent("Contents/Resources/default.metallib")

func installMetalBundleIfNeeded() {
    let files = FileManager.default
    guard !files.fileExists(atPath: metalLibraryURL.path) else { return }

    var candidates: [URL] = []
    let projectRoot = buildDirectory
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    candidates.append(
        projectRoot.appendingPathComponent("DerivedData/Build/Products/Release/\(bundleName)")
    )

    let derivedData = files.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
    if let entries = try? files.contentsOfDirectory(
        at: derivedData,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) {
        candidates.append(contentsOf: entries.map {
            $0.appendingPathComponent("Build/Products/Release/\(bundleName)")
        })
    }

    guard let source = candidates.first(where: {
        files.fileExists(
            atPath: $0.appendingPathComponent("Contents/Resources/default.metallib").path
        )
    }) else { return }
    try? files.copyItem(at: source, to: bundleURL)
}

installMetalBundleIfNeeded()
guard FileManager.default.isExecutableFile(atPath: runtimeURL.path) else {
    fputs("stacyagent-runtime: sibling mlxagent executable not found\n", stderr)
    exit(127)
}
guard FileManager.default.fileExists(atPath: metalLibraryURL.path) else {
    fputs("stacyagent-runtime: MLX Metal resource bundle not found\n", stderr)
    exit(78)
}

let arguments = [runtimeURL.path, "--runtime-service"] + Array(CommandLine.arguments.dropFirst())
let duplicated = arguments.map { strdup($0) }
var argv = duplicated + [nil]
defer { duplicated.forEach { free($0) } }
execv(runtimeURL.path, &argv)
fputs("stacyagent-runtime: exec failed: \(String(cString: strerror(errno)))\n", stderr)
exit(126)
