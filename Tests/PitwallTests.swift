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
}
