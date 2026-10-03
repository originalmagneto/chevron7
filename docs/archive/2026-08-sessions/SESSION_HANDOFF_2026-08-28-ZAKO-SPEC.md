# Odovzdanie sedenia - ZaKo externé požiadavky a implementačný plán

## Kde to začalo

Používateľ dodal tri pracovné podklady z `/Users/Magneto/Downloads` k zaručenej konverzii pre advokátov a požiadal o porovnanie s aktuálnou implementáciou, zaevidovanie špecifikácie v projekte, implementačný plán a handoff.

Režim: TECH.

## Rozhodnuté + čo je hotové

- Prečítané a porovnané tri dodané podklady:
  - `/Users/Magneto/Downloads/Štandardy formátu PDF_A-1a pre zaručenú konverziu dokumentov.md`
  - `/Users/Magneto/Downloads/Štandardy formátu PDF_A-1a pri zaručenej konverzii dokumentov.md`
  - `/Users/Magneto/Downloads/Manuál pre vývoj aplikácie na zaručenú konverziu pre advokátov.md`
- Prečítaná aktuálna ZaKo implementácia, XML/PDF/A/EZZK/evidence vrstvy a existujúce projektové špecifikácie.
- Zistený kritický konflikt: dodané podklady uvádzajú PDF/A-1a alebo PNG, aktuálna aplikácia generuje a validuje PDF/A-2b a XML codelist 53 zapisuje `PDFA2`.
- Zistený kritický integračný rozdiel: aktuálny EZZK provider je Mock plus best-effort JSON HTTP kostra; oficiálny produkčný kontrakt, autentizácia a sandbox acceptance nie sú v repozitári potvrdené.
- Zistená verzovacia medzera: generátor doložky má hardcoded P -> E namespace/form version 1.0, pričom podklady oddeľujú verzie záznamu a doložky a opisujú budúcu zmenu.
- Zistená bezpečnostná medzera: samostatné overenie cudzích vstupných podpisov a najstaršej platnej časovej pečiatky nie je hard gate v ZaKo flow.
- Pripravený register požiadaviek, rozhodnutí, porovnanie a akceptačné gates v:
  - `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/docs/ZAKO_EXTERNAL_REQUIREMENTS_SPEC_2026-08-28.md`
- Pripravený fázový implementačný plán v:
  - `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/docs/superpowers/plans/2026-08-28-zako-external-requirements.md`
- Aktualizované projektové odkazy a caveat v README a PHASES.
- Fáza 0 uzavretá ako discovery gate bez dostupného autoritatívneho XSD/XSLT/EZZK kontraktu.
- Implementovaná bezpečná časť Fázy 1: immutable `ConversionFormPack`, effective-date repository,
  explicitné pilotné `unverified/unknown` stavy, pack-aware XML API a `FormPackStamp` v envelope/evidencii.

## Kľúčové súbory pre ďalšie sedenie

- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/docs/ZAKO_EXTERNAL_REQUIREMENTS_SPEC_2026-08-28.md`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/docs/superpowers/plans/2026-08-28-zako-external-requirements.md`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramApp/ZakoSessionStore.swift`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramKit/Attestation/AttestationClauseGenerator.swift`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramKit/Attestation/AttestationXMLValidator.swift`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramKit/PDFA/PDFAConverter.swift`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramKit/PDFA/PDFAValidator.swift`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramKit/EZZK/EZZKService.swift`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramKit/Evidence/LocalEvidenceStore.swift`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramKit/Attestation/FormPack.swift`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Tests/AutogramKitTests/FormPackTests.swift`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/docs/SESSION_HANDOFF_2026-08-28.md`

## Running state

none. No server or background process was started in this continuation. Active branch is `main`.

The following pre-existing uncommitted change must be preserved:

- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramKit/VisionAI/BuiltInVisionProvider.swift`

It belongs to the earlier detector work and was not rewritten by this documentation task.

## Verifikácia

The documentation changes were checked for expected files, links, absence of em dashes in the new documents, and a cleanly scoped diff. The full suite should be run before the first code change:

```bash
cd "/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build_app.sh
```

Expected baseline from the prior session: 107 tests executed, 3 live engine tests skipped, 0 failures, packaged build passed. A fresh full-suite attempt in this continuation started normally and showed passing suites, but stopped during `PDFAConverterTests` without an exit marker, so the current full-suite result is inconclusive. The focused detector suite completed successfully: `swift test --filter SecurityElementsDetectorTests` -> 5 tests, 0 failures. This continuation did not alter runtime code.

## Odložené + otvorené otázky

1. Je pre P -> E autoritatívne povinný PDF/A-1a, alebo je akceptovaný PDF/A-2b či PNG v konkrétnom profile?
2. Aké sú presné aktuálne verzie záznamu a doložky, ich namespace, XSD, XSLT a codelists?
3. Aký je aktuálny EZZK transport, autentizácia, sandbox a idempotency contract?
4. Od akej udalosti sa počíta 24-hodinová lehota a aké presné serverové potvrdenie sa eviduje?
5. Aký OID alebo certifikátový profil je autoritatívny pre mandátny certifikát?
6. Aký je povinný rozsah overenia cudzích podpisov a časových pečiatok na vstupe?
7. Má byť vizuálna doložka iba preview/tlačivo, alebo súčasť finálneho elektronického artefaktu?
8. Zostane lokálna JSON evidencia MVP storage, alebo sa vyžaduje migračný návrh na SQLite/Core Data?
9. Ktoré právne formulácie v README a existujúcej špecifikácii schváli právnik?

## Pokračuj tu

Fáza 0 je uzavretá ako discovery gate bez externého kontraktu. Pokračuj v Fáze 1 vložením autoritatívnych artefaktov do `ConversionFormPack` a následne v nezávislom overení output profilu. PDF/A-1a, codelist 53 a produkčný EZZK transport nemeň bez autoritatívneho potvrdenia a externého validačného testu.