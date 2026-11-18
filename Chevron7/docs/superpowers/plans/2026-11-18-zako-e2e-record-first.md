# ZaKo E→E in the Order of 1. 1. 2027: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** E→E guaranteed conversion (single PDF, one-PDF container, multi-file container; ASiC-E or one-PDF client output) runs in the record-first order from 1. 1. 2027: record E→E 1.2 signed and sent first, the client output signed only after EZZK processed it.

**Architecture:** Embed the official record `50349287.ConversionRecordOfElectronicDocumentToElectronicDocument_2021.sk` 1.2 and render it from the existing `E2EFormModel`. Make the P→E record-first machinery (`startRecordFirst`, `RecordFirstPending`, resume, client signature) direction-neutral and call it from `ZakoE2EFlow` where it refuses today. Engine adds two facts the form names (signature file name, PDF document timestamps).

**Tech Stack:** Swift 6 / SwiftUI / XCTest; Java 25 / DSS 6.4 / JUnit; `/usr/bin/xmllint`.

**Spec:** `Chevron7/docs/superpowers/specs/2026-11-18-zako-e2e-record-first-design.md` (approved by the owner 2026-11-18).

## Global Constraints

- Branch `claude/e2e-record-first`, stacked on B (PR #104); P→E behaviour byte for byte unchanged; E→E before `ZakoRegime.recordFirstFrom` (2026-12-31T23:00Z) unchanged (record 1.0).
- Record E→E 1.2: official schema used as is; zip SHA-256 `cfcf60e1f27dcec319e43cbbf6e2e48d882798f1058f22aea383a0af251453b8` from `https://www.slovensko.sk/static/eform/dataset/50349287.ConversionRecordOfElectronicDocumentToElectronicDocument_2021.sk/1.2.zip`, inForceFrom 2024-10-01.
- `OriginalDocumentFormat`: codelist CL009008, code `https://metais.vicepremier.gov.sk/set/codelist/CL009008`, items read from MetaIS (source and date in a comment); a PDF/A original gets a PDF/A item only if CL009008 has one, else PDF; JPEG as Iný with `OriginalDocumentFormatOther` `JPEG`.
- `NewDocumentFormat`: CL009009 item 2 PDF/A-2 (`ZakoCodelists.record12PDFA2Item`) or item 3 PDF/A-3 for the one PDF (`record12PDFA3Item`); fingerprints hex; method CL009005 sha-256 (`record12SHA256Item`).
- `Mandant` / `Mandate` without a value in the certificate: `Žiadna` / `Žiaden`.
- State enum masculine: `platný`, `neplatný`, `nie je možné zistiť`. `CertificateType` values byte for byte from the schema (the first uses a hyphen, the others an en dash).
- An authorization whose DSS qualification is outside QESIG, QESEAL, ADESIG, ADESIG_QC, ADESEAL, ADESEAL_QC, NOT_ADES* is refused in the new order before an evidence number is allocated (owner, 2026-11-18).
- `ValidityVerificationResult` keeps record 1.0's rule (slim report, or the qualified report when attached) (owner, 2026-11-18).
- No client output before `.processed`; a failed record signature leaves no row and keeps the number; the phone is refused in the new order; `E2EProductionPolicy.enabled` and `SinglePDFProductionPolicy.enabled` stay false.
- Slovak user strings, English code, no em dashes (U+2014); `CLAUDE.md` = `AGENTS.md`; tests never touch real Application Support, Caches or named UserDefaults.
- Swift tests from `Chevron7/`: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter '<Target>\.<Class>'`. Engine: as in the `engine-maven-tests` memory.

## Review Focus

1. A resume after the advocate changed the file order, a per-file type or the client output must be refused, never sign a client output the record does not describe (Task 5 `testResumeRefusedAfterOrderChange`, `testResumeRefusedAfterTypeChange`).
2. The Mac clock says 2026 but EZZK's time says 2027 (or the reverse): forms checked against the wrong record form must be rechecked, never signed (Task 5 `testRegimeFlipAtEZZKTimeRechecksForms`).
3. Record 1.2 for a PDF with two PAdES revisions and a document timestamp: the later signature names the earlier one and the timestamp (Task 3 `testPAdESChainNamesEarlierSignatureAndTimestamp`).
4. An undetermined qualification on a nested signature only (not the container's): still refused (Task 3 `testNestedUndeterminedQualificationIsUnmappable`).
5. Every enum and codelist value validates against the official schema for each authorization type (Task 3 `testEveryAuthorizationTypeValidates`).

---

### Task 1: Record E→E 1.2 form, CL009008 and the E→E form packs

**Files:**
- Create: `Chevron7/docs/reference/forms/record-e2e-1.2/` (schema.xsd and the presentation the other forms keep), provenance entry in `Chevron7/docs/reference/forms/provenance.json`
- Modify: `Chevron7/scripts/embed-official-forms.sh`, `Chevron7/Sources/Chevron7Kit/Attestation/Forms/OfficialForm.swift`, `OfficialFormFiles.swift` (generated), `Chevron7/Sources/Chevron7Kit/Attestation/ZakoCodelists.swift`, `Chevron7/Sources/Chevron7Kit/Attestation/FormPack.swift`
- Test: `Chevron7/Tests/Chevron7KitTests/OfficialFormTests.swift`, `FormPackTests` (or the existing pack tests file)

**Interfaces:**
- Produces: `OfficialForm.recordE2E_1_2` (namespace `http://schemas.gov.sk/form/50349287.ConversionRecordOfElectronicDocumentToElectronicDocument_2021.sk/1.2`, identifier `http://data.gov.sk/doc/eform/50349287.ConversionRecordOfElectronicDocumentToElectronicDocument_2021.sk/1.2`, version `1.2`); `ZakoCodelists.record12OriginalFormatCode`, `record12OriginalFormatPDF`, `record12OriginalFormatPNG`, `record12OriginalFormatOther` (plus PDF/A items if CL009008 has them); `FormPackRepository.e2eRecord10Unverified`, `e2eRecord12Unverified` (direction `.electronicToElectronic`, split at `ZakoRegime.recordFirstFrom`), `FormPackRepository.e2ePack(at: Date) -> ConversionFormPack`, and `recordForm(of:)` returning `.recordE2E_1_0` / `.recordE2E_1_2` for those packs.

- [ ] **Step 1: Failing tests:** `testRecordE2E12IsEmbeddedWithItsHash` (the embedded schema's SHA-256 equals the provenance entry; the form compiles with xmllint), `testE2EPackSplitsAtRecordFirstFrom` (one second before: record 1.0 pack; at the instant: 1.2 pack), `testRecordFormOfE2EPacks`, `testCL009008ItemsCarryTheirSource` (codes non-empty, code URI exact).
- [ ] **Step 2: Run** `--filter 'Chevron7KitTests\.(OfficialFormTests|FormPackTests)'`. Expected: fail.
- [ ] **Step 3: Implement.** Download the zip (own empty folder, untrusted data), check the SHA-256 above, copy as the other forms are copied. Read CL009008 items from MetaIS (`https://metais.vicepremier.gov.sk/codelists/` or the data.gov.sk codelist page for CL009008), recording the URL and date in the comment; if MetaIS cannot be reached, stop and report BLOCKED rather than inventing codes.
- [ ] **Step 4: Run** the same filter. Expected: pass.
- [ ] **Step 5: Commit** `feat(zako): embed record E→E 1.2 and the E→E form packs`

### Task 2: Engine: signature file names and PDF document timestamps

**Files:**
- Modify: `engine/src/main/java/digital/slovensko/autogram/ui/machine/ConversionEvidenceService.java`
- Modify: `Chevron7/Sources/Chevron7Kit/Conversion/ConversionEvidence.swift`, `Chevron7/Tests/Chevron7TestSupport/E2EEvidenceFixtures.swift`
- Test: `engine/.../ConversionEvidenceServiceTest.java`, `Chevron7/Tests/Chevron7KitTests/ConversionEvidenceTests.swift`

**Interfaces:**
- Produces (JSON, in every evidence object, top and nested): `signatures[*].signatureFilename` (DSS `SignatureWrapper.getSignatureFilename()`, absent for PAdES); `documentTimestamps`: `[{id, productionTime, producerCommonName, indication, qualification, coveredRevisionLength}]` for DSS timestamps of type `DOCUMENT_TIMESTAMP` (PDF), `coveredRevisionLength` from its byte range.
- Produces (Swift): `ConversionEvidence.Signature.signatureFilename: String?`, `ConversionEvidence.documentTimestamps: [DocumentTimestamp]` and the same on `NestedEvidence`, with `DocumentTimestamp { id, productionTime: Date?, producerCommonName: String?, indication: String?, qualification: String?, coveredRevisionLength: Int? }`; old payloads decode with `[]` / nil.

- [ ] **Step 1: Failing tests:** engine `signatureFilenameNamesTheContainerSignatureFile` (`META-INF/signatures...xml`), `pdfDocumentTimestampIsListedWithItsRevision` (build a PDF with a PAdES signature then a document timestamp via DSS `PAdESService.timestamp`, using the test TSP source the engine tests already have, or a mock `TSPSource` if none); Swift `testDecodesSignatureFilenameAndDocumentTimestamps`, `testOldPayloadHasNoDocumentTimestamps`.
- [ ] **Step 2: Run** the engine and Swift tests. Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: pass, the existing `ConversionEvidenceServiceTest` and `ConversionEvidenceTests` included.
- [ ] **Step 5: Commit** `feat(engine): signature file names and PDF document timestamps in the evidence`

### Task 3: Rendering record E→E 1.2

**Files:**
- Create: `Chevron7/Sources/Chevron7Kit/Attestation/Forms/ConversionRecordE2E12Renderer.swift`
- Modify: `Chevron7/Sources/Chevron7Kit/Attestation/Forms/E2EDeliveryBuilder.swift`, `Chevron7/Sources/Chevron7Kit/Conversion/ElectronicOriginal.swift` (qualification kept on `Authorization`)
- Test: `Chevron7/Tests/Chevron7KitTests/ConversionRecordE2E12RendererTests.swift`

**Interfaces:**
- Consumes: Task 1 form and codes, Task 2 facts, `E2EFormModel` (with `originalDocumentTypes`), `ElectronicOriginal` (B: documents with `fileEntryName`, authorizations with `fileEntryName`, `files`).
- Produces:
  - `ElectronicOriginal.Authorization.qualification: String?` (the DSS value) and `ElectronicOriginal.Authorization.signatureFilename: String?`, `ElectronicOriginal.documentTimestamps: [DocumentTimestamp]` (top and nested, with their file entry name).
  - `ConversionRecordE2E12Renderer().render(_ m: E2EFormModel) -> String`.
  - `ConversionRecordE2E12Renderer.authorizationType(qualification:qcType:) -> String?` (the enum text, nil when unmappable) and `ConversionRecordE2E12Renderer.unmappableAuthorizations(_ original: ElectronicOriginal) -> [ElectronicOriginal.Authorization]`.
  - `E2EDeliveryBuilder.record(_ m: E2EFormModel, form: OfficialForm) throws -> ZakoRecordDelivery` (`.recordE2E_1_0` renders as today, `.recordE2E_1_2` with the new renderer, each validated against its form). The old `record(_:)` stays as `record(m, form: .recordE2E_1_0)`.
- Mapping decided here (spec 7.2): `AuthorizationName` = `signatureFilename`'s last path component, else `Autorizacia<N>` in authorization order; `TimeStampName` = `CasovaPeciatka<N>` in document order of appearance; `AuthorizationType`: QESIG `kvalifikovaný elektronický podpis`, ADESIG_QC `zdokonalený elektronický podpis s použitím kvalifikovaného certifikátu`, ADESIG `zdokonalený elektronický podpis`, NOT_ADES* `elektronický podpis` (seal variants by `qcType == "eseal"` or the SEAL values); `CertificateType`: QESIG/QESEAL `certifikát - kvalifikovaný, certifikát je na QSCD`, ADESIG_QC/ADESEAL_QC `certifikát – kvalifikovaný, certifikát nie je na QSCD`, else omitted; `AuthorizedAuthorization`: a container signature names the nested PAdES authorizations of the files it covers; a PAdES signature names the PAdES signatures of the same file with a shorter signed revision; `AuthorizedTimeStamp`: a PAdES signature names the document timestamps of its file with a shorter covered revision; `OriginalDocumentTimestamp`: each document timestamp, naming the revision document it covers.

- [ ] **Step 1: Failing tests** (fixtures from `E2EEvidenceFixtures`, B's multi-file helpers), each validating against `.recordE2E_1_2`: `testSignedPdfTwoRevisionsRecord12`, `testOnePdfContainerRecord12`, `testMultiFileWithNestedAndPartialSignatureRecord12` (`AuthorizedAuthorization` names the nested authorization; the partial signature names only its file), `testPAdESChainNamesEarlierSignatureAndTimestamp`, `testEveryAuthorizationTypeValidates` (QESIG, QESEAL, ADESIG, ADESIG_QC, ADESEAL, ADESEAL_QC, NOT_ADES), `testMissingMandantIsZiadna` (`<Mandant>Žiadna</Mandant>`, `<Mandate>Žiaden</Mandate>`), `testFingerprintsAreHex`, `testStatesAreMasculine`, `testOnePdfNewDocumentIsPDFA3Item`, `testUnmappableQualificationIsReported` (`INDETERMINATE_QESIG`, empty), `testNestedUndeterminedQualificationIsUnmappable`, `testRecord10UnchangedThroughNewSignature` (record 1.0 XML equal to before for an existing fixture).
- [ ] **Step 2: Run** `--filter 'Chevron7KitTests\.(ConversionRecordE2E12RendererTests|E2EFormRendererTests)'`. Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same plus `ElectronicOriginalTests`. Expected: pass.
- [ ] **Step 5: Commit** `feat(zako): render record E→E 1.2`

### Task 4: Direction-neutral record-first machinery

**Files:**
- Modify: `Chevron7/Sources/Chevron7App/ZakoRecordFirstFlow.swift`, `Chevron7/Sources/Chevron7App/ZakoSessionStore.swift` (the P→E caller)
- Test: `Chevron7/Tests/Chevron7AppTests/ZakoRecordFirstFlowTests.swift`

**Interfaces:**
- Produces:
  - `RecordFirstPending.direction: ConversionDirection` and `RecordFirstPending.originalFingerprints: [Data]?` (E→E: the original's document SHA-256 values in order, nil for P→E).
  - `startRecordFirst(_ pending: RecordFirstPending, recordDelivery: ZakoRecordDelivery, identityID: String, makeRow: () -> EvidenceRecord) async throws`: the caller builds the `.signed` row; the function keeps the signing, row storing, pool removal, profile save, hold and wait exactly as today. The P→E caller passes the row it builds today (form pack stamp, security review, sheets).
  - `resumeRecordFirst` also refuses when `pending.direction == .electronicToElectronic` and the current original's document fingerprints (in order) differ from `originalFingerprints`, or the per-file types differ (compared through `formMatches`, which already compares `AttestationData`), with `recordFirstOriginalChangedMessage` = "Pôvodný dokument alebo poradie jeho súborov sa od podpisu záznamu zmenili. Dokončite konverziu s pôvodným stavom alebo začnite novú."
- [ ] **Step 1: Failing test:** `testE2EPendingRefusesAfterOriginalChange` (a pending with fingerprints `[a, b]` and a current original `[b, a]` refuses with that message and signs nothing). All existing `ZakoRecordFirstFlowTests` stay green unchanged (they are the P→E guarantee).
- [ ] **Step 2: Run** `--filter 'Chevron7AppTests\.ZakoRecordFirstFlowTests'`. Expected: the new test fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same and `--filter 'Chevron7AppTests\.(ZakoSinglePDF|ZakoE2EFlowTests)'`. Expected: pass.
- [ ] **Step 5: Commit** `refactor(zako): record-first machinery for both directions`

### Task 5: E→E in the record-first order

**Files:**
- Modify: `Chevron7/Sources/Chevron7App/ZakoE2EFlow.swift`, `Chevron7/Sources/Chevron7App/ZakoSessionStore.swift` (the E→E branch of `beginAuthorization`/authorize at lines ~1484-1490)
- Test: `Chevron7/Tests/Chevron7AppTests/ZakoE2EFlowTests.swift` (or a new `ZakoE2ERecordFirstTests.swift`)

**Interfaces:**
- Consumes: Tasks 1, 3, 4.
- Produces: `e2eRecordFirstMessage` deleted; `e2eUndeterminedQualificationMessage(signer:)` = "Kvalifikáciu podpisu \(signer) sa nepodarilo určiť. Podľa postupu od 1. 1. 2027 ho nemožno zapísať do záznamu. Skúste overenie znova."
- Behaviour: by the Mac-clock regime, before a number: refuse the phone (as P→E), refuse unmappable authorizations (`unmappableAuthorizations`), check clause 1.3 and the record of `FormPackRepository.e2ePack(at:)` with a placeholder number; after EZZK's time: if the regime differs from the Mac-clock one, check the forms again for the real regime before anything is signed; under `.recordFirst` build the client output as today (ASiC-E entries or the one PDF's fixed target and appended clause, PDF/A-3b check before the record), build the `.signed` row as today plus `formPack`, and call `startRecordFirst`; under `.clauseFirst` today's path, now stamping the row's `formPack` with the record 1.0 pack.

- [ ] **Step 1: Failing tests** (Demo, preview on, fake signing and EZZK as `ZakoRecordFirstFlowTests` does): `testE2ERecordIsSignedAndProcessedBeforeTheClientOutput` (both outputs), `testE2ERejectedRecordDeliversNothing`, `testE2EFailedRecordSignatureLeavesNoRowAndKeepsTheNumber`, `testE2EResumeAtWaitAndAtClientSignature`, `testResumeRefusedAfterOrderChange`, `testResumeRefusedAfterTypeChange`, `testE2EMultiFileRecordFirst`, `testE2EUndeterminedQualificationRefusedBeforeNumber`, `testE2EPhoneRefusedInNewOrder`, `testRegimeFlipAtEZZKTimeRechecksForms`, `testE2EClauseFirstRowCarriesRecord10Pack`; record XML in the row validates against `.recordE2E_1_2`.
- [ ] **Step 2: Run** `--filter 'Chevron7AppTests\.(ZakoE2EFlowTests|ZakoE2ERecordFirstTests)'`. Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same, then `--filter 'Chevron7AppTests\.'` (whole App bundle). Expected: pass.
- [ ] **Step 5: Commit** `feat(zako): E→E in the order of 1. 1. 2027`

### Task 6: Documentation, release note and full verification

**Files:**
- Modify: `CLAUDE.md` and `AGENTS.md` (identical): the E→E bullet's "the E→E record-first order of 2027 is refused (`e2eRecordFirstMessage`)" becomes the new behaviour (record E→E 1.2, CL009008, Žiadna/Žiaden, the undetermined-qualification refusal, the shared machinery), citing this spec and plan; the 2027 bullet mentions E→E.
- Create: `docs/releases/changes/feat-zaruka-e2e-2027.md` (repo root; Slovak, for the advocate, per that folder's README, no em dashes).
- [ ] **Step 1:** Write the changes; no U+2014 in changed files; `diff CLAUDE.md AGENTS.md` empty.
- [ ] **Step 2:** Full verification: Swift `--filter 'Chevron7KitTests\.'`, `--filter 'Chevron7AppTests\.'`, `--filter 'Chevron7IntegrationTests\.'`, `--filter 'Chevron7CLITests\.'` (an unfiltered `swift test` prints only one bundle's total), engine `mvnw test`, `Chevron7/scripts/check-rename-boundary.sh --strict`, `scripts/build-engine.sh`, `build_app.sh`. Expected: 0 failures, builds succeed; report each bundle's "Executed N tests" line.
- [ ] **Step 3: Commit** `docs(zako): E→E in the order of 1. 1. 2027`
