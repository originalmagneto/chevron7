// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

// Providers in these tests render at 380 px: the frozen heuristic's mask passes
// scale super-linearly with pixel count and take tens of seconds per page in a
// debug build at the production 760 px, which only tests the compiler.
import XCTest
import PDFKit
import CoreGraphics
import os
@testable import Chevron7Kit

final class LayeredDetectionProviderTests: XCTestCase {
    private struct FixedSource: CandidateSourcing {
        let source: CandidateSource
        let boxes: [NormalizedRect]
        let fails: Bool
        func candidates(pageImage: CGImage, pageIndex: Int) async throws -> [DetectionCandidate] {
            if fails { throw NSError(domain: "test", code: 1) }
            return boxes.map { DetectionCandidate(pageIndex: pageIndex, box: $0, sources: [source]) }
        }
    }
    private struct FixedClassifier: ElementClassifying {
        let judgement: ElementJudgement
        func classify(crop: CGImage, hint: SecurityElement.Kind?) async throws -> ElementJudgement { judgement }
    }
    /// Stands in for the Foundation Model so budget enforcement is observable.
    private final class CountingClassifier: ElementClassifying, @unchecked Sendable {
        private let calls = OSAllocatedUnfairLock(initialState: 0)
        var count: Int { calls.withLock { $0 } }
        func classify(crop: CGImage, hint: SecurityElement.Kind?) async throws -> ElementJudgement {
            calls.withLock { $0 += 1 }
            // A decisive answer: an unsure one reads as a model timeout, and the
            // run stops asking the model after a few of those in a row.
            return ElementJudgement(kind: nil, confidence: 0, decidedBy: .foundationModel)
        }
    }

    /// 20 non-overlapping boxes, far more than the per-page budget of 12.
    /// They claim `.builtIn` so the merger's text gate cannot drop them and the
    /// count stays deterministic.
    private static func gridBoxes() -> [NormalizedRect] {
        var boxes: [NormalizedRect] = []
        for row in 0..<4 {
            for column in 0..<5 {
                boxes.append(.init(x: 0.05 + Double(column) * 0.09, y: 0.05 + Double(row) * 0.09,
                                   width: 0.04, height: 0.04))
            }
        }
        return boxes
    }

    private func runWithBudget(_ budget: Int) throws -> (calls: Int, stats: DetectionRunStats) {
        let (document, analyses) = try contract()
        let counter = CountingClassifier()
        var provider = LayeredDetectionProvider(
            extraSources: [FixedSource(source: .builtIn, boxes: Self.gridBoxes(), fails: false)],
            classifier: TwoStageClassifier(primary: FixedClassifier(judgement: .unsure), secondary: counter),
            renderTargetWidth: 380)
        provider.foundationModelBudgetPerPage = budget
        let configured = provider
        let doc = TestUncheckedSendable(document)
        let stats = awaitAsync { await configured.detectWithStats(in: doc.value, pageAnalyses: analyses).stats }
        return (counter.count, stats)
    }

    private func contract() throws -> (PDFDocument, [PageAnalysis]) {
        let document = try XCTUnwrap(PDFDocument(data: TestPDFBuilder.typicalContractPDF()))
        return (document, PDFAnalysisEngine().analyze(document: document).pageAnalyses)
    }

    func testEmitsPendingAIElementsWithDetectionSource() throws {
        let (document, analyses) = try contract()
        let classifier = TwoStageClassifier(
            primary: FixedClassifier(judgement: .init(kind: .officialStamp, confidence: 0.9, margin: 0.9,
                                                      descriptionSK: "Pečiatka.", decidedBy: .featurePrintKNN, supportCount: 10)),
            secondary: nil)
        let provider = LayeredDetectionProvider(
            extraSources: [FixedSource(source: .contour, boxes: [.init(x: 0.6, y: 0.1, width: 0.2, height: 0.2)], fails: false)],
            classifier: classifier, renderTargetWidth: 380)
        let doc = TestUncheckedSendable(document)
        let elements = awaitAsync { await provider.detect(in: doc.value, pageAnalyses: analyses) }
        let stamps = elements.filter { $0.kind == .officialStamp }
        XCTAssertFalse(stamps.isEmpty)
        for stamp in stamps {
            XCTAssertTrue(stamp.detectedByAI)
            XCTAssertEqual(stamp.reviewState, .pending)
            XCTAssertEqual(stamp.verbalDescription, "Pečiatka.")
            let source = try XCTUnwrap(stamp.detectionSource)
            XCTAssertTrue(source.contains("kNN"), source)
        }
    }

    func testFailingSourceDoesNotLoseBuiltInCandidates() throws {
        let (document, analyses) = try contract()
        let classifier = TwoStageClassifier(primary: FixedClassifier(judgement: .unsure), secondary: nil)
        let provider = LayeredDetectionProvider(
            extraSources: [FixedSource(source: .saliency, boxes: [], fails: true)],
            classifier: classifier, renderTargetWidth: 380)
        let doc = TestUncheckedSendable(document)
        let elements = awaitAsync { await provider.detect(in: doc.value, pageAnalyses: analyses) }
        // With an unsure kNN and no FM, hints from the built-in provider survive.
        XCTAssertTrue(elements.contains { $0.kind == .officialStamp || $0.kind == .handwrittenSignature },
                      "Vstavané nálezy musia prežiť zlyhanie zdroja: \(elements.map(\.kind))")
        XCTAssertTrue(elements.filter { $0.kind != .other }.allSatisfy { $0.detectionSource?.contains("builtInHint") == true })
    }

    func testNegativeClassificationDropsCandidates() throws {
        let (document, analyses) = try contract()
        let classifier = TwoStageClassifier(
            primary: FixedClassifier(judgement: .init(kind: nil, confidence: 0.95, margin: 0.9, decidedBy: .featurePrintKNN, supportCount: 9)),
            secondary: nil)
        let provider = LayeredDetectionProvider(extraSources: [], classifier: classifier, renderTargetWidth: 380)
        let doc = TestUncheckedSendable(document)
        let elements = awaitAsync { await provider.detect(in: doc.value, pageAnalyses: analyses) }
        XCTAssertTrue(elements.allSatisfy { $0.kind == .other }, "Len barcode passthrough smie zostať")
    }

    func testIdentifierListsActiveStages() {
        let classifier = TwoStageClassifier(primary: FixedClassifier(judgement: .unsure),
                                            secondary: FixedClassifier(judgement: .unsure))
        let provider = LayeredDetectionProvider(classifier: classifier, renderTargetWidth: 380)
        XCTAssertEqual(provider.identifier, "LayeredDetectionProvider/2 builtIn+contour+saliency kNN fm")
        let noFM = LayeredDetectionProvider(extraSources: [], classifier: TwoStageClassifier(primary: FixedClassifier(judgement: .unsure), secondary: nil), renderTargetWidth: 380)
        XCTAssertEqual(noFM.identifier, "LayeredDetectionProvider/2 builtIn kNN")
    }

    func testFoundationModelBudgetCapsCallsPerPageAndIsReportedInStats() throws {
        let unlimited = try runWithBudget(1000)
        XCTAssertGreaterThan(unlimited.calls, 12, "Fixture musí ponúknuť viac kandidátov než je rozpočet")
        XCTAssertEqual(unlimited.stats.foundationModelCalls, unlimited.calls)

        let budgeted = try runWithBudget(12)
        XCTAssertGreaterThan(budgeted.stats.pagesProcessed, 0)
        XCTAssertLessThanOrEqual(budgeted.calls, 12 * budgeted.stats.pagesProcessed)
        XCTAssertLessThan(budgeted.calls, unlimited.calls)
        XCTAssertEqual(budgeted.stats.foundationModelCalls, budgeted.calls)
    }

    func testPrioritizedPutsHintedThenMultiSourceThenLargerCandidatesFirst() {
        func candidate(x: Double, width: Double, sources: Set<CandidateSource>,
                       hint: SecurityElement.Kind? = nil) -> DetectionCandidate {
            DetectionCandidate(pageIndex: 0, box: .init(x: x, y: 0, width: width, height: width),
                               sources: sources, kindHint: hint, hintConfidence: hint == nil ? nil : 0.7)
        }
        let hinted = candidate(x: 0.0, width: 0.05, sources: [.builtIn], hint: .officialStamp)
        let twoSources = candidate(x: 0.1, width: 0.05, sources: [.contour, .saliency])
        let large = candidate(x: 0.3, width: 0.2, sources: [.contour])
        let small = candidate(x: 0.6, width: 0.05, sources: [.contour])
        let ordered = LayeredDetectionProvider.prioritized([small, large, twoSources, hinted])
        XCTAssertEqual(ordered.map(\.box.x), [hinted.box.x, twoSources.box.x, large.box.x, small.box.x])
    }

    func testPrioritizedTieBreaksByOriginWhenOtherwiseEqual() {
        func candidate(x: Double, y: Double) -> DetectionCandidate {
            DetectionCandidate(pageIndex: 0, box: .init(x: x, y: y, width: 0.05, height: 0.05),
                               sources: [.contour])
        }
        let topLeft = candidate(x: 0.1, y: 0.1)
        let topRight = candidate(x: 0.5, y: 0.1)
        let bottom = candidate(x: 0.3, y: 0.6)
        let expected: [[Double]] = [[topLeft.box.y, topLeft.box.x], [topRight.box.y, topRight.box.x], [bottom.box.y, bottom.box.x]]

        let orderedA = LayeredDetectionProvider.prioritized([bottom, topRight, topLeft])
        XCTAssertEqual(orderedA.map { [$0.box.y, $0.box.x] }, expected)

        let orderedB = LayeredDetectionProvider.prioritized([topRight, bottom, topLeft])
        XCTAssertEqual(orderedB.map { [$0.box.y, $0.box.x] }, expected)
    }

    func testFailingSourceIsReportedInRunStats() throws {
        let (document, analyses) = try contract()
        let provider = LayeredDetectionProvider(
            extraSources: [FixedSource(source: .saliency, boxes: [], fails: true)],
            classifier: TwoStageClassifier(primary: FixedClassifier(judgement: .unsure), secondary: nil), renderTargetWidth: 380)
        let doc = TestUncheckedSendable(document)
        let stats = awaitAsync { await provider.detectWithStats(in: doc.value, pageAnalyses: analyses).stats }
        XCTAssertFalse(stats.sourceFailures.isEmpty, "Zlyhanie zdroja sa musí objaviť v štatistike behu")
        XCTAssertTrue(stats.sourceFailures.allSatisfy { $0.hasPrefix("saliency: ") }, "\(stats.sourceFailures)")
        XCTAssertEqual(DetectionPipeline.sourceFailureMessage(stats.sourceFailures),
                       "Niektoré zdroje kandidátov zlyhali (saliency). ")
    }

    /// A ruled form is the shape that produced the field's false positives: the
    /// heuristic reads every stroked table cell as a signature. Only hints and the
    /// quality filter act here, so the assertion is about the filter alone.
    func testRuledFormWithPrintedTextYieldsNoSignatures() throws {
        let document = try XCTUnwrap(PDFDocument(data: TestPDFBuilder.ruledFormPDF()))
        let analyses = PDFAnalysisEngine().analyze(document: document).pageAnalyses
        let provider = LayeredDetectionProvider(
            extraSources: [],
            classifier: TwoStageClassifier(primary: FixedClassifier(judgement: .unsure), secondary: nil), renderTargetWidth: 380)
        let doc = TestUncheckedSendable(document)
        let elements = awaitAsync { await provider.detect(in: doc.value, pageAnalyses: analyses) }
        let signatures = elements.filter { $0.kind == .handwrittenSignature || $0.kind == .initial }
        XCTAssertTrue(signatures.isEmpty,
                      "Linkovaný formulár nesmie dať podpisy: \(signatures.map(\.boundingBox))")
    }

    func testDetectionPipelineAcceptsLayeredProvider() throws {
        let (document, analyses) = try contract()
        let provider = LayeredDetectionProvider(extraSources: [], classifier: TwoStageClassifier(primary: FixedClassifier(judgement: .unsure), secondary: nil), renderTargetWidth: 380)
        let pipeline = DetectionPipeline(builtin: provider)
        let doc = TestUncheckedSendable(document)
        let elements = awaitAsync { await pipeline.detect(in: doc.value, pageAnalyses: analyses) }
        XCTAssertFalse(elements.isEmpty)
    }
}
