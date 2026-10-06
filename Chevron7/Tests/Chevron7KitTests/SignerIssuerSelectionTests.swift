// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7Kit

/// The issuer a portal receives as `issuedBy` (and the done screen shows as "Vydal"):
/// the signed result's own, else a certificate read from the card, never a prompt.
final class SignerIssuerSelectionTests: XCTestCase {
    private let synthetic = EngineBridgeSigningProvider.syntheticIdentity(driverNames: ["I.CA"], driverID: "ica")
    private let resolved = SigningIdentityInfo(id: "\(EngineBridgeSigningProvider.certificateIdentityPrefix)1042",
                                               label: "Marián Čuprík OPRÁVNENIE 1042",
                                               issuerSummary: "I.CA EU Qualified CA-SK/RSA 10/2022",
                                               isMandateCertificate: true, isQualified: true, requiresPIN: true)

    private func result(signerIssuer: String?) -> SignedConversionResult {
        SignedConversionResult(pdfData: Data(), asicData: nil, signedAt: Date(),
                               signatureLabel: "Marián Čuprík OPRÁVNENIE 1042", isLegallyBinding: true,
                               signerIssuer: signerIssuer)
    }

    func testSignedResultIssuerWinsOverTheIdentity() {
        XCTAssertEqual(result(signerIssuer: "CA Disig QCA3").issuerName(fallback: synthetic), "CA Disig QCA3")
        XCTAssertEqual(result(signerIssuer: "CA Disig QCA3").issuerName(fallback: resolved), "CA Disig QCA3")
    }

    /// The 2026-10-06 probe: a card picked from the reader poll gave the page
    /// "Zadajte PIN pre načítanie certifikátov" as its issuer.
    func testSyntheticIdentityNeverLendsItsPrompt() {
        XCTAssertFalse(synthetic.describesCertificate)
        XCTAssertEqual(result(signerIssuer: nil).issuerName(fallback: synthetic), "")
        XCTAssertEqual(result(signerIssuer: "  ").issuerName(fallback: synthetic), "")
        XCTAssertNotEqual(result(signerIssuer: nil).issuerName(fallback: synthetic), synthetic.issuerSummary)
    }

    func testResolvedIdentityFillsInWhenTheResultKnowsNoIssuer() {
        XCTAssertTrue(resolved.describesCertificate)
        XCTAssertEqual(result(signerIssuer: nil).issuerName(fallback: resolved), "I.CA EU Qualified CA-SK/RSA 10/2022")
        XCTAssertEqual(result(signerIssuer: "").issuerName(fallback: resolved), "I.CA EU Qualified CA-SK/RSA 10/2022")
    }

    func testNoIssuerAndNoIdentityIsEmpty() {
        XCTAssertEqual(result(signerIssuer: nil).issuerName(fallback: nil), "")
    }

    /// The phone's result carries the issuer its signers report.
    func testPhoneResultCarriesTheSignersIssuer() throws {
        let document = AVMSignedDocument(filename: "a.pdf", mimeType: "application/pdf",
                                         content: Data("SIGNED".utf8).base64EncodedString(),
                                         signers: [AVMSigner(signedBy: "Ján Novák", issuedBy: "SVK eID ACA2")])
        let signed = try AVMResultMapper.conversionResult(from: document, outputFormat: .embeddedPAdES,
                                                          uploadedPDF: Data())
        XCTAssertEqual(signed.issuerName(fallback: synthetic), "SVK eID ACA2")
    }
}
