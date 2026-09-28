// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Extracts the `sk.minv.sca://` link out of the eIdentita session page HTML.
///
/// The page renders `_eidentita.html.erb`, whose anchor carries the phone URL:
/// `sk.minv.sca://sign?qr=true&linkUrl=<parameters URL>`. In the raw body the
/// query separator is HTML-escaped (`qr=true&amp;linkUrl=`), so the match is
/// unescaped before it becomes a URL. Without that the phone never fetches
/// `linkUrl` and the QR silently does nothing.
public enum EidentitaQR {
    private static let schemePrefix = "sk.minv.sca://"

    public static func url(fromHTML html: String) -> URL? {
        guard let start = html.range(of: schemePrefix)?.lowerBound else { return nil }
        let tail = html[start...]
        let end = tail.firstIndex(where: { $0 == "\"" || $0 == "'" || $0.isWhitespace || $0 == "<" })
           .map { $0 } ?? tail.endIndex
        var raw = String(tail[..<end])
        // Unescape repeatedly: the href can arrive double-escaped (`&amp;amp;`).
        for _ in 0..<3 {
            let unescaped = raw
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
            if unescaped == raw { break }
            raw = unescaped
        }
        guard raw.hasPrefix(schemePrefix), let url = URL(string: raw) else { return nil }
        return url
    }
}
