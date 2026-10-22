// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import CryptoKit
import XCTest
@testable import Chevron7Kit

final class SignedOutputSignerTests: XCTestCase {
    /// Self-signed P-256, subject C=SK, serialNumber=PNOSK-1234567890, CN=Ing. Ján Testovací.
    private static let signerCertificate = """
        MIIBwjCCAWigAwIBAgIUWdNqdWI51gwcJ2OLY4LQKBK5cEIwCgYIKoZIzj0EAwIwRzELMAkGA1UEBhMCU0sxGTAXBgNVBAUTEFBOT1NLLTEyMzQ1Njc4OTAxHTAbBgNVBAMMFEluZy4gSsOhbiBUZXN0b3ZhY8OtMB4XDTI2MTAyMjEzNTA0NVoXDTM2MTAxOTEzNTA0NVowRzELMAkGA1UEBhMCU0sxGTAXBgNVBAUTEFBOT1NLLTEyMzQ1Njc4OTAxHTAbBgNVBAMMFEluZy4gSsOhbiBUZXN0b3ZhY8OtMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEVKy3REGeCfoqV7EakZymA4COvaPp9jXJ2qVZgS25eghIjE0vT93cahneq5GOv89R2JJJ0kM8nuxpUuQ4LsBKBKMyMDAwHQYDVR0OBBYEFFqCGkaIO3Z5gNhn5l3OFFzL7BNqMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIhAP5N2/8Sehut6tsMkjQZc6274P8R8jNdJo2nGx/NW+BoAiAzpFPolTCaRAKzZDj/ERlJAV9JnCZAMceEO3twvW1y3w==
        """
    /// Self-signed P-256, subject CN=Test Qualified CA.
    private static let caCertificate = """
        MIIBozCCAUqgAwIBAgIUfAz9+ejLqrOml8daoa+OmV05TcwwCgYIKoZIzj0EAwIwODELMAkGA1UEBhMCU0sxDTALBgNVBAoMBFRlc3QxGjAYBgNVBAMMEVRlc3QgUXVhbGlmaWVkIENBMB4XDTI2MTAyMjEzNTA0NVoXDTM2MTAxOTEzNTA0NVowODELMAkGA1UEBhMCU0sxDTALBgNVBAoMBFRlc3QxGjAYBgNVBAMMEVRlc3QgUXVhbGlmaWVkIENBMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEpjCBi5qGzx0ySWvXNxQDkMSws9Ri976bwAnD+UKxo5tG7HFE39B6iI5sbkoOJXoeIe+LrBas19s5jcsXLByqjKMyMDAwHQYDVR0OBBYEFFVi26bLemlmO+Gv3dAVWgb5AVkLMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDRwAwRAIgVKe5hKjVG5r5uRM+em5qAwfMtVLk2TuaYQqAQMrzfBMCIEMVzvUpjt9nl4WBoVbx65RxxelN6WVPr04mKEEcSgNB
        """

    private func signatureXML(keyInfo: [String], signingCertificate: String?) -> String {
        let certificates = keyInfo.map { "<ds:X509Certificate>\($0)</ds:X509Certificate>" }.joined()
        let property = signingCertificate.map { base64 -> String in
            let digest = Data(SHA256.hash(data: Data(base64Encoded: base64)!)).base64EncodedString()
            return """
                <xades:SignedProperties><xades:SignedSignatureProperties><xades:SigningCertificateV2>\
                <xades:Cert><xades:CertDigest>\
                <ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/>\
                <ds:DigestValue>\(digest)</ds:DigestValue>\
                </xades:CertDigest></xades:Cert></xades:SigningCertificateV2>\
                </xades:SignedSignatureProperties></xades:SignedProperties>
                """
        } ?? ""
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <asic:XAdESSignatures xmlns:asic="http://uri.etsi.org/02918/v1.2.1#" \
            xmlns:ds="http://www.w3.org/2000/09/xmldsig#" xmlns:xades="http://uri.etsi.org/01903/v1.3.2#">
            <ds:Signature Id="id-1"><ds:SignedInfo/><ds:SignatureValue>AA==</ds:SignatureValue>
            <ds:KeyInfo><ds:X509Data>\(certificates)</ds:X509Data></ds:KeyInfo>
            <ds:Object><xades:QualifyingProperties>\(property)</xades:QualifyingProperties></ds:Object>
            </ds:Signature></asic:XAdESSignatures>
            """
    }

    private func container(_ signatures: [String: String]) throws -> Data {
        var entries: [ASiCEPackager.Entry] = [
            .init(path: "mimetype", data: Data(ASiCEPackager.asicMimeType.utf8), storeUncompressed: true),
            .init(path: "formular.xml", data: Data("<dokument/>".utf8))
        ]
        for (name, xml) in signatures.sorted(by: { $0.key < $1.key }) {
            entries.append(.init(path: name, data: Data(xml.utf8)))
        }
        return try ASiCEPackager().package(files: entries)
    }

    func testContainerNamesTheSigningCertificateNotTheChainBeforeIt() throws {
        let xml = signatureXML(keyInfo: [Self.caCertificate, Self.signerCertificate],
                               signingCertificate: Self.signerCertificate)
        let asic = try container(["META-INF/signatures001.xml": xml])

        XCTAssertEqual(SignedOutputSigner.commonName(in: asic), "Ing. Ján Testovací")
    }

    func testWithoutSigningCertificatePropertyTheFirstKeyInfoCertificateCounts() throws {
        let xml = signatureXML(keyInfo: [Self.signerCertificate, Self.caCertificate], signingCertificate: nil)

        XCTAssertEqual(SignedOutputSigner.commonName(in: Data(xml.utf8)), "Ing. Ján Testovací")
    }

    func testNewestSignatureFileDecides() throws {
        let older = signatureXML(keyInfo: [Self.caCertificate], signingCertificate: Self.caCertificate)
        let newer = signatureXML(keyInfo: [Self.signerCertificate], signingCertificate: Self.signerCertificate)
        let asic = try container(["META-INF/signatures001.xml": older,
                                  "META-INF/signatures002.xml": newer])

        XCTAssertEqual(SignedOutputSigner.commonName(in: asic), "Ing. Ján Testovací")
    }

    func testOutputWithoutCertificateNamesNobody() throws {
        XCTAssertNil(SignedOutputSigner.commonName(in: Data("%PDF-1.7".utf8)))
        XCTAssertNil(SignedOutputSigner.commonName(in: Data("<dokument/>".utf8)))
        XCTAssertNil(SignedOutputSigner.commonName(in: try container([:])))
    }
}
