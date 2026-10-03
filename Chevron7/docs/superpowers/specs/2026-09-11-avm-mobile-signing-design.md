# Podpisovanie mobilom cez Autogram v mobile (AVM) - návrh

Dátum: 2026-09-11
Stav: schválený v chate, čaká na implementáciu

## Cieľ

Používateľ Autogram macOS bez čítačky kariet podpíše dokument občianskym preukazom s NFC
cez iPhone a aplikáciu Autogram v mobile (AVM). Mac dokument nahrá na AVM server, zobrazí
QR kód, telefón podpíše, Mac si stiahne podpísaný súbor a pokračuje existujúcim flow
(uloženie, evidencia, validácia).

## Kontext a obmedzenia

- Mac nemá NFC a štátne eID mSDK existuje len pre iOS a Android. Podpis vzniká na
  serveri (avm-service s DSS), preto sa bundlovaný Java engine nemení.
- Verejný server: `https://autogram.slovensko.digital/api/v1`. Integrácia tretích strán
  je verejne dokumentovaná a povolená (VOP, stránka služby). Bez registrácie, bez API kľúča.
- iOS appka AVM má natvrdo universal link `autogram.slovensko.digital` a parser deep
  linkov odmieta iný hostname. Vlastný server je preto mimo rozsahu; base URL je
  konfigurovateľná len pre testovanie.
- AVM appka číta výhradne občiansky preukaz. SAK karta (aj nová s NFC) cez AVM nejde.
- Zaručená konverzia vyžaduje mandátny certifikát. Ak podpis z AVM nie je mandátny,
  ZaKo autorizácia sa odmietne (rozhodnutie: odmietať, kým sa nedorieši SAK NFC).
- Finder Quick Action ostáva len pre kartu (beží bez okna).

## Protokol AVM (overené v zdrojoch avm-server a autogram-sdk)

1. Klient vygeneruje 32 náhodných bajtov (AES-256), base64. Kľúč posiela v hlavičke
   `X-Encryption-Key` pri každom volaní nad dokumentom. Server akceptuje strict aj urlsafe base64.
2. `POST /documents` s JSON `{ document: { filename, content(base64) }, parameters: {...},
   payloadMimeType }`. Odpoveď obsahuje `guid`; hlavička `Last-Modified` je základ pre polling.
   Úrovne: `PAdES_BASELINE_B|T`, `XAdES_BASELINE_B|T`, `CAdES_BASELINE_B|T`; `container: ASiC-E|ASiC-S`.
3. QR kód: `https://autogram.slovensko.digital/api/v1/qr-code?guid=<guid>&key=<base64 kľúč, URL-encoded>`.
4. Polling `GET /documents/{guid}` s `If-Modified-Since: <Last-Modified>` a `X-Encryption-Key`.
   304 znamená nepodpísané. 200 vráti JSON `{ filename, mimeType, content(base64), signers[] }`,
   kde `signers[]` má `signedBy` a `issuedBy`.
5. `DELETE /documents/{guid}` po zrušení. Server dokument maže po 24 h aj sám.
6. Registrácia integrácie (`/integrations`, `/sign-request`, push) je mimo rozsahu.

## Architektúra

### AutogramKit: `Sources/AutogramKit/Signing/AVM/`

- `AVMModels.swift`: `AVMSignatureLevel`, `AVMContainer`, `AVMUploadRequest`,
  `AVMUploadResponse`, `AVMSignedDocument`, `AVMSigner`, `AVMError` (Codable, Sendable).
  Chyby servera (`{ code, message, details }`) sa mapujú na `AVMError.server(code:message:)`.
- `AVMDocumentKey.swift`: generovanie 32 bajtov cez CryptoKit `SymmetricKey(size: .bits256)`,
  `base64` (strict) a `urlQueryValue` (percent-encoded).
- `AVMClient.swift`: `actor AVMClient` nad `URLSession` (injektovateľná konfigurácia pre testy).
  Metódy: `upload(_:key:) -> AVMUploadResponse` (vracia guid a lastModified),
  `fetchSigned(guid:key:ifModifiedSince:) -> AVMPollResult` (`.pending` pri 304, `.signed(doc)` pri 200),
  `delete(guid:key:)`, `qrCodeURL(guid:key:) -> URL`. `baseURL` je parameter inicializátora,
  default `AVMClient.publicBaseURL`.
- `AVMSigningSession.swift`: `@Observable @MainActor final class` so stavom
  `enum State { idle, uploading, waitingForScan(qrURL: URL, qrImage: CGImage), downloading,
  signed(AVMSignedDocument), failed(String), cancelled }`. `start(request:)` nahrá dokument
  a polluje každú 1 s, timeout 15 min (`AVMError.timeout`). `cancel()` zruší `Task` a zavolá
  `delete`. Session je jednorazová (jeden dokument = jedna session = jeden QR kód).
- `QRCodeRenderer.swift`: CoreImage `CIQRCodeGenerator`, korekcia `M`, škálovanie na požadovanú
  veľkosť bez interpolácie, výstup `CGImage`.
- `AVMResultMapper.swift`: `AVMSignedDocument` -> `SignedConversionResult`
  (`pdfData` pri PAdES, `asicData` pri ASiC-E, `signatureLabel` zo `signers`,
  `isLegallyBinding` podľa kvalifikácie vydavateľa, `timestampGenTime` neznámy = nil) a
  `mandateCheck(signers:) -> Bool` cez existujúcu heuristiku
  `EngineBridgeSigningProvider.isMandateCertificate(issuer:displayName:)`.

### Mapovanie výstupov forku na AVM parametre

| Flow | Výstup forku | AVM upload |
|---|---|---|
| Podpisovanie, PAdES v PDF | PDF | `payloadMimeType: application/pdf`, `level: PAdES_BASELINE_B` alebo `_T` |
| Podpisovanie, ASiC-E | jeden PDF v kontajneri | `application/pdf`, `level: XAdES_BASELINE_B|T`, `container: ASiC-E` |
| ZaKo | PDF + doložka XML v ASiC-E | nepodpísaný kontajner z `ASiCEPackager.zakoContainer`, `payloadMimeType: application/vnd.etsi.asic-e+zip`, `level: XAdES_BASELINE_B|T` |

Časová pečiatka: úroveň `_T` podľa `includeQualifiedTimestamp`. Prvý reálny test overí,
či server pečiatku pridá bez ohľadu na prepínač v appke. Ak nie, výsledok sa označí
`hasQualifiedTimestamp = false` a používateľ dostane upozornenie; flow neblokuje.

ZaKo kontajner: prvý reálny test overí, že server podpíše nepodpísaný ASiC-E so všetkými
súbormi jedným XAdES podpisom. Ak nie, náhradou je upload samotného PDF s `container: ASiC-E`
a doložka sa priloží do kontajnera dodatočne cez `ASiCEPackager` (druhý podpis by potom
vyžadoval ďalší QR kód; toto sa rozhodne až po teste a nie je súčasťou prvej fázy).

Viditeľný podpis: fork ho vypaľuje do PDF lokálne pred podpisom (`VisibleSignatureStamper`),
rovnako ako pri karte. AVM `visibleSignature` parametre sa nepoužívajú.

### AutogramApp

- `MobileSigningCoordinator.swift` (`@Observable @MainActor`): vlastní `AVMSigningSession`,
  vystavuje `state`, `qrImage`, `start(...)`, `cancel()`. Vytvára `AVMClient` z nastavení.
- `SigningSessionStore.sign(viaMobile: Bool)`: príprava dokumentu (pečiatka, PDF/A) je
  spoločná; pri `viaMobile` sa namiesto `signingProvider.sign` zavolá koordinátor a čaká sa
  na `signed`. Uloženie, `queue` a `signedOutputURL` ostávajú rovnaké.
- `ZakoSessionStore.authorizeAndSign(viaMobile: Bool)`: rovnaký princíp; po podpise
  `mandateCheck`, pri neúspechu `lastError` so slovenskou hláškou a bez zápisu do evidencie.
  Následne existujúca `ASiCEContainerVerifier` kontrola a zápis `EvidenceRecord`.
- `MobileSigningSheet.swift`: sheet s QR kódom (min. 240 pt), textom
  "Naskenujte QR kód iPhonom a podpíšte v aplikácii Autogram v mobile", stavovým riadkom,
  odpočtom timeoutu a tlačidlom Zrušiť. Po `signed` sa sheet zavrie sám.
- Tlačidlo "Podpísať mobilom" v `StickyActionBar` v `SigningPrepareView` (vedľa "Podpísať KEP")
  a v `AuthorizeView`. Skryté v DEMO režime a keď je prepínač v nastaveniach vypnutý.
- Nastavenia (`AppSettings`): `mobileSigningEnabled: Bool` (default true),
  `avmBaseURL: String` (default verejný server), sekcia "Podpisovanie mobilom" v `SettingsView`.

### Executable `avm-probe`

Nový `executableTarget` v `Package.swift`. Použitie:
`swift run avm-probe <súbor.pdf|kontajner.asice> [--level PAdES_BASELINE_T] [--container ASiC-E] [--out výstup]`.
Nahrá súbor, vypíše QR link a vykreslí QR kód do PNG v scratch adresári (cesta sa vypíše),
polluje, po podpise uloží výsledok a vypíše `signers`. Slúži na overenie pečiatky, ZaKo
kontajnera a mandátneho certifikátu proti reálnemu serveru pred UI prácou.

## Chybové stavy

- Sieť nedostupná alebo 5xx: `failed("Server Autogram v mobile je nedostupný.")`, retry ručne.
- 401 `ENCRYPTION_KEY_*`: programátorská chyba, `failed` s kódom.
- 422 pri uploade: `failed` so serverovou `message`.
- Timeout 15 min: `failed("Podpis z mobilu neprišiel včas.")`, dokument sa zmaže.
- Zrušenie používateľom: `cancelled`, dokument sa zmaže, flow sa vráti do prípravy.
- Podpis bez mandátneho certifikátu v ZaKo: odmietnuť, súbory neukladať, evidencia bez zmeny.

## Testy

- `AVMClientTests` (XCTest, `URLProtocol` mock): hlavičky a telo uploadu, 304 -> `.pending`,
  200 -> `.signed` s dekódovaným obsahom, chybový JSON -> `AVMError.server`, `qrCodeURL`
  percent-encoding kľúča.
- `AVMDocumentKeyTests`: dĺžka 32 bajtov, base64 dekódovateľné strict aj urlsafe.
- `AVMResultMapperTests`: PAdES vs ASiC-E mapovanie, `mandateCheck` na vzorových `signers`.
- `QRCodeRendererTests`: nenulový obrázok požadovanej veľkosti.
- `AVMSigningSessionTests`: prechod stavov s mockom klienta, cancel volá delete, timeout.
- Reálny e2e beh cez `avm-probe` s eID používateľa (manuálne, zapíše sa do plánu ako
  kontrolný bod pred UI fázou).

## Mimo rozsahu

Push notifikácie a registrácia integrácie, vlastný AVM server, Quick Action, hromadný
podpis jedným QR kódom (viac súborov = viac QR kódov, sekvenčne cez existujúcu frontu).

## Overené na serveri

- 2026-09-11, `avm-probe` proti `https://autogram.slovensko.digital/api/v1` bez telefónu:
  `POST /documents` s PDF a `PAdES_BASELINE_T` vrátil 200 a GUID, polling `GET /documents/{guid}`
  s `If-Modified-Since` vracal 304, `DELETE` po timeoute prešiel. QR link a PNG sa vygenerovali.
- 2026-09-11, kontrola kódovania: `payloadMimeType` musí niesť príponu `;base64`
  (`application/pdf;base64`), inak server obsah zakóduje do base64 druhýkrát (overené cez
  `GET /documents/{guid}`: s príponou 593 B a `%PDF`, bez nej 792 B base64 textu). `DELETE` vracia 204.
- 2026-09-11, prvý podpis s iPhonom a eID (PDF, `PAdES_BASELINE_T`): podpísané PDF prišlo
  za pár sekúnd, CMS obsahuje `signatureTimeStampToken`, takže `_T` pri uploade pečiatku
  vynúti bez ohľadu na prepínač v appke. `signers.signedBy` a `issuedBy` sú celé RFC 2253 DN
  (napr. `CN=SVK eID ACA2, O=Disig a.s., ...`), `Qualified: true`, `Mandate: false` pre osobný certifikát.
- 2026-09-11, kontajnery: nepodpísaný ASiC-E server odmietne s 422
  `UNPROCESSABLE_INPUT: Parameters.Level can't be empty if document is not signed yet`
  (pri ASiC vstupe zahodí úroveň, počíta so už podpísaným kontajnerom). PDF s
  `container: ASiC-E` a `XAdES_BASELINE_B` prešlo: vrátený `.asice` má mimetype ako prvú
  položku, manifest s koreňom `/` a `META-INF/signatures001.xml`, takže prejde
  `ASiCEContainerVerifier`. ZaKo cez mobil preto posiela finálne PDF/A (s vloženou doložkou
  XML) s `container: ASiC-E`; XDCF sa ukladá vedľa kontajnera ako doteraz, ale nie je v ňom
  podpísaný. Či to pre zaručenú konverziu stačí, je právne rozhodnutie používateľa.
- Zostáva overiť: či DN mandátneho certifikátu obsahuje "mandát" alebo "oprávnenie"
  (heuristika `isMandate`); vyžaduje mandátny certifikát na eID.
