// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7Kit

/// Guards the wire format between the browser extension and the app.
///
/// These fixtures are JSON exactly as `ditec.js` builds it. A round trip
/// through Swift on both sides proves nothing here: the first version of this
/// contract used an enum with an associated value, which Swift encodes as
/// `{"inline":{"_0":"..."}}` and JavaScript as `{"inline":"..."}`. Swift talking
/// to Swift passed; the real path failed on a state portal.
final class WebSignRequestWireFormatTests: XCTestCase {
    private func decode(_ json: String) throws -> WebSignRequest {
        try JSONDecoder().decode(WebSignRequest.self, from: Data(json.utf8))
    }

    func testDecodesThePdfRequestTheExtensionSends() throws {
        let request = try decode("""
        {
          "requestID": "ditec-1757600000000",
          "filename": "dokument.pdf",
          "content": "JVBERi0xLjQ=",
          "payloadMimeType": "application/pdf;base64",
          "signatureLevel": "PAdES_BASELINE_B"
        }
        """)

        XCTAssertEqual(request.filename, "dokument.pdf")
        XCTAssertEqual(request.content, "JVBERi0xLjQ=")
        XCTAssertEqual(request.signatureLevel, "PAdES_BASELINE_B")
        XCTAssertNil(request.eform)
        XCTAssertTrue(request.isBase64)
    }

    func testDecodesTheEFormRequestTheExtensionSends() throws {
        let request = try decode("""
        {
          "requestID": "ditec-1757600000001",
          "filename": "formular.xml",
          "content": "PFppYWRvc3QvPg==",
          "payloadMimeType": "application/xml;base64",
          "signatureLevel": "XAdES_BASELINE_B",
          "container": "ASiC_E",
          "eform": {
            "containerXmlns": "http://data.gov.sk/def/container/xmldatacontainer+xml/1.1",
            "schema": "<xs:schema/>",
            "transformation": "<xsl:stylesheet/>",
            "identifier": "http://schemas.gov.sk/form/App.GeneralAgenda/1.9",
            "schemaIdentifier": null,
            "transformationIdentifier": null,
            "transformationLanguage": "sk",
            "transformationMediaDestinationTypeDescription": "HTML",
            "transformationTargetEnvironment": null,
            "embedUsedSchemas": true,
            "autoLoadEform": false,
            "fsFormID": null,
            "packaging": "ENVELOPING"
          }
        }
        """)

        let eform = try XCTUnwrap(request.eform)
        XCTAssertEqual(eform.identifier, "http://schemas.gov.sk/form/App.GeneralAgenda/1.9")
        XCTAssertEqual(eform.schema, "<xs:schema/>")
        XCTAssertEqual(eform.transformation, "<xsl:stylesheet/>")
        XCTAssertEqual(eform.transformationMediaDestinationTypeDescription, "HTML")
        XCTAssertTrue(eform.embedUsedSchemas)
        XCTAssertFalse(eform.autoLoadEform)
        XCTAssertEqual(eform.packaging, "ENVELOPING")
        XCTAssertNil(eform.fsFormID)
    }

    /// The optional eForm fields are frequently absent rather than null, because
    /// the shim omits what a portal did not provide.
    func testDecodesAnEFormWithOnlyTheRequiredFields() throws {
        let request = try decode("""
        {
          "requestID": "r",
          "filename": "f.xml",
          "content": "PHgvPg==",
          "payloadMimeType": "application/xml;base64",
          "signatureLevel": "XAdES_BASELINE_B",
          "eform": {
            "containerXmlns": "http://data.gov.sk/def/container/xmldatacontainer+xml/1.1",
            "embedUsedSchemas": false,
            "autoLoadEform": false
          }
        }
        """)

        let eform = try XCTUnwrap(request.eform)
        XCTAssertNil(eform.schema)
        XCTAssertNil(eform.identifier)
    }

    /// nove.slovensko.sk signs a PDF through `dSigXadesBpJs.addPdfObject` and
    /// `getSignatureWithASiCEnvelopeBase64`, which expects a XAdES ASiC-E
    /// container back, not a PAdES PDF.
    func testPdfWithAsicEnvelopeAsksForAContainer() throws {
        let request = try decode("""
        {
          "requestID": "ditec-1757600000002",
          "filename": "Navrhasuhlas.pdf",
          "content": "JVBERi0xLjQ=",
          "payloadMimeType": "application/pdf;base64",
          "signatureLevel": "XAdES_BASELINE_B",
          "container": "ASiC_E"
        }
        """)

        XCTAssertEqual(request.container, "ASiC_E")
        XCTAssertTrue(request.wantsASiCContainer)
    }

    /// Extension builds before the container field still sent XAdES for a PDF.
    /// A PDF has no XAdES form here other than inside ASiC-E.
    func testPdfWithXadesLevelAndNoContainerStillAsksForAContainer() throws {
        let request = try decode("""
        {
          "requestID": "r",
          "filename": "dokument.pdf",
          "content": "JVBERi0xLjQ=",
          "payloadMimeType": "application/pdf;base64",
          "signatureLevel": "XAdES_BASELINE_B"
        }
        """)

        XCTAssertTrue(request.wantsASiCContainer)
    }

    func testPadesPdfStaysAPdf() throws {
        let request = try decode("""
        {
          "requestID": "r",
          "filename": "dokument.pdf",
          "content": "JVBERi0xLjQ=",
          "payloadMimeType": "application/pdf;base64",
          "signatureLevel": "PAdES_BASELINE_B"
        }
        """)

        XCTAssertFalse(request.wantsASiCContainer)
    }

    /// JSON exactly as `ditec.js` builds it for `addTxtObject` (no eform key:
    /// `JSON.stringify` drops the undefined field, Swift decodes it as nil).
    func testTxtDecodesWithoutEformAndAsksForAContainer() throws {
        let request = try decode("""
        {
          "requestID": "ditec-1757600000006",
          "filename": "poznamka.txt",
          "content": "SGVsbG8gd29ybGQ=",
          "payloadMimeType": "text/plain;base64",
          "signatureLevel": "XAdES_BASELINE_B",
          "container": "ASiC_E"
        }
        """)

        XCTAssertNil(request.eform)
        XCTAssertTrue(request.wantsASiCContainer)
        XCTAssertEqual(Data(base64Encoded: request.content).flatMap({ String(data: $0, encoding: .utf8) }), "Hello world")
    }

    /// JSON exactly as `ditec.js` builds it for `addPngObject`.
    func testPngDecodesWithoutEformAndAsksForAContainer() throws {
        let request = try decode("""
        {
          "requestID": "ditec-1757600000007",
          "filename": "obrazok.png",
          "content": "aVBORw0KGgo=",
          "payloadMimeType": "image/png;base64",
          "signatureLevel": "XAdES_BASELINE_B",
          "container": "ASiC_E"
        }
        """)

        XCTAssertNil(request.eform)
        XCTAssertTrue(request.wantsASiCContainer)
    }

    func testEFormAlwaysAsksForAContainer() {
        let request = WebSignRequest(requestID: "r", filename: "f.xml", content: "PHgvPg==",
                                     payloadMimeType: "application/xml;base64",
                                     signatureLevel: "XAdES_BASELINE_B",
                                     eform: EFormSigningAttributes(containerXmlns: "urn:x"))

        XCTAssertTrue(request.wantsASiCContainer)
    }

    /// The content script adds the page host; the page itself cannot set it.
    func testDecodesThePageHostTheContentScriptAdds() throws {
        let request = try decode("""
        {
          "requestID": "r",
          "filename": "dokument.pdf",
          "content": "JVBERi0xLjQ=",
          "payloadMimeType": "application/pdf;base64",
          "signatureLevel": "XAdES_BASELINE_B",
          "container": "ASiC_E",
          "pageHost": "message-constructor-web.slovensko.sk"
        }
        """)

        XCTAssertEqual(request.pageHost, "message-constructor-web.slovensko.sk")
        XCTAssertFalse(request.allowsAddedTimestamp)
    }

    /// nove.slovensko.sk rejects a signature with a timestamp it did not ask for.
    func testSlovenskoSkNeverGetsAnAddedTimestamp() {
        func request(_ host: String?) -> WebSignRequest {
            WebSignRequest(requestID: "r", filename: "f.pdf", content: "", payloadMimeType: "application/pdf;base64",
                           signatureLevel: "XAdES_BASELINE_B", pageHost: host)
        }
        XCTAssertFalse(request("slovensko.sk").allowsAddedTimestamp)
        XCTAssertFalse(request("schranka.slovensko.sk").allowsAddedTimestamp)
        XCTAssertFalse(request("MESSAGE-CONSTRUCTOR-WEB.SLOVENSKO.SK").allowsAddedTimestamp)
        XCTAssertTrue(request("pfseform.financnasprava.sk").allowsAddedTimestamp)
        XCTAssertTrue(request("notslovensko.sk").allowsAddedTimestamp)
        XCTAssertTrue(request(nil).allowsAddedTimestamp)
    }

    func testResponseEncodesTheShapeTheExtensionReads() throws {
        let response = WebSignResponse(requestID: "r", content: "AAA",
                                       signedBy: "CN=Test", issuedBy: "CN=CA")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(response), encoding: .utf8)

        XCTAssertEqual(json, #"{"content":"AAA","issuedBy":"CN=CA","requestID":"r","signedBy":"CN=Test"}"#)
    }
}
