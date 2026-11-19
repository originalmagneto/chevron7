# ZaKo: waiting for EZZK in the background (order of 1. 1. 2027)

Status: approved by the owner on 2026-11-19.

## Why

Test of 2026-11-19 (Mac Studio, SAK card, Testovacia evidencia): the record-first order works for
P→E and E→E, but EZZK took 13 and 26 minutes to process the records, and the whole time the
authorize screen was blocked by the wait (`waitUntilEZZKProcessed`, 30 s polls for at most
30 minutes). The advocate wants to go back to work right after authorizing.

## Goals

- After the record is signed and sent, the advocate can start another conversion at once.
- A waiting conversion is visible in the sidebar ("Zaručené konverzie") and in the Register as
  waiting for EZZK, and then as waiting for the clause signature.
- While a conversion waits, the background check asks EZZK often (30 s, later 2 min), not hourly.
- When EZZK processed the record, a macOS notification says so; when it rejected it, too.
- The clause and the client document are signed only after the advocate confirms it (hold
  "Dokončiť konverziu", PIN or BOK as needed). This also works after an app restart.

## Non-goals and anti-goals

- No automatic client signature after the notification, not even with a remembered PIN (owner's
  decision of 2026-11-19: the signature with the mandate certificate stays a conscious act; an
  eID BOK and a removed card would not allow it anyway).
- No change to production policies, EZZK modes or the order itself; no new EZZK call types.
- No second signing UI outside ZaKo: the card and mandate flow stays where it is.

## Approaches

1. **Persisted pending conversion, finished in ZaKo (chosen).** `RecordFirstPending` is stored on
   disk per record and loaded back into ZaKo's authorize step when the advocate finishes it.
   Reuses the whole card flow; survives restarts and further conversions.
2. A separate signing panel opened from the notification or the Register: duplicates the card,
   PIN/BOK and mandate checks of ZaKo. Rejected.
3. Keep the pending conversion only in memory: a restart would lose the client output of a record
   EZZK already holds. Rejected.

## Design

- **Store.** `RecordFirstPendingStore` (app) keeps every pending conversion as
  `Evidence/pending/<recordID>.plist` (binary property list: the PDF, container entries, the
  appended clause and the attestation are `Data`/`Codable`). It is removed when the client output
  is signed, when EZZK rejected the record (after the notification), when the row is gone or
  deleted in the Register. Several may wait at once.
- **After the send.** `startRecordFirst` signs, registers and sends as today, stores the pending
  conversion, and looks the row up once. Processed (Demo answers at once): the client signature
  follows in the same authorization, as today. Otherwise ZaKo shows the done step in a
  "sent, waiting for EZZK" form with "Nová konverzia"; the blocking wait and "Zastaviť čakanie" go.
- **Background watcher.** While any pending conversion awaits EZZK, a watcher (regular app launch
  only, like `EZZKStatusChecker.shouldRun`) checks each one: a row not sent yet is sent
  (`submit(id:)`), an accepted or unknown row is looked up (`verify(id:)`). Every 30 s for the
  first 30 minutes after the record was signed, then every 2 minutes; after 24 hours the regular
  hourly check takes over. Processed: the pending stage becomes `signingClientContainer` and a
  notification is posted. Rejected (or the row ended `.recordUnsigned`): a notification with
  EZZK's code and text, and the pending conversion is dropped (the row stays in the Register).
- **Notifications.** `UNUserNotificationCenter`, permission asked the first time a conversion goes
  to the background. Clicking the "processed" notification opens ZaKo with that conversion.
  Without permission the sidebar and Register still show the state.
- **Finishing.** The sidebar row, the Register detail ("Dokončiť konverziu") and the notification
  load the pending conversion into ZaKo at the authorize step (attestation, direction, evidence
  number), where holding "Dokončiť konverziu" runs the existing card flow and
  `signClientContainer`. If ZaKo holds other unfinished work (past intake, before done), a
  confirmation asks whether to discard it first (no number is allocated before authorization).
  "Späť na doložku" is not offered for a loaded conversion.
- **Checks on finishing.** The EZZK mode check stays. The original and form checks are skipped for
  a loaded conversion, because it signs exactly the stored files and its form cannot be edited.
- **Labels.** Rows with a pending conversion read "Čaká na EZZK" or "Čaká na podpis doložky"
  in the sidebar and the Register instead of the plain EZZK state.

## Left to the builder

Exact view placement, the notification identifier scheme, the watcher's home (its own type
beside `EZZKStatusChecker`), and test seams for clock, lookups and notifications.
