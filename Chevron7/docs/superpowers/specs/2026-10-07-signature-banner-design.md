# Signature banner: existing signatures at a glance

Date: 2026-10-07
Status: implemented on branch claude/signature-banner (2026-10-07)
Branch: `claude/signature-banner`

## Problem

When a signed PDF or ASiC-E is opened, its signatures appear only as the fourth and last card of the signing inspector ("Podpisy v dokumente", `SigningPrepareView.existingSignaturesSection`, `SignatureTreeView`), below the certificate, parameters and visual stamp cards. The owner mostly opens signed documents to add a signature, yet wants to see the existing signatures at a glance without scrolling. The done screen repeats the tree in a card, ZaKo shows the input signatures only as a checklist line and a sentence, and the Safari signing panel does not check the incoming document's signatures at all.

## Goals

1. One status banner above the document that says at a glance whether and by whom the document is signed and whether the signatures are valid.
2. Details on demand in a popover under the banner (revised 2026-10-07 after the owner's check of the test build: the inline expansion pushed the document down with four signatures).
3. The same banner in four places: signing (prepare), signing (done), the Safari signing panel, ZaKo authorization.
4. Signing stays the primary task: the signing inspector holds only what a new signature needs.

## Non-goals

- A separate signatures sidebar or window.
- Changing how signatures are inspected or validated (engine INSPECT and VALIDATE, trusted lists, `SignatureTree`), or ZaKo's legal preflight.
- Batch signing (`SigningBatchView`) and attachments in the Safari panel get no banner.

## Banner

States (tone, symbol, headline; the symbol always accompanies the colour):

| Tone | When | Example headline |
|---|---|---|
| checking (grey, ⏳) | structural tree shown, validation running | "Overujem 2 podpisy voči dôveryhodným zoznamom…" |
| valid (green, ✓) | validated, every signature valid | "Podpísané 2 podpismi, oba platné · Marián Čuprík, Ján Novák" |
| warning (orange, !) | some signature indeterminate, validation unavailable, a nested document skipped, or inspection failed | "1 z 2 podpisov sa nedalo overiť (chýba zoznam CZ) · Marián Čuprík, Petr Dvořák" |
| invalid (red, ✕) | at least one signature invalid | "1 podpis je neplatný · dokument bol po podpise zmenený" |

- No banner for a document without signatures (and nothing unverified).
- Names: up to two names, then "a N ďalší" ("Marián Čuprík a 3 ďalší"). Counts use Slovak plural forms (1 podpis, 2 až 4 podpisy, 5 a viac podpisov) through the existing `SlovakCount` helper.
- Disclosure: a button at the right end, "Podpisy ▾" collapsed, "Skryť ▴" expanded. The expanded state is remembered for all four places (`@AppStorage("signatures.bannerExpanded")`, default collapsed).
- Expanded rows, one per signature: verdict symbol, signer name, qualification badge (`SignatureTreePresentation.qualificationLabel`: KEP, Kvalifikovaná pečať, Nekvalifikovaný, Kvalifikácia neurčená), "QTS" only when full validation confirmed a qualified timestamp (as today), signing time, the data objects it covers (the engine reports no issuer of the signing certificate per signature; adding one is a separate engine change); nested signatures (a signed PDF inside a container) indented under their document; a skipped or failed nested document as a warning row. On the done screen the signature added in this session is first and marked "nový".
- Footer of the expansion: the validation note ("Overené voči dôveryhodným zoznamom EÚ" or the reason it was not), and the actions the place supports: "Overiť znova" (disabled while signing, as today) and "Overiť aj na slovensko.sk".
- Accessibility: the banner is one element whose label is the headline; the disclosure button reads "Zobraziť podpisy" / "Skryť podpisy"; rows read name, qualification and verdict.

## Components

- `SignatureBannerModel` (pure, `Chevron7App`, unit tested): tone, headline, names summary, rows (with nesting and the "nový" mark), validation note, and which actions apply. Built two ways:
  - from `SignatureTreeState` (signing prepare, signing done, Safari), reusing `SignatureTreeSummary` and `SignatureTreePresentation`; `.idle` and an empty tree give no banner, `.inspecting` gives no banner (the structural pass is quick and must not flash), `.failed` gives the warning tone with the reason;
  - from `InputSignatureInspectionResult` (ZaKo): `.valid`, `.invalid`, `.unknown` map to valid, invalid, warning; `.unavailable` and an empty list give no banner; ZaKo's rows are flat (`DocumentSignatureInfo`).
- `SignatureBanner` (SwiftUI view): renders a `SignatureBannerModel`, the disclosure and the actions passed in as closures (absent closure, no button).
- `SignatureTreeLoader` (`@MainActor`, observable): the structural-then-validation pipeline now private to `SigningSessionStore` (`runSignatureTree`, `revalidate`, `validate`, the run token that drops late results, the validation task that is cancelled on replacement), extracted unchanged so `SigningSessionStore` keeps two loaders (existing and result) and `WebSigningCoordinator` gets one. `SigningSessionStore.existingSignatureState` and `resultSignatureState` keep their names and meaning for current callers.

## Placement

1. **Signing, prepare** (`SigningPrepareView`): the banner sits above the PDF preview. The inspector card "Podpisy v dokumente" is removed; the inspector keeps certificate and PIN, parameters, visual stamp and "Pridať podpis". "Overiť znova" and "Overiť aj na slovensko.sk" move into the banner.
2. **Signing, done** (`SigningDoneView`): the banner for the signed output replaces the tree card, with the new signature first and marked "nový".
3. **Safari panel** (`WebSigningSheet`, `WebSigningPrompt`): the banner sits above `WebSigningDocumentPreview`. When a panel request opens, the coordinator classifies the main document's bytes with `ExistingSignatureGuard`; only a signed PDF or a container is inspected (most portal documents are unsigned PDFs or forms and cost no engine work). It writes that document (today held only in memory) to a private temporary file, starts a `SignatureTreeLoader` on it and removes the file when the request ends; attachments are not inspected. The banner appears only once the structural pass found at least one signature. Validation never delays signing: closing the panel, signing or a new request cancels the loader (the existing `WebSignSessionGate` token decides). Because only signed bytes are inspected, an inspection failure always shows the warning.
4. **ZaKo, authorization** (`AuthorizeView` in `AuthorizeDoneViews.swift`): the banner, built from `store.inputSignatureInspection`, replaces the detail sentence under the input signature checklist line; the checklist line itself stays, and so does `AttestationPreflight`'s handling of the input signature state. No "Overiť znova" in ZaKo.

## Error handling

- Engine inspection error: warning tone, "Podpisy sa nepodarilo skontrolovať", reason in the expansion; signing stays possible.
- Validation unavailable (trusted lists not loaded, the 90 s validation limit): warning tone with the reason; rows keep their structural data without green verdicts (`SignatureTree.withoutValidationVerdicts`, as today).
- Nested document skipped (deeper than one level or over 100 MB, `nestedSkipped`) or failed (`nestedError`): warning row naming the document.

## Testing

- `SignatureBannerModelTests`: every tone from tree states and from ZaKo inspections; no banner for idle, inspecting, empty and unavailable; Slovak plurals for 1, 2, 5 signatures; names summary for 1, 2, 4 signers; the "nový" mark and its order; nested rows; QTS only after validation; actions per place.
- `SignatureTreeLoader`: the existing signing store tree tests (`SignatureTreeStoreTests`) pass unchanged against the extracted loader.
- Safari: coordinator tests with a fake provider: inspection starts for a PDF and a container only, not for an XML form or attachments; it is cancelled when the panel closes; a signature completes while validation is still running.
- Manual: a Developer ID test build checked by the owner in all four places with real documents (a signed ASiC-E with several signatures, a signed PDF, an unsigned PDF, a document from a portal, an electronic ZaKo input).

## Docs

`CLAUDE.md` and `AGENTS.md` (identically): the signing bullet ("Signing an already signed document") and the Safari and ZaKo bullets name the banner, its states and the four places; one Slovak release note in `docs/releases/changes/`.

## Revision after the owner's check (2026-10-07)

- The inline expansion is replaced by a scrolling popover under the banner, opened by a bordered "Podpisy (N)" button with the `signature` symbol; nothing is remembered between documents and the document never moves.
- Each row: verdict symbol and word, qualification, "Podpísané <time> · <format>" (format as "XAdES Baseline T"), a timestamp line "Časová pečiatka: <authority>, kvalifikovaná|nekvalifikovaná · <date and time to the second>" (authority and qualification only from full validation, as the structural pass reports the issuer DN), and "pokrýva" only in a container with more than one file. The QTS badge is dropped in favour of the timestamp line.

## Follow-ups after the final review (2026-10-07)

- Names summary: "a N ďalší" for 1 to 4 others, "a N ďalších" from five.
- A structural tree without signatures (only files the engine could not open) reads "Overujem súbory v kontajneri voči dôveryhodným zoznamom…" instead of "Overujem 0 podpisov".
- Safari panel: confirming by card or phone drops a structural inspection still running (`WebSigningSignatureCheck.cancelInspection`), because INSPECT and SIGN share one engine helper; a validation already running stays (its own session) and ends with the request. The protocol v1 runner now stops exactly the cancelled consumer's helper and starts the next run only after it ended, so the signature is neither refused (`launchFailed`) nor stopped by a late cancellation.
- Launch removes `chevron7-web-signatures-*` folders a crash or quit left in the temporary directory.
- Without the engine (Demo), the default tree inspection returns an empty tree for a PDF whose bytes carry no `/ByteRange`, so object streams no longer raise "Podpisy sa nepodarilo skontrolovať" over an unsigned PDF.
- The removed inspector sentence is covered by `existingSignatureFormatNote` for every source kind and output format.
- Coordinator tests (`WebSigningCoordinatorSignatureCheckTests`): panel closed while the check runs, card and phone confirmation during inspection, signature completing while validation runs.
