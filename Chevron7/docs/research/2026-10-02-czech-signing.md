# Czech qualified signatures and cards in Chevron7 (research, 2026-10-02)

Research only: no code was changed. Four parallel passes covered the Czech eID card and state identity, Czech trust service providers and their devices, the Czech legal framework, and the Chevron7 code paths a Czech card would touch. Evidence levels used below:

- **[primary]** statute text, the Czech trusted list (`TSL_CZ.xtsl`, sequence 182 of 2026-09-14), or a provider's or authority's own document;
- **[observed]** checked on the Mac Studio on 2026-10-02 (installed files, code signatures, HTTP probes). No signature with a Czech card was made;
- **[secondary]** press, forums or search snippets;
- **[inference]** a conclusion drawn from the above.

## 1. Summary

1. **Signing with Czech cards is realistic and mostly a driver, PIN and timestamp question.** The signing engine already lists the eObčanka, I.CA SecureStore and MONET+ ProID+Q libraries on macOS, DSS loads the Czech trusted list by default, and the hardened-runtime entitlements already allow third-party PKCS#11 libraries. What is missing is listed in section 7.
2. **Czech guaranteed conversion is out of reach for third-party software.** Czech "autorizovaná konverze" is performed only inside the state Czech POINT system; the number comes from the Digitální a informační agentura (DIA) and there is no API for advocates' own software [primary: Decree 193/2009 §2(1), Act 300/2008 §26]. ZaKo has no Czech port today. The same holds for advocates' eLegalizace (Decree 186/2025, since 1 July 2025).
3. **The default format must depend on the country.** Czech courts want PAdES inside PDF/A; Městský soud v Praze explicitly refuses ASiC-E [primary: court e-filing page]. The data box system accepts ASiC-E, so "sendable via data box" and "accepted by the court" are different checks.
4. **A signature need not be qualified towards Czech authorities.** Act 297/2016 §6 requires an "uznávaný elektronický podpis": an advanced signature based on a qualified certificate, or a qualified one [primary]. A Slovak QES qualifies as well [inference from §6(2) and eIDAS Art. 25(3), untested in practice].
5. **There is no Czech counterpart to Autogram v mobile or eIdentita.** Remote qualified signing exists only commercially and behind contracts (I.CA RemoteSign, eIdentity QSIGN via Bank iD, Software602 SecuSign). The EU Digital Identity Wallet is the only future free candidate, at the earliest in 2027, with no published API.
6. **Two existing bugs surfaced that hurt Slovak users today** and block Czech TSAs; they are filed as their own task (section 7.1).

## 2. Czech legal framework

### Signatures, seals, timestamps (Act 297/2016 Sb., version from 1 April 2023) [primary]

| Who signs | Requirement |
|---|---|
| Public-law signer (state, municipalities, bodies acting in their powers) | Qualified electronic signature (§5) or qualified seal (§8), plus a qualified timestamp (§11) |
| Anyone acting towards a public authority | "Uznávaný podpis": AdES on a qualified certificate, or QES (§6); "uznávaná pečeť" for seals (§9) |
| Private parties between themselves | Any signature or seal type (§7, §10) |

- Private filers have no statutory duty to add a qualified timestamp. Baseline B is legally enough; Baseline T (with a qualified timestamp) is the robust default.
- Long-term validation is the receiving authority's job (Decree 259/2012 §4(4)-(5), Act 499/2004 §69a). No Czech rule requires LT or LTA from the filer.
- Formats follow EU law: CID 2015/1506 today, replaced by CIR (EU) 2026/248 from 23 February 2027 (XAdES, CAdES, PAdES baseline profiles, JAdES, ASiC; older formats recognised if created before 23 February 2028).
- Under eIDAS Art. 41(3) a qualified timestamp from any Member State counts in Czechia, so the free EU qualified TSAs already built into Chevron7 (BOSA, Disig) are acceptable.

### Data boxes (ISDS) [primary unless marked]

- Advocates have a data box by law (Act 300/2008 §4(1)). A filing sent from one's own data box has the effect of a signed written act (§18(2)); civil procedure waives the signature for it (o.s.ř. §42(4)). Attachments that may later need conversion still need the originator's uznávaný signature (§24(4)(g)).
- Delivery happens at login or by fiction after 10 days (§17(3)-(4)).
- Formats (Decree 194/2009, Annex 3, version from 1 January 2026): PDF, PDF/A, XML, ZFO, office formats, images, ISDOC and more; ZIP and ASiC (asics, scs, asice, sce) allowed under limits (unencrypted, at most 1,000 entries, nesting depth 4, 3 GB unpacked).
- Size: 20 MB per regular message; up to 100 MB as a high-volume message (VoDZ) through separate services; at most 100 attachments.
- A saved message (ZFO) is a CMS/PKCS#7 envelope sealed by DIA; DSS can validate it.
- API: SOAP web services (`dm_operations`, `dm_info`, `db_search`, `db_access`), endpoints on `ws1.datovka.gov.cz` (basic auth) and `ws1c.datovka.gov.cz/cert/` (system certificate, recommended). The old `mojedatovaschranka.cz` endpoints run until 31 December 2027. Test environment: `datovka-test.gov.cz`; full specs after registration at poradnaisds.cz. Identita občana login is not available to third-party apps.

### Courts [primary unless marked]

- Channels: data box, e-mail, ePodatelna (epodatelna.justice.cz), online forms. Without a signature equal to a handwritten one, the original must follow within 3 days (o.s.ř. §42(2)).
- OS Znojmo (1 January 2025): PDF, PDF/A, office formats, ZFO; internal (enveloped) signatures recommended; no ASiC listed.
- MS Praha: ASiC-E and ASiC-S explicitly unacceptable; foreign EU qualified signatures accepted.
- Electronic court file (eSpis) pilots from Q4 2026, other agendas from 2027 [secondary].
- There is no national equivalent of the Slovak eForm and XDC container. A signer may meet Software602 `.fo`/`.zfo` forms (Windows tooling), ISDS ZFO messages, CAdES `.p7s` for tax XML (EPO / MOJE daně) [secondary], and the commercial register's "inteligentní formulář" PDF [secondary].

### Conversion and eLegalizace [primary]

| | Slovakia (zaručená konverzia) | Czechia (autorizovaná konverze) |
|---|---|---|
| Performed in | Advocate's own software | Czech POINT information system only |
| Number | Allocated by EZZK over SOAP | Assigned centrally by DIA |
| Signature | SAK mandate certificate | Performer's personal QES (or qualified seal if automated) |
| Output | ASiC-E: PDF/A plus XML clause (XDC); record XDC | PDF/A-2 or later with the doložka and a barcode |
| Register | EZZK / CEZZK | DIA register, 10 years, public doložka lookup |
| Advocates' access | Own account in EZZK | Via ČAK: 1,209.70 Kč setup plus 295 Kč a year; commercial and qualified certificate on a QSCD; Windows, Adobe Reader and 602XML Filler assumed |

DIA's FAQ of 12 March 2026 says direct conversion access for advocates is being worked on. Watch it; nothing is published.

## 3. Czech providers on the trusted list [primary: TSL_CZ, 2026-09-14]

| Provider | Qualified certificates | Qualified timestamps | Remote signing |
|---|---|---|---|
| I.CA (První certifikační autorita, a.s.) | EU Qualified CA2/RSA and CA2/ECC 06/2022 (plus older CAs) | Yes, newest TSU4/5/6 03/2026 | I.CA RemoteSign, RemoteSeal |
| Česká pošta (PostSignum) | Qualified CA 4, CA 5, ECC R1 CA1/CA3 | Yes, newest TSU 4/5/6 | No |
| eIdentity a.s. | ACAeID3.1-3.3 (also certificates without a QSCD, sold for "zaručený podpis") | Yes, TSA3 | QSIGN |
| Komerční banka | Qualified CA/RSA (listed 2026-08-09) | Yes | No |
| SSSVD, SZR (state) | NCA SubCA1 RSA and ECC | Yes | No (eligibility unverified) |
| Software602, SEFIRA | No CA | No | SecuSign; OBELISK Remote Sign |

Remote-signing entries all show a status start in 2026, which is when the list began carrying that service type, not the launch date.

## 4. Devices and middleware on macOS

| Device | Middleware | macOS and Apple Silicon | PKCS#11 library | CryptoTokenKit | PIN model and quirks |
|---|---|---|---|---|---|
| **I.CA Starcos 3.7** (C1 until 2027, C3 until 2029; also used by SAK) | SecureStore 8.3.1 (one macOS build for CZ and SK) | Universal x86_64 + arm64, Developer ID [observed] | `/usr/local/lib/pkcs11/libICASecureStorePkcs11.dylib` [observed] | Yes | Own PIN dialog with shuffled keyboard; separate qualified ("esign") area with its own PIN cache setting |
| **eObčanka** (cards from 1 July 2018 are a QSCD) | eObčanka 3.7.0 (MONET+ for DIA), signed and notarized | Native M1 since 3.3.2 (Dec 2022); macOS 13 to 26 listed on one page, 15 on another; macOS 27 not stated | `/usr/local/lib/eOPCZE/libeopproxyp11.dylib` (proxy for both chip generations) | Yes | **QPIN for every qualified signature, never cached**; driver shows its own PIN window; PIN, QPIN, PUK, IOK, DOK are different codes |
| **MONET+ ProID+Q** (PostSignum, also the basis of the Komerční banka card) | ProID+ client | macOS 10.13.5+; Apple Silicon not stated | `/usr/local/lib/ProIDPlus/libproidqcm11.dylib` | Yes | Separate PIN and QPIN; certificate request needs Windows |
| **Thales SafeNet eToken 5110 CC, IDPrime 940/941/3940** (PostSignum, eIdentity) | SafeNet Authentication Client 10.9 | macOS 15 supported; macOS 26/27 and arm64 unverified | `/usr/local/lib/libeTPkcs11.dylib` | Via SAC | Separate QPIN for the qualified area; eIdentity's request plug-in does not support macOS |
| **Bit4id TokenME EVO** (PostSignum) | Bit4id PKI Manager | PostSignum links a macOS DMG from 2017 [observed]; arm64 unverified | `/Library/bit4id/pkcs11/libbit4xpki.dylib` | Yes | Uninstall old Bit4id software first |

Also observed on this Mac: an old Gemalto IDGo800 PKCS#11 (`/usr/local/lib/libidprimepkcs11.0.dylib`) that is x86_64 and i386 only, so it cannot load in an arm64 process. It does not trigger the driver-list bug of section 7.1 here, because the engine looks for `/usr/local/lib/libIDPrimePKCS11.dylib`, which does not exist on this Mac; a newer IDPrime install at that path without an arm64 slice would.

### The eObčanka in detail

- Cards issued 2012 to June 2018 had an optional chip and are not a certified QSCD [inference]. Cards since 1 July 2018 carry a contact chip certified as a QSCD (Thales IAS Classic on MultiApp V4/V5); the contactless chip on biometric cards since August 2021 does not do eID or signing [primary: DIA, press].
- The chip holds 16 key containers (4 RSA and 4 ECC for qualified certificates, the same for authentication). Qualified keys are generated on the chip.
- **No signing certificate is preinstalled.** The holder buys one from PostSignum (about 440 Kč per year on PostSignum's FAQ; other sources quote 490 Kč) or I.CA (current eOP offer unverified). eIdentity is named by DIA but has no macOS support.
- **Enrolment is the bottleneck, not signing:** PostSignum's iSignum for macOS says qualified devices are not supported, eIdentity has no macOS tools, and I.CA's Mac guide lists only its own cards. A Mac-only user needs Windows once to create the key and request [inference].
- Middleware security: CVE-2026-59111 (CVSS 9.3, command injection through `czeeopauth://` before 3.6.0). Require 3.6.0 or later, recommend 3.7.0. Card not seen on recent macOS: DIA's fix is `useIFDCCID`.
- The Czech **BOK** is a code for identification at an office, not a chip PIN. Do not reuse the Slovak eID BOK logic.
- Uptake: 876,000 eObčanka identity means versus 1.2 million Mobilní klíč and millions of bank identities (DIA, February 2026); no figure for qualified certificates on cards. Professionals mostly use commercial tokens [inference].
- Evidence of the gap: in August 2026 a Czech developer published his own arm64 PAdES signer (EasySigner) because no usable macOS tool for the eObčanka existed [secondary].

## 5. Remote and mobile signing

| Option | How it works | Usable by Chevron7? |
|---|---|---|
| I.CA RemoteSign | HSM with signature activation, approval in the I.CA app; integration through I.CA's RSiCON connector | Only with a third-party contract; no public API or price. Also covers Slovak qualified and **Slovak mandate** certificates |
| eIdentity QSIGN / Bank iD QSIGN | Redirect to bank login, one-time qualified certificate, signing on the provider side | Only as a vetted relying party (Bankovní identita review); web flow |
| Software602 SecuSign | SOAP and .NET SDK, HSM | Price on request |
| SEFIRA OBELISK Remote Sign | No technical detail found | Unknown |
| NIA, Mobilní klíč eGovernmentu, eObčanka mobile app | Identification only | No signing |
| EU Digital Identity Wallet (Czech launch planned around the turn of 2026/2027) | QES free of charge for natural persons by law (Reg. 2024/1183 Art. 5a(5)(g)) | No API published yet; revisit in 2027 |

No Czech provider was found offering the Cloud Signature Consortium (CSC) API.

## 6. Qualified timestamps

| Provider | Endpoint | Access | Notes |
|---|---|---|---|
| PostSignum | `https://www.postsignum.cz/TSS/TSS_user/` (and www3; backups postsignum.eu, www4) | HTTP Basic [observed]; client-certificate variant `TSS_crt` | Prepaid packages without contract (350 stamps for 847 Kč); TLS chains to DigiCert; demo server currently out of service |
| I.CA | `https://tsabase.ica.cz/cgi-bin/razitko_base2.cgi` (Basic); `https://tsa.ica.cz/cgi-bin/razitko2.cgi` (client certificate) | HTTP Basic [observed] | **TLS chains to the private "I.CA TLS Root CA/RSA 05/2022", missing from macOS and from the engine's Java cacerts** [observed]; test TSA on request |
| eIdentity | `/api/HttpTspServer` on an unpublished host | Client certificate | Up to 50 stamps with personal certificate packages |

Every Czech qualified TSA needs credentials. The free EU qualified TSAs already in Chevron7 remain valid for Czech documents, so Czech TSAs are an option, not a requirement.

## 7. What Chevron7 needs

Scope: Podpisovanie (single and batch), the Finder Quick Action, and validation. ZaKo, EZZK and the mandate certificate stay Slovak.

### 7.1 Existing bugs found on the way (filed as a separate task)

1. **One driver without an arm64 slice empties the whole driver list.** `AutogramCLIEngine.drivers()` resolves all candidates inside one throwing `compactMap`, and `DriverResolver.resolve` throws `arm64Required` for any Intel-only library. One old Czech (or any) middleware hides the Slovak eID and I.CA cards too. Fix: resolve per driver. The I.CA minimum-version check (`MiddlewareRequirementValidator`) also never runs.
2. **The TSA chosen for main-window, batch and browser signing never reaches the engine.** The stores set `request.tsaURL`, but `EngineBridgeSigningProvider` forwards only `timestampServers`, so the engine always uses BOSA plus Sectigo. TSA credentials are dropped in `AutogramCLIEngine` (authentication always nil). Any Czech TSA with a login depends on this fix.

### 7.2 Minimum changes to sign with a Czech card

1. **PIN handling by token, not by driver name.** `EngineBridgeSigningProvider.requiresPIN` is `driverID != "eid"`; `usesProtectedAuthenticationPath`, `enginePIN` and `signsWithoutCertificateDiscovery` derive from it. Read `CKF_PROTECTED_AUTHENTICATION_PATH` from `C_GetTokenInfo` in `PKCS11TokenPresenceProbe` and pass it in the DRIVERS payload (`MachineDriverService.driverPayload`), then derive the app's behaviour from it.
2. **QPIN per signature.** The eObčanka and the qualified areas of SafeNet and ProID+Q ask for a separate signing PIN for every signature (`CKA_ALWAYS_AUTHENTICATE`). The engine already performs the context-specific login (`NativePkcs11SignatureToken`), but the app's "PIN for the app run" model, batch signing and the UI wording (PIN versus QPIN; blocking after 3 tries) must account for it. Test first whether the middleware shows its own QPIN window when the app supplies a secret.
3. **Driver list in the engine** (`DefaultDriverDetector.getMacDrivers`): keep eObčanka (verify the path and arm64 against 3.7.0), add SafeNet SAC `/usr/local/lib/libeTPkcs11.dylib` and Bit4id `libbit4xpki.dylib`; check whether the existing `libIDPrimePKCS11.dylib` entry exists with SAC only. List order is the only priority, so place entries on purpose. Add Czech help texts (today hardcoded Slovak, `HELPER_TEXT_CZ_EID` empty).
4. **Trusted-list countries.** CZ is in the default set, but `MachineSettings` inherits `TRUSTED_LIST` from the Java Preferences node shared with an installed upstream Autogram; pin the set so CZ cannot silently disappear.
5. **I.CA TSA trust.** Add I.CA's private TLS root (or pin it, as the EZZK test environment does) before offering `tsabase.ica.cz`; store Basic credentials in the Keychain.
6. **Labels.** `cardKindLabel` and `issuerHint` match "eID" inside "eIdentity" and would call an eIdentity certificate a Slovak ID card; add Czech card labels (eObčanka, PostSignum, eIdentity).
7. **Quick Action.** `chevron7-quick-action.sh` offers only I.CA SecureStore and the Slovak eID; add the Czech drivers and generalise the error texts.
8. **Browser panel PIN window.** `WebSigningPrompt.isEIDKeyboard` recognises only the Slovak eID client's `VirtualKeyboard`; other middleware PIN windows get no focus help. Only relevant once a Czech portal path exists.
9. **ECC.** Czech issuers run ECC qualified CAs and cards hold P-256 to P-521 keys; confirm the engine's PKCS#11 path signs ECDSA with these curves.
10. **Format default per country.** Offer PAdES (B-T) in PDF/A as the default for Czech recipients and warn before sending ASiC-E to a Czech court.
11. **Tests.** `EngineBridgeTests` and `SmartcardBadgeTests` encode the "eid" and "secure_store" assumptions; extend them for the new drivers and labels.

### 7.3 Nice to have

- A driver picker and per-driver slot index in Settings; show the trusted-list countries.
- Localization: there is no string catalog; about 526 hardcoded Slovak UI literals, Slovak visible-stamp text, `sk_SK` date formats, extension `_locales/sk` only. Czech UI needs a String Catalog and `cs` in `CFBundleLocalizations`.
- Validation of incoming ZFO (data box messages) and CAdES `.p7s`.
- A Czech counterpart to "Overiť aj na slovensko.sk" (DIA validation service or the doložka lookup).
- ISDS (data boxes) for LawOSS rather than Chevron7: inbox, delivery-fiction deadlines, archiving with `ArchiveISDSDocument`.

### 7.4 Verify on real hardware before building

| Question | Device |
|---|---|
| arm64 slice and behaviour on macOS 27 of eObčanka 3.7.0, SafeNet SAC 10.9, Bit4id, ProID+ | Each middleware on the Mac Studio |
| Does each token report a protected authentication path, and does the middleware show its own QPIN window? | eObčanka with a PostSignum certificate; eToken 5110 CC; ProID+Q |
| Exact issuer CN strings and QC statements | Certificates from I.CA CZ, PostSignum, eIdentity |
| ECDSA signing with P-384/P-521 keys | A Czech ECC qualified certificate |
| Timestamp with Basic auth from PostSignum and I.CA | Prepaid PostSignum package; I.CA test TSA (tsa@ica.cz) |

Practical note for users: PostSignum and eIdentity certificate requests need Windows; I.CA issues and renews inside SecureStore on macOS.

## 8. Suggested order

1. Fix the two bugs in 7.1 (helps Slovak users now).
2. Czech I.CA cards: same middleware as the Slovak ones, so mostly labels, issuer detection and tests; cheapest first step.
3. PIN by token flag plus QPIN handling, then SafeNet (PostSignum, eIdentity) and the eObčanka, each verified on hardware.
4. Country-aware format default (PAdES in PDF/A for Czech recipients).
5. Optional Czech TSAs with credentials and the I.CA trust root.
6. Later: Czech localization; EU wallet signing (2027); ISDS in LawOSS; watch DIA's "direct access" to conversion for advocates.

## Sources

**Czech law and EU**
- Act 297/2016 Sb.: https://www.zakonyprolidi.cz/cs/2016-297
- Act 300/2008 Sb.: https://www.zakonyprolidi.cz/cs/2008-300
- Decree 193/2009 Sb.: https://www.zakonyprolidi.cz/cs/2009-193
- Decree 194/2009 Sb.: https://www.zakonyprolidi.cz/cs/2009-194
- Act 85/1996 Sb.: https://www.zakonyprolidi.cz/cs/1996-85
- Decree 186/2025 Sb.: https://www.zakonyprolidi.cz/cs/2025-186
- Decree 259/2012 Sb.: https://www.zakonyprolidi.cz/cs/2012-259
- Act 499/2004 Sb.: https://www.zakonyprolidi.cz/cs/2004-499
- Act 99/1963 Sb. (o.s.ř.): https://www.zakonyprolidi.cz/cs/1963-99
- Act 12/2020 Sb.: https://www.zakonyprolidi.cz/cs/2020-12
- CIR (EU) 2026/248: https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX%3A32026R0248
- Reg. (EU) 2024/1183: https://eur-lex.europa.eu/eli/reg/2024/1183/oj
- eIDAS (Reg. 910/2014): https://eur-lex.europa.eu/eli/reg/2014/910/oj

**DIA, Czech POINT, ISDS, courts**
- Czech POINT conversion slides (12 March 2026): https://www.czechpoint.gov.cz/public/wp-content/uploads/2026/05/prezentace_CzP_konverze_dokumentu.pdf
- Conversion FAQ (2026): https://www.czechpoint.gov.cz/public/wp-content/uploads/2026/05/FAQ-ze-skoleni-konverze.pdf
- Doložka lookup: https://www.czechpoint.gov.cz/overovacidolozky/search.do
- DIA validation methodology: https://www.dia.gov.cz/cs/legislativa/eidas-sluzby-vytvarejici-duveru-a-elektronicka-identifikace/informace-pro-uzivatele/metodicky-navod-pro-overovani-platnosti-uznavanych-elektronickych-podpisu-a-elektronickych-peceti
- ISDS operating rules (26 June 2026): https://datovka.gov.cz/info/files/2245_Provozni_rad_ISDS_26_06_2026.pdf
- ISDS developer information: https://datovka.gov.cz/info/cs/2052.html
- ISDS domain move: https://datovka.gov.cz/info/cs/2063.html
- ISDS VoDZ, ZIP and ASiC: https://datovka.gov.cz/info/cs/1061.html
- OS Znojmo e-filing: https://msp.gov.cz/documents/d/okresni-soud-ve-znojme/elektronicka-podatelna-verze-k-1-1-2025
- MS Praha e-filing: https://msp.gov.cz/en/web/mestsky-soud-v-praze/kontakty-podrobnosti/-/clanek/elektronicka-podatelna
- ČAK conversion and eLegalizace: https://www.cak.cz/konverze-dokumentuelegalizace
- Czech POINT eLegalizace: https://www.czechpoint.gov.cz/public/verejnost/elegalizace/

**eObčanka and state identity**
- Signing with eOP: https://info.identita.gov.cz/eop/Podepisovani.aspx
- Downloads: https://info.identita.gov.cz/Download/
- macOS installation: https://info.identita.gov.cz/eop/InstalacemacOS.aspx
- macOS installation guide v1.90: https://info.identita.gov.cz/download/InstalacniPrirucka_eObcanka_macOS.pdf
- Card Manager guide v1.50: https://info.identita.gov.cz/download/UzivatelskaPrirucka_SpravceKarty_MacOS.pdf
- Card drivers: https://info.identita.gov.cz/eop/OvladaceKarty.aspx
- macOS software changes: https://info.identita.gov.cz/eop/ZmenySWMacOS.aspx
- Mobile app guide: https://info.identita.gov.cz/download/UzivatelskaPrirucka_eObcanka_Mobil.pdf
- NIA SeP handbook: https://info.identita.gov.cz/download/SeP_PriruckaKvalifikovanehoPoskytovatele.pdf
- eOP as QSCD (DIA): https://www.dia.gov.cz/cs/legislativa/eidas-sluzby-vytvarejici-duveru-a-elektronicka-identifikace/informace-pro-uzivatele/obcansky-prukaz-vydavany-od-1-7-2018-splnuje-pozadavky-na-kvalifikovany-prostredek-pro-vytvareni-elektronickych-podpisu
- Digital identity figures (DIA): https://www.dia.gov.cz/cs/aktuality/5-milionu-obcanu-jiz-vyuziva-svoji-digitalni-identitu
- EUDIW Q&A (DIA): https://www.dia.gov.cz/eudiw/cs/evropska-penezenka-v-cr/otazky-a-odpovedi
- EUDIW architecture: https://archi.gov.cz/nap:eudiw
- CVE-2026-59111: https://app.opencve.io/cve/CVE-2026-59111
- EasySigner: https://github.com/mkozarik-praha/EasySigner

**Providers, devices, timestamps**
- Czech trusted list: https://tsl.gov.cz/publ/TSL_CZ.xtsl
- I.CA SecureStore: https://www.ica.cz/en/secure-store
- I.CA SecureStore macOS guide: https://www.ica.cz/sites/default/files/download/2025/i.ca-securestore-8.1-macos-user_guide.pdf
- I.CA smart card certification: https://www.ica.cz/en/smart-card-certification
- I.CA RemoteSign: https://www.ica.cz/ica-remotesign-0
- I.CA timestamps: https://www.ica.cz/casova-razitka
- I.CA TSA testing: https://www.ica.cz/en/tsa-testing-procedure
- PostSignum qualified devices: https://www.postsignum.cz/kvalifikovane_prostredky.html
- PostSignum eOP certificate: https://www.postsignum.cz/elektronicky_obcansky_prukaz_s_cipem.html
- PostSignum iSignum for macOS: https://www.postsignum.cz/isignum_pro_macos.html
- PostSignum timestamps: https://www.postsignum.cz/casova_razitka.html
- PostSignum TSA client: http://www.postsignum.cz/files/tsa/TSA_klient.pdf
- eIdentity support: https://www.eidentity.cz/technicka-podpora/
- eIdentity price list: https://www.eidentity.cz/cenik/
- eIdentity QSCD validity notice: https://www.eidentity.cz/oznameni-o-koncici-platnosti-certifikace-qscd-prostredku/
- Bank iD QSIGN terms: https://bankid.cz/files/Bank_iD_QSIGN_podminky_v1.pdf
- ProID+ downloads: https://proid.cz/ke-stazeni/
- Bit4id macOS middleware: https://cdn.bit4id.com/es/middleware/MacOs/MacOS.html
- SafeNet Authentication Client updates: https://data-protection-updates.gemalto.com/category/safenet-authentication-client/
- Software602 SecuSign: https://www.602.cz/secusign
- SEFIRA OBELISK: https://www.sefira.com/en/produkty/product-digital-platform/obelisk-remote-signature/
