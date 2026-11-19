// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Slovak wording of the ETSI EN 319 102-1 sub-indications DSS reports for a signature that is
/// not valid. DSS's own `validationReason` is an English sentence, so the advocate sees this text
/// and the English sentence only as a technical detail.
public enum DSSSubIndicationText {
    /// The Slovak reason for a sub-indication; "dôvod: <code>" for a code this table lacks.
    public static func text(_ subIndication: String) -> String {
        let code = subIndication.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch code {
        case "FORMAT_FAILURE": return "podpis nemá správny formát"
        case "HASH_FAILURE": return "podpísané údaje sa zmenili"
        case "SIG_CRYPTO_FAILURE": return "podpis nie je kryptograficky platný"
        case "REVOKED": return "certifikát podpisovateľa bol zrušený"
        case "REVOKED_NO_POE": return "certifikát bol zrušený a chýba dôkaz, že podpis vznikol skôr"
        case "REVOKED_CA_NO_POE": return "certifikát vydavateľa bol zrušený a chýba dôkaz, že podpis vznikol skôr"
        case "SIG_CONSTRAINTS_FAILURE": return "podpis nespĺňa požiadavky politiky overenia"
        case "CHAIN_CONSTRAINTS_FAILURE": return "reťazec certifikátov nespĺňa požiadavky politiky overenia"
        case "CERTIFICATE_CHAIN_GENERAL_FAILURE": return "reťazec certifikátov sa nepodarilo overiť"
        case "CRYPTO_CONSTRAINTS_FAILURE": return "použitý kryptografický algoritmus už nie je dostatočne bezpečný"
        case "CRYPTO_CONSTRAINTS_FAILURE_NO_POE":
            return "použitý kryptografický algoritmus už nie je dostatočne bezpečný a chýba dôkaz, že podpis vznikol skôr"
        case "EXPIRED": return "certifikát podpisovateľa už nie je platný"
        case "NOT_YET_VALID": return "certifikát podpisovateľa v čase podpisu ešte nebol platný"
        case "POLICY_PROCESSING_ERROR": return "politiku podpisu sa nepodarilo spracovať"
        case "SIGNATURE_POLICY_NOT_AVAILABLE": return "politika podpisu nie je dostupná"
        case "TIMESTAMP_ORDER_FAILURE": return "časové pečiatky nie sú v správnom poradí"
        case "NO_SIGNING_CERTIFICATE_FOUND": return "certifikát podpisovateľa sa nenašiel"
        case "NO_CERTIFICATE_CHAIN_FOUND": return "reťazec certifikátov nevedie k dôveryhodnej autorite"
        case "OUT_OF_BOUNDS_NO_POE", "OUT_OF_BOUNDS_NOT_REVOKED":
            return "certifikát v čase overenia nebol platný"
        case "REVOCATION_OUT_OF_BOUNDS_NO_POE": return "informácia o zrušení certifikátu je mimo jeho platnosti"
        case "NO_POE": return "chýba dôkaz, že podpis existoval v potrebnom čase"
        case "TRY_LATER": return "stav certifikátu sa zatiaľ nedá zistiť"
        case "SIGNED_DATA_NOT_FOUND": return "podpísané údaje sa nenašli"
        default: return "dôvod: \(subIndication)"
        }
    }

    /// The text without trailing periods and whitespace, so a sentence can end it with one period.
    public static func trimmedSentence(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(".") {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}
