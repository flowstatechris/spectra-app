// Regression test for the "player did not see an IO cycle" crash: tapping a
// push notification resumes the app from background, and the first RPC
// event (message.complete/approval.request/clarify.request) tried to play a
// UI cue on an AVAudioEngine whose IO had been torn down.
//
// Fix #1 (superseded) gated play() on `engine.isRunning` — wrong, because
// iOS can leave that reporting true across a background/foreground cycle
// even though real hardware IO never resumed, so the crash recurred.
//
// Fix #2 (superseded) added an own `isWarm` flag, true only via a one-shot
// `installTap` confirming a genuine render callback — correct for plain
// backgrounding, but still crashed when the user was on a FaceTime call:
// an AVAudioSession interruption from a call can happen while the app stays
// foregrounded the whole time, so no background/foreground transition ever
// fired to invalidate isWarm, AND activating our session mid-call glitched
// the call's own audio.
//
// Fix #3 (current) adds AVAudioSession.interruptionNotification handling
// (interruptions aren't tied to app lifecycle) and shouldStayQuiet() —
// Apple's secondaryAudioShouldBeSilencedHint — which skips everything,
// including ever attempting engine.start(), for the whole duration a call/
// Siri/alarm owns the audio session, not just around its edges.

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

    func test_playSkipsWhileSomethingElseOwnsAudioEvenIfWarm() {
        let cue = Cuelume.shared
        cue.isEnabled = true
        defer {
            cue.isEnabled = false
            cue._test_shouldStayQuietOverride = nil
        }

        cue._test_forceWarm() // simulate "already warm from before the call started"
        cue._test_shouldStayQuietOverride = true // simulate an active FaceTime call

        XCTAssertFalse(cue.play(.arrival), "must not fight a call for the audio session, even while warm")
    }

    func test_startAndConfirmWarmNeverTouchesEngineWhileSomethingElseOwnsAudio() {
        let cue = Cuelume.shared
        defer { cue._test_shouldStayQuietOverride = nil }

        cue._test_invalidateWarm()
        cue._test_shouldStayQuietOverride = true

        // Direct call — this is what willEnterForeground/.interruption-ended
        // call on their own, independent of play(). Would normally call
        // engine.start(), which implicitly reactivates the audio session —
        // exactly what must NOT happen while a call owns it (the
        // call-audio-glitch half of this bug, distinct from the crash half).
        cue._test_triggerWarmUp()

        // Give any (wrongly) scheduled warm-up a moment, then confirm it
        // never happened.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(cue._test_isWarm, "must not warm up while shouldStayQuiet() is true")
    }
}
