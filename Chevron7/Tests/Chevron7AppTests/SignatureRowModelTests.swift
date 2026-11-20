// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Foundation
import XCTest
import Chevron7Kit
import Chevron7TestSupport
@testable import Chevron7App

/// The signature banner's rows and the E→E verification's authorizations map into the one
/// row `SignatureRowView` draws, each keeping every fact and its own wording.
final class SignatureRowModelTests: XCTestCase {
    // MARK: Banner

    private func bannerRow(verdict: DocumentSignatureInfo.State? = .valid, detail: String = "Podpísané 7. 10. 2026 11:18",
                           warning: String? = nil, isNew: Bool = false) -> SignatureBannerModel.Row {
        SignatureBannerModel.Row(id: "S-1", title: "Ján Klient", verdict: verdict, badges: ["KEP"],
                                 verdictLabel: verdict == nil ? nil : "Platný", detail: detail,
                                 reason: "Certifikát bol zrušený", dataTimestamp: "Časová pečiatka údajov · 7. 10. 2026",
                                 timestamp: "Časová pečiatka podpisu · 7. 10. 2026", warning: warning, depth: 1,
                                 isNew: isNew)
    }

    func testBannerSignatureKeepsEveryFact() {
        let model = SignatureRowModel(bannerRow(isNew: true))
        XCTAssertEqual(model.id, "S-1")
        XCTAssertEqual(model.title, "Ján Klient")
        XCTAssertEqual(model.tone, .valid)
        XCTAssertEqual(model.symbol, SignatureTreePresentation.icon(.valid))
        XCTAssertEqual(model.verdictLabel, "Platný")
        XCTAssertEqual(model.badges, ["KEP"])
        XCTAssertTrue(model.isNew)
        XCTAssertEqual(model.lines, ["Podpísané 7. 10. 2026 11:18", "Časová pečiatka údajov · 7. 10. 2026",
                                     "Časová pečiatka podpisu · 7. 10. 2026"],
                       "detail, then the data timestamp, then the signature timestamp")
        XCTAssertEqual(model.reason, "Certifikát bol zrušený")
        XCTAssertNil(model.technicalDetail)
        XCTAssertEqual(model.depth, 1)
    }

    func testBannerVerdictTones() {
        XCTAssertEqual(SignatureRowModel(bannerRow(verdict: .invalid)).tone, .invalid)
        XCTAssertEqual(SignatureRowModel(bannerRow(verdict: .indeterminate)).tone, .undetermined)
        XCTAssertEqual(SignatureRowModel(bannerRow(verdict: .unknown)).tone, .undetermined)
    }

    /// An undetermined row once drew no symbol at all: "questionmark.seal.fill" is not an SF Symbol.
    func testEveryVerdictSymbolExistsAndUndeterminedMatchesTheVerification() {
        for state in [DocumentSignatureInfo.State.valid, .invalid, .indeterminate, .unknown] {
            let symbol = SignatureRowModel(bannerRow(verdict: state)).symbol
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
        XCTAssertEqual(SignatureTreePresentation.icon(.indeterminate), "questionmark.diamond.fill",
                       "the same symbol as an undetermined authorization in the E→E verification")
    }

    func testBannerFileRowsAreNeutralOrWarnings() {
        let file = SignatureRowModel(bannerRow(verdict: nil, detail: "2 podpisy"))
        XCTAssertEqual(file.tone, .neutral)
        XCTAssertEqual(file.symbol, "doc.text")
        XCTAssertNil(file.verdictLabel)

        let skipped = SignatureRowModel(bannerRow(verdict: nil, detail: "", warning: "Podpisy sa neoverovali."))
        XCTAssertEqual(skipped.tone, .warning)
        XCTAssertEqual(skipped.symbol, "exclamationmark.triangle.fill")
        XCTAssertEqual(skipped.warning, "Podpisy sa neoverovali.")
        XCTAssertFalse(skipped.lines.contains(""), "an empty detail is no line")
    }

    func testBannerModelRowsMapOneToOne() throws {
        let signature = DocumentSignatureInfo(id: "A", signerDisplayName: "Eva Nová", signingTime: nil,
                                              hasQualifiedTimestamp: false, state: .valid,
                                              coveredDocuments: [], certificateQualification: "QESIG")
        let state = SignatureTreeState(tree: SignatureTree(signatures: [signature], documents: []), phase: .validated)
        let banner = try XCTUnwrap(SignatureBannerModel.make(from: state))
        let rows = banner.rows.map(SignatureRowModel.init)
        XCTAssertEqual(rows.map(\.id), banner.rows.map(\.id))
        XCTAssertEqual(rows.first?.badges, ["KEP"])
    }

    // MARK: E→E verification

    private func authorization(_ configure: (inout E2EEvidenceFixtures.Signature) -> Void = { _ in })
        throws -> ElectronicOriginal.Authorization {
        var signature = E2EEvidenceFixtures.Signature()
        signature.signedRevisionLength = 200
        configure(&signature)
        let pdf = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x41, count: 191)
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(signatures: [signature]))
        return try XCTUnwrap(ElectronicOriginal.make(sourceName: "zmluva.pdf", sourceData: pdf,
                                                     evidence: evidence).authorizations.first)
    }

    func testAuthorizationKeepsTheVerificationWording() throws {
        var authorization = try authorization()
        authorization.mandate = "advokát"
        authorization.technicalDetail = "The certificate chain is fine."
        authorization.fileEntryName = "a.pdf"
        let model = SignatureRowModel(authorization: authorization, fileName: "a.pdf", showsDocuments: true)

        XCTAssertEqual(model.title, authorization.signerName)
        XCTAssertEqual(model.verdictLabel, "platná", "the E→E list keeps the form's wording")
        XCTAssertEqual(model.tone, .valid)
        XCTAssertEqual(model.lines.first, authorization.type.skName)
        XCTAssertTrue(model.lines.contains { $0.hasPrefix("Podpísané ") })
        XCTAssertTrue(model.lines.contains("Mandát: advokát"))
        let timestamp = try XCTUnwrap(authorization.timestamp)
        XCTAssertTrue(model.lines.contains { $0.hasPrefix("Časová pečiatka ") && $0.contains(timestamp.publisherCommonName) })
        XCTAssertTrue(model.lines.contains("Podpis v súbore a.pdf"))
        XCTAssertTrue(model.lines.contains("Pokrýva " + authorization.documentNames.joined(separator: ", ")))
        XCTAssertEqual(model.technicalDetail, "The certificate chain is fine.")
        XCTAssertEqual(model.id, ZakoVerificationView.detailKey(authorization))
        XCTAssertFalse(model.isNew)
        XCTAssertNil(model.reason, "the verification step says why in its notice above the list")
    }

    func testAuthorizationWithoutTimestampOrFileSaysSo() throws {
        let authorization = try authorization { $0.timestamps = [] }
        let model = SignatureRowModel(authorization: authorization, fileName: nil, showsDocuments: false)
        XCTAssertTrue(model.lines.contains("Bez časovej pečiatky"))
        XCTAssertFalse(model.lines.contains { $0.hasPrefix("Podpis v súbore") })
        XCTAssertFalse(model.lines.contains { $0.hasPrefix("Pokrýva") })
        XCTAssertNil(model.technicalDetail)
    }

    func testAuthorizationStates() throws {
        var authorization = try authorization()
        authorization.state = .invalid
        XCTAssertEqual(SignatureRowModel(authorization: authorization, fileName: nil, showsDocuments: false).tone, .invalid)
        authorization.state = .undetermined
        let undetermined = SignatureRowModel(authorization: authorization, fileName: nil, showsDocuments: false)
        XCTAssertEqual(undetermined.tone, .undetermined)
        XCTAssertEqual(undetermined.symbol, "questionmark.diamond.fill")
        XCTAssertEqual(undetermined.verdictLabel, "nie je možné zistiť")
    }
}
