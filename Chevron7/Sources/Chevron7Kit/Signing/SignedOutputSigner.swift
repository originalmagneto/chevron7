// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import CryptoKit
import Foundation
import Security

/// Reads who signed a XAdES output from the certificate inside it. An eID signs
/// without its certificate being read first (a second BOK prompt), so the
/// provider only knows "Občiansky preukaz (eID)"; the signed output always
/// carries the certificate itself.
public enum SignedOutputSigner {
    /// The common name of the certificate behind the newest XAdES signature in
    /// an ASiC-E container or a bare XAdES document, or nil when there is none.
    public static func commonName(in signed: Data) -> String? {
        guard let certificate = signingCertificate(in: signed) else { return nil }
        var name: CFString?
        guard SecCertificateCopyCommonName(certificate, &name) == errSecSuccess,
              let commonName = (name as String?)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !commonName.isEmpty else { return nil }
        return commonName
    }

    static func signingCertificate(in signed: Data) -> SecCertificate? {
        guard let xml = newestSignatureXML(in: signed),
              let document = try? XMLDocument(data: xml) else { return nil }
        var keyInfoCertificates: [Data] = []
        var signingDigests: [(algorithm: String, value: Data)] = []
        collect(document.rootElement(), certificates: &keyInfoCertificates, digests: &signingDigests)
        guard !keyInfoCertificates.isEmpty else { return nil }

        // The signed SigningCertificate(V2) property names the signer's certificate
        // by digest; KeyInfo may also carry the issuing chain.
        let matched = keyInfoCertificates.first { der in
            signingDigests.contains { digest in
                Self.digest(der, algorithm: digest.algorithm) == digest.value
            }
        }
        guard let der = matched ?? keyInfoCertificates.first else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    /// The highest numbered META-INF signature file of a container, or the
    /// document itself when it is XML.
    private static func newestSignatureXML(in signed: Data) -> Data? {
        if signed.starts(with: Data([0x50, 0x4B, 0x03, 0x04])) {
            guard let entries = ASiCEContainerVerifier.readEntries(signed) else { return nil }
            return entries
                .filter { $0.name.hasPrefix("META-INF/") && $0.name.lowercased().contains("signatures")
                    && $0.name.lowercased().hasSuffix(".xml") }
                .max { $0.name.localizedStandardCompare($1.name) == .orderedAscending }?
                .data
        }
        let head = signed.prefix(64).drop { [0xEF, 0xBB, 0xBF, 0x20, 0x09, 0x0A, 0x0D].contains($0) }
        return head.first == UInt8(ascii: "<") ? signed : nil
    }

    private static func collect(_ element: XMLElement?, certificates: inout [Data],
                                digests: inout [(algorithm: String, value: Data)]) {
        guard let element else { return }
        switch element.localName {
        case "X509Certificate" where element.parent?.parent?.localName == "KeyInfo":
            if let text = element.stringValue,
               let der = Data(base64Encoded: text, options: .ignoreUnknownCharacters) {
                certificates.append(der)
            }
        case "CertDigest":
            let children = element.children?.compactMap { $0 as? XMLElement } ?? []
            if let algorithm = children.first(where: { $0.localName == "DigestMethod" })?
                    .attribute(forName: "Algorithm")?.stringValue,
               let text = children.first(where: { $0.localName == "DigestValue" })?.stringValue,
               let value = Data(base64Encoded: text, options: .ignoreUnknownCharacters) {
                digests.append((algorithm, value))
            }
        default:
            break
        }
        for child in element.children ?? [] {
            collect(child as? XMLElement, certificates: &certificates, digests: &digests)
        }
    }

    private static func digest(_ data: Data, algorithm: String) -> Data? {
        switch algorithm {
        case "http://www.w3.org/2001/04/xmlenc#sha256": return Data(SHA256.hash(data: data))
        case "http://www.w3.org/2001/04/xmldsig-more#sha384": return Data(SHA384.hash(data: data))
        case "http://www.w3.org/2001/04/xmlenc#sha512": return Data(SHA512.hash(data: data))
        case "http://www.w3.org/2000/09/xmldsig#sha1": return Data(Insecure.SHA1.hash(data: data))
        default: return nil
        }
    }
}
