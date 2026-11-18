// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Shared, testable wording for VoiceOver and other accessibility surfaces.
public enum UXLabels {
    /// Slovak cardinal plural: 1 one, 2-4 few, 0 and 5+ many.
    public static func count(_ n: Int, one: String, few: String, many: String) -> String {
        switch n {
        case 1: return "1 \(one)"
        case 2, 3, 4: return "\(n) \(few)"
        default: return "\(n) \(many)"
        }
    }

    public static func confidenceLabel(for confidence: Double) -> String {
        let percentage = Int((min(max(confidence, 0), 1) * 100).rounded())
        return "Istota \(percentage) %"
    }

    public static func provenanceLabel(detectedByAI: Bool) -> String {
        detectedByAI ? "AI detekcia" : "Pridané ručne"
    }

    public static func evidenceStatusLabel(for status: EvidenceRecord.Status,
                                           isOverdue: Bool = false) -> String {
        // The 24-hour deadline never hides a state that tells the advocate what to do
        // next: an unknown outcome is looked up first, and a late row has its own warning.
        if isOverdue, status != .outcomeUnknown, status != .late { return "Po lehote" }
        switch status {
        case .draft: return "Koncept"
        case .awaitingNumber: return "Čaká na evidenčné číslo"
        case .readyToSign: return "Pripravené na autorizáciu"
        case .signed: return "Podpísaný, čaká na odoslanie"
        case .queuedForSubmission: return "Čaká na odoslanie"
        case .submitted: return "Zapísané v CEZZK"
        case .submissionFailed: return "Odoslanie zlyhalo – čaká na opakovanie"
        case .acceptedForProcessing: return "Prijatý na spracovanie"
        case .processed: return "Spracovaný v EZZK"
        case .outcomeUnknown: return "Výsledok neznámy, najprv overte v EZZK"
        case .rejected: return "Odmietnutý v EZZK"
        case .recordUnsigned: return "Záznam nepodpísaný"
        case .late: return "Oneskorený"
        }
    }

    /// The register detail's "Výstup pre klienta"; nil for a row without a recorded output.
    public static func clientOutputLabel(_ output: AppSettings.ZakoClientOutput?) -> String? {
        switch output {
        case .asicContainer: return "Kontajner ASiC-E"
        case .singlePDF: return "Jeden PDF s doložkou"
        case nil: return nil
        }
    }

    /// The register's fingerprint label. A one-PDF row's fingerprint is the SHA-256 of its first
    /// revision only (the unsigned content PDF/A), which a reader gets by cutting the delivered
    /// file after `revisionOneLength` bytes, so the label says so.
    public static func fingerprintLabel(clientOutput: AppSettings.ZakoClientOutput?, revisionOneLength: Int?) -> String {
        guard clientOutput == .singlePDF, let revisionOneLength else { return "SHA-256 odtlačok" }
        return "SHA-256 prvej revízie (prvých \(revisionOneLength) bajtov)"
    }
}
