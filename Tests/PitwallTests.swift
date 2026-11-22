import XCTest
@testable import Pitwall

final class PitwallTests: XCTestCase {
    func testPlainStripsANSIAndCarriageReturns() {
        let raw = "\u{1B}[1mbold\u{1B}[0m text\r\nprogress 10%\rprogress 100%\n\u{1B}]0;title\u{07}done"
        XCTAssertEqual(Sessions.plain(raw), "bold text\nprogress 100%\ndone")
    }

    func testLooksLikeCommand() {
        XCTAssertTrue(AppModel.looksLikeCommand("npm run dev"))
        XCTAssertTrue(AppModel.looksLikeCommand("htop"))
        XCTAssertTrue(AppModel.looksLikeCommand("cat a | grep b"))
        XCTAssertFalse(AppModel.looksLikeCommand("fix the flaky login test"))
        XCTAssertFalse(AppModel.looksLikeCommand("add Slack DMs for overdue requests"))
    }

    func testSnapRoundsToHalfGrid() {
        XCTAssertEqual(CanvasView.snap(CGPoint(x: 12, y: 30)), CGPoint(x: 11, y: 33))
    }

    func testAgentNameFromTask() {
        XCTAssertEqual(ClaudeIntegration.name(fromTask: "fix the flaky login test on staging please now"), "Fix the flaky login test on")
    }

    func testShellQuote() {
        XCTAssertEqual(shellQuote("/usr/bin/git"), "/usr/bin/git")
        XCTAssertEqual(shellQuote("it's here"), "'it'\\''s here'")
    }

    func testAttentionPriorityOrder() {
        let sorted = AgentState.allCases.sorted { $0.priority < $1.priority }
        XCTAssertEqual(sorted.first, .waiting)
        XCTAssertEqual(sorted.last, .idle)
    }

    func testTileRoundTripsThroughJSON() throws {
        var b = Board(name: "x", root: "/tmp")
        var t = Tile(kind: .agent, frame: CGRect(x: 1, y: 2, width: 3, height: 4))
        t.state = .waiting
        b.tiles = [t]
        b.links = [Link(from: t.id, to: "other", kind: .manual)]
        let d = try Wire.encoder.encode(b)
        let back = try Wire.decoder.decode(Board.self, from: d)
        XCTAssertEqual(back.tiles.first?.frame, t.frame)
        XCTAssertEqual(back.tiles.first?.state, .waiting)
        XCTAssertEqual(back.links.count, 1)
    }

    func testPRInfoParsesChecksAndReviews() {
        let json = """
        {"number":7,"title":"Fix","url":"https://github.com/o/r/pull/7","state":"OPEN","isDraft":false,"headRefName":"fix",
         "reviewDecision":"CHANGES_REQUESTED","mergeable":"MERGEABLE","additions":3,"deletions":1,
         "statusCheckRollup":[
          {"__typename":"CheckRun","name":"test","workflowName":"CI","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/o/r/actions/runs/123/job/9"},
          {"__typename":"CheckRun","name":"lint","workflowName":"CI","status":"IN_PROGRESS","conclusion":"","detailsUrl":"x"},
          {"__typename":"StatusContext","context":"vercel","state":"SUCCESS","targetUrl":"y"}],
         "comments":[{"id":"c1","author":{"login":"ann"},"body":"nit","createdAt":"2026-11-01T00:00:00Z"}],
         "reviews":[{"id":"r1","author":{"login":"bob"},"body":"","state":"CHANGES_REQUESTED","submittedAt":"2026-11-02T00:00:00Z"}]}
        """
        let pr = PRInfo.parse(Data(json.utf8))!
        XCTAssertEqual(pr.checks.map(\.name), ["CI / test", "CI / lint", "vercel"])
        XCTAssertEqual(pr.checks.filter(\.failed).first?.runID, "123")
        XCTAssertTrue(pr.checks[1].pending)
        XCTAssertFalse(pr.checks[2].pending || pr.checks[2].failed)
        XCTAssertEqual(pr.comments.map(\.author), ["ann", "bob"])
        XCTAssertEqual(pr.comments.last?.kind, "CHANGES_REQUESTED")
    }

    func testFailureExcerptFindsTheError() {
        var log = (0..<200).map { "job\tstep\t2026-11-13T16:01:25.0Z setup line \($0)" }
        log.insert("job\tstep\t2026-11-13T16:01:25.9Z ##[error]Type mismatch in login.ts", at: 150)
        let out = CanvasController.failureExcerpt(log.joined(separator: "\n"))
        XCTAssertTrue(out.contains("##[error]Type mismatch in login.ts"))
        XCTAssertFalse(out.contains("2026-11-13T"))
        XCTAssertFalse(out.contains("setup line 199"))
    }

    func testWatchFailurePatterns() {
        func fails(_ l: String) -> Bool { CanvasController.failurePattern.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil }
        XCTAssertTrue(fails("src/a.ts(3,1): error TS2322: nope"))
        XCTAssertTrue(fails("FAIL src/login.test.ts"))
        XCTAssertTrue(fails("Tests: 2 failed, 10 passed"))
        XCTAssertTrue(fails("error[E0308]: mismatched types"))
        XCTAssertFalse(fails("Compiled successfully in 1.2s"))
        XCTAssertFalse(fails("GET /api/errors-page 200"))
    }

    func testAgentProcessNames() {
        XCTAssertTrue(CanvasController.isAgentProcess("claude"))
        XCTAssertTrue(CanvasController.isAgentProcess("2.1.325"))
        XCTAssertFalse(CanvasController.isAgentProcess("zsh"))
        XCTAssertFalse(CanvasController.isAgentProcess("node"))
    }

    func testScrollLatchKeepsGestureOwner() {
        final class V {}
        let canvas = V(), tile = V()
        var latch = ScrollLatch<V>()
        let t0 = Date()
        func ev(_ p: NSEvent.Phase, _ m: NSEvent.Phase = []) -> ScrollLatch<V>.Event { .init(precise: true, phase: p, momentum: m) }
        // Pan starts on the canvas, drifts over a tile, momentum continues over it.
        XCTAssertTrue(latch.owner(for: ev(.began), under: canvas, now: t0) === canvas)
        XCTAssertTrue(latch.owner(for: ev(.changed), under: tile, now: t0) === canvas)
        XCTAssertTrue(latch.owner(for: ev(.ended), under: tile, now: t0) === canvas)
        XCTAssertTrue(latch.owner(for: ev([], .began), under: tile, now: t0) === canvas)
        XCTAssertTrue(latch.owner(for: ev([], .changed), under: tile, now: t0) === canvas)
        XCTAssertTrue(latch.owner(for: ev([], .ended), under: tile, now: t0) === canvas)
        // A new gesture that starts on the tile belongs to the tile.
        XCTAssertTrue(latch.owner(for: ev(.began), under: tile, now: t0) === tile)
        XCTAssertTrue(latch.owner(for: ev(.changed), under: canvas, now: t0) === tile)
        // Mouse wheel: ticks close together stay with the first target; a pause releases it.
        let wheel = ScrollLatch<V>.Event(precise: false, phase: [], momentum: [])
        var w = ScrollLatch<V>()
        XCTAssertTrue(w.owner(for: wheel, under: canvas, now: t0) === canvas)
        XCTAssertTrue(w.owner(for: wheel, under: tile, now: t0.addingTimeInterval(0.1)) === canvas)
        XCTAssertTrue(w.owner(for: wheel, under: tile, now: t0.addingTimeInterval(0.6)) === tile)
    }

    func testImageAttachmentsGoIntoAgentCommands() {
        let img = URL(fileURLWithPath: "/tmp/pw-att/shot.png")
        let prompt = ClaudeIntegration.prompt(task: "fix this", images: [img])
        XCTAssertTrue(prompt.hasPrefix("fix this\n\nAttached image"))
        XCTAssertTrue(prompt.contains("- /tmp/pw-att/shot.png"))
        XCTAssertEqual(ClaudeIntegration.prompt(task: "x", images: []), "x")
        let claude = AgentKind.claude.command(task: "fix this", images: [img]) ?? ""
        XCTAssertTrue(claude.contains("--add-dir '/tmp/pw-att'") || claude.contains("--add-dir /tmp/pw-att"), claude)
        let codex = AgentKind.codex.command(task: "fix this", images: [img]) ?? ""
        XCTAssertTrue(codex.contains("--image"), codex)
        XCTAssertTrue(codex.contains(" -- "), codex)
    }

    func testRelaunchResumesInsteadOfReplayingThePrompt() throws {
        let img = URL(fileURLWithPath: "/tmp/pw-att/shot.png")
        let transcript = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try Data().write(to: transcript)
        defer { try? FileManager.default.removeItem(at: transcript) }
        var t = Tile(kind: .agent, frame: .zero)
        let options = ClaudeIntegration.command(task: nil)

        // Saved before conversations were tracked: pick one.
        t.command = ClaudeIntegration.command(task: "deploy it -- now\nit's urgent")
        XCTAssertEqual(AgentKind.relaunchCommand(for: t), options + " --resume")

        t.claudeSession = "abc-123"
        t.claudeTranscript = transcript.path
        XCTAssertEqual(AgentKind.relaunchCommand(for: t), options + " --resume abc-123")

        // Image folders stay readable; the prompt naming them goes.
        t.command = ClaudeIntegration.command(task: "fix this", images: [img])
        let withImage = try XCTUnwrap(AgentKind.relaunchCommand(for: t))
        XCTAssertTrue(withImage.contains("--add-dir /tmp/pw-att"), withImage)
        XCTAssertFalse(withImage.contains("fix this") || withImage.contains("shot.png"), withImage)

        // A hand-written command that became an agent.
        t.command = "cd web && claude 'fix this'"
        XCTAssertEqual(AgentKind.relaunchCommand(for: t), options + " --resume abc-123")

        t.claudeTranscript = transcript.path + ".gone"
        XCTAssertEqual(AgentKind.relaunchCommand(for: t), options)
    }

    func testOnlyANewTileGetsItsPrompt() throws {
        var t = Tile(kind: .agent, frame: .zero)
        t.command = ClaudeIntegration.command(task: "fix this")
        t.awaitingLaunch = true
        // Deferred until its board opens, possibly after an app restart.
        let saved = try Wire.decoder.decode(Tile.self, from: Wire.encoder.encode(t))
        XCTAssertEqual(AgentKind.launchCommand(for: saved), t.command)
        XCTAssertEqual(Sessions.headlessRequest(for: saved, boardID: "b", size: (80, 24)).script, t.command)

        t.awaitingLaunch = nil
        let resume = ClaudeIntegration.command(task: nil) + " --resume"
        XCTAssertEqual(AgentKind.launchCommand(for: t), resume)
        XCTAssertEqual(Sessions.headlessRequest(for: t, boardID: "b", size: (80, 24)).script, resume)
    }

    func testRelaunchOfOtherTiles() {
        var t = Tile(kind: .agent, frame: .zero)
        t.command = AgentKind.codex.command(task: "fix this")
        XCTAssertEqual(AgentKind.relaunchCommand(for: t), "codex resume")
        t.command = "aider --message 'fix this'"
        XCTAssertNil(AgentKind.relaunchCommand(for: t))
        t.command = nil
        XCTAssertNil(AgentKind.relaunchCommand(for: t))
        for kind in [TileKind.terminal, .logs] {
            t.kind = kind
            t.command = "npm run dev"
            XCTAssertEqual(AgentKind.relaunchCommand(for: t), "npm run dev")
        }
    }

    func testWaitSpecs() {
        XCTAssertEqual(CanvasController.waitSpec(run: "43775328604", pr: nil, command: nil),
                       .init(command: "gh run watch 43775328604 --exit-status --interval 30", label: "CI run 43775328604",
                             runID: "43775328604"))
        let url = CanvasController.waitSpec(run: "https://github.com/acme/web/actions/runs/123/job/9", pr: nil, command: nil)
        XCTAssertEqual(url?.label, "CI run 123")
        XCTAssertEqual(url?.runID, "123")
        XCTAssertEqual(url?.runRepo, "acme/web")
        XCTAssertTrue(url?.command.contains("-R 'acme/web'") == true || url?.command.contains("-R acme/web") == true, url?.command ?? "")
        XCTAssertNil(CanvasController.waitSpec(run: "not-a-run", pr: nil, command: nil))
        XCTAssertEqual(CanvasController.waitSpec(run: nil, pr: "42", command: nil)?.label, "PR #42 checks")
        XCTAssertEqual(CanvasController.waitSpec(run: nil, pr: nil, command: "kubectl rollout status deploy/api")?.command,
                       "kubectl rollout status deploy/api")
        XCTAssertNil(CanvasController.waitSpec(run: "", pr: " ", command: nil))
        // Outside a checkout gh can't guess the repo, so a PR number carries -R.
        XCTAssertEqual(CanvasController.waitSpec(run: nil, pr: "42", command: nil, repo: "acme/web")?.command,
                       "gh pr checks 42 -R acme/web --watch --interval 30")
        XCTAssertFalse(CanvasController.waitSpec(run: nil, pr: "https://github.com/acme/web/pull/42", command: nil, repo: "x/y")?
            .command.contains("-R") ?? true)
    }

    func testGitHubRepoFromRemote() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertNil(Git.githubRepo(dir))
        Git.run(["init", "-q"], in: dir)
        for (url, want) in [("git@github.com:acme/web.git", "acme/web"), ("https://github.com/acme/web", "acme/web"),
                            ("https://github.com/acme/web.git/", "acme/web"), ("https://gitlab.com/acme/web.git", nil)] {
            Git.run(["remote", "remove", "origin"], in: dir)
            Git.run(["remote", "add", "origin", url], in: dir)
            XCTAssertEqual(Git.githubRepo(dir), want, url)
        }
    }

    func testBlockingWaitDetection() {
        let c = "gh run watch 43775328604 --exit-status --interval 30 > /dev/null 2>&1; gh run view 43775328604 --json conclusion"
        XCTAssertEqual(CanvasController.blockingWait(c), "CI run 43775328604")
        XCTAssertEqual(CanvasController.blockingWait("gh pr checks 12 --watch"), "PR checks")
        XCTAssertEqual(CanvasController.blockingWait("kubectl -n x rollout status deploy/api"), "a rollout")
        XCTAssertEqual(CanvasController.blockingWait("until curl -sf localhost:3000; do sleep 2; done"), "a poll loop")
        XCTAssertEqual(CanvasController.blockingWait("sleep 120"), "a 120s timer")
        XCTAssertNil(CanvasController.blockingWait("sleep 1 && npm test"))
        XCTAssertNil(CanvasController.blockingWait("gh pr checks 12"))
        XCTAssertNil(CanvasController.blockingWait("npm run build"))
    }

    func testRunInfoParse() {
        let json = """
        {"databaseId": 7, "displayTitle": "feat: thing", "workflowName": "Deploy", "headBranch": "feat/x",
         "headSha": "abcdef1234", "event": "pull_request", "status": "in_progress", "conclusion": "",
         "url": "https://github.com/acme/web/actions/runs/7", "createdAt": "2026-01-01T00:00:00Z",
         "startedAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:05:00Z", "attempt": 1,
         "jobs": [
          {"databaseId": 1, "name": "build", "status": "completed", "conclusion": "success",
           "startedAt": "2026-01-01T00:00:05Z", "completedAt": "2026-01-01T00:02:05Z", "url": "u", "steps": []},
          {"databaseId": 2, "name": "test", "status": "completed", "conclusion": "failure",
           "startedAt": "2026-01-01T00:00:05Z", "completedAt": "2026-01-01T00:03:00Z", "url": "u",
           "steps": [{"number": 1, "name": "Set up", "status": "completed", "conclusion": "success"},
                     {"number": 2, "name": "Run tests", "status": "completed", "conclusion": "failure"}]},
          {"databaseId": 3, "name": "deploy", "status": "in_progress", "conclusion": "",
           "startedAt": "2026-01-01T00:03:00Z", "completedAt": "0001-01-01T00:00:00Z", "url": "u",
           "steps": [{"number": 1, "name": "Set up", "status": "completed", "conclusion": "success"},
                     {"number": 2, "name": "Push image", "status": "in_progress", "conclusion": ""}]},
          {"databaseId": 4, "name": "unpromote", "status": "completed", "conclusion": "skipped", "steps": []}
         ]}
        """
        guard let r = RunInfo.parse(Data(json.utf8)) else { return XCTFail("didn't parse") }
        XCTAssertFalse(r.completed)
        XCTAssertNil(r.conclusion)
        XCTAssertEqual(r.countedJobs.count, 3)
        XCTAssertEqual(r.progress, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(r.jobs[1].currentStep?.name, "Run tests")
        XCTAssertEqual(r.jobs[2].currentStep?.name, "Push image")
        XCTAssertNil(r.jobs[2].completedAt)
        XCTAssertTrue(r.failureSummary.contains("test: failure at step \"Run tests\""))
        XCTAssertEqual((185.0 as TimeInterval).clock, "3m 05s")
    }

    // MARK: Remote Control

    func testTranscriptReaderBuildsConversation() throws {
        let lines = [
            #"{"type":"bridge-session","sessionId":"s","bridgeSessionId":"cse_01ABC"}"#,
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"Fix the bestLap test"}}"#,
            #"{"type":"user","uuid":"m","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>x</local-command-caveat>"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"npm test\nmore"}}]}}"#,
            #"{"type":"user","uuid":"r1","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","is_error":true,"content":"1 failing"}]}}"#,
            #"{"type":"assistant","uuid":"a2","message":{"content":[{"type":"tool_use","id":"toolu_2","name":"Edit","input":{"file_path":"/x/src/laps.js"}}]}}"#,
            #"{"type":"assistant","uuid":"a3","isSidechain":true,"message":{"content":[{"type":"text","text":"sub-agent chatter"}]}}"#,
            #"{"type":"assistant","uuid":"a4","message":{"content":[{"type":"text","text":"Fixed it."}]}}"#,
            #"{"type":"ai-title","aiTitle":"Fix bestLap","sessionId":"s"}"#,
            #"{"type":"cost-state","totalCostUSD":0.42}"#,
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pw-transcript-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = TranscriptReader(path: url.path)
        XCTAssertTrue(r.read())
        let t = r.transcript
        XCTAssertEqual(t.items, [
            .prompt(id: "u1", text: "Fix the bestLap test"),
            .tool(id: "toolu_1", name: "Bash", summary: "npm test", status: .failed),
            .tool(id: "toolu_2", name: "Edit", summary: "laps.js", status: .running),
            .reply(id: "a4-0", text: "Fixed it."),
        ])
        XCTAssertEqual(t.title, "Fix bestLap")
        XCTAssertEqual(t.cost, 0.42)
        XCTAssertEqual(t.model, "claude-opus-5-5")
        XCTAssertEqual(t.url?.absoluteString, "https://claude.ai/code/session_01ABC")
        XCTAssertFalse(r.read(), "nothing new")
        // Appended lines are picked up incrementally.
        let h = try FileHandle(forWritingTo: url)
        h.seekToEndOfFile()
        h.write(Data((#"{"type":"user","uuid":"r2","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_2"}]}}"# + "\n").utf8))
        try h.close()
        XCTAssertTrue(r.read())
        XCTAssertEqual(r.transcript.items[2], .tool(id: "toolu_2", name: "Edit", summary: "laps.js", status: .ok))
        XCTAssertEqual(RemoteSessionView.modelName("claude-opus-5-5"), "Opus 5.5")
    }

    func testRemoteHostStatusParsing() {
        let connected = """
        Remote Control starts Claude Code sessions in this folder, driven from your other devices:
        ·✔︎· Connected · trackside · main
            Capacity: 2/32 · New sessions will be created in the current directory
        Continue coding in the Claude mobile app or https://claude.ai/code?environment=env_01Ff34a2
        space to show QR code · w to toggle spawn mode
        """
        let s = RemoteHostStatus.parse(connected, shellInForeground: false)
        XCTAssertEqual(s.phase, .connected)
        XCTAssertEqual(s.capacity?.used, 2)
        XCTAssertEqual(s.capacity?.total, 32)
        XCTAssertEqual(s.worktreeSpawn, false)
        XCTAssertEqual(s.environmentURL?.absoluteString, "https://claude.ai/code?environment=env_01Ff34a2")

        let ready = "Remote Control starts Claude Code sessions\n[21:47:39] Session failed: Process exited with error cse_01\n·✔︎· Ready · trackside · main\n    Capacity: 0/32 · New sessions will be created in the current directory"
        XCTAssertEqual(RemoteHostStatus.parse(ready, shellInForeground: false).phase, .connected)
        let later = connected + "\n[21:50:19] Session failed: Process exited with error cse_02"
        XCTAssertEqual(RemoteHostStatus.parse(later, shellInForeground: false).phase, .connected)
        let trust = "Remote Control starts Claude Code sessions in this folder\nTrust /x/repo? [y/N] "
        XCTAssertEqual(RemoteHostStatus.parse(trust, shellInForeground: false).phase, .needsTrust)
        XCTAssertEqual(RemoteHostStatus.parse(connected + "\n% ", shellInForeground: true).phase, .stopped)
        let failed = "Remote Control starts Claude Code sessions\nError: this folder is already being served by another `claude remote-control` instance"
        XCTAssertEqual(RemoteHostStatus.parse(failed, shellInForeground: false).phase, .failed)
    }

    func testRemoteControlDetection() {
        XCTAssertTrue(CanvasController.isRemoteControlCommand(["claude", "rc"]))
        XCTAssertTrue(CanvasController.isRemoteControlCommand(["claude", "remote-control", "--spawn", "worktree"]))
        XCTAssertFalse(CanvasController.isRemoteControlCommand(["claude", "--remote-control"]))
        XCTAssertFalse(CanvasController.isRemoteControlCommand(["claude"]))
        XCTAssertEqual(ProcessArgs.argv(getpid())?.isEmpty, false)
        let choose = "Remote Control starts\n  [1] same-dir\n  [2] worktree\nChoose [1/2] (default: 1): "
        XCTAssertEqual(RemoteHostStatus.parse(choose, shellInForeground: false).phase, .needsSpawnMode)
    }

    func testMarkdownBlocks() {
        let b = MarkdownBlocks.blocks("Done.\n\n- **Bug:** fixed\n  - nested\n1. first\n## Notes\n```\nnpm test\n```\ntail")
        XCTAssertEqual(b, [.para("Done."), .bullet("**Bug:** fixed", 0), .bullet("nested", 1), .numbered("1.", "first"),
                           .heading("Notes"), .code("npm test"), .para("tail")])
    }

    func testSlashFrontmatterFoldedAndQuoted() {
        let md = "---\nname: pr-review\ndescription: >\n  Review a PR\n  strictly.\nargument-hint: \"[id]\"\nuser-invocable: false\n---\nBody"
        let m = SlashCommands.frontmatter(md)
        XCTAssertEqual(m["name"], "pr-review")
        XCTAssertEqual(m["description"], "Review a PR strictly.")
        XCTAssertEqual(m["argument-hint"], "[id]")
        XCTAssertEqual(m["user-invocable"], "false")
        XCTAssertTrue(SlashCommands.frontmatter("no frontmatter").isEmpty)
    }

    func testSlashCommandsLoadProjectUserAndPlugins() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("slash-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        func write(_ path: String, _ text: String) throws {
            let url = home.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write(".claude/skills/spec/SKILL.md", "---\nname: spec\ndescription: User spec\n---\n")
        try write(".claude/skills/hidden/SKILL.md", "---\nuser-invocable: false\n---\n")
        try write(".claude/commands/standup.md", "Write my standup\n")
        try write("code/app/.claude/skills/spec/SKILL.md", "---\ndescription: Project spec\n---\n")
        try write("code/app/.claude/commands/deploy.md", "---\ndescription: Ship it\n---\n")
        let plugin = home.appendingPathComponent("plugins/notion")
        try write("plugins/notion/.claude-plugin/plugin.json", #"{"name": "Notion"}"#)
        try write("plugins/notion/commands/find.md", "---\ndescription: Find pages\nargument-hint: query\n---\n")
        try write("plugins/notion/commands/tasks/build.md", "---\ndescription: Build\n---\n")
        try write("plugins/off/skills/x/SKILL.md", "---\ndescription: Disabled\n---\n")
        try write(".claude/plugins/installed_plugins.json", """
            {"version": 2, "plugins": {"notion@m": [{"installPath": "\(plugin.path)"}],
             "off@m": [{"installPath": "\(home.appendingPathComponent("plugins/off").path)"}]}}
            """)
        try write(".claude/settings.json", #"{"enabledPlugins": {"notion@m": true, "off@m": true}}"#)
        try write("code/app/.claude/settings.json", #"{"enabledPlugins": {"off@m": false}}"#)

        let all = SlashCommands.load(repo: home.appendingPathComponent("code/app").path, home: home)
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        XCTAssertEqual(byName["spec"]?.description, "Project spec") // project shadows user
        XCTAssertEqual(byName["spec"]?.source, .project)
        XCTAssertEqual(byName["deploy"]?.source, .project)
        XCTAssertEqual(byName["standup"]?.description, "Write my standup")
        XCTAssertNil(byName["hidden"])
        XCTAssertEqual(byName["Notion:find"]?.argumentHint, "query")
        XCTAssertEqual(byName["Notion:tasks:build"]?.source, .plugin("Notion"))
        XCTAssertNil(byName["off:x"])
        XCTAssertNotNil(byName["init"])

        XCTAssertEqual(SlashCommands.matches("fi", in: all).first?.name, "Notion:find")
        XCTAssertEqual(SlashCommands.matches("dep", in: all).first?.name, "deploy")
        XCTAssertEqual(SlashCommands.matches("", in: all).first?.source, .project)
    }

    // MARK: Portals

    private func portalFixture() -> (api: Board, web: Board, a: Tile, w: Tile, shell: Tile) {
        var api = Board(name: "api", root: "/r/api")
        var web = Board(name: "web", root: "/r/web")
        var a = Tile(kind: .agent, frame: CGRect(x: 0, y: 0, width: 726, height: 506)); a.name = "Api agent"; a.cwd = "/r/api"
        var w = Tile(kind: .agent, frame: CGRect(x: 0, y: 0, width: 726, height: 506)); w.name = "Web agent"; w.cwd = "/r/web"; w.branch = "main"
        let shell = Tile(kind: .terminal, frame: CGRect(x: 800, y: 0, width: 682, height: 462))
        a.cwd = "/r/api"
        api.tiles = [a]
        web.tiles = [w, shell]
        return (api, web, a, w, shell)
    }

    func testPortalRoundTripsThroughJSON() throws {
        let p = Portal(a: PortalEnd(boardID: "b-1", tileID: "t-1"), b: PortalEnd(boardID: "b-2", tileID: "t-2"), openedBy: "agent", task: "x")
        let back = try Wire.decoder.decode(Portal.self, from: Wire.encoder.encode(p))
        XCTAssertEqual(back.id, p.id)
        XCTAssertEqual(back.key, ["t-1", "t-2"])
        // Older/minimal files: only the required fields.
        let minimal = #"{"id":"p-1","a":{"boardID":"b-1","tileID":"t-1"},"b":{"boardID":"b-2","tileID":"t-2"},"createdAt":"2026-11-19T15:00:00Z"}"#
        let m = try Wire.decoder.decode(Portal.self, from: Data(minimal.utf8))
        XCTAssertNil(m.task)
        XCTAssertEqual(m.other("t-1")?.tileID, "t-2")
        XCTAssertNil(m.other("t-9"))
    }

    func testPortalsPrunedDropsMissingTilesAndBoards() {
        let f = portalFixture()
        let good = Portal(a: PortalEnd(boardID: "stale", tileID: f.w.id), b: PortalEnd(boardID: f.api.id, tileID: f.a.id),
                          createdAt: Date(timeIntervalSince1970: 1))
        let dup = Portal(a: PortalEnd(boardID: f.api.id, tileID: f.a.id), b: PortalEnd(boardID: f.web.id, tileID: f.w.id),
                         createdAt: Date(timeIntervalSince1970: 2))
        let missing = Portal(a: PortalEnd(boardID: f.web.id, tileID: f.w.id), b: PortalEnd(boardID: "gone", tileID: "t-gone"))
        let sameBoard = Portal(a: PortalEnd(boardID: f.web.id, tileID: f.w.id), b: PortalEnd(boardID: f.web.id, tileID: f.shell.id))
        let out = Portals.pruned([dup, missing, good, sameBoard], boards: [f.api, f.web])
        XCTAssertEqual(out.map(\.id), [good.id], "keeps the oldest of a duplicate pair, drops missing and same-board")
        XCTAssertEqual(out.first?.a.boardID, f.web.id, "refreshes the board id cache")
    }

    func testPortalRouteResolvesLinksThenPortals() {
        var f = portalFixture()
        let p = Portal(a: PortalEnd(boardID: f.web.id, tileID: f.w.id), b: PortalEnd(boardID: f.api.id, tileID: f.a.id))
        XCTAssertEqual(Portals.route(from: f.w.id, to: f.a.id, boards: [f.api, f.web], portals: [p]), .portal(p))
        XCTAssertEqual(Portals.route(from: f.a.id, to: f.w.id, boards: [f.api, f.web], portals: [p]), .portal(p))
        XCTAssertNil(Portals.route(from: f.shell.id, to: f.a.id, boards: [f.api, f.web], portals: [p]))
        let l = Link(from: f.w.id, to: f.shell.id, kind: .manual)
        f.web.links = [l]
        XCTAssertEqual(Portals.route(from: f.w.id, to: f.shell.id, boards: [f.api, f.web], portals: [p]), .link(l, f.web))
    }

    func testPortalPeersListsOtherSideWithBoard() {
        let f = portalFixture()
        let p = Portal(a: PortalEnd(boardID: f.web.id, tileID: f.w.id), b: PortalEnd(boardID: f.api.id, tileID: f.a.id))
        let peers = Portals.peers(of: f.w.id, boards: [f.api, f.web], portals: [p])
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers.first?.tile.id, f.a.id)
        XCTAssertEqual(peers.first?.board.name, "api")
        XCTAssertTrue(Portals.peers(of: f.shell.id, boards: [f.api, f.web], portals: [p]).isEmpty)
    }

    func testPortalValidate() {
        let f = portalFixture()
        let boards = [f.api, f.web]
        func v(_ src: String, _ board: String, task: String? = "do it", existing: String? = nil, by: OpenedBy = .agent,
               enabled: Bool = true, recent: [Date] = [], portals: [Portal] = [], extra: [Board] = []) -> Result<Portals.Plan, PortalError> {
            Portals.validate(source: src, board: board, task: task, existing: existing, by: by, boards: boards + extra, portals: portals,
                             hooked: [], agentPortalsEnabled: enabled, recentOpens: recent, now: Date())
        }
        func err(_ r: Result<Portals.Plan, PortalError>) -> String? { if case .failure(let e) = r { return e.message }; return nil }
        XCTAssertEqual(err(v(f.shell.id, "api")), "tile \(f.shell.displayName) isn't an agent")
        XCTAssertEqual(err(v(f.w.id, "nope")), "no board named nope")
        XCTAssertTrue(err(v(f.w.id, "api", extra: [Board(name: "API", root: "/old")]))?.hasPrefix("several boards are named api") ?? false)
        XCTAssertEqual(err(v(f.w.id, "web")), "that's this tile's own board; use a link instead")
        XCTAssertEqual(err(v(f.w.id, "api", enabled: false)), "portals from agents are turned off in Pitwall Settings")
        XCTAssertNil(err(v(f.w.id, "api", by: .user, enabled: false)), "the menu works with the toggle off")
        let now = Date()
        XCTAssertNotNil(err(v(f.w.id, "api", recent: [now, now, now])))
        XCTAssertNil(err(v(f.w.id, "api", recent: [now, now])))
        XCTAssertNil(err(v(f.w.id, "api", recent: [now, now, now.addingTimeInterval(-700)])), "old opens expire")
        XCTAssertNil(err(v(f.w.id, "api", by: .user, recent: [now, now, now])), "the user isn't rate limited")
        XCTAssertEqual(err(v(f.w.id, "api", existing: f.shell.id)), "tile \(f.shell.id) isn't an agent on board api")
        XCTAssertEqual(err(v(f.w.id, "api", task: "  ")), "task required to start a new agent")
        guard case .success(.spawn(_, _, let target, let task)) = v(f.w.id, f.api.id) else { return XCTFail("spawn by board id") }
        XCTAssertEqual(target.id, f.api.id)
        XCTAssertEqual(task, "do it")
        let p = Portal(a: PortalEnd(boardID: f.web.id, tileID: f.w.id), b: PortalEnd(boardID: f.api.id, tileID: f.a.id))
        guard case .success(.connect(_, _, _, let tile, let t2, let existing)) = v(f.w.id, "api", task: nil, existing: f.a.id, portals: [p]) else {
            return XCTFail("connect")
        }
        XCTAssertEqual(tile.id, f.a.id)
        XCTAssertNil(t2)
        XCTAssertEqual(existing, p)
    }

    func testPortalBoardLookup() {
        let a = Board(name: "API", root: "/a"), b = Board(name: "web", root: "/b")
        XCTAssertEqual(try? Portals.board("api", in: [a, b]).get().id, a.id)
        XCTAssertEqual(try? Portals.board(b.id, in: [a, b]).get().id, b.id)
        XCTAssertNil(try? Portals.board("x", in: [a, b]).get())
    }

    func testPortalSpotStartAndFreeSpot() {
        var b = Board(name: "x", root: nil)
        b.viewport = Viewport(origin: CGPoint(x: 100, y: 200), zoom: 0.5)
        let size = CGSize(width: 726, height: 506)
        let s = Portals.spotStart(on: b, viewSize: CGSize(width: 1000, height: 800), size: size)
        // Visible world: 2000 × 1600 from (100, 200); its center is (1100, 1000).
        XCTAssertEqual(s, CGPoint(x: 1100 - 363, y: 1000 - 253))
        b.tiles = [Tile(kind: .agent, frame: CGRect(origin: s, size: size))]
        let free = CanvasController.freeSpot(in: b, size: size, near: s)
        XCTAssertFalse(CGRect(origin: free, size: size).intersects(b.tiles[0].frame))
    }

    func testPortalAgentPromptHasMarkerAndReplyInstructions() {
        let f = portalFixture()
        let p = Portals.agentPrompt(source: f.w, sourceBoard: f.web, target: f.api, cwd: "/r/api/.worktrees/pw-x", branch: "pw/x", task: "Add /v2/orders")
        XCTAssertTrue(p.hasPrefix(Portals.promptMarker))
        XCTAssertTrue(p.contains(f.w.id))
        XCTAssertTrue(p.contains("\"web\"") && p.contains("\"api\""))
        XCTAssertTrue(p.contains("send_message"))
        XCTAssertTrue(p.contains("branch pw/x"))
        XCTAssertTrue(p.contains("Task: Add /v2/orders"))
    }

    func testHeadlessRequestCarriesSurfaceEnv() {
        var t = Tile(kind: .agent, frame: .zero)
        t.cwd = "/tmp"
        t.command = "claude -- hi"
        t.sessionID = "s-1"
        t.awaitingLaunch = true
        let r = Sessions.headlessRequest(for: t, boardID: "b-9", size: (100, 30))
        XCTAssertEqual(r.op, .attach)
        XCTAssertEqual(r.id, "s-1")
        XCTAssertEqual(r.script, "claude -- hi")
        XCTAssertEqual(r.cwd, "/tmp")
        XCTAssertEqual(r.env?[PitwallEnv.tileID], t.id)
        XCTAssertEqual(r.env?[PitwallEnv.boardID], "b-9")
        XCTAssertNotNil(r.env?[PitwallEnv.appSocket])
        XCTAssertNotNil(r.env?[PitwallEnv.helper])
        XCTAssertNotNil(r.env?["TERM"])
        XCTAssertNil(r.env?["GHOSTTY_SHELL_FEATURES"])
        XCTAssertEqual(Sessions.headlessEnv(tileID: "t", boardID: "b", base: [:])["LANG"], "en_US.UTF-8")
        XCTAssertEqual(Sessions.headlessEnv(tileID: "t", boardID: "b", base: ["LANG": "de_DE.UTF-8"])["LANG"], "de_DE.UTF-8")
    }

    func testKeyBytesMatchNamedKeys() {
        for k in TerminalSurfaceView.namedKeys.keys { XCTAssertNotNil(Sessions.keyBytes[k], k) }
        let chunks = Sessions.textChunks("ls\necho hi")
        XCTAssertEqual(chunks.map { String(decoding: $0.0, as: UTF8.self) }, ["\u{1B}[200~ls\u{1B}[201~", "\r", "\u{1B}[200~echo hi\u{1B}[201~"])
    }

    func testPortalContextIsBounded() {
        var boards: [Board] = []
        var portals: [Portal] = []
        var me = Board(name: "me", root: "/me")
        let mine = Tile(kind: .agent, frame: .zero)
        me.tiles = [mine]
        boards.append(me)
        for i in 0..<8 {
            var b = Board(name: "board-\(i)", root: "/r/\(i)")
            var t = Tile(kind: .agent, frame: .zero); t.name = String(repeating: "x", count: 60)
            b.tiles = [t]
            boards.append(b)
            portals.append(Portal(a: PortalEnd(boardID: me.id, tileID: mine.id), b: PortalEnd(boardID: b.id, tileID: t.id)))
        }
        let c = Portals.context(for: mine.id, boards: boards, portals: portals)
        XCTAssertNotNil(c)
        XCTAssertLessThanOrEqual(c!.count, 600)
        XCTAssertNil(Portals.context(for: "t-none", boards: boards, portals: portals))
    }
}
