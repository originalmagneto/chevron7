// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7WebBridge

// Connects to the Mach service the running app publishes and calls status.
// Proves the app half of the Safari bridge without Safari, which is the only
// part of the chain that cannot be automated: enabling an unsigned extension is
// an in-memory Safari setting with no preference key.

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 1
// Tearing the connection down at the end fires the invalidation handler too,
// and reporting that as a failure would contradict the result just printed.
nonisolated(unsafe) var finished = false

let agent = NSXPCConnection(machServiceName: WebSigningBridge.machServiceName, options: [])
agent.remoteObjectInterface = NSXPCInterface(with: WebBridgeRendezvousProtocol.self)
agent.resume()

agent.interruptionHandler = {
    guard !finished else { return }
    FileHandle.standardError.write(Data("XPC spojenie prerušené: appka pravdepodobne nebeží.\n".utf8))
    semaphore.signal()
}
agent.invalidationHandler = {
    guard !finished else { return }
    FileHandle.standardError.write(Data("XPC spojenie neplatné: služba \(WebSigningBridge.machServiceName) nie je publikovaná.\n".utf8))
    semaphore.signal()
}

guard let rendezvous = agent.remoteObjectProxyWithErrorHandler({ error in
    FileHandle.standardError.write(Data("XPC chyba: \(error.localizedDescription)\n".utf8))
    semaphore.signal()
}) as? WebBridgeRendezvousProtocol else {
    FileHandle.standardError.write(Data("Nepodarilo sa získať proxy agenta.\n".utf8))
    exit(1)
}

rendezvous.appEndpoint { endpoint in
    guard let endpoint else {
        FileHandle.standardError.write(Data("Agent beží, ale Chevron7 sa nepodarilo spustiť ani po 20 s.\n".utf8))
        semaphore.signal()
        return
    }
    let app = NSXPCConnection(listenerEndpoint: endpoint)
    app.remoteObjectInterface = NSXPCInterface(with: WebSigningBridgeProtocol.self)
    app.resume()
    guard let proxy = app.remoteObjectProxyWithErrorHandler({ error in
        FileHandle.standardError.write(Data("Spojenie s aplikáciou zlyhalo: \(error.localizedDescription)\n".utf8))
        semaphore.signal()
    }) as? WebSigningBridgeProtocol else {
        semaphore.signal()
        return
    }
    if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--sign" {
        let path = CommandLine.arguments[2]
        guard let data = FileManager.default.contents(atPath: path) else {
            FileHandle.standardError.write(Data("Nepodarilo sa prečítať \(path)\n".utf8))
            semaphore.signal()
            return
        }
        let isXML = path.lowercased().hasSuffix(".xml")
        // A finished XML Data Container goes as addXmlObject2 sends it: the engine
        // takes the schema and transformation from the container itself.
        let isXDC = path.lowercased().hasSuffix(".xdcf")
        // Every "--attach <file>" after the document joins the same signature, as
        // schranka adds several documents before it signs.
        var attachments: [WebSignAttachment] = []
        var index = 3
        while index + 1 < CommandLine.arguments.count, CommandLine.arguments[index] == "--attach" {
            let attachmentPath = CommandLine.arguments[index + 1]
            guard let attachmentData = FileManager.default.contents(atPath: attachmentPath) else {
                FileHandle.standardError.write(Data("Nepodarilo sa prečítať \(attachmentPath)\n".utf8))
                semaphore.signal()
                return
            }
            attachments.append(WebSignAttachment(
                filename: (attachmentPath as NSString).lastPathComponent,
                content: attachmentData.base64EncodedString(),
                payloadMimeType: probeMimeType(for: attachmentPath)))
            index += 2
        }
        // An XML payload is treated as a state-portal eForm, with a self-contained
        // namespace so no registry lookup happens.
        let eform: EFormSigningAttributes? = isXML ? EFormSigningAttributes(
            schema: """
            <?xml version="1.0" encoding="UTF-8"?>
            <xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns="http://probe.local/form/1.0"             targetNamespace="http://probe.local/form/1.0" elementFormDefault="qualified">            <xs:element name="Ziadost"><xs:complexType><xs:sequence>            <xs:element name="Meno" type="xs:string"/></xs:sequence></xs:complexType></xs:element></xs:schema>
            """,
            transformation: """
            <?xml version="1.0" encoding="UTF-8"?>
            <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"             xmlns:z="http://probe.local/form/1.0"><xsl:template match="/"><html><body><h1>            <xsl:value-of select="z:Ziadost/z:Meno"/></h1></body></html></xsl:template></xsl:stylesheet>
            """,
            identifier: "http://probe.local/form/1.0",
            transformationLanguage: "sk",
            transformationMediaDestinationTypeDescription: "HTML",
            transformationTargetEnvironment: "probe",
            embedUsedSchemas: true,
            packaging: "ENVELOPING")
            : isXDC ? EFormSigningAttributes(embedUsedSchemas: true, packaging: "ENVELOPING") : nil
        let wantsContainer = isXML || isXDC || !attachments.isEmpty
        let request = WebSignRequest(
            requestID: UUID().uuidString,
            filename: (path as NSString).lastPathComponent,
            content: data.base64EncodedString(),
            payloadMimeType: probeMimeType(for: path),
            signatureLevel: wantsContainer ? "XAdES_BASELINE_B" : "PAdES_BASELINE_T",
            container: wantsContainer ? "ASiC_E" : nil,
            eform: eform,
            attachments: attachments.isEmpty ? nil : attachments)
        print("Posielam požiadavku na podpis: \(request.filename) (\(data.count) B)"
              + (attachments.isEmpty ? "" : " a \(attachments.count) ďalšie dokumenty"))
        print("V aplikácii sa má otvoriť okno so žiadosťou o PIN.")
        proxy.sign(request: try! JSONEncoder().encode(request)) { response, error in
            if let error {
                FileHandle.standardError.write(Data("Podpis zlyhal: \(error)\n".utf8))
                semaphore.signal()
                return
            }
            guard let response,
                  let decoded = try? JSONDecoder().decode(WebSignResponse.self, from: response),
                  let signed = Data(base64Encoded: decoded.content) else {
                FileHandle.standardError.write(Data("Odpoveď sa nepodarilo prečítať.\n".utf8))
                semaphore.signal()
                return
            }
            let out = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("webbridge-signed-\(decoded.requestID.prefix(8))")
                .appendingPathExtension(wantsContainer ? "asice" : "pdf")
            try? signed.write(to: out)
            print("Podpísané: \(decoded.signedBy)")
            print("Vydal    : \(decoded.issuedBy)")
            print("Súbor    : \(out.path) (\(signed.count) B)")
            exitCode = 0
            finished = true
            semaphore.signal()
        }
        return
    }

    proxy.status { ready, version in
        print("Mach service : \(WebSigningBridge.machServiceName) (launchd agent)")
        print("Chevron7     : \(version)")
        print("Ready to sign: \(ready ? "áno" : "nie (sign handler nie je zapojený)")")
        print("")
        print("Transport funguje: agent našiel aplikáciu a tá odpovedala cez XPC.")
        exitCode = 0
        finished = true
        semaphore.signal()
    }
}

/// The payload type ditec.js would send for a file of this name.
func probeMimeType(for path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "xml": return "application/xml;base64"
    case "xdcf": return "application/vnd.gov.sk.xmldatacontainer+xml;base64"
    case "txt": return "text/plain;base64"
    case "png": return "image/png;base64"
    default: return "application/pdf;base64"
    }
}

_ = semaphore.wait(timeout: .now() + 300)
agent.invalidate()
exit(exitCode)
