import Foundation

@main
struct MLXAgentMain {
    static func main() {
        if CommandLine.arguments.contains("--ipc-integration") {
            let completion = DispatchSemaphore(value: 0)
            Task.detached {
                let results = await IPCIntegrationSelfTest.runAll()
                let failed = results.filter { !$0.passed }
                if failed.isEmpty {
                    print("Stacy Agent IPC integration: PASS \(results.count)/\(results.count)")
                } else {
                    print("Stacy Agent IPC integration: FAIL \(results.count - failed.count)/\(results.count) · " + failed.map(\.name).joined(separator: "; "))
                }
                completion.signal()
            }
            completion.wait()
            return
        }
        if CommandLine.arguments.contains("--runtime-service") {
            runRuntimeServiceMode()
            return
        }
        if CommandLine.arguments.contains("--selftest") {
            let completion = DispatchSemaphore(value: 0)
            Task.detached {
                print(await StacyAgentSelfTest.run())
                completion.signal()
            }
            completion.wait()
            return
        }
        fputs(
            "mlxagent is an internal Stacy Agent runtime component; launch Stacy Agent.app instead.\n",
            stderr
        )
        exit(64)
    }
}
