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

## Open ideas for Chevron7

### A. qpdf as an independent check of the PDFs we write

PdfCraft verifies every file it writes with qpdf in CI. We mention qpdf only in two findings documents.

- Where it pays off: the one-PDF client output (three revisions, `PdfClauseAppender`), `PdfaFromSigned --merge`, `PdfaNormalize`, `PdfFormAppearances`. These are the places where the engine writes PDF structure itself.
- Shape: a test helper that runs `qpdf --check` on the output and fails on errors and warnings; skipped with a clear message when qpdf is not installed, required in CI.
- To decide: whether CI installs qpdf (Homebrew on the runner), and whether warnings fail the test.
- Size: small.

### B. PdfCraft's validator as a second opinion on our signatures

The fixtures showed that two independent validators find what one misses. The other direction has not been tried: run PdfCraft's `sign_list` (through `pdfcraft-cli`) over PDFs signed by Chevron7 (PAdES B and T, with a content timestamp, the one-PDF output, a second signature on a signed PDF) and read what it says about later revisions.

- A one-off experiment, not a test in the repository: it needs `pdfcraft-cli` (a macOS zip in their releases; the owner's Mac has only the GUI app).
- Expect noise: it has no EU trusted lists, so every signer will be "unknown". Only the integrity and change verdicts are interesting.
- Size: an afternoon.

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
