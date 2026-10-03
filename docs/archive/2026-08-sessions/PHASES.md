# Autogram macOS - Implementačná dokumentácia fáz 1–4

> Stav: august 2026 · 236 vykonaných testov · 3 skipped · 0 failures · Swift 6 strict concurrency · 0 Swift package dependencies

Tento dokument popisuje, čo presne implementujú jednotlivé fázy modulu Zaručená konverzia
(ZaKo) a štandardného podpisovania, aké rozhodnutia boli prijaté a kde sú limity.

## Externá revízia požiadaviek z 28. 8. 2026

Pracovné podklady dodané po implementácii uvádzajú pre P -> E PDF/A-1a alebo PNG, zatiaľ čo
aktuálny runtime pipeline a testy používajú PDF/A-2b. Tento rozdiel je release-blocking
rozhodnutie, nie dôvod na slepé prepnutie čísel v validátore. Rovnako nie sú v repozitári
potvrdené aktuálne produkčné EZZK API, verzie formulárov ani požiadavky na overenie cudzích
podpisov.

Autoritatívny register, porovnanie a akceptačné gates:

- [`docs/ZAKO_EXTERNAL_REQUIREMENTS_SPEC_2026-08-28.md`](ZAKO_EXTERNAL_REQUIREMENTS_SPEC_2026-08-28.md)
- [`Chevron7/docs/superpowers/plans/2026-08-28-zako-external-requirements.md`](../../../Chevron7/docs/superpowers/plans/2026-08-28-zako-external-requirements.md)
- [`docs/SESSION_HANDOFF_2026-08-28-ZAKO-SPEC.md`](SESSION_HANDOFF_2026-08-28-ZAKO-SPEC.md)

Kým neprejdú Fáza 0 a externé validačné gates, označenie produktu zostáva kontrolovaný
technický pilot P -> E.

### Stav Fázy 0 a začiatok Fázy 1

Fáza 0 je uzavretá ako dokončený discovery gate s negatívnym externým výsledkom: verejné
zdroje overené 28. 8. 2026 neposkytli autoritatívne XSD/XSLT ani produkčný EZZK kontrakt.
Preto sa nezmenil PDF/A profil ani produkčný transport.

Bezpečná časť Fázy 1 je implementovaná ako provenance vrstva:

- `ConversionFormPack` rozlišuje verziu záznamu a doložky, účinnosť, renderer, artefakty,
  stav overenia a stav prijatia,
- `FormPackRepository` podporuje effective-date výber, historické lookup a produkčný gate,
- existujúci P -> E pack je explicitne `unverified` a `unknown`,
- generátor má pack-aware API s kontrolou fingerprintu a zachovaným legacy overloadom,
- `EvidenceRecord` a `ConversionRecordEnvelope` ukladajú `FormPackStamp`.
- `ConversionOutputProfile` oddeľuje implementovaný pilotný PDF/A-2b profil od navrhovaného
  PDF/A-1a a PNG profilu; neimplementované profily konvertor aj validátor odmietnu.

Fáza 1 nie je externá XSD validácia. Ďalším krokom je vloženie autoritatívnych artefaktov do
form packu a ich nezávislé overenie.

---

## Fáza 1 - Výstupná pipeline podľa špecifikácie

### XML doložka (ConversionRecord 1.0)
- Namespace: `https://data.gov.sk/id/egov/eform/50349287.ConversionRecordOfPaperToElectronicDocument.sk/1.0`
  (stará schéma `ConversionCertificate…/1.2` zo vzorových ASiC-E súborov je podľa § 4.1 špecu neplatná)
- Poradie elementov presne podľa skeletonu v `AUTOGRAM_ZAKO_MODULE_SPEC.md` § 4.2:
  `OriginalDocumentInfo → NewDocumentInfo → PersonPerformingConversion → UsedDevice → ConversionExecutionDateTime → ConversionRecordEvidenceNumber`
- **Codelisty** cez mechanizmus `codelistCode + codelistItem[itemCode, itemName@Language=sk]`:

| Codelist | Význam | Hodnoty v appke |
|---|---|---|
| 12 | formát papiera | A4 / A3 / Letter |
| 11 | umiestnenie prvku | Down, Down edge, Left down, Right down, Left up, Right up, Up, Center, Left, Right |
| 14 | metóda otlačku | SHA-256 |
| 15 | druh prvku | vlastnoručný podpis, okrúhla pečiatka so štátnym znakom, reliéfna pečiatka, parafa, iný prvok |
| 53 | formát nového dokumentu | PDFA2 |
| 4001 (item 7) | typ identifikátora | IČO |

- Identifikátor osoby ako IDCType: `ico://sk/{IČO}`
- Evidenčné číslo vo forme URI: `https://data.gov.sk/id/egov/conversion-record/{číslo}`
- Otlačok: **base64(SHA-256)** intermediárneho PDF/A pred vložením EmbeddedFile + metóda codelist 14
- Každý bezpečnostný prvok: slovný opis + strana + list (duplex počítadlo `(strana+1)/2`) +
  lokalita codelist 11 + nová strana
- `ConversionExecutionDateTime` s lokálnym UTC offsetom (`+02:00`), nie Z-formou

### Poradie pipeline (kľúčová oprava)
```
PDF/A konverzia → SHA-256 (fingerprint) → XML doložka →
EmbeddedFile do PDF → finálna normalizácia a validácia → ASiC-E balenie →
podpis → lokálna evidencia → CEZZK fronta
```
Fingerprint sa počíta nad čistým konvertovaným dokumentom (doložka je „spojená“ cez
EmbeddedFile + samostatný `.xml.xdcf`, nemení teda obsah otlačku).

Tlačiteľná strana doložky sa do konvertovaného PDF nevkladá (vizuálna reprezentácia je
samostatné tlačivo, § 5.5 špecu). `ClausePDFRenderer` zostáva v kit-e pre budúci preview/tlač.

### ASiC-E kontajner
```
mimetype                       application/vnd.etsi.asic-e+zip (prvý, stored)
{dokument}.pdf                 PDF/A-2b s EmbeddedFile doložkou
{evidenčné číslo}.xml.xdcf     samostatná doložka
META-INF/manifest.xml          OASIS manifest 1.2 ("/" + dáta)
META-INF/signatures001.xml     XAdES-B/T nad všetkými dátovými objektmi
```

### Evidenčné čísla
Mock EZZK generuje reálny formát `{registry}-{YYMMDD}-{seq}` (default registry `1563`).
Produkčné čísla prichádzajú z IS EZZK ešte pred vytvorením záznamu (§ 38 zákona).

---

## Fáza 2 - Časové pečiatky a PDF/A v štandardnom režime

### RFC 3161 klient (`RFC3161TimestampClient`)
- Vlastná DER enkódkia TimeStampReq (SHA-256 messageImprint, nonce, certReq) -
  golden vektor testovaný bajt-po-bajte
- Parser odpovede: PKIStatusInfo (granted/grantedWithMods), extrakcia ContentInfo tokenu
  a `genTime` z TSTInfo (GeneralizedTime aj UTCTime)
- Injektovateľný transport (`LLMTransport`) → testy bežia offline

### TSA servery
Built-in zoznam zrkadlí originálnu aplikáciu Autogram + slovenskú realitu:
1. **CA Disig (SK)** - `http://tsa.disig.sk/qts` *(default)*
2. **Sectigo Qualified** - `http://timestamp.sectigo.com/qualified`
3. **Belgian Federal Government TSA** - `http://tsa.belgium.be/connect`

Vlastné servery je možné pridávať v Nastaveniach; tlačidlo *Otestovať spojenie* pošle
skutočnú RFC 3161 žiadosť. Migrácia starej jedinej `tsaURL` prebieha automaticky pri načítaní.

### PDF/A pred podpisom
Toggle *Konvertovať do PDF/A pred podpisom* v štandardnom režime; režim konverzie
(vektorový / raster 200 dpi) sa berie z Nastavenia › Konverzia PDF/A.

---

## Fáza 3 - SAK karta end-to-end

### Reálne KEP podpisy
Dva natívne podpisové enginy nad `SecIdentity` (Keychain / CryptoTokenKit karty):

| Engine | Výstup | Použitie |
|---|---|---|
| `KeychainXAdESSigningProvider` → XAdES-B/T | ASiC-E kontajner | ZaKo (default), štandardný režim |
| ten istý provider → PAdES-B/T (`PAdESSigner`) | podpísané PDF (inkrementálna revízia) | voliteľný formát v štandardnom režime |

**XAdES**: exc-c14n-kompatibilná serializácia (namespaces deklarované lokálne na
podpisovaných fragmentoch), SHA-256 digesty dát + SignedProperties, SigningCertificate
(SHA-512 cert digest + IssuerSerial), SigningTime, voliteľný SignatureTimeStamp
(RFC 3161 token ako EncapsulatedTimeStamp).

**PAdES**: CMS SignedData (detached) so signed attrs (contentType, messageDigest,
signingTime, signingCertificateV2) + unsigned attr time-stamp token; ByteRange pokrýva
celý súbor okrem rezervovaného `/Contents`; inkrementálna revízia s AcroForm/SigField.
Test overuje, že `messageDigest` v CMS == SHA-256 nad rozsahmi ByteRange.

**X.509 parser** (`X509Inspector`): sériové číslo (ľubovoľná dĺžka → desiatkové),
issuer/subject → RFC 2253 (vrátane hex-formy pre neznáme typy a escapingu).

### Mandátna brána (ZaKo)
- Checklist riadok *Mandátny certifikát SAK* - vyžaduje `isMandateCertificate &&
  isQualified && hasPrivateKey`
- Autorizácia bez mandátu je zablokovaná; pokračovanie len výslovným override toggle-om
  (varovanie, že CEZZK zápis môže byť zamietnutý) - edge case podľa špecu § 9
- Auto-výber identity preferuje mandátny certifikát

### Live detekcia karty
`CardPresenceMonitor` (TKTokenWatcher + KVO na `tokenIDs`) - vloženie/vytiahnutie karty
okamžite refreshuje zoznam certifikátov v autorizačnom kroku.

### eID / CryptoTokenKit
Slovenská eID (Cosmo 9.2, `eID_klient` 5.4) neexportuje `kSecClassIdentity` spoľahlivo
a hromadný `SecItemCopyMatching` s `kSecReturnRef` na všetky certifikáty **visí**.
Scanner preto:
1. zoberie `TKTokenWatcher.tokenIDs` (mimo Apple tokenov),
2. na každom tokene načíta certifikáty cez `kSecReturnData` a privátny kľúč cez
   `kSecReturnRef` filtrovaný `kSecAttrTokenID`,
3. spáruje ich podľa verejného kľúča.

PIN zadáva CryptoTokenKit / eID_klient vo vlastnom dialógu (`SecKeyCreateSignature`).
PKCS#11 (`libPkcs11.dylib`, OpenSC, AWP) ostáva fallback, ak token SecKey nevráti.
Oficiálny PKCS#11 modul eID klienta aktuálne hlási 0 slotov; AWP je iba x86_64.

### Výber providera
`SigningProviderFactory.makeDefault()`: ak existuje identita s privátnym kľúčom →
reálny provider (výstup označený ako právne záväzný), inak DEMO podpisovač
(jasne označený, nikdy `isLegallyBinding = true`).

---

## Fáza 4 - Validácie a EZZK dashboard

### Validačné vrstvy (hard gates pred/po autorizácii)

| Validátor | Čo kontroluje |
|---|---|
| `PDFAValidator` | %PDF hlavička, %%EOF, startxref, XMP pdfaid part/conformance, GTS_PDFA OutputIntent + ICC profil, absencia šifrovania a JavaScriptu |
| `AttestationXMLValidator` | štruktúra ConversionRecord 1.0, povinné polia neprázdne, sheets ≥ 1, fingerprint == base64(SHA-256), evidenčné číslo ako URI, ISO8601 čas, počet prvkov == vstup, PhysicalPerson/LegalSubject |
| `ASiCEContainerVerifier` | mimetype prvý + hodnota, manifest "/" + úplnosť, **recompute SHA-256 každého dátového objektu proti ds:Reference DigestValue**, prítomnosť XAdES signed-properties referencie, demo flag |

Všetky tri bežajú automaticky v `ZakoSessionStore.authorizeAndSign()`; zlyhanie =
`ComplianceValidationError` so zoznamom problémov, konverzia sa nedokončí.

### Dashboard evidencie
- Summary karty: celkovo / zapísaných v CEZZK / čakajúcich / **po lehote 24 h**
- Červený indikátor a textový stav pre záznamy po lehote + stĺpec „Lehota CEZZK"
- Filtre podľa stavu + fulltext
- Detail: status timeline (číslo → KEP → CEZZK), kopírovanie URI a SHA-256,
  náhľad XML doložky, zmazanie záznamu
- Hromadné odosielanie čakajúcich záznamov do IS EZZK s aktualizáciou stavov;
  minútový refresh lehôt

---

## Aktuálny UI workflow update

Aktuálny macOS 27 build obsahuje tieto používateľské zmeny:

- sidebar používa gear tlačidlo a natívny `Settings` scene namiesto samostatnej položky,
- Settings scene má karty AI Vision, Konverzia PDF/A, EZZK a Profily advokáta,
- AI Vision zobrazuje provider cards, readiness stav URL/modelu/Keychain kľúča a päť prompt režimov,
- prompt predvoľby pokrývajú právne dokumenty, konzervatívnu kontrolu, podpisy a parafy,
  pečiatky a reliéfne prvky aj vlastný prompt,
- karta Konverzia PDF/A obsahuje vektorový a rasterizovaný režim, správu TSA serverov
  a test RFC 3161 spojenia,
- voľba PAdES alebo ASiC-E/XAdES používa priame tlačidlá v podpisovom workflow,
- recent documents, dávkové preflight fázy, progress, cancel, stop, retry a Finder
  Quick Action sú napojené na existujúce workflow stores.
- `build_app.sh install` robí čistú náhradu bundle v `/Applications/Autogram macOS.app`;
  samostatný build bez argumentu mení iba `.build` výstup.

---

## EZZK OAuth2 a REST integrácia

Aktuálny build obsahuje bezpečnostne ohraničenú OAuth2 integráciu pre EZZK:

- pevné sandboxové a produkčné environmenty bez URL override v nastaveniach,
- OIDC discovery s kontrolou issueru, HTTPS endpointov a rovnakého hostiteľa,
- authorization-code flow s PKCE, `state` a `ASWebAuthenticationSession`,
- natívny callback `autogram://ezzk/callback` registrovaný v hlavnom bundle,
- Keychain token store s oddelením environmentov, obnovou session po štarte,
  odhlásením a explicitným zrušením autentizácie,
- typed REST klient pre dostupné evidenčné čísla a EZZK endpointy,
- fail-closed spracovanie chýb, neúplných odpovedí a neovereného receipt.

Lokálny mock zostáva dostupný pre demo režim. Produkčné odoslanie sa nepovažuje za
hotové, kým nebude potvrdená registrácia callbacku, sandboxový účet, kompletný POST
kontrakt a samostatný podpísaný ASiC record v konverznom workflow.

---

## Podpis mobilom (Autogram v mobile)

Fáza pridaná 2026-09-11 na vetve `feature/avm-mobile-signing`. Mac nemá NFC, preto ide
podpis občianskym preukazom cez relay Slovensko.Digital: `AVMClient` nahrá dokument
zašifrovaný 32-bajtovým kľúčom (`X-Encryption-Key`, `payloadMimeType` s príponou
`;base64`), `AVMSigningSession` ukáže QR kód (`/qr-code?guid&key`) a polluje
`GET /documents/{guid}` s `If-Modified-Since`, kým iPhone s Autogram v mobile dokument
nepodpíše. `MobileSigningCoordinator` a `MobileSigningSheet` riadia UI, stores menia len
posledný krok (`sign(viaMobile:)`, `authorizeAndSign(viaMobile:)`).

Overené na reálnom serveri: PAdES aj ASiC-E, pečiatka pri úrovni `_T`, `signers` ako
celé DN. Nepodpísaný ASiC-E server odmieta, preto ZaKo cez mobil podpisuje finálne PDF/A
s vloženou doložkou a server ho zabalí do kontajnera. Podpis bez mandátneho certifikátu
ZaKo odmietne. `swift run avm-probe <súbor>` slúži na kontrolu protokolu.

---

## Obmedzenia a ďalšie kroky

| Oblasť | Stav | Poznámka |
|---|---|---|
| EZZK API | Demo mock + typed OAuth2 REST client | registrácia callbacku, sandboxový receipt a oficiálny POST kontrakt zostávajú externými gate-mi |
| Cert chain v XAdES | len podpisový cert | chain/LTA (B-LT archivácia) je V2 |
| veraPDF | nahradené vlastným `PDFAValidator` | štrukturálna validácia; plná schémová validácia ostáva voliteľná via bundled CLI |
| eID PKCS#11 | natívny SecKey funguje | oficiálny `libPkcs11.dylib` má 0 slotov; pri uviaznutom CTK reštartovať eID_klient |
| Mandát atribút | heuristika CN/issuer strings | presný OID mandátu doplniť po analýze reálneho SAK certifikátu |
| Formuláre 1.2 (2027) | verziované konštanty v `ZakoCodelists` | auto-update artefaktov z formulare.slovensko.sk (FormularyRepository) |
| XAdES_ZEP | netvorí sa | zakázaný podľa eIDAS IR 2015/1506 |
| Podpis mobilom | funguje pre PAdES a ASiC-E s eID | mandátny certifikát na eID neoverený; XDCF v ZaKo kontajneri nie je podpísaný samostatne; SAK karta cez AVM nejde |

## Právna kotva
- Zákon č. 305/2013 Z. z., § 35–39
- Vyhláška MIRRI č. 70/2021 Z. z. (+ formulár 50349287 verzia 1.0 záznamu P→E)
- eIDAS 910/2014 + IR 2015/1506 (PAdES/XAdES/CAdES v ASiC; ZEP zakázaný)
