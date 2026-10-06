// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Turns the AVM server answer into the fork's `SignedConversionResult` and
/// classifies the signer using the same string heuristics the engine bridge uses.
public enum AVMResultMapper {
    public static let fallbackLabel = "Podpis z Autogram v mobile"

    public static func signatureLabel(signers: [AVMSigner]) -> String {
        let names = signers.compactMap { $0.signedBy?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return names.isEmpty ? fallbackLabel : names.joined(separator: ", ")
    }

    /// The AVM app signs only with the qualified certificate on the eID, so a
    /// signature is treated as qualified unless the issuer is a commercial
    /// (non-qualified) authority.
    public static func isQualified(signers: [AVMSigner]) -> Bool {
        !signers.isEmpty && signers.allSatisfy { signer in
            !EngineBridgeSigningProvider.isCommercialIssuer(signer.issuedBy ?? "")
        }
    }

    public static func isMandate(signers: [AVMSigner]) -> Bool {
        signers.contains { signer in
            EngineBridgeSigningProvider.isMandateCertificate(
                issuer: signer.issuedBy ?? "", displayName: signer.signedBy ?? "")
        }
    }

    public static func conversionResult(from document: AVMSignedDocument,
                                        outputFormat: SigningOutputFormat,
                                        uploadedPDF: Data,
                                        signedAt: Date = Date()) throws -> SignedConversionResult {
        guard let payload = document.data else { throw AVMError.invalidResponse }
        let signers = document.signers ?? []
        switch outputFormat {
        case .embeddedPAdES:
            return SignedConversionResult(pdfData: payload, asicData: nil, signedAt: signedAt,
                                          signatureLabel: signatureLabel(signers: signers),
                                          isLegallyBinding: isQualified(signers: signers),
                                          signerIssuer: signers.first?.issuedBy)
        case .attachedASIC:
            return SignedConversionResult(pdfData: uploadedPDF, asicData: payload, signedAt: signedAt,
                                          signatureLabel: signatureLabel(signers: signers),
                                          isLegallyBinding: isQualified(signers: signers),
                                          signerIssuer: signers.first?.issuedBy)
        }
    }
}
