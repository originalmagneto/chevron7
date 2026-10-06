// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7Identity

/// eForm and XML Data Container attributes for a state-portal signing request.
///
/// The field set mirrors the engine's `ServerSigningParameters` so the machine
/// protocol and the engine's own HTTP entry point cannot drift apart. `schema`
/// and `transformation` are the raw XSD and XSLT; they are base64 encoded on
/// the wire, exactly as the engine's HTTP server expects them.
public struct EFormSigningAttributes: Sendable, Equatable, Codable {
    public let containerXmlns: String?
    public let schema: String?
    public let transformation: String?
    public let identifier: String?
    public let schemaIdentifier: String?
    public let transformationIdentifier: String?
    public let transformationLanguage: String?
    public let transformationMediaDestinationTypeDescription: String?
    public let transformationTargetEnvironment: String?
    public let embedUsedSchemas: Bool
    public let autoLoadEform: Bool
    public let fsFormID: String?
    public let packaging: String?

    public static let xmlDataContainerXmlns = "http://data.gov.sk/def/container/xmldatacontainer+xml/1.1"

    public init(
        containerXmlns: String? = xmlDataContainerXmlns,
        schema: String? = nil,
        transformation: String? = nil,
        identifier: String? = nil,
        schemaIdentifier: String? = nil,
        transformationIdentifier: String? = nil,
        transformationLanguage: String? = nil,
        transformationMediaDestinationTypeDescription: String? = nil,
        transformationTargetEnvironment: String? = nil,
        embedUsedSchemas: Bool = false,
        autoLoadEform: Bool = false,
        fsFormID: String? = nil,
        packaging: String? = nil
    ) {
        self.containerXmlns = containerXmlns
        self.schema = schema
        self.transformation = transformation
        self.identifier = identifier
        self.schemaIdentifier = schemaIdentifier
        self.transformationIdentifier = transformationIdentifier
        self.transformationLanguage = transformationLanguage
        self.transformationMediaDestinationTypeDescription = transformationMediaDestinationTypeDescription
        self.transformationTargetEnvironment = transformationTargetEnvironment
        self.embedUsedSchemas = embedUsedSchemas
        self.autoLoadEform = autoLoadEform
        self.fsFormID = fsFormID
        self.packaging = packaging
    }
}

/// Contract shared by the Safari web extension handler and the app.
///
/// Safari delivers `browser.runtime.sendNativeMessage` to a sandboxed app
/// extension, which can neither spawn the signing engine nor reach the card.
/// The extension therefore forwards every request here, over a Mach service the
/// app publishes and the extension is entitled to look up.
public enum WebSigningBridge {
    /// Mach service the app publishes and the extension looks up. The extension
    /// carries `com.apple.security.temporary-exception.mach-lookup.global-name`
    /// for exactly this name, which needs neither a Team ID nor an app group.
    public static let machServiceName = ProductIdentity.webBridgeServiceName

    /// Label of the launchd agent that owns ``machServiceName``.
    public static let agentLabel = ProductIdentity.webBridgeServiceName

    /// Documents travel inline. Measured on 2026-09-11: 16 MB crosses the page,
    /// the extension, the appex, the agent and the app in 151 ms with no ceiling
    /// reached, so no file handover is needed. The cap exists only so a runaway
    /// page cannot wedge the app.
    public static let maximumPayloadBytes = 32 * 1024 * 1024
}

/// Rendezvous published by the launchd agent.
///
/// A plain GUI app cannot publish a named Mach service: launchd owns the name
/// and hands the receive right to the process it launches for it. So a tiny
/// on-demand agent owns the name, the app registers its own anonymous endpoint
/// with it, and the extension asks for that endpoint and then talks to the app
/// directly. The agent is a phone book, not a relay.
@objc public protocol WebBridgeRendezvousProtocol {
    /// Called by the app at launch to publish where it can be reached.
    func registerApp(endpoint: NSXPCListenerEndpoint)

    /// Called by the extension handler to find the running app.
    func appEndpoint(reply: @escaping (NSXPCListenerEndpoint?) -> Void)
}

/// Methods the app exposes to the web extension handler.
///
/// Kept deliberately small: the handler is a relay, not a participant.
@objc public protocol WebSigningBridgeProtocol {
    /// Answers whether the app is ready to sign, so the extension can tell the
    /// page before a document is prepared.
    func status(reply: @escaping (_ ready: Bool, _ version: String) -> Void)

    /// Signs one document. `request` is the JSON encoding of ``WebSignRequest``
    /// and the reply carries the JSON encoding of ``WebSignResponse``.
    ///
    /// The reply waits for the person, so Safari's extension background may be
    /// gone before it arrives. The extension uses ``beginSign(request:reply:)``;
    /// this stays for `webbridge-probe`.
    func sign(request: Data, reply: @escaping (_ response: Data?, _ error: String?) -> Void)

    /// Starts signing one document and answers at once with a job identifier,
    /// or an error when the request cannot be accepted.
    func beginSign(request: Data, reply: @escaping (_ jobID: String?, _ error: String?) -> Void)

    /// Reports a job started by ``beginSign(request:reply:)``: `done` is false while
    /// the person is still signing. A finished result is delivered once.
    func signResult(jobID: String, reply: @escaping (_ done: Bool, _ response: Data?, _ error: String?) -> Void)
}

/// A signing request as it arrives from a state portal, before the app turns it
/// into an engine request.
///
/// Mirrors what the ditec shim gives the extension.
public struct WebSignRequest: Codable, Sendable, Equatable {
    public let requestID: String
    public let filename: String
    /// Base64 document content. A plain field on purpose: an enum with an
    /// associated value encodes as {"inline":{"_0":"..."}} in Swift and as
    /// {"inline":"..."} everywhere else, and the extension is the other side.
    public let content: String
    public let payloadMimeType: String
    public let signatureLevel: String
    public let container: String?
    public let eform: EFormSigningAttributes?
    /// Host of the page that asked, set by the extension's content script from its
    /// own `location`, which the page cannot overwrite.
    public let pageHost: String?

    public init(requestID: String, filename: String, content: String, payloadMimeType: String,
                signatureLevel: String, container: String? = nil,
                eform: EFormSigningAttributes? = nil, pageHost: String? = nil) {
        self.requestID = requestID
        self.filename = filename
        self.content = content
        self.payloadMimeType = payloadMimeType
        self.signatureLevel = signatureLevel
        self.container = container
        self.eform = eform
        self.pageHost = pageHost
    }

    /// True when the payload mime type carries the `;base64` marker the AVM and
    /// the engine's HTTP server both use to mean "content is already encoded".
    public var isBase64: Bool {
        payloadMimeType.replacingOccurrences(of: " ", with: "").hasSuffix(";base64")
    }

    /// True when the page expects a XAdES ASiC-E container back rather than a
    /// PAdES PDF: every eForm, an explicit ASiC container, and any XAdES level,
    /// because a PDF has no XAdES form here other than inside ASiC-E.
    /// Whether the person may add a timestamp the page did not ask for. slovensko.sk
    /// rejects such a signature (nove.slovensko.sk: detach 500, Asic join 422), so
    /// there the page's level is final; other portals keep the choice.
    public var allowsAddedTimestamp: Bool {
        guard let host = pageHost?.lowercased() else { return true }
        return host != "slovensko.sk" && !host.hasSuffix(".slovensko.sk")
    }

    public var wantsASiCContainer: Bool {
        eform != nil
            || container?.uppercased().hasPrefix("ASIC") == true
            || signatureLevel.uppercased().hasPrefix("XADES")
    }
}

/// The signed result handed back to the page.
public struct WebSignResponse: Codable, Sendable, Equatable {
    public let requestID: String
    /// Base64 of the signed container or document.
    public let content: String
    public let signedBy: String
    public let issuedBy: String

    public init(requestID: String, content: String, signedBy: String, issuedBy: String) {
        self.requestID = requestID
        self.content = content
        self.signedBy = signedBy
        self.issuedBy = issuedBy
    }
}
