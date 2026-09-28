# eID NFC signing: contactless reset hypothesis (2026-09-28)

Status: hypothesis, not verified. Do not fix from this note alone.

## Symptom (user report, main window)

- eID on an NFC reader is detected (reader badge shows the card).
- Signing fails with an error, the card on the NFC field reloads (re-enumerates) and only then the BOK window pops up.

## Suspected cause

`EngineBridgeSigningProvider.sign()` calls `engine.drivers()` first
(`Chevron7/Sources/Chevron7Kit/Signing/JavaEngine/EngineBridgeSigningProvider.swift:305`).
That fans out to `PKCS11TokenDriver.tokenPresent()`, which runs
`PKCS11TokenPresenceProbe.tokenPresent()`: `C_Initialize` + `C_GetSlotList` +
`C_Finalize` when the probe owns init
(`engine/src/main/java/digital/slovensko/autogram/drivers/PKCS11TokenPresenceProbe.java:25-39,79-89,122-131`).
On a contactless eID the `C_Finalize` from that short-lived probe call can drop
the NFC field before the signing session starts. The card reset and the BOK
popup are then consequences, not the cause. Pausing the `CardReaderStatus`
poll cannot help, because the probe runs inside `sign()` itself.

Second trap (from review, unverified in code here): if the PIN field holds a
non-empty value on the eID path, `enginePIN` forwards it instead of the
`protected-authentication-path` placeholder, so the engine attempts a real
login where the eID client flow is expected.

## Debug plan

1. Reproduce both ways on the same reader: contact-inserted vs contactless.
   Record the exact app error text for each.
2. `PKCS11_DEBUG=1` engine stderr plus
   `/usr/bin/log show --last 5m --predicate 'subsystem == "app.slovensko.chevron7"'`
   around one failed attempt. Look for driver probe vs signing session order.
3. Check whether `tokenPresent` flaps across repeated `engine.drivers()` calls
   on the NFC reader (field drop signature).
4. Check the main-window PIN field state on the eID path: it must be empty so
   the placeholder is used (cf. WEB-SIGNING-FINDINGS section 8: a real value
   spends a BOK attempt per signature).

## Verify plan (when fixed)

- Candidate fix: in `sign()`, reuse the cached driver fingerprint instead of a
  fresh `engine.drivers()` probe when the driver is already known, so no
  `C_Initialize`/`C_Finalize` cycle runs right before the signing session.
- NFC eID signs without a card reset and with the expected BOK rounds only.
- Regression: contact eID, I.CA SecureStore (slot 0 vs 1), phone path, plus
  `PKCS11TokenPresenceProbeTest` and `MachineDriverServiceTest`.
