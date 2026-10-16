// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

protocol SigningEngine: Sendable {
    func capabilities() async throws -> EngineCapabilities
    func drivers() async throws -> [SigningDriver]
    func certificates(driverID: String, pin: Secret?) async throws -> [SigningCertificate]
    func certificateDiscovery(driverID: String, pin: Secret?) async throws -> CertificateDiscovery
    func inspect(files: [PDFItemDescriptor]) async throws -> [PDFInspection]
    func previewEmbeddedDocument(sourceURL: URL, named: String) async throws -> EmbeddedDocumentPreview
    func validate(files: [PDFItemDescriptor]) async throws -> [PDFInspection]
    func conversionEvidence(file: PDFItemDescriptor) async throws -> ConversionEvidence
    /// Gives up on a validation that timed out: ends whatever still runs it, so the next
    /// validation does not queue behind the hung request.
    func stopValidation() async
    func sign(request: EngineSigningRequest) -> AsyncThrowingStream<SigningEvent, Error>
    /// Ends the helpers a signature runs on, but not a validation.
    func stopSigning() async
    func cancel() async
}

extension SigningEngine {
    func previewEmbeddedDocument(sourceURL: URL, named: String) async throws -> EmbeddedDocumentPreview {
        throw SigningFailure.engine("This signing engine does not support embedded document previews.")
    }

    func validate(files: [PDFItemDescriptor]) async throws -> [PDFInspection] {
        throw SigningFailure.engine("This signing engine does not support complete validation.")
    }

    func conversionEvidence(file: PDFItemDescriptor) async throws -> ConversionEvidence {
        throw SigningFailure.engine("Overenie pre zaručenú konverziu vyžaduje podpisový engine.")
    }

    func stopValidation() async {}

    func stopSigning() async {}
}
