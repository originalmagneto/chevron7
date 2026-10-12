// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import CoreGraphics
import os
@testable import Chevron7Kit

/// The on-device model answers one request at a time: four pages asking at once
/// took 7 to 9 s per crop against 2.5 s in a row (Mac Studio, 2026-10-12), so
/// queued crops ran into the 8 s limit. These tests pin the serialized path.
final class FoundationModelGateTests: XCTestCase {
    private static let answer = FoundationJudgement(isSecurityElement: true, kind: .stamp,
                                                    descriptionSK: "", confidence: 0.9)

    /// Records how many judge calls run at once.
    private final class InFlightJudge: FoundationJudging, @unchecked Sendable {
        let delay: Double
        private let state = OSAllocatedUnfairLock(initialState: (current: 0, peak: 0, calls: 0))
        init(delay: Double) { self.delay = delay }
        var peak: Int { state.withLock { $0.peak } }
        var calls: Int { state.withLock { $0.calls } }

        func judge(crop: CGImage, hint: SecurityElement.Kind?, context: String) async throws -> FoundationJudgement {
            state.withLock { $0.current += 1; $0.calls += 1; $0.peak = max($0.peak, $0.current) }
            defer { state.withLock { $0.current -= 1 } }
            try await Task.sleep(for: .seconds(delay))
            return FoundationModelGateTests.answer
        }
    }

    /// Never observes cancellation and blocks for `seconds`, like a wedged model call.
    private struct StubbornJudge: FoundationJudging {
        let seconds: Double
        func judge(crop: CGImage, hint: SecurityElement.Kind?, context: String) async throws -> FoundationJudgement {
            let start = Date()
            while Date().timeIntervalSince(start) < seconds { /* spin */ }
            return FoundationModelGateTests.answer
        }
    }

    private struct FailingJudge: FoundationJudging {
        struct Refused: Error {}
        func judge(crop: CGImage, hint: SecurityElement.Kind?, context: String) async throws -> FoundationJudgement {
            throw Refused()
        }
    }

    private func blankImage() throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func classifyConcurrently(_ classifier: any ElementClassifying, times: Int,
                                      image: CGImage) async -> [ElementJudgement?] {
        await withTaskGroup(of: ElementJudgement?.self) { group in
            for _ in 0..<times {
                group.addTask { try? await classifier.classify(crop: image, hint: nil) }
            }
            var results: [ElementJudgement?] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    func testConcurrentCallsReachTheModelOneAtATime() async throws {
        let judge = InFlightJudge(delay: 0.05)
        let classifier = FoundationModelClassifier(judge: judge, timeoutSeconds: 5)
        let results = await classifyConcurrently(classifier, times: 4, image: try blankImage())
        XCTAssertEqual(judge.calls, 4)
        XCTAssertEqual(judge.peak, 1, "Model musí dostať naraz iba jednu otázku")
        XCTAssertTrue(results.allSatisfy { $0?.isUnsure == false })
    }

    func testTimeQueuedForTheModelDoesNotCountAgainstTheLimit() async throws {
        // Each answer takes 0.3 s; four in a row need 1.2 s, well over the 0.5 s
        // limit, yet none of them is slower than the limit once it has the model.
        let judge = InFlightJudge(delay: 0.3)
        let classifier = FoundationModelClassifier(judge: judge, timeoutSeconds: 0.5)
        let results = await classifyConcurrently(classifier, times: 4, image: try blankImage())
        XCTAssertEqual(results.compactMap { $0 }.filter(\.isUnsure).count, 0,
                       "Čakanie v rade nesmie spôsobiť vypršanie limitu")
    }

    func testAbandonedCallHoldsTheModelUntilItEnds() async throws {
        let gate = FoundationModelGate()
        let image = try blankImage()
        // Times out at 0.6 s, still holds the model until it ends at 1 s, which
        // is before its cap (another 0.6 s) would release it.
        let stubborn = FoundationModelClassifier(judge: StubbornJudge(seconds: 1), timeoutSeconds: 0.6,
                                                 gate: gate)
        let first = try await stubborn.classify(crop: image, hint: nil)
        XCTAssertTrue(first.isUnsure)

        let judge = InFlightJudge(delay: 0)
        let next = FoundationModelClassifier(judge: judge, timeoutSeconds: 5, gate: gate)
        let start = Date()
        _ = try await next.classify(crop: image, hint: nil)
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.25,
                             "Ďalšia otázka čaká, kým opustené volanie modelu neskončí")
    }

    func testWedgedCallReleasesTheModelAfterTheCap() async throws {
        let gate = FoundationModelGate()
        let image = try blankImage()
        // The stubborn call blocks for 2 s; the gate gives it its 0.2 s limit
        // plus the same again, so the next call starts after about 0.4 s.
        let stubborn = FoundationModelClassifier(judge: StubbornJudge(seconds: 2), timeoutSeconds: 0.2,
                                                 gate: gate)
        _ = try await stubborn.classify(crop: image, hint: nil)

        let next = FoundationModelClassifier(judge: InFlightJudge(delay: 0), timeoutSeconds: 5, gate: gate)
        let start = Date()
        let judgement = try await next.classify(crop: image, hint: nil)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.2, "Zaseknuté volanie nesmie držať model navždy")
        XCTAssertFalse(judgement.isUnsure)
    }

    func testColdModelGetsTheLongerAllowanceOnlyUntilItAnswers() async throws {
        let gate = FoundationModelGate()
        let image = try blankImage()
        let classifier = FoundationModelClassifier(judge: InFlightJudge(delay: 0.4), timeoutSeconds: 0.2,
                                                   coldStartTimeoutSeconds: 2, gate: gate)
        let cold = try await classifier.classify(crop: image, hint: nil)
        XCTAssertFalse(cold.isUnsure, "Prvé volanie studeného modelu má dlhší limit")
        let warm = try await classifier.classify(crop: image, hint: nil)
        XCTAssertTrue(warm.isUnsure, "Zahriaty model má bežný limit")
    }

    func testRunStopsAskingTheModelAfterConsecutiveTimeouts() async throws {
        let judge = InFlightJudge(delay: 0.3)
        let classifier = FoundationModelClassifier(judge: judge, timeoutSeconds: 0.05)
        let counting = CallCountingClassifier(wrapping: classifier)
        let image = try blankImage()
        for _ in 0..<6 {
            let judgement = try await counting.classify(crop: image, hint: nil, textCoverage: nil)
            XCTAssertTrue(judgement.isUnsure)
        }
        XCTAssertEqual(judge.calls, CallCountingClassifier.consecutiveTimeoutLimit,
                       "Po opakovanom vypršaní sa model v tomto behu už nepýta")
        XCTAssertEqual(counting.unsure, 6, "Každý výrez bez odpovede modelu sa započíta do hlásenia")
    }

    func testThrownErrorsDoNotStopTheRun() async throws {
        let classifier = FoundationModelClassifier(judge: FailingJudge(), timeoutSeconds: 1)
        let counting = CallCountingClassifier(wrapping: classifier)
        let image = try blankImage()
        for _ in 0..<5 {
            _ = try? await counting.classify(crop: image, hint: nil, textCoverage: nil)
        }
        XCTAssertEqual(counting.count, 5, "Odmietnutie jedného výrezu nevypína model pre celý dokument")
        XCTAssertEqual(counting.unsure, 5)
    }

    /// Answers after the given delays, one per call in order.
    private final class ScriptedJudge: FoundationJudging, @unchecked Sendable {
        private let delays = OSAllocatedUnfairLock(initialState: (remaining: [Double](), calls: 0))
        init(delays: [Double]) { self.delays.withLock { $0.remaining = delays } }
        var calls: Int { delays.withLock { $0.calls } }
        func judge(crop: CGImage, hint: SecurityElement.Kind?, context: String) async throws -> FoundationJudgement {
            let delay = delays.withLock { state -> Double in
                state.calls += 1
                return state.remaining.isEmpty ? 0 : state.remaining.removeFirst()
            }
            try await Task.sleep(for: .seconds(delay))
            return FoundationModelGateTests.answer
        }
    }

    func testAnAnswerResetsTheTimeoutStreak() async throws {
        let slow = 0.3
        let judge = ScriptedJudge(delays: [slow, slow, 0, slow, slow, 0])
        let counting = CallCountingClassifier(
            wrapping: FoundationModelClassifier(judge: judge, timeoutSeconds: 0.1))
        let image = try blankImage()
        for _ in 0..<6 {
            _ = try await counting.classify(crop: image, hint: nil, textCoverage: nil)
        }
        XCTAssertEqual(judge.calls, 6, "Odpoveď modelu nuluje sériu vypršaní")
        XCTAssertEqual(counting.unsure, 4)
    }
}
