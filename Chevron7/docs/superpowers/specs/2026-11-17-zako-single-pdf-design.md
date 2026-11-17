# ZaKo: one PDF with the clause inside (design)

Date: 2026-11-17. Status: draft for the owner's approval. Project A of three (A: one-PDF output, B: multi-file ASiC-E originals, C: E→E in the 2027 record-first order), agreed order A, B, C.

## 1. Intent

An advocate using Chevron7 (feedback relayed by the owner on 2026-11-17) needs the result of a guaranteed conversion as **one PDF in which the certification clause is part of the document** (§ 37 ods. 4 zákona č. 305/2013 Z. z., § 37 ods. 3 from 1. 1. 2027). The reason is the Commercial Register (ORSR): in practice it does not accept multi-file containers, so today's ZaKo output (an ASiC-E holding the PDF/A and the clause XDCF) cannot be filed there, and neither can a document the advocate authorized electronically. The advocate's concrete case is E→E (his own authorization container, which needs project B as well), but the same wall stands in front of every P→E conversion meant for ORSR, so the owner decided (2026-11-17) that the one-PDF output is offered for **both directions**.

Success: an advocate converts a document in ZaKo, picks "one PDF", and gets a single PDF/A that ORSR accepts, which carries the content, the clause as its own clearly separate last pages, and one PAdES Baseline T signature with the mandate certificate and a qualified timestamp, while the record still goes to EZZK as today.

## 2. Law (checked 2026-11-17 on Slov-Lex)

- **§ 37 ods. 4 zákona** (today; § 37 ods. 3 from 2027, same wording): the clause need not be a separate document if it is made as a separate part of the new document in a way that allows its content to be separated from the rest "bez akýchkoľvek pochybností"; the condition of joint authorization is met by authorizing the new document.
- **§ 5 ods. 1 and § 6 ods. 1 vyhlášky 70/2021**: the clause is made with the published eForm (annex 3 for P→E, annex 5 for E→E); where the clause can be made both as a separate document and as a separate part of the new document, it is made "spôsobom určeným žiadateľom". The output choice in the app is that choice of the client (žiadateľ), made through the advocate.
- **§ 5 ods. 2** (and § 6 ods. 2): QES with the mandate certificate or a qualified seal, with a qualified timestamp covering the signature object; certificate data must match the clause. A PAdES Baseline T signature with the mandate certificate meets this.
- **§ 5 ods. 3**: insertion of the document, the clause and the signature "do podpisového kontajnera" per vyhláška 78/2020. A PAdES PDF is a "priamo podpísaný elektronický dokument" (§ 46 ods. 2 písm. a) vyhlášky 78/2020), not a container under § 47. The statute (§ 37 ods. 4) prevails and allows the clause inside the document; this tension is a stated risk (section 9), not a blocker.
- **§ 46 ods. 2 písm. h) vyhlášky 78/2020**: signed documents without nested files, so the clause's XML cannot be attached inside the PDF. The clause is present as rendered pages only.

## 3. Goals, non-goals, anti-goals

Goals
- A per-conversion output choice in ZaKo, P→E and E→E, in the current order and (P→E) in the 2027 record-first order: "Kontajner ASiC-E" (today, default) or "Jeden PDF s doložkou".
- The one-PDF output: revision 1 = the new document's content as PDF/A-2b (its SHA-256 is the clause's and the record's fingerprint), revision 2 = the clause pages rendered from the official eForm presentation XSLT, revision 3 = the advocate's PAdES Baseline T signature (mandate certificate, `TimestampAuthority.zakoQualifiedURLs` outside Demo).
- The whole signed file passes veraPDF as PDF/A-2b before it is delivered.
- Register, Done screen, "Uložiť ako…" and the sidebar work for the PDF the same way they do for the ASiC-E.

Non-goals
- Multi-file ASiC-E originals (project B), E→E in the 2027 order (project C, `e2eRecordFirstMessage` stays).
- Keeping the client's PAdES signatures inside the one-PDF output (see 5.4).
- A visible signature stamp; the signature is invisible.
- Phone authorization of the one-PDF output (Demo-only route today; refused with a message, as record-first refuses it).
- Changing the record forms or how the record is signed and sent.
- Rendering the clause natively or changing the live clause preview in `AttestationFormView`.

Anti-goals
- A clause whose fingerprint does not match the bytes a reader can extract from the delivered PDF.
- A delivered PDF that claims PDF/A and fails veraPDF.
- A one-PDF output where the clause pages could be mistaken for part of the original content (no separation page or heading, pages interleaved, or the clause drawn onto content pages).
- An evidence number consumed (record accepted by EZZK) for a conversion whose client PDF could not be produced.

## 4. Approaches (decided 2026-11-17)

1. **Clause pages from the official presentation XSLT (chosen).** The clause XML is transformed by the form's own `form.2.html2.xslt` (P→E clause 1.3) or `form.19.html2.xslt` (E→E clause 1.3), and the HTML is printed to PDF by WebKit. The pages look exactly like the form on slovensko.sk, which is the strongest reading of "s použitím elektronického formulára"; a new form version only swaps the XSLT. Cost: the page content is not ours (fonts, page breaks, transparency) and must pass veraPDF.
2. Native layout of the clause from `ConversionFormModel` (CoreGraphics, embedded fonts): sure PDF/A, but our interpretation instead of the form, reworked at every form change, a weaker argument before ORSR or MIRRI. Not chosen.
3. Composing the PDF in the app with PDFKit: rewrites the whole file, so no revision structure, no verifiable fingerprint and broken PDF/A. Dropped.

Common to 1 and 2 and decided with the owner: the revision structure (5.2) and conversion of every E→E original to new PDF/A content in this output (5.4).

## 5. Design

### 5.1 The choice

- `AppSettings.zakoClientOutput`: `.asicContainer` (default) | `.singlePDF`, remembered. Shown in the authorize step (`AuthorizeView`, both directions) as a segmented control "Výstup pre klienta: Kontajner ASiC-E | Jeden PDF s doložkou", with a footnote: "Jeden PDF, v ktorom je osvedčovacia doložka samostatnou poslednou časťou (§ 37 ods. 4 zákona č. 305/2013 Z. z.). Vhodné napríklad pre Obchodný register, ktorý neprijíma kontajnery s viacerými súbormi."
- The choice is part of the conversion once authorization starts: `RecordFirstPending` stores it, and "Dokončiť konverziu" finishes with the stored choice, not the current setting.
- The phone ("Použiť mobil") is disabled for `.singlePDF` with the reason, as for record-first.

### 5.2 Structure of the delivered PDF

```
revision 1   new document content, PDF/A-2b, exact bytes hashed into clause and record
revision 2   incremental update: the clause pages appended at the end of the page tree,
             each page with the heading the XSLT draws ("Osvedčovacia doložka ...");
             an outline (bookmark) entry "Osvedčovacia doložka" pointing to its first page
revision 3   PAdES Baseline T signature (DSS), invisible, covering revisions 1 and 2
```

- **Fingerprint.** `ElectronicFingerprintValue` in the clause and the record is the SHA-256 of revision 1, i.e. of the bytes before the first appended revision. These are exactly the bytes today's code already hashes (`finalPDF` after `normalizeForDelivery` in P→E, `newDocument` in E→E), so the model, the renderers, `RecordFirstPending` and the record EZZK already holds in the 2027 order stay unchanged. Anyone can verify it by cutting the file at the end of revision 1 (the first `%%EOF` after the original cross reference), which the Register will also do (5.6).
- **Separation "bez akýchkoľvek pochybností":** the clause is its own revision, its own pages after all content pages, opens with the form's own title, and the outline names it. Nothing of the clause is drawn on content pages.
- **Page size:** A4 portrait for the clause pages regardless of the content's page size.
- **Name:** `NewDocumentName` = the delivered file name, `ConversionOutputNaming.containerDocumentName` (the sanitized "Názov výstupu (PDF/A)" with `.pdf`), unchanged; the file next to the source is that name, made unique with `uniqueURL`.

### 5.3 Rendering the clause pages (app side)

- New `ClausePresentationRenderer` (Chevron7Kit): clause XML (the same XML that `ZakoClauseDeliveryBuilder` / `E2EDeliveryBuilder` render and validate) → `/usr/bin/xsltproc --nonet` with `OfficialForm.presentation` (already embedded by `scripts/embed-official-forms.sh`) → HTML → PDF.
- HTML → PDF with WebKit printing paginated A4 (`WKWebView` `printOperation(with:)` into a PDF file, offscreen, `NSPrintInfo` A4, margins chosen so nothing is clipped). `createPDF` is not used because it produces one long page. Inline base64 fonts and images in the XSLT are already self-contained; the web view loads no network resource (`loadHTMLString` with no base URL, content rules blocking all network).
- The rendered PDF is an intermediate; it never reaches the client as its own file.
- The first build step is a spike: render a clause for each form, merge per 5.4, run veraPDF on the result, and record what CSS the XSLT output needs (if any) in a findings note. If WebKit output cannot pass veraPDF PDF/A-2b with small injected print CSS, stop and come back to the owner before falling back to approach 2.

### 5.4 Producing the new document's content per direction

- **P→E:** unchanged: `pdfaConverter.convert` → `normalizeForDelivery` → `finalPDF`, fingerprint over it.
- **E→E:** `.singlePDF` always takes the `.convert` plan (`PdfaFromSigned`, offering `--raster` when veraPDF refuses), even when the original would qualify for `.keep`. Reason: appending pages after the client's PAdES signatures leaves them cryptographically valid but reported as modified after signing, and that is the anti-goal of the E→E design. The clause and the record already describe the client's signatures; `NewDocumentInfo` describes the converted content as for any `.convert` plan.

### 5.5 Engine: append and sign

- One signing request does both steps, so the appended clause and the signature cannot drift apart: machine protocol v1 file gains an optional `appendPages: { source: <path to the clause pages PDF> }`, valid only with a `PAdES_BASELINE_*` level and no `attachments`, eForm or visible appearance. `MachineRequestValidator` enforces it; the v1 request schema documents it.
- `SigningJob.build`: with `appendPages`, `PdfClauseAppender` (new, PDFBox) imports the pages of the clause PDF into the source document, adds the outline entry, keeps the catalog's OutputIntents and XMP (`pdfaid` part 2, conformance B) intact, and writes an incremental update (`saveIncremental`). `PdfFormAppearances` is not run for this request (the source is our own PDF/A).
- Pre-signature check, in the engine, on the appended (unsigned) document: veraPDF PDF/A-2b through DSS `PDFAStructureValidator`; a failure ends the request with a new error code `PDFA_INVALID` and the veraPDF rule summary, nothing signed.
- Signing: PAdES as today (`signDocumentAsPAdeS`), Baseline T with the request's timestamp servers.
- `PdfOutputValidator` for `appendPages` requires: the source bytes are a byte-exact prefix of the output; exactly two revisions after the source (the append and the signature); page count = source pages + clause pages; exactly one new signature at the requested level covering the whole file; and veraPDF PDF/A-2b passes on the signed output.
- Swift: `SigningRequest.appendedPagesPDF: Data?` with `outputFormat = .embeddedPAdES`; `EngineBridgeSigningProvider` sends it (v1 only) and returns the signed PDF as `pdfData` with `asicData == nil`. `QualifiedSigningProviding` gains `supportsAppendedPages` (true for the engine, false for Keychain/Demo signer, which refuses the choice with a message outside Demo; in Demo the local signer may append with PDFKit-free concatenation only if trivial, else the choice is unavailable in Demo, builder's call).

### 5.6 Flow, register, UI

- **Order of work at authorization (both directions):** build the clause XML as today (number, time, fingerprint) → render clause pages (5.3) → for the current order: sign the client PDF (5.5) → sign the record → store and send as today. For the 2027 P→E order: record first, wait for `.processed`, then sign the client PDF with the pending clause pages. Rendering happens before any number is consumed in both orders, so a template failure leaves the number in `EvidenceNumberPool`. A `PDFA_INVALID` from the engine in the current order happens before the record is signed or sent; in the 2027 order it happens after EZZK accepted the record, which is why rendering and a veraPDF dry run of the appended document (engine operation `PDFA_CHECK` on the unsigned append, same appender) run **before the record is signed** in the 2027 order.
- `RecordFirstPending` gains the output choice and the clause pages PDF (or the clause XML to re-render; builder's call, the stored bytes are simpler and deterministic).
- `EvidenceRecord`: `deliveredFileName` = the PDF's name; `pdfFileName` = `containerDocumentName`; new `clientOutput` (`asicContainer` | `singlePDF`, absent = container for old rows). The clause XML for a one-PDF conversion is kept in `Evidence/clauses/<id>.xml` (the ASiC-E kept it inside; here only its rendering is delivered).
- Done screen and Register detail: "Uložiť ako…" works by extension already; texts that say ASiC-E become output-aware. Register detail for a one-PDF row adds "Uložiť obsah bez doložky…" (revision 1 extracted, so the fingerprint can be checked by anyone) and shows that revision 1's SHA-256 matches the record.
- The signature banner on the Done screen validates the PDF as for any PAdES output.

### 5.7 Tests

- Engine: append + PAdES-T on a PDF/A-2b (prefix preserved, page count, outline, veraPDF passes before and after signature); refusal of `appendPages` with XAdES, attachments, eForm or a visible appearance; `PDFA_INVALID` on a clause PDF with an unembedded font; output validator refuses an output whose prefix differs.
- Swift: `ClausePresentationRenderer` renders both forms offline (no network access, deterministic page count for a fixture); fingerprint of revision 1 equals the clause value for P→E and E→E; record-first pending stores and resumes the choice; E→E `.keep` original is converted under `.singlePDF`; register export of revision 1 hashes to the record value; phone refused.
- A Testovacia evidencia run per direction before release, and one filing of the output into ORSR's test or a real filing by the advocate who asked, recorded in a findings note.

## 6. Constraints

- Release Xcode 27 toolchain, macOS 27; `/usr/bin/xsltproc` and WebKit are system components.
- No network during rendering; no new third-party dependency in the app or the engine (PDFBox and DSS are already there).
- Tests never touch real Application Support, Caches or `UserDefaults` (CLAUDE.md rules).
- CLAUDE.md and AGENTS.md updated together; no em dashes.

## 7. Calls made by Claude (owner may override)

- Default output stays the ASiC-E; the choice is remembered.
- Clause pages are A4 portrait and carry an outline entry; no visible signature.
- E→E under one PDF always converts (5.4), agreed in conversation as part of the structure.
- Clause XML kept in `Evidence/clauses/`; Register offers revision 1 export.
- The phone is refused for the one-PDF output.

## 8. Left to the builder

- WebKit print margins and any injected print CSS, within the spike's findings.
- Whether `RecordFirstPending` stores the rendered pages or re-renders.
- Demo signer behaviour (5.5).
- Exact Slovak wording of messages beyond the footnote in 5.1, following the app's tone.

## 9. Risks

- **Fingerprint over revision 1.** The clause says "hash of the new document"; a reader who hashes the whole delivered file gets a different value. The Register export and the outline mitigate; the question goes to MIRRI with the pending 2027 questions.
- **Clause 1.3 (P→E) and record 1.0 wording** of `NewDocumentName` ("uložený v podpisovom kontajneri spolu s osvedčovacou doložkou") assumes a container. The E→E forms do not. Same MIRRI question.
- **§ 5 ods. 3 vyhlášky 70/2021** names a signature container; PAdES is not one under § 47 vyhlášky 78/2020. The statute allows the clause inside the document; risk stated, not resolved by code.
- **ORSR acceptance** is the advocate's report, not verified by us; the first real filing is the test.
- **WebKit output and PDF/A** is unproven until the spike.
