# Testy Chevron7 1.20.0 (MacBook Air, Mac17,3, macOS 27.0.1)

Aplikácia: /Applications/Chevron7.app 1.20.0 (notarizovaná, main 96c00a81). Začiatok: 19. 11. 2026.

## Testovacie súbory (~/Desktop/chevron7-test/)

Všetky sú syntetické ukážky z `.impeccable/zako/` (žiadne osobné údaje klientov).

| Súbor | Obsah |
|---|---|
| A-sken.pdf | 3 strany A4, syntetický sken (scan-1, scan-2, scan-1), PDFKit |
| B-zdroj-listina.pdf, B-zdroj-zapisnica.pdf | nepodpísané zdroje pre B1 až B3 |
| B4-obrazok.png | syntetický sken ako obrázok pre B4 |

## Stav pred testom

- Nastavenia > Prehliadač a Finder: "Prepojenie so Safari je zapnuté", "Rozšírenie Chevron7 je v Safari zapnuté" (OK).
- Nastavenia > EZZK: pripojené, prostredie bolo **Ostrá evidencia**, odosielanie zapnuté.
- Karta: "Karta nepripojená".

## Výsledky

| # | Test | Režim | Súbor | Ev. číslo | Register / EZZK | Výsledok | Text chyby |
|---|---|---|---|---|---|---|---|
| 1c | Jedno PDF zablokované v Ostrej evidencii | Ostrá evidencia (len pohľad) | A-sken.pdf | žiadne (nič nespustené) | žiadny riadok | OK | Voľba "Jeden PDF s doložkou" je sivá a klik ju nevyberie. Pod ňou: "Výstup ako jeden PDF s doložkou Chevron7 v ostrej evidencii zatiaľ nevykonáva: najprv sa overuje v testovacej evidencii. Zvoľte kontajner ASiC-E alebo testovaciu evidenciu." |

### Kolo 1: Skúšobný režim (lokálne) (Demo)

- Prepnuté z Ostrej evidencie na "Skúšobný režim (lokálne)" v Nastavenia > EZZK (rozšírené). V Demo sa objavila sekcia "Zaručená konverzia od 1. 1. 2027" s prepínačom "Postup od 1. 1. 2027 vopred" (vypnutý); v Ostrej evidencii sa nezobrazuje.
- Test 1 (P→E, A-sken.pdf, jedno PDF): analýza 3 strán, 6 pečiatok potvrdených, strany skontrolované. V autorizácii "Jeden PDF s doložkou" je v Demo voliteľný, s vysvetlením (§ 37 ods. 4 zákona 305/2013, § 2 ods. 3 vyhl. 70/2021); "Autorizovať mobilom" sa pri jednom PDF zašedí (OK). Po "Autorizovať konverziu": dialóg "Vložte kartu s mandátnym certifikátom ... Čakám na kartu..." -> čaká sa na kartu SAK a PIN od používateľa.

**Zmena plánu (19. 11.):** karta SAK nie je k dispozícii, eID ani telefón ZaKo autorizovať nemôžu (kód: `noMandateMessage` v `ZakoMandateCardFlow.swift:157`, telefón `AVMResultMapper.isMandate` v `ZakoSessionStore.swift:1775`). Preto sa netestuje nič, čo podpisuje výstup alebo záznam (krok 1, autorizácia v kroku 2, krok 3 okrem hlášok a prepínača, otázka DSId). B1 až B4 sa nevytvárali; namiesto nich:

| Súbor | Pôvod |
|---|---|
| E1-eid-podpisane.pdf | `.impeccable/zako/Ukazkova_zapisnica_podpisane.pdf` (PAdES, eID, 6. 10. 2026) |
| E2-eid-jedno-pdf.asice | `.impeccable/zako/Ukazkova_zapisnica_podpisane.asice` (XAdES ASiC-E, 1 PDF, eID) |
| E3-sample-signed.pdf | engine fixture `sample_signed.pdf` (PAdES, certifikát exspirovaný) |
| E4-png-xades.asice | engine fixture `sample_png_xades.asice` (ASiC-E s PNG) |
| R1-nepodpisane.pdf | engine fixture `sample.pdf` (nepodpísané) |
| R2-xml.asice | engine fixture `FUPS_signed.asice` (ASiC-E s XDC/XML) |
| R3-cades.asice | engine fixture `sample_pdf_cades.asice` (ASiC-E, CAdES) |

| # | Test | Režim | Súbor | Ev. číslo | Register / EZZK | Výsledok | Text |
|---|---|---|---|---|---|---|---|
| 1a | P→E jedno PDF, voľba v autorizácii | Demo | A-sken.pdf | nepridelené | žiadny riadok | OK (len UI) | "Jeden PDF s doložkou" voliteľný; "Autorizovať mobilom" pri ňom zašedený. Autorizácia nespustená (chýba karta SAK). |
| 3a | Prepínač "Postup od 1. 1. 2027 vopred" | Demo | - | - | - | OK | Zobrazuje sa v Demo, v Ostrej evidencii nie. Popis: "Od 1. 1. 2027 Chevron7 najprv podpíše a odošle záznam o konverzii (formulár 1.2), počká, kým ho EZZK spracuje, a až potom podpíše doložku s dokumentom. Tento prepínač tento postup zapne už teraz, iba v skúšobnom režime a v testovacej evidencii; v ostrej evidencii sa neuplatní." |
| 3b | Mobil v novom postupe (P→E, ASiC-E) | Demo, postup 2027 | A-sken.pdf | nepridelené | žiadny riadok | OK | "Konverziu sa nepodarilo autorizovať. Od 1. 1. 2027 sa najprv podpisuje záznam o konverzii, a ten mobil podpísať nevie. Autorizujte kartou." Poznámka (UX): tlačidlo "Autorizovať mobilom" je v novom postupe aktívne, hláška príde až po kliknutí; pri jednom PDF je tlačidlo zašedené. |
| 2a | E→E overenie jedného PAdES PDF (náhrada B1) | Demo, postup 2027 | E1-eid-podpisane.pdf | nepridelené | žiadny riadok | OK (po autorizáciu) | Overenie: "Podpis klienta je platný"; Marián Čuprík, KEP, podpísané 6. 10. 2026 19:44:58, "Časová pečiatka kvalifikovaná, platná: NASES Time Stamp Authority 2". "PDF nie je platné PDF/A, preto vznikne nový PDF/A-2b." Doložka § 35 ods. 1 písm. c), druh "Iný dokument". V autorizácii nie je tlačidlo mobilu, ponuka ASiC-E aj "Jeden PDF s doložkou". Poznámka: predvolený "Názov nového dokumentu" je "E1-eid-podpisane" bez ".pdf"; v kontrolnom zozname je riadok "Overenie aplikáciou Chevron7 (testovacia evidencia)" aj v Demo. Doložka 1.3 / záznam 1.2 sa bez podpisu nedajú overiť. |
| 2e1 | Odmietnutie nepodpísaného PDF | Demo, postup 2027 | R1-nepodpisane.pdf | nepridelené | žiadny riadok | OK | Hneď pri overení: "Podpisy sa nepodarilo overiť. Dokument nie je podpísaný. Zaručenú konverziu elektronického dokumentu Chevron7 zatiaľ vykoná len pre dokument, ktorý klient autorizoval." "Pokračovať na doložku" zašedené. |
| 2e2 | Odmietnutie ASiC-E s XML | Demo, postup 2027 | R2-xml.asice (FUPS.xdcf) | nepridelené | žiadny riadok | OK | Hneď pri overení: "Podpisy sa nepodarilo overiť. Súbor FUPS.xdcf nie je PDF ani obrázok PNG alebo JPEG. Chevron7 ho do nového dokumentu nevie zahrnúť." "Pokračovať na doložku" zašedené. |
| 2e3 | ASiC-E s CAdES podpisom (testovací certifikát) | Demo, postup 2027 | R3-cades.asice | nepridelené | žiadny riadok | Pozorovanie | Nie je odmietnuté (CLAUDE.md spomína odmietnutie len pre "detached CAdES"). Overenie: "Platnosť niektorého podpisu sa nedá zistiť. Podpis Jano Suchal sa nepodarilo overiť: The certificate chain for signature is not trusted, it does not contain a trust anchor.. Do doložky aj záznamu sa zapíše „nie je možné zistiť“." + potvrdenie "Pokračovať aj tak". Kvalifikácia "Kvalifikácia podpisu sa nedala určiť (DSS: NA)". Nálezy: (1) anglický text z DSS v slovenskej hláške a dve bodky "anchor.."; (2) odmietnutie kvalifikácie NA (`e2eUndeterminedQualificationMessage`) sa pri overení ani v autorizácii neukáže, "Autorizovať konverziu" najprv pýta kartu SAK; bez karty sa nedá overiť, či príde pred pridelením čísla. (3) Dialóg "Vložte kartu s mandátnym certifikátom" sa po kliknutí na "Autorizovať konverziu" objaví až asi po 10 s, dovtedy tlačidlo nijako nereaguje (žiadny indikátor). |
| 2b | E→E ASiC-E s jedným PNG | Demo, postup 2027 | E4-png-xades.asice | nepridelené | žiadny riadok | Čiastočne OK | Sekcia "Súbory v kontajneri" sa zobrazí ("V tomto poradí sa súbory spoja do nového dokumentu a v tomto poradí ich uvedie doložka aj záznam."), sample.png "PNG · Obrázok", "Podpis kontajnera: Jano Suchal", "Druh dokumentu" s ponukou Zmluva, Plná moc, Rozsudok, Osvedčenie, Rozhodnutie, Iný dokument; zvolené "Osvedčenie" ostalo po návrate späť. Názov nového dokumentu "E4-png-xades.pdf". Pozorovania: (1) náhľad vľavo je pri PNG prázdny; (2) v kroku doložky je ďalší výber "Druh dokumentu: Iný dokument" pre celý kontajner, nezávislý od druhu zvoleného pri súbore; nie je jasné, ktorý platí (podľa CLAUDE.md doložka E→E druh originálu nemá, záznam berie druh pri súbore). Umiestnenie obrázka na A4 sa nedá overiť: nový dokument (`PdfaFromSigned --merge`) vzniká až pri autorizácii, v Caches ani TMPDIR nevznikol žiadny PDF. |
| 2c | E→E ASiC-E s jedným PDF (eID) | Demo, postup 2027 | E2-eid-jedno-pdf.asice | nepridelené | žiadny riadok | OK (po overenie) | "Podpis klienta je platný", Marián Čuprík, KEP, NASES TSA 2. Pri jednom PDF sa "Súbory v kontajneri" nezobrazuje. |
| 2d | E→E PAdES s exspirovaným testovacím certifikátom | Demo, postup 2027 | E3-sample-signed.pdf | nepridelené | žiadny riadok | OK (pozorovanie ako 2e3) | "nie je možné zistiť" + "Pokračovať aj tak", kvalifikácia "DSS: NA". |
| 2f | Register po teste v Demo | Demo | - | - | iba 2 staré riadky (1563-260924-2, 1563-260924-1 DEMO), žiadny nový | OK | Žiadna z odmietnutých ani prerušených konverzií nezanechala riadok. |
| 3c | Testovacia evidencia: nastavenia | Testovacia evidencia | - | - | - | OK | Účet "Neprihlásené" (heslo nezadané). Sekcia "Zaručená konverzia od 1. 1. 2027" sa zobrazuje, prepínač zostal zapnutý z Demo. |
| 3d | Testovacia evidencia: autorizácia E→E | Testovacia evidencia, postup 2027 | E3-sample-signed.pdf | nepridelené | žiadny riadok | OK (len UI) | "Jeden PDF s doložkou" voliteľný; prepínač QTS skrytý (mimo Demo vždy kvalifikovaná); hláška "Zaručenú konverziu s EZZK podpisujte kartou SAK. Podpis z mobilu je zatiaľ dostupný iba v skúšobnom režime EZZK (lokálne, bez zápisu do evidencie)." Pozorovanie: kontrolný zoznam neupozorní, že EZZK účet je neprihlásený; "Autorizovať konverziu" je aktívne. |
| 3e | Vypnutie "Postup od 1. 1. 2027 vopred" | Testovacia evidencia | - | - | - | OK | Vypnuté na konci testu. |

## Čo sa netestovalo (chýba karta SAK s mandátnym certifikátom)

- Krok 1: vznik jedného PDF, PAdES, príloha `<číslo>.xml.xdcf`, strany doložky, záložka, odtlačok "SHA-256 prvej revízie" v Registri.
- Krok 2: autorizácia B1 až B4 (doložka E→E 1.3, záznam E→E 1.0), originály `-1`/`-2` pri dvoch revíziách (B2 nevznikol), poradie a záložky viacerých súborov (B3 nevznikol), umiestnenie obrázka na A4 (B4).
- Krok 3: podpis a odoslanie záznamu 1.2, čakanie v EZZK, "Zastaviť čakanie" / "Dokončiť konverziu", kombinácia s jedným PDF.
- **Otázka DSId zostáva otvorená**: či Testovacia evidencia prijme záznam E→E 1.2 bez DSId, sa dá zistiť iba odoslaním podpísaného záznamu.

## Stav aplikácie po teste

- EZZK prostredie: **Testovacia evidencia** (pred testom Ostrá evidencia; späť som neprepínal, podľa pravidiel).
- "Postup od 1. 1. 2027 vopred": vypnutý. "Rozšírené nastavenia": zapnuté (v Nastaveniach).
- V ZaKo je otvorená autorizácia E3-sample-signed.pdf (nič nespustené).
