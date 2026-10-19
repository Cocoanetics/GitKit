// Twin-repository fixtures for RepositoryAmendTests: they fork the system
// `git`, so they are gated to macOS/Linux like the `git`-driven suites.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

/// Twin fixtures: the same history built twice by the `git` CLI with fixed
/// dates, so its commits are identical; one twin is amended by real git,
/// the other by GitKit, and the results must match to the byte.
enum AmendFixture {
    /// Thu Jan 1 10:00:00 2026 +0100 — every fixture commit's dates.
    static let authorDate = "1767258000 +0100"
    /// Mon Feb 2 11:00:00 2026 +0100 — the amend's committer date.
    static let commitDate = "1770026400 +0100"

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryAmendTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: dir)
        try git(["config", "user.email", "t@e.com"], in: dir)
        try git(["config", "user.name", "T"], in: dir)
        return dir
    }

    /// Run `git` with no ambient `GIT_*` variables or global config, plus
    /// `env`. Returns stdout, stderr and the exit status.
    @discardableResult
    static func run(
        _ args: [String], in dir: URL, env: [String: String] = [:]
    ) throws -> (out: String, err: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = dir
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment.merge(env) { $1 }
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self), process.terminationStatus)
    }

    /// Run `git` with every date pinned to ``authorDate``; throws on failure.
    @discardableResult
    static func git(_ args: [String], in dir: URL) throws -> String {
        let result = try run(args, in: dir, env: [
            "GIT_AUTHOR_DATE": authorDate, "GIT_COMMITTER_DATE": authorDate
        ])
        guard result.status == 0 else {
            throw Failure(description: "git \(args.joined(separator: " ")) failed: \(result.err)")
        }
        return result.out
    }

    static func write(_ text: String, to name: String, in dir: URL) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    /// Two commits: `f` ("first"), then `g` ("second").
    static func twoCommits(_ dir: URL) throws {
        try write("hi\n", to: "f", in: dir)
        try git(["add", "f"], in: dir)
        try git(["commit", "-q", "-m", "first"], in: dir)
        try write("two\n", to: "g", in: dir)
        try git(["add", "g"], in: dir)
        try git(["commit", "-q", "-m", "second"], in: dir)
    }

    static func lastLine(of path: String, in dir: URL) throws -> String {
        let text = String(decoding: try Data(contentsOf: dir.appendingPathComponent(path)), as: UTF8.self)
        return text.split(separator: "\n").last.map(String.init) ?? ""
    }

    /// Render `details` as `git commit` prints its summary — what a CLI
    /// built on GitKit prints.
    static func summary(_ details: Libgit2CommitDetails, subject: String) -> String {
        let root = details.isRoot ? " (root-commit)" : ""
        var out = "[\(details.branchName ?? "detached HEAD")\(root) \(details.shortSHA)] \(subject)\n"
        let author = details.author
        let committer = details.committer
        if author.name != committer.name || author.email != committer.email {
            out += " Author: \(author.name) <\(author.email)>\n"
        }
        if details.showsAuthorDate { out += " Date: \(author.formattedDate)\n" }
        if details.filesChanged > 0 {
            out += " \(details.filesChanged) file\(details.filesChanged == 1 ? "" : "s") changed"
            if details.insertions > 0 || details.deletions == 0 {
                out += ", \(details.insertions) insertion\(details.insertions == 1 ? "" : "s")(+)"
            }
            if details.deletions > 0 || details.insertions == 0 {
                out += ", \(details.deletions) deletion\(details.deletions == 1 ? "" : "s")(-)"
            }
            out += "\n"
        }
        let modes = details.addedFiles.map { ("create", $0) } + details.deletedFiles.map { ("delete", $0) }
        for (kind, file) in modes.sorted(by: { $0.1.path < $1.1.path }) {
            out += " \(kind) mode \(String(format: "%06o", file.mode)) \(file.path)\n"
        }
        return out
    }

    /// Build the fixture twice, amend one twin with `git commit --amend
    /// <gitArgs>` and the other with `amend`, and expect the same commit,
    /// the same reflog entries and the same summary.
    @discardableResult
    static func expectParity(
        setup: (URL) throws -> Void,
        gitArgs: [String],
        subject: String,
        env: [String: String] = [:],
        after: (_ viaGit: URL, _ viaKit: URL) throws -> Void = { _, _ in },
        amend: (Repository, [String: String]) throws -> Libgit2CommitDetails
    ) throws -> Libgit2CommitDetails {
        let viaGit = try makeRepo()
        let viaKit = try makeRepo()
        defer {
            try? FileManager.default.removeItem(at: viaGit)
            try? FileManager.default.removeItem(at: viaKit)
        }
        try setup(viaGit)
        try setup(viaKit)
        let amendEnv = env.merging(["GIT_COMMITTER_DATE": commitDate]) { $1 }
        let expected = try run(["commit", "--amend"] + gitArgs, in: viaGit, env: amendEnv)
        #expect(expected.status == 0, "git failed: \(expected.err)")

        let details = try amend(try Repository.open(at: viaKit), amendEnv)

        let gitHead = try git(["rev-parse", "HEAD"], in: viaGit)
        let kitHead = try git(["rev-parse", "HEAD"], in: viaKit)
        #expect(kitHead == gitHead)
        #expect(details.sha + "\n" == kitHead)
        #expect(try git(["cat-file", "-p", "HEAD"], in: viaKit) == git(["cat-file", "-p", "HEAD"], in: viaGit))
        var logs = ["logs/HEAD"]
        if let branch = details.branchName { logs.append("logs/refs/heads/\(branch)") }
        for log in logs {
            let line = try lastLine(of: ".git/\(log)", in: viaKit)
            #expect(line == (try lastLine(of: ".git/\(log)", in: viaGit)))
            #expect(line.hasSuffix("\tcommit (amend): \(subject)"))
        }
        #expect(summary(details, subject: subject) == expected.out)
        try after(viaGit, viaKit)
        return details
    }

    /// Build the fixture twice, amend one twin quietly with `git commit
    /// --amend <gitArgs>` and the other with `amend`, and expect the same
    /// commit and the same reflogs byte for byte — or both without them.
    static func expectSameRepos(
        setup: (URL) throws -> Void,
        gitArgs: [String],
        after: (_ viaGit: URL, _ viaKit: URL) throws -> Void = { _, _ in },
        amend: (Repository, [String: String]) throws -> Void
    ) throws {
        let viaGit = try makeRepo()
        let viaKit = try makeRepo()
        defer {
            try? FileManager.default.removeItem(at: viaGit)
            try? FileManager.default.removeItem(at: viaKit)
        }
        try setup(viaGit)
        try setup(viaKit)
        let env = ["GIT_COMMITTER_DATE": commitDate]
        let amended = try run(["commit", "-q", "--amend"] + gitArgs, in: viaGit, env: env)
        #expect(amended.status == 0, "git failed: \(amended.err)")
        try amend(try Repository.open(at: viaKit), env)
        #expect(try git(["rev-parse", "HEAD"], in: viaKit) == git(["rev-parse", "HEAD"], in: viaGit))
        for log in [".git/logs/HEAD", ".git/logs/refs/heads/main"] {
            let kitLog = FileManager.default.contents(atPath: viaKit.appendingPathComponent(log).path)
            let gitLog = FileManager.default.contents(atPath: viaGit.appendingPathComponent(log).path)
            #expect(kitLog == gitLog, "\(log) differs")
        }
        try after(viaGit, viaKit)
    }
}
#endif
