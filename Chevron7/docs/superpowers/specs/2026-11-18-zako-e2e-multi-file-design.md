# ZaKo E→E: an ASiC-E with several files as the original (project B)

Date: 2026-11-18. Status: draft for the owner's approval. Builds on project A (one-PDF client output, spec `2026-11-17-zako-single-pdf-design.md`, PR #103), on whose branch this work starts.

## 1. Intent

An advocate collected the authorizations of participants on several continents in one ASiC-E that holds several files (owner's relayed feedback of 2026-11-17). The Obchodný register does not accept a container with several files, so the advocate needs a guaranteed conversion of that container (§ 35 ods. 1 písm. c) zákona č. 305/2013 Z. z.) into one new document, ideally project A's one PDF with the clause inside. Chevron7 refuses such an original today (`ElectronicOriginalError.unsupportedContainer`, and `signedPDFInsideContainer` for a PDF data object with its own PAdES).

The owner's decisions:
- 2026-11-17: order A, then B, then C (E→E in the 2027 record-first order).
- 2026-11-18: accept PDF data objects (also with their own PAdES signatures) and PNG and JPEG images; refuse every other data object.
- 2026-11-18: approach 1, the engine reads and builds everything.
- 2026-11-18: every fingerprint is exactly what a signature signed; a PDF whose bytes go beyond its last PAdES revision is two documents.
- 2026-11-18: the real container from the feedback is not available, so B is built and tested on synthetic containers; whether it solves that case is checked when the advocate runs it.

## 2. What the forms allow

- Clause E→E 1.3: `OriginalDocumentInfo` 1 to 999, each authorization lists the documents it covers (`AuthorizedDocument` 1 to 999), `NewDocumentInfo` exactly once. Several originals therefore become one new document.
- Record E→E 1.0: `OriginalDocumentInfo` unbounded, each with its own `OriginalDocumentType`, and the same one `NewDocumentInfo`.
- Naming rule of `OriginalDocumentName` (schema documentation): with several originals each is named as the file is named (for identification in the authorization's document list); a PDF whose PAdES signatures cover different parts gets `<stem>-1`, `<stem>-2`.
- Formats (codelist 53): `PDF`, `PDFA1`, `PDFA2`, `PNG` and others by their usual extension or abbreviation.

## 3. Goals

- An ASiC-E whose data objects are all PDFs (signed or not), PNG or JPEG images is accepted as the original of an E→E conversion, in Demo and Testovacia evidencia like today's E→E.
- Every data object is one original document (or several, for a PDF with PAdES revisions); every container signature and every PAdES signature inside a data object is one authorization naming exactly the documents it covers.
- The new document is one PDF/A-2b: the data objects one after another in an order the advocate can change, one outline item per file.
- Both client outputs of project A work unchanged: the ASiC-E (new PDF/A + clause) and the one PDF (PDF/A-3 with the clause attached and appended).

## 4. Non-goals

- DOCX, ODT, TXT, XML, an XDC form, a nested ASiC or ZIP, any other data object: refused with the file's name.
- An ASiC-S, a detached CAdES (`.p7s`), XAdES_ZEP: still refused.
- Several new documents from one conversion, or one conversion per file.
- The 2027 record-first order for E→E (project C).
- Opening production for E→E (`E2EProductionPolicy.enabled` stays false).

## 5. Anti-goals

- A data object no container signature covers must never reach the new document as if it were authorized.
- The new document must never silently drop, reorder or duplicate a file: the pages, the outline and the clause's document list come from the same ordered list.
- No change to P→E or to an E→E original that works today (a signed PDF, an ASiC-E with one unsigned PDF), except that the latter may now also carry its own PAdES signatures.

## 6. Approaches considered

1. **The engine reads and builds everything (chosen).** The evidence operation lists every data object with its format, SHA-256, the container signatures covering it and, for a PDF, its own PAdES evidence. A merging variant of `PdfaFromSigned` converts each PDF the way it does today, turns each image into a page, joins them into one PDF/A-2b with outline items and checks it with veraPDF. One place builds PDF/A, already checked by veraPDF; project A's outputs need no change. Costs the most Java.
2. **PDFKit merges in Swift, then `PdfaFromSigned` on the result.** Less Java, but PDFKit rewrites the files it joins, loses PDF/A structure and sometimes fonts, so more results would fail veraPDF and end rasterized. Rejected.
3. **One conversion per file.** Several evidence numbers and several outputs, so the Obchodný register would still get several files. Rejected: it does not solve the case.

## 7. Design

### 7.1 Engine: evidence of a container (`ConversionEvidenceService`)

`pdfFacts` keeps its current output for a PDF source and an ASiC-E with one data object, so today's paths decode unchanged. Every ASiC-E source also gets a `dataObjects` array in the order of the zip entries (the order the container lists them), each with:

- `name` (the entry path), `size`, `sha256Base64`;
- `kind`: `pdf`, `png`, `jpeg` or `other`, read from the bytes (`%PDF`, the PNG signature, `FF D8 FF`), never from the extension;
- `coveredBy`: the ids of the container signatures whose signature scope names this entry (DSS `SignatureWrapper.getSignatureScopes()`);
- for a `pdf`: the facts `PdfConversionFacts.read` gives today (PDF/A part, compliance, embedded files), `pages`, and, when it carries PAdES signatures, a nested `evidence` object of the same shape as the top one (signatures with their values, signed revision lengths, slim ETSI reports, signer facts, timestamps, trusted list state, `changesAfterLastSignature`), from one more validation of that data object;
- for a `png` or `jpeg`: `widthPx`, `heightPx`, and the resolution when the file states one.

A data object over 100 MB, or one the engine cannot read, is listed with `kind` `other` and a `problem` string. The top-level `asicDataObjectCount`, `asicDataObjectName` and `asicDataObjectSigned` stay as today for older callers.

### 7.2 Swift: the original (`ElectronicOriginal`, `ConversionEvidence`)

`ConversionEvidence` decodes `dataObjects`. `ElectronicOriginal.make` for an ASiC-E:

- Refuses (new `ElectronicOriginalError` cases, Slovak messages naming the file): a data object of kind `other` ("Súbor X nie je PDF ani obrázok PNG alebo JPEG. Chevron7 ho do nového dokumentu nevie zahrnúť."), a data object no container signature covers, a container without signatures, more than 999 originals or 99 authorizations, and an invalid nested evidence the same way as an invalid top-level one (the gate handles it, 7.4).
- Builds the documents in container order. An image or an unsigned PDF is one document named by its entry. Every fingerprint is exactly the bytes some signature signed (owner's decision of 2026-11-18, "odtlačky presne"): a PDF with PAdES signatures gives one document per distinct signed revision length (the SHA-256 of that prefix, as the single-PDF path does today), and the whole data object is one more document whenever its bytes differ from the longest signed revision in any way, DSS extension data (a DSS dictionary, document timestamps) included. With more than one document they are `<stem>-1`, `<stem>-2`, ... in revision order, the whole data object last; each PAdES signature names only its revision's document, each container signature covering the file only the whole data object's document. Only when the longest signed revision is the whole file do the two share one document.
- Names are the entry's last path component; when two entries share it, the full entry path is used for those entries.
- Formats: a PDF as `documentFormat` does today; a PNG as the codelist 53 `PNG` item; a JPEG as `Iny` with other text `JPEG` unless codelist 53 has a JPEG item (the builder checks the official filler's list and records the source in `E2ECodelists`).
- Authorizations: every container signature (documents: every document of the data objects in its `coveredBy`) and every nested PAdES signature (documents: the revision document it signed and none other), with the same fields as today taken from the evidence they came from (top or nested; the validation time of the nested evidence for nested ones).
- `kind` gains `.asicEMultiple(entries:)` (or an equivalent carrying the ordered data objects with their bytes); `pdfData` stays for the one-PDF paths.
- `plan`: an ASiC-E with exactly one unsigned PDF/A data object keeps today's `.keep` rule; every other container is `.convert(reason:)`, the reason saying the files are joined into one PDF/A.

A PDF data object with embedded files is converted without them, as today's single-PDF path does; the evidence lists their names (`embeddedFileNames`) and the verification step names them under that file ("Prílohy v PDF sa do nového dokumentu neprenesú: ..."), so nothing disappears without a word (my call).

A changed-after-last-signature PAdES inside a data object is not refused: the container signatures covering the whole data object authorize those bytes. The verification step shows it as a note on that file.

### 7.3 Engine: the new document (`PdfaFromSigned` merge)

A second entry point, `PdfaFromSigned --merge <out.pdf> <iccProfile> <title> [--raster] <in> <name> [<in> <name>]...`, also callable in process:

- each PDF input goes through today's `stripAndFlatten` (or `rasterized` with `--raster`) on its own and its pages are imported in order;
- each PNG or JPEG becomes one page (my proposal, left to the builder to tune: an A4 page in the image's orientation, the image scaled to fit inside 10 mm margins and never enlarged beyond its stated resolution, or 150 dpi when none is stated); a CMYK JPEG is converted to RGB;
- one outline item per input at its first page, titled with its name;
- then `PdfaNormalize` and veraPDF exactly as the single-file path, with the same result shape (`compliant`, rule errors), so the existing raster offer applies to the whole document.

`PdfaFromSignedRunner` gets a `merge(_ inputs: [(data: Data, name: String)], title:raster:)` that writes the inputs to a temporary folder it removes afterwards.

### 7.4 App flow

- **Verification (`ZakoVerificationView`).** For a multi-file original a "Súbory v kontajneri" list shows each file in the current order with its format, page count (images: 1), the signers covering it and, for a PDF with its own signatures, those signatures under it. The advocate moves files up and down (default: container order). Each file has its own "Druh dokumentu" field, defaulting to the common value the screen offers today, because the record carries `OriginalDocumentType` per original. Authorization rows stay as today; a nested signature names the file it belongs to.
- **Gate (`E2EVerificationGate`).** Unchanged rules over every authorization, nested ones included.
- **Attestation.** "Názov nového dokumentu" defaults to the container's stem. Clause and record list the originals in the chosen order.
- **Authorization.** Where `ZakoE2EFlow` converts today, a multi-file original calls `merge` with the data objects in the chosen order; everything after (evidence number, forms, ASiC-E or one PDF, record, Register, EZZK) is unchanged. The order and the per-file types are part of the session state and kept by the paths that keep the attestation today.
- **Qualified validation report (Ostrá evidencia only, still locked).** The report must name every original or every signature; otherwise the advocate confirms as today.

### 7.5 Register

Nothing new is stored. The Register does not keep the original's bytes (today neither), so the file order and the per-file types survive only inside the clause and the record, which the Register keeps in the delivered file and `Evidence/records/<id>.asice`.

### 7.6 Time frame

From 2026-12-31T23:00Z every E→E conversion is refused until project C (`e2eRecordFirstMessage`), so B alone serves about six weeks. The new state (the multi-file original, the file order, the per-file types) is built so `RecordFirstPending` can carry it in project C (my call). A single-file E→E conversion accepted by Testovacia evidencia is still the owner's pending live check; B does not wait for it, but its own live check follows it.

Trusted lists: the engine loads only SK, CZ, AT, PL, HU, BE, NL, ES, so a signer whose qualified certificate comes from another country is recorded as "nie je možné zistiť" after the advocate's confirmation, as today.

## 8. Tests

- Engine: evidence of containers with two PDFs, PDF plus PNG plus JPEG, a PDF carrying two PAdES revisions, an uncovered entry, a DOCX entry, two entries with the same file name in different folders; `coveredBy` when a second XAdES signature covers only one file; the merge entry point (page count, outline titles and order, veraPDF PDF/A-2b, CMYK JPEG, `--raster`).
- Swift: `ElectronicOriginal.make` for each of those, names and formats, authorization document lists, each refusal; `E2EFormModel` clause and record with three originals and nested signatures, validated against the official clause schema and the record's validation schema; order change reaching pages, outline and forms alike.
- App: the multi-file path through Demo with both client outputs.
- Fixtures are built in the tests (no client documents in the repo).

## 9. Left to the builder

- The exact JSON names beyond those listed, and how nested evidence shares code with the top-level path.
- The image page geometry within the proposal in 7.3.
- How the reorder control looks (buttons or drag), within the macOS conventions the verification view already uses.
- Codelist 53 items for PNG and JPEG, checked against the official filler.

## 10. Calls made without the owner (to check while reading)

- Container order as the default page order, changeable by the advocate.
- One "Druh dokumentu" per file.
- A file covered by no container signature refuses the whole conversion.
- Image pages on A4 with margins.
