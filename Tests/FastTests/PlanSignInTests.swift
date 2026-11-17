import Foundation
import Testing
@testable import Fast

@MainActor
struct PlanSignInTests {
    private func settings() -> (UserDefaults, String) {
        let name = "dev.serafim.fast.test.signin." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    private func seed(_ settings: UserDefaults, usual: PlanAccount, extras: [PlanAccount] = []) throws {
        settings.set(try JSONEncoder().encode([usual.cli: usual]), forKey: "plans.usual")
        settings.set(try JSONEncoder().encode(extras), forKey: "plans.accounts")
        settings.set([usual.id] + extras.map(\.id), forKey: "plans.order")
        settings.set([usual.id], forKey: "plans.signedOut")
    }

    @Test func aDifferentIdentityKeepsTheOldAccountAndQuotaAcrossRestart() throws {
        let (settings, name) = settings()
        defer { settings.removePersistentDomain(forName: name) }
        let old = PlanAccount(id: "claude", cli: "claude", email: "old@example.com", plan: "max")
        try seed(settings, usual: old)
        let accounts = PlanAccounts(settings: settings)
        accounts.ranOut(old.id, until: Date().addingTimeInterval(3600))
        let quota = accounts.quotas[old.id]
        let fresh = PlanAccount(id: "claude.new", cli: "claude", home: "/test/new", email: "new@example.com", plan: "pro")
        let accepted = accounts.acceptSignIn(fresh, replacing: old.id)
        #expect(accepted == fresh)
        #expect(accounts.account(old.id) == old)
        #expect(accounts.signedOut.contains(old.id))
        #expect(accounts.quotas[old.id] == quota)
        #expect(accounts.quotas[fresh.id] == nil)
        #expect(accounts.pick("claude") == fresh)
        #expect(accounts.env(accepted, base: ["PATH": "/test/bin"])["CLAUDE_CONFIG_DIR"] == fresh.home)

        let restarted = PlanAccounts(settings: settings)
        #expect(restarted.all("claude").count == 2)
        #expect(restarted.account(old.id) == old)
        #expect(restarted.signedOut.contains(old.id))
        #expect(restarted.pick("claude") == fresh)
    }

    @Test func theSameIdentityRenewsTheStableSlotAndKeepsItsOrder() throws {
        let (settings, name) = settings()
        defer { settings.removePersistentDomain(forName: name) }
        let old = PlanAccount(id: "claude", cli: "claude", email: "me@example.com", plan: "max")
        try seed(settings, usual: old)
        let accounts = PlanAccounts(settings: settings)
        let fresh = PlanAccount(id: "claude.login", cli: "claude", home: "/test/renewed", email: "ME@example.com", plan: "pro")
        let accepted = accounts.acceptSignIn(fresh, replacing: old.id)
        #expect(accepted.id == old.id)
        #expect(accepted.usual)
        #expect(accepted.home == fresh.home)
        #expect(accounts.all("claude").count == 1)
        #expect(accounts.order == [old.id])
        #expect(!accounts.signedOut.contains(old.id))
        #expect(PlanAccounts(settings: settings).account(old.id) == accepted)
    }

    @Test func signingInAsAnExistingExtraRenewsItWithoutRemovingTheOldAccount() throws {
        let (settings, name) = settings()
        defer { settings.removePersistentDomain(forName: name) }
        let old = PlanAccount(id: "claude", cli: "claude", email: "old@example.com")
        let extra = PlanAccount(id: "claude.extra", cli: "claude", home: "/test/extra", email: "other@example.com")
        try seed(settings, usual: old, extras: [extra])
        let accounts = PlanAccounts(settings: settings)
        let fresh = PlanAccount(id: "claude.login", cli: "claude", home: "/test/renewed", email: extra.email)
        let accepted = accounts.acceptSignIn(fresh, replacing: old.id)
        #expect(accepted.id == extra.id)
        #expect(accepted.home == fresh.home)
        #expect(accounts.account(old.id) == old)
        #expect(accounts.all("claude").count == 2)
        #expect(accounts.pick("claude") == accepted)
    }

    @Test func anUnknownIdentityCannotReplaceAKnownOne() throws {
        let (settings, name) = settings()
        defer { settings.removePersistentDomain(forName: name) }
        let old = PlanAccount(id: "claude", cli: "claude", email: "old@example.com")
        try seed(settings, usual: old)
        let accounts = PlanAccounts(settings: settings)
        let fresh = PlanAccount(id: "claude.login", cli: "claude", home: "/test/new")
        #expect(accounts.acceptSignIn(fresh, replacing: old.id) == fresh)
        #expect(accounts.account(old.id) == old)
        #expect(accounts.all("claude").count == 2)
    }

    @Test func aDifferentIdentityAlsoKeepsASignedOutExtra() throws {
        let (settings, name) = settings()
        defer { settings.removePersistentDomain(forName: name) }
        let usual = PlanAccount(id: "claude", cli: "claude", email: "first@example.com")
        let extra = PlanAccount(id: "claude.extra", cli: "claude", home: "/test/extra", email: "old@example.com")
        try seed(settings, usual: usual, extras: [extra])
        settings.set([usual.id, extra.id], forKey: "plans.signedOut")
        let accounts = PlanAccounts(settings: settings)
        let fresh = PlanAccount(id: "claude.login", cli: "claude", home: "/test/new", email: "new@example.com")
        accounts.acceptSignIn(fresh, replacing: extra.id)
        #expect(accounts.account(extra.id) == extra)
        #expect(accounts.signedOut.contains(extra.id))
        #expect(accounts.all("claude").count == 3)
        #expect(accounts.pick("claude") == fresh)
    }

    @Test func theFirstLoginUsesThePrimarySlotAndCodexHasItsOwnEnvironment() throws {
        let (settings, name) = settings()
        defer { settings.removePersistentDomain(forName: name) }
        let accounts = PlanAccounts(settings: settings)
        let first = accounts.prepareSignIn("claude", replacing: "claude")
        #expect(first.id == "claude" && first.home == nil)
        #expect(accounts.env(first, base: ["PATH": "/test/bin"]) == ["PATH": "/test/bin", "CLAUDE_CODE_ENTRYPOINT": "yab"])
        let fresh = PlanAccount(id: "codex.login", cli: "codex", home: "/test/codex", email: "me@example.com")
        let accepted = accounts.acceptSignIn(fresh, replacing: "codex")
        #expect(accepted.id == "codex")
        #expect(accepted.usual)
        #expect(accounts.all("codex").count == 1)
        #expect(accounts.env(accepted, base: [:]) == ["CODEX_HOME": "/test/codex"])
        #expect(accounts.account("claude")?.home == nil)
    }

    @Test func refreshingAndCancelingUseOnlyTheirOwnConfigFolders() async throws {
        let (settings, name) = settings()
        defer { settings.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yab-signin-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalHome = root.appendingPathComponent("original")
        let freshHome = root.appendingPathComponent("candidate")
        for home in [originalHome, freshHome] { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
        let old = PlanAccount(id: "claude", cli: "claude", home: originalHome.path, email: "old@example.com", plan: "max")
        try seed(settings, usual: old)
        let consent = ProviderConsent(settings: settings, history: [])
        consent.beginConnection("claude")
        defer { consent.cancelConnections() }
        let permit = try #require(consent.connectionPermit("claude"))
        let accounts = PlanAccounts(settings: settings, consent: consent)
        let binary = root.appendingPathComponent("claude")
        try """
        #!/bin/sh
        case "$2" in
          status) /bin/cat "$CLAUDE_CONFIG_DIR/status.json" ;;
          logout) printf '%s' "$CLAUDE_CONFIG_DIR" > "$SIGNIN_LOG" ;;
          *) exit 1 ;;
        esac
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try #"{"loggedIn":false}"#.write(to: originalHome.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        await accounts.remember(old, binary: binary.path, base: [:], permit: permit)
        #expect(accounts.account(old.id)?.email == old.email)
        #expect(accounts.signedOut.contains(old.id))
        let fresh = PlanAccount(id: "claude.login", cli: "claude", home: freshHome.path, email: "new@example.com", plan: "pro")
        let log = root.appendingPathComponent("logout.txt")
        await accounts.discardSignIn(fresh, binary: binary.path, base: ["SIGNIN_LOG": log.path])
        #expect(try String(contentsOf: log, encoding: .utf8) == freshHome.path)
        #expect(!FileManager.default.fileExists(atPath: freshHome.path))
        #expect(FileManager.default.fileExists(atPath: originalHome.path))
        #expect(accounts.account(old.id) == old)
        #expect(accounts.extras.isEmpty)

        try FileManager.default.createDirectory(at: freshHome, withIntermediateDirectories: true)
        try #"{"loggedIn":true,"email":"new@example.com","subscriptionType":"pro"}"#.write(to: freshHome.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        // Looking reads the config folder, as the CLI left it.
        try #"{"oauthAccount":{"emailAddress":"new@example.com"}}"#.write(to: freshHome.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        accounts.acceptSignIn(fresh, replacing: old.id)
        await accounts.look(Shell.Found(claude: binary.path, env: [:]))
        #expect(accounts.account(old.id) == old)
        #expect(accounts.account(fresh.id) == fresh)
        #expect(accounts.pick("claude") == fresh)
    }

    @Test func refreshingARenewedPrimaryKeepsItsManagedFolder() async throws {
        let (settings, name) = settings()
        defer { settings.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yab-signin-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf '%s' '{\"loggedIn\":true,\"email\":\"me@example.com\",\"subscriptionType\":\"max\"}'\n"
            .write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let old = PlanAccount(id: "claude", cli: "claude", email: "me@example.com")
        try seed(settings, usual: old)
        let accounts = PlanAccounts(settings: settings)
        try #"{"oauthAccount":{"emailAddress":"me@example.com"}}"#.write(to: root.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let fresh = PlanAccount(id: "claude.login", cli: "claude", home: root.path, email: old.email)
        accounts.acceptSignIn(fresh, replacing: old.id)
        await accounts.look(Shell.Found(claude: binary.path, env: [:]))
        #expect(accounts.account(old.id)?.home == root.path)
        #expect(accounts.account(old.id)?.usual == true)
        #expect(!accounts.signedOut.contains(old.id))
        #expect(PlanAccounts(settings: settings).account(old.id)?.home == root.path)
    }

    @Test func aSignedOutCLIRetainsItsLastIdentityBeforeTheFirstRenewal() async throws {
        let (settings, name) = settings()
        defer { settings.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yab-signin-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf '%s' '{\"loggedIn\":false}'\nexit 1\n"
            .write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try #"{"oauthAccount":{"emailAddress":"old@example.com"}}"#
            .write(to: root.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let old = PlanAccount(id: "claude", cli: "claude", home: root.path)
        try seed(settings, usual: old)
        let consent = ProviderConsent(settings: settings, history: [])
        consent.beginConnection("claude")
        defer { consent.cancelConnections() }
        let permit = try #require(consent.connectionPermit("claude"))
        let accounts = PlanAccounts(settings: settings, consent: consent)
        await accounts.remember(old, binary: binary.path, base: [:], permit: permit)
        #expect(accounts.account(old.id)?.email == "old@example.com")
        #expect(accounts.signedOut.contains(old.id))
        #expect(PlanAccounts(settings: settings).account(old.id)?.email == "old@example.com")
    }

    @Test func aSignedOutCodexCanStillIdentifyTheAccountInItsConfig() async throws {
        let fixture = IsolatedProviderConsent("codex")
        defer { fixture.close() }
        let permit = try #require(fixture.consent.permit("codex"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yab-signin-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 1\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let claims = Data(#"{"email":"old@example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let auth = ["tokens": ["id_token": "test." + claims + ".test"]]
        try JSONSerialization.data(withJSONObject: auth).write(to: root.appendingPathComponent("auth.json"))
        let old = PlanAccount(id: "codex", cli: "codex", home: root.path)
        let who = await PlanAccounts.identify(old, binary: binary.path, env: [:], permit: permit)
        #expect(!who.signedIn)
        #expect(who.email == "old@example.com")
        #expect(who.plan == "pro")
    }

    @Test func aRevokedPermitCannotIdentifyOrRememberAnotherAccount() async throws {
        let fixture = IsolatedProviderConsent("claude")
        defer { fixture.close() }
        let permit = try #require(fixture.consent.permit("claude"))
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("claude")
        let marker = root.appendingPathComponent("launched")
        try "#!/bin/sh\ntouch \"$CLAUDE_CONFIG_DIR/launched\"\necho '{\"loggedIn\":true,\"email\":\"new@example.test\"}'\n"
            .write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let old = PlanAccount(id: "claude", cli: "claude", home: root.path, email: "old@example.test")
        try seed(fixture.settings, usual: old)
        let accounts = PlanAccounts(settings: fixture.settings, consent: fixture.consent)
        fixture.consent.revoke("claude")
        let who = await PlanAccounts.identify(old, binary: binary.path, env: ["CLAUDE_CONFIG_DIR": root.path, "PATH": "/usr/bin:/bin"], permit: permit)
        await accounts.remember(old, binary: binary.path, base: ["PATH": "/usr/bin:/bin"], permit: permit)
        #expect(!who.signedIn && who.email == nil && who.plan == nil)
        #expect(accounts.account(old.id) == old && accounts.signedOut.contains(old.id))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!fixture.consent.allows("claude"))
    }
    // MARK: - signed in, from files alone

    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yab-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func codexIsSignedInWhenItsAuthFileHoldsTokensOrAKey() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["CODEX_HOME": home.path]
        #expect(!(await PlanAccounts.read("codex", env: env)).signedIn)
        let claims = Data(#"{"email":"me@example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"plus"}}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        let auth = home.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": "x." + claims + ".y", "access_token": "a", "refresh_token": "r"]]).write(to: auth)
        let who = (await PlanAccounts.read("codex", env: env))
        #expect(who.signedIn)
        #expect(who.email == "me@example.com")
        #expect(who.plan == "plus")
        try JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": "sk-test"]).write(to: auth)
        #expect((await PlanAccounts.read("codex", env: env)).signedIn)
        // Logged out: nothing left in the file.
        try JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": NSNull(), "tokens": NSNull()]).write(to: auth)
        #expect(!(await PlanAccounts.read("codex", env: env)).signedIn)
    }

    @Test func claudeIsSignedInWhenItsConfigNamesItsAccount() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["CLAUDE_CONFIG_DIR": home.path]
        #expect(!(await PlanAccounts.read("claude", env: env)).signedIn)
        let config = home.appendingPathComponent(".claude.json")
        try #"{"numStartups":3,"mcpServers":{}}"#.write(to: config, atomically: true, encoding: .utf8)
        #expect(!(await PlanAccounts.read("claude", env: env)).signedIn)
        try #"{"oauthAccount":{"accountUuid":"u-1","emailAddress":"me@example.com"}}"#.write(to: config, atomically: true, encoding: .utf8)
        let who = (await PlanAccounts.read("claude", env: env))
        #expect(who.signedIn)
        #expect(who.email == "me@example.com")
        // A key given in the environment counts, its value never read.
        try FileManager.default.removeItem(at: config)
        #expect((await PlanAccounts.read("claude", env: env.merging(["ANTHROPIC_API_KEY": "sk-test"]) { $1 })).signedIn)
        // The credentials file Claude Code keeps where there is no keychain.
        try "{}".write(to: home.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
        #expect((await PlanAccounts.read("claude", env: env)).signedIn)
    }

    @Test func lookingAtAccountsRunsNoAgent() async throws {
        let (settings, name) = settings()
        defer { settings.removePersistentDomain(forName: name) }
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("ran")
        for cli in ["claude", "codex"] {
            try "#!/bin/sh\necho run >> '\(marker.path)'\n".write(to: root.appendingPathComponent(cli), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(cli).path)
        }
        let claudeHome = root.appendingPathComponent("claude-home"), codexHome = root.appendingPathComponent("codex-home")
        for home in [claudeHome, codexHome] { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
        try #"{"oauthAccount":{"emailAddress":"me@example.com"}}"#.write(to: claudeHome.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let claude = PlanAccount(id: "claude", cli: "claude", home: claudeHome.path)
        let codex = PlanAccount(id: "codex", cli: "codex", home: codexHome.path)
        settings.set(try JSONEncoder().encode(["claude": claude, "codex": codex]), forKey: "plans.usual")
        settings.set(["claude", "codex"], forKey: "plans.order")
        settings.set(["claude", "codex"], forKey: "plans.signedOut")
        let accounts = PlanAccounts(settings: settings)
        await accounts.look(Shell.Found(claude: root.appendingPathComponent("claude").path, codex: root.appendingPathComponent("codex").path, env: [:]))
        #expect(!accounts.signedOut.contains("claude"))
        #expect(accounts.account("claude")?.email == "me@example.com")
        #expect(accounts.signedOut.contains("codex"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// `claude setup-token`'s token (feedback #80): the usual Claude
    /// account runs with it, as your terminal's claude does; another
    /// account never gets it, since Claude Code takes it before any
    /// folder's own sign-in.
    @Test func aSetupTokenGoesToTheUsualClaudeAccountAlone() async throws {
        let (settings, name) = settings()
        defer { settings.removePersistentDomain(forName: name) }
        let accounts = PlanAccounts(settings: settings)
        let base = ["PATH": "/test/bin", Shell.claudeToken: "sk-ant-oat01-stand-in"]
        let usual = PlanAccount(id: "claude", cli: "claude")
        #expect(accounts.env(usual, base: base) == base.merging(["CLAUDE_CODE_ENTRYPOINT": "yab"]) { $1 })
        #expect(accounts.env(nil, base: base) == base)
        let renewed = PlanAccount(id: "claude", cli: "claude", home: "/test/renewed")
        #expect(accounts.env(renewed, base: base)[Shell.claudeToken] == "sk-ant-oat01-stand-in")
        let other = PlanAccount(id: "claude.other", cli: "claude", home: "/test/other")
        #expect(accounts.env(other, base: base) == ["PATH": "/test/bin", "CLAUDE_CONFIG_DIR": "/test/other", "CLAUDE_CODE_ENTRYPOINT": "yab"])
        #expect((await PlanAccounts.read("claude", env: accounts.env(usual, base: base))).signedIn)
    }

    /// Every Claude Code process Yab starts names Yab as its client, over
    /// whatever origin the app was opened with. Other CLIs are left alone.
    @Test func everyClaudeAccountRunsAsYab() {
        let (settings, name) = settings()
        defer { settings.removePersistentDomain(forName: name) }
        let accounts = PlanAccounts(settings: settings)
        let claude = [PlanAccount(id: "claude", cli: "claude"),
                      PlanAccount(id: "claude.other", cli: "claude", home: "/test/other"),
                      PlanAccount(id: "claude.key", cli: "claude", tail: "abcd")]
        for origin in ["claude-desktop", "cli", "sdk-cli"] {
            let base = ["PATH": "/test/bin", "CLAUDE_CODE_ENTRYPOINT": origin]
            for account in claude {
                #expect(accounts.env(account, base: base)["CLAUDE_CODE_ENTRYPOINT"] == "yab")
                #expect(PlanAccounts.environment(account, base: base, secret: nil)["CLAUDE_CODE_ENTRYPOINT"] == "yab")
            }
            let codex = PlanAccount(id: "codex.other", cli: "codex", home: "/test/codex")
            #expect(accounts.env(codex, base: base) == base.merging(["CODEX_HOME": "/test/codex"]) { $1 })
            let cursor = PlanAccount(id: "cursor", cli: "cursor")
            #expect(accounts.env(cursor, base: base) == CursorRunner.environment(base))
        }
        #expect(accounts.env(PlanAccount(id: "claude", cli: "claude"), base: [:]) == ["CLAUDE_CODE_ENTRYPOINT": "yab"])
    }

    /// The login shell says the token after everything else; only a line
    /// of a token's characters counts, and the part before is read as ever.
    @Test func theLoginShellsTokenIsReadApartFromThePath() {
        let said = "Last login: Mon\n__yab_agent__\n/usr/bin:/bin\n/test/claude\n\n/test/codex\n\n__yab_token__\nsk-ant-oat01-Ab_c-9\n__yab_token__\nlogout: bye\n"
        let (rest, token) = Shell.token(in: said)
        #expect(token == "sk-ant-oat01-Ab_c-9")
        #expect(!rest.contains("__yab_token__") && !rest.contains("sk-ant"))
        #expect(rest.hasSuffix("/test/codex\n\n"))
        #expect(Shell.token(in: "__yab_agent__\n/usr/bin:/bin\n").token == nil)
        #expect(Shell.token(in: "__yab_token__\n__yab_token__\nbye\n").token == nil)
        // Cut short before its end: not a token, and not read as a path.
        #expect(Shell.token(in: "/usr/bin:/bin\n__yab_token__\nsk-ant-oat01-x").token == nil)
        #expect(Shell.token(in: "/usr/bin:/bin\n__yab_token__\nsk-ant-oat01-x").rest == "/usr/bin:/bin\n")
        #expect(Shell.token(in: "__yab_token__\nnot a token\n__yab_token__\n").token == nil)
        #expect(Shell.clean("  sk-ant-oat01-x \n") == "sk-ant-oat01-x")
    }

    /// Opened from inside Claude Code, the app's environment is that
    /// session's: a token in it isn't yours.
    @Test func aTokenFromInsideAnAgentIsNotTaken() {
        #expect(Shell.mayInherit([:]))
        #expect(Shell.mayInherit(["HOME": "/test"]))
        #expect(!Shell.mayInherit(["CLAUDECODE": "1"]))
        #expect(!Shell.mayInherit(["CLAUDE_CODE_ENTRYPOINT": "cli"]))
    }
}
