import Foundation

/// Runs helper processes with a sanitized environment.
enum Shell {
    struct Outcome {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    @discardableResult
    static func run(_ executable: URL, _ arguments: [String], cwd: URL? = nil,
                    env: [String: String] = ["PATH": "/usr/bin:/bin"],
                    timeout: TimeInterval? = nil,
                    onStdoutLine: ((String) -> Void)? = nil) throws -> Outcome {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.environment = env
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        var stdoutData = Data()
        var stderrData = Data()
        let lock = NSLock()
        var buffer = ""
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            lock.lock(); stdoutData.append(d); lock.unlock()
            if let onStdoutLine, let s = String(data: d, encoding: .utf8) {
                buffer += s
                while let nl = buffer.firstIndex(of: "\n") {
                    onStdoutLine(String(buffer[..<nl]))
                    buffer = String(buffer[buffer.index(after: nl)...])
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            lock.lock(); stderrData.append(d); lock.unlock()
        }
        try p.run()
        if let timeout {
            let exited = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in exited.signal() }
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                p.terminate()
                if exited.wait(timeout: .now() + 3) == .timedOut { kill(p.processIdentifier, SIGKILL) }
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                throw ClementineError.helperFailed("\(executable.lastPathComponent) did not finish within \(Int(timeout)) seconds.")
            }
        } else {
            p.waitUntilExit()
        }
        // Drain anything left after exit.
        let restOut = out.fileHandleForReading.readDataToEndOfFile()
        let restErr = err.fileHandleForReading.readDataToEndOfFile()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        stdoutData.append(restOut); stderrData.append(restErr)
        let result = Outcome(status: p.terminationStatus,
                            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                            stderr: String(data: stderrData, encoding: .utf8) ?? "")
        lock.unlock()
        return result
    }

    /// Bridges a short async call into synchronous engine code running off the main thread.
    static func sync<T>(_ op: @escaping () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: Swift.Result<T, Error>!
        Task.detached(priority: .userInitiated) {
            do { result = .success(try await op()) } catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }
}
