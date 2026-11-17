# ZaKo: one PDF with the clause inside (design)

Date: 2026-11-17. Status: for the owner's approval. Project A of three (A: one-PDF output, B: multi-file ASiC-E originals, C: E→E in the 2027 record-first order); the owner set the order A, B, C on 2026-11-17.

## 1. Intent

An advocate using Chevron7 (feedback relayed by the owner on 2026-11-17) needs the result of a guaranteed conversion as **one PDF in which the certification clause is part of the document** (§ 37 ods. 4 zákona č. 305/2013 Z. z., § 37 ods. 3 from 1. 1. 2027). The reason is the Commercial Register (ORSR): in practice it does not accept multi-file containers, so today's ZaKo output (an ASiC-E holding the PDF/A and the clause XDCF) cannot be filed there, and neither can a document the advocate authorized electronically. The advocate's concrete case is E→E (his own authorization container, which needs project B as well), but the same wall stands in front of every P→E conversion meant for ORSR, so the owner decided (2026-11-17) that the one-PDF output is offered for **both directions**.

Success: an advocate converts a document in ZaKo, picks "one PDF", and gets a single PDF/A-3 that ORSR accepts. It carries the content, the clause both as the attached XML form the decree prescribes and as readable last pages, and one PAdES Baseline T signature with the mandate certificate and a qualified timestamp. The record still goes to EZZK as today.

## 2. Law (checked 2026-11-17 on Slov-Lex)

Verbatim where it decides something.

- **§ 37 ods. 4 zákona** (today; § 37 ods. 3 from 2027, same wording): "Osvedčovacia doložka nemusí byť vyhotovená ako samostatný dokument, ak je vyhotovená ako samostatná časť novovzniknutého dokumentu spôsobom, ktorý bez akýchkoľvek pochybností umožní oddeliť obsah osvedčovacej doložky od obsahu zvyšnej časti novovzniknutého dokumentu; podmienka spoločnej autorizácie je splnená autorizáciou novovzniknutého dokumentu."
- **§ 2 ods. 3 vyhlášky 70/2021** (since 1. 4. 2024, vyhláška 63/2024): "Ak ide o zaručenú konverziu podľa § 35 ods. 1 písm. b) a c) zákona, osvedčovacia doložka, ktorá je vyhotovená ako samostatná časť novovzniknutého dokumentu podľa § 37 ods. 4 zákona, sa vyhotovuje vo formáte elektronického dokumentu v jazyku Extensible Markup Language (.xml), zahrnutého v textovom súbore Portable Document Format (.pdf) ako príloha typu EmbeddedFile, pri dodržaní štandardov na prijímanie a čítanie podpísaných elektronických dokumentov podľa osobitného predpisu." This is the decisive rule: P→E (písm. b)) and E→E (písm. c)) alike, the clause inside the new document is the eForm XML attached to the PDF.
- **§ 5 ods. 1 / § 6 ods. 1 vyhlášky 70/2021**: the clause is made with the published eForm, and "Ak je vykonávaná zaručená konverzia, vyhotovuje sa osvedčovacia doložka ako samostatný elektronický dokument a aj ako samostatná časť novovzniknutého elektronického dokumentu, osvedčovacia doložka sa vytvára spôsobom určeným žiadateľom." Read together with § 2 ods. 3 and § 37 ods. 4, Claude reads this as: both forms are lawful and the applicant (žiadateľ, the client) picks one. This is an interpretation, not settled; the in-app choice is how the advocate records the client's pick.
- **§ 5 ods. 2** (and § 6 ods. 2): QES with the mandate certificate or a qualified seal, with a qualified timestamp covering the signature object; certificate data must match the clause. A PAdES Baseline T signature with the mandate certificate meets this.
- **§ 5 ods. 3**: insertion "do podpisového kontajnera" per vyhláška 78/2020. For the clause inside the document, § 37 ods. 4 and the later, specific § 2 ods. 3 govern; the PAdES PDF is the signed document itself.
- **Annex 6 písm. b)** (E→E record) and **annex 4 písm. c)** (P→E record): when the clause is a separate part of the new document, the new document is described only "v rozsahu podľa prílohy č. 2 písm. a) prvého bodu", i.e. name, kind and format, with no fingerprint. The clause annexes (1, 3, 5) do not ask for the new document's fingerprint either. The official forms (clause 1.3, record 1.0, record E→E 1.0, record 1.2) predate this and still require `ElectronicFingerprintValue`; see 5.2.
- **§ 46 ods. 2 písm. h) vyhlášky 78/2020** accepts signed documents "ak neobsahujú vnorené súbory". § 2 ods. 3 vyhlášky 70/2021 requires exactly such an attachment for this case; whether ORSR's intake follows the special rule is unknown (section 9, precondition in 5.8).

## 3. Goals, non-goals, anti-goals

Goals
- A per-conversion output choice in ZaKo, P→E and E→E, in the current order and (P→E) in the 2027 record-first order: "Kontajner ASiC-E" (today, default) or "Jeden PDF s doložkou".
- The one-PDF output: revision 1 = the new document's content as PDF/A; revision 2 = the clause XDC attached as an EmbeddedFile plus the clause pages rendered from the official presentation XSLT, the file now PDF/A-3b; revision 3 = the advocate's PAdES Baseline T signature (mandate certificate, qualified timestamp).
- The whole signed file passes veraPDF as PDF/A-3b before it is delivered.
- Register, Done screen, "Uložiť ako…" and the sidebar work for the PDF as they do for the ASiC-E.

Non-goals
- Multi-file ASiC-E originals (project B), E→E in the 2027 order (project C, `e2eRecordFirstMessage` stays).
- Keeping the client's PAdES signatures inside the one-PDF output (5.4).
- A visible signature stamp; the signature is invisible.
- Phone authorization of the one-PDF output (Demo-only route today; refused with a message, as record-first refuses it).
- Changing the record forms or how the record is signed and sent.
- Rendering the clause natively or changing the live clause preview in `AttestationFormView`.
- Keeping a copy of the client PDF in the evidence folder.

Anti-goals
- A clause fingerprint that does not match bytes a reader can extract from the delivered PDF.
- A delivered PDF that claims PDF/A and fails veraPDF.
- Clause pages that could be mistaken for the original content (no title, interleaved, drawn onto content pages), or pages that differ from the attached XML.
- An evidence number consumed (record accepted by EZZK) for a conversion whose client PDF could not be produced.

## 4. Approaches

How the clause gets into the PDF (owner's decision 2026-11-17, after § 2 ods. 3 was found): **the eForm XML as an EmbeddedFile and, in addition, readable pages rendered from the official presentation XSLT.** The attachment satisfies the decree; the pages make the clause visible to an ORSR clerk who never opens attachments. Considered: XML attachment only (lawful, but the clause is invisible in a PDF viewer's page view); rendered pages only (the first draft, contradicts § 2 ods. 3).

How the pages are made (owner's decision 2026-11-17): **from the form's official presentation XSLT** (`form.2.html2.xslt` for P→E clause 1.3, `form.19.html2.xslt` for E→E clause 1.3) printed to PDF by WebKit. They look like the form on slovensko.sk and a new form version only swaps the XSLT. Considered: a native layout from `ConversionFormModel` (sure PDF/A, but our interpretation and reworked at every form change); composing the PDF in the app with PDFKit (dropped: rewrites the file, no revisions, breaks PDF/A).

Claude's calls inside the chosen approach (owner may override): the revision structure of 5.2 and converting every E→E original to new content for this output (5.4).

## 5. Design

### 5.1 The choice

- `AppSettings.zakoClientOutput`: `.asicContainer` (default) | `.singlePDF`, remembered. Shown in the authorize step (`AuthorizeView`, both directions) as a segmented control "Výstup pre klienta: Kontajner ASiC-E | Jeden PDF s doložkou", with a footnote: "Jeden PDF, ktorého súčasťou je osvedčovacia doložka ako príloha XML a ako posledné strany (§ 37 ods. 4 zákona č. 305/2013 Z. z., § 2 ods. 3 vyhlášky č. 70/2021 Z. z.). Vhodné napríklad pre Obchodný register, ktorý neprijíma kontajnery s viacerými súbormi."
- The choice belongs to the conversion once authorization starts: `RecordFirstPending` stores it, and "Dokončiť konverziu" finishes with the stored choice.
- The phone ("Použiť mobil") is disabled for `.singlePDF` with the reason.
- Production gate: `SinglePDFProductionPolicy.enabled` (owner constant, starts false) refuses `.singlePDF` in Ostrá evidencia with a message; it is set true for P→E in a follow-up commit once one P→E conversion succeeded end to end in Testovacia evidencia and the ORSR precondition (5.8) holds. E→E stays behind `E2EProductionPolicy` as today. (Claude's proposal, not yet confirmed by the owner.)

### 5.2 Structure of the delivered PDF

```
revision 1   new document content, PDF/A (2b in P→E and E→E convert), exact bytes = fingerprint
revision 2   incremental update:
               - EmbeddedFile: the clause XDC, same bytes and name as today's container entry
                 (<number>.xml.xdcf, dolozka.xml.xdcf without a number),
                 /Subtype application/vnd.gov.sk.xmldatacontainer+xml, /AFRelationship /Supplement,
                 listed in /Names /EmbeddedFiles and the catalog's /AF
               - the clause pages appended after all content pages, A4 portrait
               - outline entry "Osvedčovacia doložka" to the first clause page
               - XMP updated: pdfaid:part 3, conformance B
revision 3   PAdES Baseline T signature (DSS), invisible, covering revisions 1 and 2
```

- **Fingerprint.** The forms still require `ElectronicFingerprintValue` for the new document; it is the SHA-256 of revision 1. These are exactly the bytes hashed today (`finalPDF` after `normalizeForDelivery` in P→E, `newDocument` in E→E), so the models, renderers, `RecordFirstPending` and the 2027 record are unchanged. A reader verifies it by cutting the file at revision 1's length, which the Register row stores (`revisionOneLength`). Annexes 4 and 6 do not even ask for this value when the clause is inside the document, so filling it with the content's hash is the most faithful use of a field the form makes mandatory.
- **Format.** `NewDocumentFormat` names the delivered file: PDF/A-3 has no item in codelist 53, so the clause uses `Iny` with `NewDocumentFormatOther` "PDF/A-3" (as the E→E design already does for a kept PDF/A-3) and the records the string "PDF/A-3"; record 1.2 (2027 P→E) uses its codelist's PDF/A-3 item if it has one, else its "other" route (builder checks the codelist).
- **Separation "bez akýchkoľvek pochybností":** the clause is its own revision, its own attachment, its own pages after all content pages under the form's title, and the outline names it.
- **Name:** the delivered file's final name (after `uniqueURL` in the output folder) is fixed **before** the clause XML is built, and that name is `NewDocumentName`, so clause, record and file always agree.

### 5.3 Rendering the clause pages (app side)

- New `ClausePresentationRenderer` (Chevron7Kit): the clause XML that `ZakoClauseDeliveryBuilder` / `E2EDeliveryBuilder` already render and validate → `/usr/bin/xsltproc --nonet` with `OfficialForm.presentation` (already embedded by `scripts/embed-official-forms.sh`) → HTML → PDF.
- HTML → PDF with WebKit printing paginated A4 (`WKWebView.printOperation(with:)` into a PDF file, offscreen, `NSPrintInfo` A4, margins so nothing is clipped); not `createPDF`, which makes one long page. The XSLT's fonts and images are inline base64; the web view loads no network resource (no base URL, a content rule blocking all loads).
- The pages are rendered from the very XML that is attached, so they cannot differ.
- First build step is a spike: render a clause for each form; run veraPDF on a real P→E `finalPDF` alone (it has only ever passed the in-house marker check); append attachment and pages per 5.5 and run veraPDF PDF/A-3b on the result; sign a sample PAdES-T and upload it to slovensko.sk's validator. Record the results and any print CSS needed in a findings note. If WebKit output cannot pass veraPDF with small injected print CSS, stop and come back to the owner.

### 5.4 Producing the new document's content per direction

- **P→E:** unchanged: `pdfaConverter.convert` → `normalizeForDelivery` → `finalPDF`. If the spike shows `finalPDF` failing veraPDF, the one-PDF path checks it with veraPDF before the number is allocated and offers the raster PDF/A as E→E does.
- **E→E:** `.singlePDF` always takes the `.convert` plan (`PdfaFromSigned`, raster offer on veraPDF refusal), even when the original qualifies for `.keep`: pages and an attachment appended after the client's PAdES signatures would leave them reported as modified after signing, the E→E design's anti-goal. The clause and the record describe the client's signatures.

### 5.5 Engine: append and sign

- One signing request does append and signature, so they cannot drift apart: machine protocol v1 file gains optional `appendClause: { pages: <path>, attachment: { source: <path>, name, mimeType } }`, valid only with a `PAdES_BASELINE_*` level and no `attachments`, eForm or visible appearance; `MachineRequestValidator` enforces it and the v1 request schema documents it.
- `SigningJob.build`: with `appendClause`, new `PdfClauseAppender` (PDFBox) imports the pages, adds the EmbeddedFile with `/AF` and `/AFRelationship`, the outline entry and the XMP change, keeps the OutputIntents, and writes one incremental update (`saveIncremental`). `PdfFormAppearances` is not run for this request.
- Pre-signature check in the engine on the appended document: veraPDF PDF/A-3b via DSS `PDFAStructureValidator`; failure ends the request with new error `PDFA_INVALID` and the rule summary, nothing signed.
- The same appender is exposed as a check-only operation (`PDFA_CHECK` with `appendClause`, nothing signed), used before the record is signed in the 2027 order (5.6).
- Signing: PAdES as today (`signDocumentAsPAdeS`), Baseline T. Timestamp servers for this PAdES: BOSA first, then Sectigo Qualified (the app's PAdES rule; `zakoQualifiedURLs` puts Sectigo first only because of XAdES on slovensko.sk). The spike's slovensko.sk upload confirms it.
- `PdfOutputValidator` for `appendClause` requires: the source bytes are a byte-exact prefix of the output; exactly two revisions after the source; page count = source pages + clause pages; the EmbeddedFile equals the given attachment bytes; exactly one new signature at the requested level covering the whole file; veraPDF PDF/A-3b passes on the signed output.
- Swift: `SigningRequest.appendedClause: (pages: Data, attachment: Data, name: String)?` with `outputFormat = .embeddedPAdES`; `EngineBridgeSigningProvider` sends it (v1) and returns the signed PDF as `pdfData`, `asicData == nil`. `QualifiedSigningProviding.supportsAppendedClause` is true for the engine; providers without it make the choice unavailable (Demo signer behaviour left to the builder).

### 5.6 Flow, register, UI

- **Current order (both directions):** fix the output name → build the clause XML (number, time, fingerprint) → render the pages → sign the client PDF (5.5) → sign the record → store and send as today. Everything that can fail on content happens before the record is signed or sent, and an unused number stays in `EvidenceNumberPool`.
- **2027 order (P→E):** fix the name → clause XML → render pages → `PDFA_CHECK` → record first, wait for `.processed` → sign the client PDF with the stored pages and attachment. `RecordFirstPending` gains the output choice and the rendered pages and attachment bytes.
- `EvidenceRecord`: `deliveredFileName` = the PDF's name; `pdfFileName` = `NewDocumentName`; new `clientOutput` (`asicContainer` | `singlePDF`; absent = container for old rows) and `revisionOneLength`. The register keeps no client PDF, as it keeps no client ASiC-E today.
- Done screen: texts that say ASiC-E become output-aware; "Uložiť ako…" already works by extension; the signature banner validates the PDF as any PAdES output. Register detail shows the output type.

### 5.7 Tests

- Engine: append + PAdES-T on a PDF/A-2b source (prefix preserved, page count, EmbeddedFile bytes and `/AF`, outline, veraPDF PDF/A-3b before and after signature); refusal of `appendClause` with XAdES, attachments, eForm or a visible appearance; `PDFA_INVALID` for pages with an unembedded font; output validator refuses a changed prefix or a changed attachment; `PDFA_CHECK` signs nothing.
- Swift: `ClausePresentationRenderer` renders both forms offline with a stable page count for a fixture; fingerprint of revision 1 equals the clause value (P→E, E→E); the output name is fixed before the clause; record-first pending stores and resumes the choice; E→E `.keep` original converted under `.singlePDF`; phone refused; production gate refuses in Ostrá evidencia while false.
- Before the gate opens: one Testovacia evidencia conversion per direction, the slovensko.sk validator upload, and the ORSR precondition (5.8), in a findings note.

### 5.8 Precondition from ORSR practice

Before the production gate opens, the owner gets from the advocate (or a test filing) whether ORSR accepts a PAdES-signed PDF that carries an XML EmbeddedFile, ideally with a sample filing ORSR accepted. If ORSR refuses attachments, the decree (§ 2 ods. 3) and the register's practice conflict, and the owner decides before release.

## 6. Constraints

- Release Xcode 27 toolchain, macOS 27; `/usr/bin/xsltproc` and WebKit are system components.
- No network during rendering; no new third-party dependency (PDFBox and DSS are already in the engine).
- Tests never touch real Application Support, Caches or `UserDefaults` (CLAUDE.md rules).
- CLAUDE.md and AGENTS.md updated together; no em dashes.

## 7. Calls made by Claude (owner may override)

- Default output stays the ASiC-E; the choice is remembered per app.
- Revision structure (5.2), fingerprint = revision 1, `revisionOneLength` stored.
- The attached XML is the same XDC (and name) as today's container entry, `/AFRelationship /Supplement`.
- `NewDocumentFormat` = PDF/A-3 via "Iny".
- E→E under one PDF always converts (5.4).
- A4 portrait clause pages, outline entry, invisible signature.
- BOSA first for this PAdES timestamp.
- Phone refused; no client PDF kept in the register; no "content without clause" export.
- Production gate as in 5.1.

## 8. Left to the builder

- WebKit print margins and injected print CSS, within the spike's findings.
- Demo signer behaviour with `.singlePDF`.
- Record 1.2 codelist route for PDF/A-3.
- Exact Slovak wording of messages beyond the footnote in 5.1, in the app's tone.

## 9. Risks

- **ORSR and attachments:** § 46 ods. 2 písm. h) vyhlášky 78/2020 versus § 2 ods. 3 vyhlášky 70/2021; ORSR's intake is unverified (5.8).
- **Fingerprint over revision 1:** a reader hashing the whole file gets another value; the annexes do not ask for it in this case, the forms do. Goes to MIRRI with the pending 2027 questions.
- **Clause 1.3 (P→E) and record 1.0 wording** of `NewDocumentName` ("uložený v podpisovom kontajneri spolu s osvedčovacou doložkou") assumes a container. Same MIRRI question.
- **2027 decree:** LP/2026/337 replaces 70/2021 on 1. 1. 2027; whether it keeps § 2 ods. 3 is unchecked (its text was not found on 2026-11-17). Check before the 2027 order ships with this output.
- **WebKit output and PDF/A-3b** is unproven until the spike.
