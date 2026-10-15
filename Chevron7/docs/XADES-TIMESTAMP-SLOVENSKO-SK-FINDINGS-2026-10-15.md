# XAdES signature timestamp ignored by slovensko.sk (2026-10-15)

## Observation

Chevron7 1.5.3, eID card of the owner, same day, same TSA setting (BOSA, the default):

- ASiC-E XAdES Baseline T (`Test dohoda_podpisane.asice`): slovensko.sk informative validation shows "Predbežne platný" (Kód stavu 3, Kód výsledku 17), type `XadesBPLevelT`, "Obsahuje časovú pečiatku: Nie", column "Bez časovej pečiatky".
- PAdES Baseline T of a PDF: "Platný" with its timestamp.
- A second ASiC-E (`Test dohoda 6_podpisane.asice`, about 15:38Z, a PR #83 test build with the content timestamp on) carries an `xades:AllDataObjectsTimeStamp` and a `xades:SignatureTimeStamp`, both from BOSA "Timestamp Unit 202302" (ECDSA chain, exc-c14n, SHA-512 imprint). slovensko.sk reported it exactly like the first: "Predbežne platný", 3 / 17, `XadesBPLevelT`, "Obsahuje časovú pečiatku: Nie". A PAdES from the same build (document timestamp plus signature timestamp, BOSA, SHA-512 imprints) was "Platný" with its timestamp listed.

DSS (our engine, 6.4) validates the same ASiC-E as `TOTAL_PASSED` with a valid QTSA timestamp. The container is correct; the Slovak validator does not see the timestamp.

## Cause (confirmed by the owner's uploads, see "Confirmation files")

The BOSA timestamp is signed with elliptic curves, which the Slovak XAdES validator does not support. The encoding of the timestamp (canonicalization, imprint algorithm) plays no part.

- Every BOSA unit is ECDSA. `tsa.belgium.be/connect` answers with "Timestamp Unit 202302": P-256 key, token signed `ecdsa-with-SHA256`, unit and "Timestamp CA" certificates signed `ecdsa-with-SHA384` up to "Belgium Root CA6" (P-384). The Belgian trusted list shows the same for all four BOSA units (EC1/EC2 TSU 2021, TSU 202301, TSU 202302).
- The central e-filing office (CEP) validates XAdES with Ditec's D.Verifier-SVR-XAdES and PAdES with a different component. Its documentation (Dokumentácia funkčnosti CEP v1.17, 10. 5. 2024, chapter 5.1 "Podporované kryptografické funkcie a algoritmy", page 14, columns PAdES / XAdES / CAdES) lists `ecdsaWithSHA256` for PAdES and XAdES, but `ecdsaWithSHA384` and `ecdsaWithSHA512` for PAdES only, and warns that an XAdES with EC-DSA is verified only when its certificates and revocation data are signed with RSA.
- NASES' notice "Zmeny v CEP: nové algoritmy" says a timestamp made with an unsupported algorithm is not detected at all. That is exactly "Obsahuje časovú pečiatku: Nie" while the signature type still reads `XadesBPLevelT`. Without a usable timestamp, the synchronous informative validation checks the signature against the current time, which is the "Predbežne platný" of chapter 5.1.4.1 / 5.1.4.5 (a).
- This explains why PAdES with the very same BOSA unit was accepted: the PAdES component supports `ecdsaWithSHA384`.
- Upstream Autogram noticed the same: in its PR slovensko-digital/autogram#597 (July 2025, which changed the default TSAs mainly because tsa.sep.bg stopped answering) the author noted in testing that on slovensko.sk a signature timestamped by the Belgian TSA showed an error while the new defaults did not. Upstream now defaults to Sectigo Qualified first and keeps BOSA second (`UserSettings.DEFAULT_TSA_SERVER`).

## Ruled out

- Trusted list: TSU 202302 is listed directly and granted in the Belgian list (CEP chapter 5.1.4.3 refuses a unit that is only issued by a listed service).
- Wrong imprint: the token's message imprint equals SHA-512 of the exclusive-c14n `ds:SignatureValue`, as the element's `ds:CanonicalizationMethod` declares. Inclusive c14n would give another value (it adds the inherited `xmlns:asic`).
- Profile conformity: XAdES_ZEPbp v1.0 (Ditec, 4.3.1.1 and 4.4.5.1) allows c14n, c14n11 and exc-c14n and only requires the timestamp to name its canonicalization; CEP lists SHA-512 as supported for XAdES.
- Encoding: DSS defaults the XAdES timestamp to exclusive c14n and a SHA-512 imprint (`XAdESTimestampParameters`, `TimestampParameters`), and the engine never overrides them, while Ditec-made containers use inclusive c14n and SHA-256. The uploads show this does not matter: B (BOSA, inclusive, SHA-256) failed like A, and C (Sectigo, exclusive, SHA-512) passed like D. No engine change is needed.
- Trusted list rule for Sectigo: its Spanish list entry names the CA rather than the signing unit, which CEP 5.1.4.3 calls invalid, but C and D were accepted with their timestamp, so the rule does not hit Sectigo for XAdES.

## Impact

- Every XAdES signature with a timestamp from BOSA, the default (`TimestampAuthority.legacyDefaultURL`): main window ASiC-E, batch ASiC-E, extended containers.
- ZaKo outside Demo always passes `TimestampAuthority.qualifiedURLs` with BOSA first (`ZakoSessionStore`), so the client ASiC-E (PDF/A plus clause) of every guaranteed conversion carries a timestamp CEP does not see. The record container sent to EZZK has the same timestamp; how EZZK evaluates it is unknown.
- PAdES is not affected.
- The content timestamp of PR #83 (AllDataObjectsTimeStamp) comes from the same TSA, and CEP does not report content timestamps at all (chapter 5.1.4.3).

## Choosing a replacement is the owner's decision

| Built-in | Unit key | Listed directly in its TL | Free | CEP risk |
| --- | --- | --- | --- | --- |
| BOSA | ECDSA P-256, chain ECDSA-SHA384 | yes | yes | XAdES timestamp invisible (this report) |
| Sectigo Qualified | RSA 4096, `sha384WithRSAEncryption` | no: the Spanish list names "Sectigo Qualified Time Stamping CA R35", not "Signer #3" | yes | XAdES accepted with its timestamp (files C, D); PAdES not yet uploaded |
| CA Disig | RSA (TSU 1 to 3, aTSU 1 to 3) | yes | no, contract | none known |

Other RSA units listed directly in the Slovak list: NASES, Ardaco, NFQES, MO SR (none public and free as far as known).

## Confirmation files

Built from the owner's real signature by replacing only the unsigned `xades:SignatureTimeStamp` (everything up to `xades:UnsignedProperties` byte-identical, so the card signature stays valid; DSS 6.4 rates all four `TOTAL_PASSED` with a valid QTSA timestamp). They sit in the shared notes folder `xades-timestamp-test-files/` (not in the repository, they carry the owner's signature):

| File | TSA | c14n | Imprint | Expected if ECDSA is the cause | slovensko.sk, 2026-10-15 |
| --- | --- | --- | --- | --- | --- |
| `A_original_BOSA_exclusive_sha512.asice` | BOSA | exclusive | SHA-512 | Nie | Predbežne platný (3 / 17), "Obsahuje časovú pečiatku: Nie", "Bez časovej pečiatky" |
| `B_BOSA_inclusive_sha256.asice` | BOSA | inclusive | SHA-256 | Nie | as A |
| `C_Sectigo_exclusive_sha512.asice` | Sectigo | exclusive | SHA-512 | Áno, unless the 5.1.4.3 listing rule hits Sectigo | Platný (1 / 0), "Obsahuje časovú pečiatku: Áno", 15. 10. 2026 15:51 UTC, `XadesBPLevelT` |
| `D_Sectigo_inclusive_sha256.asice` | Sectigo | inclusive | SHA-256 | as C | as C |

Result: B "Nie", C and D "Áno", the second case below. ECDSA is confirmed as the cause and Sectigo works for XAdES.

Reading the results:

- B shows a timestamp: the encoding is the cause, not ECDSA. Then set the engine's signature timestamp to inclusive c14n and SHA-256 (`SigningParameters`, `getSignatureTimestampParameters()`).
- B "Nie", C and D "Áno": ECDSA confirmed and Sectigo works for XAdES. Then make Sectigo the default for XAdES (or for everything after a PAdES check with Sectigo selected in Settings) and put it first in `qualifiedURLs` for ZaKo.
- C "Nie", D "Áno": both the TSA and the encoding matter; do both changes.
- C and D "Nie": Sectigo is refused too (likely the listing rule); only a directly listed RSA authority such as CA Disig works, which needs a contract and credentials support.

Still open: a PAdES signed with Sectigo selected in Settings, before Sectigo becomes the default for PAdES too.

## Decision and change (2026-10-15)

The owner: Sectigo Qualified as the default only for ASiC-E (XAdES) and ZaKo; PAdES stays on BOSA until a PAdES with Sectigo is checked on slovensko.sk.

- An XAdES signature never takes BOSA: `TimestampAuthority.authorityURL(forSelected:signsXAdES:)` swaps BOSA for Sectigo for the signature timestamp and the content timestamp, in the main window, the batch (by its format), an extended container and the browser panel, and the engine provider applies the same rule to whatever `tsaURL` it receives.
- ZaKo outside Demo hands the engine `TimestampAuthority.xadesQualifiedURLs` (Sectigo, then CA Disig), so neither the client ASiC-E nor the record container can get BOSA.
- The stored choice is not migrated. A stored BOSA is the shipped default for almost everyone and cannot be told apart from a deliberate pick, and no one has a reason to want an XAdES timestamp slovensko.sk cannot see, so BOSA chosen means BOSA for PAdES and Sectigo for ASiC-E, which the pickers and Settings say under the choice. Another built-in (Sectigo, CA Disig) and every custom URL are sent as chosen.

## Method

Imprint recomputed with lxml c14n over `ds:SignatureValue` and compared with `openssl ts -reply -token_in -text`; TSA chains and trusted list entries read with openssl from `~/Library/Caches/Chevron7/Trusted Lists`; live sample tokens requested from each built-in authority; survey of every `.asice` on this Mac (timestamp c14n, imprint algorithm, unit); comparison files validated with the installed engine's machine protocol v2 `VALIDATE`.

Sources: Dokumentácia funkčnosti Centrálnej elektronickej podateľne v1.17 (slovensko.sk), Profil XAdES_ZEPbp v1.0 and Profil XAdES_ZEP v2.0 (ditec.sk), NASES "Zmeny v CEP: nové algoritmy" (slovensko.sk), slovensko-digital/autogram PR #597 and `UserSettings.java`.
