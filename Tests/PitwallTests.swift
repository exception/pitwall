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
}
