// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Codelists of the E→E clause 1.3 (`50349287.ConversionCertificateOfElectronicDocumentToElectronicDocument.sk`)
/// with the item codes and Slovak names of the official filler (`Content/form.19.html`).
public enum E2ECodelists {
    public static let documentFormat = 53
    public static let fingerprintMethod = 14
    public static let authorizationType = 54
    public static let validityState = 16
    public static let timestampType = 55

    public static let pdfFormat = ZakoCodelistItem(code: "PDF", skName: "PDF")
    public static let pdfa1Format = ZakoCodelistItem(code: "PDFA1", skName: "PDF/A-1")
    public static let pdfa2Format = ZakoCodelistItem(code: "PDFA2", skName: "PDF/A-2")
    public static let otherFormat = ZakoCodelistItem(code: "Iny", skName: "Iný")

    public static let qualifiedSignature = ZakoCodelistItem(code: "2", skName: "Kvalifikovaný elektronický podpis")
    public static let advancedSignature = ZakoCodelistItem(code: "3", skName: "Zdokonalený elektronický podpis")
    public static let electronicSignature = ZakoCodelistItem(code: "4", skName: "Elektronický podpis")
    public static let qualifiedSeal = ZakoCodelistItem(code: "5", skName: "Kvalifikovaná elektronická pečať")
    public static let advancedSeal = ZakoCodelistItem(code: "6", skName: "Zdokonalená elektronická pečať")
    public static let electronicSeal = ZakoCodelistItem(code: "7", skName: "Elektronická pečať")
    public static let otherAuthorization = ZakoCodelistItem(code: "Iny", skName: "Iný")

    public static let qualifiedTimestamp = ZakoCodelistItem(code: "KVAL", skName: "Kvalifikovaná")
    public static let nonQualifiedTimestamp = ZakoCodelistItem(code: "NEKVAL", skName: "Nekvalifikovaná")
}
