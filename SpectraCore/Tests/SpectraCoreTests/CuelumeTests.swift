// Regression test for the "player did not see an IO cycle" crash: tapping a
// push notification resumes the app from background, and the first RPC
// event (message.complete/approval.request/clarify.request) tried to play a
// UI cue on an AVAudioEngine that had been torn down while backgrounded.
// Cuelume.play() called AVAudioPlayerNode.play() in the same tick as
// restarting the engine, before any IO cycle — an uncaught NSException that
// crashed the whole app. See Cuelume.swift's play() doc comment for the fix.

import XCTest
@testable import SpectraCore

final class CuelumeTests: XCTestCase {
    func test_playOnStoppedEngineSkipsInsteadOfCrashing() {
        let cue = Cuelume.shared
        cue.isEnabled = true // ponytail: init() disables under XCTest; re-enable for this test
        defer { cue.isEnabled = false }

        cue._test_stopEngine()
        XCTAssertFalse(cue._test_engineIsRunning)

        // This is the exact call shape that crashed: play() right after the
        // engine stops. Reaching this assertion at all (not a process crash)
        // is half the regression coverage; the return value covers the rest.
        let playedWhileCold = cue.play(.scan)
        XCTAssertFalse(playedWhileCold, "must skip the play, not call node.play() on a cold engine")
        XCTAssertTrue(cue._test_engineIsRunning, "play() should still (re)start the engine for next time")

        let playedWhileWarm = cue.play(.scan)
        XCTAssertTrue(playedWhileWarm, "engine is warm now — this cue should actually play")
    }

    func test_disabledNeverPlaysRegardlessOfEngineState() {
        let cue = Cuelume.shared
        cue.isEnabled = false
        XCTAssertFalse(cue.play(.arrival))
    }
}
