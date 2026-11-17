// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Engine diagnostics that may go to the system log in public: veraPDF rule IDs and texts, with
/// anything that looks like a file path replaced, because a path names the person's documents.
public enum EngineDiagnosticText {
    static let pathPlaceholder = "<cesta>"
    static let maximumLines = 20
    static let maximumLineLength = 1024

    /// Absolute paths under the usual macOS roots, home-relative paths and `file:` URLs. PDF names
    /// such as `/Type /Font` and `PDF/A-3b` or a clause reference `ISO 19005-3:2012/6.2` stay.
    private static let pathPattern = try! NSRegularExpression(
        pattern: #"file:[^\s"'<>]*|~/[^\s"'<>]*|/(?:Users|private|var|tmp|Volumes|Applications|Library|System|opt|home|usr|etc)(?:/[^\s"'<>]*)?"#)

    /// The non-empty lines of `text`, each with its paths replaced and its length capped.
    public static func loggableLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { line -> String in
                let line = String(line).trimmingCharacters(in: .whitespaces)
                let range = NSRange(line.startIndex..., in: line)
                let stripped = pathPattern.stringByReplacingMatches(in: line, range: range,
                                                                    withTemplate: pathPlaceholder)
                return String(stripped.prefix(maximumLineLength))
            }
            .filter { !$0.isEmpty }
            .prefix(maximumLines)
            .map { $0 }
    }
}
