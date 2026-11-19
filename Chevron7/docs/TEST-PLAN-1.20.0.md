# Chevron7 1.20.0: čo odskúšať

Nainštalovaná verzia: 1.20.0 v `/Applications/Chevron7.app` (podpísaná, notarizovaná, rovnaký kód ako `main`, commit 96c00a81). Verzia 1.19.0 je v Koši.

Pri každom teste si zapíš: evidenčné číslo, výsledok (OK / chyba), presný text chyby a pri EZZK stav riadku v Registri.

## 0. Príprava (10 min)

- [ ] Spusti Chevron7, v Nastaveniach > Prehliadač a Finder skontroluj, že rozšírenie v Safari je zapnuté (po výmene aplikácie ukonči Safari cez ⌘Q a znova ho otvor).
- [ ] Nastavenia > EZZK: prepni na **Testovacia evidencia** (Rozšírené nastavenia) a prihlás sa.
- [ ] Priprav si testovacie súbory:
  - **A:** naskenovaný papierový dokument (PDF, 2 až 3 strany).
  - **B1:** PDF podpísané tvojou kartou (Podpisovanie, PAdES).
  - **B2:** to isté PDF podpísané ešte raz (dva podpisy, dve revízie).
  - **B3:** ASiC-E s dvoma PDF (Podpisovanie > dávka, ASiC-E, „jeden spoločný kontajner“).
  - **B4:** ak vieš, ASiC-E s PDF a obrázkom JPEG alebo PNG (napr. cez podpisuj.sk alebo D.Signer).

## 1. Jedno PDF pre klienta (P→E, #103)

Režim: Testovacia evidencia, bez „Postup od 1. 1. 2027 vopred“.

- [ ] Prejdi celú konverziu P→E so súborom A. V kroku autorizácie zvoľ **Výstup pre klienta: jedno PDF**.
- [ ] Vedľa zdroja vznikne jedno `.pdf` (žiadny `.asice`).
- [ ] Otvor ho v Adobe Acrobat Reader a skontroluj:
  - podpis je platný,
  - v prílohách je doložka `<číslo>.xml.xdcf`,
  - na konci sú čitateľné strany doložky,
  - v záložkách je „Osvedčovacia doložka“.
- [ ] Nahraj PDF na slovensko.sk (overenie podpisu), zapíš si výsledok a či vidí časovú pečiatku.
- [ ] V Registri pri riadku je odtlačok označený „SHA-256 prvej revízie (prvých N bajtov)“. Riadok po chvíli prejde do stavu prijatý alebo spracovaný v EZZK.
- [ ] Prepni na Ostrú evidenciu: voľba „jedno PDF“ musí byť zablokovaná s vysvetlením. Potom prepni späť na Testovaciu.
- [ ] Ak máš kde, over, či ORSR prijme takéto PDF (podpísané PDF s XML prílohou). Toto je otvorená otázka pred povolením v ostrej evidencii.

## 2. E→E s viacerými súbormi (#104)

Režim: Testovacia evidencia, dnešný postup.

- [ ] Konverzia E→E so súborom **B1**: overenie prejde, výsledok má doložku a záznam E→E 1.0.
- [ ] Konverzia so súborom **B2**: v zozname originálov sú `<názov>-1` a `<názov>-2` (každá podpísaná revízia zvlášť).
- [ ] Konverzia so súborom **B3**:
  - v časti „Súbory v kontajneri“ zmeň poradie súborov,
  - každému zvoľ „Druh dokumentu“,
  - nový dokument je jedno PDF so záložkou pre každý súbor v zvolenom poradí.
- [ ] **B4** (ak ho máš): obrázok je v novom PDF na strane A4, nezväčšený a správne otočený.
- [ ] Odmietnutia, ak chceš skúsiť: nepodpísané PDF, ASiC-E s XML súborom. Obe musia skončiť zrozumiteľnou chybou ešte pred pridelením čísla.
- [ ] Pri každom riadku v Registri skontroluj „Uložiť správu o overení…“ a stav EZZK.

## 3. Postup od 1. 1. 2027: záznam najprv (#105, najdôležitejšie)

Nastavenia > EZZK > Rozšírené: zapni **„Postup od 1. 1. 2027 vopred“**. Režim zostáva Testovacia evidencia.

- [ ] **E→E so súborom B1.** Očakávaný postup:
  - najprv sa podpíše záznam E→E 1.2 (PIN),
  - záznam sa odošle,
  - aplikácia čaká na spracovanie v EZZK (kontrola každých 30 s, najviac 30 min),
  - po spracovaní sa podpíše výstup pre klienta s doložkou 1.3.
- [ ] **Kľúčová otázka:** prijme EZZK záznam E→E 1.2? Neobsahuje DSId. Ak ho EZZK odmietne, zapíš si presný kód a text chyby z Registra.
- [ ] To isté so súborom **B3** (viac súborov v jednom zázname).
- [ ] **Prerušenie:** počas čakania stlač „Zastaviť čakanie“, potom „Dokončiť konverziu“. Musí pokračovať bez nového čísla a bez nového podpisu záznamu.
- [ ] **P→E v novom postupe** so súborom A: overí, či EZZK prijme záznam 1.2 a doložku 1.3 (kontrola s kartou je stále otvorená).
- [ ] Kombinácia s jedným PDF: E→E alebo P→E v novom postupe s voľbou „jedno PDF“.
- [ ] Mobil musí byť v novom postupe odmietnutý (len kontrola hlášky).
- [ ] Na konci vypni „Postup od 1. 1. 2027 vopred“.

## 4. Čo mi poslať späť

- Evidenčné čísla a stav každého riadku v EZZK (prijatý, spracovaný, odmietnutý s kódom).
- Pri chybe snímku obrazovky alebo presný text.
- Výsledok zo slovensko.sk pre jedno PDF.
- Ak niečo zlyhá v podpise, výstup z Konzoly: filter `EngineBridge` alebo `ZaKo`.

## Ostrá evidencia zostáva zatvorená

- **E→E** (`E2EProductionPolicy.enabled`): kým jedna konverzia E→E neprejde celá v Testovacej evidencii.
- **Jedno PDF** (`SinglePDFProductionPolicy.enabled`): kým EZZK v Testovacej evidencii neprijme jednu konverziu v každom smere a kým nie je jasné, či ORSR takéto PDF prijme.

Po tvojich výsledkoch ich viem otvoriť.
