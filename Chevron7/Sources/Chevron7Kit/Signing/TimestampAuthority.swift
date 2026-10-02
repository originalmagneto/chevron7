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

    public static let legacyDefaultURL = "http://tsa.belgium.be/connect"

    public static let builtIn: [TimestampAuthority] = [
        TimestampAuthority(name: "Belgium BOSA (kvalifikovaná)", url: "http://tsa.belgium.be/connect", isQualified: true),
        TimestampAuthority(name: "Certum (PL)", url: "http://time.certum.pl", isQualified: true),
        TimestampAuthority(name: "CA Disig (SK, kvalifikovaná, vyžaduje zmluvu s Disig)", url: "http://tsa.disig.sk/qts", isQualified: true),
        TimestampAuthority(name: "DigiCert (nekvalifikovaná)", url: "http://timestamp.digicert.com", isQualified: false),
        TimestampAuthority(name: "Sectigo (nekvalifikovaná)", url: "http://timestamp.sectigo.com", isQualified: false)
    ]

    public static var fallbackURLs: [URL] {
        qualifiedURLs
    }

    public static var qualifiedURLs: [URL] {
        builtIn.filter(\.isQualified).compactMap { URL(string: $0.url) }
    }

    public static func resolveSelected(customServers: [String], selectedTSAURL: String)
        -> [TimestampAuthority] {
        var all = builtIn
        for raw in customServers where !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            let server = raw.trimmingCharacters(in: .whitespaces)
            if !all.contains(where: { $0.url.caseInsensitiveCompare(server) == .orderedSame }) {
                all.append(TimestampAuthority(name: server, url: server))
            }
        }
        return all
    }
}
