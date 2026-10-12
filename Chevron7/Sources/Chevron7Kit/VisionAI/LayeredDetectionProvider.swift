// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import CoreGraphics
import PDFKit
import os
import Chevron7Identity

/// A page rendered and OCRed exactly once, then shared by every detection stage.
///
/// Sending this across task boundaries is safe: `PixelMap` is a value type and
/// `CGImage` is immutable, so no task can observe another task's mutation. The
/// `@unchecked` conformance is only needed because `CGImage` predates `Sendable`.
struct PreparedPage: @unchecked Sendable {
    let pageIndex: Int
    let pixels: PixelMap
    let image: CGImage
    let exclusions: BuiltInVisionProvider.VisionExclusions
}

/// Per-run counters, useful for the evaluation harness and for surfacing
/// degraded stages in the UI.
public struct DetectionRunStats: Sendable, Equatable {
    public var foundationModelCalls: Int
    public var pagesProcessed: Int
    public var sourceFailures: [String]
    /// Calls where the on-device model timed out or threw, so its answer carried
    /// no information and the built-in hint decided instead.
    public var foundationModelUnsure: Int
    /// Candidates dropped by `CandidateQualityFilter` before classification.
    public var filteredCandidates: Int
    /// Wall-clock seconds spent waiting for the on-device model.
    public var foundationModelSeconds: Double

    public init(foundationModelCalls: Int = 0, pagesProcessed: Int = 0, sourceFailures: [String] = [],
                foundationModelUnsure: Int = 0, filteredCandidates: Int = 0,
                foundationModelSeconds: Double = 0) {
        self.foundationModelCalls = foundationModelCalls
        self.pagesProcessed = pagesProcessed
        self.sourceFailures = sourceFailures
        self.foundationModelUnsure = foundationModelUnsure
        self.filteredCandidates = filteredCandidates
        self.foundationModelSeconds = foundationModelSeconds
    }
}

/// Counts how often the secondary (Foundation Model) classifier was invoked
/// during one detection run. Created per run, so the count never leaks between runs.
/// After `consecutiveTimeoutLimit` timeouts in a row it stops asking the model for
/// the rest of the run: model calls are serialized, so a model that keeps timing out
/// would otherwise cost every remaining crop its full limit one after another.
final class CallCountingClassifier: ElementClassifying, @unchecked Sendable {
    static let consecutiveTimeoutLimit = 3
    private static let logger = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "VisionAI")

    let wrapped: any ElementClassifying
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    private let unsureCalls = OSAllocatedUnfairLock(initialState: 0)
    private let consecutiveTimeouts = OSAllocatedUnfairLock(initialState: 0)
    private let elapsed = OSAllocatedUnfairLock(initialState: 0.0)

    init(wrapping wrapped: any ElementClassifying) { self.wrapped = wrapped }

    var count: Int { calls.withLock { $0 } }
    /// Crops the model gave no usable answer for: unsure results, thrown errors,
    /// and crops skipped after the run stopped asking the model.
    var unsure: Int { unsureCalls.withLock { $0 } }
    /// Wall-clock seconds spent inside the wrapped classifier, including time a
    /// crop waited for the model while another page's crop held it.
    var seconds: Double { elapsed.withLock { $0 } }

    func classify(crop: CGImage, hint: SecurityElement.Kind?) async throws -> ElementJudgement {
        try await classify(crop: crop, hint: hint, textCoverage: nil)
    }

    func classify(crop: CGImage, hint: SecurityElement.Kind?,
                  textCoverage: Double?) async throws -> ElementJudgement {
        if consecutiveTimeouts.withLock({ $0 >= Self.consecutiveTimeoutLimit }) {
            unsureCalls.withLock { $0 += 1 }
            return ElementJudgement(kind: nil, confidence: 0, decidedBy: .foundationModel, isUnsure: true)
        }
        calls.withLock { $0 += 1 }
        let start = Date()
        defer { let dt = Date().timeIntervalSince(start); elapsed.withLock { $0 += dt } }
        do {
            let result: ElementJudgement
            if let foundationModel = wrapped as? FoundationModelClassifier {
                result = try await foundationModel.classify(crop: crop, hint: hint, textCoverage: textCoverage)
            } else {
                result = try await wrapped.classify(crop: crop, hint: hint)
            }
            if result.isUnsure {
                unsureCalls.withLock { $0 += 1 }
                let streak = consecutiveTimeouts.withLock { $0 += 1; return $0 }
                Self.logger.notice("Foundation Model gave no answer in time (\(streak, privacy: .public) in a row)")
                if streak == Self.consecutiveTimeoutLimit {
                    Self.logger.error("Foundation Model timed out \(streak, privacy: .public) times in a row; not asked again in this run")
                }
            } else {
                consecutiveTimeouts.withLock { $0 = 0 }
            }
            return result
        } catch {
            // A throwing secondary is as uninformative as a timeout; count it,
            // then let the caller's `try?` turn it into an absent judgement. It
            // returned at once, so it does not count towards the timeout streak.
            unsureCalls.withLock { $0 += 1 }
            Self.logger.error("Foundation Model failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}

/// Layered on-device security element detector: built-in heuristics seed
/// candidates, contour and saliency sources add more, then a two-stage
/// classifier (kNN, optionally a Foundation Model fallback) decides the
/// final kind for each merged candidate.
public struct LayeredDetectionProvider: SecurityElementsProviding {
    public static let version = 2
    /// Page width in pixels the detector renders at. `ExampleBankRecorder` embeds
    /// review crops at the same width, so a reviewed candidate matches itself.
    public static let defaultRenderTargetWidth = 760

    public let builtIn: BuiltInCandidateSource
    public var extraSources: [any CandidateSourcing]
    public let classifier: TwoStageClassifier
    public let renderTargetWidth: Int
    public let maxConcurrentPages: Int

    /// Upper bound on candidates per page that may reach the Foundation Model.
    /// Candidates beyond it are decided by kNN with the built-in hint as fallback.
    public var foundationModelBudgetPerPage: Int = 12

    /// Called on the detection loop after each page result, with the number of
    /// pages finished and the total number of non-empty pages.
    public var progress: (@Sendable (_ processed: Int, _ total: Int) -> Void)?

    public init(builtIn: BuiltInCandidateSource = BuiltInCandidateSource(),
                extraSources: [any CandidateSourcing] = [ContourCandidateSource(), SaliencyCandidateSource()],
                classifier: TwoStageClassifier,
                renderTargetWidth: Int = LayeredDetectionProvider.defaultRenderTargetWidth,
                maxConcurrentPages: Int = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)) {
        self.builtIn = builtIn
        self.extraSources = extraSources
        self.classifier = classifier
        self.renderTargetWidth = renderTargetWidth
        // Chunked page processing strides by this value; zero would trap.
        self.maxConcurrentPages = max(1, maxConcurrentPages)
    }

    public static func makeDefault(bank: ExampleBank, useFoundationModel: Bool,
                                   learnedSource: LearnedCandidateSource? = nil) -> LayeredDetectionProvider {
        let knn = FeaturePrintClassifier(bank: bank)
        let fm: (any ElementClassifying)? = useFoundationModel ? FoundationModelClassifier.makeIfAvailable() : nil
        var extra: [any CandidateSourcing] = [ContourCandidateSource(), SaliencyCandidateSource()]
        if let learnedSource { extra.append(learnedSource) }
        return LayeredDetectionProvider(extraSources: extra,
                                        classifier: TwoStageClassifier(primary: knn, secondary: fm))
    }

    /// A copy with the learned source appended (or itself when nil), for call
    /// sites that cannot rebuild the provider.
    public func withLearnedSource(_ source: LearnedCandidateSource?) -> LayeredDetectionProvider {
        guard let source else { return self }
        var copy = self
        copy.extraSources.append(source)
        return copy
    }

    /// Versioned audit identifier listing active stages, stored in SecurityReviewStamp.
    public var identifier: String {
        var stages = ["builtIn"] + extraSources.map { $0.source.rawValue }
        stages = CandidateSource.allCases.map(\.rawValue).filter { stages.contains($0) }
        var parts = ["LayeredDetectionProvider/\(Self.version)", stages.joined(separator: "+"), "kNN"]
        if classifier.secondary != nil { parts.append("fm") }
        for learned in extraSources.compactMap({ $0 as? LearnedCandidateSource }) {
            parts.append("learned(\(learned.modelID))")
        }
        return parts.joined(separator: " ")
    }

    public var providerName: String { identifier }

    public func detect(in document: PDFDocument, pageAnalyses: [PageAnalysis]) async -> [SecurityElement] {
        await detectWithStats(in: document, pageAnalyses: pageAnalyses).elements
    }

    public func detectWithStats(in document: PDFDocument,
                                pageAnalyses: [PageAnalysis]) async -> (elements: [SecurityElement], stats: DetectionRunStats) {
        guard document.pageCount > 0 else { return ([], DetectionRunStats()) }

        let nonEmptyPageIndices = (0..<document.pageCount).filter { pageIndex in
            pageAnalyses.first(where: { $0.pageIndex == pageIndex })?.isEmpty == false
        }

        // Snapshot the example bank once per run so every page votes against the
        // same set of examples even if the user confirms elements while it runs.
        let counting = classifier.secondary.map { CallCountingClassifier(wrapping: $0) }
        let runClassifier = TwoStageClassifier(primary: await Self.snapshot(of: classifier.primary),
                                               secondary: counting,
                                               minimumSupport: classifier.minimumSupport,
                                               minimumMargin: classifier.minimumMargin)

        var elements: [SecurityElement] = []
        var sourceFailures: [String] = []
        var pagesProcessed = 0
        var filteredCandidates = 0
        var pagesFinished = 0
        let totalPages = nonEmptyPageIndices.count

        // Pages are processed in chunks of `maxConcurrentPages`. Each chunk is
        // rendered and OCRed sequentially (PDFKit is not thread safe), then
        // classified concurrently within one `TaskGroup`. Only one chunk's
        // bitmaps are resident at a time, so peak memory is bounded by the
        // window rather than growing with the page count.
        for chunkStart in stride(from: 0, to: nonEmptyPageIndices.count, by: maxConcurrentPages) {
            let chunkIndices = nonEmptyPageIndices[chunkStart..<min(chunkStart + maxConcurrentPages, nonEmptyPageIndices.count)]

            var chunk: [PreparedPage] = []
            for pageIndex in chunkIndices {
                guard let page = document.page(at: pageIndex),
                      let rendered = BuiltInVisionProvider.render(page: page, targetWidth: renderTargetWidth) else { continue }
                let fast = await BuiltInVisionProvider.visionExclusionBoxes(cgImage: rendered.cgImage)
                let accurate = await AccurateTextExclusions.textBoxes(in: rendered.cgImage)
                let exclusions = AccurateTextExclusions.merged(into: fast, accurate: accurate)
                chunk.append(PreparedPage(pageIndex: pageIndex, pixels: rendered.pixels,
                                          image: rendered.cgImage, exclusions: exclusions))
            }
            pagesProcessed += chunk.count

            await withTaskGroup(of: PageResult.self) { group in
                for page in chunk {
                    group.addTask { await self.detectOnPage(page, classifier: runClassifier) }
                }
                for await pageResult in group {
                    elements.append(contentsOf: pageResult.elements)
                    sourceFailures.append(contentsOf: pageResult.sourceFailures)
                    filteredCandidates += pageResult.filteredCandidates
                    pagesFinished += 1
                    progress?(pagesFinished, totalPages)
                }
            }
        }

        let stats = DetectionRunStats(foundationModelCalls: counting?.count ?? 0,
                                      pagesProcessed: pagesProcessed,
                                      sourceFailures: sourceFailures,
                                      foundationModelUnsure: counting?.unsure ?? 0,
                                      filteredCandidates: filteredCandidates,
                                      foundationModelSeconds: counting?.seconds ?? 0)
        return (elements, stats)
    }

    private struct PageResult: Sendable {
        var elements: [SecurityElement]
        var sourceFailures: [String]
        var filteredCandidates: Int = 0
    }

    private func detectOnPage(_ page: PreparedPage, classifier runClassifier: TwoStageClassifier) async -> PageResult {
        let builtInResult = builtIn.candidates(on: page)
        var candidates = builtInResult.candidates
        var sourceFailures: [String] = []
        for source in extraSources {
            do {
                candidates.append(contentsOf: try await source.candidates(pageImage: page.image, pageIndex: page.pageIndex))
            } catch {
                sourceFailures.append("\(source.source.rawValue): \(error.localizedDescription)")
            }
        }
        let allMerged = CandidateMerger.merge(candidates, exclusions: page.exclusions)
        let kept = allMerged.compactMap { CandidateQualityFilter.filter($0, page: page) }
        let filteredCandidates = allMerged.count - kept.count
        let merged = Self.prioritized(kept)

        // Candidates without a secondary classifier cannot reach the Foundation Model.
        let withoutFoundationModel = TwoStageClassifier(primary: runClassifier.primary, secondary: nil,
                                                        minimumSupport: runClassifier.minimumSupport,
                                                        minimumMargin: runClassifier.minimumMargin)

        var result = builtInResult.passthrough
        for (rank, candidate) in merged.enumerated() {
            guard let crop = PageCrop.crop(page.image, to: candidate.box) else { continue }
            let effective = rank < foundationModelBudgetPerPage ? runClassifier : withoutFoundationModel
            let coverage = CandidateQualityFilter.textCoverage(of: candidate.box,
                                                               textBoxes: page.exclusions.textBoxes)
            guard let judgement = await effective.classify(crop: crop, hint: candidate.kindHint,
                                                           hintConfidence: candidate.hintConfidence,
                                                           textCoverage: coverage),
                  let kind = judgement.kind else { continue }
            // For a hint-only decision `descriptionSK` is empty on purpose: no
            // judgement produced a verbal description, and inventing one would
            // put unreviewed text in front of the notary.
            result.append(SecurityElement(
                kind: kind, pageIndex: page.pageIndex, boundingBox: candidate.box,
                confidence: judgement.confidence, verbalDescription: judgement.descriptionSK,
                detectedByAI: true, reviewState: .pending,
                detectionSource: Self.sourceString(candidate: candidate, judgement: judgement)))
        }
        return PageResult(elements: result, sourceFailures: sourceFailures,
                          filteredCandidates: filteredCandidates)
    }

    /// Foundation Model budget order: hinted candidates first, then the ones more
    /// sources agreed on, then the larger regions. Candidates that tie on all
    /// three are ordered by box origin (y then x) so the result is deterministic
    /// regardless of input order.
    static func prioritized(_ candidates: [DetectionCandidate]) -> [DetectionCandidate] {
        candidates.sorted { lhs, rhs in
            let lhsHinted = lhs.kindHint != nil
            let rhsHinted = rhs.kindHint != nil
            if lhsHinted != rhsHinted { return lhsHinted }
            if lhs.sources.count != rhs.sources.count { return lhs.sources.count > rhs.sources.count }
            let lhsArea = lhs.box.width * lhs.box.height
            let rhsArea = rhs.box.width * rhs.box.height
            if lhsArea != rhsArea { return lhsArea > rhsArea }
            if lhs.box.y != rhs.box.y { return lhs.box.y < rhs.box.y }
            return lhs.box.x < rhs.box.x
        }
    }

    /// Returns an examples-backed copy of a kNN classifier; any other classifier
    /// is returned unchanged.
    static func snapshot(of primary: any ElementClassifying) async -> any ElementClassifying {
        guard let knn = primary as? FeaturePrintClassifier else { return primary }
        return await knn.snapshot()
    }

    static func sourceString(candidate: DetectionCandidate, judgement: ElementJudgement) -> String {
        switch judgement.decidedBy {
        case .featurePrintKNN where judgement.isExactMatch: return "\(candidate.sourceLabel); kNN(exact)"
        case .featurePrintKNN: return "\(candidate.sourceLabel); kNN(n=\(judgement.supportCount))"
        case .foundationModel: return "\(candidate.sourceLabel); fm"
        case .builtInHint: return "\(candidate.sourceLabel); builtInHint"
        }
    }
}
