import Foundation
import Darwin

let ownURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let runtimeURL = ownURL.deletingLastPathComponent().appendingPathComponent("mlxagent")
guard FileManager.default.isExecutableFile(atPath: runtimeURL.path) else {
    fputs("slta-runtime: sibling mlxagent executable not found\n", stderr)
    exit(127)
}

let arguments = [runtimeURL.path, "--runtime-service"] + Array(CommandLine.arguments.dropFirst())
let duplicated = arguments.map { strdup($0) }
var argv = duplicated + [nil]
defer { duplicated.forEach { free($0) } }
execv(runtimeURL.path, &argv)
fputs("slta-runtime: exec failed: \(String(cString: strerror(errno)))\n", stderr)
exit(126)
