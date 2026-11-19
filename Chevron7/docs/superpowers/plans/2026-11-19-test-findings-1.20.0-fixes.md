# Fixes from the 1.20.0 test on the MacBook Air (2026-11-19)

Status: plan only, nothing implemented. Source: `Chevron7/docs/TEST-RESULTS-1.20.0-air.md` (card-free run, no SAK card was available). Line numbers refer to `main` at 96c00a81.

Every user-facing string stays Slovak, every identifier and comment English, no em dashes. Each fix gets a test in the existing suites and a Slovak change note under `docs/releases/changes/` (`fix-*.md`).

## Priority

| # | Finding | Severity | Effort |
|---|---|---|---|
| F1 | English DSS text and ".." in the Slovak verification notice | medium (seen by the advocate on every undetermined signature) | S |
| F2 | Record-first refusal of an undetermined qualification (DSS NA) comes only after the card and PIN | medium | S |
| F3 | "Autorizovať konverziu" gives no feedback for about 10 s before "Vložte kartu" | medium | S |
| F4 | Two "Druh dokumentu" pickers for a container with a file list | medium (which one counts is unclear) | M |
| F5 | Verification preview is blank for a container without a PDF (PNG/JPEG) | low | S |
| F6 | Default new document name: no ".pdf" for one file, ".pdf" for several | low | XS |
| F7 | "Autorizovať mobilom" is active under the 1. 1. 2027 order and refuses only on click (P→E) | low | XS |
| F8 | Authorize checklist does not say that the EZZK account is signed out | medium (the PIN is asked before EZZK refuses) | S |
| F9 | Checklist says "(testovacia evidencia)" in Demo | low | XS |

## F1: DSS reason in English, double period

Seen: "Podpis Jano Suchal sa nepodarilo overiť: The certificate chain for signature is not trusted, it does not contain a trust anchor.. Do doložky aj záznamu sa zapíše „nie je možné zistiť“."

Cause:
- `ElectronicOriginal.swift:564` takes `signature.detail` as the reason.
- `detail` is `validationReason ?? subIndication` (`SignatureTreeDecoder.swift:44`, `EngineBridgeSigningProvider.swift:329`), so DSS's English sentence wins over the code.
- `ZakoVerificationView.swift:191` appends "." to a reason that already ends with one. The same pattern sits in `E2EVerificationGate.decide` (`ElectronicOriginal.swift:736`).

Fix:
1. Add `DSSSubIndicationText` (Chevron7Kit, next to `SignatureTreePresentation`), mapping the ETSI EN 319 102-1 sub-indications to Slovak. Examples:
   - `NO_CERTIFICATE_CHAIN_FOUND`: "reťazec certifikátov nevedie k dôveryhodnej autorite"
   - `OUT_OF_BOUNDS_NO_POE` / `OUT_OF_BOUNDS_NOT_REVOKED`: "certifikát v čase overenia nebol platný"
   - `REVOKED_NO_POE`: "certifikát bol zrušený"
   - `TRY_LATER`: "stav certifikátu sa zatiaľ nedá zistiť"
   - `SIGNED_DATA_NOT_FOUND`, `FORMAT_FAILURE`, `HASH_FAILURE`, `SIG_CRYPTO_FAILURE`, `CRYPTO_CONSTRAINTS_FAILURE*`, `CHAIN_CONSTRAINTS_FAILURE`, `NO_SIGNING_CERTIFICATE_FOUND`, `NO_POE`, `EXPIRED`, `NOT_YET_VALID`, and the rest of the enum.
   - Unknown code: "dôvod: <code>".
2. Keep the subindication on `Authorization` (new field `subIndication`). Build `reason` from the Slovak text. Keep DSS's English sentence only as a secondary `technicalDetail`, shown in a disclosure ("Technický detail") and in the saved ETSI report, never in the sentence.
3. Join reasons without double punctuation: trim trailing "." and whitespace before appending, in `ZakoVerificationView.undeterminedMessage` and `E2EVerificationGate.decide`.
4. Tests: a decoder fixture with `subIndication = NO_CERTIFICATE_CHAIN_FOUND` and an English `validationReason` gives the Slovak reason. A reason ending in "." gives one period.

## F2: Undetermined qualification refused late under record-first

Seen with `R3-cades.asice` and `E3-sample-signed.pdf` (qualification "DSS: NA") in Demo with "Postup od 1. 1. 2027 vopred" on: verification offered "Pokračovať aj tak", the clause and authorize steps showed no problem, and "Autorizovať konverziu" asked for the SAK card.

Cause:
- The check `ConversionRecordE2E12Renderer.unmappableAuthorizations` runs only inside `authorizeElectronicOriginal` (`ZakoE2EFlow.swift:209`).
- That function is reached after the card flow (`ZakoMandateCardFlow.advanceCardFlow`) and the PIN. The number is still safe, but the advocate types a PIN for a conversion that can never succeed.

Fix:
1. Add a computed `e2eRecordFirstRefusal: String?` on `ZakoSessionStore`. It is non-nil when `ZakoRegime.resolve(conversionTime: Date(), mode:, preview:)` is `.recordFirst` and `unmappableAuthorizations(original)` is not empty, and returns `e2eUndeterminedQualificationMessage`.
2. Show it as a blocking `ZakoNotice` in `ZakoVerificationView` (instead of "Pokračovať aj tak" for that signature) and as a failed checklist item in `e2eChecklistItems`.
3. Make `canBeginAuthorization` false while it is set, so `beginAuthorization` never reaches the card.
4. Keep the existing check in `authorizeElectronicOriginal`: EZZK's time still decides at authorization.
5. Tests: the store with preview on and an NA authorization has `canBeginAuthorization == false` and the message. With preview off (record 1.0) nothing changes.

Not a bug: an ASiC-E with a CAdES signature is accepted on purpose. Only detached CAdES is refused, and record 1.2 handles CAdES content timestamps. Do not add a refusal.

## F3: No feedback for about 10 s after "Autorizovať konverziu"

Cause:
- `advanceCardFlow` first awaits `readCard()` → `signingProvider.availableIdentities()`, which asks the engine for drivers and identities. On the Air this takes about 10 s.
- `cardPrompt` is set to `.insertCard` only afterwards. Meanwhile the button stays enabled and the certificate card keeps showing "Vyhľadávam certifikáty…".

Fix:
1. Add a `cardPrompt` state `.checkingCard` (sheet title "Kontrolujem kartu…", spinner, "Zrušiť"), set synchronously in `beginAuthorization` before the first `await`. Disable "Autorizovať konverziu" while `pendingCardAction != nil`.
2. Fast path: when the shared `CardReaderStatus` poll (CryptoTokenKit slot state, no card session) already reports no card in any reader, go straight to `.insertCard` without asking the engine. `waitForCard` then keeps polling as today.
3. Cancel from `.checkingCard` calls `cancelCardFlow()`, and a late `readCard` result is dropped when `pendingCardAction` is nil.
4. Test: the store with a provider whose `availableIdentities` sleeps shows `.checkingCard` before it returns, and `.insertCard` immediately when the reader status says empty.

## F4: Two "Druh dokumentu" for a container with a file list

Seen with `E4-png-xades.asice`: "Osvedčenie" was picked for sample.png under "Súbory v kontajneri", but the clause step still showed a separate "Druh dokumentu: Iný dokument" for the whole container.

Cause:
- The clause step picker (`ZakoVerificationView.swift:665`) edits `attestation.originalDocumentTypeLabel`.
- The per-file field (`:357`) edits `originalDocumentTypeLabels[entryName]` and falls back to the container label (`:385`).
- The record takes the per-file value (`E2EFormModel.originalDocumentTypes`), and the E→E clause has no original document type at all. So the clause step picker only sets a hidden default.

Fix:
1. When the verification view shows "Súbory v kontajneri" (any `.asicEMultiple`, including a single image), replace the clause step picker with a read-only row: "Druh dokumentu: podľa súborov (Osvedčenie, Zmluva, …)" plus a button "Upraviť v overení" that goes back to verification.
2. A file without its own value keeps the explicit default "Iný dokument". Write it into `originalDocumentTypeLabels` when the file list is built, so the fallback disappears.
3. The checklist item "Druh dokumentu vyplnený" checks every file's label for multi-file originals.
4. For one PDF or one container PDF, keep today's single picker. The help text should say the type goes only into the record ("Druh pôvodného dokumentu sa zapíše do záznamu, nie do doložky.").
5. Tests: `E2EFormModel` built after editing per-file labels carries them, and the clause step no longer writes `originalDocumentTypeLabel` for multi-file originals.

## F5: Blank preview for a container without a PDF

Cause: `ZakoE2EFlow.swift:80` builds `document` only from `%PDF` bytes or `ASiCEContainerVerifier.extractPDFData`. A PNG/JPEG-only container leaves it nil, and `ZakoVerificationView` shows `PDFKitPreview` only when `store.document` exists.

Fix:
1. Build a preview `PDFDocument` from the data objects in order: PDFs as they are, images as one page each via `PDFPage(image:)`. Preview only, never used for the conversion; the real new document stays `PdfaFromSigned --merge`.
2. Alternatively show the first file and switch preview when a row in "Súbory v kontajneri" is selected.
3. Test: a fixture container with one PNG yields a non-nil preview with one page.

## F6: Default new document name

Seen: "E1-eid-podpisane" for one PDF, "E4-png-xades.pdf" for a container.

Cause: `ZakoE2EFlow.swift:86` sets the stem, and only `.asicEMultiple` gets ".pdf" (`:94`).

Fix:
1. Set `stem + ".pdf"` for every E→E original. The delivered name already goes through `ConversionOutputNaming.containerDocumentName`, which ensures ".pdf", so the clause preview and the field agree with the file.
2. Check that the clause, the record `NewDocumentName` and the delivered file still match (`ZakoSinglePDFDelivery.fixedTarget`).
3. Test: after intake of a single PDF, `newDocumentName` ends in ".pdf".

## F7: Phone button under the 1. 1. 2027 order (P→E)

Cause: `AuthorizeDoneViews.swift:395` disables the button for single PDF (`mobileRefusalForClientOutput`) but not for the expected `.recordFirst` regime. The refusal comes from `ZakoSessionStore.swift:1481` only after the click.

Fix:
1. Extend `mobileRefusalForClientOutput`, or add `mobileRefusal`, to return `recordFirstMobileMessage` when `ZakoRegime.resolve(conversionTime: Date(), mode:, preview:)` is `.recordFirst`.
2. The button is then disabled with that help text, as for one PDF. Keep the refusal in `authorizeAndSign`.
3. Test: with preview on, `mobileRefusal` is the 2027 message.

## F8: EZZK signed out is not shown before the card

Seen: Testovacia evidencia, account "Neprihlásené", yet the checklist was all green apart from the card items and "Autorizovať konverziu" was active.

Cause: neither `e2eChecklistItems` nor the P→E checklist reads `EZZKAccountController.state`. The number is requested after the MQC and PIN, so a signed-out account fails only after the advocate typed the PIN.

Fix:
1. Outside Demo, add a checklist item "Prihlásenie do EZZK" (green for `.signedIn`).
2. Make `canBeginAuthorization` false when the account is not signed in, with a notice "Prihláste sa do EZZK v Nastaveniach (EZZK)." plus a button that opens the EZZK pane (`OpenSettingsButton`, `SettingsPane.ezzk`).
3. Leave the existing EZZK error mapping as the last line of defence.
4. Tests for both directions (P→E and E→E) with `MemoryCredentialStore`.

## F9: "(testovacia evidencia)" in Demo

Cause: `AuthorizeDoneViews.swift:125` hardcodes the suffix.

Fix: use `EZZKMode.label` for the current mode, giving "(Skúšobný režim (lokálne))", or a shorter wording such as "Overenie aplikáciou Chevron7 (mimo ostrej evidencie)".

## Retest on the Mac Studio with the SAK card (still open from the test plan)

These steps were never run because they need the SAK card with the mandate certificate. They should run after the fixes above:

1. P→E with `A-sken.pdf`, "Jeden PDF s doložkou", Demo and Testovacia evidencia:
   - one .pdf next to the source;
   - a valid PAdES signature and the attachment `<číslo>.xml.xdcf`;
   - readable clause pages and the outline item "Osvedčovacia doložka";
   - in the Register, "SHA-256 prvej revízie (prvých N bajtov)".
2. Create B1 (PAdES), B2 (B1 signed again), B3 (batch, ASiC-E, one shared container with two PDFs) and B4 (ASiC-E with PDF + `B4-obrazok.png`, if the batch accepts images) from `~/Desktop/chevron7-test/B-zdroj-*.pdf`. Then E→E with each:
   - doložka E→E 1.3 and záznam E→E 1.0;
   - `-1`/`-2` originals for B2;
   - reorder and per-file "Druh dokumentu" for B3, with one outline item per file in that order;
   - B4 image on A4, not enlarged, upright.
3. "Postup od 1. 1. 2027 vopred" on, Testovacia evidencia, E→E with B1 and B3:
   - the record 1.2 is signed and sent first;
   - the app polls every 30 s until processed;
   - then the client output is signed with clause 1.3.
4. **DSId question:** does Testovacia evidencia accept record E→E 1.2 without `DSId`? If refused, copy the code and EZZK's text from the Register row.
5. During the wait, press "Zastaviť čakanie", then "Dokončiť konverziu". The conversion must continue without a new number and without a new record signature.
6. P→E with `A-sken.pdf` under the new order (record 1.2, clause 1.3), and the same combined with "Jeden PDF s doložkou".
7. Turn "Postup od 1. 1. 2027 vopred" off afterwards. Never switch to Ostrá evidencia for any of this.

The test files and the substitute signed files (E1 to E4, R1 to R3) are listed in the results file.
