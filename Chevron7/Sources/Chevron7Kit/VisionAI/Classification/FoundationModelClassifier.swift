// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import CoreGraphics
import FoundationModels

public enum FoundationJudgementKind: String, Sendable, CaseIterable, Codable {
    case stamp, signature, embossedSeal, initial, bindingCord, securityTape, waxSeal, other, none

    public var securityKind: SecurityElement.Kind? {
        switch self {
        case .stamp: return .officialStamp
        case .signature: return .handwrittenSignature
        case .embossedSeal: return .embossedSeal
        case .initial: return .initial
        case .bindingCord: return .bindingCord
        case .securityTape: return .securityTape
        case .waxSeal: return .waxSeal
        case .other: return .other
        case .none: return nil
        }
    }
}

public struct FoundationJudgement: Sendable, Equatable {
    public var isSecurityElement: Bool
    public var kind: FoundationJudgementKind
    public var descriptionSK: String
    public var confidence: Double

    public init(isSecurityElement: Bool, kind: FoundationJudgementKind, descriptionSK: String, confidence: Double) {
        self.isSecurityElement = isSecurityElement
        self.kind = kind
        self.descriptionSK = descriptionSK
        self.confidence = confidence
    }
}

public protocol FoundationJudging: Sendable {
    /// `context` carries extra evidence about the crop (for example OCR text
    /// coverage). Empty when nothing is known.
    func judge(crop: CGImage, hint: SecurityElement.Kind?, context: String) async throws -> FoundationJudgement
}

/// Structured output type for the on-device model.
@Generable(description: "Judgement whether a crop of a scanned legal document shows a physical security element")
struct GeneratedJudgement {
    @Guide(description: "true only if an ink stamp, handwritten signature or initial, embossed impression, binding cord, sealing tape or sticker, or wax seal is visible in the image")
    var isSecurityElement: Bool
    @Guide(description: "one of: stamp, signature, embossedSeal, initial, bindingCord, securityTape, waxSeal, other, none")
    var kind: String
    @Guide(description: "confidence between 0 and 1", .range(0.0...1.0))
    var confidence: Double
}

/// Live judge. Every call gets a fresh session: a `LanguageModelSession` keeps its
/// transcript, so reusing one across crops would grow the context (images included)
/// until the model slows down and finally exceeds its window, and a session still
/// answering an abandoned (timed out) request rejects the next one outright.
public actor SystemFoundationJudge: FoundationJudging {
    private static let instructions = """
        You inspect small crops of scanned Slovak legal documents. Decide only from what is \
        physically visible in the image. Never infer an element from context, expected placement, \
        or surrounding text. A stamp is an inked impression (often round, blue or red, with text or \
        a coat of arms). A signature is handwritten cursive ink. An embossed seal is a colourless \
        relief impression. An initial is a short handwritten mark. Binding cord is a visible physical cord or ribbon, \
        including tricolour cord, used to bind sheets. Security tape is a visible sealing strip or \
        attachment sticker, including printed text on that physical sticker. A wax seal is a raised \
        blob or seal attached to paper or cord, not colourless embossing. Do not infer secure binding, \
        signature certification or authenticity; those require human inspection of the original. Printed text, logos, lines, tables \
        and photographs are not security elements. Printed or typed text, names, addresses, \
        numbers, table cells, form fields, ruled boxes and underlines are NOT security elements \
        even when bold. A handwritten signature shows irregular pen strokes that do not look like \
        a font. Answer in the requested structure.
        """

    /// Retained until the first real call so ARC cannot drop it mid warm-up.
    private var warmSession: LanguageModelSession?

    public init() {
        // Warming one throwaway session loads the model before the first real crop.
        let session = LanguageModelSession(instructions: Self.instructions)
        session.prewarm()
        warmSession = session
    }

    public func judge(crop: CGImage, hint: SecurityElement.Kind?, context: String) async throws -> FoundationJudgement {
        // The heuristic's guess is deliberately not shown to the model: naming a
        // kind in the prompt measurably biases it towards confirming that kind.
        _ = hint
        warmSession = nil
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(generating: GeneratedJudgement.self,
                                                 options: GenerationOptions(temperature: 0)) {
            "Is a physical security element visible in this crop? \(context)"
            Attachment(crop)
        }
        let content = response.content
        return FoundationJudgement(isSecurityElement: content.isSecurityElement,
                                   kind: FoundationJudgementKind(rawValue: content.kind) ?? .none,
                                   // The on-device model cannot write reliable Slovak; the app
                                   // composes the clause text from kind and position instead.
                                   descriptionSK: "",
                                   confidence: min(max(content.confidence, 0), 1))
    }
}

/// Holds the outcome of a judge task so a cancellable polling task can observe it without
/// awaiting the (possibly non-cancellable) judge task directly.
private actor JudgementCell {
    private(set) var result: Result<ElementJudgement, Error>?
    func set(_ r: Result<ElementJudgement, Error>) { result = r }
}

public struct FoundationModelClassifier: ElementClassifying {
    public let judge: any FoundationJudging
    public let timeoutSeconds: Double
    /// Limit for a crop that finds the model cold (`FoundationModelGate.Lease.isCold`):
    /// its first answer after loading took 8.7 s, over the usual limit on its own.
    public let coldStartTimeoutSeconds: Double
    /// Serializes model calls; the limit of a crop starts only once it holds the gate.
    public let gate: FoundationModelGate

    public init(judge: any FoundationJudging, timeoutSeconds: Double = 8,
                coldStartTimeoutSeconds: Double? = nil,
                gate: FoundationModelGate = FoundationModelGate()) {
        self.judge = judge
        self.timeoutSeconds = timeoutSeconds
        self.coldStartTimeoutSeconds = max(timeoutSeconds, coldStartTimeoutSeconds ?? timeoutSeconds)
        self.gate = gate
    }

    public static func makeIfAvailable(timeoutSeconds: Double = 8,
                                       coldStartTimeoutSeconds: Double = 20) -> FoundationModelClassifier? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        return FoundationModelClassifier(judge: SystemFoundationJudge(), timeoutSeconds: timeoutSeconds,
                                         coldStartTimeoutSeconds: coldStartTimeoutSeconds,
                                         gate: .shared)
    }

    public func classify(crop: CGImage, hint: SecurityElement.Kind?) async throws -> ElementJudgement {
        try await classify(crop: crop, hint: hint, textCoverage: nil)
    }

    /// `textCoverage` is the fraction of the crop covered by OCR text boxes, passed
    /// to the model as extra evidence so printed regions are rejected more reliably.
    public func classify(crop: CGImage, hint: SecurityElement.Kind?,
                         textCoverage: Double?) async throws -> ElementJudgement {
        let judge = self.judge
        let crop = crop
        let context = Self.contextText(textCoverage: textCoverage)
        let gate = self.gate
        let lease = await gate.acquire()
        let timeout = lease.isCold ? coldStartTimeoutSeconds : timeoutSeconds
        // The judge runs in its own detached task, outside the task group, because
        // `withThrowingTaskGroup` only returns once every child task has finished.
        // `LanguageModelSession.respond` is not guaranteed to observe cancellation, so if the
        // judge itself were a group child, a slow/non-cancellable model call would block
        // `classify` for the full inference time and the timeout would never be honoured.
        // Instead the judge writes its outcome into an actor-isolated cell, and a cancellable
        // polling child inside the group reads that cell. This lets the group (and therefore
        // `classify`) return as soon as the timeout fires, without ever awaiting the judge task.
        // The judge task releases the gate when the model is done with it, so an abandoned
        // call never overlaps the next one.
        let cell = JudgementCell()
        let judgeTask = Task {
            do {
                let result = Self.map(try await judge.judge(crop: crop, hint: hint, context: context))
                await cell.set(.success(result))
                await gate.release(lease, answered: true)
            } catch {
                await cell.set(.failure(error))
                await gate.release(lease, answered: false)
            }
        }
        let result: ElementJudgement?
        do {
            result = try await withThrowingTaskGroup(of: ElementJudgement?.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        if let outcome = await cell.result {
                            return try outcome.get()
                        }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    return nil
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
        } catch {
            if await cell.result == nil { Self.releaseAfterCap(lease, gate: gate, seconds: timeout) }
            throw error
        }
        if result == nil {
            judgeTask.cancel()
            Self.releaseAfterCap(lease, gate: gate, seconds: timeout)
        }
        return result ?? ElementJudgement(kind: nil, confidence: 0, decidedBy: .foundationModel,
                                          isUnsure: true)
    }

    /// A call that ignores cancellation keeps the model at most `seconds` past its
    /// limit, so a wedged model cannot hold the gate for good.
    private static func releaseAfterCap(_ lease: FoundationModelGate.Lease, gate: FoundationModelGate,
                                        seconds: Double) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            await gate.release(lease, answered: false)
        }
    }

    static func contextText(textCoverage: Double?) -> String {
        guard let textCoverage else { return "" }
        let percent = Int((textCoverage * 100).rounded())
        return "OCR found printed text covering \(percent) % of this region."
    }

    public static func map(_ judgement: FoundationJudgement) -> ElementJudgement {
        let kind = judgement.isSecurityElement ? judgement.kind.securityKind : nil
        return ElementJudgement(kind: kind, confidence: judgement.confidence, margin: 0,
                                descriptionSK: judgement.descriptionSK, decidedBy: .foundationModel)
    }
}
