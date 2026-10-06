// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// The authority rows of the done screen's timestamp card.
///
/// A card signature is timestamped by the authority chosen in Chevron7, so its name
/// and address are the ones in Settings. A phone signature is timestamped by the
/// phone's own service (Autogram v mobile or eIDENTITA), so the Settings authority
/// would be wrong there: the card names the authority the validated signature
/// carries, and until validation has named it, the app that added the timestamp.
enum SigningTimestampPresentation {
    struct Row: Equatable {
        let label: String
        let value: String
    }

    /// - Parameters:
    ///   - mobileMethod: how the phone signed, nil for a card signature.
    ///   - validatedAuthority: the timestamp authority from full validation, nil
    ///     while only the structural tree is known.
    static func authorityRows(mobileMethod: MobileSigningMethod?,
                              settingsAuthorityName: String,
                              settingsAuthorityURL: String,
                              validatedAuthority: String?) -> [Row] {
        guard let mobileMethod else {
            return [Row(label: "Autorita", value: settingsAuthorityName),
                    Row(label: "Adresa", value: settingsAuthorityURL)]
        }
        if let validatedAuthority = validatedAuthority?.trimmingCharacters(in: .whitespacesAndNewlines),
           !validatedAuthority.isEmpty {
            return [Row(label: "Autorita", value: validatedAuthority),
                    Row(label: "Pridala", value: appName(mobileMethod))]
        }
        return [Row(label: "Autorita", value: "Pridala aplikácia \(appName(mobileMethod))")]
    }

    private static func appName(_ method: MobileSigningMethod) -> String {
        switch method {
        case .autogramMobile: return "Autogram v mobile"
        case .eidentita: return "eIDENTITA"
        }
    }
}
