import Foundation

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool

    var succeeded: Bool { status == 0 && !timedOut }
    var combined: String { [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n") }
}

enum Shell {
    /// Runs a fixed executable with arguments. No shell is involved, so scan
    /// output cannot smuggle commands. Output is written to a temporary file,
    /// which avoids pipe deadlocks on verbose tools.
    static func run(_ executable: String, _ arguments: [String] = [], timeout: TimeInterval = 15) -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return ProcessResult(status: -1, stdout: "", stderr: "Executable not found: \(executable)", timedOut: false)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let tempDirectory = FileManager.default.temporaryDirectory
        let outURL = tempDirectory.appendingPathComponent("fettle-out-\(UUID().uuidString)")
        let errURL = tempDirectory.appendingPathComponent("fettle-err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            return ProcessResult(status: -1, stdout: "", stderr: "Could not create output file", timedOut: false)
        }
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? outHandle.close()
            try? errHandle.close()
            return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() > deadline {
                timedOut = true
                process.terminate()
                let grace = Date().addingTimeInterval(2)
                while process.isRunning && Date() < grace { usleep(50_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            usleep(40_000)
        }
        process.waitUntilExit()
        try? outHandle.close()
        try? errHandle.close()

        let outData = (try? Data(contentsOf: outURL)) ?? Data()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    static var currentUID: uid_t { getuid() }

    static var currentUser: String {
        ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
    }
}

enum FsTool {
    static var sqlitePath: String { "/usr/bin/sqlite3" }
    static var pmsetPath: String { "/usr/bin/pmset" }
    static var launchctlPath: String { "/bin/launchctl" }
    static var systemExtensionsPath: String { "/usr/bin/systemextensionsctl" }
    static var pluginkitPath: String { "/usr/bin/pluginkit" }
    static var sfltoolPath: String { "/usr/bin/sfltool" }
    static var openPath: String { "/usr/bin/open" }
}
