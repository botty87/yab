import Foundation
import Testing
@testable import Fast

/// Claude Code is told Yab is its client however a launch starts: on an
/// account, on none, or from an app opened with another client's origin.
@MainActor
struct AgentLaunchEntrypointTests {
    private func plans() -> (PlanAccounts, UserDefaults, String) {
        let name = "dev.serafim.fast.test.entrypoint." + UUID().uuidString
        let settings = UserDefaults(suiteName: name)!
        return (PlanAccounts(settings: settings), settings, name)
    }

    private func found(_ origin: String?) -> Shell.Found {
        var env = ["PATH": "/test/bin"]
        env["CLAUDE_CODE_ENTRYPOINT"] = origin
        return Shell.Found(claude: "/test/bin/claude", codex: "/test/bin/codex", cursor: "/test/bin/cursor-agent", env: env)
    }

    @Test func aClaudeLaunchNamesYabWithOrWithoutAnAccount() throws {
        let (plans, settings, name) = plans()
        defer { settings.removePersistentDomain(forName: name) }
        for origin in [nil, "claude-desktop", "cli", "sdk-cli"] {
            let found = found(origin)
            // The usual account, as a task and as a look see it.
            let task = try #require(AgentLaunch.resolve("claude", in: found, plans: plans))
            #expect(task.account?.usual == true)
            #expect(task.env["CLAUDE_CODE_ENTRYPOINT"] == "yab")
            #expect(AgentLaunch.look("claude", in: found, plans: plans)?.env["CLAUDE_CODE_ENTRYPOINT"] == "yab")
            // Every account already tried: pick has none, the launch has no account.
            #expect(plans.pick("claude", skipping: ["claude"]) == nil)
            let bare = AgentLaunch.on(nil, cli: "claude", binary: "/test/bin/claude", in: found, plans: plans)
            #expect(bare.env == ["PATH": "/test/bin", "CLAUDE_CODE_ENTRYPOINT": "yab"])
            // Another account's folder, its key never looked up.
            let other = PlanAccount(id: "claude.other", cli: "claude", home: "/test/other")
            let extra = AgentLaunch.on(other, cli: "claude", binary: "/test/bin/claude", in: found, plans: plans)
            #expect(extra.env == ["PATH": "/test/bin", "CLAUDE_CONFIG_DIR": "/test/other", "CLAUDE_CODE_ENTRYPOINT": "yab"])
        }
    }

    @Test func otherAgentsKeepTheEnvironmentTheyWereHanded() {
        let (plans, settings, name) = plans()
        defer { settings.removePersistentDomain(forName: name) }
        let found = found("claude-desktop")
        for cli in ["codex", "cursor", "gemini", "external"] {
            #expect(AgentLaunch.named(cli, found.env) == found.env)
        }
        #expect(AgentLaunch.on(nil, cli: "codex", binary: "/test/bin/codex", in: found, plans: plans).env == found.env)
        #expect(AgentLaunch.named("claude", found.env) == ["PATH": "/test/bin", "CLAUDE_CODE_ENTRYPOINT": "yab"])
    }
}
