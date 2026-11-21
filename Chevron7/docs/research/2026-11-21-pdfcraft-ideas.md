# What to take from PdfCraft (ideas, 2026-11-21)

Status: ideas and a rough spec, nothing here is decided or built. To be worked out in a later session.

## Source

[storytold/pdfcraft](https://github.com/storytold/pdfcraft): a PDF reader and editor written from scratch in Rust, MIT or Apache-2.0 (compatible with EUPL; the ArtCraft brand is not open). Read on 2026-11-21 at version 0.21.1 (the version installed on the owner's Mac).

Facts that decide how far to trust it:

- The repository was created on 2026-09-30, so it was seven weeks old, with a release every few days, about 21 000 stars, over 100 contributors and 3 497 open issues.
- It has its own PDF parser and writer.
- Its signing is weaker than ours. Its own `docs/gaps.md` (gap 10) lists as missing: PKCS #11 on macOS, EU trusted lists, online OCSP and CRL, timestamp server settings. It signs with a Keychain identity or a `.p12` file, PAdES B-B, with B-T and LTV only when the caller supplies the transport. It cannot sign with an eID or an I.CA card and cannot tell a qualified signature.
- Its PDF/A check covers parts of PDF/A-2b and 3b only. It does not replace veraPDF.

## Rules for anything taken from it

1. No PdfCraft code in Chevron7. Ideas and test cases only.
2. Nothing it writes goes into a signature or the evidence register without our own checks (`PdfOutputValidator`, veraPDF).
3. No Rust helper in the app bundle: a third runtime beside Swift and Java, a larger DMG, one more thing to sign and notarize.
4. No PDF editor in Chevron7. Editing breaks signatures and is outside the product.
5. No `--control` style UI channel (a loopback port into a signing app).

## Done

Attack fixtures for changes after the last PDF signature, after the change classes in PdfCraft's `crates/sign/src/pdf/changes.rs` and `revision_classification_tests.rs`: `PostSignatureChangeAttackTest` and the engine's own check `PdfPostSignatureChanges` (PR #128). DSS 6.5.1 missed three of the cases; they were reported to the DSS team by the owner.

qpdf as an independent check of the PDFs the engine writes (idea A, 2026-11-21): `QpdfCheck` in the engine tests runs `qpdf --check` on the outputs of `PdfClauseAppender` (every append), the signed one-PDF output with three revisions (`MachineSigningServiceTest`), `PdfaFromSigned` (plain, `--raster` and `--merge`, every test), `PdfaNormalize` and `PdfFormAppearances`. The verdict is qpdf's exit code, so warnings fail too: what we write in full must be clean, and an incremental update of a source we did not write may keep the source's own warnings but add none (`assertNoNewFindings`). `QpdfCheckTest` proves the check fails on a damaged file.

- What qpdf found: every engine output made from an intact input is clean, including a `PdfaNormalize` output whose source holds a stream it cannot decode. Two test fixtures were flagged. `PdfaNormalizeTest`'s hand-written incremental update redefined the page object `1 0` as a catalog, and the "collapsed" output carried that page typed `/Catalog`: `PdfaNormalize` rewrites the file but does not repair structural damage in its source (garbage in, garbage out; E→E sends client PDFs through it, and veraPDF judges the result there). The fixture is now a real PDFBox incremental update, and `QpdfCheckTest` keeps the damaged variant as its negative case. The `NeedAppearancesFixture` pages have no `/Resources`, which `PdfFormAppearances` rightly leaves as it is (the source stays a byte-exact prefix). The WebKit-printed clause page fixtures carry "object has offset 0" warnings; `PdfClauseAppender` writes those objects anew, and its output is clean.
- Without qpdf only that check is left out (a notice on stderr, the test's own assertions still run); `AUTOGRAM_REQUIRE_QPDF=1` turns a missing qpdf into a failure, `AUTOGRAM_QPDF` names the binary.
- CI: `release.yml` builds with `-DskipTests`, so the owner chose a separate `engine-tests.yml` (2026-11-21) that runs every engine test on pull requests and main when `engine/` changes. The GitHub `xcode-27-arm64` image has Homebrew 7.0.15 but no qpdf, so the workflow installs it and sets `AUTOGRAM_REQUIRE_QPDF=1`. Locally the whole suite was 768 tests in about 4 minutes.

PdfCraft's validator as a second opinion on our signatures (idea B, 2026-11-21, one-off, nothing added to the repository): `pdfcraft-cli` 0.21.1 (`pdfcraft-cli-0.21.1-macos-universal.zip` from their release, SHA-256 checked, notarized by Learning Machines LLC, unpacked in a scratch folder only) ran `doc_open`, `sign_list` and `doc_revisions` over PDFs the engine signed with the test keystore, a test CA key and the in-process test authority of `ContentTimestampTest` (temporary test methods, not committed).

| File | PdfCraft's verdict |
|---|---|
| PAdES B | intact ("not modified since this signature"), signer unknown |
| PAdES T | intact, embedded timestamp seen |
| PAdES T with the content timestamp | the document timestamp (revision 2, `ETSI.RFC3161`) "modified, but permitted (signature, form fill)", the signature (revision 3) intact |
| Signed again (T with content timestamp, twice) | every earlier timestamp and signature "permitted (signature, form fill)", the last signature intact; five revisions, each signed by the expected field |
| One-PDF output | revisions 1 (PDF/A) and 2 (clause) unsigned, the one signature in revision 3 intact over the whole file |
| Control: `/Info` changed after signing | "permitted (metadata)" |
| Control: a page added after signing | invalid, "pages added or removed" |
| Control: one signed byte flipped | invalid, "altered or corrupted" |

- No disagreement on any file Chevron7 signed: every last signature intact, every earlier one changed only by later signatures and timestamps, and the revision list matches what the engine writes.
- Every signer is "unknown" (no EU trusted lists), as expected; the expired test certificate is reported as not valid at signing time.
- PdfCraft is more lenient than our `PdfPostSignatureChanges` on metadata: it allows a new `/Info` after a signature, which the engine refuses in a conversion since PR #128. Nothing to change on our side.
- Small gaps on their side, not ours: the time of a signature timestamp inside CAdES is not shown (`timestamp_time` empty), only that one exists; a later signature is labelled "form fill" as well as "signature".
- Not covered: a visible stamp, an E→E original, a real card signature with a qualified timestamp. Worth repeating with a real signed file when PdfCraft's change classification changes.

## Open ideas for Chevron7

### C. Review by confidence in the security element step

PdfCraft's OCR Verify screen colours each word by the engine's confidence and jumps to the next suspect with one key. The same idea fits `AnalysisCanvasView`: order pending suggestions from the least certain and add a key for "next uncertain one".

- We already have what it needs: `ElementJudgement`, the kNN distance and the model's sure or unsure answer.
- To decide: whether it replaces or complements "Potvrdiť všetky" and "Odmietnuť návrhy" on a page.
- Size: medium, UI only.

### D. Searchable text layer in the P→E PDF/A (question, not a proposal)

PdfCraft writes OCR results as invisible text over the scan. We run OCR for detection, and it was not checked whether the P→E PDF/A carries a text layer. Adding one to a guaranteed conversion is a legal question first: the text is a guess, not the original. Owner's decision before any work.

## Idea for LawOSS: PdfCraft as a second plugin beside Chevron7

Chevron7 is already a LawOSS plugin for signing (`sign`, `validate`, `inspect` through the bundled `chevron7` CLI and MCP, see `Chevron7/docs/INTEGRATIONS.md`). PdfCraft could be a second one for what happens to a PDF before it is signed. Chevron7 itself would not change.

What it would bring (tool names from PdfCraft's automation table):

- Anonymisation: `redact_mark`, `redact_apply`. Their redaction then proves on its own that the removed text is gone from the content streams, metadata, attachments and earlier revisions, and fails closed when it cannot check something. This is the most careful part of the project.
- Combine, extract and split (`combine`, `extract`, `split`), page operations.
- OCR to a searchable copy (`ocr_recognize`).
- Reading: text in reading order, form fields, document properties.

How it runs: `pdfcraft-cli mcp --root <folder>`, stdio only, no port, every read and write confined to the root; `--compact` keeps the tool list short.

Rules for the flow:

- Edit first, sign last. A change appended after a signature is exactly what `PdfPostSignatureChanges` now refuses in a conversion.
- After any edit, validate with Chevron7 (`inspect` or `validate`) before signing, so an output PdfCraft damaged does not get signed.
- For anonymisation, show the advocate PdfCraft's proof result, not only the redacted page.
- The original stays untouched; edits go to a copy in the matter folder.

Not known yet (LawOSS code was not read for this note):

- How LawOSS registers plugins and whether a second stdio MCP server fits beside the Chevron7 one.
- How `pdfcraft-cli` gets onto the Mac and stays updated (their release zip, not Homebrew as far as was checked).
- Whether a project this young is acceptable for client documents; a pinned version and a short test set of the firm's own PDFs would be the minimum.
- Whether its PDF/A-2b and 3b checks say anything useful next to our veraPDF.

## Not taken

- The signing crate (see Source).
- Their PDF/A conversion and verification as a replacement for veraPDF.
- `tool_search` and `--compact` for our MCP server: we expose a handful of tools, so there is nothing to shorten.
