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

    // MARK: Board agent

    func testBoardAgentDropsAsksFromOutsideItsLists() {
        var cfg = BoardAgentConfig()
        let ask = AgentAsk(source: "slack", from: "@Alice", channel: "#Bugs", text: "fix login")
        XCTAssertNotNil(BoardAgent.rejection(ask, config: cfg), "slack asks need a watched channel")
        cfg.slack.channels = ["bugs"]
        XCTAssertNil(BoardAgent.rejection(ask, config: cfg))
        cfg.slack.allowedUsers = ["bob"]
        XCTAssertNotNil(BoardAgent.rejection(ask, config: cfg))
        cfg.slack.allowedUsers = ["alice", "bob"]
        XCTAssertNil(BoardAgent.rejection(ask, config: cfg))
        XCTAssertNotNil(BoardAgent.rejection(AgentAsk(source: "cli", from: "alice", text: "  "), config: cfg))
        // CLI asks ignore the channel list (it's for Slack) but not the allowlist.
        XCTAssertNil(BoardAgent.rejection(AgentAsk(source: "cli", from: "bob", channel: "random", text: "x"), config: cfg))
        XCTAssertNotNil(BoardAgent.rejection(AgentAsk(source: "cli", from: "eve", text: "x"), config: cfg))
    }

    func testBoardAgentTaskFramesTheAskAsSomeoneElses() {
        var cfg = BoardAgentConfig()
        cfg.instructions = "Never touch billing."
        let t = BoardAgent.task(for: AgentAsk(source: "slack", from: "alice", channel: "#bugs", text: "login 500s"), config: cfg)
        XCTAssertTrue(t.hasPrefix("login 500s\n\n(Asked by alice in #bugs.)"))
        XCTAssertTrue(t.contains("Never touch billing."))
        XCTAssertTrue(t.contains("not from the user"))
    }

    func testBoardAgentStateAndTrim() {
        var w = Tile(kind: .agent, frame: .zero)
        w.state = .working
        var a = AgentAsk(source: "cli", from: "a", text: "x")
        XCTAssertEqual(BoardAgent.state(asks: [a], tiles: []), .waiting)
        a.state = .pickedUp
        a.workerTileID = w.id
        XCTAssertEqual(BoardAgent.state(asks: [a], tiles: [w]), .working)
        XCTAssertEqual(BoardAgent.state(asks: [], tiles: [w]), .idle)
        let many = (0..<50).map { i -> AgentAsk in
            var q = AgentAsk(source: "cli", from: "a", text: "\(i)"); q.state = .ignored; q.at = Date(timeIntervalSince1970: Double(i)); return q
        } + [AgentAsk(source: "cli", from: "a", text: "new")]
        let kept = BoardAgent.trimmed(many)
        XCTAssertEqual(kept.count, BoardAgent.keepHandled + 1)
        XCTAssertTrue(kept.contains { $0.text == "new" })
        XCTAssertFalse(kept.contains { $0.text == "0" })
        XCTAssertEqual(BoardAgent.list("#a, b  c\n"), ["#a", "b", "c"])
    }

    func testOldBoardsDecodeWithoutAnAgent() throws {
        let json = #"{"id":"b-1","name":"x","colorIndex":0,"tiles":[],"links":[],"frames":[],"viewport":{"origin":[0,0],"zoom":1}}"#
        let b = try Wire.decoder.decode(Board.self, from: Data(json.utf8))
        XCTAssertNil(b.agent)
        XCTAssertEqual(b.agentConfig.name, "Pit")
        var c = b
        c.agent = BoardAgentConfig(name: "Scout")
        c.asks = [AgentAsk(source: "cli", from: "a", text: "x")]
        let back = try Wire.decoder.decode(Board.self, from: Wire.encoder.encode(c))
        XCTAssertEqual(back.agent?.name, "Scout")
        XCTAssertEqual(back.asks?.count, 1)
    }

    func testSlackCheckParsesStructuredOutput() throws {
        let out = """
        Last login: Mon
        {"type":"result","is_error":false,"result":"","structured_output":{"workspace":"Motordil","asks":[{"from":"Ana","channel":"dm","via":"dm","title":"flujo de tarjeta","text":"can you look at the card flow?\\nalso the retry","link":"https://x.slack.com/archives/D1/p1","ts":["1.2","1.3"]},{"from":"Bo","channel":"bugs","via":"channel","title":"500s","text":"500s","ts":["3.4"],"link":"javascript:alert(1)","continues":"q-abc"}]}}
        """
        let r = try BoardAgent.parseCheck(Data(out.utf8))
        XCTAssertEqual(r.workspace, "Motordil")
        XCTAssertEqual(r.asks.map(\.from), ["Ana", "Bo"])
        XCTAssertNil(r.asks[0].channel, "DMs have no channel")
        XCTAssertNil(r.asks[1].link, "only https links are kept")
        XCTAssertEqual(r.keys, [["Ana:1.2", "Ana:1.3"], ["Bo:3.4"]])
        XCTAssertEqual(r.asks[0].count, 2)
        XCTAssertEqual(r.asks[0].title, "flujo de tarjeta")
        XCTAssertEqual(r.continues, [nil, "q-abc"])
        XCTAssertThrowsError(try BoardAgent.parseCheck(Data(#"{"type":"result","is_error":true,"result":"Not logged in"}"#.utf8)))
        XCTAssertThrowsError(try BoardAgent.parseCheck(Data("zsh: command not found: claude".utf8)))
    }

    func testSlackAsksMustArriveAWayTheBoardListens() {
        var cfg = BoardAgentConfig()
        cfg.slack.directMessages = false
        XCTAssertNotNil(BoardAgent.rejection(AgentAsk(source: "slack", from: "a", via: "dm", text: "x"), config: cfg))
        XCTAssertNil(BoardAgent.rejection(AgentAsk(source: "slack", from: "a", channel: "random", via: "mention", text: "x"), config: cfg))
        XCTAssertNotNil(BoardAgent.rejection(AgentAsk(source: "slack", from: "a", channel: "random", via: "channel", text: "x"), config: cfg))
        let p = BoardAgent.checkPrompt(cfg.slack, since: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertFalse(p.contains("Direct messages"))
        XCTAssertTrue(p.contains("Unix 1800000000"))
        XCTAssertTrue(BoardAgent.checkTools(.boardSignIn).filter { $0 != "Skill" }.allSatisfy { $0.hasPrefix("mcp__slack__slack_read") || $0.hasPrefix("mcp__slack__slack_search") })
        XCTAssertFalse(BoardAgent.checkTools(.claudeConnector).contains { $0.contains("send") || $0.contains("reaction") })
    }

    func testBoardAgentNeverActsWithoutAsking() throws {
        XCTAssertEqual(PermissionLevel.allCases, [.off, .ask])
        let old = #"{"pickUpTasks":"auto","replyAsMe":"auto","reactAsMe":"off","setMyStatus":"ask"}"#
        let p = try Wire.decoder.decode(AgentPermissions.self, from: Data(old.utf8))
        XCTAssertEqual(p.pickUpTasks, .ask)
        XCTAssertEqual(p.replyAsMe, .ask)
        XCTAssertEqual(p.reactAsMe, .off)
        XCTAssertTrue(BoardAgent.checkTools(.claudeConnector).contains("Skill"))
        let t = BoardAgent.task(for: AgentAsk(source: "slack", from: "a", title: "Tarjeta", text: "x\ny", count: 2), config: BoardAgentConfig())
        XCTAssertTrue(t.hasPrefix("Tarjeta\n\nx\ny\n\n(Asked by a, 2 messages.)"))
        XCTAssertTrue(t.contains("skills"))
        let open = [AgentAsk(id: "q-1", source: "slack", from: "Ana", title: "flujo de tarjeta", text: "...")]
        XCTAssertTrue(BoardAgent.checkPrompt(SlackWatch(), since: Date(), open: open).contains("q-1: Ana: flujo de tarjeta"))
    }
}

