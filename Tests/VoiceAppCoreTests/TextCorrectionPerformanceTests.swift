import Foundation
import VoiceAppCore
import XCTest

final class TextCorrectionPerformanceTests: XCTestCase {
    func testDictationLatency() throws {
        guard ProcessInfo.processInfo.environment["VOICEAPP_BENCHMARK"] == "1" else {
            throw XCTSkip("Run with VOICEAPP_BENCHMARK=1 swift test -c release --filter TextCorrectionPerformanceTests")
        }
        let paragraph = """
            Please send the release notes to the team after the morning review. We used chat GPT pro to draft
            the summary and Voice app to dictate the remaining comments. The support team checked Tail scale
            before opening the customer workspace. Tomorrow we should review the onboarding instructions,
            confirm the keyboard shortcuts, and make sure the documentation describes the current workflow.
            Keep the existing recordings until everyone has checked the transcript and signed off on the update.
            The project is on schedule, although the network configuration still needs another careful review.
            """.split(whereSeparator: \.isWhitespace).map(String.init)
        for count in [100, 500] {
            let terms = dictionary(count: count)
            for words in [40, 300] {
                for capped in [false, true] {
                    var corpus = (0..<words).map { paragraph[$0 % paragraph.count] }
                    if capped { corpus.replaceSubrange(0..<4, with: ["saffron", "cobalt", "rivet", "rivet"]) }
                    let input = corpus.joined(separator: " ")
                    for _ in 0..<3 { _ = correctText(input, terms: terms) }
                    var times: [Double] = []
                    for _ in 0..<21 {
                        let start = ContinuousClock.now
                        let result = correctText(input, terms: terms)
                        let elapsed = start.duration(to: .now).components
                        times.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
                        XCTAssertEqual(result.converged, !capped)
                        if !capped { XCTAssertTrue(result.text.contains("ChatGPT Pro")) }
                    }
                    print("DICTIONARY BENCH terms=\(count) aliases=2 words=\(words) mode=\(capped ? "eight-pass" : "fixed-point") median_ms=\(String(format: "%.3f", times.sorted()[10]))")
                }
            }
        }
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
