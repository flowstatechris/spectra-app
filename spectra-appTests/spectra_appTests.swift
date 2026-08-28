//
//  spectra_appTests.swift
//  spectra-appTests
//
//  Created by Chris Victorin on 8/26/26.
//

import Testing
import SpectraCore
@testable import spectra_app

private func status(_ text: String) -> Message {
    Message(role: .agent, text: text, kind: .status)
}
private func plain(_ text: String) -> Message {
    Message(role: .agent, text: text)
}

struct ThreadItemsTests {

    /// Adjacent status lines collapse into one run; only a run with nothing
    /// after it is live (shimmers).
    @Test func groupsAdjacentStatusLinesAndMarksOnlyTheTrailingRunLive() {
        let items = threadItems([
            Message(role: .user, text: "what's on my calendar?"),
            status("Loading your September calendar now."),
            status("gws isn't in PATH."),
            tool("read"),
            status("Pulling September"),
        ])

        #expect(items.count == 4)

        guard case .statusRun(_, let firstRun, let firstLive) = items[1] else {
            Issue.record("expected the two adjacent status lines to fold into a run")
            return
        }
        #expect(firstRun.count == 2)
        #expect(firstLive == false)   // the tool row superseded it → collapses

        guard case .statusRun(_, let lastRun, let lastLive) = items[3] else {
            Issue.record("expected a trailing status run")
            return
        }
        #expect(lastRun.count == 1)
        #expect(lastLive == true)     // nothing after it → shimmers
    }

    /// Composition guard: pinning the answer to the end of the turn means a
    /// status run is no longer trailing, so it stops shimmering and the answer
    /// row is the only live surface. One shimmer per turn, not two.
    @Test func pinnedAnswerLeavesNoLiveStatusRun() {
        let items = threadItems([
            Message(role: .user, text: "flights?"),
            plain("Here are your flights."),
            status("Still working"),
        ])

        #expect(items.count == 3)
        guard case .statusRun(_, _, let live) = items[1] else {
            Issue.record("expected the status run to sit above the pinned answer")
            return
        }
        #expect(live == false)
        guard case .message(let last) = items[2] else {
            Issue.record("expected the answer pinned last")
            return
        }
        #expect(last.text == "Here are your flights.")
    }

    @Test func nonStatusMessagesPassThroughUngrouped() {
        let items = threadItems([Message(role: .user, text: "hi"), plain("hello")])
        #expect(items.count == 2)
        if case .statusRun = items[0] { Issue.record("plain messages must not group") }
    }

    @Test func emptyThreadProducesNoItems() {
        #expect(threadItems([]).isEmpty)
    }
}

private func tool(_ name: String) -> Message {
    Message(id: "tool:\(name)", role: .agent, text: "",
            kind: .toolActivity(ToolActivity(id: name, toolName: name, status: .succeeded)))
}

struct PinAnswersTests {

    /// The reported bug: the answer is written into the slot of its first token,
    /// so the tools that produced it end up below it.
    @Test func answerMovesBelowTheToolsThatRanAfterIt() {
        let out = pinAnswersToTurnEnd([
            Message(role: .user, text: "search flights BOS to HND"),
            plain("BOS → HND: best offer is CX at $8,602."),
            tool("soar_search_flights"),
            tool("command"),
        ])

        #expect(out.map(\.id).last == out.first(where: { $0.role == .agent && $0.kind == .plain })?.id)
        #expect(out[1].id == "tool:soar_search_flights")   // tools keep their order
        #expect(out[2].id == "tool:command")
    }

    /// Narration that introduces a tool must stay above it — only the turn's
    /// last agent message is the "answer".
    @Test func earlierNarrationStaysAboveItsTools() {
        let narration = plain("Loading the flight skill first:")
        let answer = plain("Here are your flights.")
        let out = pinAnswersToTurnEnd([
            Message(role: .user, text: "flights?"),
            narration,
            tool("skill_view"),
            answer,
        ])

        #expect(out.map(\.id) == [out[0].id, narration.id, "tool:skill_view", answer.id])
    }

    /// Each turn is pinned independently; an earlier turn must not reshuffle
    /// when a new prompt arrives.
    @Test func pinsPerTurnNotAcrossTheWholeThread() {
        let firstAnswer = plain("first answer")
        let secondAnswer = plain("second answer")
        let out = pinAnswersToTurnEnd([
            Message(role: .user, text: "one"),
            firstAnswer,
            tool("a"),
            Message(role: .user, text: "two"),
            secondAnswer,
            tool("b"),
        ])

        #expect(out.map(\.id) == [out[0].id, "tool:a", firstAnswer.id,
                                 out[3].id, "tool:b", secondAnswer.id])
    }

    @Test func aTurnWithNoToolsIsLeftAlone() {
        let answer = plain("hi")
        let input = [Message(role: .user, text: "hello"), answer]
        #expect(pinAnswersToTurnEnd(input).map(\.id) == input.map(\.id))
    }
}
