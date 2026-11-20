// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
import Chevron7Kit
import Chevron7TestSupport
@testable import Chevron7App

/// The E→E verification step leads with one sentence per gate decision, beside the gate's card.
final class ZakoVerificationVerdictTests: XCTestCase {
    private var original: ElectronicOriginal!

    override func setUpWithError() throws {
        var signature = E2EEvidenceFixtures.Signature()
        signature.signedRevisionLength = 200
        let pdf = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x41, count: 191)
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(signatures: [signature]))
        original = try ElectronicOriginal.make(sourceName: "zmluva.pdf", sourceData: pdf, evidence: evidence)
    }

    private func authorization(_ configure: (inout ElectronicOriginal.Authorization) -> Void = { _ in })
        throws -> ElectronicOriginal.Authorization {
        var authorization = try XCTUnwrap(original.authorizations.first)
        configure(&authorization)
        return authorization
    }

    /// The sentence for these authorizations under the real gate's decision.
    private func verdict(_ authorizations: [ElectronicOriginal.Authorization], confirmed: Bool = false,
                         recordFirstRefused: Bool = false) -> ZakoVerificationPresentation.Verdict? {
        var decided = original!
        decided.authorizations = authorizations
        return ZakoVerificationPresentation.verdict(decision: E2EVerificationGate.decide(decided),
                                                    authorizations: authorizations,
                                                    undeterminedConfirmed: confirmed,
                                                    recordFirstRefused: recordFirstRefused)
    }

    func testNoDecisionNoSentence() {
        XCTAssertNil(ZakoVerificationPresentation.verdict(decision: nil, authorizations: [],
                                                          undeterminedConfirmed: false, recordFirstRefused: false))
    }

    func testValidSignatures() throws {
        let one = try authorization()
        XCTAssertNotNil(one.timestamp, "the fixture carries a signature timestamp")
        XCTAssertEqual(verdict([one]), .init(sentence: "Podpis aj jeho časová pečiatka sú platné.", tone: .success))
        XCTAssertEqual(verdict([one, one]),
                       .init(sentence: "Všetky podpisy a časové pečiatky sú platné.", tone: .success))

        let bare = try authorization { $0.timestamp = nil }
        XCTAssertEqual(verdict([bare])?.sentence, "Podpis je platný.")
        XCTAssertEqual(verdict([bare, bare])?.sentence, "Všetky podpisy sú platné.")
    }

    func testGateCardOnlyForRefusalsWarningsAndConfirmations() throws {
        let valid = try authorization()
        var decided = original!
        decided.authorizations = [valid, valid]
        let ready = E2EVerificationGate.decide(decided)
        XCTAssertEqual(ready, .ready)
        XCTAssertFalse(ZakoVerificationPresentation.showsGateCard(decision: ready, recordFirstRefused: false),
                       "the verdict line says all is valid; no second card repeats it")
        XCTAssertTrue(ZakoVerificationPresentation.showsGateCard(decision: ready, recordFirstRefused: true))
        XCTAssertTrue(ZakoVerificationPresentation.showsGateCard(decision: .blocked("x"),
                                                                 recordFirstRefused: false))
        XCTAssertTrue(ZakoVerificationPresentation.showsGateCard(decision: .needsConfirmation([valid]),
                                                                 recordFirstRefused: false))
        XCTAssertFalse(ZakoVerificationPresentation.showsGateCard(decision: nil, recordFirstRefused: true))
    }

    func testUndeterminedAsksForConfirmation() throws {
        let valid = try authorization()
        let unknown = try authorization { $0.state = .undetermined }
        XCTAssertEqual(verdict([unknown]),
                       .init(sentence: "Podpis nie je možné overiť: potvrďte, že chcete pokračovať.", tone: .warning))
        XCTAssertEqual(verdict([valid, unknown])?.sentence,
                       "Jeden podpis nie je možné overiť: potvrďte, že chcete pokračovať.")
        XCTAssertEqual(verdict([unknown, unknown])?.sentence,
                       "2 podpisy nie je možné overiť: potvrďte, že chcete pokračovať.")
        XCTAssertEqual(verdict(Array(repeating: unknown, count: 5))?.sentence,
                       "5 podpisov nie je možné overiť: potvrďte, že chcete pokračovať.")
        XCTAssertEqual(verdict([valid, unknown], confirmed: true)?.sentence,
                       "Jeden podpis nie je možné overiť: pokračovanie ste potvrdili.")

        let unknownTimestamp = try authorization { $0.timestamp?.state = .undetermined }
        XCTAssertEqual(verdict([unknownTimestamp])?.tone, .warning)
    }

    func testBlockedSaysWhy() throws {
        let valid = try authorization()
        let invalid = try authorization { $0.state = .invalid }
        XCTAssertEqual(verdict([invalid]),
                       .init(sentence: "Podpis nie je platný: konverziu nemožno vykonať.", tone: .failure))
        XCTAssertEqual(verdict([valid, invalid])?.sentence, "Jeden podpis nie je platný: konverziu nemožno vykonať.")
        XCTAssertEqual(verdict([invalid, invalid])?.sentence,
                       "Niektoré podpisy nie sú platné: konverziu nemožno vykonať.")

        let badTimestamp = try authorization { $0.timestamp?.state = .invalid }
        XCTAssertEqual(verdict([badTimestamp])?.sentence,
                       "Časová pečiatka podpisu nie je platná: konverziu nemožno vykonať.")

        let noList = try authorization { $0.trustedListUnavailable = true; $0.state = .undetermined }
        XCTAssertEqual(verdict([noList])?.sentence, "Overenie sa nedokončilo: konverziu zatiaľ nemožno vykonať.")
    }

    /// A refusal the sentence cannot name still reads as one.
    func testOtherBlockedDecisionFallsBack() throws {
        XCTAssertEqual(ZakoVerificationPresentation.verdict(decision: .blocked("Iný dôvod."),
                                                            authorizations: [try authorization()],
                                                            undeterminedConfirmed: false, recordFirstRefused: false),
                       .init(sentence: "Konverziu nemožno vykonať.", tone: .failure))
    }

    func testRecordFirstRefusalLeads() throws {
        XCTAssertEqual(verdict([try authorization()], recordFirstRefused: true),
                       .init(sentence: "Konverziu nemožno vykonať postupom od 1. 1. 2027.", tone: .failure))
    }
}
