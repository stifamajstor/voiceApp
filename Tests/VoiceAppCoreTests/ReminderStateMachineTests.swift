import Foundation
import XCTest
@testable import VoiceAppCore

/// The transition table, checked cell by cell against a second table written out by hand, and the
/// planner that turns states into notification-center work.
final class ReminderStateMachineTests: XCTestCase {
    private let due = Date(timeIntervalSince1970: 1_900_000_000)
    private let other = Date(timeIntervalSince1970: 1_900_003_600)

    private enum Column: String, CaseIterable { case idle, scheduled, handed, missed, alerted }

    private func state(_ column: Column) -> ReminderState {
        switch column {
        case .idle: return .idle
        case .scheduled: return .scheduled(dueAt: due)
        case .handed: return .handedToMacOS(dueAt: due)
        case .missed: return .missed(dueAt: due)
        case .alerted: return .alerted(dueAt: due)
        }
    }

    /// Result tokens: `idle`, `S` scheduled, `H` handed, `M` missed, `A` alerted, all for `due`; `S'` is scheduled for `other`.
    private func result(_ token: String) -> ReminderState {
        switch token {
        case "idle": return .idle
        case "S": return .scheduled(dueAt: due)
        case "S'": return .scheduled(dueAt: other)
        case "H": return .handedToMacOS(dueAt: due)
        case "M": return .missed(dueAt: due)
        case "A": return .alerted(dueAt: due)
        default: preconditionFailure(token)
        }
    }

    /// Every event variant against every state: 17 rows of 5 results. Columns: idle, scheduled, handed, missed, alerted.
    private var table: [(name: String, event: ReminderEvent, results: String)] {[
        ("set(other)",               .set(other),                         "S' S' S' S' S'"),
        ("set(same due time)",      .set(due),                           "S  S  S  S  S"),
        ("remove",                  .remove,                             "idle idle idle idle idle"),
        ("done",                    .done,                               "idle idle idle idle idle"),
        ("delete",                  .delete,                             "idle idle idle idle idle"),
        ("edit",                    .edit,                               "idle S H M A"),
        ("timeReached(before due)", .timeReached(due.addingTimeInterval(-1)), "idle S H M A"),
        ("timeReached(at due)",     .timeReached(due),                   "idle M A M A"),
        ("timeReached(after due)",  .timeReached(due.addingTimeInterval(1)), "idle M A M A"),
        ("requestAdded(due)",       .requestAdded(due),                  "idle H H M A"),
        ("requestAdded(other)",     .requestAdded(other),                "idle S H M A"),
        ("requestWithdrawn(due)",   .requestWithdrawn(due),              "idle S S M A"),
        ("requestWithdrawn(other)", .requestWithdrawn(other),            "idle S H M A"),
        ("delivered(due)",          .delivered(due),                     "idle A A A A"),
        ("delivered(other)",        .delivered(other),                   "idle S H M A"),
        ("catchUpPosted(due)",      .catchUpPosted(due),                 "idle S H A A"),
        ("catchUpPosted(other)",    .catchUpPosted(other),               "idle S H M A"),
    ]}

    func testTransitionTableMatchesTheHandWrittenTableForEveryStateAndEvent() {
        var checked = 0
        for row in table {
            let expected = row.results.split(separator: " ").map { result(String($0)) }
            XCTAssertEqual(expected.count, Column.allCases.count, row.name)
            for (column, want) in zip(Column.allCases, expected) {
                XCTAssertEqual(ReminderStateMachine.next(state(column), row.event), want,
                               "\(column.rawValue) on \(row.name)")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 17 * 5)
    }

    func testTheTableCoversEveryEventKind() {
        // A new event case must get rows here: this switch stops compiling until it is handled.
        func kind(_ event: ReminderEvent) -> String {
            switch event {
            case .set: return "set"
            case .remove: return "remove"
            case .done: return "done"
            case .delete: return "delete"
            case .edit: return "edit"
            case .timeReached: return "timeReached"
            case .requestAdded: return "requestAdded"
            case .requestWithdrawn: return "requestWithdrawn"
            case .delivered: return "delivered"
            case .catchUpPosted: return "catchUpPosted"
            }
        }
        XCTAssertEqual(Set(table.map { kind($0.event) }).count, 10)
    }

    func testAnAlertedDueTimeLeavesThatStateOnlyThroughSetOrRemoval() {
        let alerted = ReminderState.alerted(dueAt: due)
        for row in table {
            let next = ReminderStateMachine.next(alerted, row.event)
            switch row.event {
            case .set(let date): XCTAssertEqual(next, .scheduled(dueAt: date))
            case .remove, .done, .delete: XCTAssertEqual(next, .idle)
            default: XCTAssertEqual(next, alerted, "\(row.name) must not bring an alerted due time back")
            }
        }
    }

    func testClockMovingBackNeverUndoesAPassedDueTime() {
        for column in [Column.missed, .alerted] {
            let before = state(column)
            XCTAssertEqual(ReminderStateMachine.next(before, .timeReached(due.addingTimeInterval(-86_400))), before)
        }
    }

    func testEveryStateMatchesItsDueTimeToTheMillisecondOnly() {
        let nearlySame = due.addingTimeInterval(0.0004)
        XCTAssertEqual(ReminderStateMachine.next(.scheduled(dueAt: due), .requestAdded(nearlySame)), .handedToMacOS(dueAt: due))
        XCTAssertEqual(ReminderStateMachine.next(.scheduled(dueAt: due), .requestAdded(due.addingTimeInterval(0.002))), .scheduled(dueAt: due))
    }

    func testTheSavedFormRoundTripsEveryState() {
        for column in Column.allCases {
            let value = state(column)
            XCTAssertEqual(ReminderState(dueAt: value.dueAt, phase: value.phase), value, column.rawValue)
        }
        XCTAssertEqual(ReminderState.idle.phase, nil)
        XCTAssertEqual(ReminderState(dueAt: due, phase: nil), .scheduled(dueAt: due), "a due time with no phase is handed over again, never skipped")
        XCTAssertEqual(ReminderState(dueAt: due, phase: "garbage"), .scheduled(dueAt: due))
        XCTAssertEqual(ReminderState(dueAt: nil, phase: "alerted"), .idle)
    }

    func testAFullLifeOfOneReminderEndToEnd() {
        var state = ReminderState.idle
        for (event, expected) in [
            (ReminderEvent.set(due), ReminderState.scheduled(dueAt: due)),
            (.requestAdded(due), .handedToMacOS(dueAt: due)),
            (.edit, .handedToMacOS(dueAt: due)),
            (.requestWithdrawn(due), .scheduled(dueAt: due)),
            (.requestAdded(due), .handedToMacOS(dueAt: due)),
            (.timeReached(due), .alerted(dueAt: due)),
            (.timeReached(due.addingTimeInterval(-60)), .alerted(dueAt: due)),
            (.requestAdded(due), .alerted(dueAt: due)),
            (.set(due), .scheduled(dueAt: due)),
            (.timeReached(due), .missed(dueAt: due)),
            (.timeReached(due.addingTimeInterval(60)), .missed(dueAt: due)),
            (.catchUpPosted(due), .alerted(dueAt: due)),
            (.done, .idle),
        ] {
            state = ReminderStateMachine.next(state, event)
            XCTAssertEqual(state, expected, "after \(event)")
        }
    }

    // MARK: Identifiers

    func testDeliveryIdentifiersCarryTheirDueTimeAndOlderOnesDoNot() {
        let id = UUID()
        let identifier = NoteNotification.identifier(for: id, due: due)
        XCTAssertEqual(NoteNotification.dueDate(for: identifier).map(ReminderState.key), ReminderState.key(due))
        XCTAssertNil(NoteNotification.dueDate(for: "voice-note.\(id.uuidString)"), "built before due times were part of the identifier")
        XCTAssertNil(NoteNotification.dueDate(for: NoteNotification.summaryIdentifier))
        XCTAssertNil(NoteNotification.dueDate(for: "voice-note.not-a-uuid.123"))
        XCTAssertNil(NoteNotification.dueDate(for: "other.\(id.uuidString).123"))
    }

    // MARK: Planner

    private func plan(_ states: [UUID: ReminderState], now: Date? = nil, authorized: Bool = true, limit: Int = 60,
                      pending: Set<String> = [], resubmit: ReminderResubmit = .none) -> ReminderPlan {
        ReminderPlan.make(states, now: now ?? due.addingTimeInterval(-3600), authorized: authorized, limit: limit,
                          pending: pending, resubmit: resubmit)
    }

    private func ids(_ count: Int) -> [UUID] {
        // Ascending identifiers so ties order predictably.
        (0..<count).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
    }

    func testPlannerHandsOverScheduledRemindersAndLeavesHandedOnesThatMacOSStillHolds() {
        let id = ids(3)
        let pending: Set<String> = [NoteNotification.identifier(for: id[1], due: due)]
        let states: [UUID: ReminderState] = [id[0]: .scheduled(dueAt: due), id[1]: .handedToMacOS(dueAt: due), id[2]: .handedToMacOS(dueAt: due)]
        let result = plan(states, pending: pending)
        XCTAssertEqual(result.hand, [id[0], id[2]], "id[0] was never handed over; id[2] was lost from macOS")
        XCTAssertEqual(result.withdraw, [])
        XCTAssertEqual(plan(states, pending: pending, resubmit: .notes([id[1]])).hand, [id[0], id[1], id[2]])
        XCTAssertEqual(plan(states, pending: pending, resubmit: .all).hand, [id[0], id[1], id[2]])
    }

    func testPlannerNeverSchedulesOrWakesForAnAlertedReminderEvenWithAFutureDueTime() {
        let id = ids(2)
        let states: [UUID: ReminderState] = [id[0]: .alerted(dueAt: due), id[1]: .scheduled(dueAt: other)]
        let result = plan(states)
        XCTAssertEqual(result.hand, [id[1]])
        XCTAssertEqual(result.nextWake, other, "the alerted one is not what the timer waits for")
        XCTAssertEqual(plan([id[0]: .alerted(dueAt: due)], resubmit: .all), ReminderPlan())
    }

    func testPlannerKeepsTheNearestRemindersInTheWindowAndWithdrawsHandedOnesBeyondIt() {
        let id = ids(5)
        var states: [UUID: ReminderState] = [:]
        for (index, note) in id.enumerated() { states[note] = .scheduled(dueAt: due.addingTimeInterval(Double(index) * 60)) }
        states[id[3]] = .handedToMacOS(dueAt: due.addingTimeInterval(180))
        states[id[4]] = .handedToMacOS(dueAt: due.addingTimeInterval(240))
        let pending = Set([id[3], id[4]].map { NoteNotification.identifier(for: $0, due: states[$0]!.dueAt) })
        let result = plan(states, limit: 3, pending: pending)
        XCTAssertEqual(result.hand, [id[0], id[1], id[2]])
        XCTAssertEqual(result.withdraw, [id[3], id[4]])
        XCTAssertEqual(plan(states, authorized: false, limit: 3, pending: pending).withdraw, [id[3], id[4]],
                       "taking a request back needs no permission")
    }

    func testPlannerOrdersEqualDueTimesByIdentifierSoTheWindowIsStable() {
        let id = ids(4)
        let states = Dictionary(uniqueKeysWithValues: id.map { ($0, ReminderState.scheduled(dueAt: due)) })
        XCTAssertEqual(plan(states, limit: 2).hand, [id[0], id[1]])
    }

    func testPlannerWithNotificationsOffAddsAndAlertsNothingButStillNamesTheNextWake() {
        let id = ids(3)
        let states: [UUID: ReminderState] = [id[0]: .scheduled(dueAt: other), id[1]: .handedToMacOS(dueAt: due), id[2]: .missed(dueAt: due)]
        let result = plan(states, authorized: false)
        XCTAssertEqual(result.hand, [])
        XCTAssertEqual(result.catchUp, [])
        XCTAssertEqual(result.nextWake, due)
        XCTAssertEqual(plan(states, authorized: true).catchUp, [id[2]])
    }

    func testPlannerWakesAtTheEarliestDueTimeOfAReminderThatIsNotAlertedYet() {
        let id = ids(4)
        XCTAssertNil(plan([id[0]: .idle, id[1]: .missed(dueAt: due), id[2]: .alerted(dueAt: other)]).nextWake)
        XCTAssertEqual(plan([id[0]: .scheduled(dueAt: other), id[1]: .handedToMacOS(dueAt: due), id[2]: .alerted(dueAt: due.addingTimeInterval(-60))]).nextWake, due)
        XCTAssertNil(plan([id[0]: .scheduled(dueAt: due)], now: due).nextWake, "a due time already reached is for timeReached, not for the timer")
    }

    func testPlannerListsMissedRemindersInDueOrder() {
        let id = ids(3)
        let states: [UUID: ReminderState] = [id[0]: .missed(dueAt: other), id[1]: .missed(dueAt: due), id[2]: .missed(dueAt: due)]
        XCTAssertEqual(plan(states).catchUp, [id[1], id[2], id[0]])
    }
}
