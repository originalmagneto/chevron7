// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Security
import CryptoKit

public enum XAdESError: LocalizedError, Sendable {
    case certificateUnavailable
    case keyUnavailable
    case unsupportedKeyType
    case signingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .certificateUnavailable: return "Certifikát identity sa nepodarilo načítať."
        case .keyUnavailable: return "Súkromný kľúč certifikátu nie je dostupný (karta odpojená alebo zamietnutý PIN)."
        case .unsupportedKeyType: return "Nepodporovaný typ kľúča podpisového certifikátu."
        case .signingFailed(let detail): return "Kryptografická operácia zlyhala: \(detail)"
        }
    }
}

public struct XAdESResult: Sendable {
    public var signatureXML: String
    public var timestampGenTime: Date?
}

public struct XAdESSigner: Sendable {
    public struct DataObject: Sendable {
        public var uri: String
        public var mimeType: String
        public var data: Data

        public init(uri: String, mimeType: String, data: Data) {
            self.uri = uri
            self.mimeType = mimeType
            self.data = data
        }
    }

    public init() {}

    static let dsNS = "http://www.w3.org/2000/09/xmldsig#"
    static let xadesNS = "http://uri.etsi.org/01903/v1.3.2#"
    static let asicNS = "http://uri.etsi.org/02918/v1.2.1#"
    static let sha256DigestMethod = "http://www.w3.org/2001/04/xmlenc#sha256"
    static let sha512DigestMethod = "http://www.w3.org/2001/04/xmlenc#sha512"
    static let excC14N = "http://www.w3.org/2001/10/xml-exc-c14n#"

    public func sign(dataObjects: [DataObject],
                     certificate: SecCertificate,
                     signer: RawSigner,
                     includeTimestamp: Bool,
                     tsaURL: URL?) async throws -> XAdESResult {
        let signatureMethod = signer.signatureMethodURI

        let certificateDER = Data(SecCertificateCopyData(certificate) as Data)
        guard let facts = X509Inspector.facts(certificateData: certificateDER) else {
            throw XAdESError.certificateUnavailable
        }

        let signatureID = "id-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let signedPropsID = "xades-\(signatureID)"
        let timeFormatter = ISO8601DateFormatter()
        timeFormatter.formatOptions = [.withInternetDateTime]
        timeFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let signingTime = timeFormatter.string(from: Date())

        var references = ""
        var dataObjectFormats = ""
        for (index, object) in dataObjects.enumerated() {
            let refID = "r-\(signatureID)-\(index + 1)"
            let digest = Data(SHA256.hash(data: object.data)).base64EncodedString()
            references += "<ds:Reference Id=\"\(refID)\" URI=\"\(Self.uriEscaped(object.uri))\"><ds:DigestMethod Algorithm=\"\(Self.sha256DigestMethod)\"></ds:DigestMethod><ds:DigestValue>\(digest)</ds:DigestValue></ds:Reference>"
            dataObjectFormats += "<xades:DataObjectFormat ObjectReference=\"#\(refID)\"><xades:MimeType>\(object.mimeType)</xades:MimeType></xades:DataObjectFormat>"
        }

        let signedPropertiesDocument =
            "<xades:SignedProperties Id=\"\(signedPropsID)\">" +
            "<xades:SignedSignatureProperties>" +
            "<xades:SigningTime>\(signingTime)</xades:SigningTime>" +
            "<xades:SigningCertificate><xades:Cert>" +
            "<xades:CertDigest><ds:DigestMethod Algorithm=\"\(Self.sha512DigestMethod)\"></ds:DigestMethod>" +
            "<ds:DigestValue>\(Data(SHA512.hash(data: certificateDER)).base64EncodedString())</ds:DigestValue></xades:CertDigest>" +
            "<xades:IssuerSerial><ds:X509IssuerName>\(Self.escapeXML(facts.issuerRFC2253))</ds:X509IssuerName>" +
            "<ds:X509SerialNumber>\(facts.serialNumberDecimal)</ds:X509SerialNumber></xades:IssuerSerial>" +
            "</xades:Cert></xades:SigningCertificate></xades:SignedSignatureProperties>" +
            "<xades:SignedDataObjectProperties>\(dataObjectFormats)</xades:SignedDataObjectProperties>" +
            "</xades:SignedProperties>"

        let signedPropertiesC14N = Self.exclusiveC14N(
            signedPropertiesDocument,
            namespaces: [("ds", Self.dsNS), ("xades", Self.xadesNS)])
        let signedPropertiesDigest = Data(SHA256.hash(data: Data(signedPropertiesC14N.utf8))).base64EncodedString()

        let signedInfoDocument =
            "<ds:SignedInfo>" +
            "<ds:CanonicalizationMethod Algorithm=\"\(Self.excC14N)\"></ds:CanonicalizationMethod>" +
            "<ds:SignatureMethod Algorithm=\"\(signatureMethod)\"></ds:SignatureMethod>" +
            references +
            "<ds:Reference Type=\"http://uri.etsi.org/01903#SignedProperties\" URI=\"#\(signedPropsID)\">" +
            "<ds:Transforms><ds:Transform Algorithm=\"\(Self.excC14N)\"></ds:Transform></ds:Transforms>" +
            "<ds:DigestMethod Algorithm=\"\(Self.sha256DigestMethod)\"></ds:DigestMethod>" +
            "<ds:DigestValue>\(signedPropertiesDigest)</ds:DigestValue></ds:Reference></ds:SignedInfo>"

        let canonicalSignedInfo = Self.exclusiveC14N(signedInfoDocument, namespaces: [("ds", Self.dsNS)])
        let signatureValue = try signer.sign(Data(canonicalSignedInfo.utf8))

        var unsignedBlock = ""
        var timestampGenTime: Date?
        if includeTimestamp, let tsaURL, !tsaURL.absoluteString.isEmpty {
            let signatureValueElement =
                "<ds:SignatureValue Id=\"value-\(signatureID)\">\(signatureValue.base64EncodedString())</ds:SignatureValue>"
            let signatureValueC14N = Self.exclusiveC14N(signatureValueElement, namespaces: [("ds", Self.dsNS)])
            let reply = try await RFC3161TimestampClient().requestToken(
                for: Data(signatureValueC14N.utf8),
                tsaURL: URL(string: TimestampAuthority.authorityURL(forSelected: tsaURL.absoluteString,
                                                                     signsXAdES: true)) ?? tsaURL,
                fallbacks: TimestampAuthority.xadesQualifiedURLs)
            timestampGenTime = reply.genTime
            let tsID = "TS-" + UUID().uuidString.lowercased()
            unsignedBlock =
                "<xades:UnsignedProperties><xades:UnsignedSignatureProperties>" +
                "<xades:SignatureTimeStamp Id=\"\(tsID)\">" +
                "<ds:CanonicalizationMethod Algorithm=\"\(Self.excC14N)\"></ds:CanonicalizationMethod>" +
                "<xades:EncapsulatedTimeStamp Id=\"ETS-\(tsID)\">\(reply.token.base64EncodedString())</xades:EncapsulatedTimeStamp>" +
                "</xades:SignatureTimeStamp></xades:UnsignedSignatureProperties></xades:UnsignedProperties>"
        }

        let xml =
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>" +
            "<asic:XAdESSignatures xmlns:asic=\"\(Self.asicNS)\">" +
            "<ds:Signature xmlns:ds=\"\(Self.dsNS)\" Id=\"\(signatureID)\">" +
            canonicalSignedInfo +
            "<ds:SignatureValue Id=\"value-\(signatureID)\">\(signatureValue.base64EncodedString())</ds:SignatureValue>" +
            "<ds:KeyInfo><ds:X509Data><ds:X509Certificate>\(certificateDER.base64EncodedString())</ds:X509Certificate></ds:X509Data></ds:KeyInfo>" +
            "<ds:Object><xades:QualifyingProperties xmlns:xades=\"\(Self.xadesNS)\" Target=\"#\(signatureID)\">" +
            signedPropertiesDocument + unsignedBlock +
            "</xades:QualifyingProperties></ds:Object></ds:Signature></asic:XAdESSignatures>"


        return XAdESResult(signatureXML: xml, timestampGenTime: timestampGenTime)
    }

    static func exclusiveC14N(_ xml: String, namespaces: [(String, String)]) -> String {
        let nsMap = Dictionary(uniqueKeysWithValues: namespaces)
        let expanded = expandEmptyElements(xml)
        var result = ""
        var index = expanded.startIndex
        var scope: [[String: String]] = [[:]]

        while index < expanded.endIndex {
            if expanded[index] == "<" {
                guard let gt = expanded[index...].firstIndex(of: ">") else { break }
                let afterLt = expanded.index(after: index)
                let isClose = afterLt < expanded.endIndex && expanded[afterLt] == "/"
                if isClose {
                    result.append(contentsOf: expanded[index...gt])
                    if scope.count > 1 { scope.removeLast() }
                    index = expanded.index(after: gt)
                    continue
                }
                guard let nameEnd = expanded[afterLt...].firstIndex(where: { $0 == " " || $0 == ">" }) else { break }
                let qname = String(expanded[afterLt..<nameEnd])
                let prefix = qname.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                var declared = scope.last ?? [:]
                var extra = ""
                if let uri = nsMap[prefix], declared[prefix] != uri {
                    extra += " xmlns:\(prefix)=\"\(uri)\""
                    declared[prefix] = uri
                }
                result += "<\(qname)\(extra)"
                result.append(contentsOf: expanded[nameEnd...gt])
                scope.append(declared)
                index = expanded.index(after: gt)
                continue
            }
            result.append(expanded[index])
            index = expanded.index(after: index)
        }
        return result
    }

    static func expandEmptyElements(_ xml: String) -> String {
        var result = ""
        var index = xml.startIndex
        while index < xml.endIndex {
            if xml[index] == "<",
               let close = xml[index...].firstIndex(of: ">") {
                let tag = xml[index...close]
                if tag.hasPrefix("</") || tag.hasPrefix("<?") || tag.hasPrefix("<!") {
                    result.append(contentsOf: tag)
                } else if tag.hasSuffix("/>") {
                    let body = tag.dropFirst().dropLast(2)
                    let name = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                        .first.map(String.init) ?? String(body)
                    result += "<\(body)></\(name)>"
                } else {
                    result.append(contentsOf: tag)
                }
                index = xml.index(after: close)
                continue
            }
            result.append(xml[index])
            index = xml.index(after: index)
        }
        return result
    }

    static func uriEscaped(_ uri: String) -> String {
        uri.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn:
                "/._-ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")) ?? uri
    }

    static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

}
