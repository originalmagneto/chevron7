# ZaKo externé požiadavky a porovnanie implementácie

> Verzia: 0.1 · Dátum: 28. 8. 2026 · Stav: pracovná technická špecifikácia a register otvorených rozhodnutí
>
> Tento dokument zachytáva požiadavky z dodaných pracovných podkladov, porovnáva ich s aktuálnym repozitárom a oddeľuje implementačný fakt od právneho alebo prevádzkového tvrdenia, ktoré ešte musí potvrdiť autoritatívny zdroj. Nie je právnym stanoviskom a sám osebe nepotvrdzuje prijatie výstupu orgánom verejnej moci ani CEZZK.

## 1. Zdrojové podklady

### Podklady dodané na porovnanie

1. `/Users/Magneto/Downloads/Štandardy formátu PDF_A-1a pre zaručenú konverziu dokumentov.md`
2. `/Users/Magneto/Downloads/Štandardy formátu PDF_A-1a pri zaručenej konverzii dokumentov.md`
3. `/Users/Magneto/Downloads/Manuál pre vývoj aplikácie na zaručenú konverziu pre advokátov.md`

### Existujúce projektové podklady

1. `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/AUTOGRAM_ZAKO_MODULE_SPEC.md`
2. `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/docs/PHASES.md`
3. `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramApp/ZakoSessionStore.swift`
4. `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramKit/Attestation/AttestationClauseGenerator.swift`
5. `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramKit/Attestation/AttestationXMLValidator.swift`
6. `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramKit/PDFA/PDFAConverter.swift`
7. `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramKit/PDFA/PDFAValidator.swift`
8. `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramKit/EZZK/EZZKService.swift`
9. `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramKit/Evidence/LocalEvidenceStore.swift`

### Hierarchia dôvery

Požiadavka môže byť označená ako release requirement až po potvrdení v jednej z týchto vrstiev:

1. platné znenie zákona alebo vyhlášky,
2. aktuálny autoritatívny formulár, XSD, XSLT alebo codelist od MIRRI,
3. aktuálna integračná dokumentácia a sandbox CEZZK/EZZK,
4. interná produktová politika, napríklad ľudské schválenie AI nálezu.

Pracovné podklady z Downloads sú vstupom na analýzu. Ich tvrdenia o formáte, verziách formulárov, protokole alebo právnych účinkoch sa nesmú implementovať ako nemenné konštanty bez potvrdenia autoritatívnym zdrojom.

## 2. Cieľový rozsah

### MVP: listinný dokument -> elektronický dokument (P -> E)

MVP má pokrývať iba kontrolovaný tok P -> E:

1. import PDF alebo podporovaného obrazového skenu,
2. potvrdenie, že vstup je originál alebo úradne osvedčená kópia,
3. analýza strán, neprázdnych strán, listov a formátov papiera,
4. návrh bezpečnostných prvkov pomocou lokálneho AI asistenta,
5. povinné ľudské potvrdenie alebo úprava každého relevantného prvku,
6. získanie evidenčného čísla z EZZK pred vytvorením záznamu,
7. vytvorenie doložky podľa aktívneho oficiálneho form packu,
8. vytvorenie a nezávislá kontrola výsledného dokumentu,
9. autorizácia mandátnym kvalifikovaným podpisom a kvalifikovanou časovou pečiatkou,
10. lokálna evidencia a odoslanie do CEZZK v lehote podľa aktuálneho integračného kontraktu.

E -> P, E -> E, dávkové spracovanie, priame skenovanie, fakturačný export a externý overovací klient zostávajú samostatnými capability modulmi. Nemajú byť implicitne súčasťou P -> E release gate.

## 3. Normatívna matica požiadaviek

Statusy v tabuľke:

- **Pokryté**: existuje implementácia a test, ale nemusí ísť o externú konformitu.
- **Čiastočne**: časť toku existuje, chýba hard gate, autoritatívny artefakt alebo produkčné overenie.
- **Chýba**: v aktuálnom kóde nie je samostatná funkcia alebo dôkaz.
- **Blokované**: nemožno bezpečne dokončiť bez externého rozhodnutia alebo kontraktu.

| Oblasť | Požiadavka z podkladov | Aktuálny stav v repozitári | Status | Ďalší krok |
|---|---|---|---|---|
| Smer konverzie | P -> E ako prvý podporovaný smer | `ZakoSessionStore` a `ConversionDirection.paperToElectronic` existujú | Pokryté | Udržať P -> E ako jediný produkčný pilotný smer |
| Pôvod vstupu | Originál alebo úradne osvedčená kópia s potvrdením obsluhy | `AttestationData.originConfirmed` a preflight checkbox existujú | Čiastočne | Pridať auditný záznam potvrdenia, čas, identitu a text poučenia |
| Strany a listy | Počet strán, neprázdnych strán a listov, s voľbou simplex/duplex/manual | `PDFAnalysisEngine`, `SheetCountingMethod` a UI existujú | Čiastočne | Vyžadovať potvrdenie nejasných strán a oddeliť fyzický počet listov od odhadu |
| Formát listiny | Formát papiera per strana a skupiny podľa veľkosti | `paperSizeBreakdown` a codelist 12 existujú | Čiastočne | Doplniť hard gate pre neznámy formát a golden fixtures pre zmiešané formáty |
| Bezpečnostné prvky | Slovný opis, strana, list a umiestnenie pre každý relevantný prvok | AI detector, manuálne prvky a XML lokality existujú | Čiastočne | Zaviesť stav `navrhnuté/potvrdené/zamietnuté` a potvrdenie všetkých neprázdnych strán |
| AI detekcia | AI môže pomáhať pri označení podpisov, pečiatok a reliéfov | `BuiltInVisionProvider` a manuálna paleta existujú | Čiastočne | AI nesmie sama potvrdiť úplnosť; doplniť review checklist a testy false positive |
| Výstupný formát | Podklady uvádzajú PDF/A-1a, prípadne PNG v obmedzenom prípade | `PDFAConverter` a UI cielia na PDF/A-2b | Blokované | Získať autoritatívnu format matrix a rozhodnúť PDF/A-1a, PDF/A-2b, PNG alebo kombináciu |
| OCR a Unicode | Pri PDF/A-1a textová vrstva, tagy a Unicode mapovanie | Vektorový režim zachováva vstupnú vrstvu, raster režim OCR nevytvára | Chýba | Navrhnúť OCR/tagging pipeline a overenie skutočnej PDF/A-1a konformity |
| Doložka | Aktuálny XML formát podľa oficiálneho formulára a vizualizácia podľa šablóny | `AttestationClauseGenerator` hardcoduje P -> E namespace a verziu 1.0 | Čiastočne | Zaviesť verzované form packs s XSD, XSLT, codelistami, namespace a hashom artefaktov |
| Verzie formulárov | Podklady rozlišujú záznam 1.0/1.2 a doložku 1.3, s budúcou účinnosťou | Projektové docs používajú ConversionRecord 1.0 a spomínajú 1.2 v budúcnosti | Blokované | Vytvoriť autoritatívnu maticu `recordVersion` a `clauseVersion`; neodvodzovať ich z jedného čísla |
| Spojenie doložky | XML ako samostatný artefakt aj EmbeddedFile v dokumente, prípadne ASiC-E | `EmbeddedFileService`, `.xdcf` export a `ASiCEPackager` existujú | Čiastočne | Overiť asociáciu `/AF`, MIME typ, názov, package profile a prijatie reálnym validátorom |
| Fingerprint | Hash novovzniknutého dokumentu podľa presne definovaného rozsahu | SHA-256 sa počíta nad PDF/A pred vložením doložky | Čiastočne | Potvrdiť hash contract s EZZK a pokryť ho golden artefaktom; zakázať nejednoznačný názov `intermediate` |
| Autorizácia | Mandátny KEP alebo kvalifikovaná pečať, s QTS zahŕňajúcou objekt podpisu | Signing provider, XAdES/PAdES a RFC 3161 klient existujú | Čiastočne | Nezávisle overovať podpis, certifikačný reťazec, mandátny atribút, QTS a pokrytie objektu |
| Cudzí podpis | Pred konverziou overiť cudzie podpisy a najstaršiu platnú časovú pečiatku | Samostatný vstupný signature-verification gate sa v ZaKo toku nenachádza | Chýba | Pridať `InputSignatureVerificationService` s jasným stavom a záznamom výsledku do doložky/evidencie |
| Čas konverzie | Dôveryhodný serverový čas, bez tichého fallbacku na lokálne hodiny | HTTP HEAD `Date` a EZZK service abstraction existujú | Čiastočne | Ukladať zdroj, presnosť, čas získania a väzbu na číslo; pri nedostupnosti blokovať produkčný tok |
| Evidenčné číslo | Číslo získať pred vytvorením záznamu a evidovať jeho vydanie | `requestEvidenceNumbers(count:)` a preflight gate existujú | Čiastočne | Pridať `issuedAt`, osobu, request id, stav použitia a ochranu proti opakovanému použitiu |
| Lehota CEZZK | Odoslanie v lehote 24 hodín od vytvorenia záznamu, podľa kontraktu | `EvidenceRecord` počíta deadline z `conversionTime` | Čiastočne | Ujasniť autoritatívny začiatok lehoty, uložiť ho explicitne a pridať warning/escalation pred expiráciou |
| EZZK protokol | Podklady opisujú konkrétny integračný tok, projektové docs upozorňujú na nepublikované API | Implementácia používa best-effort JSON `/portal/api/*` a Mock | Blokované | Vyžiadať aktuálny WSDL/OpenAPI, autentizáciu, podpis requestu, sandbox a idempotency pravidlá |
| Lokálna evidencia | Všeobecná časť, záznamy, audit a reporty | `LocalEvidenceStore` je JSON register s aktuálnymi stavmi | Čiastočne | Doplniť immutable audit trail, artefaktové referencie, number lifecycle a export overovacieho balíka |
| Nezávislá validácia | PDF/A, XML, ASiC-E/XAdES a certifikáty majú prejsť nezávislou kontrolou | Lokálne validátory sú heuristické; ASiC verifier kontroluje základnú štruktúru a digesty | Čiastočne | Integrovať alebo prevádzkovo vyžadovať veraPDF/PDFBox/DSS-equivalent validation report |
| Registrácia kancelárie | EZZK credentials, eDesk/email a prístupový certifikát podľa aktuálneho procesu | Nastavenia obsahujú IČO, login, heslo, email a eDesk | Čiastočne | Neimplementovať registračný proces podľa pracovnej poznámky bez overenia aktuálneho portálu a certifikátového profilu |
| Vizuálna doložka | Vizualizácia podľa oficiálnej šablóny | `ClausePDFRenderer` existuje, pipeline doložku do PDF nevkladá ako tlačiteľnú stranu | Čiastočne | Získať XSLT/šablónu, rozhodnúť samostatný preview versus súčasť artefaktu a pridať golden render |
| Právne účinky | Podklady používajú široké formulácie o účinkoch a povinnom prijatí | README a špecifikácia obsahujú produktové právne tvrdenia | Blokované | Nahradiť ich counsel-approved textom a oddeliť právnu zodpovednosť obsluhy od technického výsledku |

## 4. Rozhodnutia, ktoré treba uzavrieť pred kódom

### D1: Profil PDF/A

Podklady z Downloads uvádzajú PDF/A-1a ako bezpečný alebo očakávaný formát a v obmedzenom prípade PNG. Aktuálny produkt používa PDF/A-2b. Ide o release-blocking konflikt.

Rozhodnutie nesmie vzniknúť iba prepnutím čísla v `PDFAValidator`. PDF/A-1a vyžaduje reálne tagovanie, Unicode mapovanie a konformný output intent. Pred zmenou treba mať:

1. autoritatívny formátový požiadavok pre P -> E,
2. testovací vstup s textovou a grafickou vrstvou,
3. nezávislý validátor a referenčný report,
4. rozhodnutie, či PNG patrí do MVP alebo mimo neho.

### D2: Verzie formulárov

Záznam o konverzii a osvedčovacia doložka sú odlišné artefakty. Pracovné podklady uvádzajú odlišné verzie a dátumy účinnosti, zatiaľ čo existujúca implementácia má jednu hardcoded P -> E namespace konštantu. Zavádza sa preto dvojica:

```text
ConversionFormPack {
    direction
    recordVersion
    clauseVersion
    namespace
    xsd
    xslt
    codelists
    effectiveFrom
    effectiveUntil
    artifactSHA256
    acceptedByEZZK
}
```

Aktívny pack sa vyberá z autoritatívneho effective-date a acceptance údaja. Už vydané záznamy sa spätne neprepíšu.

### D3: EZZK kontrakt

Kód nesmie predpokladať, že pracovný opis SOAP, JSON alebo challenge-response je aktuálny. Doménová vrstva bude volať protokolový adaptér:

```text
EZZKGateway
  serverClock()
  allocateEvidenceNumbers()
  submitConversionRecord()
  queryRecord()
```

Konkrétny HTTP/SOAP transport, autentizácia, podpis správ, retry a idempotency patria do adaptera. Produkčný provider nesmie byť označený ako production-ready, kým neprejde sandboxom.

### D4: Ľudské potvrdenie AI

AI detekcia je asistované označenie, nie dôkaz, že dokument neobsahuje ďalší bezpečnostný prvok. Pred autorizáciou musí obsluha potvrdiť:

- každú neprázdnu stranu,
- počet listov a metódu počítania,
- každý navrhnutý prvok,
- každý ručne pridaný prvok,
- záver, že zostávajúce strany boli skontrolované.

Toto potvrdenie sa uloží do lokálnej evidencie s časom, identitou a verziou detectora.

### D5: Produkčný versus demo režim

Mock EZZK, demo podpisovač, lokálny heuristický validátor a neoverený form pack musia byť v UI aj dátach označené ako neprodukčné. Demo režim nesmie:

- volať produkčný EZZK,
- vytvoriť stav `submitted` bez potvrdenia servera,
- označiť výsledok ako právne záväzný,
- skryť, že externá konformita nebola overená.

## 5. Akceptačný kontrakt pre P -> E pilot

Pilot možno označiť ako produkčne pripravený až po splnení všetkých bodov:

1. Aktívny form pack obsahuje oficiálne XSD/XSLT/codelisty a hash artefaktov.
2. XML doložka prejde oficiálnou XSD validáciou na reprezentatívnych dokumentoch.
3. Zvolený PDF/A alebo PNG profil prejde nezávislou kontrolou na vektorovom aj skenovanom vstupe.
4. EmbeddedFile, standalone XML/XDCF a ASiC-E majú potvrdený package contract.
5. Fingerprint presne zodpovedá hash contractu EZZK.
6. Reálny podporovaný mandátny certifikát je správne klasifikovaný, platný a použitý na autorizáciu.
7. QTS je kvalifikovaná, časovo konzistentná a pokrýva požadovaný objekt podpisu.
8. Cudzie vstupné podpisy a časové pečiatky majú samostatný overiteľný výsledok.
9. Sandbox EZZK pridelí číslo, prijme záznam a vráti jednoznačný stav.
10. Číslo, jeho vydanie, použitie, odoslanie a retry sú idempotentné a auditované.
11. Každý operator override je viditeľný a uložený.
12. Demo a mock cesta je oddelená od produkčnej cesty a je testom zakázaná.

Kým tieto body nie sú splnené, správne označenie produktu je **kontrolovaný technický pilot P -> E**, nie potvrdený produkčný nástroj zaručenej konverzie.

## 6. Mimo rozsahu tejto revízie

- právne stanovisko k výkladu § 35 až 39 zákona č. 305/2013 Z. z.,
- potvrdenie, že pracovné podklady presne opisujú aktuálne účinné formuláre,
- implementácia E -> P alebo E -> E,
- certifikácia AI detectora znalcom,
- náhrada lokálneho JSON registra za Core Data alebo SQLite bez samostatného dátového návrhu,
- integrácia na nepublikované produkčné EZZK rozhranie bez kontraktu,
- tvrdenie o prijatí výsledku konkrétnym orgánom verejnej moci.

## 7. Referenčné právne a prevádzkové kotvy na overenie

- zákon č. 305/2013 Z. z., najmä § 35 až 39,
- vyhláška MIRRI č. 70/2021 Z. z.,
- aktuálne formuláre, XSD, XSLT a codelisty z autoritatívneho zdroja MIRRI,
- aktuálny integračný manuál a sandbox EZZK/CEZZK,
- eIDAS 910/2014 a vykonávacie akty pre kvalifikované podpisy, pečate, časové pečiatky a ASiC.

Pri každej implementácii treba v change requeste uviesť, ktorá konkrétna verzia zdroja bola overená a kedy.