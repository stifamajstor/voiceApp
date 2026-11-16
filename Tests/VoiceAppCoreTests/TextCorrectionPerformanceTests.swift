import Foundation
import VoiceAppCore
import XCTest

final class TextCorrectionPerformanceTests: XCTestCase {
    func testDictationLatency() throws {
        guard ProcessInfo.processInfo.environment["VOICEAPP_BENCHMARK"] == "1" else {
            throw XCTSkip("Run with VOICEAPP_BENCHMARK=1 swift test -c release --filter TextCorrectionPerformanceTests")
        }
        for count in [100, 500] {
            let terms = dictionary(count: count)
            for words in [40, 300] {
                for capped in [false, true] {
                    var corpus = (0..<words).map { paragraph[$0 % paragraph.count] }
                    if capped { corpus.replaceSubrange(0..<4, with: ["saffron", "cobalt", "rivet", "rivet"]) }
                    let input = corpus.joined(separator: " ")
                    let matcher = CorrectionMatcher(terms: terms)
                    for _ in 0..<3 {
                        _ = correctText(input, terms: terms)
                        _ = matcher.correct(input)
                    }
                    var times: [Double] = []
                    var reusedTimes: [Double] = []
                    for _ in 0..<21 {
                        let start = ContinuousClock.now
                        let result = correctText(input, terms: terms)
                        let elapsed = start.duration(to: .now).components
                        times.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
                        XCTAssertEqual(result.converged, !capped)
                        if !capped { XCTAssertTrue(result.text.contains("ChatGPT Pro")) }

                        let reusedStart = ContinuousClock.now
                        let reusedResult = matcher.correct(input)
                        let reusedElapsed = reusedStart.duration(to: .now).components
                        reusedTimes.append(Double(reusedElapsed.seconds) * 1_000 + Double(reusedElapsed.attoseconds) / 1e15)
                        XCTAssertEqual(reusedResult, result)
                    }
                    print("DICTIONARY BENCH terms=\(count) aliases=2 words=\(words) mode=\(capped ? "eight-pass" : "fixed-point") rebuild_median_ms=\(String(format: "%.3f", times.sorted()[10])) rebuild_worst_ms=\(String(format: "%.3f", times.max() ?? 0)) reused_median_ms=\(String(format: "%.3f", reusedTimes.sorted()[10])) reused_worst_ms=\(String(format: "%.3f", reusedTimes.max() ?? 0))")
                }
            }
        }
        let terms500 = dictionary(count: 500)
        let matcher500 = CorrectionMatcher(terms: terms500)
        let longInput = (0..<1_200).map { paragraph[$0 % paragraph.count] }.joined(separator: " ")
        for _ in 0..<3 { _ = matcher500.correct(longInput) }
        var longTimes: [Double] = []
        for _ in 0..<21 {
            let start = ContinuousClock.now
            let result = matcher500.correct(longInput)
            let elapsed = start.duration(to: .now).components
            longTimes.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
            XCTAssertTrue(result.converged)
        }
        print("DICTIONARY BENCH REUSED terms=500 aliases=2 words=1200 mode=fixed-point reused_median_ms=\(String(format: "%.3f", longTimes.sorted()[10])) reused_worst_ms=\(String(format: "%.3f", longTimes.max() ?? 0))")

        let terms2000 = dictionary(count: 2_000)
        let matcher2000 = CorrectionMatcher(terms: terms2000)
        let input300 = (0..<300).map { paragraph[$0 % paragraph.count] }.joined(separator: " ")
        for _ in 0..<3 { _ = matcher2000.correct(input300) }
        var times2000: [Double] = []
        for _ in 0..<21 {
            let start = ContinuousClock.now
            let result = matcher2000.correct(input300)
            let elapsed = start.duration(to: .now).components
            times2000.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
            XCTAssertTrue(result.converged)
            XCTAssertFalse(result.timedOut)
        }
        print("DICTIONARY BENCH REUSED terms=2000 aliases=2 words=300 mode=fixed-point reused_median_ms=\(String(format: "%.3f", times2000.sorted()[10])) reused_worst_ms=\(String(format: "%.3f", times2000.max() ?? 0))")

        // Pathological case 1: legacy oversized term ("lorem " * 1000 + "ipsum" <- "the") skipped by matcher.
        let loremTerm = DictionaryTerm(text: String(repeating: "lorem ", count: 1_000) + "ipsum", aliases: ["the"], deviceID: UUID())
        let loremMatcher = CorrectionMatcher(terms: [loremTerm])
        let loremStart = ContinuousClock.now
        let loremResult = loremMatcher.correct(input300)
        let loremElapsed = loremStart.duration(to: .now).components
        let loremMs = Double(loremElapsed.seconds) * 1_000 + Double(loremElapsed.attoseconds) / 1e15
        XCTAssertEqual(loremResult.text, input300)
        XCTAssertFalse(loremResult.timedOut)
        print("DICTIONARY BENCH PATHOLOGICAL lorem_x1000 ms=\(String(format: "%.3f", loremMs)) output_chars=\(loremResult.text.count)")

        // Pathological case 2: a fixed 50 ms CPU override still discards multi-pass growth on expiry.
        let chainTerms = [
            DictionaryTerm(text: "c a a", aliases: ["a"], deviceID: UUID()),
            DictionaryTerm(text: "a a c b", aliases: ["a c c a"], deviceID: UUID()),
            DictionaryTerm(text: "b c c c", aliases: ["c a a c"], deviceID: UUID()),
        ]
        let chainMatcher = CorrectionMatcher(terms: chainTerms)
        let chainInput = String(repeating: "c b a a ", count: 2_000)
        let chainStart = ContinuousClock.now
        let chainResult = chainMatcher.correct(chainInput, timeBudget: .milliseconds(50))
        let chainElapsed = chainStart.duration(to: .now).components
        let chainMs = Double(chainElapsed.seconds) * 1_000 + Double(chainElapsed.attoseconds) / 1e15
        XCTAssertEqual(chainResult.text, chainInput)
        XCTAssertTrue(chainResult.timedOut)
        print("DICTIONARY BENCH PATHOLOGICAL chain_2000x_cbaa ms=\(String(format: "%.3f", chainMs)) timedOut=\(chainResult.timedOut) output_chars=\(chainResult.text.count)")
    }

    private let paragraph = """
            Please send the release notes to the team after the morning review. We used chat GPT pro to draft
            the summary and Voice app to dictate the remaining comments. The support team checked Tail scale
            before opening the customer workspace. Tomorrow we should review the onboarding instructions,
            confirm the keyboard shortcuts, and make sure the documentation describes the current workflow.
            Keep the existing recordings until everyone has checked the transcript and signed off on the update.
            The project is on schedule, although the network configuration still needs another careful review.
            """.split(whereSeparator: \.isWhitespace).map(String.init)

    func testNestedCandidateWorkIsBounded() throws {
        guard ProcessInfo.processInfo.environment["VOICEAPP_BENCHMARK"] == "1" else {
            throw XCTSkip("Set VOICEAPP_BENCHMARK=1 for release timing checks")
        }
        let terms = (1...50).map { count in
            DictionaryTerm(text: Array(repeating: "a", count: count).joined(separator: " "),
                aliases: count == 50 ? ["b"] : [], deviceID: UUID())
        }
        let matcher = CorrectionMatcher(terms: terms)
        let input = Array(repeating: "b", count: 200).joined(separator: " ")
        var times: [Double] = []
        for _ in 0..<21 {
            let start = ContinuousClock.now
            let result = matcher.correct(input)
            let elapsed = start.duration(to: .now)
            times.append(milliseconds(elapsed))
            XCTAssertLessThan(elapsed, .milliseconds(250))
            XCTAssertTrue(result.timedOut)
            XCTAssertEqual(result.text, input)
            XCTAssertEqual(result.replacements, [])
        }
        print("DICTIONARY NESTED words=200 median_ms=\(times.sorted()[10]) max_ms=\(times.max()!)")
    }

    func testFiveMinuteDictationUnderTwentyBusyProcesses() throws {
        guard ProcessInfo.processInfo.environment["VOICEAPP_DICTIONARY_LOAD"] == "1" else {
            throw XCTSkip("Set VOICEAPP_DICTIONARY_LOAD=1 for the 20-process release load test")
        }
        let matcher = CorrectionMatcher(terms: dictionary(count: 2_000))
        let input = (0..<1_000).map { paragraph[$0 % paragraph.count] }.joined(separator: " ")
        let expected = matcher.correct(input, timeBudget: nil)
        XCTAssertTrue(expected.converged)
        XCTAssertFalse(expected.replacements.isEmpty)
        var workers: [Process] = []
        defer {
            for worker in workers { worker.terminate() }
            for worker in workers { worker.waitUntilExit() }
        }
        for _ in 0..<20 {
            let worker = Process()
            worker.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
            worker.standardOutput = FileHandle.nullDevice
            worker.standardError = FileHandle.nullDevice
            try worker.run()
            workers.append(worker)
        }
        Thread.sleep(forTimeInterval: 1)
        var timeouts = 0
        var times: [Double] = []
        for _ in 0..<60 {
            let start = ContinuousClock.now
            let result = matcher.correct(input)
            times.append(milliseconds(start.duration(to: .now)))
            if result.timedOut { timeouts += 1 }
            XCTAssertEqual(result.text, expected.text)
            XCTAssertEqual(result.replacements, expected.replacements)
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(timeouts, 0)
        print("DICTIONARY LOAD terms=2000 words=1000 processes=20 cores=\(ProcessInfo.processInfo.processorCount) timeouts=\(timeouts)/60 p50_ms=\(times.sorted()[30]) max_ms=\(times.max()!)")
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private func dictionary(count: Int) -> [DictionaryTerm] {
        let values: [(String, [String])] = [
            ("ChatGPT", ["chat GPT", "chat gee pee tee"]), ("ChatGPT Pro", ["chat pro", "GPT professional"]),
            ("VoiceApp", ["Voice app", "voice application"]), ("Tailscale", ["Tail scale", "tails kale"]),
            ("saffron rivet rivet", ["rivet", "rivet product"]),
            ("rivet rivet saffron cobalt", ["rivet saffron saffron rivet", "saffron platform"]),
            ("cobalt saffron saffron saffron", ["saffron rivet rivet saffron", "cobalt platform"]),
        ]
        var terms = values.map { DictionaryTerm(text: $0.0, aliases: $0.1, deviceID: UUID()) }
        let brands = ["Harbor", "Copper", "Meadow", "Silver", "Cedar", "Maple", "Summit", "Orchard", "River", "Falcon"]
        let products = ["Cloud", "Studio", "Desk", "Flow", "Bridge", "Pilot", "Canvas", "Portal", "Monitor", "Archive"]
        for index in terms.count..<count {
            let brand = brands[index % brands.count]
            let product = products[(index / brands.count) % products.count]
            let version = index / 100 + 1
            terms.append(DictionaryTerm(text: "\(brand)\(product) \(version)",
                aliases: ["\(brand) \(product) \(version)", "\(brand) \(product) version \(version)"], deviceID: UUID()))
        }
        return terms
    }
}
