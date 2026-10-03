# Autogram — Modul Zaručená Konverzia (ZaKo): Kompletná Špecifikácia & Plán

> **Verzia dokumentu:** 1.0 · **Dátum:** 22. 8. 2026 · **Status:** Zadávací podklad pre vývoj
>
> Tento dokument vychádza z (a) právnej rešerše platnej legislatívy SR, (b) reverse engineeringu aplikácie **Podpisuj.sk 5.7.144** (`/Applications/Podpisuj.app`) ako funkčnej referencie a (c) existujúcich dizajnových špecifikácií Autogramu (`AUTOGRAM_MASTER_UI_UX_SPEC.md`, `AUTOGRAM_UI_UX_CONCEPTS.md`).

---

## 1. Exekutívny Súhrn

Modul **ZaKo** pridáva do Autogramu schopnosť vykonávať **zaručenú konverziu dokumentov** podľa § 35–39 zákona č. 305/2013 Z. z. o e-Governmente a vyhlášky MIRRI č. 70/2021 Z. z. o zaručenej konverzii.

**Cieľový používateľ:** advokát (ďalej aj notár/exekútor) s mandátnym certifikátom na advokátskom preukaze a predplatenými kvalifikovanými časovými pečiatkami — oboje už má k dispozícii.

**Hlavný konkurenčný rozdiel:** existujúce nástroje (Podpisuj.sk, D.Convert) sú Java desktopové monštrá s desiatkami manuálne vypĺňaných polí. Autogram ZaKo bude **seamless**: automaticky zdeteguje počet strán, neprázdne strany, formát listiny, bezpečnostné prvky (pečiatky, vlastnoručné podpisy, reliéfne slepotlače), automaticky stiahne evidenčné číslo z centrálnej evidencie EZZK, vygeneruje XML osvedčovaciu doložku podľa oficiálnej XSD schémy a celé to zapečatí KEP advokáta s kvalifikovanou časovou pečiatkou — **na 2–3 kliky namiesto 30 políčok**.

**Podporované smery konverzie (podľa zákona):**

| Smer | Kód | Použitie u advokáta | Priorita |
|---|---|---|---|
| Listinný → elektronický | **P→E** | Klient prinieslo papierový originál → e-dokument s účinkami osvedčenej kópie | **MVP** |
| Elektronický → listinný | **E→P** | Tlač e-dokumentu + doložky na papier | V2 |
| Elektronický → elektronický | **E→E** | Napr. XAdES_ZEP/XML → PDF/A | V2 |

---

## 2. Právny Rámec (Rešerš)

### 2.1 Primárne predpisy

| Predpis | Obsah relevantný pre modul |
|---|---|
| **Zákon č. 305/2013 Z. z.** o e-Governmente, **§ 35–39** | Definícia zaručenej konverzie, okruh oprávnených osôb (§ 35 ods. 3 — advokát medzi nimi), postup konverzie (§ 36), obsah a spojenie osvedčovacej doložky (§ 37), evidencia a Centrálna evidencia záznamov (§ 38), účinky novovzniknutého dokumentu (§ 39). |
| **Vyhláška MIRRI č. 70/2021 Z. z.** o zaručenej konverzii | Formáty vstupných/výstupných dokumentov, obsah osvedčovacej doložky (prílohy č. 1, 3, 5) a záznamu o konverzii (prílohy č. 2, 4, 6), spôsob autorizácie, evidencia záznamov, prideľovanie evidenčných čísel, 24-hodinová lehota na zápis do CEZZK. Nahrádza starú vyhlášku č. 331/2018 Z. z. |
| **Metodické usmernenie MIRRI č. 006408/2021/oMK-3** (25. 3. 2021) | „Manuál" praktického postupu konverzie; doplnené usmernením k výplni položiek *mandát* a *identifikátor* vo formulári doložky. |
| **Nariadenie eIDAS (EÚ) 910/2014** + Vykonávacie rozhodnutie 2015/1506 | QES/QTS musia byť vo formátoch PAdES/XAdES/CAdES v kontajneroch ASiC-E/S. **Formát XAdES_ZEP (.zep/.xzep) je zakázaný** vytvárať. |
| **Zákon č. 272/2016 Z. z.** o dôveryhodných službách | Kvalifikované prostriedky, TSA, sankcie. |

### 2.2 Kľúčové právne fakty pre implementáciu

1. **Vstup P→E:** konvertovať možno len **originál alebo úradne osvedčenú kópiu** listinného dokumentu. Advokát zodpovedá za dodržanie podmienok konverzie, ale **nezodpovedá za pravdivosť obsahu** pôvodného dokumentu.
2. **Účinok:** novovzniknutý dokument neoddeliteľne spojený s osvedčovacou doložkou má rovnaké právne účinky ako **osvedčená kópia** pôvodného dokumentu.
3. **Osvedčovacia doložka (P→E, príloha č. 3 vyhlášky 70/2021)** musí obsahovať údaje podľa prílohy č. 1 písm. a)–c), e), f) a najmä:
   - **počet listov pôvodného dokumentu a počet neprázdnych strán**, formát listiny,
   - **slovný opis bezpečnostných prvkov a ich umiestnenia** (list + strana + pozícia),
   - údaje o osobe vykonávajúcej konverziu (zhoda s certifikátom!), čas konverzie,
   - **evidenčné číslo záznamu o konverzii** a odkaz na CEZZK.
4. **Forma doložky (§ 3 ods. 3 vyhlášky):** pri P→E a E→E sa doložka vyhotovuje ako **XML (.xml) zahrnutý v PDF ako príloha typu EmbeddedFile**, pri dodržaní štandardov na prijímanie podpísaných dokumentov. Doložka sa vytvára **ako samostatný dokument AJ ako súčasť novovzniknutého dokumentu**, nesmie obsahovať prázdne listy a musí byť trvalo spojená s novým dokumentom.
5. **Autorizácia:** KEP vyhotovený s použitím **mandátneho certifikátu** alebo kvalifikovaná pečať, **s pripojenou kvalifikovanou časovou pečiatkou zahŕňajúcou objekt podpisu**. Údaje autorizujúcej osoby v certifikáte **sa musia zhodovať** s údajmi osvedčujúcej osoby v doložke.
6. **Evidencia (§ 38–39 zákona + vyhláška § 7–10):**
   - Osoba si vedie **lokálnu evidenciu záznamov o konverzii** (všeobecná časť + záznamy).
   - **Evidenčné číslo** pridelí **IS EZZK** (`ezzk.iomo.sk`, prevádzkovateľ MIRRI) **ešte pred vytvorením záznamu**; 1 číslo = 1 záznam, viaže sa na osobu + čas pridelenia; možné hromadné prideľovanie.
   - Záznam o konverzii sa do CEZZK **zašle do 24 hodín od vytvorenia** (jednotlivo alebo hromadne).
   - CEZZK zamietne zápis, ak napr. **čas v kvalifikovanej časovej pečiatke predchádza času konverzie** uvedenému v zázname, alebo evidenčné číslo už bolo použité.
7. **Registrácia v IS EZZK:** cez `https://ezzk.iomo.sk/portal/ezzk/registration`; registračný formulár sa podpisuje **mandátnym certifikátom** (nie občianskym preukazom). Notifikácie chodia na edesk/email.
8. **Automatizácia posúdenia bezpečnostných prvkov** je novelou č. 211/2019 (§ 39 ods. 4) výslovne umožnená technickými/programovými prostriedkami, ak je znalcom osvedčené, že prostriedky umožňujú dodržať podmienky konverzie a sú zabezpečené proti zneužitiu → právny základ pre **AI Vision detekciu**.
9. **Overovanie tretími stranami:** OVM, ktoré použije skonvertovaný dokument, musí overiť zhodu doložky s CEZZK (§ 39 ods. 1) → verejný overovací portál `ezzk.iomo.sk`. Autogram pridá aj **lokálny overovací režim** (validácia KEP+QTS+ASiC).
10. ⚠️ **Termín:** MIRRI zverejnilo **nové verzie formulárov verzia 1.2, účinné od 1. 1. 2027** → architektúra musí mať **aktualizovateľnú sadu formulárov/XSD** (auto-download artefaktov), nie natvrdo zapísané schémy.
11. **Sadzobník úhrad:** advokát má nárok na úhradu za konverziu podľa sadzobníka → modul bude evidovať fakturovateľné úkony (export CSV).

---

## 3. Ako Funguje Zaručená Konverzia P→E (End-to-End)

```
 ┌──────────┐   ┌──────────────┐   ┌─────────────┐   ┌──────────────┐   ┌───────────────┐
 │ 1. SCAN  │ → │ 2. ANALÝZA    │ → │ 3. ČÍSLO     │ → │ 4. DOLOŽKA   │ → │ 5. AUTORIZÁCIA│
 │ originál │   │ (automatická) │   │ z IS EZZK    │   │ XML + PDF    │   │ KEP + QTS     │
 └──────────┘   └──────────────┘   └─────────────┘   └──────────────┘   └───────┬───────┘
                                                                                │
                                              ┌─────────────────────────────────┘
                                              ▼
                              ┌────────────────┐        ┌──────────────────────────┐
                              │ 6. LOKÁLNA      │ ─24h→ │ 7. ODOSLANIE DO CEZZK    │
                              │ EVIDENCIA       │       │ (jednotlivo / hromadne)  │
                              └────────────────┘        └──────────────────────────┘
```

1. **Scan/Import** — advokát naskenuje papierový originál (alebo pretiahne hotový sken PDF). Autogram priamo podporí import zo skenera cez ImageCapture framework (bonus).
2. **Automatická analýza (AI Vision)** — appka bez akéhokoľvek kliknutia zistí:
   - počet strán PDF, počet **neprázdnych** strán, odhad počtu **listov** (duplex),
   - veľkosť/formát listiny (A4/A3/portrét/landscape — per-page),
   - bezpečnostné prvky: okrúhle úradné pečiatky, vlastnoručné podpisy, reliéfne slepotlače, parafy — vrátane **strany a umiestnenia** (bounding boxy),
   - či sken nie je prevrátený/prázdny/nekvalitný.
3. **Evidenčné číslo** — Autogram sa online spýta IS EZZK a získa jedinečné evidenčné číslo záznamu (pred vytvorením doložky!).
4. **Generovanie doložky** — XML podľa oficiálneho eFormulára `50349287.ConversionRecordOfPaperToElectronicDocument` + vizuálna HTML/PDF reprezentácia; SHA-256 otlačok novovzniknutého dokumentu; vloženie XML do PDF ako **EmbeddedFile**.
5. **Autorizácia** — PAdES alebo ASiC-E podpis KEP advokáta z mandátneho certifikátu + **QTS** (časová pečiatka zahŕňajúca objekt podpisu). Čas konverzie sa berie zo **serverového času** (nie lokálnych hodín!).
6. **Lokálna evidencia** — záznam (XML) sa uloží do lokálneho registra konverzií.
7. **Odoslanie do CEZZK** — automaticky do 24 h (aj hromadne); stav doručenia viditeľný v UI.

---

## 4. Reverse Engineering Podpisuj.sk — Zistenia

Rozbalený `podpisuj-app-5.7.144.jar` potvrdil presnú dátovej štruktúru a workflow. Toto je **funkčná referencia** (nie UX referencia — UX budeme robiť lepšie).

### 4.1 Oficiálne eFormuláre (data.gov.sk)

- Namespace P→E záznamu: `https://data.gov.sk/id/egov/eform/50349287.ConversionRecordOfPaperToElectronicDocument.sk/1.0`
- Namespace E→P záznamu: `https://data.gov.sk/id/egov/eform/50349287.ConversionRecordOfElectronicDocumentToPaper.sk/1.0`
- Artefakty (XSD/XSLT) sa sťahujú z Modulu elektronických formulárov:
  `https://formulare.slovensko.sk/_layouts/eFLCM/GetEFormArtefact.aspx?ac=4&vid={identifier}&sid={...}&vh={hash}&vl={verzia}`
- Staršie verzie (už neplatné): `schemas.gov.sk/form/50349287.ConversionCertificateOfPaperToElectronicDocument/1.2`, `50349287.Dolozka_o_autorizacii.sk/1.4`.
- Identifikátor záznamu sa tvorí ako URI: `https://data.gov.sk/id/egov/conversion-record/{evidenčné číslo}`; subjekt: `https://data.gov.sk/id/legal-subject/{ICO}`.

### 4.2 Štruktúra XML `ConversionRecordOfPaperToElectronicDocument`

Rekonštruované z JAXB tried (`com.archimetes.podpisuj.desktopapp.commons.cxsd.conversionrecordofpapertoelectronicdocument`):

```xml
<ConversionRecord xmlns="https://data.gov.sk/id/egov/eform/
                   50349287.ConversionRecordOfPaperToElectronicDocument.sk/1.0">
  <OriginalDocumentInfo>
    <OriginalDocumentOrder/>            <!-- poradie v dávke -->
    <OriginalDocumentName/>             <!-- názov -->
    <OriginalDocumentType/>             <!-- druh (codelist) -->
    <OriginalDocumentNumberOfSheets/>   <!-- POČET LISTOV -->
    <OriginalDocumentNonEmptyPageCount/><!-- NEPRÁZDNE STRANY -->
    <OriginalDocumentPaperSize>
      <PaperSize/>                      <!-- codelist: A4/A3/... -->
      <PaperSizeNumberOfSheets/>        <!-- listov tejto veľkosti -->
    </OriginalDocumentPaperSize>
    <DocumentSecurityElementsDetails>
      <NewDocumentSecurityElementsPage/><!-- umiestnenie prvkov (list/strana) -->
    </DocumentSecurityElementsDetails>
  </OriginalDocumentInfo>

  <NewDocumentInfo>
    <NewDocumentName/>
    <NewDocumentFormat/>                <!-- codelist (PDF/PDF-A...) -->
    <ElectronicFingerprintValue/>       <!-- SHA-256 nového dokumentu -->
  </NewDocumentInfo>

  <PersonPerformingConversion>
    <PersonData>
      <PhysicalPerson>
        <PersonName><GivenName/><FamilyName/></PersonName>
        <Position/>                     <!-- funkcia (advokát/notár/...) -->
      </PhysicalPerson>
      <!-- alebo <LegalSubject><Name/></LegalSubject> pre PO -->
    </PersonData>
  </PersonPerformingConversion>

  <UsedDevice/>                          <!-- skener/zariadenie -->

  <ConversionExecutionDateTime/>         <!-- SERVEROVÝ čas konverzie -->
  <ConversionRecordEvidenceNumber/>      <!-- číslo z IS EZZK -->
</ConversionRecord>
```

Pomocné typy: `IDCType` (identifikátory s typmi ako `ico://sk/…`), codelisty (`codelistCode` + `codelistItem[itemCode, itemName]`) siahajú na **referenčné údaje data.gov.sk**.

### 4.3 Behaviorálne vzory Podpisuj (čo replikovať logicky, nie vizuálne)

| Správanie v Podpisuj | Detail |
|---|---|
| Detekcia mandátneho certifikátu | Certifikáty označené badge „Mandátny"; pri výbere certifikátu bez mandátu varovanie „Zvolený certifikát nie je mandátnym certifikátom pre zaručenú konverziu." |
| Serverový čas | Čas konverzie = serverový čas; pri nedostupnosti blokuje operáciu („Nesprávne nastavený čas… môže spôsobiť problém pri zápise záznamu do EZZK"). |
| Evidenčné číslo | Žiada sa od servera **pred** autorizáciou („Nepodarilo sa získať číslo osvedčovacej doložky"). |
| EZZK credentials | IČO + prihlasovacie meno + heslo + adresa edesku + notifikačný email. |
| Šablóny | Uloženie/načítanie predvyplnených údajov doložky. |
| Validácia pred autorizáciou | Tlačidlo „Skontrolovať"; chybné polia červené. |
| Batch konverzia | Viac dokumentov naraz; limit na počet („too_many_documents"). |
| Automatická štandardizácia | Prevod neštandardných vstupov do PDF/A (integrácia LibreOffice + **veraPDF validácia** — jars `validation-model-jakarta`). |
| Doložka | Generuje sa ako `attestationClauseXml` + `attestationClauseHtml` (vizuálna vrstva), vložená do výsledného PDF. |

---

## 5. Feature List

Legenda: 🟢 MVP (Fáza 1) · 🔵 V2 · 🟣 V3 · ⭐ = seamless/automatika

### 5.1 Vstup a analýza dokumentu

- 🟢⭐ Import PDF skenu drag-and-drop / NSOpenPanel / Quick Look extension.
- 🟢⭐ **Auto-počítadlo strán**: celkový počet strán, počet **neprázdnych** strán (detekcia bielych/obsahovo prázdnych skenov cez pixel analýzu).
- 🟢⭐ **Výpočet listov** (duplex odhad: `ceil(strany/2)`) s manuálnym override („Koľko listov má fyzický originál?") — predvyplnené, 1-klik potvrdenie.
- 🟢⭐ **Detekcia veľkosti listiny** per strana (A4/A3/portrét/landscape) z PDF mediaboxu + DPI skenu.
- 🔵 Import viacerých dokumentov naraz (dávka) so zdieľanou doložkou / samostatnými doložkami.
- 🔵 Priamy scan z TWAIN/ImageCapture zariadenia (300 dpi, farebnosť, duplex).
- 🔵 Auto-štandardizácia: konverzia do PDF/A-2b + veraPDF validácia (pre E→E a čistenie vstupov).

### 5.2 AI Vision — Bezpečnostné prvky (seamless jadro produktu)

- 🟢⭐ Detekcia **vlastnoručných podpisov** (bounding boxy, strana + kvadrant/pozícia).
- 🟢⭐ Detekcia **okrúhlych úradných pečiatok**: Implementované: vrstvená detekcia (heuristiky + Vision kontúry + saliency), kNN nad lokálnym datasetom, on-device Foundation Model klasifikácia neistých výrezov. Fáza C (plán): Create ML `MLObjectDetector` natrénovaný z exportovaného datasetu, pripojený ako ďalší zdroj kandidátov cez `CoreMLRequest`.
- 🟢⭐ Detekcia **reliéfnych slepotlačí** (shadow/gradient heuristika).
- 🟢⭐ **Slovný opis prvkov generovaný automaticky** do doložky: *„Na liste 2, strane 1, v pravej dolnej časti sa nachádza vlastnoručný podpis…"* — advokát len schváli/upraví.
- 🟢 Manuálny režim: advokát klikne na stranu → pridá prvok z palety (podpis/pečiatka/slepotlač/parafa/iné) → ťahaním umiestni.
- 🔵 OCR (Vision framework) — prečítanie hlavičky dokumentu na auto-názov doložky.
- 🔵 Confidence score + „potrebný ľudský dohľad" indikátor pri nízkjej istote.
- 🟣 Fáza C: doladenie Create ML `MLObjectDetector` nad rastúcim datasetom (pozri 5.2 vyššie); znalecké osvedčenie automatizácie podľa § 39 ods. 4 (marketingová výhoda).

### 5.3 Certifikáty a podpisovanie

- 🟢 PKCS#11/CryptoTokenKit enumerácia kartových certifikátov (eID, advokátsky preukaz SAK, I.CA, Disig).
- 🟢⭐ **Auto-detekcia mandátneho atribútu** v certifikáte (OID mandátu) → badge „MANDÁTNY"; varovanie pri ne-mandátnom certifikáte.
- 🟢 KEP podpis PAdES-BASELINE-T/LT + **QTS** (kvalifikovaná časová pečiatka zahŕňajúca objekt podpisu) — TSA konfigurovateľná.
- 🟢 Výstup: **PDF s EmbeddedFile XML doložkou** alebo **ASiC-E** (PDF sken + XML doložka spoluautorizované).
- 🟢 Zhoda identity: porovnanie CN/druhov mena certifikátu vs. údaje v doložke (hard gate pred podpisom).
- 🔵 Archívna časová pečiatka (PAdES-B-LTA) pre dlhodobú archiváciu.

### 5.4 EZZK Integrácia

- 🟢 Konfigurácia prístupov: IČO, login, heslo (macOS **Keychain**), notifikačný email/edesk.
- 🟢 **Žiadosť o evidenčné číslo** pred vytvorením záznamu (+ hromadné prideľovanie pre batch).
- 🟢 **Odoslanie záznamu do CEZZK** do 24 h — automatické s retry/backoff; fronta neodoslaných záznamov s alarmom v UI.
- 🟢 Stavy: `ČAKÁ NA ČÍSLO → PRIPRAVENÉ → PODPÍSANÉ → ODOSLANÉ → POTVRDENÉ/ZAMIETNUTÉ`.
- 🟢 Serverový čas EZZK/NTP ako čas konverzie (blokácia offline bez fallbacku na lokálne hodiny).
- 🔵 Overovací klient: vyhľadanie záznamu v CEZZK podľa evidenčného čísla (overenie cudzích doložiek).
- 🔵 Offline režim: lokálna evidencia pokračuje, odoslanie sa odloží (legislative: 24 h lehota → UI warning).

### 5.5 Doložka & XML engine

- 🟢 **XSD-validovaný generátor XML** podľa aktuálneho eFormulára (artefakty sťahované z formulare.slovensko.sk, verziované v appke).
- 🟢⭐ **Predvyplnenie 95 % polí**: identita advokáta (z certifikátu), profil kancelárie (SAK reg. č., IČO, sídlo), čas (server), otlačok (SHA-256), strany/listy/prvky (AI Vision), evidenčné číslo (EZZK).
- 🟢 Šablóny profilov (Advocate Profile Presets) — viacero profilov (advokát / kancelária / zastupovanie).
- 🟢 HTML/PDF vizuálna reprezentácia doložky (tlačivo podľa vyhlášky) — render cez WKWebView → PDF.
- 🔵 Verzia formulárov **1.0 → 1.2 (platná od 1.1.2027)**: auto-detekcia aktívnej verzie + migrácia šablón.

### 5.6 Lokálna evidencia & reporty

- 🟢 Register konverzií (Core Data/SQLite): všetky povinné údaje všeobecnej časti + záznamy; export XML/CSV.
- 🟢 Vyhľadávanie/filtruj podľa klienta, dátumu, evidenčného čísla, stavu CEZZK.
- 🔵 Fakturačný export úkonov (sadzobník úhrad za zaručenú konverziu) pre vyúčtovanie klientovi.
- 🔵 Štatistiky dashboard (konverzie/mesiac, neodoslané záznamy, expirácia certifikátu/pečiatok).

### 5.7 Smery E→P a E→E

- 🔵 **E→P:** validácia vstupných KEP/pečiatí (eIDAS reťazec), doložka príloha č. 1, tlač listinného dokumentu + doložky („notárska šnúrka" — perforácia/spojenie), QR kód na overenie v CEZZK.
- 🔵 **E→E:** konverzia legacy formátov (vrátane neautorizovaných PDF/TXT/PNG/XML) do PDF/A s doložkou príloha č. 5.

---

## 6. UX/UI Špecifikácia (Liquid Glass, SwiftUI)

Naväzuje na `design_assets/zako_advocate_studio.jpg` a hybridný model (kompaktná kapsula ↔ studio). Režim ZaKo je **vizuálne oddelený svet** od bežného podpisovania — po prepnutí sa horná lišta prefarbí do „notárskej" burgundy/smaragdovej témy a zobrazí stepper.

### 6.1 Obrazovky

1. **`ZaKoIntakeView`** — kompaktná dropzone (morfuje na studio). Po vložení skenu okamžite beží analýza: shimmer sweep cez miniatúry strán, bounding boxy prvkov „vyskočia" spring animáciou, počítadlá (strany/neprázdné/listy) sa doladia odometer efektom. SF Symbols: `doc.viewfinder`, `shield.checkerboard`, `brain.head.profile`.
2. **`ZaCoAnalysisCanvasView`** — plátno PDFKit + overlay bounding boxy; ľavý panel miniatúr so značkami prvkov; každý prvok editovateľný (typ, list, strana, pozícia, slovný opis). Chýbajúci prvok → amber warning pill.
3. **`ZaCoAttestationFormView`** — doložka ako „living document": náhľad tlačiva vpravo, formulárové polia vľavo, **takmer všetko predvyplnené a uzamknuté** (🔒 auto), editovateľné len názov/opis dokumentu a ručné doplnky. Validácia live (červené polia ako v Podpisuj, ale inline, nie až po „Skontrolovať").
4. **`ZaCoAuthorizeView`** — súhrnná „letková" kontrola: ✓ originál overený, ✓ evidenčné číslo, ✓ SHA-256, ✓ mandátny certifikát, ✓ QTS dostupná, ✓ zhoda identity. Jedno sklenené tlačidlo **„Autorizovať konverziu"** → PIN/BOK overlay → haptic success pulse + zelená pečiatková animácia na dokumente.
5. **`ZaCoEvidenceDashboard`** — tabuľka registrov + stav odoslania do CEZZK; neodoslané >20 h → pulsujúci červený indikátor; hromadné „Odoslať teraz".

### 6.2 SF Symbols (doplnok ku globálnej tabuľke)

| Symbol | Význam |
|---|---|
| `building.columns.fill` | Režim ZaKo / advokátska identita |
| `shield.checkerboard` | Overenie originálu / bezpečnostné prvky |
| `doc.badge.plus` → `doc.text.fill` | Vstup → doložka |
| `number.square.fill` | Evidenčné číslo EZZK |
| `signature` / `checkmark.seal.fill` | KEP / kvalifikovaná pečiatka |
| `clock.badge.checkmark` | QTS + serverový čas |
| `arrow.left.arrow.right.square` | Smer konverzie P↔E |
| `tray.and.arrow.down.fill` | Fronta odosielania do CEZZK |

---

## 7. Technická Architektúra (SwiftUI / macOS)

```
AutogramApp (SwiftUI)
 ├─ ZaKoFeature
 │   ├─ Intake          (drag&drop, scanner bridge)
 │   ├─ AnalysisEngine  (PDFKit + Vision + FoundationModels (+ CoreML vo fáze C) → SecurityElementsModel)
 │   ├─ AttestationKit  (XMLCoder generátor + XSD validator + HTML/PDF renderer)
 │   ├─ SigningEngine   (PKCS#11/CryptoTokenKit + PAdES/ASiC-E + TSA klient)
 │   ├─ EzzkClient      (URLSession, Keychain creds, evidence-number API, submission queue)
 │   ├─ EvidenceStore   (Core Data register + exporty)
 │   └─ TimeAuthority   (server time provider, monotónne watchdogy)
 └─ Shared: DesignSystem(Liquid Glass), CertificateInspector, BatchQueue
```

Kľúčové technické rozhodnutia:

1. **Podpisový engine:** PAdES/ASiC-E + QTS je najrizikovejší diel. Možnosti: (a) zabaliť EU **DSS knižnicu** (rovnakú ako používa Autogram/Podpisuj) do helper procesu, (b) natívna Swift implementácia nad Apple Crypto. Odporúčanie: **(a)** pre MVP-paritu s ekosystémom, s natívnym Swift facade.
2. **Vision + FoundationModels pipeline (+ CoreML vo fáze C):** `LayeredDetectionProvider` zlučuje kandidátov z `BuiltInVisionProvider` (frozen baseline), `VNDetectContoursRequest` a objectness saliency cez `CandidateMerger`; `TwoStageClassifier` klasifikuje najprv `FeaturePrintClassifier` (kNN nad `ExampleBank`) a neisté prípady posunie on-device `FoundationModelClassifier`; `SegmentationSnapper` (`GenerateIterativeSegmentationRequest`) dorába klik-na-prvok rámce. Fáza C dopĺňa Create ML `MLObjectDetector` ako ďalší zdroj kandidátov cez `CoreMLRequest`. Všetko on-device (GDPR), voliteľne LLM vision backendy podľa existujúcej 4-režimovej AI špecifikácie.
3. **XML:** `XMLCoder` + runtime XSD validácia; artefakty formulárov cacheované a verziované (`FormularyRepository`).
4. **EmbeddedFile do PDF:** PDFKit/CoreGraphics (`PDFDocument` + attachment) — kontrola, že viewer zachová prílohu; alternatívne ASiC-E kontajner.
5. **Bezpečnosť:** EZZK heslá len v Keychain; PIN/BOK overlay bez logovania; audit log úkonov.
6. **Testy:** golden-file testy XML doložky (porovnanie s referenčným outputom), integračný test EZZK sandboxu, unit testy počítadiel strán/listov na fixture skenoch.

---

## 8. Compliance Checklist (Hard Gates pred Autorizáciou)

- [ ] Vstup je originál / úradne osvedčená kópia (advokát potvrdzuje checkbox s právnym poučením)
- [ ] Evidenčné číslo získané z IS EZZK a nepoužité
- [ ] Čas konverzie = serverový čas; QTS čas ≥ čas konverzie (inak CEZZK zamietne)
- [ ] Počet listov / neprázdnych strán / veľkosť listiny vyplnené a potvrdené
- [ ] Každý bezpečnostný prvok má slovný opis + list + stranu + umiestnenie
- [ ] Doložka nemá prázdne listy; je trvalo spojená s dokumentom (EmbeddedFile/ASiC)
- [ ] SHA-256 novovzniknutého dokumentu zapísaný v doložke
- [ ] Údaje certifikátu == údaje osvedčujúcej osoby v doložke
- [ ] Mandátny atribút certifikátu prítomný; certifikát platný; QTS z kvalifikovanej TSA
- [ ] Formát výstupu podľa štandardov (PDF/PDF-A, ASiC-E; žiadny XAdES_ZEP)
- [ ] Záznam uložený do lokálnej evidencie + naplánované odoslanie do CEZZK ≤ 24 h

## 9. Edge Cases

| Scenár | Správanie |
|---|---|
| EZZK nedostupné | Blokácia začiatku konverzie (nie fallback na lokálny čas); retry s exponenciálnym backoffom |
| QTS staršia než čas konverzie | Hard stop — záznam by bol zamietnutý; opakovanie s novým časom/číslom |
| Duplex vs. simplex nejasný | Otázka s predvýberom z analýzy; ovplyvní počet listov |
| Viacero veľkostí papiera | Skupinové `PaperSize` bloky (A4×n, A3×m) |
| Priložené prázdne listy v skene | Upozornenie + vylúčenie z neprázdnych; doložka nesmie mať prázdne listy |
| Certifikát bez mandátu | Varovanie + možnosť zvoliť iný; pokračovanie len s výslovným override (audit log) |
| Hromadná konverzia | Limit dávky (referenčne ~30 strán/dokument, limit počtu — konfigurovateľné) |
| Zmena formulára 1.2 (2027) | Feature-flag verzie, migračná obrazovka, regresné testy |

## 10. Roadmapa

| Fáza | Rozsah | Exit kritériá |
|---|---|---|
| **F1 — MVP P→E** (≈ 6–8 týždňov) | Intake, analýza (strany/listy/veľkosť), AI Vision prvky v1, XML doložka v1.0, EZZK číslo+odoslanie, KEP+QTS podpis, lokálna evidencia | End-to-end konverzia reálneho dokumentu; XSD-validný XML; zápis v CEZZK |
| **F2** | E→P, E→E, batch, PDF/A štandardizácia + veraPDF, overovací klient CEZZK, fakturačný export | Dva nové smery konverzie; hromadná dávka 20 dokumentov bez zásahu |
| **F3** | Formuláre 1.2 (2027-ready), LTA archivácia, Create ML `MLObjectDetector` (fáza C, pozri 5.2 a 7 vyššie), znalecké osvedčenie automatizácie, scanner bridge, CLI/REST (autogram protocol) | Auto-update formulárov; certifikovaná automatizácia prvkov |

## 11. Otvorené Otázky / Riziká

1. **EZZK aplikačné rozhranie** — vyhláška ho výslovne zabezpečuje („prostredníctvom aplikačného rozhrania"), ale verejná OpenAPI dokumentácia nie je publikovaná; Podpisuj komunikuje cez vlastný REST klient. → **Action:** vyžiadať od MIRRI špecifikáciu API / zvážiť partnerstvo s existujúcim prevádzkovateľom softvéru.
2. Presné codelisty (`originalDocumentType`, `paperSize`, `newDocumentFormat`) — siahnuť na referenčné registre data.gov.sk za behu, nie hardcoded.
3. Znalecké osvedčenie AI detekcie (§ 39 ods. 4) — dlhodobý projekt, MVP ponúka AI ako *asistenta* (advokát schvaľuje), čo je vždy compliant.
4. Licencovanie EU DSS (LGPL) v Mac App Store distribúcii — ak potreba, distribúcia mimo MAS / dynamické linkovanie.
```
