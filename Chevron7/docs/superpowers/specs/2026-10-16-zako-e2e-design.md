# ZaKo E→E: guaranteed conversion of an electronic document to a new electronic document

Date: 2026-10-16. Status: draft for the owner's review (revision 2, after the builder check).
Builds on: `2026-09-23-ezzk-part-b-design.md` (P→E clause, record, submission), `2026-10-01-nested-signature-tree-design.md` (validation in the engine), `Chevron7/docs/EZZK-INTEGRATION.md`.

## Intent

An advocate's client brings a document they authorized electronically (a PDF with PAdES, or an ASiC-E with XAdES, signed with a qualified signature or seal and possibly timestamped). The advocate performs a guaranteed conversion of it to a new electronic document (§ 35 ods. 1 písm. c) and § 36 ods. 4 zákona č. 305/2013 Z. z.), attaches the osvedčovacia doložka, authorizes both with the mandate certificate and a qualified timestamp, and sends the record to EZZK, exactly as Chevron7 already does for paper originals (§ 36 ods. 3). Owner's words: "Najprv by som chcel spraviť tú konverziu E->E, ale ako pre advokáta, kde by som vedel dokument autorizovaný klientom v el. podobe pridať autorizačnú doložku."

## Legal frame (read on Slov-Lex on 2026-10-16)

- **§ 36 ods. 4 zákona 305/2013** (in force until 31. 12. 2026): verify the validity of the original's authorization and of its timestamp, transform the original into the new electronic document, create the clause as an electronic document, authorize clause and new document together with a timestamp, create the record. From 1. 1. 2027 the order changes for every direction (record first, sent to EZZK, clause built from EZZK data). That change is out of scope here and handled by the session "ZaKo podľa zmeny zákona od 1. 1. 2027".
- **Vyhláška 70/2021 § 6:** clause content per annex 5 (= annex 1 a) to g)), authorization as in § 5 ods. 2 and 3 (QES with the mandate certificate or qualified seal, qualified timestamp covering the signature; container per § 47 písm. a) vyhlášky 78/2020), record content per annex 6 (annex 2 a), b), c), e), f) for original, new document, timestamps, authorizations, conversion).
- **§ 2 ods. 2:** the new document is a PDF or PNG "pri dodržaní štandardov na prijímanie a čítanie podpísaných elektronických dokumentov" (§ 46 ods. 2 vyhlášky 78/2020), which for a signed PDF means PDF/A-1, A-2 or A-3, and § 46 ods. 2 písm. h) excludes signed documents with nested files.
- **§ 3 ods. 4:** a qualified electronic signature or seal on the original is checked "s použitím kvalifikovanej služby validácie" (eIDAS čl. 33 and 40), and the service's output is kept in the record. § 3 ods. 5: the signature is identified by its signature identifier.
- **Official forms** (slovensko.sk eForm module, current pair, the same generation as the P→E pair Chevron7 uses):
  - clause `50349287.ConversionCertificateOfElectronicDocumentToElectronicDocument.sk` 1.3 (in force from 2019-12-01, package SHA-256 `d2da1181950ee4047c3ea0c59507db646974bcfd91ab2ec60dd09e2c61fcbcd1`), root `ConversionCertificateOfElectronicDocumentToElectronicDocument`, namespace `http://schemas.gov.sk/form/50349287.ConversionCertificateOfElectronicDocumentToElectronicDocument.sk/1.3`, signer presentation `Content/form.19.html2.xslt` (HTML, the only one with the "Osvedčujem, že ..." sentence);
  - record `50349287.ConversionRecordOfElectronicDocumentToElectronicDocument.sk` 1.0 (in force from 2019-11-29, package SHA-256 `c5d5650b75127dac7af0fcae78164bb44058600efb497dabf29a1a0ab84773bb`), root `ConversionRecord`, namespace `https://data.gov.sk/id/egov/eform/50349287.ConversionRecordOfElectronicDocumentToElectronicDocument.sk/1.0`, signer presentation `Content/form101.sb.xslt` (TXT). Its `IdentifierValueType` pattern has the same escaped slashes libxml2 rejects, so it gets a derived `schema.validation.xsd` like record 1.0 P→E.
  - Both clause sentences still cite the repealed vyhláška 331/2018. That is a defect of the official form, which Chevron7 cannot change.
- **The record's `ValidityVerificationResult`** (1..1 per authorization) is documented as "validačná správa splnenia požiadaviek čl. 32 nariadenia (EÚ) č. 910/2014 ..., ak aplikácia používaná na overovanie takúto správu poskytuje, alebo výsledok procesu validácie podpísaný alebo zapečatený kvalifikovanou dôveryhodnou službou validácie". EZZK takes the record as a signed attachment and does not interpret the field.
- **EZZK:** `ReceiveConversionRecord` is form-agnostic (the signed ASiC-E as `ATTACHMENT`); the conversion type is carried only by the record form inside. Nothing in the SOAP layer changes.

## Owner's decisions

1. **Validation evidence (2026-10-16, option B):** build the whole E→E pipeline now with Chevron7's own DSS validation report as the evidence. E→E is offered in Demo and Testovacia evidencia only. Ostrá evidencia stays locked for E→E until the advocate has a qualified validation service set up and its output is attached to the conversion.
2. **Qualified validation services are added by the users themselves** ("a tú službu validácie si budú môcť užívatelia pridať sami"): each advocate configures their own contracted provider in Settings; credentials only in the Keychain.
3. The free qualified timestamp authorities stay as in P→E (`TimestampAuthority.zakoQualifiedURLs`: Sectigo Qualified first, BOSA last resort). No paid timestamp authority.
4. The 1. 1. 2027 change is a separate project.

Open questions for the owner are at the end (section "Questions").

## Goals

- An advocate converts a signed PDF (PAdES) or an ASiC-E holding one PDF (XAdES or CAdES) into a new PDF/A-2b with the E→E clause, signed together with the mandate certificate and a qualified timestamp, records it in Register konverzií and sends the E→E record to EZZK.
- The clause and record carry, for every signature and seal of the original, the data annex 1 g) and annex 2 c) ask for: type, covered documents, validation state, signing time, validation time, place, signer identifier, mandant, mandate, oldest valid timestamp.
- The validation report is kept with the record and in the register, and the advocate can save it.
- Production E→E only with a qualified validation service's sealed output attached.
- Verified end to end in EZZK Testovacia evidencia (record "Záznam je spracovaný") before production is offered.

## Non-goals

- E→P (later project).
- The 2027 forms (`_2021.sk` 1.2) and order.
- Originals other than a PDF or an ASiC-E with exactly one PDF data object: ASiC-E with several data objects, an XML form (XDC) data object, detached CAdES (`.p7s`), XAdES_ZEP, plain images or text. They are refused with a clear message; each is a follow-up.
- Unsigned originals (see section 2).
- PNG output.
- Phone (AVM, eIdentita) authorization of an E→E conversion outside Demo (same rule as P→E).
- A built-in paid validation service or any contract on the advocate's behalf.

## Anti-goals

- A conversion whose clause says a signature is valid when the validation said otherwise.
- A production E→E record without a qualified validation output in it.
- A new document that still carries the client's cryptographic signature in a broken state (a re-saved PDF whose signature fields now fail in Acrobat).
- Any change to the P→E forms, digests or records EZZK already accepted.

## Design

### 1. Direction at intake

The ZaKo intake screen gets a direction choice ("Pôvodný dokument: V listinnej podobe | V elektronickej podobe"), default listinná, remembered for the app run. P→E behaves exactly as today. E→E accepts `.pdf`, `.asice`, `.sce` (`ContainerFileTypes`), from the panel, a drop or Finder's Open With while the ZaKo window shows E→E.

`ZakoSessionStore.Step` gains `.verification`. E→E runs intake → verification → attestation → authorize → done; the analysis step (scan, security elements, OCR) is never entered. `ZakoSessionStore` keeps `direction: ConversionDirection` and every place that hard-codes `.paperToElectronic` (initial form pack, `formPackRepository.pack(for:)`, `EvidenceRecord.direction`) reads it.

### 2. Reading the original (Kit `ElectronicOriginal`)

A new value type built from the source bytes and the engine's validation:

- **PDF:** each PAdES signature covers a revision (the bytes up to the end of its `/ByteRange`). The original documents are the distinct signed revisions in order. One signed revision: one original named after the file. Several: `<stem>-1`, `<stem>-2`, ... in signing order, each with the SHA-256 of its revision bytes, as the form's `OriginalDocumentName` rule 3 asks.
- **Changes after the last signature:** the new document is made from the whole final file, so v1 refuses a PDF whose bytes after the last signed revision hold anything but DSS extension data (document timestamps, DSS/VRI dictionaries). The engine reports this from DSS's PDF revision analysis (modification detection) per file; annotations, form fills or page changes after the last signature are refused with a message naming them, so the clause never certifies content nobody authorized.
- **ASiC-E:** exactly one data object, which must be a PDF without signatures of its own; the original is that data object (its entry name, format `PDF`, SHA-256 of its bytes), and every container signature authorizes it. A PDF data object that carries its own PAdES signatures is refused in v1 (describing nested authorizations is a follow-up), as is anything else in the non-goals.
- **Unsigned originals** (`OriginalDocumentAuthorizationOccurance` false) are refused in v1: the owner's case is a document the client authorized, and § 2 ods. 1 písm. b) vyhlášky 70/2021 would need a separate agreement with the client for other formats.
- `OriginalDocumentFormat`: codelist 53 `PDF`, or `PDFA1` / `PDFA2` when the file declares PDF/A part 1 or 2 in its XMP; record carries the item name.
- `OriginalDocumentType` (record only): "Druh dokumentu", typed by the advocate (e.g. "zmluva o pôžičke"), required.

### 3. Verification (engine VALIDATE, extended)

The engine's VALIDATE already validates against the EU trusted lists (`MachineInspectionService.forTrustedValidation`). It gains, per request flag `evidence: true`:

- the ETSI TS 119 102-2 validation report XML of the whole document (DSS `Reports.getEtsiValidationReportJaxb`, marshalled), returned base64, plus the DSS version and the validation time;
- per signature: the signature value (base64), the signed revision length for PAdES, the signer certificate's CN, subject `serialNumber`, every subject value starting with `MANDANT ` (the form's mandant rule), the certificate policy OIDs and the `userNotice` `explicitText` of each, QcCompliance and QcType (signature or seal), and the signature production place when the signature names one;
- per timestamp (already partly there): type, qualification, state, production time, TSA certificate CN.

Swift decodes this into `ElectronicOriginal.authorizations` (one per signature or seal). `ElectronicOriginal` is independent of the form version: the record 1.0 renderer and, later, the 2027 record renderer (hex fingerprints, `DSId`, base64 `ElectronicSignature`) read the same value, so the 2027 project only adds a renderer.

| Clause / record field | Source |
|---|---|
| `AuthorizationType` (codelist 54; record: item name) | QESig `2` Kvalifikovaný elektronický podpis, QESeal `5`, AdESig-QC or AdESig `3`, AdESeal-QC or AdESeal `6`, anything DSS reports as not AdES `4` or `7`, an undetermined qualification `Iny` with the DSS value in `AuthorizationTypeOther` |
| `AuthorizedDocument` | the original document(s) the signature covers (section 2) |
| `AuthorizationState` (codelist 16) | DSS indication TOTAL_PASSED `platná`, TOTAL_FAILED `neplatná`, INDETERMINATE `nie je možné zistiť` |
| `AuthorizationTime` | claimed signing time, when present |
| `AuthorizationValidationTime` | validation time of the report |
| `AuthorizationLocation` | the signature production place, else `Neuvedené` |
| `PersonID` | subject `serialNumber` (e.g. `PNOSK-...`), else CN |
| `Mandant` | the `MANDANT ...` subject values, joined with `; ` |
| `Mandate` | last arc of a policy OID under `1.3.158.36061701.1.1` plus its `explicitText` (e.g. `1042 OPRÁVNENIE ...`) |
| `TimeStamp` | only the oldest valid one, as the form says: type (55 `KVAL` / `NEKVAL`), state (16), production time, TSA CN, validation time |
| `OtherAuthorizationInfo` | "Kvalifikovaný certifikát: áno/nie" from QcCompliance and the trusted list, as the form's documentation asks |
| record `ElectronicSignature` | the signature value base64 (the value the signature identifier of § 3 ods. 5 is computed from) |
| record `ValidityVerificationResult` | the validation evidence report bytes, base64 (section 6) |

All times are written in Europe/Bratislava with `+01:00` / `+02:00` and no fractional seconds (`dateTimeCetOrCest`).

**Gate on the result:**

- any signature or timestamp `neplatná`: refused, the conversion cannot continue;
- `nie je možné zistiť` because a trusted list did not load (`TrustedListAvailability`, the engine's `unverified` country): always blocked with "Skúste overenie znova", never written into a legal record, since it says nothing about the signature;
- any other `nie je možné zistiť`: see question 2 (default: allowed only after the advocate confirms in a sheet that names the signature and DSS's reason, and the state is written as is).

The verification step shows the existing `SignatureBanner` and the rows of `SignatureTreeView`, plus the original documents with their hashes, and a "Uložiť správu o overení…" button.

### 4. Transformation (engine, new)

The new document is always a fresh PDF/A-2b (question 1). A new engine entry point `PdfaFromSigned` (beside `PdfaNormalize`, PDFBox):

1. remove every signature field's `/V` signature dictionary, `/Perms` (DocMDP) and the AcroForm `SigFlags`;
2. flatten the AcroForm: every widget's normal appearance, including visible signature stamps, becomes page content, so the visible information content (§ 1 písm. c) vyhlášky: "podpis a odtlačok úradnej pečiatky") stays;
3. drop embedded files and JavaScript;
4. hand the result to the existing `PdfaNormalize` path (vector-preserving rewrite with sRGB OutputIntent and XMP);
5. check the output with veraPDF (bundled in the engine, PDF/A-2b profile), because `PdfaNormalize` only adds the identification and the OutputIntent and `PDFAValidator` only looks for those markers: a client PDF with unembedded fonts or transparency would otherwise be labelled PDF/A without being one. On a veraPDF failure the advocate is offered the rasterized PDF/A (`PDFAConversionMode.rasterGuaranteed`, text no longer selectable) or to stop.

The output is the `NewDocumentInfo`: name `ConversionOutputNaming.containerDocumentName`, format `PDFA2` / "PDF/A-2", SHA-256 of the delivered bytes. For an ASiC-E the input is the extracted PDF data object. Engine tests: a PAdES PDF with a visible signature, a two-signature PDF, an AcroForm with filled fields, a PDF/A-1b input; the output has no `/Sig`, passes `PDFAValidator`, and its page rendering equals the input's.

### 5. Clause, record, delivery

- New forms under `docs/reference/forms/clause-e2e-1.3/` (`schema.xsd`, `form.19.html2.xslt`) and `record-e2e-1.0/` (`schema.xsd`, `schema.validation.xsd`, `form101.sb.xslt`), `provenance.json` extended, `scripts/embed-official-forms.sh` file list extended, `OfficialFormFiles.swift` regenerated; `OfficialForm.clauseE2E_1_3` and `.recordE2E_1_0`. The P→E entries and their digests do not change (`OfficialFormTests` pins them).
- `ConversionFormModel` becomes direction-aware: the P→E body stays as it is; an E→E body carries `[ElectronicOriginalDocument]`, `OriginalDocumentAuthorizationOccurance`, `[OriginalAuthorization]`, the new document and the shared conversion fields (evidence number as URI in the clause and plain in the record, `UsedDevice` "Chevron7 <version>", conversion time, person).
- New renderers `ConversionCertificateE2ERenderer` and `ConversionRecordE2ERenderer`, validated by `FormSchemaValidator` against the official schema (clause) and the derived validation schema (record), wrapped by `XMLDataContainerBuilder` with the E→E form.
- `ZakoClauseDeliveryBuilder` and `ZakoRecordDeliveryBuilder` take the form pair from the direction; names stay `<number>.xml.xdcf`, `<number>.record.xml.xdcf`, `<stem>.asice`.
- Signing at authorization is the P→E sequence unchanged: the client ASiC-E (new PDF/A + E→E clause XDCF as two data objects, `signsExtraFilesAsDataObjects`, `timestampServers` = `zakoQualifiedURLs` outside Demo) and then the E→E record XDC alone (`signsAsRecordContainer`), one PIN, mandate certificate required (`MandateCertificate`, `ZakoMandateCardFlow`), evidence number allocated right before signing (`needsFreshEvidenceNumber`), same Bratislava day and mode rules (`EZZKEvidenceNumberPolicy`).
- Because the new document is a fresh unsigned PDF/A, the engine never takes the `wrapsSignedSource` path.

### 6. Validation evidence

`ValidationEvidence { source, reportData, contentType, fileName, createdAt }` with `source` either `.chevron7DSS(dssVersion)` or `.qualifiedService(serviceName, providerName)`. It is stored in `Evidence/validation/<record id>.<ext>`, named by `EvidenceRecord.validationEvidenceFileName`, and saved from the register detail ("Uložiť správu o overení…").

- **Demo and Testovacia evidencia:** the ETSI report from the engine (`.chevron7DSS`). The whole report (with certificates and revocation data, possibly megabytes) is kept in `Evidence/validation/`. Each authorization's `ValidityVerificationResult` in the record carries, base64, only that signature's ETSI `SignatureValidationReport` with its validation objects reduced to their identifiers, so the signed record stays small. The live check in Testovacia evidencia measures the record size; EZZK publishes no size limit.
- **Ostrá evidencia:** a qualified service's sealed output must be attached (section 7). Each authorization's `ValidityVerificationResult` then carries that sealed output unchanged as base64 (a seal cannot be cut to one signature). The clause states (`platná` etc.) come from the engine's per-signature mapping and are compared with the qualified report: where the report is machine-readable (Disig/NASES `XadesXml`, ETSI TS 119 102-2, DSS simple or detailed report), Chevron7 compares per signature and refuses on any mismatch, and `AuthorizationValidationTime` / `TimeStampValidationTime` take the report's validation time; where it is a sealed PDF or text, the advocate confirms the match in the verification step ("Výsledok kvalifikovanej služby validácie sa zhoduje") and the times stay the engine's.

### 7. Qualified validation services (Settings)

No qualified validation provider publishes an API an advocate can use without a contract (research 2026-10-16: NASES QVal is free but only for OVM and state-owned companies; Disig sells it inside its Windows Desktop Signer conversion module, about 209 € a year, without a published API; Ardaco and brainit NFQES have unpublished APIs for contracted customers; NFQES offers a web portal where a customer uploads a document and downloads a sealed report). So the first version is provider-independent:

- **Settings, EZZK pane, new group "Kvalifikovaná služba validácie"** (advanced until one is added): a list of services the advocate added, each with a name, the provider (Disig, Ardaco, NFQES or another, free text), an optional portal URL, and a method. v1 method: **import of the provider's sealed report**. The group links the providers' pages and says what a contract gives.
- **Verification step in Ostrá evidencia:** "Pripojiť výsledok kvalifikovanej validácie…" opens the provider's portal (when set) and accepts the downloaded report file (PDF with PAdES, XML with XAdES, or ASiC-S/ASiC-E). The engine validates the report's own seal: it must be valid and its certificate must belong to a trusted list service of type `QESValidation/Q` with status granted (DSS trusted service info), and its validation time must be after the original's last signature. The trusted list carries a dedicated certificate for each such service (checked 2026-10-16: Disig "Qualified validation service for QES" under CA Disig QCA3 and QCA4, NASES "Qualified validation service for QES P1/P2/S1" under SNCA4, "Ardaco Qualified Validation Service 1", brainit "NFQES VAL"), so the check matches the seal certificate against those service digital identities. NASES's sample reports are sealed with a demo pseudonym certificate, so real reports must be checked during the live test before the rule is trusted; until then a mismatch is reported with the certificate's subject, not silently refused.
- **Binding the report to this original:** a machine-readable report must name the original: Disig/NASES `XadesXml` carries each data object's `ContentHash` and each signature's `SignatureValue` and `DSId`, ETSI and DSS reports carry signature identifiers and digests. Chevron7 requires the original's SHA-256 or every signature value to appear in it. For a sealed PDF or text report, the advocate confirms that it concerns this document, and the file name is shown beside the original's name. A report that names another document is refused.
- **API method (later phase, not v1):** the NASES and Disig services share a published SOAP contract (WSDL, XSD and sample reports in NASES's `ValidationReport-dokumentacia_SNCA.zip`: one `Validate` operation, MTOM, client TLS certificate, outputs `DisigPdf`, `NbuText`, `XadesXml`, each sealed with a qualified timestamp). An adapter for it is built when an advocate has Disig test access to verify against; credentials (a `.p12` identity) then go to the Keychain under `app.slovensko.chevron7.qval.<service id>`.
- **The 2027 draft decree** (eLegislatíva LP/2026/337, per the 2027 session) extends qualified validation to advanced signatures based on a qualified certificate; the production gate here already requires the qualified output for every signature and seal of the original, whatever its type.
- **Production gate:** `ZakoSessionStore` refuses to allocate a production evidence number or authorize an E→E conversion without a qualified `ValidationEvidence` attached (`EZZKError.e2eNeedsQualifiedValidation`, Slovak message naming the Settings group). `EZZKProductionPolicy` is unchanged for P→E.

### 8. Register

`EvidenceRecord` already has `direction`. New optional fields: `validationEvidenceFileName`, `validationEvidenceSource`, `originalDocumentHashes`. Paper-only fields (sheets, pages, security elements) stay empty for E→E; the register list and detail show "E→E" and hide them. The sidebar rows and the EZZK status checker need no change (the submission path is form-agnostic). Rows written before this change decode as P→E.

### 9. Testing

- Renderer tests: E→E clause and record for one PAdES signature, two PAdES revisions, an ASiC-E XAdES with a timestamp; refusals for an unsigned PDF, a PDF changed after its last signature and an ASiC-E holding a signed PDF; each validates against the official (clause) or derived (record) schema; element order pinned against the schema; times in `+01:00` / `+02:00` without fractions.
- `OfficialFormTests`: the new files and digests match `provenance.json`; P→E digests unchanged.
- Mapping tests from recorded engine payloads (JSON fixtures) to `ElectronicOriginal`, including mandant and mandate extraction, the oldest valid timestamp, and the gate (`neplatná` refused, `nie je možné zistiť` needs confirmation).
- Engine tests: VALIDATE with `evidence: true` (ETSI report present, certificate facts), `PdfaFromSigned` (section 4), report seal check (a sealed test report fixture accepted when its signer is a `QESValidation/Q` service in a test trusted list, refused otherwise).
- `ZakoSessionStore` flow tests with the Demo provider: E→E Demo end to end; Test mode with the engine fake; production refused without qualified evidence.
- Live: the owner signs an E→E conversion in Testovacia evidencia with the SAK card; `ezzk-probe lookup` reports the record processed; the client container opens in Chevron7 and on slovensko.sk.

### 10. Delivery phases

1. Forms, model, renderers, validators (Kit only).
2. Engine: VALIDATE evidence fields and ETSI report; `PdfaFromSigned`; report seal check.
3. App: intake direction, verification step, E→E attestation form, authorization, register; Demo and Testovacia evidencia.
4. Qualified evidence: Settings group, report import, production gate.
5. Live check in Testovacia evidencia, docs (`EZZK-INTEGRATION.md`, CLAUDE.md and AGENTS.md), Slovak change note `docs/releases/changes/feat-zako-e2e.md`.
6. Later, with Disig test access: the NASES/Disig SOAP adapter.

## Calls made by the builder (not the owner)

- The original's name for a single file is the file name, not "Dokument" (rule 1 applies only to an unnamed document).
- Multi-revision PAdES follows the form's `<stem>-N` rule in v1 rather than being refused, because two-party signed contracts are the common case.
- ASiC-E: the original document is the PDF data object, not the container.
- `ValidityVerificationResult` carries the whole report as base64, repeated in each authorization block (the field is 1..1 per authorization).
- `ElectronicSignature` carries the signature value; this is a reading of annex 2 c) 1 and the field's one-word documentation.
- `Mandate`, `Mandant`, `PersonID` and `OtherAuthorizationInfo` formats as in the table in section 3.
- The E→E settings live in the EZZK pane.
- The API adapter waits for test access; v1 ships the report import, which works with any provider's portal.
- Production E→E before 1. 1. 2027 needs an advocate's contract with a provider, so in practice it may first be used under the 2027 forms; the Settings group, the report import and the gate are still built now because the 2027 draft keeps (and widens) the qualified validation duty, and `ElectronicOriginal` is form-version independent.
- v1 refuses unsigned originals, an ASiC-E whose PDF carries its own signatures, and a PDF changed after its last signature (other than DSS extension data).
- A trusted list that failed to load always blocks verification instead of producing `nie je možné zistiť`.
- The record carries per signature a slim ETSI signature report (DSS evidence) or the whole sealed qualified output; the full DSS report stays in `Evidence/validation/`.

## Questions for the owner

1. **The new document when the client's PDF is signed.** Default (above): always a fresh PDF/A-2b with the client's signatures flattened to their visible appearance; the clause and record carry the signature data, and the client's original stays with the client. Alternative: when the client's PDF already passes veraPDF as PDF/A-1, A-2 or A-3, keep it byte-identical as the new document (the form allows it: an untransformed original is described "identickými hodnotami"), so the recipient can still check the client's own signature inside it, and convert only the other files. The alternative brings the engine's wrapped-signed-source path into the client container and makes two kinds of output.
2. **A signature whose validity cannot be determined for a reason other than a trusted list that did not load** (for example a revocation source that did not answer, or a certificate chain DSS cannot build). Default: allowed after an explicit confirmation, written as "nie je možné zistiť" in the clause and record. Alternative: refused like an invalid one.
