# ZaKo and register UI clarity (2026-11-20)

## Why

E→E, the record-first order of 1. 1. 2027, the one-PDF output and the background wait for EZZK were added to screens designed for the first P→E flow. In the card test of 2026-11-20 (conversion 261120-Wg580fC029) the advocate could not see at a glance where the conversion stood, which EZZK environment it ran in, or what came next. The owner approved all items below on 2026-11-20 (critique in the session of that day, 23/40 on Nielsen's heuristics), with the waiting step kept as a full screen showing a timeline.

## Goals

- The EZZK environment is visible wherever a conversion is shown, so a test conversion (no legal effect) is never mistaken for a real one.
- The ZaKo flow shows its steps and its settings (order, output, environment) on screen, not only in the window subtitle and in Settings.
- The authorize step leads with what is still missing, refuses a card without a mandate before the card check, and never shows a stale error.
- The waiting and done steps tell what happened, when, and what comes next.
- The register shows direction, output and environment, and lets a pending conversion be finished from its row.
- One signature row design across signing, E→E verification and the register.
- Readable clause pages in the one-PDF output.

## Non-goals and anti-goals

- No change to legal content: clause and record XML, the official XSLT text, signatures, EZZK calls, gates and policies stay as they are. The official form's own defects (the reference to the repealed decree 331/2018, the literal "true") are reported to MIRRI, not patched.
- No new visual world: native macOS controls, SF Symbols, existing `glassCard`, `StickyActionBar`, `ZakoNotice` and the Settings pill style. No decoration, no eyebrow labels, no colored side borders.
- Meaning never by color alone: every badge carries text, every state an accessibility label.

## Decisions

1. **Environment badge** (`EZZKEnvironmentBadge`): a tinted capsule with text. Demo "Skúšobný režim" (grey), Test "Testovacia evidencia" (orange), production none in lists, "Ostrá evidencia" only where the environment is the subject (ZaKo header, done step). Shown in the register's number column (replacing `DemoBadge`), in sidebar conversion rows (short form "Test" / "Skúšobný"), in the ZaKo conversion header and on the done step. The register gains an environment filter next to the status filter.
2. **ZaKo conversion header** (`ZakoConversionHeader`) above every ZaKo step after intake: the document name, a step indicator built from a step model that knows both directions and both orders (P→E today: Analýza, Doložka, Autorizácia, Hotovo; E→E today: Overenie, Doložka, Autorizácia, Hotovo; record-first adds Záznam do EZZK and Podpis doložky around the wait), and chips for the order ("Postup od 2027" only when record-first), the client output ("Kontajner ASiC-E" / "Jeden PDF") once chosen, and the environment badge. The window subtitle stays as is.
3. **Authorize step:** the checklist becomes a model (`ZakoChecklistItem` with met, title, symbol and an optional action hint). Met items fold into one row "N z M pripravené" (expandable); unmet items stay visible, each with its hint. When the inserted card is known to hold no mandate certificate (`mandateGate == .noMandate`), the authorize button is disabled and the reason "Vložte kartu s mandátnym certifikátom SAK" shows under it, so the card check never starts. `lastError` clears when the reader's card changes. The "Kontrolujem kartu…" state shows inline in the action bar instead of a sheet; PIN entry and "Vložte kartu" stay sheets.
4. **Remembered PIN:** when `signingPIN` is held and the next authorization will use it, a note under the authorize button says "Použije sa PIN zadaný pri podpise záznamu. Aplikácia ho drží do zatvorenia alebo vybratia karty." (wording may be shortened, meaning kept).
5. **Waiting and done timeline** (`ZakoConversionTimeline`): steps Záznam podpísaný (time), Odoslaný do EZZK (time), EZZK spracúva (elapsed since sending, "zvyčajne 10 až 30 minút" in Testovacia evidencia), Podpis doložky, Hotovo; the current step highlighted, done steps checked with their times. One headline, no repeated card text; the line "Môžete pracovať ďalej. Keď EZZK záznam spracuje, ozveme sa upozornením." while waiting. The done step keeps the output folder actions next to the timeline.
6. **Register columns:** Evidenčné číslo (with environment badge and overdue dot), Stav, Smer (P→E / E→E with symbol), Výstup (ASiC-E / Jeden PDF / empty for old rows), Dátum konverzie, Pôvodný dokument, Lehota EZZK. "Strany / Listy" and "SHA-256" move to the detail only. A row whose conversion waits for the clause signature shows a "Dokončiť" button in its status cell (same action as the detail footer).
7. **One signature row** (`SignatureRowView`): the banner popover row becomes the shared view; the E→E verification list renders its authorizations through it (verdict, signer, qualification, signed time, timestamps, mandate, covered file, technical detail disclosure), keeping every fact it shows today.
8. **Clause pages legibility:** the clause print injects layout CSS only (no text change) so the official form lays out at the printable width instead of being shrunk by `.fit`; target body text at least 9 pt. Verified by rendering the test clauses and by veraPDF through the existing appender tests.
9. **Smaller items:** the E→E verification step leads with a one-sentence verdict; the PDF/A note moves next to the output; the sidebar's recent-documents section gets a "Vyčistiť" action.

## Left to the builder

Exact spacing, symbols and copy within the meanings above; component file placement; test shape (pure model tests for the step model, checklist folding, timeline states and register row presentation; hosting tests only where layout is the risk, as `ZakoDoneWindowSizeTests`).
