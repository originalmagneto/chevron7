# PAdES signature hidden in Acrobat by /NeedAppearances (2026-10-02)

## Symptom

Adobe Acrobat DC showed no signature at all (empty Signatures panel, no banner) for a PAdES Baseline T PDF signed by Chevron7 with an I.CA mandate certificate. The source was a PDF exported from a JSF web form (openhtmltopdf): its AcroForm has `/NeedAppearances true`, no `/DA`, an empty `/DR`, and hidden text widgets (`/F 2`, `Rect [0 0 1 1]`, a value but no `/AP`) named `mainForm`, `j_idt12:j_idt13` and `javax.faces.ViewState`. The last one exists twice: two top-level `javax` fields, one widget on page 1 and one on page 3.

The signature itself was valid: `pdfsig` validated it, `qpdf --check` was clean, the incremental update and the cross-reference table were correct, the signature field was in `/AcroForm /Fields` and page 1 `/Annots`, `/SigFlags 3`, `/SubFilter /ETSI.CAdES.detached`.

## Cause

Changing only `/NeedAppearances true` to `false` in the signed revision (same length) made Acrobat list the signature (as invalid, because bytes changed). So Acrobat hides a signature whose signed revision asks it to redraw the form fields.

The same copy also reported "Annotations Deleted: Widget annot on page 1", although the signed revision deletes nothing: DSS and PDFBox rewrite the page 1 widgets unchanged and add the signature widget to page 1 `/Annots`. The likely reading is that Acrobat drew appearances for the earlier revision (flag true) and found none in the signed one (flag false, no `/AP`).

## Fix

`SigningJob.build` passes the document of every PAdES job through `PdfFormAppearances.withGeneratedAppearances` (engine, `digital.slovensko.autogram.core`). For an unsigned PDF whose AcroForm has `/NeedAppearances true`, it loads the PDF with PDFBox and applies the stock `AcroFormDefaultFixup`, which:

- adds `/DA (/Helv 0 Tf 0 g)` and Helv and ZaDb to `/DR` when the form has none,
- builds an appearance stream for every field widget,
- sets `/NeedAppearances false`.

The result is saved as an incremental update (PDFBox 3 tracks the changed objects), so the source stays a verbatim first revision, and the signature follows as a third revision. Every revision from the second on says `false`, and every widget carries an `/AP`, so the signed revision no longer asks Acrobat to redraw anything.

The hook sits in `SigningJob.build`, not only in the machine service, so the Finder Quick Action (`CliApp`, `buildFromFile`) and the HTTP `SignEndpoint` are fixed too. Only PAdES: an ASiC-E (XAdES or CAdES) keeps the source byte-identical as its data object, which ZaKo relies on (the PDF/A SHA-256 is the clause fingerprint).

Checked against the real file with the engine and the test keystore: three revisions, `qpdf --check` clean, `pdfsig` "Signature is Valid", the source a byte-identical prefix, every widget with `/AP` in the signed revision, page 1 `/Annots` only gaining the signature widget.

## Left unchanged on purpose

- An already signed PDF (any signature dictionary, or `/ByteRange` anywhere in the bytes, the same rule as the app's `ExistingSignatureGuard`) stays byte-identical, because rewriting it would break or hide the existing signatures. A new signature added to such a PDF can still be hidden in Acrobat when an earlier signer left the flag true.
- An encrypted PDF stays unchanged.
- When PDFBox cannot build the appearances (it logs the reason and leaves the flag true), the PDF stays unchanged and is signed as before. Clearing the flag without appearances would change what a viewer draws.

## Side effects

- The generated appearances use Helvetica, not embedded. PDF/A-1 and PDF/A-2 already forbid `/NeedAppearances true`, so a conformant PDF/A never enters this path; a source that claims PDF/A but has the flag was not conformant before either.
- The app's own steps cannot reintroduce the flag: the PDF/A conversion and the PDFKit visual stamp run before the engine, which normalizes afterwards. The Swift `PAdESSigner` (Keychain and Demo fallback, no engine) replaces the AcroForm wholesale, so it drops the flag (and the existing fields) anyway.

## Residual risks for the Acrobat check

- The original revision with `/NeedAppearances true` is still revision 1. Acrobat judges the signed revision, but if it still hides the signature, the next step is a full PDFBox save instead of an incremental one (a change inside `PdfFormAppearances` only).
- The duplicated `javax.faces.ViewState` field name is merged by Acrobat across pages and might cause its own "widget deleted" report. Renaming fields is not the remedy; report it first.

## Owner verification

Sign a web form export with `/NeedAppearances true` (for example a slovensko.sk or registry PDF export) as PAdES with the real card, then open it in Acrobat DC: the Signatures panel must list the signature, and the modifications list must not report a deleted widget annotation.
