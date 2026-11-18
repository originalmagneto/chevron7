# ZaKo E→E Multi-File ASiC-E Originals: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An ASiC-E whose data objects are PDFs (signed or not), PNG or JPEG images is accepted as the original of an E→E guaranteed conversion and becomes one new PDF/A-2b, the files in an order the advocate can change, with the clause and record listing every original and every authorization.

**Architecture:** The engine's EVIDENCE operation lists every data object of a container (kind, SHA-256, covering container signatures, PDF facts, a nested evidence object for a PDF carrying PAdES). `PdfaFromSigned` gets a merge entry point (PDFs flattened as today, images as A4 pages, one outline item per file, `PdfaNormalize` and veraPDF). Swift decodes the data objects, `ElectronicOriginal` turns them into ordered documents and authorizations with exact fingerprints, the forms carry a type per original, and `ZakoE2EFlow` calls the merge where it converts today. Project A's client outputs (ASiC-E and one PDF) are reused unchanged.

**Tech Stack:** Swift 6 / SwiftUI / XCTest; Java 25 / PDFBox 3 / DSS 6.4 (`dss-pdfa` veraPDF, `dss-asic-xades`) / JUnit.

**Spec:** `Chevron7/docs/superpowers/specs/2026-11-18-zako-e2e-multi-file-design.md` (approved by the owner 2026-11-18).

## Global Constraints

- Branch `claude/e2e-multi-file-originals`, stacked on project A (PR #103); never touch P→E behavior.
- Accepted data objects: PDF, PNG, JPEG, recognized by bytes (`%PDF`, `89 50 4E 47 0D 0A 1A 0A`, `FF D8 FF`), never by extension. Everything else is refused with the file's name.
- Every fingerprint is exactly the bytes some signature signed; a PDF whose bytes go beyond its longest signed PAdES revision is two or more documents, `<stem>-1` ... `<stem>-n`, revisions in order, the whole data object last (owner, 2026-11-18).
- Limits from the official clause schema: at most 999 originals, at most 99 authorizations.
- Existing E→E originals keep their exact output: a signed PDF, and an ASiC-E with one unsigned PDF (including `.keep` for an unsigned PDF/A without attachments). The top-level `asicDataObjectCount`, `asicDataObjectName`, `asicDataObjectSigned` stay in the engine output.
- `E2EProductionPolicy.enabled` stays false; E→E stays refused in the 2027 record-first order.
- Slovak user strings, English code and comments, no em dashes anywhere; `CLAUDE.md` and `AGENTS.md` stay identical.
- Tests never touch `~/Library/Application Support/Chevron7`, `~/Library/Caches/Chevron7` or named `UserDefaults` suites (`makeSettingsStore()`, `MemoryUserDefaults()`); fixtures are built in tests, no client documents in the repo.
- Swift tests: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter <Name>` from `Chevron7/`. Engine tests: as in the `engine-maven-tests` memory (Zulu FX 25), `mvn -q test -Dtest=<Class>` from `engine/`.

## Review Focus

1. A container signature covering only some files: an authorization must list only those files' documents, and a file covered by no container signature refuses the conversion (Task 1 and Task 5 tests).
2. Two entries with the same file name in different folders: names must stay unique in the clause, or `AuthorizedDocument` points at the wrong file (Task 5 test `testSameFileNameInTwoFoldersUsesFullPaths`).
3. Reordering after verification: pages, outline titles and the clause's `OriginalDocumentInfo` order must follow the same list (Task 5 `testReorderedMovesDocumentsAndDataObjects`, Task 7 `testDemoMultiFileFollowsChosenOrder`).
4. A PDF data object with embedded files loses them silently (Task 1 lists `embeddedFileNames`, Task 7 shows the note; test `testEmbeddedFilesAreNamedOnTheFile`).
5. A CMYK or 16-bit image breaking PDF/A: veraPDF must accept the merged document or the raster offer must appear, never an unchecked file (Task 3 `cmykJpegBecomesRgbPage`, `sixteenBitPngMerges`).

---

### Task 1: Engine: every data object of a container in the evidence

**Files:**
- Create: `engine/src/test/java/digital/slovensko/autogram/core/ConversionTestContainers.java`
- Modify: `engine/src/main/java/digital/slovensko/autogram/ui/machine/ConversionEvidenceService.java` (`pdfFacts`, new `dataObjects`)
- Modify: `engine/src/main/java/digital/slovensko/autogram/core/PdfConversionFacts.java` (add `pages`, `embeddedFileNames`)
- Test: `engine/src/test/java/digital/slovensko/autogram/ui/machine/ConversionEvidenceServiceTest.java`

**Interfaces:**
- Produces (test helper): `ConversionTestContainers.xadesAsice(List<Entry> entries) -> byte[]` signs every entry with one XAdES signature, using the same generated key as `ConversionTestPdfs.sign`; `ConversionTestContainers.addSignatureCovering(byte[] asice, List<String> names) -> byte[]` signs only the named entries and adds that signature as the next `META-INF/signaturesN.xml`; `record Entry(String name, byte[] bytes)`; `png(int w, int h, boolean sixteenBit)`, `jpeg(int w, int h, boolean cmyk)` image builders.
- Produces (JSON, under `evidence.pdf` for every ZIP source): `dataObjects`: array in zip entry order of `{name, size, sha256Base64, kind: "pdf"|"png"|"jpeg"|"other", coveredBy: [signatureId], problem?}`; for `pdf` also the `PdfConversionFacts.read` keys plus `pages` and `embeddedFileNames`; for images `widthPx`, `heightPx`, optional `dpiX`, `dpiY`.

- [ ] **Step 1: Write the test helper and the failing tests**

`multiFileContainerListsEveryDataObjectInOrder`: entries `zmluva.pdf` (unsigned sample), `priloha.png`, `foto.jpg`; assert 3 `dataObjects`, names in that order, kinds `pdf`, `png`, `jpeg`, each `sha256Base64` equal to the SHA-256 of the entry bytes, each `coveredBy` = the one signature id, `pages` 1 for the PDF, `widthPx`/`heightPx` for the images, top-level `asicDataObjectCount` 3.
`signatureCoveringOneFileIsListedOnlyThere`: container of `a.pdf`, `b.pdf`, then `addSignatureCovering(["b.pdf"])`; assert `a.pdf.coveredBy` has one id, `b.pdf.coveredBy` has two.
`docxEntryIsOther`: `sample_docx_xades.asice` gives one data object of kind `other`.
`kindIsReadFromBytes`: a PNG stored as `obrazok.pdf` has kind `png`.
`embeddedFileNamesAreListed`: a PDF with one embedded file `x.txt` as a data object lists `embeddedFileNames` `["x.txt"]`.
Existing `asicFactsNameTheOnlyPdfDataObject` and `evidenceForXadesContainerHasNoRevision` stay green unchanged.

- [ ] **Step 2: Run the tests and see them fail**

Run: `mvn -q test -Dtest=ConversionEvidenceServiceTest` from `engine/`. Expected: the five new tests fail (no `dataObjects`).

- [ ] **Step 3: Implement**

In `pdfFacts`, collect every non-`META-INF/`, non-`mimetype`, non-directory entry with its bytes, keep the current single-object keys, and add `dataObjects`. `coveredBy` comes from the validator's diagnostic data: for each `SignatureWrapper`, the names in `getSignatureScopes()` (`XmlSignatureScope.getName()`); `pdfFacts` therefore takes the `DiagnosticData` it already receives. An entry over 100 MB, or a PDF PDFBox cannot open, gets `kind` `other` and `problem` (`"TOO_LARGE"`, `"UNREADABLE"`). Image dimensions and resolution through `javax.imageio` metadata.

- [ ] **Step 4: Run the tests and see them pass**

Run the same command. Expected: all `ConversionEvidenceServiceTest` tests pass.

- [ ] **Step 5: Commit** `feat(engine): list every data object of a container in the evidence`

### Task 2: Engine: nested evidence for a signed PDF data object

**Files:**
- Modify: `engine/src/main/java/digital/slovensko/autogram/ui/machine/ConversionEvidenceService.java`
- Test: `engine/src/test/java/digital/slovensko/autogram/ui/machine/ConversionEvidenceServiceTest.java`

**Interfaces:**
- Consumes: Task 1 `dataObjects`, `ConversionTestContainers`.
- Produces (JSON): a `pdf` data object that carries PAdES signatures gets `evidence`: `{validationTime, dssVersion, etsiReportBase64, signatures: [...], pdf: {...PdfConversionFacts, changesAfterLastSignature}}`, the same keys as the top-level `evidence` object (no tree), from one more validation of that data object's bytes; `signatures[*].signedRevisionLength` relative to that data object.

- [ ] **Step 1: Write the failing tests**

`signedPdfDataObjectCarriesNestedEvidence`: entries `zmluva.pdf` = `ConversionTestPdfs.sign(samplePdf, false)` and `b.pdf` unsigned; assert `dataObjects[0].evidence.signatures` has 1 entry with `signatureValueBase64`, `etsiSignatureReportBase64` and `signedRevisionLength` equal to the PDF's length; `dataObjects[1]` has no `evidence`.
`nestedChangesAfterSignatureAreReported`: `zmluva.pdf` = `annotateIncrementally(sign(...))`; assert its nested `pdf.changesAfterLastSignature` contains `ANNOTATION`.
`nestedTrustedListStateUsesTheSameCountries`: with `unavailable` = the signer's country, the nested signature carries `trustedListUnavailable` true (mirror of `trustedListUnavailableOnlyWhenTheAnchorCountryDidNotLoad`).

- [ ] **Step 2: Run them and see them fail**

Run: `mvn -q test -Dtest=ConversionEvidenceServiceTest`. Expected: the three new tests fail.

- [ ] **Step 3: Implement**

Split `evidence(Path)` into a private `evidenceBody(DSSDocument document, byte[] content) -> JsonObject` that validates once and returns the `evidence` object; `evidence(Path)` adds the tree around it as today. A nested call passes an `InMemoryDocument` and runs through the same injected `validation` and `unavailableCountries`. Nested evidence is built only for kind `pdf` with at least one signature and never recurses further.

- [ ] **Step 4: Run them and see them pass**

Expected: all `ConversionEvidenceServiceTest` tests pass.

- [ ] **Step 5: Commit** `feat(engine): nested evidence for signed PDF data objects`

### Task 3: Engine: merge files into one PDF/A

**Files:**
- Modify: `engine/src/main/java/digital/slovensko/autogram/core/PdfaFromSigned.java`
- Test: `engine/src/test/java/digital/slovensko/autogram/core/PdfaFromSignedTest.java`

**Interfaces:**
- Consumes: `ConversionTestContainers.png/jpeg` (Task 1), `ConversionTestPdfs`.
- Produces: `PdfaFromSigned.merge(List<Input> inputs, File output, File iccProfile, String title, boolean raster) -> Result` with `record Input(File file, String name)`; CLI `PdfaFromSigned --merge <out.pdf> <iccProfile> <title> [--raster] <in> <name> [<in> <name>]...`, exit codes as the single-file form (0 compliant, 3 not compliant with rule lines on stderr, 2 unreadable input, 1 other).

- [ ] **Step 1: Write the failing tests**

`mergeKeepsOrderAndOutline`: inputs signed 1-page PDF `zmluva.pdf`, a 2-page unsigned PDF `priloha.pdf`, a PNG `foto.png`; assert 4 pages, outline titles `["zmluva.pdf", "priloha.pdf", "foto.png"]` pointing at pages 1, 2, 4, no signature fields, `compliant` true.
`imagePageIsA4InTheImageOrientation`: a 3000x2000 PNG gives one landscape A4 page (842 x 595 pt), the image inside 10 mm (28.35 pt) margins.
`smallImageIsNotEnlarged`: a 300x300 PNG with 300 dpi is drawn 72 x 72 pt.
`cmykJpegBecomesRgbPage`: CMYK JPEG merges and veraPDF reports compliant.
`sixteenBitPngMerges`: 16-bit PNG merges and is compliant.
`unreadableInputExitsTwo`: CLI `--merge` with a truncated PDF exits 2.
`rasterMergeHasNoText`: `raster` true gives pages without text, compliant.

- [ ] **Step 2: Run them and see them fail**

Run: `mvn -q test -Dtest=PdfaFromSignedTest`. Expected: new tests fail to compile or fail.

- [ ] **Step 3: Implement**

Each PDF input: load, `stripAndFlatten` (or `rasterized`), import pages with `PDFMergerUtility`-free page import (`PDDocument.importPage` and keep resources) into one target document. Each image: one A4 page oriented by aspect ratio, image scaled to fit inside 10 mm margins and never larger than its stated resolution (150 dpi when none), centered; CMYK or 16-bit images are redrawn into an 8-bit sRGB `BufferedImage` before `LosslessFactory`/`JPEGFactory`. One `PDOutlineItem` per input at its first page. Then save to a temporary file and run `PdfaNormalize.normalize` and `PDFAStructureValidator` exactly as `convert` does. Check `PdfaNormalize` keeps the outline; if it drops it, re-add the outline after normalizing and before the veraPDF check.

- [ ] **Step 4: Run them and see them pass**

Expected: all `PdfaFromSignedTest` tests pass.

- [ ] **Step 5: Commit** `feat(engine): merge PDFs and images into one PDF/A`

### Task 4: Swift: decode data objects and nested evidence

**Files:**
- Modify: `Chevron7/Sources/Chevron7Kit/Conversion/ConversionEvidence.swift`
- Modify: `Chevron7/Tests/Chevron7TestSupport/E2EEvidenceFixtures.swift`
- Test: `Chevron7/Tests/Chevron7KitTests/ConversionEvidenceTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct DataObject: Sendable, Equatable {
      public enum Kind: String, Sendable { case pdf, png, jpeg, other }
      public var name: String
      public var size: Int
      public var sha256: Data
      public var kind: Kind
      public var coveredBy: [String]
      public var problem: String?
      public var pdf: PDFFacts?          // kind == .pdf
      public var pages: Int?
      public var embeddedFileNames: [String]
      public var widthPx: Int?
      public var heightPx: Int?
      public var nested: NestedEvidence?
  }
  public struct NestedEvidence: Sendable, Equatable {
      public var validationTime: Date
      public var etsiReport: Data
      public var signatures: [Signature]
      public var pdf: PDFFacts
  }
  ```
  `ConversionEvidence.PDFFacts.dataObjects: [DataObject]` (empty for a PDF source or an old payload).
- Fixtures: `E2EEvidenceFixtures.DataObject` (name, bytes, kind, coveredBy, pages, embeddedFileNames, nestedSignatures: `[Signature]`, nestedPDF: `PDF?`) and `payload(signatures:pdf:dataObjects:)` that computes `sha256Base64` and `size` from the bytes.

- [ ] **Step 1: Write the failing tests**

`testDecodesDataObjectsInOrder`, `testDecodesNestedEvidenceSignatures` (nested signature value, slim report, `signedRevisionLength`), `testOldPayloadHasNoDataObjects` (a payload without the key decodes with `[]`).

- [ ] **Step 2: Run** `swift test --filter ConversionEvidenceTests`. Expected: fail.
- [ ] **Step 3: Implement** the decoding, reusing the existing `RawSignature` mapping for nested signatures (extract it into a function both use).
- [ ] **Step 4: Run** the same filter. Expected: pass.
- [ ] **Step 5: Commit** `feat(zako): decode container data objects in E→E evidence`

### Task 5: Swift: the multi-file original

**Files:**
- Modify: `Chevron7/Sources/Chevron7Kit/Conversion/ElectronicOriginal.swift`
- Modify: `Chevron7/Sources/Chevron7Kit/Conversion/E2ECodelists.swift`
- Modify: `Chevron7/Sources/Chevron7Kit/Conversion/QualifiedValidationReport.swift` (`names`)
- Test: `Chevron7/Tests/Chevron7KitTests/ElectronicOriginalTests.swift`, `Chevron7/Tests/Chevron7KitTests/QualifiedValidationReportTests.swift`

**Interfaces:**
- Consumes: Task 4 `DataObject`, `NestedEvidence`.
- Produces:
  - `ElectronicOriginal.Kind.asicEMultiple` (no payload); `.asicE(entryName:)` stays for the one-unsigned-PDF case so its output is unchanged.
  - `ElectronicOriginal.File: Sendable, Equatable { entryName: String; displayName: String; kind: DataObject.Kind; data: Data; documentNames: [String]; embeddedFileNames: [String]; changedAfterSignature: [String] }` and `public var files: [File]` (empty for `.pdf` and `.asicE`).
  - `Document` gains `fileEntryName: String?`.
  - `Authorization` gains `fileEntryName: String?` (set for a nested PAdES signature, nil for a container signature).
  - `public func reordered(entryNames: [String]) -> ElectronicOriginal` (files, and documents grouped by file, in that order; authorizations unchanged; precondition: same set of names).
  - New `ElectronicOriginalError` cases with Slovak `errorDescription`:
    - `.unsupportedDataObject(name:)` "Súbor \(name) nie je PDF ani obrázok PNG alebo JPEG. Chevron7 ho do nového dokumentu nevie zahrnúť."
    - `.unreadableDataObject(name:)` "Súbor \(name) sa nepodarilo prečítať."
    - `.uncoveredDataObject(name:)` "Súbor \(name) nepokrýva žiadny podpis kontajnera. Neautorizovaný súbor nemožno zaručene konvertovať."
    - `.tooManyDocuments(Int)` "Kontajner obsahuje \(n) dokumentov. Formulár doložky ich pripúšťa najviac 999."
    - `.tooManyAuthorizations(Int)` "Dokument má \(n) autorizácií. Formulár doložky ich pripúšťa najviac 99."
  - `.unsupportedContainer` and `.signedPDFInsideContainer` are no longer thrown; delete them if nothing else uses them.
  - `E2ECodelists.pngFormat` and `jpegFormat` (or `Iny` with other text `JPEG` when codelist 53 has no JPEG item), with a comment naming where the items were read (the official filler `Content/form.19.html` of the clause form, via the `form.19.html2.xslt` lists or slovensko.sk's form page).

- [ ] **Step 1: Write the failing tests** (fixtures from Task 4)

- `testTwoPdfsAndImagesBecomeDocumentsInContainerOrder`: `a.pdf`, `b.png`, `c.jpg`, one container signature; documents `a.pdf`, `b.png`, `c.jpg`, SHA-256 from the bytes, formats PDF, PNG, JPEG item; one authorization listing all three; `plan` is `.convert`; `kind` `.asicEMultiple`.
- `testSignatureCoveringOneFileListsOnlyIt`: signature S-2 covers only `b.png`; its `documentNames` == `["b.png"]`.
- `testUncoveredFileIsRefused`, `testDocxIsRefusedByName`, `testUnreadableIsRefusedByName`.
- `testSignedPdfWholeFileIsItsOwnDocumentWhenBytesDiffer`: `zmluva.pdf` of 1000 bytes with one PAdES whose `signedRevisionLength` is 900; documents `zmluva-1` (SHA of first 900 bytes) and `zmluva-2` (SHA of all 1000); the PAdES authorization lists `zmluva-1` with `fileEntryName` `zmluva.pdf`; the container signature lists `zmluva-2`.
- `testSignedPdfCoveringWholeFileSharesOneDocument`: `signedRevisionLength` == size; one document `zmluva.pdf`, both authorizations list it.
- `testTwoRevisionsPlusTailGiveThreeDocuments`: lengths 500 and 800 of 1000: `zmluva-1`, `zmluva-2`, `zmluva-3`.
- `testSameFileNameInTwoFoldersUsesFullPaths`: `a/zmluva.pdf`, `b/zmluva.pdf`, `priloha.pdf`; names `a/zmluva.pdf`, `b/zmluva.pdf`, `priloha.pdf`.
- `testReorderedMovesDocumentsAndDataObjects`.
- `testEmbeddedFilesAreNamedOnTheFile`, and a nested `changesAfterLastSignature` reaching `File.changedAfterSignature`.
- `testSingleUnsignedPdfContainerIsUnchanged`: the existing `testAsicUsesEntryNameAndItsBytes` expectations (kind `.asicE`, `.keep` rule) still hold.
- `testSingleSignedPdfContainerIsNowAccepted`: one PDF data object with PAdES: kind `.asicEMultiple`, revision documents as above, `.convert`.
- `testTooManyAuthorizationsIsRefused` (100 signatures).
- `QualifiedValidationReportTests.testMultiFileReportMustNameEveryDocumentOrEverySignature`: for `.asicEMultiple`, a report carrying only one of three document hashes does not name the original; all three hashes, or every signature value (nested included), does. Single-file originals keep today's any-one-hash rule.

- [ ] **Step 2: Run** `swift test --filter ElectronicOriginalTests`. Expected: new tests fail.
- [ ] **Step 3: Implement** in `make`: an ASiC-E with exactly one data object that is an unsigned PDF keeps today's path; any other ASiC-E with `dataObjects` takes the new path; refusals checked before documents are built. Nested signatures map to `Authorization` with the nested evidence's validation time and facts; the gate (`E2EVerificationGate`) needs no change because nested authorizations sit in the same array. `pdfData` stays the first PDF's bytes for callers that read it, but `ZakoE2EFlow` uses `files` for `.asicEMultiple` (Task 7).
- [ ] **Step 4: Run** the same filter. Expected: pass, including the unchanged existing tests.
- [ ] **Step 5: Commit** `feat(zako): ASiC-E with several PDFs and images as an E→E original`

### Task 6: Swift: forms with several originals and the merge runner

**Files:**
- Modify: `Chevron7/Sources/Chevron7Kit/Models/AttestationData.swift` (`originalDocumentTypeLabels: [String: String]`, decoded with `decodeIfPresent ?? [:]`)
- Modify: `Chevron7/Sources/Chevron7Kit/Attestation/Forms/E2EFormModel.swift`
- Modify: `Chevron7/Sources/Chevron7Kit/Conversion/PdfaFromSignedRunner.swift`
- Test: `Chevron7/Tests/Chevron7KitTests/E2EFormRendererTests.swift`, a new `PdfaFromSignedRunnerMergeTests` in `Chevron7/Tests/Chevron7KitTests/`

**Interfaces:**
- Consumes: Task 5 `ElectronicOriginal.files`, `Document.fileEntryName`.
- Produces:
  - `E2EFormModel.originalDocumentTypes: [String]`, one per `original.documents` element in order (a revision document takes its file's type), filled from `originalDocumentTypeLabels[fileEntryName]`, else the common `originalDocumentTypeLabel`, else the document name; `originalDocumentType` (single) remains as the common value for single-file originals.
  - `ConversionRecordE2ERenderer` writes `originalDocumentTypes[i]` per `OriginalDocumentInfo`.
  - `PdfaFromSignedRunner.merge(_ inputs: [(data: Data, name: String)], title: String, raster: Bool) throws -> Data`, same `Failure` mapping as `convert`.

- [ ] **Step 1: Write the failing tests**

`testThreeOriginalsWithNestedSignatureValidateAgainstBothSchemas`: clause against the official clause E→E 1.3 schema and record against `record-e2e-1.0/schema.validation.xsd` (as the existing renderer tests do), three `OriginalDocumentInfo` in order, the nested authorization's `AuthorizedDocument` names only its revision document.
`testRecordCarriesTypePerFile`: types `Zmluva` for `a.pdf`, `Iný dokument` for `b.png` appear in that order.
`testMergeArgumentsAndOrder` (runner with an injected `launch`): arguments are `PdfaFromSigned --merge <out> <icc> <title>` then `<file> <name>` pairs in input order, `--raster` after the title when asked; exit 3 maps to `.notCompliant`.

- [ ] **Step 2: Run** `swift test --filter E2EFormRendererTests` and `--filter PdfaFromSignedRunnerMergeTests`. Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both filters. Expected: pass.
- [ ] **Step 5: Commit** `feat(zako): E→E forms with several originals and a merge runner`

### Task 7: App: verification list, order, conversion

**Files:**
- Modify: `Chevron7/Sources/Chevron7App/ZakoE2EFlow.swift` (conversion branch and default new document name)
- Modify: `Chevron7/Sources/Chevron7App/ZakoSessionStore.swift` (`moveE2EFile(from:to:)`)
- Modify: `Chevron7/Sources/Chevron7App/Views/ZakoVerificationView.swift`
- Test: `Chevron7/Tests/Chevron7AppTests/ZakoE2EFlowTests.swift`, `Chevron7/Tests/Chevron7AppTests/E2EScreenSnapshotTests.swift`

**Interfaces:**
- Consumes: Tasks 5 and 6.
- Produces: `ZakoSessionStore.moveE2EFile(from: IndexSet, to: Int)` replaces `electronicOriginal` with `reordered(entryNames:)` and is refused (no change) while authorizing; `ZakoE2EFlow` for `.asicEMultiple` calls `pdfaFromSignedRunner.merge(files.map { ($0.data, $0.displayName) }, title:, raster:)` where `convert` runs today, with the same raster offer; `attestation.newDocumentName` defaults to the container's stem plus `.pdf` for `.asicEMultiple`.

- [ ] **Step 1: Write the failing tests**

`testDemoMultiFileDeliversContainerWithMergedPdf` (ASiC-E output) and `testDemoMultiFileDeliversOnePdf` (`.singlePDF`): fake merge runner returns a fixed PDF/A; the clause in the delivered output lists the three originals; the register row exists.
`testDemoMultiFileFollowsChosenOrder`: after `moveE2EFile` the merge inputs and the clause's document order follow the new order.
`testMultiFileNotCompliantOffersRaster`: merge throws `.notCompliant`; `rasterConversionOffered` true and no evidence number allocated.
`testReorderIsRefusedWhileAuthorizing`.
Snapshot: the verification screen with a three-file container (names, formats, page counts, signers per file, the embedded-files note, a nested signature under its file).

- [ ] **Step 2: Run** `swift test --filter ZakoE2EFlowTests` and `--filter E2EScreenSnapshotTests`. Expected: fail.
- [ ] **Step 3: Implement**

`ZakoVerificationView`: a "Súbory v kontajneri" section (only for `.asicEMultiple`) in a `List` with `.onMove` plus "Posunúť vyššie" / "Posunúť nižšie" buttons for keyboard and VoiceOver users; each row: name, format, "N strán" or "Obrázok", covering signers, nested signatures indented under it, the note "Prílohy v PDF sa do nového dokumentu neprenesú: \(names)." and "Po podpise PAdES boli v súbore zmeny (\(kinds)); celý súbor pokrýva podpis kontajnera." when they apply, and a "Druh dokumentu" picker per file (the existing `documentKinds` plus free text, writing `originalDocumentTypeLabels[entryName]`). The single-file layout stays as is.

- [ ] **Step 4: Run** both filters, then the whole App suite `swift test --filter Chevron7AppTests`. Expected: pass.
- [ ] **Step 5: Commit** `feat(zako): convert an ASiC-E with several files in E→E`

### Task 8: Documentation and release note

**Files:**
- Modify: `CLAUDE.md` and `AGENTS.md` (repo root, identical): in the E→E bullet, replace "v1 refuses ... an ASiC-E with several data objects or a signed PDF inside" with the accepted kinds, the exact-fingerprint rule, the merge, the per-file type and the order, citing this spec and plan.
- Modify: `Chevron7/docs/superpowers/specs/2026-10-16-zako-e2e-design.md` non-goals: point to the 2026-11-18 spec for multi-file containers.
- Create: `Chevron7/docs/releases/changes/feat-zaruka-viac-suborov.md` (one Slovak paragraph for the advocate, per that folder's README, no mention of signing internals).

- [ ] **Step 1:** Write the three changes; a search for the em dash character (U+2014) in each changed file finds none; `diff CLAUDE.md AGENTS.md` prints nothing.
- [ ] **Step 2:** Run the full verification: Swift `swift test` (all targets), engine `mvn -q test`, `Chevron7/scripts/check-rename-boundary.sh --strict`, `scripts/build-engine.sh`, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build_app.sh`. Expected: 0 failures, both builds succeed.
- [ ] **Step 3: Commit** `docs(zako): multi-file ASiC-E originals for E→E`
