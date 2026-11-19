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
