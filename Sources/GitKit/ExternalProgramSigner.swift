#if os(macOS) || os(Linux) || os(Windows)
import Foundation

/// Git's external-program signing convention. Only this signer interprets
/// key paths, literal SSH keys, and the process's home and environment.
public struct ExternalProgramSigner: GitSigner {
    public init() {}

    public func sign(_ payload: [UInt8], request: SigningRequest) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitKit-sign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        switch request.format {
        case .ssh:
            return try signSSH(payload, request: request, directory: directory)
        case .openpgp, .x509:
            let program = request.program ?? (request.format == .openpgp ? "gpg" : "gpgsm")
            let result = try run(program, arguments: ["--status-fd=2", "-bsau", request.key ?? request.identity],
                                 input: payload, directory: directory, workingDirectory: request.workingDirectory)
            guard result.status == 0, result.err.contains("[GNUPG:] SIG_CREATED "), !result.out.isEmpty else {
                throw SigningError.failed(program: program, stderr: result.err)
            }
            return result.out
        }
    }

    private func signSSH(_ payload: [UInt8], request: SigningRequest, directory: URL) throws -> String {
        var key = request.key
        if key == nil || key?.isEmpty == true, let command = request.defaultKeyCommand {
            #if os(Windows)
            let shell = environmentValue("COMSPEC") ?? "cmd.exe"
            let arguments = ["/c", command]
            #else
            let shell = "/bin/sh"
            let arguments = ["-c", command]
            #endif
            let result = try run(shell, arguments: arguments, input: [], directory: directory,
                                 workingDirectory: request.workingDirectory)
            guard result.status == 0 else { throw SigningError.failed(program: shell, stderr: result.err) }
            key = result.out.split(separator: "\n").first { $0.hasPrefix("key::") }.map(String.init)
        }
        guard let key, !key.isEmpty else { throw SigningError.missingKey }
        let literal: String?
        if key.hasPrefix("key::") { literal = String(key.dropFirst(5)) }
        else if key.hasPrefix("ssh-") { literal = key }
        else { literal = nil }

        let keyPath: String
        if let literal {
            let file = directory.appendingPathComponent("key.pub")
            try Data((literal + "\n").utf8).write(to: file)
            keyPath = file.path
        } else {
            keyPath = key.hasPrefix("~/") ? (key as NSString).expandingTildeInPath : key
        }
        let file = directory.appendingPathComponent("payload")
        try Data(payload).write(to: file)
        let program = request.program ?? "ssh-keygen"
        var arguments = ["-Y", "sign", "-n", "git", "-f", keyPath]
        if literal != nil { arguments.append("-U") }
        arguments.append(file.path)
        let result = try run(program, arguments: arguments, input: [], directory: directory,
                             workingDirectory: request.workingDirectory)
        guard result.status == 0 else { throw SigningError.failed(program: program, stderr: result.err) }
        do {
            return String(decoding: try Data(contentsOf: URL(fileURLWithPath: file.path + ".sig")), as: UTF8.self)
        } catch {
            throw SigningError.failed(program: program, stderr: result.err + "\n" + error.localizedDescription)
        }
    }

    // File-backed streams avoid deadlocks when a program writes a large
    // diagnostic before consuming stdin, or fills stdout and stderr together.
    private func run(
        _ program: String, arguments: [String], input: [UInt8], directory: URL, workingDirectory: URL?
    ) throws -> (out: String, err: String, status: Int32) {
        let inputURL = directory.appendingPathComponent("stdin")
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        try Data(input).write(to: inputURL)
        try Data().write(to: outputURL)
        try Data().write(to: errorURL)
        let stdin = try FileHandle(forReadingFrom: inputURL)
        let stdout = try FileHandle(forWritingTo: outputURL)
        let stderr = try FileHandle(forWritingTo: errorURL)
        defer {
            try? stdin.close()
            try? stdout.close()
            try? stderr.close()
        }
        let process = Process()
        #if os(Windows)
        process.executableURL = executableURL(program, workingDirectory: workingDirectory)
        process.arguments = arguments
        #else
        if program.contains("/") {
            process.executableURL = URL(fileURLWithPath: program, relativeTo: workingDirectory)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [program] + arguments
        }
        #endif
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() }
        catch { throw SigningError.failed(program: program, stderr: error.localizedDescription) }
        process.waitUntilExit()
        return (String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
                String(decoding: try Data(contentsOf: errorURL), as: UTF8.self), process.terminationStatus)
    }

    #if os(Windows)
    private func executableURL(_ program: String, workingDirectory: URL?) -> URL {
        if program.contains("/") || program.contains("\\") {
            return URL(fileURLWithPath: program, relativeTo: workingDirectory)
        }
        let extensions = [""] + (environmentValue("PATHEXT") ?? ".EXE").split(separator: ";").map(String.init)
        for path in (environmentValue("PATH") ?? "").split(separator: ";") {
            for suffix in extensions {
                let url = URL(fileURLWithPath: String(path)).appendingPathComponent(program + suffix)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return URL(fileURLWithPath: program)
    }

    private func environmentValue(_ name: String) -> String? {
        // Windows environment names are case-insensitive (commonly "Path").
        ProcessInfo.processInfo.environment.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    #endif
}
#endif
