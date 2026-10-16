# ZaKo from 1. 1. 2027: record first (design)

Findings and sources: `docs/ZAKO-2027-FINDINGS-2026-10-16.md`. Owner's decision of 2026-10-16:
option (c), that is a date switch, record form 1.2 and a record-first flow on today's EZZK SOAP,
plus a switch that refuses ZaKo outside Demo from 1. 1. 2027 in case EZZK 2.0 is not ready; keep
clause 1.3; build the clause only after EZZK reports the record processed.

## Regime

- `ZakoRegime` (`Sources/Chevron7Kit/Attestation/ZakoRegime.swift`): `.clauseFirst` (today) and
  `.recordFirst` (zákon č. 305/2013 Z. z. § 36 ods. 3 from 1. 1. 2027).
- `ZakoRegime.recordFirstFrom` is `2026-12-31T23:00:00Z`, which is 1. 1. 2027 00:00 in
  Europe/Bratislava. One constant, so a further postponement is a one-line change.
- The regime of a conversion follows its conversion time, which is EZZK's server time
  (`ConversionExecutionDateTime`), never the Mac's clock. The same instant splits the two P→E form
  packs in `FormPackRepository` (`effectiveUntil` of the 1.0 pack, `effectiveFrom` of the 1.2
  pack), so every register row's `FormPackStamp` says which record form it carries.
- Test preview: `AppSettings.zakoRecordFirstPreview` (Advanced, ZaKo group) makes a conversion
  record-first before the date, in Demo and Testovacia evidencia only; production ignores it.
  It forces the 2027 form pack too (the pack is resolved at
  `max(conversionTime, ZakoRegime.recordFirstFrom)`), so a preview conversion sends a record 1.2,
  while its `ConversionExecutionDateTime` stays the real server time. This is how the flow and
  record 1.2 are checked end to end on test EZZK before 2027.
- `ZakoRegime.resolve(conversionTime:mode:preview:)` is the one function that applies the date,
  the preview and the mode.
- Refusal switch: `ZakoRecordFirstPolicy.refusesOutsideDemo` (owner constant, `false`). When true,
  a record-first conversion outside Demo stops before a number is allocated, with
  `ZakoRecordFirstPolicy.refusalMessage`. Checked by the Mac's clock before the number is
  allocated, and again on the conversion time from EZZK, which decides (a conversion crossing
  midnight is already stopped by the same-day evidence number rule).

## Record form 1.2

- `docs/reference/forms/record-1.2/` gets the official `schema.xsd` and the TXT sign presentation
  `form103.sb.xslt` from `50349287.ConversionRecordOfPaperToElectronicDocument_2021.sk/1.2.zip`
  (sha256 `3b43bc0f...e68e`), with provenance. libxml2 compiles the official schema, so there is
  no validation copy. `scripts/embed-official-forms.sh` embeds them; `OfficialForm.record_1_2`.
- `ConversionRecord12Renderer` renders it from `ConversionFormModel`, in schema order:
  - security element description: the clause codelist 15 code, except
    `trvale spojenie dokumentu - iné`, which is `trvalé pevné spojenie - iné` in 1.2; the other
    codes Chevron7 uses are 1.2 enum values word for word. `...DescriptionOther` as in 1.0.
  - location: the clause codelist 11 Slovak name in lower case (`vpravo dole`), which is the 1.2
    enum; `NewDocumentSecurityElementsPage` is gone.
  - paper size: `A4`/`A3` as is, otherwise `Iný` with `PaperSizeOther`.
  - `NewDocumentType` = the original document's type (the new document is the same document).
  - `ContentType` `application/pdf`.
  - `NewDocumentFormat`: CodelistCode `https://metais.vicepremier.gov.sk/set/codelist/CL009009`,
    item `2` "PDF/A-2" (MetaIS, 2026-10-16: 1 PDF/A-1, 2 PDF/A-2, 3 PDF/A-3, 4 PNG).
  - fingerprint: hex SHA-256; method CodelistCode `https://metais.vicepremier.gov.sk/set/codelist/CL009005`,
    item `2.16.840.1.101.3.4.2.1` "sha-256".
  - evidence number as `https://data.gov.sk/id/egov/conversion-record/<number>`.
  - person: given and family name, no `Position`; legal subject; `ID` with CodelistCode
    `https://data.gov.sk/set/codelist/CL004001` (MetaIS gives no URI for CL004001; the
    `data.gov.sk/set/codelist` form is the one MetaIS uses for CL009005 and CL009009), item `7`,
    only for an 8 or 12 digit IČO, as in 1.0.
- `ZakoRecordDeliveryBuilder.build(model:form:)` validates against the chosen form and wraps the
  XDC with it; file names stay `<number>.record.xml.xdcf`.

## Record-first flow (`ZakoSessionStore.authorizeAndSign`, card only)

1. Unchanged preconditions (mode, Demo provider, register load, mandate certificate).
2. Preliminary regime and refusal switch, then the evidence number as today.
3. Conversion time from EZZK, same-day check, regime from the conversion time.
4. PDF/A, delivery normalisation, fingerprint (unchanged).
5. Model, record 1.2 validated, clause 1.3 validated (both before any signature).
6. **Sign the record** (first PIN or BOK) and verify its container. Only then register the row
   `.signed` with the stored record container and `formPack`, and remove the number from the pool
   (the signed record carries it). A failed or cancelled record signature leaves no row and keeps
   the number in the pool for the next attempt. The row is held through the **send**
   (`EZZKStatusChecker.submit(id:)` right after release).
7. **Wait** until EZZK reports the row processed: `EZZKStatusChecker.verify(id:)` every 30 s
   (`ZakoSessionStore.recordFirstPollInterval`), up to 30 minutes (`recordFirstWaitLimit`), showing
   "Čakám, kým EZZK spracuje záznam…" with a "Zastaviť čakanie" button (the wait otherwise holds
   the window, since authorizing disables reset). A busy row (the periodic check has it) is
   retried; `.queuedForSubmission` (EZZK did not know the number) is sent again; `.outcomeUnknown`
   keeps waiting; `.rejected` stops the conversion with EZZK's code and text, drops the pending
   state, and nothing reaches the client.
8. **Sign the client ASiC-E** (PDF/A + clause 1.3, second PIN or BOK, qualified timestamps as
   today), verify it, deliver it, update the row's delivered file names.

Interruptions keep a `RecordFirstPending` value in the session (PDF/A bytes, model, clause XDC,
row id, stage). Pressing "Autorizovať konverziu" again resumes at the stage reached: waiting for
EZZK, or the client signature. A new document drops it. The record and its number are never
signed or allocated twice for one conversion. If the app quits while waiting, the row stays in
the register (`EZZKStatusChecker` keeps checking it) but no client container exists; the Done
screen and the register say so (`EvidenceRecord.deliveredFileName` is nil).

After EZZK refuses the record, or its row or signature is gone, `startNewRecordAttempt` gives the
next attempt a new register row and a new evidence number (EZZK may have consumed the old one);
the refused row stays in the Register. The client signature holds the row
(`EZZKStatusChecker.hold`), so it cannot be deleted while the conversion is completed.

Known limit: `RecordFirstPending` lives in memory. If Chevron7 quits after EZZK processed the
record and before the client signature, the row stays `.processed` without a delivered file and
the conversion cannot be resumed; the advocate converts again with a new number.

Not offered under record-first: the phone (it cannot sign the record), and a row whose record
signature failed (`.recordUnsigned`) cannot continue; the advocate starts again.

## Unchanged

Rows signed before the switch keep record 1.0 and are sent and looked up as today (draft decree
§ 12 ods. 1). `EZZKSubmissionCoordinator` rules, the evidence number pool, the same-day rule,
production policy and timestamps.

## Plan

1. Record 1.2 reference files, provenance, embed script, `OfficialForm.record_1_2`,
   `OfficialFormTests`.
2. `ConversionFormModel` gains `fingerprintHex` and `newDocumentType`; `ConversionRecord12Renderer`;
   `ZakoRecordDeliveryBuilder.build(model:form:)`; tests that the rendered record validates and
   carries the mapped values.
3. `ZakoRegime`, `ZakoRecordFirstPolicy`, two form packs; tests for the instant and both packs.
4. `AppSettings.zakoRecordFirstPreview` with the Advanced toggle.
5. `authorizeAndSign` branch, `RecordFirstPending`, polling and resume; app tests with the
   recording signing provider and an in-memory EZZK (Demo lookup answers processed; a scripted
   lookup for the waiting and the refusal cases).
6. Docs: findings, `EZZK-INTEGRATION.md`, `P2E-EZZK-FINDINGS.md`, CLAUDE.md and AGENTS.md,
   Slovak change note.
7. Pre-check M4 on test EZZK with a card signature: only the owner can sign; the probe command is
   in the PR description.
