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

    // MARK: tool runs

    /// The whole point: a turn that fires several tools is one collapsible
    /// group, not one row per call.
    @Test func groupsAdjacentToolRowsIntoOneRun() {
        let items = threadItems([
            Message(role: .user, text: "flights?"),
            tool("skill_view"),
            tool("soar_flights"),
            tool("soar_flights_2"),
        ])

        #expect(items.count == 2)
        guard case .toolRun(_, let activities, let live) = items[1] else {
            Issue.record("expected the three tool rows to fold into one run")
            return
        }
        #expect(activities.count == 3)
        #expect(live == true)     // nothing after it → the turn is still going
    }

    /// Status narration and tool receipts fold in parallel, never into each
    /// other — the model keeps them distinct and so does the thread.
    @Test func statusAndToolRunsStaySeparate() {
        let items = threadItems([
            Message(role: .user, text: "flights?"),
            status("Loading the flight skill"),
            tool("skill_view"),
            tool("soar_flights"),
            status("Comparing fares"),
        ])

        #expect(items.count == 4)
        guard case .statusRun(_, let opening, _) = items[1] else {
            Issue.record("expected the opening narration to stay a status run")
            return
        }
        #expect(opening.count == 1)
        guard case .toolRun(_, let tools, let toolsLive) = items[2] else {
            Issue.record("expected the two tools to fold between the narration")
            return
        }
        #expect(tools.count == 2)
        #expect(toolsLive == false)   // the later status line superseded it
        guard case .statusRun(_, _, let closingLive) = items[3] else {
            Issue.record("expected a trailing status run")
            return
        }
        #expect(closingLive == true)
    }

    /// Any other kind closes both runs, so tools either side of an approval
    /// don't collapse across it.
    @Test func anApprovalBreaksASurroundingToolRun() {
        let request = ApprovalRequest(sessionID: "s", payload: [
            "request_id": "a1", "command": "rm -rf /", "choices": ["once", "deny"],
        ])!
        let items = threadItems([
            Message(role: .user, text: "clean up"),
            tool("read"),
            Message(role: .agent, text: "", kind: .approval(ApprovalEvent(request: request))),
            tool("write"),
        ])

        #expect(items.count == 4)
        guard case .toolRun(_, let before, _) = items[1],
              case .message = items[2],
              case .toolRun(_, let after, _) = items[3] else {
            Issue.record("expected the approval to split the tool rows into two runs")
            return
        }
        #expect(before.count == 1)
        #expect(after.count == 1)
    }

    /// Same composition guard as the status case: with the answer pinned last,
    /// a finished turn's tool run is no longer trailing, so it settles.
    @Test func pinnedAnswerLeavesNoLiveToolRun() {
        let items = threadItems([
            Message(role: .user, text: "flights?"),
            plain("Here are your flights."),
            tool("soar_flights"),
        ])

        #expect(items.count == 3)
        guard case .toolRun(_, _, let live) = items[1] else {
            Issue.record("expected the tool run above the pinned answer")
            return
        }
        #expect(live == false)
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
