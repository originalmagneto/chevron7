# ZaKo One PDF with the Clause Inside: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In ZaKo (P→E and E→E), the advocate can deliver one PDF/A-3b instead of the ASiC-E: content as revision 1, the clause XDC as an EmbeddedFile plus readable clause pages rendered from the official XSLT as revision 2, and the mandate certificate's PAdES Baseline T signature as revision 3.

**Architecture:** The app renders the clause pages (xsltproc + WebKit) from the clause XML it already builds. The engine gets `PdfClauseAppender` (PDFBox incremental update plus veraPDF PDF/A-3b), reachable as a v1 `appendClause` field on a PAdES sign request and as a check-only CLI class. ZaKo's three signing sites (P→E now, P→E 2027 record-first, E→E) branch on a remembered output choice; register, forms and UI follow. The spec's check-only `PDFA_CHECK` operation (5.5) is built as a command-line class run like `PdfaFromSigned` (`PdfClauseCheckRunner`), which needs no protocol change.

**Tech Stack:** Swift 6 / SwiftUI / WebKit / XCTest; Java 25 / PDFBox 3 / DSS 6.4 (`dss-pdfa` veraPDF) / JUnit; `/usr/bin/xsltproc`.

**Spec:** `Chevron7/docs/superpowers/specs/2026-11-17-zako-single-pdf-design.md` (approved by the owner 2026-11-17).

## Global Constraints

- Slovak for user-facing strings, English for code, comments and docs; never an em dash anywhere.
- CLAUDE.md and AGENTS.md at the repository root stay identical.
- Tests never touch `~/Library/Application Support/Chevron7`, `~/Library/Caches/Chevron7`, a named `UserDefaults` suite or `UserDefaults.standard` (`makeSettingsStore()`, `MemoryUserDefaults()`, `directory:` parameters).
- No network during clause rendering; no new third-party dependency in app or engine.
- The ASiC-E output stays the default (`.asicContainer`) and its behaviour, bytes and tests do not change.
- Fingerprint in clause and record = SHA-256 of revision 1, the exact bytes hashed today (`finalPDF` in P→E, `newDocument` in E→E).
- Attached clause: the same XDC bytes and name as today's container entry (`ConversionOutputNaming.containerClauseName`), MIME `application/vnd.gov.sk.xmldatacontainer+xml`, `/AFRelationship /Supplement`, listed in `/Names /EmbeddedFiles` and the catalog `/AF`.
- Clause pages A4 portrait, after all content pages; outline entry title exactly `Osvedčovacia doložka`.
- Delivered file: XMP `pdfaid:part` 3, conformance `B`; veraPDF PDF/A-3b passes before and after the signature.
- PAdES timestamp servers for this output, outside Demo: BOSA (`TimestampAuthority.bosaURL`) first, then Sectigo Qualified, then any other qualified built-in.
- `NewDocumentFormat` for this output: clause `Iny` + `NewDocumentFormatOther` "PDF/A-3"; record 1.0 and record E→E 1.0 the string "PDF/A-3"; record 1.2 CL009009 item 3.
- Production: `SinglePDFProductionPolicy.enabled = false` refuses `.singlePDF` in Ostrá evidencia; E→E also stays behind `E2EProductionPolicy`.
- Phone ("Použiť mobil") refused for `.singlePDF`.
- Engine tests: `cd engine && J=~/Library/Java/zulu25.36.205-ca-fx-jdk25.0.4.1-macosx_aarch64/Contents/Home && JAVA_HOME=$J ./mvnw -q -Djlink.jdk.path=$J test -Dtest=<Class> -Dsurefire.failIfNoSpecifiedTests=false` (reports in `target/surefire-reports/*.txt`). Swift: from `Chevron7/`, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Name>`. Engine build for the app: `Chevron7/scripts/build-engine.sh`.

## Review Focus

- A clause long enough to span several pages (E→E with several signatures and timestamps, Slovak diacritics everywhere): every page A4, nothing clipped, diacritics extractable as text (Task 1 test `longClauseIsPaginatedWithDiacritics`).
- A content PDF/A whose revision 1 ends in a cross-reference stream, or a raster (image only) PDF/A from E→E: append keeps the prefix byte-exact and still passes veraPDF (Task 2 tests `xrefStreamSourceKeepsPrefix`, `rasterSourcePassesPdfa3b`).
- A signature that fails after the pages were rendered (wrong PIN, card removed, `PDFA_INVALID`, timestamp refused): nothing is written next to the source, no register row in the current order, the evidence number stays in the pool (Task 7 test `failedSignatureLeavesNumberAndNoOutput`).
- The 2027 resume after a restart of the wait: the PDF is signed with the stored pages and attachment and lands under the name fixed before the record, also when another file took that name meanwhile (Task 8 test `resumeSignsStoredClauseAndKeepsRecordedName`).
- An E→E original that would be kept byte for byte (`.keep`) under `.singlePDF`: converted, never appended after the client's signatures (Task 9 test `keepPlanIsConvertedForSinglePDF`).

---

Execution order: 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11. Task 1's fixtures feed Task 2; if Task 2's veraPDF test fails on Task 1's pages, fix the print CSS in Task 1 before going on, and stop for the owner if small CSS cannot fix it (spec 5.3).

### Task 1: Clause pages from the official XSLT

**Files:**
- Create: `Chevron7/Sources/Chevron7Kit/Attestation/Forms/ClausePresentationRenderer.swift`
- Create: `Chevron7/Tests/Chevron7KitTests/ClausePresentationRendererTests.swift`
- Create (generated by a test helper, committed): `engine/src/test/resources/digital/slovensko/autogram/core/clause-pages-p2e.pdf`, `clause-pages-e2e.pdf`, `clause-p2e.xdcf`, `zako-p2e-final.pdf` (a real P→E `finalPDF` from `PDFAConverter.convert` + `normalizeForDelivery` of a one-page test image)
- Create: `Chevron7/docs/ZAKO-SINGLE-PDF-FINDINGS-2026-11-17.md` (print CSS used, page counts, veraPDF result of `zako-p2e-final.pdf` from Task 2)

**Interfaces:**
- Produces: `public struct ClausePresentationRenderer: Sendable { public init(xsltproc: URL = URL(fileURLWithPath: "/usr/bin/xsltproc")); @MainActor public func render(clauseXML: Data, form: OfficialForm) async throws -> Data }` returning a PDF; `public enum ClausePresentationError: LocalizedError { case transformFailed(String), printFailed }` with Slovak `errorDescription` ("Osvedčovaciu doložku sa nepodarilo vykresliť: …").
- Consumes: `OfficialForm.clause_1_3` / `.clauseE2E_1_3` `.presentation` bytes (already embedded); clause XML as built by `ConversionCertificateRenderer` / `E2EDeliveryBuilder` (the XML inside the XDC, not the XDC).

- [ ] **Step 1: Write failing tests**: `rendersP2EClauseOnA4` (fixture model from `ZakoClauseDeliveryBuilderTests`' helpers: PDF with ≥1 page, every page mediabox 595×842 ±1, page text contains "Osvedčovacia doložka" and the evidence number), `rendersE2EClauseOnA4` (same with an `E2EFormModel` fixture from `E2EFormRendererTests`), `longClauseIsPaginatedWithDiacritics` (E→E model with 6 signatures and 4 timestamps, office "Advokátska kancelária Čuprík, s. r. o.": pageCount ≥ 2, extracted text contains "Čuprík" and "kancelária", no page's text ends mid-row clipped: last line of each page fully inside the mediabox via `PDFPage.characterBounds`), `rendersWithoutNetwork` (renderer's web view uses a `WKContentRuleList` blocking `.*`; a clause XML is rendered with networking sandboxed: assert completion and no `WKNavigationDelegate` resource request other than `about:blank`).
- [ ] **Step 2: Run** `swift test --filter ClausePresentationRendererTests`; expected FAIL (type missing).
- [ ] **Step 3: Implement.** XSLT: write XML and stylesheet to a temp dir, run `xsltproc --nonet <xslt> <xml>`; non-zero exit → `.transformFailed(stderr)`. Print: offscreen `NSWindow` hosting a `WKWebView` (A4 content size), `loadHTMLString(html, baseURL: nil)` after installing the rule list, then `printOperation(with:)` with `NSPrintInfo` paper A4, `.jobDisposition = .save`, `jobSavingURL` in the temp dir, `horizontalPagination = .fit`, margins 36 pt, `showsPrintPanel = false`, `showsProgressPanel = false`; `runModal(for:)` on the offscreen window or `run()` (whichever completes headless in XCTest; record which in the findings). Inject a `<style>@page{size:A4;margin:0} body{-webkit-print-color-adjust:exact}</style>` before `</head>`; add only what veraPDF in Task 2 needs.
- [ ] **Step 4: Run** the tests; expected PASS. Add a test helper `writeEngineFixtures()` (skipped unless `CHEVRON7_WRITE_FIXTURES=1`) that writes the four engine fixtures; run it once and commit its output.
- [ ] **Step 5: Commit** `feat(zako): render the clause from the official form presentation`.

### Task 2: Engine `PdfClauseAppender`

**Files:**
- Create: `engine/src/main/java/digital/slovensko/autogram/core/PdfClauseAppender.java`
- Test: `engine/src/test/java/digital/slovensko/autogram/core/PdfClauseAppenderTest.java`

**Interfaces:**
- Produces:
  ```java
  public final class PdfClauseAppender {
      public static final String OUTLINE_TITLE = "Osvedčovacia doložka";
      public record Attachment(String name, String mimeType, byte[] content) {}
      public record Result(byte[] pdf, int addedPages, boolean pdfaCompliant, List<String> pdfaErrors) {}
      public static Result append(byte[] source, byte[] clausePages, Attachment attachment) throws IOException;
      public static void main(String[] args); // check-only CLI, see Task 3
  }
  ```

- [ ] **Step 1: Write failing tests** with Task 1's fixtures: `appendKeepsSourceAsBytePrefix` (`Arrays.equals(result.pdf(), 0, source.length, source, 0, source.length)`), `appendAddsClausePagesAtTheEnd` (page count = source + clause pages; last page's text contains "Osvedčovacia doložka"), `appendEmbedsClauseAsAssociatedFile` (`/Names/EmbeddedFiles` has one entry named `clause-p2e.xdcf`'s name with `/Subtype` `application/vnd.gov.sk.xmldatacontainer+xml`, `/AFRelationship /Supplement`, catalog `/AF` contains it, embedded bytes equal the attachment), `appendAddsOutlineEntry` (outline item titled `OUTLINE_TITLE` pointing at the first clause page), `appendDeclaresPdfa3b` (XMP `pdfaid:part` = 3, `conformance` = B; OutputIntents unchanged), `realP2EFinalPassesPdfa3b` (`zako-p2e-final.pdf` + `clause-pages-p2e.pdf`: `pdfaCompliant` true; also record in the findings whether `zako-p2e-final.pdf` alone passes PDF/A-2b with `PDFAStructureValidator`), `e2eClausePassesPdfa3b`, `xrefStreamSourceKeepsPrefix` (source re-saved by PDFBox with `CompressParameters.DEFAULT_COMPRESSION` so it ends in an xref stream: prefix kept, compliant), `rasterSourcePassesPdfa3b` (`PdfaFromSigned.convert(..., raster=true)` output as source), `unembeddedFontPagesAreNotCompliant` (clause pages built with PDFBox `Standard14Fonts` Helvetica: `pdfaCompliant` false, errors non-empty), `appendRefusesSignedOrEncryptedSource` (a source with `/ByteRange` or encryption: `IOException`).
- [ ] **Step 2: Run** `-Dtest=PdfClauseAppenderTest`; expected FAIL.
- [ ] **Step 3: Implement `append`.** Load source with `Loader.loadPDF`; refuse signature dictionaries or encryption; import each clause page with `PDDocument.importPage`; add `PDComplexFileSpecification` with `PDEmbeddedFile` (subtype, size, creation/mod date), `AFRelationship` name, add to the names tree and to a catalog `/AF` array; add an outline item; rewrite the XMP metadata stream with `pdfaid:part=3`, `conformance=B` (keep every other XMP property); mark every changed dictionary with `setNeedToBeUpdated(true)` and write with `saveIncremental(output, Set.of(...))` so the prefix is untouched; then `new PDFAStructureValidator().validate(new InMemoryDocument(bytes))` for the result.
- [ ] **Step 4: Run** the test class; expected PASS. Write the veraPDF facts into the findings note.
- [ ] **Step 5: Commit** `feat(engine): append the clause to a PDF/A as PDF/A-3b`.

### Task 3: Engine protocol: `appendClause` on a PAdES sign, check-only CLI

**Files:**
- Modify: `engine/src/main/java/digital/slovensko/autogram/ui/machine/MachineFile.java` (component `ClauseAppend appendClause`, nullable; existing constructors pass null)
- Create: `engine/src/main/java/digital/slovensko/autogram/ui/machine/ClauseAppend.java` (`record ClauseAppend(String pages, String attachment, String attachmentName, String attachmentMimeType)`)
- Modify: `MachineCliApp.java:220-259` (parse optional `appendClause` object: exactly keys `pages`, `attachment` (`{source, name, mimeType}`); file object size 4 when present; never together with `attachments`)
- Modify: `MachineRequestValidator.java:67-70` (`appendClause` requires a `PAdES_BASELINE_*` level, no eForm, no attachments, no visible appearance; else `PROTOCOL_INVALID_REQUEST`)
- Modify: `MachineSigningService.java` (`PreparedFile` reads pages and attachment through `fileSystem.openSource`; `signingJob(...)` applies `PdfClauseAppender.append` before `SigningJob.buildFromRequest`, throwing `MachineProtocolException("PDFA_INVALID")` when not compliant; `signFile` validates with the new `appendedClauseFailure`; `failureCode` passes `PDFA_INVALID` through)
- Modify: `SigningJob.java:228-229` (skip `PdfFormAppearances` when the parameters carry `appendsClause`, a new boolean on `SigningParameters`)
- Modify: `MachineErrorMapper.java` (`PDFA_INVALID` in `INTERNAL_CODES`)
- Modify: `engine/protocol/v1/schema/request.schema.json` (document `attachments` and `appendClause`)
- Modify: `PdfClauseAppender.main` (usage `PdfClauseAppender <source.pdf> <pages.pdf> <attachment> <name> <mimeType>`; exit 0 compliant, 3 not compliant with up to 5 veraPDF messages on stderr, 2 unreadable, 1 otherwise; writes nothing)
- Test: `MachineRequestValidatorTest.java`, `MachineCliAppTest.java`, `MachineSigningServiceTest.java`, `PdfClauseAppenderTest.java`

**Interfaces:**
- Produces v1 file JSON: `{"id", "source", "target", "appendClause": {"pages": "<abs path>", "attachment": {"source": "<abs path>", "name": "<entry name>", "mimeType": "<mime>"}}}`.
- Produces error code `PDFA_INVALID` (event `file.failed`), message carries up to 5 veraPDF rule lines.
- Produces `PdfOutputValidator.appendedClauseFailure(byte[] content, byte[] source, byte[] attachment, int clausePages, String requestedLevel)`: null when the source is a byte prefix, exactly two revisions follow (`%%EOF` count after the source), page count = source pages + `clausePages`, the EmbeddedFile equals `attachment`, exactly one new signature at `requestedLevel` with cryptographic integrity (and the Baseline T checks for `_T`), and veraPDF passes; else `OUTPUT_VALIDATION_FAILED`.

- [ ] **Step 1: Write failing tests**: validator `appendClauseNeedsPades`, `appendClauseRefusesAttachmentsEformOrAppearance`; CLI parse `parsesAppendClause`, `refusesAppendClauseWithAttachments`, `refusesUnknownAppendClauseKeys`; signing service (DSS test token, mock TSP, as `ContentTimestampTest` does) `signsAppendedClauseAsPadesT` (output passes `appendedClauseFailure`, the signature covers the whole file), `pdfaInvalidStopsBeforeSigning` (Helvetica pages from Task 2: `file.failed` with `PDFA_INVALID`, no target written, key never asked to sign), `appendedClauseFailureRefusesChangedPrefixOrAttachment`; CLI `checkOnlyExitCodes` (0 and 3 on Task 2 fixtures, no output file created).
- [ ] **Step 2: Run** those classes; expected FAIL.
- [ ] **Step 3: Implement** per the Files list.
- [ ] **Step 4: Run** `-Dtest='Machine*Test,PdfClauseAppenderTest,ContentTimestampTest'`; expected PASS. Then `Chevron7/scripts/build-engine.sh`.
- [ ] **Step 5: Commit** `feat(engine): sign a PDF with its appended clause in one request`.

### Task 4: Swift engine bridge and check runner

**Files:**
- Modify: `Chevron7/Sources/Chevron7Kit/Signing/SigningProvider.swift` (`SigningRequest.appendedClause: AppendedClause?`, init param defaulting to nil; `QualifiedSigningProviding.supportsAppendedClause` with default `false` in the protocol extension)
- Create: `Chevron7/Sources/Chevron7Kit/Signing/AppendedClause.swift`
- Modify: `Chevron7/Sources/Chevron7Kit/EngineBridge/Models/SigningModels.swift` (`SigningFile.appendClause: SigningFile.ClauseAppendFiles?`)
- Modify: `Chevron7/Sources/Chevron7Kit/EngineBridge/CLI/AutogramCLIEngine.swift` (`machineFile` encodes `appendClause`; v1 only; error text for `PDFA_INVALID`)
- Modify: `Chevron7/Sources/Chevron7Kit/Signing/JavaEngine/EngineBridgeSigningProvider.swift` (new branch before the `wantsPAdES` fallthrough: requires `.embeddedPAdES`, no `extraFiles`, no `eform`, no `visualStamp`; writes pages and attachment into the workspace; returns `pdfData` with `asicData == nil`; `supportsAppendedClause = true`; message for `PDFA_INVALID`: "Výsledný PDF nespĺňa PDF/A-3b, preto nebol podpísaný. Konverzia sa nevykonala a evidenčné číslo zostáva nepoužité.")
- Create: `Chevron7/Sources/Chevron7Kit/Conversion/PdfClauseCheckRunner.swift` (mirrors `PdfaFromSignedRunner`: `Launch` injection, classpath from the bundled engine)
- Modify: `TimestampAuthority.swift` (`public static var zakoPAdESQualifiedURLs: [URL]`: BOSA, then Sectigo Qualified, then other qualified built-ins)
- Test: `Chevron7/Tests/Chevron7KitTests/EngineBridgeTests.swift`, `TimestampOptionalTests.swift`, new `PdfClauseCheckRunnerTests.swift`

**Interfaces:**
- Produces: `public struct AppendedClause: Sendable, Equatable { public var pages: Data; public var attachment: Data; public var attachmentName: String; public var attachmentMimeType: String; public static let xdcMimeType = "application/vnd.gov.sk.xmldatacontainer+xml" }`.
- Produces: `public struct PdfClauseCheckRunner: Sendable { public enum Failure: LocalizedError, Equatable { case notCompliant([String]), unreadable, engineUnavailable, failed }; public init(launch: Launch? = nil); public func check(source: Data, clause: AppendedClause) throws }`.
- Produces: `TimestampAuthority.zakoPAdESQualifiedURLs`.

- [ ] **Step 1: Write failing tests**: `machineRequestCarriesAppendClause` (captured JSON has `appendClause.pages`, `.attachment.source/name/mimeType`, no `attachments`, level `PAdES_BASELINE_T`), `appendedClauseRefusesASiCOutputOrExtras` (`.attachedASIC`, `extraFiles`, `eform` or `visualStamp` → `SigningError.signingFailed`), `appendedClauseReturnsPdfWithoutAsic` (fake engine), `pdfaInvalidHasSlovakMessage`, `padesZakoAuthoritiesStartWithBosa` (`zakoPAdESQualifiedURLs.first == bosaURL`, second Sectigo Qualified, all qualified), runner `checkMapsExitCodes` (0 → returns, 3 → `.notCompliant` with stderr lines, 2 → `.unreadable`).
- [ ] **Step 2: Run** `swift test --filter 'EngineBridgeTests|TimestampOptionalTests|PdfClauseCheckRunnerTests'`; expected FAIL.
- [ ] **Step 3: Implement** per the Files list.
- [ ] **Step 4: Run** the same filter; expected PASS.
- [ ] **Step 5: Commit** `feat(signing): send an appended clause to the engine`.

### Task 5: Output choice, register fields and PDF/A-3 in the forms

**Files:**
- Modify: `Chevron7/Sources/Chevron7Kit/Support/AppSettings.swift` (`public enum ZakoClientOutput: String, Codable, CaseIterable, Sendable { case asicContainer, singlePDF }`, `public var zakoClientOutput: ZakoClientOutput` default `.asicContainer`, coding key, `decodeIfPresent`)
- Modify: `Chevron7/Sources/Chevron7Kit/Evidence/LocalEvidenceStore.swift` (`EvidenceRecord.clientOutput: AppSettings.ZakoClientOutput?`, `revisionOneLength: Int?`, both optional and decoded with `decodeIfPresent`)
- Modify: `ConversionFormModel.swift` (`newDocumentFormatOther: String?`; `make(...)` gains `deliveredAsSinglePDF: Bool = false`, which sets format `Iny` and other "PDF/A-3"), `ConversionCertificateRenderer.swift` (write `NewDocumentFormatOther` when set), `ConversionRecordRenderer.swift` (record 1.0: "PDF/A-3"), `ConversionRecord12Renderer.swift` (CL009009 item 3 via new `ZakoCodelists.record12PDFA3Item`), `ZakoClauseDeliveryBuilder.swift` and `ZakoRecordDeliveryBuilder` (pass the flag through)
- Modify: `E2EFormModel.swift` (`make(..., deliveredAsSinglePDF: Bool = false)`: format `(E2ECodelists.otherFormat, "PDF/A-3")`)
- Test: `ConversionCertificateRendererTests.swift`, `ConversionRecordRendererTests.swift`, `ConversionRecord12RendererTests.swift`, `E2EFormRendererTests.swift`, `ZakoClauseDeliveryBuilderTests.swift`, new `Chevron7/Tests/Chevron7AppTests/ZakoClientOutputSettingsTests.swift` (settings via `makeSettingsStore()`)

**Interfaces:**
- Produces: `AppSettings.ZakoClientOutput`, `AppSettings.zakoClientOutput`, `EvidenceRecord.clientOutput`, `EvidenceRecord.revisionOneLength`, the `deliveredAsSinglePDF:` parameters above.

- [ ] **Step 1: Write failing tests**: `singlePDFClauseNamesPdfA3AsOther` (P→E clause XML has `NewDocumentFormat` code `Iny`, `NewDocumentFormatOther` "PDF/A-3", validates against clause 1.3 schema), `singlePDFRecord10SaysPdfA3`, `singlePDFRecord12UsesItem3`, `e2eSinglePDFFormats` (clause and record E→E, schema-valid), `asicOutputUnchanged` (default path renders byte-identical XML to a stored fixture of today's output), `clientOutputDefaultsToContainerAndRoundTrips`, `oldEvidenceRowsDecodeWithoutClientOutput`.
- [ ] **Step 2: Run** the filters; expected FAIL.
- [ ] **Step 3: Implement** per the Files list.
- [ ] **Step 4: Run**; expected PASS, plus `swift test --filter OfficialFormTests`.
- [ ] **Step 5: Commit** `feat(zako): forms and settings for the one-PDF output`.

### Task 6: One-PDF delivery assembly and policy

**Files:**
- Create: `Chevron7/Sources/Chevron7App/ZakoSinglePDFDelivery.swift`
- Test: `Chevron7/Tests/Chevron7AppTests/ZakoSinglePDFDeliveryTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum SinglePDFProductionPolicy {
      static let enabled = false
      static let refusalMessage = "Výstup ako jeden PDF s doložkou Chevron7 v ostrej evidencii zatiaľ nevykonáva: najprv sa overuje v testovacej evidencii. Zvoľte kontajner ASiC-E alebo testovaciu evidenciu."
  }
  struct ZakoSinglePDFDelivery {
      static let mobileRefusal = "Jeden PDF s doložkou autorizujte kartou s mandátnym certifikátom."
      /// Final file name in `directory` for `containerDocumentName`, unique, fixed before the clause.
      static func fixedTarget(in directory: URL, containerDocumentName: String) -> URL
      /// Renders the pages from `clauseXML` and pairs them with the XDC.
      @MainActor static func appendedClause(clauseXML: Data, clauseXDCF: Data, clauseFileName: String,
                                            form: OfficialForm, renderer: ClausePresentationRenderer) async throws -> AppendedClause
      static func refusal(mode: AppSettings.EZZKMode, viaMobile: Bool, provider: QualifiedSigningProviding) -> String?
  }
  ```
  `refusal` returns the production message for `.production` while `SinglePDFProductionPolicy.enabled` is false, `mobileRefusal` for the phone, and "Jeden PDF s doložkou vyžaduje podpisový engine Chevron7." when `!provider.supportsAppendedClause`.

- [ ] **Step 1: Write failing tests**: `fixedTargetAvoidsExistingFile` (existing `Zmluva.pdf` → `Zmluva (2).pdf`), `refusesProductionWhilePolicyOff`, `refusesPhone`, `refusesProviderWithoutAppend`, `allowsDemoAndTest`, `appendedClauseCarriesXdcBytesAndName` (renderer stub; `attachment == clauseXDCF`, `attachmentName == clauseFileName`, `attachmentMimeType == AppendedClause.xdcMimeType`).
- [ ] **Step 2: Run** `swift test --filter ZakoSinglePDFDeliveryTests`; expected FAIL.
- [ ] **Step 3: Implement.** `ClausePresentationRenderer` is injected (protocol `ClausePageRendering` with the Task 1 signature, so tests stub it; `ZakoSessionStore` holds one, default the real renderer).
- [ ] **Step 4: Run**; expected PASS.
- [ ] **Step 5: Commit** `feat(zako): assemble the one-PDF delivery`.

### Task 7: P→E, current order

**Files:**
- Modify: `Chevron7/Sources/Chevron7App/ZakoSessionStore.swift` (`authorizeAndSign`, around :1495-1730)
- Test: create `Chevron7/Tests/Chevron7AppTests/ZakoSinglePDFFlowTests.swift` (fake signing provider capturing `SigningRequest`, as `ZakoRecordFirstFlowTests` does)

**Interfaces:**
- Consumes: Tasks 4 to 6. The output choice is read once at the start of `authorizeAndSign` into a local `let output = settings.zakoClientOutput`.

- [ ] **Step 1: Write failing tests**: `singlePDFSignsPadesWithAppendedClause` (request: `.embeddedPAdES`, `appendedClause` attachment = the clause XDCF, `timestampServers == zakoPAdESQualifiedURLs` outside Demo, no `extraFiles`, `signsExtraFilesAsDataObjects == false`), `singlePDFNameFixedBeforeClause` (an existing file with the default name in the output folder: clause `NewDocumentName` == the delivered file's name == row `deliveredFileName` == row `pdfFileName`), `singlePDFWritesOnePdfOnly` (output folder gains exactly one `.pdf`, no `.asice`, no `.xdcf`), `singlePDFRowFields` (`clientOutput == .singlePDF`, `revisionOneLength == finalPDF.count`, fingerprint == SHA-256 of the signed file's first `revisionOneLength` bytes), `failedSignatureLeavesNumberAndNoOutput` (provider throws: number still in `evidenceNumberPool`, no file, no row), `singlePDFRefusedInProductionBeforeNumber` (no number allocated, `lastError == SinglePDFProductionPolicy.refusalMessage`), `containerOutputUnchanged` (default setting: today's request shape).
- [ ] **Step 2: Run** `swift test --filter ZakoSinglePDFFlowTests`; expected FAIL.
- [ ] **Step 3: Implement.** When `output == .singlePDF`: check `ZakoSinglePDFDelivery.refusal` before any number; compute the output directory and `fixedTarget` before the clause and use its `lastPathComponent` as `containerDocumentName`; build clause and record with `deliveredAsSinglePDF: true`; render `appendedClause` before signing; sign with `outputFormat: .embeddedPAdES`, `appendedClause`, `timestampServers` = `zakoPAdESQualifiedURLs` outside Demo; verify the result's prefix equals `finalPDF`; write `signed.pdfData` to `fixedTarget` (or `uniqueURL` of that name if it appeared meanwhile); fill the row fields. If Task 2's findings say a real P→E `finalPDF` fails veraPDF, stop here and bring it to the owner (spec 5.4 raster offer) instead of shipping a path that always ends in `PDFA_INVALID`.
- [ ] **Step 4: Run** `swift test --filter 'ZakoSinglePDFFlowTests|ZakoClauseRouteTests|ZakoRecordRouteTests|EvidenceSubmissionFlowTests'`; expected PASS.
- [ ] **Step 5: Commit** `feat(zako): deliver a P→E conversion as one PDF`.

### Task 8: P→E, 2027 record-first order

**Files:**
- Modify: `Chevron7/Sources/Chevron7App/ZakoRecordFirstFlow.swift` (`RecordFirstPending` gains `clientOutput: AppSettings.ZakoClientOutput`, `appendedClause: AppendedClause?`, `fixedTarget: URL?`; `signClientContainer` branches)
- Modify: `ZakoSessionStore.swift` (the `.recordFirst` branch: render the pages and run `PdfClauseCheckRunner.check(source: finalPDF, clause:)` before the record is signed)
- Test: `Chevron7/Tests/Chevron7AppTests/ZakoRecordFirstFlowTests.swift`

- [ ] **Step 1: Write failing tests**: `recordFirstChecksPdfaBeforeRecord` (check runner fails: no record signed, no row, number in pool, `lastError` from `PdfClauseCheckRunner.Failure`), `resumeSignsStoredClauseAndKeepsRecordedName` (pending created with `.singlePDF`, the setting switched to `.asicContainer` before "Dokončiť konverziu", a file created at `fixedTarget` meanwhile: request uses the stored `appendedClause`, output written under `uniqueURL` of the fixed name, row `pdfFileName` stays the recorded name), `recordFirstSinglePDFRequestShape`.
- [ ] **Step 2: Run** `swift test --filter ZakoRecordFirstFlowTests`; expected FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter; expected PASS.
- [ ] **Step 5: Commit** `feat(zako): one PDF in the 2027 record-first order`.

### Task 9: E→E

**Files:**
- Modify: `Chevron7/Sources/Chevron7App/ZakoE2EFlow.swift` (around :186-340)
- Test: `Chevron7/Tests/Chevron7AppTests/ZakoE2EFlowTests.swift`

- [ ] **Step 1: Write failing tests**: `keepPlanIsConvertedForSinglePDF` (original with `.keep`: `pdfaFromSignedRunner.convert` is called, the signed request's source is its output, not `original.pdfData`), `e2eSinglePDFRequestShape` (as Task 7, E→E XDC and `form19` pages), `e2eSinglePDFRowFields`, `e2eSinglePDFRasterOfferStillWorks` (runner throws `.notCompliant`: raster offer shown, nothing allocated).
- [ ] **Step 2: Run** `swift test --filter ZakoE2EFlowTests`; expected FAIL.
- [ ] **Step 3: Implement.** `.singlePDF` treats `.keep` as `.convert` (raster offer included), passes `deliveredAsSinglePDF: true` to `E2EFormModel.make` and the dry run, then the Task 7 sequence with `OfficialForm.clauseE2E_1_3` pages. `E2EProductionPolicy` still applies first.
- [ ] **Step 4: Run** `swift test --filter 'ZakoE2EFlowTests|E2EEvidenceRegisterTests'`; expected PASS.
- [ ] **Step 5: Commit** `feat(zako): deliver an E→E conversion as one PDF`.

### Task 10: UI: choice, Done screen, register, sidebar

**Files:**
- Modify: `Chevron7/Sources/Chevron7App/Views/AuthorizeDoneViews.swift` (segmented `Picker` bound to `settings.zakoClientOutput` in `AuthorizeView`, disabled while authorizing; footnote text from spec 5.1 verbatim; "Použiť mobil" disabled with `ZakoSinglePDFDelivery.mobileRefusal` as help while `.singlePDF`; Done screen copy for the PDF)
- Modify: `Chevron7/Sources/Chevron7App/Views/EvidenceDashboardView.swift` (detail row "Výstup pre klienta": "Kontajner ASiC-E" / "Jeden PDF s doložkou", hidden when `clientOutput` is nil)
- Modify: `Chevron7/Sources/Chevron7Kit/Models/UXLabels.swift` (`public static func clientOutputLabel(_ output: AppSettings.ZakoClientOutput?) -> String?`)
- Test: new `Chevron7/Tests/Chevron7KitTests/UXLabelsClientOutputTests.swift`, `Chevron7/Tests/Chevron7AppTests/ZakoMobileAvailabilityTests.swift`

- [ ] **Step 1: Write failing tests**: `clientOutputLabels` (both cases, nil → nil), `mobileDisabledForSinglePDF` (the store's existing mobile availability API returns the refusal for `.singlePDF`; see `ZakoMobileAvailabilityTests`).
- [ ] **Step 2: Run**; expected FAIL.
- [ ] **Step 3: Implement.** Footnote verbatim: "Jeden PDF, ktorého súčasťou je osvedčovacia doložka ako príloha XML a ako posledné strany (§ 37 ods. 4 zákona č. 305/2013 Z. z., § 2 ods. 3 vyhlášky č. 70/2021 Z. z.). Vhodné napríklad pre Obchodný register, ktorý neprijíma kontajnery s viacerými súbormi."
- [ ] **Step 4: Run** `swift test --filter 'UXLabelsClientOutputTests|ZakoMobileAvailabilityTests'`; expected PASS. Build the app (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build_app.sh` from `Chevron7/`) and look at the authorize step in Demo.
- [ ] **Step 5: Commit** `feat(zako): choose the one-PDF output in the authorize step`.

### Task 11: Docs, release note, verification

**Files:**
- Modify: `CLAUDE.md` and `AGENTS.md` (identical): a ZaKo bullet for the one-PDF output (choice, structure, `appendClause`, `PdfClauseAppender`, `SinglePDFProductionPolicy`, spec link)
- Create: `docs/releases/changes/feat-zaruka-jeden-pdf.md` (one Slovak paragraph for the advocate: what the option does and that ORSR is the reason; no signing or notarization talk)
- Modify: `Chevron7/docs/ZAKO-SINGLE-PDF-FINDINGS-2026-11-17.md`

- [ ] **Step 1: Full test runs**: `swift test` (all) from `Chevron7/`, engine `./mvnw ... test` (all). Expected: all green; any pre-existing failure noted with its name.
- [ ] **Step 2: Demo run** in the built app: P→E and E→E with `.singlePDF`; open the delivered PDF in Preview (clause pages, outline, attachment present) and check the Done screen's signature banner validates it; record the results in the findings note.
- [ ] **Step 3: Testovacia evidencia run** with a card (owner's Mac): one P→E and one E→E `.singlePDF` conversion accepted and processed by EZZK; upload one delivered PDF to the slovensko.sk validator and record whether the BOSA timestamp shows. Record in the findings note. This step needs the owner; leave it unchecked if not done and say so.
- [ ] **Step 4: Commit** `docs(zako): one-PDF output` and open the PR. `SinglePDFProductionPolicy.enabled` stays false in this PR; flipping it for P→E is a separate commit after Step 3 and the ORSR answer (spec 5.8).
