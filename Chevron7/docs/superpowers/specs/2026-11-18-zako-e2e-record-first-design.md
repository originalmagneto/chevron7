# ZaKo E→E in the order of 1. 1. 2027 (project C)

Date: 2026-11-18. Status: draft for the owner's approval. Builds on project A (one-PDF client output, PR #103) and project B (multi-file ASiC-E originals, PR #104); this branch (`claude/e2e-record-first`) starts from B's tip.

## 1. Intent

From 1. 1. 2027 (zákon č. 305/2013 Z. z. § 36 ods. 3 as amended by 325/2022, postponed by 239/2025) the record of a guaranteed conversion goes to the central register (EZZK) first and the clause follows from the register's data. Chevron7 does this for P→E since PR #90 (`ZakoRecordFirstFlow.swift`). For E→E it refuses today (`ZakoE2EFlow.e2eRecordFirstMessage`, decided by EZZK's server time through `ZakoRegime.resolve`). From New Year the advocate of the relayed feedback (2026-11-17) could therefore not convert a client's multi-file authorization into one PDF for the Obchodný register at all. Project C makes E→E work in the new order.

The owner's decisions:
- 2026-11-17: order A, B, then C right after.
- 2026-11-18: MIRRI has not answered the questions of 2026-10-16; build C on the same assumptions as P→E.
- 2026-11-18: approach 1 (reuse the P→E record-first machinery, add the E→E record form 1.2, fill its mandatory fields and the optional ones today's data supports).
- 2026-11-18: an authorization whose qualification DSS leaves undetermined (any value outside QESIG, QESEAL, ADESIG(_QC), ADESEAL(_QC), NOT_ADES*, for example `INDETERMINATE_QESIG` or empty) is refused in the new order before an evidence number is allocated, because record 1.2's closed `AuthorizationType` enum has no honest value for it; the advocate can repeat the verification.
- 2026-11-18: `ValidityVerificationResult` keeps record 1.0's rule: the slim ETSI report in Demo and Testovacia evidencia, the qualified validation service's report in Ostrá evidencia (still locked for E→E); record 1.2's wording ("neposkytnutý" for non-qualified types) is not applied.

## 2. Assumptions (the same as P→E, findings `docs/ZAKO-2027-FINDINGS-2026-10-16.md`)

- EZZK 1.0 SOAP keeps running in 2027; the record is sent with `ReceiveConversionRecord` and looked up until processed.
- An evidence number is still allocated before the record (record forms keep a mandatory `ConversionRecordEvidenceNumber`).
- The clause stays today's E→E clause 1.3, as P→E keeps clause 1.3.
- The new record form is the published `50349287.ConversionRecordOfElectronicDocumentToElectronicDocument_2021.sk` 1.2 (inForceFrom 2024-10-01, zip SHA-256 `cfcf60e1f27dcec319e43cbbf6e2e48d882798f1058f22aea383a0af251453b8`, fetched 2026-11-18 from `https://www.slovensko.sk/static/eform/dataset/`), as P→E uses `ConversionRecordOfPaperToElectronicDocument_2021.sk` 1.2.
- The same instant `ZakoRegime.recordFirstFrom` (2026-12-31T23:00Z) switches E→E to record 1.2 and the new order; rows signed before keep record 1.0.
- `AppSettings.zakoRecordFirstPreview` forces the new order before the date in Demo and Testovacia evidencia, as for P→E; `ZakoRecordFirstPolicy.refusesOutsideDemo` applies to E→E too.

## 3. Goals

- E→E (single PDF, one-PDF container, multi-file container) runs in the new order: validate both forms, sign the record first, register the row only once the record is signed, send, wait until EZZK reports it processed (30 s polls, up to 30 minutes, "Zastaviť čakanie"), then sign the client output (ASiC-E or one PDF), with "Dokončiť konverziu" resuming at the wait or the client signature.
- Record E→E 1.2 is rendered from the same `ElectronicOriginal` and `E2EFormModel` data as record 1.0, validated against the official schema, and signed and sent exactly as the P→E record 1.2.
- `.rejected` ends the conversion with nothing delivered, as for P→E.

## 4. Non-goals

- The optional record fields that need new engine work: `DSId` (ISO 14533-4), `ContentType` (from XAdES `DataObjectFormat` or the CMS content type), `AuthorizationTimeBefore` / `AuthorizationTimeAfter` with their timestamp names. They can be added when MIRRI says how it wants them.
- A new clause form, EZZK 2.0, the unsigned record of draft § 7 ods. 3 písm. b).
- Opening Ostrá evidencia for E→E (`E2EProductionPolicy.enabled` stays false) or for the one PDF (`SinglePDFProductionPolicy.enabled` stays false).
- The phone: refused in the new order, as for P→E.

## 5. Anti-goals

- No client output is delivered before EZZK reports the record processed.
- A failed record signature leaves no register row and keeps the evidence number in the pool.
- A resume never signs a client output that differs from what the record describes: the original (its files, their order, their fingerprints), the form and the EZZK mode must be the ones signed into the record, and the output is the one the conversion started with.
- P→E behaviour stays byte for byte the same.

## 6. Approaches considered

1. **Reuse the P→E record-first machinery, add the E→E record 1.2 (chosen).** E→E prepares the new document, the clause and the record and hands them to the same steps P→E uses: record signature, row, send, wait, client signature, resume. New: the record 1.2 renderer, the form choice by EZZK time, removing the refusal. The tested wait and resume stay one piece of code.
2. **A separate E→E record-first flow.** Faster to write first, but the wait and resume would exist twice and drift. Rejected.
3. **As 1, filling every optional field.** Needs engine work (DSId, content type, before and after times) and raises the risk before 1. 1. Rejected for now; the optional fields can follow MIRRI's answer.

## 7. Design

### 7.1 The form

- Embed record E→E 1.2 beside the others (`docs/reference/forms/record-e2e-1.2`, `scripts/embed-official-forms.sh`, provenance entry, `OfficialForm.recordE2E_1_2`), the official schema used as is (libxml2 compiles it, checked 2026-11-18).
- `FormPackRepository` gains the E→E form choice by conversion time, so every E→E row's `FormPackStamp` names its record form; record 1.0 rows keep 1.0.

### 7.2 Rendering record E→E 1.2 (`ConversionRecordE2E12Renderer`)

From `E2EFormModel`, in the schema's element order:
- `OriginalDocumentInfo` per original document: name, type (per file, B's rule), format as codelist CL009008 (the form's own annotation: code `https://metais.vicepremier.gov.sk/set/codelist/CL009008`, items PDF, TXT, PNG, XMLDataContainer, Iný with `OriginalDocumentFormatOther`), item codes and names read from MetaIS and kept with their source in `ZakoCodelists` as P→E did for CL009009 on 2026-10-16; a PDF/A original gets a PDF/A item only if CL009008 has one, else PDF (my call); JPEG as Iný with `OriginalDocumentFormatOther` JPEG, fingerprint as **hex**, method sha-256 (CL009005).
- `OriginalDocumentTimestamp`: every timestamp that covers documents rather than a signature, when the evidence lists it; none otherwise (the form's annotation lists all of them):
  - PDF document timestamps (engine fact `documentTimestamps`) of the PDF original and of each PDF in a container, also of a PDF without PAdES signatures (the engine gives such a PDF nested evidence with no signatures; a one-PDF container keeps the single-PDF path and its record 1.0 and clause unchanged). Each names the longest document of its file whose revision lies within the timestamped bytes; one covering less than the first signed revision (Chevron7's own PAdES content timestamp, a timestamp revision before the first PAdES signature) names the file's first document, and that signature authorizes it. A timestamp without a covered length or a time is left out.
  - XAdES content timestamps (`AllDataObjectsTimeStamp`, `IndividualDataObjectsTimeStamp`, which Chevron7 adds to an ASiC-E under the QTS switch), engine fact `contentTimestamps` with the carrying signature (`signatureId`) and the covered data objects (`coveredDataObjects`, DSS's timestamp scope names, the same names as the signature scopes). Each names the whole-file document of every covered file and is an `AuthorizedTimeStamp` of the container signature that carries it. One that cannot be tied to the original's documents and its carrier (no time, no coverage, a file the original does not hold, a carrier that does not cover it) is refused by record 1.2 (`E2EDeliveryBuilder.Failure.unresolvedContentTimestamp`), never left out; record 1.0 does not list timestamps and is unchanged.
  - CAdES and PAdES content timestamps (the signed attribute `id-aa-ets-contentTimestamp`, DSS `CONTENT_TIMESTAMP`, never among the timestamps produced after the signature) are in the same engine fact `contentTimestamps`, top level and in a container PDF's nested evidence (owner's decision of 2026-11-18: refuse rather than omit): a CAdES container signature's one is resolved as a XAdES one once the ASiC manifest (`META-INF/ASiCManifest*.xml`, which its CMS signs and DSS adds to the scopes) is set aside; a PAdES one of a PDF original has no container carrier and stays unresolved (`unresolvedContentTimestamp`); one inside a container PDF's own PAdES signature is refused by record 1.2 (`E2EDeliveryBuilder.Failure.nestedContentTimestamp`), both at the dry run before an evidence number.
- `Authorization` per authorization: `AuthorizationName` (the last path component of the container signature's file, `signaturesN.xml` of `META-INF/signaturesN.xml`, from a new engine fact `signatureFilename`, when no other authorization has the same one; else `Autorizacia1`, `Autorizacia2`, ... in authorization order, skipping a name already taken), `AuthorizationType` from the enum (finer than codelist 54: `ADESIG_QC` and `ADESEAL_QC` become "... s použitím kvalifikovaného certifikátu"), and one `OriginalDocumentAuthorization` with the documents it names, `AuthorizedAuthorization` and `AuthorizedTimeStamp` as the form's annotations describe them: a container signature names the nested PAdES authorizations of the files it covers (B's nested signatures), and inside one PDF a later PAdES signature names the earlier signatures and document timestamps its revision covers, state from the enum (masculine: "platný", "neplatný", "nie je možné zistiť", mapped from `ValidityState`), `AuthorizationTime` when known, `ElectronicSignature` (signature value, obligatory for every signature and seal type: a missing value is refused by `E2EDeliveryBuilder`, `missingSignatureValue`), `ValidityVerificationResult` (slim ETSI report, or the qualified service's report, as record 1.0), validation time, `AuthorizationPerson` (`PersonID`, `Mandant`, `Mandate`: both required non-empty; when the certificate carries none, the form's own words with diacritics, "Žiadna" for `Mandant` and "Žiaden" for `Mandate`; `Mandate` otherwise the last arc of the mandate policy OID plus its `userNotice` text, as today), `TimeStamp` (the oldest valid, as today, with a generated `TimeStampName`), `CertificateType` from the qualification (QESIG/QESEAL: qualified on QSCD; ADESIG_QC/ADESEAL_QC: qualified, not on QSCD; else omitted), the enum values copied byte for byte (the first uses a hyphen, the others an en dash), `OtherAuthorizationInfo` as today.
- `NewDocumentInfo`: name, `NewDocumentType` (the original's type, as P→E record 1.2), format codelist CL009009 (item 2 PDF/A-2, or item 3 PDF/A-3 for the one PDF, as P→E record 1.2; record 1.2 has no `NewDocumentFormatOther`), hex fingerprint, method.
- Evidence number as URI, used device, conversion time in `+01:00` / `+02:00`, the person as P→E record 1.2 (no `Position`).

### 7.3 Flow

- The forms are checked with a placeholder number before EZZK's time is known, using the record form of the Mac-clock regime (`expectedRegime`), and checked again once EZZK's time decides the regime.
- `ZakoE2EFlow.authorizeE2E`: where it refuses today, `.recordFirst` goes on: validate clause 1.3 and record 1.2, build the client output as today (ASiC-E entries, or the one PDF's fixed target and appended clause), and call the shared record-first start.
- `startRecordFirst` and `RecordFirstPending` become direction-neutral: the register row is built by the caller (P→E as today; E→E as its current `.signed` row with validation evidence, `clientOutput`, `revisionOneLength`). `RecordFirstPending` carries the direction and, for E→E, what a resume must match (the original's document fingerprints in order).
- `resumeRecordFirst` for E→E refuses when the original, its order, the form or the EZZK mode changed, as P→E refuses on the mode or form; the client output is the one the conversion started with (kept in `RecordFirstPending`, as for P→E), since the record already names it.
- The client signature after the wait reuses E→E's current signing code for both outputs.
- Remove `e2eRecordFirstMessage` and its two refusals.

### 7.4 Register and EZZK

Unchanged: the row, the record container, the submission coordinator and the status checker already handle record 1.2 for P→E; the record's form decides nothing in SOAP.

### 7.5 Refusal of an undetermined qualification

`E2EVerificationGate` (or the record-first branch before `fetchEvidenceNumber`) refuses under `.recordFirst` when any authorization's qualification maps to no record 1.2 `AuthorizationType`, with a Slovak message naming the signer, for example "Kvalifikáciu podpisu \(signer) sa nepodarilo určiť. Podľa postupu od 1. 1. 2027 ho nemožno zapísať do záznamu. Skúste overenie znova." The 1.0 path keeps today's "Iný" with its text.

## 8. Tests

- Renderer: record E→E 1.2 for a signed PDF with two revisions, a one-PDF container, a multi-file container with a nested PAdES and a second container signature covering one file; each validates against the official schema; enum and codelist values pinned; hex fingerprints; `Žiadna` / `Žiaden` for an absent mandant or mandate; `AuthorizedAuthorization` names the nested authorizations.
- Refusal of an undetermined qualification under `.recordFirst` before any number is allocated, and the 1.0 path unchanged.
- Form choice: before and after `recordFirstFrom`, and with the preview in Demo and Testovacia evidencia.
- Flow (Demo, fake signing and EZZK): the record is signed before the client output; nothing is delivered before `.processed`; `.rejected` delivers nothing; a failed record signature leaves no row and keeps the number; resume at the wait and at the client signature; resume refused after the original's order or form changed; both client outputs; P→E record-first tests unchanged.

## 9. Left to the builder

- How `startRecordFirst` is split (closure, protocol or value for the row), within "P→E unchanged".
- `TimeStampName` and `AuthorizationName` fallbacks' exact spelling within the schema's patterns.
- Whether the engine already exposes the signature file name and document-level timestamps, and the smallest change if not.

## 10. Calls made without the owner (to check while reading)

- "Žiadna" / "Žiaden" for a missing mandant or mandate, the form's own words.
- CL009008 items from MetaIS; a PDF/A original is PDF unless CL009008 has a PDF/A item.
- `AuthorizationType` uses the finer enum ("s použitím kvalifikovaného certifikátu") where DSS says `ADESIG_QC` / `ADESEAL_QC`.
- `CertificateType` filled only where the qualification decides it.
- The one PDF in the new order checks PDF/A-3b before the record is signed, as A does for P→E.
