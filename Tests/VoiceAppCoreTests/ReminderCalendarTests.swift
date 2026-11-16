import Foundation
import UserNotifications
import XCTest
@testable import VoiceAppCore

@MainActor
final class ReminderCalendarTests: XCTestCase {
    func testCalendarTriggersKeepSpringForwardAndBothFallBackInstants() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let formatter = ISO8601DateFormatter()
        for text in ["2027-03-14T06:30:00Z", "2027-03-14T07:30:00Z",
                     "2027-11-07T05:30:00Z", "2027-11-07T06:30:00Z"] {
            let due = try XCTUnwrap(formatter.date(from: text))
            let request = SystemNoteNotificationCenter.request(for: NoteNotification(noteID: UUID(), text: "DST", date: due), timeZone: zone)
            let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
            XCTAssertFalse(trigger.repeats)
            XCTAssertEqual(trigger.nextTriggerDate(), due, text)
            XCTAssertEqual(trigger.dateComponents.timeZone?.secondsFromGMT(for: due), zone.secondsFromGMT(for: due))
            let moved = SystemNoteNotificationCenter.calendarTrigger(for: due, timeZone: TimeZone(identifier: "Europe/Berlin")!)
            XCTAssertEqual(moved.nextTriggerDate(), due, "Time zone changes preserve the stored due instant")
        }
    }

    func testTimeZoneChangeReschedulesWithoutRequestingPermission() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ReminderZone-\(UUID())")
        let name = "ReminderZone.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let events = NotificationCenter()
        let fake = FakeNotifications()
        let due = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970) + 86_400)
        let history = DictationHistory(repository: SQLiteHistoryRepository(directory: directory),
            notifications: fake, notificationEvents: events, defaults: defaults)
        let note = CompletedDictation(rawText: "zone", finalText: "zone", appBundleID: nil, appName: nil,
            modelID: "test", durationSeconds: 1)
        await history.deliver(note, destination: .note) { _ in XCTFail() }
        await history.pendingSave?.value
        await history.remindNote(id: note.id, date: due).value
        fake.added = []
        let rescheduled = expectation(description: "time zone change replaced the pending request")
        fake.onAdd = { _ in rescheduled.fulfill() }
        events.post(name: .NSSystemTimeZoneDidChange, object: nil)
        await fulfillment(of: [rescheduled], timeout: 2)
        await history.pendingSave?.value
        XCTAssertEqual(fake.added.map(\.date), [due])
        XCTAssertEqual(fake.accessRequests, 0)
    }
}
