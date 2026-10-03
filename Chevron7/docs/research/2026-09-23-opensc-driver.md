# OpenSC as a signing driver: findings

Status (2026-10-03): **not pursued.** A branch (`feature/opensc-driver`, 2026-09-23) offered OpenSC as a PKCS#11 driver next to the vendor middleware. It was never merged and was deleted on 2026-10-03, because OpenSC recognised neither the owner's eID (IDEMIA Cosmo 9.2) nor the I.CA SAK card, so the driver option could not sign with any card in use. The eID klient and I.CA SecureStore stay the only drivers. Revisit only if OpenSC gains a driver for the Cosmo generation, or for eID v3 (CardOS 5.4) cards after a real-card test.

## What OpenSC is (verified)

| Fact | Source |
|---|---|
| Open-source smart card middleware (PKCS#11 module, Windows minidriver, macOS CryptoTokenKit token), LGPL-2.1, actively maintained | https://github.com/OpenSC/OpenSC |
| Latest release 0.27.1 (2026-03-31), ships `OpenSC-0.27.1.dmg` for macOS | https://github.com/OpenSC/OpenSC/releases |
| The macOS installer puts the PKCS#11 module in `/Library/OpenSC/lib/opensc-pkcs11.so` (copies in `/usr/local/lib`) and installs the CryptoTokenKit plugin (OpenSCToken) for native apps | https://github.com/OpenSC/OpenSC/wiki/macOS-Quick-Start |
| Slovak eID driver `card-skeid.c` and emulator `pkcs15-skeid.c`, added 2023-03-22 (PR #2672, Juraj Šarinay), last touched 2026-04-24 | `src/libopensc/card-skeid.c`, `src/libopensc/pkcs15-skeid.c` in the OpenSC repo |

What the skeid driver declares (read from the source, not tested):

- It matches exactly one ATR, `3b:d2:18:00:81:31:fe:58:c9:04:11` ("Slovak eID v3, CardOS 5.4"), and then checks the card's CIF URL `http://www.minv.sk/cif/cif-sk-eid-v3.xml`. Other card generations are not matched.
- Three certificates: "Kvalifikovany certifikat pre elektronicky podpis", "Certifikat pre elektronicky podpis", "Sifrovaci certifikat".
- Two PINs: `BOK` (reference 0x03, path `3F00`, max 6 digits, 5 tries) and `Podpisovy PIN` (reference 0x87, path `3F000101`, local, max 10 digits, 3 tries).
- Three RSA 3072 keys. `Podpisovy kluc (KEP)` (non-repudiation + sign) is guarded by the **Podpisový PIN** and has `user_consent = 1`, which OpenSC exposes as `CKA_ALWAYS_AUTHENTICATE`. The other signing key and the decryption key are guarded by the BOK.
- Signing uses `MSE RESTORE`, following the vendor driver; algorithms RSA PKCS#1 v1.5 without hashing on card. The driver has no PACE code, so it reaches the card only through a contact reader, never over NFC.


## Research prompts

Each prompt is self-contained: paste it into a fresh session in this repository. Write the answer back into this file (section "Findings") with sources and the date, and turn verified facts into tasks.

### A. Which eID generations does OpenSC recognise?

> Context: Chevron7 (this repo) wants to sign with the Slovak eID through OpenSC. OpenSC's `src/libopensc/card-skeid.c` matches only ATR `3b:d2:18:00:81:31:fe:58:c9:04:11` (eID v3, CardOS 5.4) plus the CIF URL `http://www.minv.sk/cif/cif-sk-eid-v3.xml`. Question: which Slovak identity card generations with the electronic chip are in circulation today (issue dates, chip platform, ATR), and which of them this driver matches? Check OpenSC issues and PRs mentioning skeid or Slovak eID, the minv.sk eID documentation, and slovensko.sk / slovensko.digital sources. If a card is at hand, `opensc-tool --atr` gives its ATR. Output: a table generation → chip → ATR → matched by skeid (yes/no/unknown), with sources.

### B. Slot layout and where the KEP key lives

> Context: see `Chevron7/docs/OPENSC-INTEGRATION.md` and `engine/src/main/java/digital/slovensko/autogram/drivers/PKCS11TokenDriver.java` (it picks the first slot with a token via `PKCS11TokenPresenceProbe.firstTokenSlotIndex`). Question: with OpenSC's default configuration on macOS, how many PKCS#11 slots does a Slovak eID v3 produce, what are their token labels, and which slot exposes the KEP private key (`Podpisovy kluc (KEP)`) and certificate? Read OpenSC's `src/pkcs11/framework-pkcs15.c` (`create_slots_for_pins`, virtual slots per PIN) and `etc/opensc.conf` defaults, and compare with `onepin-opensc-pkcs11.so`. If a card is at hand, confirm with `pkcs11-tool --module /Library/OpenSC/lib/opensc-pkcs11.so -L` and `-O --slot <id>` (no login). Output: the slot table and a recommendation for how `PKCS11TokenDriver` should choose the slot for the `opensc` driver.

### C. PIN sequence for a KEP signature

> Context: `pkcs15-skeid.c` guards the KEP key with the Podpisový PIN (reference 0x87, 3 tries) and sets `user_consent = 1` (CKA_ALWAYS_AUTHENTICATE); the other keys use the BOK (reference 0x03, 5 tries). Chevron7's engine sends one secret both to `C_Login(CKU_USER)` and to `C_Login(CKU_CONTEXT_SPECIFIC)` (`NativePkcs11SignatureToken.runContextSpecificLoginIfNeeded`, `ui/machine/MachineSecretUI.java`). Question: to produce a KEP signature through OpenSC, which secrets must be verified and in which order: only the Podpisový PIN, or the BOK first and then the Podpisový PIN? Does the card require the BOK to be verified in the same session before the Podpisový PIN? Read OpenSC's skeid sources and its PKCS#11 login code, the eID klient documentation from minv.sk, and upstream Autogram's handling of the eID. Do not answer by trying PINs on a card. Output: the exact PKCS#11 call sequence, and whether Chevron7's machine protocol needs a second secret field (and its name) for the `opensc` driver.

### D. eID klient and OpenSC side by side

> Context: Chevron7's engine probes every installed driver for a token (`PKCS11TokenPresenceProbe`) and prefers the eID klient (`driver id eid`). Question: can the eID klient (`/Applications/eID_klient.app`, `libPkcs11.dylib`) and OpenSC (`opensc-pkcs11.so` plus the OpenSCToken CryptoTokenKit plugin) be installed together on macOS and access the same eID over PC/SC without exclusive-access conflicts, stale sessions or one of them blocking the other? Look for reports in OpenSC issues, the eID klient FAQ and slovensko.digital forums. Output: known conflicts and a recommended test procedure.

### E. Other cards Chevron7 users sign with

> Context: besides the eID, Chevron7 users sign with I.CA cards (SecureStore middleware), Disig cards, SAK advocate cards and Gemalto IDPrime 940 (see `getMacDrivers()` in `engine/src/main/java/digital/slovensko/autogram/core/DefaultDriverDetector.java`). Question: for each of these, which chip and applet is used, and does OpenSC 0.27+ support it for qualified signing (driver name, known limitations)? Use OpenSC's `src/libopensc/card-*.c`, its wiki page "Supported hardware (smart cards and USB tokens)", and the vendors' documentation. If a card is at hand, `opensc-tool --name` shows the matched driver. Output: a table card → chip → OpenSC driver → qualified signing possible (yes/no/unknown) → notes.

### F. Bundling OpenSC in Chevron7.app

> Context: Chevron7 is EUPL-1.2, ad hoc signed, distributed as a DMG (`Chevron7/scripts/package-release.sh`), arm64 only, macOS 27+. Question: can OpenSC's PKCS#11 module be shipped inside `Chevron7.app` (for example `Contents/Frameworks`) so users need no separate install? Cover: LGPL-2.1 obligations (notice, source offer, relinking) and compatibility with EUPL-1.2; what `opensc-pkcs11.so` loads at runtime (`libopensc`, `opensc.conf`, hardcoded `/Library/OpenSC` paths, `OPENSC_CONF`); building it for arm64 in GitHub Actions on the `xcode-27` runner; code signing and library validation when an ad hoc signed app loads it via SunPKCS11 in the bundled Java runtime. Output: a go/no-go with the concrete steps and the files `build_app.sh` would have to add.

### G. CryptoTokenKit route

> Context: `SigningProviderFactory.makeDefault()` in `Chevron7/Sources/Chevron7Kit/Signing/SigningProvider.swift` uses the bundled engine when present, otherwise `KeychainXAdESSigningProvider` if the Keychain holds an identity with a private key; `CardPresenceMonitor` watches `TKTokenWatcher`. The OpenSC installer adds the OpenSCToken CryptoTokenKit plugin. Question: with OpenSC installed, does a Slovak eID appear as a Keychain identity (`security list-smartcards`, `sc_auth identities`, `system_profiler SPSmartCardsDataType`), which of its keys, and how does macOS ask for the BOK and the Podpisový PIN for `SecKeyCreateSignature`? Could this replace the Java engine for eID signing, and does it change what `CardPresenceMonitor` reports? Output: observed behaviour and a recommendation.

### H. pkcs11-spy for the drivers we already use

> Context: `Chevron7/docs/WEB-SIGNING-FINDINGS-2026-09-16.md` and `docs/PHASES.md` record PKCS#11 problems with the eID klient (a module that reported 0 slots, BOK handling) and I.CA SecureStore (slot choice). OpenSC ships `pkcs11-spy.so`, which wraps a real module (`PKCS11SPY=<module>`, `PKCS11SPY_OUTPUT=<log>`) and logs every call. Question: how to run Chevron7's engine (`Chevron7/.build/engine/Contents/Helpers/AutogramCLI-arm64`, machine protocol v1, see `engine/protocol/v1`) and `pkcs11-tool` through `pkcs11-spy` on macOS arm64, and what is the smallest engine change (for example an environment variable in `DefaultDriverDetector`) that routes a chosen driver through the spy for diagnostics only? Output: the commands and the proposed change, with the logs redacted of PINs.

### I. Qualified status with third-party middleware

> Context: a qualified electronic signature (KEP) under eIDAS needs a qualified certificate and a qualified signature creation device (QSCD). Question: does creating the signature through OpenSC instead of the eID klient affect whether a signature made with the Slovak eID counts as qualified? Check the QSCD certification of the Slovak eID (what exactly is certified: chip, applet, middleware), the EU list of certified QSCDs, the minv.sk terms of use of the eID, and any statement from NBÚ or slovensko.sk. Output: a short answer with sources, and any wording Chevron7 must show to users.

## Findings

### 2026-09-23: OpenSC does not handle the IDEMIA Cosmo 9.2 eID (prompt A, partial)

Mac Studio, macOS 27.0, OpenSC 0.27.1 from Homebrew (`/opt/homebrew/lib/opensc-pkcs11.so`), contact reader "Generic EMV Smartcard Reader 01". Everything below ran without a login, PIN or BOK.

- The owner's eID has ATR `3b:df:18:ff:81:b1:fe:45:1f:87:00:31:b9:64:09:37:72:13:73:84:01:e0:00:00:00:8e`. The eID klient module (`pkcs11-tool --module /Applications/eID_klient.app/Contents/Frameworks/libPkcs11.dylib -I -L`) reports it as **IDEMIA "Cosmo 9.2, CombI"** (hardware 9.2, firmware 2.2), not the CardOS 5.4 chip of eID v3.
- `opensc-tool --name` answers "Unsupported card"; `pkcs11-tool -L` shows the slot as "token not recognized"; `pkcs15-tool --list-certificates|--list-keys|--list-pins` fail with "Card is invalid or cannot be handled".
- Forcing a driver does not help: `-c skeid` / `OPENSC_DRIVER=skeid` fails ("Internal error", then "Card is invalid or cannot be handled"), `iasecc` fails ("Card does not support the requested operation"), `default` answers "Unsupported card".
- `card-skeid.c` matches only `3b:d2:18:00:81:31:fe:58:c9:04:11` in both the `0.27.1` tag and `master` (checked 2026-09-23, https://github.com/OpenSC/OpenSC/blob/master/src/libopensc/card-skeid.c line 48).
- Through the eID klient the same card shows two PKCS#11 slots, `Sig_ZEP` and `Sig_EP`, both with "PIN pad present" (protected authentication path) and PIN length 6/6.

Consequence: with today's OpenSC, the `opensc` driver cannot sign with an IDEMIA Cosmo 9.2 eID at all. The route stays open only for eID v3 (CardOS 5.4) cards, which still need a card to verify, or after OpenSC gains a driver for the Cosmo generation. The eID klient remains the only way to sign with this card.

Also seen on the same Mac: an I.CA SAK card (ATR `3b:da:96:ff:81:b1:fe:45:1f:07:80:58:49:43:41:20:56:32:2e:30:e9`, "XICA V2.0") is "Unsupported card" in OpenSC too; the I.CA SecureStore driver handles it.
