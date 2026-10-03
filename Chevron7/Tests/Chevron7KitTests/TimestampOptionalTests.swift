// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7Kit

/// The timestamp is optional as in upstream Autogram, and its qualification is reported,
/// never enforced, for the app's own signatures.
final class TimestampOptionalTests: XCTestCase {
    private func request(includeTimestamp: Bool, override: String? = nil) -> SigningRequest {
        SigningRequest(pdfData: Data("d".utf8), identityID: "x", includeTimestamp: includeTimestamp,
                       signatureLevelOverride: override)
    }

    func testTheSwitchOffSignsBaselineB() {
        XCTAssertEqual(EngineBridgeSigningProvider.untimestampedLevel(
            for: request(includeTimestamp: false), wantsPAdES: true, sourceIsContainer: false), "PAdES_BASELINE_B")
        XCTAssertEqual(EngineBridgeSigningProvider.untimestampedLevel(
            for: request(includeTimestamp: false), wantsPAdES: false, sourceIsContainer: false), "XAdES_BASELINE_B")
    }

    /// With a timestamp (ZaKo, the switch on) nothing changes: the output format's Baseline T.
    func testATimestampedRequestKeepsBaselineT() {
        XCTAssertNil(EngineBridgeSigningProvider.untimestampedLevel(
            for: request(includeTimestamp: true), wantsPAdES: true, sourceIsContainer: false))
    }

    /// A portal's own level wins, and an existing container is always extended at Baseline T.
    func testAPortalLevelAndAnExistingContainerAreLeftAlone() {
        XCTAssertNil(EngineBridgeSigningProvider.untimestampedLevel(
            for: request(includeTimestamp: false, override: "XAdES_BASELINE_B"), wantsPAdES: false,
            sourceIsContainer: false))
        XCTAssertNil(EngineBridgeSigningProvider.untimestampedLevel(
            for: request(includeTimestamp: false), wantsPAdES: false, sourceIsContainer: true))
    }

    func testTheEngineProviderNoLongerForcesATimestamp() {
        XCTAssertFalse(EngineBridgeSigningProvider().alwaysAddsQualifiedTimestamp)
    }

    func testFileCompletedCarriesTheTimestampVerdict() {
        XCTAssertEqual(AutogramCLIEngine.timestampQualification(in: ["timestampQualification": .string("qualified")]),
                       .qualified)
        XCTAssertEqual(AutogramCLIEngine.timestampQualification(in: ["timestampQualification": .string("notQualified")]),
                       .notQualified)
        XCTAssertEqual(AutogramCLIEngine.timestampQualification(in: [
            "timestampQualification": .string("unverified"), "country": .string("be")]),
                       .unverified(country: "BE"))
        XCTAssertNil(AutogramCLIEngine.timestampQualification(in: [:]))
        XCTAssertNil(AutogramCLIEngine.timestampQualification(in: ["timestampQualification": .string("other")]))
    }

    func testTheVerdictsReadAsSlovakSentencesWithoutEmDashes() {
        let unverified = TimestampQualification.unverified(country: "BE").slovakDescription
        XCTAssertTrue(unverified.contains("Belgick"), unverified)
        XCTAssertTrue(TimestampQualification.notQualified.slovakDescription.contains("Podpis je platný"))
        for verdict in [TimestampQualification.qualified, .notQualified, .unverified(country: nil),
                        .unverified(country: "BE")] {
            XCTAssertFalse(verdict.slovakDescription.contains("\u{2014}"))
        }
    }

    /// Upstream Autogram's first default authority is offered again, and ZaKo may fall back to it.
    func testSectigoQualifiedIsOfferedAndSentAsQualified() {
        XCTAssertTrue(TimestampAuthority.isBuiltIn("http://timestamp.sectigo.com/qualified"))
        XCTAssertTrue(TimestampAuthority.qualifiedURLs.map(\.absoluteString)
            .contains("http://timestamp.sectigo.com/qualified"))
        XCTAssertTrue(TimestampAuthority.isRetiredUnqualified("http://timestamp.sectigo.com"))
    }
}
