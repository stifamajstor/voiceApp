import Foundation
import VoiceAppCore
import XCTest

/// The scanner must read the process as it is. If production code ever writes the process time zone or the
/// `AppleLanguages` default again, even only for the length of a scan, these tests fail: they watch both from a
/// second thread while a long scan runs, and compare them before and after.
final class SystemDateScannerGlobalStateTests: XCTestCase {
    private typealias Support = NoteTestSupport

    private typealias Snapshot = ProcessSettings.Snapshot

    /// Half a second or more of detector work: about 0.5 s per 20,000 digit-heavy characters.
    private static let longText = "Call Anna tomorrow at 9 " + String(repeating: "1234567890 ", count: 2_000)

    /// Runs `scan` on this thread while another thread reads the settings in a loop. Returns every distinct state
    /// the sampler saw.
    private func settingsSeenDuring(_ scan: () -> Void) -> (seen: [Snapshot], samples: Int) {
        let lock = NSLock()
        nonisolated(unsafe) var seen: [Snapshot] = []
        nonisolated(unsafe) var samples = 0
        nonisolated(unsafe) var finished = false
        let started = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let sampler = Thread {
            started.signal()
            while true {
                let snapshot = Snapshot.take()
                lock.lock()
                samples += 1
                if !seen.contains(snapshot) { seen.append(snapshot) }
                let done = finished
                lock.unlock()
                if done { break }
            }
            stopped.signal()
        }
        sampler.start()
        started.wait()
        scan()
        lock.lock(); finished = true; lock.unlock()
        stopped.wait()
        lock.lock(); defer { lock.unlock() }
        return (seen, samples)
    }

    /// A zone whose offset differs from the process zone's, so that asking for it is a real mismatch.
    private func zoneOtherThanTheProcess() -> TimeZone {
        let now = Date()
        let offset = NSTimeZone.default.secondsFromGMT(for: now)
        return [Support.berlin, Support.losAngeles, Support.auckland].first { $0.secondsFromGMT(for: now) != offset }!
    }

    func testAScanInTheProcessZoneChangesNothingWhileItRuns() throws {
        let zone = NSTimeZone.default
        let now = try Support.nowAwayFromMidnight(in: zone)
        nonisolated(unsafe) var clockReads = 0
        let scanner = SystemDateScanner(clock: { clockReads += 1; return Date() })
        let before = Snapshot.take()

        let (seen, samples) = settingsSeenDuring {
            _ = scanner.scan(Self.longText, reference: now, timeZone: zone)
        }

        XCTAssertEqual(clockReads, 2, "the detector did not run, so this scan proves nothing")
        XCTAssertGreaterThan(samples, 10)
        XCTAssertEqual(seen, [before])
        XCTAssertEqual(Snapshot.take(), before)
    }

    func testAScanAskedForAnotherZoneChangesNothingEither() throws {
        let process = NSTimeZone.default
        let now = try Support.nowAwayFromMidnight(in: process)
        let other = zoneOtherThanTheProcess()
        let scanner = SystemDateScanner()
        let before = Snapshot.take()

        let (seen, _) = settingsSeenDuring {
            XCTAssertEqual(scanner.scan(Self.longText, reference: now, timeZone: other), [])
        }

        XCTAssertEqual(seen, [before])
        XCTAssertEqual(Snapshot.take(), before)
    }
}
