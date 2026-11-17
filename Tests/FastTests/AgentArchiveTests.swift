import Foundation
import Testing
@testable import Fast

struct AgentArchiveTests {
    @Test func claudeOriginCannotLeakFromItsCaller() {
        let base = ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop", "CLAUDE_CONFIG_DIR": "/test/account",
                    "CLAUDE_SECURESTORAGE_CONFIG_DIR": "", "HOME": "/test/user", "PATH": "/test/bin"]
        var expected = base
        expected["CLAUDE_CODE_ENTRYPOINT"] = "yab"
        #expect(AgentArchive.environment(cli: "claude", base: base) == expected)
        #expect(AgentArchive.environment(cli: "codex", base: base) == base)
        #expect(AgentArchive.environment(cli: "external", base: base) == base)
        #expect(AgentArchive.environment(cli: "claude", base: [:]) == ["CLAUDE_CODE_ENTRYPOINT": "yab"])
    }

    /// A chat and background work both run as yab, the account's client
    /// name, even when Yab was opened with Claude Desktop's origin.
    @MainActor @Test func everyClaudeRunNamesYabOverAnInheritedOrigin() {
        for origin in ["claude-desktop", "cli"] {
            let account = PlanAccounts.environment(PlanAccount(id: "claude", cli: "claude"),
                                                   base: ["CLAUDE_CODE_ENTRYPOINT": origin, "PATH": "/test/bin"], secret: nil)
            #expect(account["CLAUDE_CODE_ENTRYPOINT"] == "yab")
            #expect(AgentArchive.environment(cli: "claude", base: account)["CLAUDE_CODE_ENTRYPOINT"] == "yab")
        }
    }

    private static func world() throws -> URL {
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("agent-archive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        return user
    }

    private static func file(_ user: URL, name: String = "local_desktop") -> URL {
        user.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions/account/org/" + name + ".json")
    }

    private static func write(_ record: [String: Any], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: record).write(to: file)
    }

    @Test func claudeArchivesOnlyTheExactConversationAndKeepsItsContents() throws {
        let user = try Self.world()
        defer { try? FileManager.default.removeItem(at: user) }
        let ours = Self.file(user)
        let other = Self.file(user, name: "local_other")
        let record: [String: Any] = ["cliSessionId": "yab-child", "sessionId": "local_desktop", "title": "Read the page",
                                    "isArchived": false, "lastActivityAt": 1_800_000_000_123 as Int64,
                                    "unknown": ["nested": ["keep", "this"], "enabled": true], "artifacts": [["url": "https://example.test"]]]
        try Self.write(record, to: ours)
        try Self.write(["cliSessionId": "user-chat", "title": "Read the page", "isArchived": false], to: other)
        let untouched = try Data(contentsOf: other)
        let transcript = user.appendingPathComponent(".claude/projects/project/yab-child.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let answer = Data("{\"type\":\"assistant\",\"text\":\"The answer\"}\n".utf8)
        try answer.write(to: transcript)

        #expect(try AgentArchive.claude(thread: "yab-child", user: user))
        var expected = record
        expected["isArchived"] = true
        let actual = try JSONSerialization.jsonObject(with: Data(contentsOf: ours)) as! NSDictionary
        #expect(actual == expected as NSDictionary)
        #expect(try Data(contentsOf: other) == untouched)
        #expect(try Data(contentsOf: transcript) == answer)
        let firstArchive = try Data(contentsOf: ours)
        #expect(try !AgentArchive.claude(thread: "yab-child", user: user))
        #expect(try Data(contentsOf: ours) == firstArchive)
    }

    @Test func claudeDoesNotCreateAnAppRecordForAnUnimportedSession() throws {
        let user = try Self.world()
        defer { try? FileManager.default.removeItem(at: user) }
        #expect(try !AgentArchive.claude(thread: "yab-child", user: user))
        #expect(!FileManager.default.fileExists(atPath: Self.file(user).path))
        try Self.write(["cliSessionId": "another"], to: Self.file(user))
        let before = try Data(contentsOf: Self.file(user))
        #expect(try !AgentArchive.claude(thread: "yab-child", user: user))
        #expect(try Data(contentsOf: Self.file(user)) == before)
    }

    @Test func claudeLeavesRunningAndMalformedRecordsAlone() throws {
        let user = try Self.world()
        defer { try? FileManager.default.removeItem(at: user) }
        let live = Self.file(user)
        let malformed = Self.file(user, name: "local_malformed")
        try Self.write(["cliSessionId": "yab-child", "isRunning": true, "isArchived": false], to: live)
        let broken = Data("unfinished JSON".utf8)
        try broken.write(to: malformed)
        let before = try Data(contentsOf: live)
        #expect(try !AgentArchive.claude(thread: "yab-child", user: user))
        #expect(try Data(contentsOf: live) == before)
        #expect(try Data(contentsOf: malformed) == broken)
        try Self.write(["cliSessionId": "yab-child", "starting": true], to: live)
        #expect(try !AgentArchive.claude(thread: "yab-child", user: user))
    }

    @Test func claudeDoesNotFollowAnAppRecordSymlink() throws {
        let user = try Self.world()
        defer { try? FileManager.default.removeItem(at: user) }
        let outside = user.appendingPathComponent("outside.json")
        try Self.write(["cliSessionId": "yab-child", "isArchived": false], to: outside)
        let link = Self.file(user)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let before = try Data(contentsOf: outside)
        #expect(try !AgentArchive.claude(thread: "yab-child", user: user))
        #expect(try Data(contentsOf: outside) == before)
    }
}
