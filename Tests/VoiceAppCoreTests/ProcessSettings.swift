import Foundation
import XCTest

/// Test support for the tests that need the real `NSDataDetector` to behave as on another machine. The detector
/// reads the process time zone and the preferred languages, so these tests switch both for the length of one
/// closure. This lives in the test target on purpose: production code must never write them (see
/// SystemDateScannerGlobalStateTests).
enum ProcessSettings {
    /// What the detector reads, as the process has it right now.
    struct Snapshot: Equatable, CustomStringConvertible {
        let timeZone: String
        let argumentLanguages: [String]?
        let storedLanguages: [String]?
        let preferredLanguages: [String]

        static func take() -> Snapshot {
            let defaults = UserDefaults.standard
            return Snapshot(
                timeZone: NSTimeZone.default.identifier,
                argumentLanguages: defaults.volatileDomain(forName: UserDefaults.argumentDomain)["AppleLanguages"] as? [String],
                storedLanguages: defaults.array(forKey: "AppleLanguages") as? [String],
                preferredLanguages: Locale.preferredLanguages)
        }

        var description: String {
            "zone \(timeZone), argument languages \(argumentLanguages ?? []), stored languages \(storedLanguages ?? []), preferred \(preferredLanguages)"
        }
    }

    /// Recursive so a test may nest calls. XCTest runs the tests of one process one after another; the lock only
    /// stops two switches from overlapping if that ever changes.
    private static let lock = NSRecursiveLock()

    /// Runs `body` with the process time zone and/or preferred languages (BCP 47, such as "de-DE") replaced,
    /// then puts back what was there, also when `body` throws.
    static func with<T>(timeZone: TimeZone? = nil, languages: [String]? = nil, _ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        let defaults = UserDefaults.standard
        let previousZone = NSTimeZone.default
        let previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            NSTimeZone.default = previousZone
            defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
        }
        if let timeZone { NSTimeZone.default = timeZone }
        if let languages {
            var arguments = previousArguments
            arguments["AppleLanguages"] = languages
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        return try body()
    }

    /// The detector as a user in `timeZone` with a single preferred language `localeID` ("de_DE") would have it.
    static func asUser<T>(in timeZone: TimeZone, speaking localeID: String = "en_US", _ body: () throws -> T) rethrows -> T {
        try with(timeZone: timeZone, languages: [Locale(identifier: localeID).identifier(.bcp47)], body)
    }
}

/// Base class for tests that switch process settings: fails the test that leaves them changed, so a leak is
/// reported where it happens and cannot reach the tests that run after it.
class ProcessSettingsTestCase: XCTestCase {
    private var settingsAtStart: ProcessSettings.Snapshot?

    override func setUp() {
        super.setUp()
        settingsAtStart = ProcessSettings.Snapshot.take()
    }

    override func tearDown() {
        XCTAssertEqual(ProcessSettings.Snapshot.take(), settingsAtStart, "the test left process settings changed")
        super.tearDown()
    }
}
