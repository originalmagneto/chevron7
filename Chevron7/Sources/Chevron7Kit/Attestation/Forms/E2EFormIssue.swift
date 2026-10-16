// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Turns a failure to build the E→E clause or record into advice for the advocate: which
/// value is missing or malformed and where to fix it, never libxml2's text. The technical
/// detail stays in `technicalDetail` for the log and a support report.
public struct E2EFormIssue: Sendable, Equatable {
    public let advice: String
    public let technicalDetail: String?

    /// Slovak name and the step that holds each value the forms take from the advocate.
    static let fields: [String: (label: String, place: String)] = [
        "UsedDevice": ("Použitý prostriedok", "aplikácia ho dopĺňa sama; aktualizujte Chevron7"),
        "OriginalDocumentType": ("Druh dokumentu", "v kroku Osvedčovacia doložka"),
        "OriginalDocumentName": ("Názov pôvodného dokumentu", "premenujte súbor a vložte ho znova"),
        "NewDocumentName": ("Názov nového dokumentu", "v kroku Osvedčovacia doložka"),
        "GivenName": ("Meno osoby vykonávajúcej konverziu", "v kroku Osvedčovacia doložka"),
        "FamilyName": ("Priezvisko osoby vykonávajúcej konverziu", "v kroku Osvedčovacia doložka"),
        "Position": ("Funkcia osoby vykonávajúcej konverziu", "v kroku Osvedčovacia doložka"),
        "Name": ("Názov advokátskej kancelárie", "v kroku Osvedčovacia doložka"),
        "IdentifierValue": ("IČO", "v kroku Osvedčovacia doložka (8 alebo 12 číslic)"),
        "AuthorizationLocation": ("Miesto podpisu klienta", "overte podpisy znova"),
        "PersonID": ("Identifikátor podpisovateľa", "overte podpisy znova"),
        "ConversionRecordEvidenceNumber": ("Evidenčné číslo", "skúste autorizáciu znova"),
    ]

    public static func from(_ error: Error) -> E2EFormIssue {
        if let failure = error as? FormSchemaValidator.Failure {
            switch failure {
            case .validatorUnavailable:
                return E2EFormIssue(advice: failure.errorDescription ?? "", technicalDetail: nil)
            case .invalid(let details):
                return from(schemaDetails: details)
            }
        }
        if let attestation = error as? AttestationGenerationError {
            return E2EFormIssue(advice: attestation.localizedDescription, technicalDetail: nil)
        }
        return E2EFormIssue(advice: error.localizedDescription, technicalDetail: nil)
    }

    static func from(schemaDetails details: String) -> E2EFormIssue {
        let element = details.range(of: #"Element '\{[^}]*\}(\w+)'"#, options: .regularExpression)
            .flatMap { match -> String? in
                let text = String(details[match])
                guard let close = text.lastIndex(of: "}") else { return nil }
                return String(text[text.index(after: close)...].dropLast())
            }
        guard let element, let field = fields[element] else {
            return E2EFormIssue(
                advice: "Osvedčovaciu doložku alebo záznam sa nepodarilo vytvoriť podľa oficiálneho formulára. Evidenčné číslo sa nepoužilo. Pošlite nám prosím túto chybu.",
                technicalDetail: details)
        }
        let problem = details.contains("minLength") || details.contains("Missing child element")
            ? "chýba" : "nemá správny tvar"
        return E2EFormIssue(
            advice: "Údaj „\(field.label)“ \(problem): \(field.place). Evidenčné číslo sa nepoužilo.",
            technicalDetail: details)
    }
}

extension E2EFormModel {
    /// `UsedDevice` as the record documents it: the product's trade name with what it did.
    public static var defaultUsedDevice: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let name = version.map { "Chevron7 \($0)" } ?? "Chevron7"
        return "\(name): overenie podpisov, prevod do PDF/A a autorizácia elektronického dokumentu"
    }
}
