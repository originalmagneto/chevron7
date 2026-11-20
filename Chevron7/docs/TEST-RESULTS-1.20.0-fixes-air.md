# Overenie opráv F1 až F9 (PR #106) na MacBooku Air

Dátum: 19. 11. 2026. Vetva `fix/test-1.20.0-findings`, vývojová verzia `.build/out/Products/Debug/Chevron7.app` (engine aj aplikácia zostavené z vetvy). `/Applications/Chevron7.app` sa nemenil.

Záloha nastavení: `defaults export app.slovensko.chevron7`, kópia v `~/Desktop/chevron7-test/chevron7-defaults-backup-2026-11-19.plist`.

Stav pred testom: EZZK režim Testovacia evidencia (nechaný z predchádzajúceho testu, pôvodne Ostrá evidencia), "Postup od 1. 1. 2027 vopred" vypnutý, karta nepripojená.

Testovacie súbory: `~/Desktop/chevron7-test/` (popis v `TEST-RESULTS-1.20.0-air.md`).

## Výsledky

| # | Oprava | Režim | Súbor | Čo som urobil | Čo som videl (presný text) | Výsledok |
|---|---|---|---|---|---|---|
| F6 | Názov nového dokumentu s .pdf | Testovacia evidencia | E1-eid-podpisane.pdf | E→E po krok doložky | "Názov nového dokumentu: E1-eid-podpisane.pdf" | OK |
| F4a | Jeden výber druhu pri jednom PDF | Testovacia evidencia | E1-eid-podpisane.pdf | krok doložky | "Druh dokumentu: Iný dokument" s poznámkou "Druh pôvodného dokumentu sa zapíše do záznamu, nie do doložky." | OK |
| F8a | Neprihlásený účet EZZK | Testovacia evidencia (Neprihlásené) | E1-eid-podpisane.pdf | krok autorizácie | Oranžové hlásenie "Nie ste prihlásený do EZZK. Prihláste sa do EZZK v Nastaveniach (EZZK)." a tlačidlo "Otvoriť nastavenia EZZK"; v zozname položka "Prihlásenie do EZZK" s prázdnym prerušovaným krúžkom (rovnaký štýl ako karta; nie červená); "Autorizovať konverziu" sivé. | OK (štýl položky nie je červený, ako čakal zadávateľ; zhodný so zvyškom zoznamu) |
| F8b | Otvoriť nastavenia EZZK | Testovacia evidencia | - | klik na "Otvoriť nastavenia EZZK" | Otvorí sa okno Nastavenia na paneli EZZK (Testovacia evidencia, "Neprihlásené"). | OK |
| F9a | Text overenia v Testovacej evidencii | Testovacia evidencia | E1-eid-podpisane.pdf | krok autorizácie | "Overenie aplikáciou Chevron7 (Testovacia evidencia)" | OK |
| F9b | Text overenia v Demo | Demo | E1-eid-podpisane.pdf | krok autorizácie | "Overenie aplikáciou Chevron7 (Skúšobný režim (lokálne))" | OK |
| F3a | Výzva na kartu bez karty v čítačke | Demo | E1-eid-podpisane.pdf | stlačené a podržané "Autorizovať konverziu" (1,5 s) | Hneď po uvoľnení: "Vložte kartu s mandátnym certifikátom ... Čakám na kartu..." so "Zrušiť" (rýchla cesta, "Kontrolujem kartu…" sa pri prázdnej čítačke nezobrazí). | OK |
| F3b | Zrušiť počas čakania | Demo | E1-eid-podpisane.pdf | "Zrušiť", potom 8 s čakanie | Žiadny ďalší dialóg, späť na kontrolnom zozname. Stav "Kontrolujem kartu…" sa bez karty v čítačke vyvolať nedá, takže zrušenie počas samotnej kontroly sa netestovalo. | OK (čiastočne) |
| F3c | Poznámka k pôvodnému nálezu F3 | - | - | - | "Autorizovať konverziu" je `HoldToConfirmButton` (podržať 1 s). Obyčajný klik myšou nerobí nič, a to je zámer; v prvom teste som tlačidlo len klikal. Oneskorenie ~10 s pri AX stlačení v 1.20.0 platilo. | Info |
| F1a | Slovenský dôvod, jedna bodka | Demo, postup 2027 vypnutý | R3-cades.asice | E→E overenie | "Platnosť niektorého podpisu sa nedá zistiť. Podpis Jano Suchal sa nepodarilo overiť: reťazec certifikátov nevedie k dôveryhodnej autorite. Do doložky aj záznamu sa zapíše „nie je možné zistiť“." Bez angličtiny, bez "..". | OK |
| F1b | Technický detail | Demo | R3-cades.asice | rozbalenie pri podpise | "Technický detail" rozbalí "The certificate chain for signature is not trusted, it does not contain a trust anchor." Drobnosť: rozbalí sa len klikom na šípku, klik na text "Technický detail" nič nerobí. | OK (drobnosť) |
| F2a | Blokovanie pri postupe 2027 | Demo, postup 2027 zapnutý | R3-cades.asice | zapnutý prepínač pri otvorenom overení | Hlásenie sa zmení hneď (bez nového overenia): červené "Konverziu nemožno vykonať postupom od 1. 1. 2027. Kvalifikáciu podpisu Jano Suchal sa nepodarilo určiť. Podľa postupu od 1. 1. 2027 ho nemožno zapísať do záznamu. Skúste overenie znova."; "Pokračovať aj tak" zmizne; "Pokračovať na doložku" sivé. Poznámka: "Skúste overenie znova" pri testovacom certifikáte nepomôže (kvalifikácia NA sa opakovaním nezmení); možno doplniť "alebo použite pôvodný postup". | OK |
| F2b | Po vypnutí prepínača | Demo, postup 2027 vypnutý | R3-cades.asice | vypnutý prepínač | Späť oranžové hlásenie z F1a a "Pokračovať aj tak..."; "Pokračovať na doložku" sivé až do potvrdenia. | OK |
| F1c | Slovenský dôvod pri PAdES | Demo | E3-sample-signed.pdf | E→E overenie | Rovnaké slovenské hlásenie ako F1a, "Technický detail" pri podpise. | OK |
| F5 | Náhľad kontajnera bez PDF | Demo | E4-png-xades.asice | E→E overenie | Vľavo sa zobrazí obrázok sample.png (obsah fixtúry je snímka okna Autogramu), nie prázdna plocha. | OK |
| F4b | Druh pri súbore a v doložke | Demo, postup 2027 vypnutý | E4-png-xades.asice | "Súbory v kontajneri": predvyplnené "Iný dokument" -> "Osvedčenie"; "Pokračovať aj tak"; krok doložky; "Upraviť v overení" | Krok doložky: "Druh dokumentu: podľa súborov (Osvedčenie)" + tlačidlo "Upraviť v overení"; druhý nezávislý výber nie je. "Upraviť v overení" vráti na overenie, "Osvedčenie" aj potvrdenie "nie je možné zistiť" zostanú (riadok "Potvrdené: do doložky aj záznamu sa zapíše „nie je možné zistiť“."). | OK |
| F4c | "Druh nového dokumentu" pri postupe 2027 | Demo, postup 2027 | E4-png-xades.asice | - | Netestovateľné bez platného viacsúborového kontajnera: E4 má testovací podpis s kvalifikáciou NA, ktorý postup 2027 správne zablokuje (F2) ešte pred krokom doložky. Treba B3 alebo B4 s kartou. | Netestované |
| F7 | Mobil pri postupe 2027 (P→E) | Demo | A-sken.pdf | analýza, 3 strany skontrolované, 6 pečiatok potvrdených, autorizácia s výstupom "Kontajner ASiC-E"; prepínač 2027 vypnutý, potom zapnutý | Pri vypnutom: "Autorizovať mobilom" aktívne. Po zapnutí: tlačidlo hneď sivé. Nastavenie mobilu som nemenil. Nález (drobný): dôvod sa nedá prečítať, lebo macOS pri neaktívnom tlačidle bublinu `.help` nezobrazí (podržanie kurzora 3 s bez bubliny); text je len v `.help` a `accessibilityHint` (`recordFirstMobileMessage`, `ZakoSessionStore.swift:211`). Návrh: dôvod ukázať ako riadok pod tlačidlami alebo v karte certifikátu, ako pri jednom PDF. | OK (dôvod neviditeľný) |
| F8c | Neprihlásený účet pri P→E | Testovacia evidencia (Neprihlásené), postup 2027 zapnutý | A-sken.pdf | prepnutie Demo -> Testovacia evidencia na otvorenej autorizácii | Hneď sa objaví "Nie ste prihlásený do EZZK. Prihláste sa do EZZK v Nastaveniach (EZZK)." + "Otvoriť nastavenia EZZK", položka "Prihlásenie do EZZK" nesplnená, "Autorizovať konverziu" sivé. Tlačidlo mobilu sa v Testovacej evidencii nezobrazuje (mobil len v Demo). | OK |
| F8d | Položka zozelenie po prihlásení | Testovacia evidencia | - | Používateľ sa dvakrát prihlasoval v Nastaveniach vývojovej verzie | Prihlásenie sa neuložilo: panel EZZK ostal "Neprihlásené" s prázdnymi poľami, v Keychaine nepribudla položka `app.slovensko.chevron7.ezzk.soap` (jediná má dátum 24. 9. 2026). Po druhom pokuse bol režim EZZK "Skúšobný režim (lokálne)" namiesto Testovacej evidencie; nezistil som, či ho prepol používateľ, alebo ho aplikácia vrátila po neúspešnom prihlásení (EZZKConnection vracia predchádzajúci režim pri zlyhaní). Text chyby pri prihlásení nemám. Treba zopakovať a zapísať hlášku. | Neoverené |

## Netestované

- Karta SAK nebola k dispozícii: celá časť "Retest on the Mac Studio with the SAK card" (kroky 1 až 7) vrátane otázky DSId.
- F3: stav "Kontrolujem kartu…" a "Zrušiť" počas neho (vyžaduje kartu v čítačke, inak rýchla cesta rovno na "Vložte kartu").
- F4: "Druh nového dokumentu" pri postupe 2027 (vyžaduje platný viacsúborový kontajner, B3 alebo B4).
- F8: zelená položka "Prihlásenie do EZZK" po prihlásení (pozri F8d).

## Nálezy na zváženie (neopravené, žiadny nie je jasná malá chyba)

1. F7: dôvod sivého "Autorizovať mobilom" je len v `.help`, ktorú macOS pri neaktívnom tlačidle nezobrazí. Ukázať ho ako text pod tlačidlami.
2. F1: "Technický detail" sa rozbalí len šípkou, nie klikom na text.
3. F2: "Skúste overenie znova" pri kvalifikácii NA nepomôže; zvážiť dodatok o pôvodnom postupe.
4. F8: nesplnená položka "Prihlásenie do EZZK" má rovnaký sivý prerušovaný krúžok ako ostatné, nie červenú farbu (hlásenie nad zoznamom je oranžové).
5. F8d: prihlásenie do Testovacej evidencie vo vývojovej verzii sa neuložilo a režim sa prepol na Demo; treba zopakovať s presnou hláškou.

## Stav po teste

- Vývojová verzia ukončená. `/Applications/Chevron7.app` nezmenený.
- EZZK režim: **Skúšobný režim (lokálne)** (nastavenia zdieľa s nainštalovanou verziou). Pred prvým testom bola Ostrá evidencia; späť neprepínané.
- "Postup od 1. 1. 2027 vopred": vypnutý.
- Register: žiadny nový riadok (nič sa neautorizovalo).

## Vyšetrenie F8d: prihlásenie do Testovacej evidencie (19. 11. 2026, kód, bez Keychainu a bez hesla)

**a) Kedy sa vracia predchádzajúci režim.** Iba v `EZZKConnection.connect`. Ten patrí tlačidlu „Pripojiť k EZZK“, ktoré sa ukazuje v Skúšobnom režime a v neprihlásenej Ostrej evidencii, a výberu „Ostrá evidencia“ v rozšírenom nastavení. Postup:
- prepne do Ostrej evidencie (po potvrdení „Pripojiť k ostrej evidencii EZZK?“);
- prihlási sa;
- pri neúspechu vráti režim, ktorý bol predtým.

„Prihlásiť a overiť“ v Testovacej evidencii (`signInInCurrentMode`, `EZZKAccountController.signIn`) režim nemení nikdy. Návrat do Skúšobného režimu po druhom pokuse teda zodpovedá tomuto postupu:
1. pokus bol spustený v Skúšobnom režime cez „Pripojiť k EZZK“ (prihlásenie do **Ostrej** evidencie);
2. testovacie údaje Ostrá evidencia odmietla;
3. aplikácia vrátila Skúšobný režim, ako má.

V Testovacej evidencii treba použiť „Prihlásiť a overiť“. Tlačidlo sa ukáže až po výbere „Testovacia evidencia“ v časti „Prostredie EZZK“.

**b) Či sa chyba vždy ukáže.**
- Zlyhané prihlásenie áno: `state = .failed` alebo `connectError`, pod poľami ako `InlineError` a v hlavičke ako „Prihlásenie zlyhalo“.
- Chyba pri **čítaní** Keychainu nie. `reloadStoredLogin` (pri spustení a pri zmene režimu) ju zahadzovala cez `try?` a panel ukázal len „Neprihlásené“ s prázdnymi poľami. **Opravené:** teraz sa ukáže „Bezpečné úložisko (Keychain) nie je dostupné (kód N).“ (test `testUnreadableKeychainIsShownNotSwallowed`).

**c) Ad hoc podpis a Keychain.**
- Údaje EZZK sú v bežnom (súborovom) Keychaine, bez skupiny prístupu a bez data protection keychainu. Ad hoc build teda novú položku zapísať môže.
- Existujúca položka `app.slovensko.chevron7.ezzk.soap` (z 24. 9. 2026, vytvorená notarizovanou aplikáciou) má v ACL notarizovaný Chevron7. Ad hoc build má iný určený požiadavok (cdhash, ktorý sa mení s každým buildom), takže pri čítaní alebo prepise tej položky macOS buď zobrazí výzvu na prístup, alebo vráti chybu. Ak táto položka patrí účtu `test`, vývojová verzia ju nevie prečítať ani prepísať, kým prístup nepovolíš.
- Pred opravou z bodu b) to vyzeralo presne ako „Neprihlásené“ s prázdnymi poľami.

**Návrh na preskúšanie (MacBook Air):**
1. Spusti vývojovú verziu z tejto vetvy. Nastavenia > EZZK > Rozšírené > Prostredie: „Testovacia evidencia“.
2. Ak sa hneď ukáže „Bezpečné úložisko (Keychain) nie je dostupné (kód N)“, zapíš kód. Bod c) je potom potvrdený.
3. Zadaj meno a heslo a stlač **„Prihlásiť a overiť“** (nie „Pripojiť k EZZK“).
   - Ak macOS ukáže výzvu na prístup ku Keychainu pre Chevron7, zvoľ „Povoliť“. „Vždy povoliť“ platí len pre tento konkrétny build.
4. Zapíš presnú hlášku pod poľami.
5. Na porovnanie urob to isté v notarizovanej `/Applications/Chevron7.app` 1.20.0.

## Preskúšanie na Mac Studiu s kartou SAK (19. 11. 2026, vývojová verzia z vetvy, Testovacia evidencia)

Karta I.CA s mandátnym certifikátom „Marián Čuprík OPRÁVNENIE 1042“. PIN zadával advokát. Ostrá evidencia sa nepoužila, aplikáciu prepol do Testovacej evidencie advokát sám.

**Prihlásenie (F8d):** vývojová (ad hoc) verzia na Mac Studiu prečítala uložené prihlásenie z Keychainu bez výzvy a prihlásenie do Testovacej evidencie prešlo. Problém z MacBooku Air sa tu neprejavil.

**Test 1: P→E, `A-sken.pdf`, Jeden PDF s doložkou, dnešný postup** (číslo 261119-beA3601438). Prešiel:
- `A-sken-konvertovane.pdf` vedľa zdroja, 8 strán, 3 revízie, PDF/A-3B v XMP;
- jeden podpis PAdES (`ETSI.CAdES.detached`) certifikátom OPRÁVNENIE 1042, pokrýva celý súbor, kryptograficky platný (pdfsig);
- príloha `261119-beA3601438.xml.xdcf` s `/AFRelationship /Supplement`, doložka 1.3, strany doložky čitateľné, osnova „Osvedčovacia doložka“;
- SHA-256 prvej revízie (870 275 bajtov) sa rovná `ElectronicFingerprintValue` doložky;
- Register: `clientOutput` singlePDF, `revisionOneLength` 870275, EZZK kód 0, „Prijatý na spracovanie v EZZK“.

**Test 2: E→E, `E1-eid-podpisane.pdf`, postup od 1. 1. 2027 vopred, Kontajner ASiC-E** (číslo 261119-SgA3601435). Prešiel:
- overenie: podpis klienta platný, KEP s kvalifikovanou časovou pečiatkou NASES; názov nového dokumentu `E1-eid-podpisane.pdf` (F6), položka „Overenie aplikáciou Chevron7 (Testovacia evidencia)“ (F9), „Prihlásenie do EZZK“ zelené;
- záznam `50349287.ConversionRecordOfElectronicDocumentToElectronicDocument_2021.sk` 1.2 podpísaný a odoslaný ako prvý, **bez `DSId`**;
- **Otázka DSId: Testovacia evidencia záznam E→E 1.2 bez `DSId` prijala (kód 0) a spracovala** (odoslaný 12:47:20Z, „Spracovaný v EZZK“ pri kontrole 13:00:21Z, asi 13 minút);
- „Zastaviť čakanie“ a potom „Dokončiť konverziu“: aplikácia pokračovala v čakaní bez nového čísla a bez nového podpisu záznamu;
- po spracovaní podpísaná doložka (13:00:34Z): `E1-eid-podpisane.asice` s `E1-eid-podpisane.pdf` a `261119-SgA3601435.xml.xdcf` (doložka E→E 1.3), jeden podpis XAdES s časovou pečiatkou; SHA-256 PDF sa rovná odtlačku v doložke aj v Registri.

**Test 3: E→E, `E1-eid-podpisane.pdf`, postup od 1. 1. 2027 vopred, Jeden PDF s doložkou** (číslo 261119-qZa3601436). Prešiel:
- prevod na PDF/A a kontrola PDF/A-3B pred pridelením čísla prešli; záznam 1.2 podpísaný a odoslaný 13:03:34Z, prijatý (kód 0), „Spracovaný v EZZK“ pri kontrole 13:29:15Z (asi 26 minút);
- po spracovaní podpísaný `E1-eid-podpisane-konvertovane.pdf` (13:29:30Z): jeden podpis PAdES certifikátom OPRÁVNENIE 1042 cez celý súbor, príloha `261119-qZa3601436.xml.xdcf` (doložka E→E 1.3, formát PDF/A-3), osnova „Osvedčovacia doložka“;
- SHA-256 prvej revízie (364 502 bajtov) sa rovná odtlačku nového dokumentu v doložke; odtlačok originálu je SHA-256 `E1-eid-podpisane.pdf`.

**Pozorovanie k čakaniu:** spracovanie v Testovacej evidencii trvalo 13 a 26 minút. Počas celej doby je obrazovka autorizácie zablokovaná čakaním (najviac 30 minút), kým kontrola na pozadí sa pýta až hodinu po prvej kontrole. Advokát navrhuje, aby čakanie bežalo na pozadí.

**Nové nálezy:**
- **F10 (opravené v tejto vetve):** zastavené čakanie sa ukazovalo ako červená chyba „Konverziu sa nepodarilo autorizovať“ a text odkazoval na „Autorizovať konverziu“, hoci tlačidlo sa volá „Dokončiť konverziu“. Teraz je to modrá informácia „Čakanie na EZZK je zastavené“, rovnako pri uplynutí 30 minút („EZZK záznam ešte spracúva“) (test `testStoppedOrLongWaitReadsAsInformationNamingTheFinishButton`).
- **F11 (neopravené, mimo PR #106):** prvá analýza AI pri `A-sken.pdf` trvala asi 6 minút, kým bolo okno v pozadí; proces pritom takmer nevyťažoval procesor. Treba zistiť, či čaká na studený model FoundationModels alebo na aktiváciu okna.

### Krok 2: E→E s B1 až B4 (Mac Studio, karta SAK, Testovacia evidencia, postup od 1. 1. 2027 vypnutý)

Zdroje v `~/Desktop/chevron7-test`: B1 = `B1-listina_podpisane.pdf` (PAdES T s QTS, teda revízia s časovou pečiatkou dokumentu a podpis), B2 = `B2-listina-dvakrat_podpisane.pdf` (B1 podpísané ešte raz, PAdES B bez QTS, pozri F12), B3 = `B3/B3-listina_podpisane.asice` (dávka, jeden spoločný kontajner XAdES s QTS Sectigo, dve PDF).

**B1** (261119-Z0A360143b, Kontajner ASiC-E). Prešiel: podpis platný, doložka E→E 1.3, balík záznamu `chevron7-e2e-record-1.0`, nový dokument PDF/A-2B, odtlačok nového PDF aj originálu sedí, EZZK „Prijatý na spracovanie“.

**B2** (261119-nja360143C, Kontajner ASiC-E). Prešiel: overenie ukázalo dva platné podpisy a originály `B2-listina-dvakrat_podpisane-1` a `-2`; v doložke aj zázname dva originály, odtlačok `-1` = SHA-256 prvých 360 404 bajtov (koniec prvého podpisu), `-2` = celý súbor; EZZK „Prijatý na spracovanie“.

**B3** (261119-V7A3601439, Kontajner ASiC-E). Prešiel: „Súbory v kontajneri“ preusporiadané (zápisnica pred listinou), druh dokumentu Zmluva a Plná moc; doložka uvádza originály v tomto poradí, záznam E→E 1.0 nesie `OriginalDocumentType` Zmluva a Plná moc; nové PDF má 2 strany a osnovu `B3-zapisnica.pdf`, `B3-listina.pdf` v zvolenom poradí; EZZK „Prijatý na spracovanie“.

**B4 sa nedal vytvoriť:** dávka berie iba PDF a kontajnery, PNG pri otvorení ticho vynechá. Obrázok na A4 treba overiť s `E4-png-xades.asice` (zatiaľ neurobené, čakalo sa na povolenie celej obrazovky pre okno výberu súboru).

**Nové nálezy:**
- **F12 (neopravené):** podpis už podpísaného PDF (PAdES s úrovňou T) so zapnutou QTS vždy zlyhá „Podpisovanie zlyhalo: Signing failed. [SIGNING_FAILED]“, bez QTS prejde. Príčina (overená bez karty na testovacej CA v engine): `SigningJob` pridáva časovú pečiatku údajov cez `PAdESService.timestamp()`, ktorá v DSS 6.4 najprv volá `incorporateValidationData` a pre existujúci podpis úrovne T chce dáta o odvolaní; holý `CommonCertificateVerifier` ich nemá, takže padne `AlertException` ešte pred kartou. Návrh: časovú pečiatku pridať priamo `PAdESTimestampService.timestampDocument` a doplniť test s podpisom od CA na úrovni T. Okrem toho `CLIProcessRunner` (protokol v1) nezapisuje riadky chyby z engine do logu `EngineBridge`, preto v logu nebola trieda výnimky.
- **F13 (neopravené):** pri spustení aplikácie sa samo otvorí okno Nastavenia. Okno `Window("Nastavenia")` nemá `.restorationBehavior(.disabled)`, takže ho macOS obnoví, ak bolo otvorené pri ukončení (v systéme je vypnuté „Zatvárať okná pri ukončení aplikácie“).

**Ešte neoverené:** obrázok na A4 (E4), postup od 1. 1. 2027 v kombinácii s Jedným PDF (P→E aj E→E), F7, F1, F2 a F8 vizuálne na Mac Studiu.

## Kontrola po 1.21.2 (20. 11. 2026)

- **F12 overené kartou (I.CA, OPRÁVNENIE):** `B1-listina_podpisane.pdf` podpísané znova ako PAdES so zapnutou QTS (BOSA) prešlo, výstup `B1-listina_podpisane_podpisane.pdf`. Prvých 360404 bajtov je zhodných s B1, súbor má dve časové pečiatky dokumentu a dva podpisy, pdfsig hodnotí oba podpisy ako platné a druhý pokrýva celý dokument (čas podpisu 20. 11. 2026 06:12:19). Pruh nad dokumentom: „Podpísané 2 podpismi, obe platné“.
- **F14 (opravené):** obrazovka po podpise ukazuje v karte „Časová pečiatka“ časy prvého, starého podpisu (19. 11. 2026 22:13:31) namiesto nového. `SigningDoneView` berie `store.resultSignatures.first`, čo je pri už podpísanom dokumente najstarší podpis, a nie ten, ktorý pruh označí ako „nový“. Oprava: karta berie podpis pridaný v tejto relácii (`SignatureBannerModel.addedSignature`), inak najnovší.
- **F13 nejasné:** pri tomto spustení bolo okno Nastavenia otvorené. Treba overiť, či ho otvoril používateľ, alebo ho macOS obnovil aj v 1.21.2.
- **F13 (pokračovanie, opravené):** Nastavenia sa v 1.21.2 otvárali pri každom otvorení dokumentu z Findera, aj keď appka už bežala, nielen pri spustení. Hlavná `WindowGroup` neprijíma externé udalosti, preto SwiftUI odovzdalo dokument scéne `Window("Nastavenia")` a otvorilo ju. Overené na malej SwiftUI appke: bez `.handlesExternalEvents(matching: [])` na okne Nastavenia sa pri otvorení PDF ukáže Nastavenia, s ním žiadne okno a hlavné okno otvorí delegát cez príkaz Nové okno (⌘N). Oprava: rovnaký modifikátor na oknách Nastavenia a Trénovanie detektora.

## Kontrola po 1.21.4 (20. 11. 2026)

- **F13 overené:** Chevron7 ukončený, PDF otvorené cez „Otvoriť v“ (a znova dvakrát, kým appka bežala): vždy len hlavné okno, Nastavenia sa neotvorili.
- **F14 overené kartou:** `B1-listina_podpisane_podpisane.pdf` podpísané tretí raz s QTS (`…_podpisane_podpisane_podpisane.pdf`, pdfsig: tri platné podpisy). Karta „Časová pečiatka“ ukazuje nový podpis: čas podpisu 20. 11. 2026 7:18:43, časová pečiatka podpisu 7:18:44.
- **F15 (opravené):** v tej istej karte „Časová pečiatka údajov“ ukazovala 19. 11. 2026 22:13:31, teda pečiatku dokumentu spred prvého podpisu. Engine pri PAdES vypisuje každú časovú pečiatku dokumentu zo skoršej revízie, ktorú podpis pokrýva, od najstaršej, a `SignatureTreeDecoder` brala prvú. Oprava: berie najnovšiu (tú, ktorú pridal tento podpis); platí aj pre riadky v zozname podpisov.

## Kontrola po 1.21.5 (20. 11. 2026)

- **F15 neopravené v 1.21.5:** v zozname „Podpisy (3)“ mali všetky tri podpisy „Časovú pečiatku údajov“ 19. 11. 2026 22:13:31. Príčina je v engine, nie v aplikácii: `MachineInspectionService.signatureTimestamps` priraďovala podpisu len časové pečiatky dokumentu z `getDetachedTimestamps()`, no DSS vedie pečiatku pridanú po prvom podpise ako jeho archívnu pečiatku, takže druhý a tretí podpis ju nevideli. Oprava: zoznam všetkých časových pečiatok dokumentu PDF (samostatné aj tie, ktoré DSS priradí podpisom), zoradený podľa revízie. Overené sondou nad `B1-listina_podpisane_podpisane_podpisane.pdf`: podpis 2 pokrýva pečiatky 21:13:31Z a 05:12:19Z, podpis 3 aj 06:18:43Z; aplikácia z nich ukáže najnovšiu.

## Kontrola po 1.21.6 (20. 11. 2026)

- **F15 overené:** `B1-listina_podpisane_podpisane_podpisane.pdf`, zoznam „Podpisy (3)“, všetky tri podpisy platné KEP. Časová pečiatka údajov: podpis 1 19. 11. 2026 22:13:31, podpis 2 20. 11. 2026 06:12:19, podpis 3 20. 11. 2026 07:18:43. Každá je o sekundu staršia než časová pečiatka podpisu, ako má byť.

## E4: obrázok na A4 (1.21.6, 20. 11. 2026)

- `E4-png-xades.asice` (jeden PNG `sample.png`, 628 × 605 px bez údaja o rozlíšení, testovací XAdES podpis s neovereným reťazcom): overenie s potvrdením „nie je možné zistiť“, doložka E→E, autorizácia kartou v Testovacej evidencii, číslo 261120-oV580fC024, EZZK prijalo záznam na spracovanie.
- Výstup `E4-png-xades (2).asice`: `E4-png-xades.pdf` a `261120-oV580fC024.xml.xdcf`. PDF má jednu stranu A4 na šírku (841,89 × 595,28 pt), lebo obrázok je širší ako vyšší. Obrázok je vložený bez zmeny (628 × 605 px), pri predvolených 150 dpi meria 301,4 × 290,4 pt (asi 106 × 102 mm), je vycentrovaný, nezväčšený a vzpriamený.
- **Overené.**
