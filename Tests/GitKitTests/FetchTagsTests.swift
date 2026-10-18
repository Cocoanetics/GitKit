// Integration tests for which tags a fetch brings (`git fetch --tags`,
// `--no-tags`, `remote.<name>.tagOpt`). Fixtures are built with the
// system `git` CLI (gated to non-Windows like the other integration
// suites); everything under test goes through `Repository`. Expected
// lines are git 2.54's for the same fetches.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

private final class TagsLog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ text: String) { lock.lock(); buffer += text; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
}

@Suite("Fetch tags")
struct FetchTagsTests {

    private func tmp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FetchTagsTests-\(label)-\(UUID().uuidString)")
    }

    @discardableResult
    private func runGit(_ args: [String], in dir: URL, input: String? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com"] + args
        p.currentDirectoryURL = dir
        let out = Pipe(); let err = Pipe(); let stdin = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = stdin
        try p.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        let outStr = String(decoding: (try? out.fileHandleForReading.readToEnd()) ?? Data(),
                            as: UTF8.self)
        if p.terminationStatus != 0 {
            let errStr = String(decoding: (try? err.fileHandleForReading.readToEnd()) ?? Data(),
                                as: UTF8.self)
            throw Failure("git \(args.joined(separator: " ")) failed: \(errStr)")
        }
        return outStr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) { self.message = m }
        var description: String { message }
    }

    /// An upstream whose `main` has tags `v1` and annotated `v2`, and
    /// whose `side` branch has `vside`, cloned; then `v3` on `main`
    /// and `vside2` on `side` come after the clone.
    private func makeUpstreamAndClone() throws -> (upstream: URL, clone: URL) {
        let upstream = tmp("up"), clone = tmp("clone")
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: upstream)
        try runGit(["commit", "-q", "--allow-empty", "-m", "one"], in: upstream)
        try runGit(["tag", "v1"], in: upstream)
        try runGit(["checkout", "-q", "-b", "side"], in: upstream)
        try runGit(["commit", "-q", "--allow-empty", "-m", "s"], in: upstream)
        try runGit(["tag", "vside"], in: upstream)
        try runGit(["checkout", "-q", "main"], in: upstream)
        try runGit(["commit", "-q", "--allow-empty", "-m", "two"], in: upstream)
        try runGit(["tag", "-a", "v2", "-m", "v2"], in: upstream)
        try runGit(["clone", "-q", upstream.path, clone.path], in: upstream)
        try runGit(["commit", "-q", "--allow-empty", "-m", "three"], in: upstream)
        try runGit(["tag", "v3"], in: upstream)
        try runGit(["checkout", "-q", "side"], in: upstream)
        try runGit(["commit", "-q", "--allow-empty", "-m", "s2"], in: upstream)
        try runGit(["tag", "vside2"], in: upstream)
        try runGit(["checkout", "-q", "main"], in: upstream)
        return (upstream, clone)
    }

    private func fetch(
        _ repo: URL, _ refspecs: [String] = [], tags: FetchTags?
    ) throws -> (output: String, error: FetchRejectedError?) {
        let log = TagsLog()
        do {
            try Repository.open(at: repo).fetch(
                remote: "origin", refspecs: refspecs, tags: tags, progress: { log.append($0) })
            return (log.text, nil)
        } catch let error as FetchRejectedError {
            return (log.text, error)
        }
    }

    private func tagNames(_ repo: URL) throws -> [String] {
        try runGit(["tag", "-l"], in: repo).split(separator: "\n").map(String.init)
    }

    /// FETCH_HEAD's descriptions, without object IDs and URL.
    private func fetchHead(_ repo: URL) throws -> [String] {
        try String(contentsOf: repo.appendingPathComponent(".git/FETCH_HEAD"), encoding: .utf8)
            .split(separator: "\n")
            .map { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                let what = fields[2].components(separatedBy: " of ")[0]
                return (fields[1].isEmpty ? "" : "\(fields[1]) ") + what
            }
    }

    @Test("--tags fetches every tag, after what the refspecs fetched")
    func allTags() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        let (output, error) = try fetch(clone, tags: .all)
        #expect(error == nil)
        #expect(output.hasSuffix("""
             * [new tag]         v3         -> v3
             * [new tag]         vside2     -> vside2

            """))
        #expect(try tagNames(clone) == ["v1", "v2", "v3", "vside", "vside2"])
        #expect(try fetchHead(clone) == [
            "branch 'main'", "not-for-merge branch 'side'",
            "not-for-merge tag 'v1'", "not-for-merge tag 'v2'", "not-for-merge tag 'v3'",
            "not-for-merge tag 'vside'", "not-for-merge tag 'vside2'"
        ])
    }

    @Test("by default only the tags pointing into what was fetched come along")
    func followedTags() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try fetch(clone, tags: nil)
        #expect(try tagNames(clone) == ["v1", "v2", "v3", "vside", "vside2"])

        let (other, plain) = try makeUpstreamAndClone()
        defer { [other, plain].forEach { try? FileManager.default.removeItem(at: $0) } }
        // A fetch into FETCH_HEAD alone follows none.
        _ = try fetch(plain, ["main"], tags: nil)
        #expect(try tagNames(plain) == ["v1", "v2", "vside"])
    }

    @Test("a tag on nothing fetched isn't followed, lightweight or annotated")
    func unreachableTagsStayBehind() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        // Tags on a branch the clone doesn't fetch.
        try runGit(["checkout", "-q", "-b", "hidden"], in: upstream)
        try runGit(["commit", "-q", "--allow-empty", "-m", "h"], in: upstream)
        try runGit(["tag", "vhidden"], in: upstream)
        try runGit(["commit", "-q", "--allow-empty", "-m", "h2"], in: upstream)
        try runGit(["tag", "-a", "vhidden2", "-m", "h2"], in: upstream)
        try runGit(["checkout", "-q", "main"], in: upstream)
        try runGit(["config", "remote.origin.fetch", "+refs/heads/main:refs/remotes/origin/main"], in: clone)
        let (output, _) = try fetch(clone, tags: nil)
        #expect(try tagNames(clone) == ["v1", "v2", "v3", "vside"])
        #expect(!output.contains("vhidden"))
        #expect(!(try fetchHead(clone)).contains { $0.contains("vhidden") })
    }

    @Test("a tag of a tree or blob is followed only when what's fetched holds it")
    func treeAndBlobTags() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        let blob = try runGit(["hash-object", "-w", "--stdin"], in: upstream, input: "unrelated\n")
        try runGit(["tag", "tblob", blob], in: upstream)
        try runGit(["tag", "tmain", "main^{tree}"], in: upstream)
        // A blob only an ancestor of the fetched tip holds.
        try Data("gone\n".utf8).write(to: upstream.appendingPathComponent("gone.txt"))
        try runGit(["add", "gone.txt"], in: upstream)
        try runGit(["commit", "-q", "-m", "add"], in: upstream)
        try runGit(["tag", "tgone", "HEAD:gone.txt"], in: upstream)
        try runGit(["rm", "-q", "gone.txt"], in: upstream)
        try runGit(["commit", "-q", "-m", "rm"], in: upstream)
        _ = try fetch(clone, tags: nil)
        let names = try tagNames(clone)
        #expect(names.contains("tmain"))
        #expect(names.contains("tgone"))
        #expect(!names.contains("tblob"))
    }

    @Test("a tag of an object here already, reachable or not, is followed")
    func danglingTarget() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        let blob = try runGit(["hash-object", "-w", "--stdin"], in: upstream, input: "dangling\n")
        try runGit(["tag", "tdangling", blob], in: upstream)
        try runGit(["hash-object", "-w", "--stdin"], in: clone, input: "dangling\n")
        _ = try fetch(clone, tags: nil)
        #expect(try tagNames(clone).contains("tdangling"))
    }

    @Test("a fetched ref that is a blob itself vouches for a tag of it")
    func blobTip() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        let blob = try runGit(["hash-object", "-w", "--stdin"], in: upstream, input: "meta\n")
        try runGit(["update-ref", "refs/meta/blob", blob], in: upstream)
        try runGit(["tag", "tmeta", blob], in: upstream)
        // Alongside it, a branch's tag still follows: the blob tip doesn't
        // upset the commit graph.
        _ = try fetch(clone, ["refs/meta/blob:refs/meta/blob", "+refs/heads/*:refs/remotes/origin/*"], tags: nil)
        #expect(try tagNames(clone).contains("tmeta"))
        #expect(try tagNames(clone).contains("v3"))
    }

    @Test("an object an alternate holds counts as here already")
    func alternateTarget() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        let borrower = tmp("borrower")
        defer { [upstream, clone, borrower].forEach { try? FileManager.default.removeItem(at: $0) } }
        let blob = try runGit(["hash-object", "-w", "--stdin"], in: upstream, input: "borrowed\n")
        try runGit(["tag", "tborrowed", blob], in: upstream)
        // A repository borrowing the clone's objects, which hold the blob.
        try runGit(["hash-object", "-w", "--stdin"], in: clone, input: "borrowed\n")
        try runGit(["clone", "-q", "--shared", clone.path, borrower.path], in: clone)
        try runGit(["remote", "set-url", "origin", upstream.path], in: borrower)
        _ = try fetch(borrower, tags: nil)
        #expect(try tagNames(borrower).contains("tborrowed"))
    }

    @Test("a tag fetched by a short source is the refspec's, not a followed one")
    func shortSourceTag() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        // vside2 is on `side`, which this fetch doesn't bring.
        let (output, error) = try fetch(clone, ["vside2:refs/tags/x"], tags: nil)
        #expect(error == nil)
        #expect(output.contains(" * [new tag]         vside2     -> x\n"))
        #expect(try runGit(["rev-parse", "x"], in: clone) == runGit(["rev-parse", "vside2"], in: upstream))
    }

    @Test("--no-tags follows none, and overrides tagOpt")
    func noTags() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        try runGit(["config", "remote.origin.tagOpt", "--tags"], in: clone)
        _ = try fetch(clone, tags: .off)
        #expect(try tagNames(clone) == ["v1", "v2", "vside"])
    }

    @Test("tagOpt --tags fetches every tag even for an explicit refspec")
    func tagOpt() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        try runGit(["config", "remote.origin.tagOpt", "--tags"], in: clone)
        let (output, _) = try fetch(clone, ["main"], tags: nil)
        #expect(output.contains(" * branch            main       -> FETCH_HEAD\n"))
        #expect(try tagNames(clone) == ["v1", "v2", "v3", "vside", "vside2"])
        #expect(try fetchHead(clone).first == "branch 'main'")
    }

    @Test("a tag that moved on the remote isn't clobbered")
    func clobber() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        let before = try runGit(["rev-parse", "v1"], in: clone)
        try runGit(["tag", "-f", "v1", "main"], in: upstream)
        let (output, error) = try fetch(clone, tags: .all)
        #expect(error == FetchRejectedError(refs: ["refs/tags/v1"]))
        // git lines the summary up unpadded once it refused something.
        #expect(output.contains(" ! [rejected] v1         -> v1  (would clobber existing tag)\n"))
        #expect(output.contains(" * [new tag] v3         -> v3\n"))
        #expect(try runGit(["rev-parse", "v1"], in: clone) == before)

        // Forced, it moves.
        let forced = try fetch(clone, ["+refs/tags/*:refs/tags/*"], tags: .all)
        #expect(forced.error == nil)
        #expect(forced.output.contains(" t [tag update]      v1         -> v1\n"))
        #expect(try runGit(["rev-parse", "v1"], in: clone) == runGit(["rev-parse", "v1"], in: upstream))
    }

    @Test("a branch fetched into tags clobbers none of them, by a short source or into two")
    func branchIntoTags() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        let specs = ["main:refs/tags/x", "refs/heads/main:refs/tags/a", "refs/heads/main:refs/tags/b"]
        _ = try fetch(clone, specs, tags: .off)
        let before = try runGit(["rev-parse", "x"], in: clone)
        try runGit(["commit", "-q", "--allow-empty", "-m", "four"], in: upstream)
        let (output, error) = try fetch(clone, specs, tags: .off)
        #expect(error == FetchRejectedError(refs: ["refs/tags/x", "refs/tags/a", "refs/tags/b"]))
        #expect(output.contains("""
             ! [rejected] main       -> x  (would clobber existing tag)
             ! [rejected] main       -> a  (would clobber existing tag)
             ! [rejected] main       -> b  (would clobber existing tag)

            """))
        for tag in ["x", "a", "b"] {
            #expect(try runGit(["rev-parse", tag], in: clone) == before)
        }
    }

    @Test("a negative refspec keeps --tags off a tag an explicit refspec still stores")
    func excludedButExplicit() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        let (output, error) = try fetch(
            clone, ["+refs/heads/main:refs/tags/v1", "^refs/tags/v1"], tags: .all)
        #expect(error == nil)
        #expect(try runGit(["rev-parse", "v1"], in: clone) == runGit(["rev-parse", "main"], in: upstream))
        #expect(output.components(separatedBy: " -> v1\n").count == 2)
    }

    @Test("an object ID fetched into a tag doesn't clobber it")
    func objectIDIntoTag() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try fetch(clone, ["main:refs/tags/x"], tags: .off)
        let before = try runGit(["rev-parse", "x"], in: clone)
        try runGit(["commit", "-q", "--allow-empty", "-m", "four"], in: upstream)
        let sha = try runGit(["rev-parse", "main"], in: upstream)
        let (output, error) = try fetch(clone, ["\(sha):refs/tags/x"], tags: .off)
        #expect(error == FetchRejectedError(refs: ["refs/tags/x"]))
        #expect(output.contains(" ! [rejected] \(sha) -> x  (would clobber existing tag)\n"))
        #expect(try runGit(["rev-parse", "x"], in: clone) == before)
    }

    @Test("an object ID fetched into a tag --tags excludes still lands there")
    func objectIDIntoExcludedTag() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        try runGit(["tag", "-d", "v1"], in: clone)
        let sha = try runGit(["rev-parse", "main"], in: upstream)
        let (output, error) = try fetch(clone, ["\(sha):refs/tags/v1", "^refs/tags/v1"], tags: .all)
        #expect(error == nil)
        #expect(output.contains(" * [new ref]         \(sha) -> v1\n"))
        #expect(try runGit(["rev-parse", "v1"], in: clone) == sha)

        // Forced, it moves the tag that's there.
        let other = try runGit(["rev-parse", "side"], in: upstream)
        let forced = try fetch(clone, ["+\(other):refs/tags/v1", "^refs/tags/v1"], tags: .all)
        #expect(forced.error == nil)
        #expect(try runGit(["rev-parse", "v1"], in: clone) == other)
    }

    @Test("the remote's HEAD fetched into a tag doesn't clobber it")
    func headIntoTag() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try fetch(clone, ["HEAD:refs/tags/x"], tags: .off)
        let before = try runGit(["rev-parse", "x"], in: clone)
        try runGit(["commit", "-q", "--allow-empty", "-m", "four"], in: upstream)
        let (output, error) = try fetch(clone, ["HEAD:refs/tags/x"], tags: .off)
        #expect(error == FetchRejectedError(refs: ["refs/tags/x"]))
        #expect(output.contains(" ! [rejected] HEAD       -> x  (would clobber existing tag)\n"))
        #expect(try runGit(["rev-parse", "x"], in: clone) == before)
    }

    @Test("a negative refspec excludes a tag from an explicit refspec too")
    func excludedExplicitSource() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        let before = try runGit(["rev-parse", "v1"], in: clone)
        try runGit(["tag", "-f", "v1", "main"], in: upstream)
        let (_, error) = try fetch(clone, ["refs/tags/v1:refs/tags/v1", "^refs/tags/v1"], tags: .all)
        #expect(error == nil)
        #expect(try runGit(["rev-parse", "v1"], in: clone) == before)
    }

    @Test("a short source is the ref git picks for it: a tag before a branch")
    func shortSourcePrefersTag() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        try runGit(["tag", "foo", "main"], in: upstream)
        try runGit(["branch", "foo", "main"], in: upstream)
        _ = try fetch(clone, ["refs/tags/foo:refs/tags/x"], tags: .off)
        try runGit(["checkout", "-q", "foo"], in: upstream)
        try runGit(["commit", "-q", "--allow-empty", "-m", "f"], in: upstream)
        try runGit(["checkout", "-q", "main"], in: upstream)
        let (_, error) = try fetch(clone, ["foo:refs/tags/x"], tags: .off)
        #expect(error == nil)
        #expect(try runGit(["rev-parse", "x"], in: clone) == runGit(["rev-parse", "refs/tags/foo"], in: upstream))
    }

    @Test("a symbolic tag a negative refspec excludes stays as it was")
    func symbolicExcludedTag() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        try runGit(["tag", "x", "main"], in: upstream)
        try runGit(["symbolic-ref", "refs/tags/x", "refs/heads/main"], in: clone)
        _ = try fetch(clone, ["refs/heads/*:refs/remotes/origin/*", "^refs/tags/x"], tags: .all)
        #expect(try runGit(["symbolic-ref", "refs/tags/x"], in: clone) == "refs/heads/main")
    }

    @Test("--tags leaves a symbolic tag alone, as git does")
    func symbolicTagUntouched() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        try runGit(["tag", "x", "side"], in: upstream)
        try runGit(["symbolic-ref", "refs/tags/x", "refs/heads/main"], in: clone)
        let (output, error) = try fetch(clone, tags: .all)
        #expect(error == nil)
        #expect(!output.contains(" -> x"))
        #expect(try runGit(["symbolic-ref", "refs/tags/x"], in: clone) == "refs/heads/main")
        #expect(!(try fetchHead(clone)).contains("not-for-merge tag 'x'"))
    }

    @Test("an explicit refspec into a symbolic tag is refused, as git refuses it")
    func symbolicTagExplicit() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        try runGit(["tag", "x", "side"], in: upstream)
        try runGit(["symbolic-ref", "refs/tags/x", "refs/heads/main"], in: clone)
        for tags in [FetchTags.off, .all] {
            let (output, error) = try fetch(clone, ["refs/tags/x:refs/tags/x"], tags: tags)
            #expect(error == FetchRejectedError(refs: ["refs/tags/x"]))
            #expect(output.contains(" -> x  (would clobber existing tag)\n"))
            #expect(try runGit(["symbolic-ref", "refs/tags/x"], in: clone) == "refs/heads/main")
        }
    }

    @Test("a fetched ref that is an annotated tag vouches for what it points at")
    func annotatedTagTip() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        try runGit(["checkout", "-q", "-b", "hidden"], in: upstream)
        try runGit(["commit", "-q", "--allow-empty", "-m", "h"], in: upstream)
        try runGit(["tag", "vhidden"], in: upstream)
        try runGit(["tag", "-a", "ann", "-m", "a"], in: upstream)
        try runGit(["update-ref", "refs/meta/ann", "refs/tags/ann"], in: upstream)
        try runGit(["checkout", "-q", "main"], in: upstream)
        _ = try fetch(clone, ["refs/meta/ann:refs/meta/ann"], tags: nil)
        #expect(try tagNames(clone).contains("vhidden"))
    }

    @Test("a negative refspec keeps a tag out of --tags")
    func negativeRefspec() throws {
        let (upstream, clone) = try makeUpstreamAndClone()
        defer { [upstream, clone].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try fetch(clone, ["refs/heads/*:refs/remotes/origin/*", "^refs/tags/v3"], tags: .all)
        #expect(try tagNames(clone) == ["v1", "v2", "vside", "vside2"])
        #expect(!(try fetchHead(clone)).contains("not-for-merge tag 'v3'"))
    }
}
#endif
