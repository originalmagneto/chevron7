// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

public struct TimestampAuthority: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var url: String
    public var isQualified: Bool

    public init(name: String, url: String, isQualified: Bool = false) {
        self.name = name
        self.url = url
        self.isQualified = isQualified
    }

    public var id: String { url }

    public static let legacyDefaultURL = bosaURL

    public static let bosaURL = "http://tsa.belgium.be/connect"
    public static let sectigoQualifiedURL = "http://timestamp.sectigo.com/qualified"

    /// The authorities the pickers offer. Every one is qualified, because the pickers sit under
    /// the switch "Kvalifikovaná časová pečiatka (QTS)" and card signing always timestamps.
    public static let builtIn: [TimestampAuthority] = [
        TimestampAuthority(name: "Belgium BOSA (kvalifikovaná)", url: bosaURL, isQualified: true),
        // Upstream Autogram's first default authority (UserSettings.DEFAULT_TSA_SERVER), free and
        // signed by "Sectigo Qualified Time Stamping Signer" of Sectigo (Europe) SL, Spain.
        TimestampAuthority(name: "Sectigo (ES, kvalifikovaná)", url: sectigoQualifiedURL, isQualified: true),
        TimestampAuthority(name: "CA Disig (SK, kvalifikovaná, vyžaduje zmluvu s Disig)", url: "http://tsa.disig.sk/qts", isQualified: true)
    ]

    /// Non-qualified authorities the list once offered. Kept only to recognise them in stored
    /// settings and in a request, so they are never offered, sent or taken for custom servers.
    public static let retiredUnqualified: [TimestampAuthority] = [
        TimestampAuthority(name: "DigiCert (nekvalifikovaná)", url: "http://timestamp.digicert.com"),
        TimestampAuthority(name: "Sectigo (nekvalifikovaná)", url: "http://timestamp.sectigo.com"),
        // Certum's public time.certum.pl signs with "Certum Timestamp 2026" under "Certum
        // Timestamping 2021 CA", which the Polish trusted list does not grant as qualified
        // (its granted units are Certum QTST 2017 and Certum QTSA G3, a paid service).
        TimestampAuthority(name: "Certum (nekvalifikovaná)", url: "http://time.certum.pl")
    ]

    public static func isRetiredUnqualified(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return retiredUnqualified.contains { $0.url.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    public static func isBuiltIn(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return builtIn.contains { $0.url.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Shown under every picker while a custom authority is chosen.
    public static let unverifiedQualificationWarning =
        "Kvalifikáciu vlastnej TSA aplikácia neoverí. Časová pečiatka bude kvalifikovaná, len ak je služba vedená ako kvalifikovaná v dôveryhodnom zozname EÚ."

    public static var fallbackURLs: [URL] {
        qualifiedURLs
    }

    public static var qualifiedURLs: [URL] {
        builtIn.filter(\.isQualified).compactMap { URL(string: $0.url) }
    }

    /// Authorities whose timestamp slovensko.sk does not see in an XAdES signature. Every BOSA
    /// unit signs with ECDSA under an ecdsa-with-SHA384 chain, which the central e-filing
    /// office's XAdES validator does not support, so an ASiC-E from it shows "Predbežne platný"
    /// without a timestamp while a PAdES with the same unit passes (owner's uploads, 2026-10-15,
    /// docs/XADES-TIMESTAMP-SLOVENSKO-SK-FINDINGS-2026-10-15.md).
    public static func isUnseenInXAdES(_ url: String) -> Bool {
        url.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(bosaURL) == .orderedSame
    }

    /// The authority a signature of this format gets for the person's choice: an XAdES (ASiC-E)
    /// signature never takes one slovensko.sk cannot see and gets Sectigo Qualified instead;
    /// PAdES, other built-ins and custom URLs keep the choice.
    public static func authorityURL(forSelected selected: String, signsXAdES: Bool) -> String {
        signsXAdES && isUnseenInXAdES(selected) ? sectigoQualifiedURL : selected
    }

    /// Qualified authorities for XAdES, in the order tried: Sectigo first, never one
    /// slovensko.sk cannot see. ZaKo hands exactly these to the engine.
    public static var xadesQualifiedURLs: [URL] {
        let usable = builtIn.filter { $0.isQualified && !isUnseenInXAdES($0.url) }
        let ordered = usable.filter { $0.url == sectigoQualifiedURL } + usable.filter { $0.url != sectigoQualifiedURL }
        return ordered.compactMap { URL(string: $0.url) }
    }

    /// Shown under the pickers while BOSA is chosen for (or could reach) an ASiC-E signature.
    public static let xadesSubstitutionNote =
        "Podpis ASiC-E (XAdES) dostane časovú pečiatku od Sectigo: pečiatku BOSA v ASiC-E slovensko.sk nezobrazí. PAdES ostáva na BOSA."

    public static func resolveSelected(customServers: [String], selectedTSAURL: String)
        -> [TimestampAuthority] {
        var all = builtIn
        for raw in customServers where !raw.trimmingCharacters(in: .whitespaces).isEmpty
            && !isRetiredUnqualified(raw) {
            let server = raw.trimmingCharacters(in: .whitespaces)
            if !all.contains(where: { $0.url.caseInsensitiveCompare(server) == .orderedSame }) {
                all.append(TimestampAuthority(name: server, url: server))
            }
        }
        return all
    }
}
