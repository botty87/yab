import Foundation
import Testing
@testable import Fast

/// Real pipe/EOF ordering, with a local protocol stub and no provider account.
@MainActor
@Suite(.serialized)
struct AgentArchiveLifecycleTests {
    private struct World {
        let root: URL
        let binary: URL
        let log: URL
        let gate: URL
        let auth: URL

        func messages() -> [[String: Any]] {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
        }
    }

    private func world() throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-archive-lifecycle-" + UUID().uuidString)
        let auth = root.appendingPathComponent("source-account", isDirectory: true)
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        // CodexProbe only needs a file to link. The stub never reads sign-in.
        try Data("{}".utf8).write(to: auth.appendingPathComponent("auth.json"))
        let binary = root.appendingPathComponent("codex-stub")
        try #"""
        #!/usr/bin/python3
        import json, os, sys, time

        def log(message):
            with open(os.environ['ARCHIVE_LOG'], 'a') as output:
                output.write(json.dumps(message) + '\n')

        def emit(message):
            print(json.dumps(message), flush=True)

        thread = os.environ['ARCHIVE_THREAD']
        mode = sys.argv[1]
        log({'event': 'launch', 'mode': mode, 'pid': os.getpid()})
        if mode == 'exec':
            events = [
                {'type': 'thread.started', 'thread_id': thread},
                {'type': 'item.completed', 'item': {'id': 'answer', 'type': 'agent_message', 'text': 'Final exec answer'}},
                {'type': 'turn.completed', 'usage': {'input_tokens': 3, 'output_tokens': 4}},
            ]
            os.write(1, ''.join(json.dumps(event) + '\n' for event in events).encode())
            os._exit(0)

        for line in sys.stdin:
            message = json.loads(line)
            log(message)
            method = message.get('method')
            if method == 'initialize':
                emit({'id': message['id'], 'result': {}})
            elif method == 'thread/unarchive':
                emit({'id': message['id'], 'result': {'thread': {'id': thread}}})
            elif method in ('thread/start', 'thread/resume'):
                emit({'id': message['id'], 'result': {'thread': {'id': thread}}})
            elif method == 'turn/start':
                text = message['params']['input'][0]['text']
                turn = 'turn-' + str(message['id'])
                emit({'id': message['id'], 'result': {'turn': {'id': turn}}})
                emit({'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn,
                     'item': {'id': 'answer-' + turn, 'type': 'agentMessage', 'text': 'Answer: ' + text}}})
                emit({'method': 'turn/completed', 'params': {'threadId': thread,
                     'turn': {'id': turn, 'status': 'completed'}}})
            elif method == 'thread/archive':
                until = time.monotonic() + 8
                while not os.path.exists(os.environ['ARCHIVE_GATE']) and time.monotonic() < until:
                    time.sleep(0.01)
                emit({'id': message['id'], 'result': {}})
        log({'event': 'eof', 'pid': os.getpid()})
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return World(root: root, binary: binary, log: root.appendingPathComponent("wire.jsonl"),
                     gate: root.appendingPathComponent("archive-ack"), auth: auth)
    }

    private func permit(in world: World, cli: String) -> ProviderLaunchPermit? {
        let settings = UserDefaults(suiteName: "archive-consent-" + world.root.lastPathComponent)!
        let consent = ProviderConsent(settings: settings, history: [])
        consent.grant(cli)
        return consent.permit(cli)
    }

    private func session(in world: World, thread: String) -> Agents.Session {
        let session = Agents.Session(id: UUID().uuidString, cli: "codex", name: "Archive lifecycle", prompt: "First", state: .starting)
        session.providerPermit = permit(in: world, cli: "codex")
        session.quiet = true
        session.textOnly = true
        session.full = true
        session.folder = world.root.path
        session.binary = world.binary.path
        session.env = ["CODEX_HOME": world.auth.path, "ARCHIVE_LOG": world.log.path,
                       "ARCHIVE_GATE": world.gate.path, "ARCHIVE_THREAD": thread]
        return session
    }

    private func claudeWorld() throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-archive-lifecycle-" + UUID().uuidString)
        let auth = root.appendingPathComponent("source-account", isDirectory: true)
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        let binary = root.appendingPathComponent("claude-stub")
        try #"""
        #!/usr/bin/python3
        import json, os, sys

        def log(message):
            with open(os.environ['ARCHIVE_LOG'], 'a') as output:
                output.write(json.dumps(message) + '\n')

        def emit(message):
            print(json.dumps(message), flush=True)

        args = sys.argv[1:]
        assert '-p' in args
        assert args[args.index('--input-format') + 1] == 'stream-json'
        assert args[args.index('--output-format') + 1] == 'stream-json'
        resume = args[args.index('--resume') + 1] if '--resume' in args else None
        thread = resume or os.environ['ARCHIVE_THREAD']
        transcript = os.environ['ARCHIVE_TRANSCRIPT']
        keys = ['CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CONFIG_DIR', 'CLAUDE_SECURESTORAGE_CONFIG_DIR',
                'HOME', 'ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN_FILE']
        log({'event': 'launch', 'thread': thread, 'resume': resume,
             'env': {key: os.environ.get(key) for key in keys}})
        history = []
        if resume:
            with open(transcript) as source:
                history = [json.loads(line) for line in source]
            assert history and all(row['sessionId'] == resume for row in history)
        emit({'type': 'system', 'subtype': 'init', 'session_id': thread})
        for line in sys.stdin:
            message = json.loads(line)
            assert message['type'] == 'user'
            text = ''.join(part['text'] for part in message['message']['content'])
            answer = 'Answer: ' + text
            turn = len(history) // 2 + 1
            rows = [{'type': kind, 'text': value, 'sessionId': thread,
                     'entrypoint': os.environ.get('CLAUDE_CODE_ENTRYPOINT')}
                    for kind, value in [('user', text), ('assistant', answer)]]
            with open(transcript, 'a') as output:
                for row in rows:
                    output.write(json.dumps(row) + '\n')
            history.extend(rows)
            emit({**message, 'isReplay': True, 'session_id': thread})
            emit({'type': 'assistant', 'session_id': thread,
                  'message': {'id': 'answer-' + str(turn), 'role': 'assistant',
                              'content': [{'type': 'text', 'text': answer}]}})
            emit({'type': 'result', 'subtype': 'success', 'is_error': False,
                  'session_id': thread, 'result': answer, 'num_turns': turn})
        log({'event': 'eof', 'thread': thread})
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return World(root: root, binary: binary, log: root.appendingPathComponent("wire.jsonl"),
                     gate: root.appendingPathComponent("unused-gate"), auth: auth)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        // The stand-in Codex is a real process: quick alone, slower with
        // the rest of a full test run on every core.
        let until = ProcessInfo.processInfo.systemUptime + 30
        while !condition(), ProcessInfo.processInfo.systemUptime < until {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func remove(_ world: World) {
        UserDefaults(suiteName: "archive-consent-" + world.root.lastPathComponent)?.removePersistentDomain(forName: "archive-consent-" + world.root.lastPathComponent)
        Agents.codexServes.removeValue(forKey: world.binary.path)
        if Store.testing {
            let home = CodexProbe.home(root: Store.file("codex"), source: world.auth)
            try? FileManager.default.removeItem(at: home)
        }
        try? FileManager.default.removeItem(at: world.root)
    }

    @Test func followUpWaitsForArchiveAndRetiringEOFPreservesItsNewTurn() async throws {
        try #require(Store.testing)
        let world = try world()
        let agents = Agents()
        let child = session(in: world, thread: "resumable-child")
        Agents.codexServes[world.binary.path] = true
        defer {
            try? child.input?.close()
            if child.process?.isRunning == true { child.process?.terminate() }
            remove(world)
        }

        agents.start(child, message: "First")
        let awaitingArchive = await waitUntil {
            child.archiveTask != nil && world.messages().contains { $0["method"] as? String == "thread/archive" }
        }
        try #require(awaitingArchive)
        let oldProcess = try #require(child.process)
        #expect(oldProcess.isRunning)
        #expect(child.state == .done)
        #expect(child.result == "Answer: First")

        // This is the state run(resume:) installs before its deferred start.
        child.turnPermit = AgentTurnPermit() // A new deliberate follow-up, as run(resume:) admits.
        child.state = .starting
        child.prompt = "Follow-up"
        child.result = ""
        child.ended = nil
        agents.start(child, message: "Follow-up")
        await Task.yield()
        #expect(child.process === oldProcess)
        #expect(child.state == .starting)
        #expect(world.messages().filter { $0["event"] as? String == "launch" }.count == 1)

        try Data().write(to: world.gate)
        let answeredFollowUp = await waitUntil {
            child.result == "Answer: Follow-up" && child.state == .done && child.process == nil
        }
        try #require(answeredFollowUp)
        await child.archiveTask?.value
        #expect(!oldProcess.isRunning)
        #expect(child.archiveError == nil)
        #expect(!child.events.contains("Failed"))
        let methods = world.messages().compactMap { $0["method"] as? String }
        #expect(methods.filter { $0 == "thread/start" }.count == 1)
        #expect(methods.filter { $0 == "thread/resume" }.count == 1)
        // Archived after its first answer: taken out before it is resumed.
        #expect(methods.firstIndex(of: "thread/unarchive").map { $0 < methods.firstIndex(of: "thread/resume")! } == true)
        #expect(methods.filter { $0 == "turn/start" }.count == 2)
        #expect(methods.filter { $0 == "thread/archive" }.count == 2)
        let resumes = world.messages().filter { $0["method"] as? String == "thread/resume" }
        #expect((resumes.first?["params"] as? [String: Any])?["threadId"] as? String == "resumable-child")
    }

    @Test func fastExecKeepsFinalJSONAndArchivesItsExactThread() async throws {
        try #require(Store.testing)
        let world = try world()
        let agents = Agents()
        Agents.codexServes[world.binary.path] = false
        try Data().write(to: world.gate)
        defer { remove(world) }

        // Immediate exec exit exercises queued stdout against termination.
        for index in 0..<4 {
            let thread = "fast-exec-child-\(index)"
            let child = session(in: world, thread: thread)
            agents.start(child, message: "First")
            let finished = await waitUntil {
                child.state == .done && child.result == "Final exec answer" && child.archiveTask != nil
            }
            if !finished, child.process?.isRunning == true { child.process?.terminate() }
            try #require(finished)
            await child.archiveTask?.value
            #expect(child.thread == thread)
            #expect(child.archiveError == nil)
            #expect(child.items.contains { $0.kind == .message && $0.text == "Final exec answer" })
            #expect(child.tokensUsed == 7)
            let archives = world.messages().filter {
                $0["method"] as? String == "thread/archive" && ($0["params"] as? [String: Any])?["threadId"] as? String == thread
            }
            #expect(archives.count == 1)
        }
    }

    @Test func backgroundClaudeKeepsItsOriginAndHistoryAcrossArchiveAndResume() async throws {
        try #require(Store.testing)
        let world = try claudeWorld()
        let agents = Agents()
        let thread = UUID().uuidString
        let transcript = world.auth.appendingPathComponent("child.jsonl")
        let home = world.root.appendingPathComponent("user-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let settings = world.auth.appendingPathComponent("settings.json")
        let token = world.auth.appendingPathComponent("fixture-token")
        let settingsData = Data("{\"fixture\":true}".utf8)
        let tokenData = Data("fixture-token-is-not-a-credential".utf8)
        try settingsData.write(to: settings)
        try tokenData.write(to: token)
        let base = ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop", "CLAUDE_CONFIG_DIR": world.auth.path,
                    "CLAUDE_SECURESTORAGE_CONFIG_DIR": "", "HOME": home.path,
                    "ANTHROPIC_API_KEY": "fixture-key-is-not-a-credential", "CLAUDE_CODE_OAUTH_TOKEN_FILE": token.path,
                    "ARCHIVE_LOG": world.log.path, "ARCHIVE_THREAD": thread, "ARCHIVE_TRANSCRIPT": transcript.path]
        var expected = base
        expected["CLAUDE_CODE_ENTRYPOINT"] = "yab"
        // The launch puts the selected CLI's folder first on PATH (AgentCopies.environment).
        expected = AgentCopies.environment(for: world.binary.path, base: expected)
        let record = Store.file("provider-user/Library/Application Support/Claude/claude-code-sessions/fixture/local_" + thread + ".json")
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["cliSessionId": thread, "isArchived": false,
                                                  "title": "Fixture child", "unknown": "keep"]).write(to: record)
        let child = Agents.Session(id: UUID().uuidString, cli: "claude", name: "Claude lifecycle", prompt: "First", state: .starting)
        child.providerPermit = permit(in: world, cli: "claude")
        child.providerBackground = true
        child.textOnly = true
        child.full = true
        child.folder = world.root.path
        child.binary = world.binary.path
        child.env = base
        let ordinary = Agents.Session(id: UUID().uuidString, cli: "claude", name: "User lifecycle", prompt: "User task", state: .starting)
        ordinary.providerPermit = permit(in: world, cli: "claude")
        defer {
            for session in [child, ordinary] {
                try? session.input?.close()
                if session.process?.isRunning == true { session.process?.terminate() }
            }
            try? FileManager.default.removeItem(at: record)
            remove(world)
        }

        agents.start(child, message: "First")
        let firstProcess = try #require(child.process)
        let firstFinished = await waitUntil {
            child.state == .done && child.result == "Answer: First" && child.process == nil && child.archiveTask != nil
        }
        try #require(firstFinished)
        await child.archiveTask?.value
        #expect(!firstProcess.isRunning)
        #expect(child.thread == thread)
        #expect(child.archiveError == nil)
        #expect(child.providerEnvironment == expected)
        #expect(child.env == base)
        let archived = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as! [String: Any]
        #expect(archived["isArchived"] as? Bool == true)
        #expect(archived["unknown"] as? String == "keep")
        let firstTranscript = try Data(contentsOf: transcript)
        let firstItems = child.items

        child.turnPermit = AgentTurnPermit() // A new deliberate follow-up, as run(resume:) admits.
        child.state = .starting
        child.prompt = "Follow-up"
        child.result = ""
        child.ended = nil
        agents.start(child, message: "Follow-up")
        let secondFinished = await waitUntil {
            child.state == .done && child.result == "Answer: Follow-up" && child.process == nil && child.archiveTask != nil
        }
        try #require(secondFinished)
        await child.archiveTask?.value
        #expect(child.thread == thread)
        #expect(child.archiveError == nil)
        #expect(child.providerEnvironment == expected)
        #expect(child.env == base)
        #expect(firstItems.allSatisfy { old in child.items.contains { $0.id == old.id && $0.text == old.text } })
        #expect(child.items.filter { $0.kind == .asked }.map(\.text) == ["First", "Follow-up"])
        #expect(child.items.filter { $0.kind == .message }.map(\.text) == ["Answer: First", "Answer: Follow-up"])
        let finalTranscript = try Data(contentsOf: transcript)
        #expect(finalTranscript.starts(with: firstTranscript))
        let rows = try String(decoding: finalTranscript, as: UTF8.self).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        #expect(rows.map { $0["text"] as? String } == ["First", "Answer: First", "Follow-up", "Answer: Follow-up"])
        #expect(rows.allSatisfy { $0["sessionId"] as? String == thread && $0["entrypoint"] as? String == "yab" })
        let launches = world.messages().filter { $0["event"] as? String == "launch" }
        #expect(launches.count == 2)
        #expect(launches.first?["resume"] is NSNull)
        #expect(launches.last?["resume"] as? String == thread)
        #expect(launches.allSatisfy { ($0["env"] as? [String: String])?["CLAUDE_CODE_ENTRYPOINT"] == "yab" })

        // Exercise the same launch path for a user's ordinary chat.
        ordinary.textOnly = true
        ordinary.full = true
        ordinary.folder = world.root.path
        ordinary.binary = world.binary.path
        ordinary.env = base
        ordinary.env["ARCHIVE_THREAD"] = UUID().uuidString
        ordinary.env["ARCHIVE_TRANSCRIPT"] = world.auth.appendingPathComponent("ordinary.jsonl").path
        #expect(ordinary.providerPermit?.valid == true)
        agents.start(ordinary, message: "User task")
        let ordinaryFinished = await waitUntil {
            ordinary.state == .done && ordinary.result == "Answer: User task" && ordinary.process == nil
        }
        try #require(ordinaryFinished)
        #expect(ordinary.archiveTask == nil)
        #expect(ordinary.providerEnvironment == AgentCopies.environment(for: world.binary.path,
                                                                          base: ordinary.env.merging(["CLAUDE_CODE_ENTRYPOINT": "yab"]) { $1 }))
        #expect((world.messages().last { $0["event"] as? String == "launch" }?["env"] as? [String: String])?["CLAUDE_CODE_ENTRYPOINT"] == "yab")
        #expect(try Data(contentsOf: settings) == settingsData)
        #expect(try Data(contentsOf: token) == tokenData)
        #expect(!child.events.contains("Failed"))
        #expect(!ordinary.events.contains("Failed"))
    }
}
