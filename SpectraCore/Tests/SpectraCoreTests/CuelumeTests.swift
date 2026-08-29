// Regression test for the "player did not see an IO cycle" crash: tapping a
// push notification resumes the app from background, and the first RPC
// event (message.complete/approval.request/clarify.request) tried to play a
// UI cue on an AVAudioEngine whose IO had been torn down while backgrounded.
//
// First fix attempt (superseded) gated play() on `engine.isRunning` — wrong,
// because iOS can leave that reporting true across a background/foreground
// cycle even though real hardware IO never resumed, so the crash recurred.
// The fix now tracks its own `isWarm` flag, set true only by a one-shot
// `installTap` confirming a genuine render callback actually happened.

import XCTest
@testable import SpectraCore

final class CuelumeTests: XCTestCase {
    func test_playSkipsWhileColdEvenIfEngineReportsRunning() {
        let cue = Cuelume.shared
        cue.isEnabled = true // ponytail: init() disables under XCTest; re-enable for this test
        defer { cue.isEnabled = false }

        // Reproduces exactly what broke fix #1: go cold without stopping
        // the engine, so engine.isRunning stays true throughout.
        cue._test_invalidateWarm()
        XCTAssertFalse(cue._test_isWarm)

        let playedWhileCold = cue.play(.scan)
        XCTAssertFalse(playedWhileCold, "must skip while isWarm is false, regardless of engine.isRunning")

        // The warm-up that skipped play() kicked off confirms asynchronously
        // (real IO render callback → dispatch to main) — poll for it rather
        // than assume a fixed delay is enough on every machine.
        let deadline = Date().addingTimeInterval(2)
        while !cue._test_isWarm && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(cue._test_isWarm, "engine should confirm warm within 2s of a real start")

        XCTAssertTrue(cue.play(.scan), "now warm — this cue should actually play")
    }

    func test_disabledNeverPlaysRegardlessOfWarmState() {
        let cue = Cuelume.shared
        cue.isEnabled = false
        XCTAssertFalse(cue.play(.arrival))
    }
}
