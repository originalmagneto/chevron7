# EZZK integration

How Chevron7 talks to EZZK (the central register of records about guaranteed
conversion, CEZZK) and what an operator has to know to run, test and maintain it.

Companion documents:

- `docs/superpowers/specs/2026-09-17-ezzk-soap-design.md`: the approved design of part A.
- `docs/superpowers/plans/2026-09-17-ezzk-soap.md`: the implementation plan it was built from.
- `docs/superpowers/specs/2026-09-23-ezzk-part-b-design.md`: the approved design of part B (client clause in B1, record submission in B2, "Revision 5" amendments from the live test service).
- `docs/P2E-EZZK-FINDINGS.md`: the research register, the deviations from the MIRRI manual, and the gaps left open.
- `docs/reference/ezzk-soap/2026-09-17/`: the WSDL and XSD snapshot the request tests validate against.

## Scope

Parts A, B1 and B2 ship today; B3 ships without its final step (production for
everyone), which waits for the owner's live production conversion:

- The advocate signs in with their own EZZK name and password and Chevron7 verifies it against EZZK.
- Chevron7 reads the EZZK server time, allocates and reuses evidence numbers, and looks records up; on production, allocating and reusing a number is a consequential call gated by `EZZKProductionPolicy` (see "Production and the owner switch" below).
- ZaKo signs the conversion record (form `50349287.ConversionRecordOfPaperToElectronicDocument.sk` 1.0) with the mandate certificate and a qualified timestamp into its own ASiC-E, and sends it with `ReceiveConversionRecord`.
- Production always allows sign in, server time and public record lookup. Allocation and submission there are open for everyone since v0.12.0 (`EZZKProductionPolicy.enabledForEveryone`); ZaKo allocates and signs only with a card carrying a mandate certificate.
- `ezzk-probe` exercises the same service from the command line, including reading a record back and submitting one; it never allocates, consumes or sends on production, whichever environment its credentials belong to.

Record form version 1.2, effective 2027-01-01, is not built yet.

## Why SOAP and not the portal API

The portal REST API behind Keycloak needs MIRRI to register a native redirect URI
for Chevron7, and on the 2026-09-17 call the podpisuj.sk team confirmed that will
not happen: EZZK is not maintained, MIRRI has no administrative access to it, and
even creating a user requires a paid change request to Ditec. The SOAP service is
what every integrator has used since 2019 and it authenticates the advocate's own
account. The OAuth code (`EZZKSessionController`, `EZZKClient`, `EZZKTokenStore`,
`EZZKAuthenticationSession`) stays in the repository, compiled but unwired, for a
future login through slovensko.sk.

## Modes

`AppSettings.ezzkMode` has three values and drives everything else. Old settings
without the field decode to `demo`.

| Mode | Service | What works |
| --- | --- | --- |
| `demo` | none, `MockEZZKService` | Local numbers and local clock. No network, no Keychain. Lookup always answers processed (ruling R4). ZaKo refuses to allocate a number or authorize here with the Demo signing provider outside this mode (`EZZKError.demoSignatureOutsideDemo`). |
| `test` | `https://ezzk-test.iomo.sk` | Sign in, server time, lookup, allocate numbers, sign and send a record. "Vyžiadať čísla" in Settings only ever runs here. |
| `production` | `https://ezzk.iomo.sk` | Sign in, server time, public lookup always. Allocation and submission only when `EZZKProductionPolicy` allows a consequential call (see "Production and the owner switch" below). |

`EZZKProductionPolicy` is asked independently at every one of these call sites, so
changing one does not open another: `EZZKSOAPClient.perform` (before any network use),
`EZZKSOAPServiceAdapter.requestEvidenceNumbers`, `EZZKAccountController.requestTestNumbers`
(hard test-only, no policy check needed), `EZZKSOAPServiceAdapter.submit` and
`ezzk-probe` itself (also hard test-only for `numbers`, `consume` and `receive`).
`EZZKStatusChecker.sendsInProduction` asks the same policy, so a row signed on
production stays queued with the `submissionUnavailable` message until the policy
allows consequential calls.

## Production and the owner switch

`EZZKProductionPolicy` decides whether a consequential EZZK call (allocating or
consuming an evidence number, sending a record) may reach production; read-only
calls (login, server time, public lookup) never need it. It is read at the SOAP
client and the service adapter, at `EZZKStatusChecker`, at the Register's and
ZaKo's Done screen actions, and in Settings; every test and `ezzk-probe` default
to refused, so no forgotten call site can reach production by accident.

Since v0.12.0 production is open for everyone (`enabledForEveryone` is true), so the
switch below no longer changes anything; it is kept for a build that closes production
again. Before that release production stayed refused until the owner turned it on for this Mac:

```
defaults write app.slovensko.chevron7 EZZKProductionOwnerSwitch -bool YES
```

then relaunches Chevron7 (the policy is read once, when a client is created, so
a change needs a relaunch). To turn it off again:

```
defaults delete app.slovensko.chevron7 EZZKProductionOwnerSwitch
```

The switch only unlocks calls with the EZZK account the person already signed
in with; it grants nobody access they do not otherwise have. "Vyžiadať čísla"
in Settings stays test only regardless of the switch, and `ezzk-probe` never
allocates, consumes or sends on production, whichever environment its
credentials belong to.

## Setting it up

1. Nastavenia, tab EZZK, card Prostredie: pick Demo, Test or Produkcia. The SOAP addresses of the chosen environment are shown read only.
2. Card Účet: enter Prihlasovacie meno and Heslo (the credentials EZZK sent by email after registration), Názov osoby exactly as it appears in the conversion clause, and IČO.
3. Press Prihlásiť a overiť. Chevron7 calls `LogIn` and only saves the credentials in the Keychain after EZZK accepts them. The card then shows the account name EZZK returned and the time of the check. Odhlásiť deletes the Keychain item and drops the token.
4. Card Overenie záznamu works without signing in, on test and on production.
5. Card Evidenčné čísla is test only. On production it shows a locked label instead of a button.

Every advocate needs their own EZZK account. There is no shared integrator account.

## Transport contract

The contract below was verified against the live service on 2026-09-17. Where the
MIRRI manual and the live service disagree, the live service wins.

- SOAP 1.2, `Content-Type: application/soap+xml; charset=utf-8; action="<action>"`.
- WS-Addressing headers are mandatory: `a:Action` (`mustUnderstand`), `a:MessageID` (`urn:uuid:`) and `a:To` (`mustUnderstand`). An empty header, as in the manual's examples, fails with `a:ActionMismatch`.
- Service actions are `http://www.ditec.sk/IEZZKService/IEZZKService/<Operation>`; login is `http://ditec/2017/06/iam/core/ILogInService/LogIn`.
- WCF data contract serialization: every element declared in the XSD must be present, in XSD order, with `i:nil="true"` for empty nillable values.
- Fields inherited from a base type, and the shared object elements (`Class`, `Encoding`, `Id`, `IsSigned`, `Mimetype`, `Data`), live in `http://schemas.datacontract.org/2004/07/Ditec.IOM.EZZK.Dol`. `Container` fields live in the operation namespace. The manual puts the `ZiadostVypis` fields in the operation namespace and the service rejects that with `DeserializationFailed`. The element is `Mimetype`, not `MimeType`.
- `LogIn` uses `ApplicationId` `EZZK`. Success returns a `TokenDescriptor` and the account name; failure returns an `ErrorCode` such as `CORE-003` (wrong name or password) or `CORE-018` (locked account).
- Every authenticated call sends `Cookie: IamTokenDescriptor=<token>`. The same token in an HTTP header is ignored. Without the cookie the service answers HTTP 500 with the fault "The service implementation object was not initialized or is not available."; with an invalid token it answers HTTP 200 with `Result/Code` 101.
- The load balancer sets a `SERVERID` cookie and alternates nodes. A token works on any node, so Chevron7 never sends that cookie back.
- The manual states no token lifetime. Chevron7 keeps the token in memory only, logs in lazily, and on 101 or the uninitialized-service fault logs in once more and repeats the call once. A second failure is `authenticationFailed`.

### Operations used

| Operation | Auth | Used for |
| --- | --- | --- |
| `GetOptions` | no | Server time, read from the HTTP `Date` header. |
| `GetConversionRecordEvidenceNumber` | yes | Allocating evidence numbers. Test only. |
| `ConsumeConversionRecordEvidenceNumber` | yes | Consuming a number. Test only. |
| `GetConversionRecordInformationPurpose` | no | Public record lookup in Settings and in the probe. |
| `GetConversionRecord` | yes | The advocate's own record with the stored object (`ezzk-probe record`). |
| `ReceiveConversionRecord` | yes | Submitting a record. Consumes the evidence number on acceptance (`EZZKSOAPClient.receive`, `ezzk-probe receive`). |

Result codes: 0 OK; 1 recorded but not processed yet; 101 not authorized; 104 and
105 number not recorded; 106 the number is used by several records, so the
execution time has to be sent (EZZK stores duplicates rather than refusing them:
as a `ReceiveConversionRecord` result Chevron7 treats it as an unknown outcome
that a lookup resolves, and as a lookup result as a record EZZK holds, ruling
R17); 110 empty batch; 112 the number belongs to another
person; 113 the account's limit of unconsumed evidence numbers is reached (live,
2026-09-23; the MIRRI manual describes 113 as an empty batch, which the live
service does not). Any other code on a lookup of an `.acceptedForProcessing` row
(106 excepted) means EZZK processed and refused the record (for example 12
"Neznámy obsah"). A lookup that first answers 106 is asked again once with the
record's conversion time (the only thing that tells the duplicates apart); a 105
on that timed retry does not mean the record is gone, since the first 106 already
proved the number is occupied, so the row still keeps code 106 and EZZK's text
rather than being requeued for a resend (ruling R-B3-1).

## Evidence numbers

Verified live on test EZZK, 2026-09-23 (`P2E-EZZK-FINDINGS.md`, "Part B2"):

- `GetConversionRecordEvidenceNumber` allocates and returns exactly one new number per call; it never returns a number already given out. Once the account's limit of unconsumed numbers is reached it refuses with code 113. Chevron7 keeps every number it allocated and has not yet used, per EZZK mode and Bratislava day (`EvidenceNumberPool`), and reuses one before asking EZZK again; code 113 with nothing left to reuse shows `EZZKError.numberLimitMessage`.
- Test numbers look like `260917-dD9DbFE4f7`, production numbers like `1563-260824-1`. Chevron7 treats a number as an opaque string.
- `ReceiveConversionRecord` consumes the number: right after a result-0 receipt a new number can be allocated. No `ConsumeConversionRecordEvidenceNumber` call is needed for a sent record (that operation still exists for part A's manual `consume`). An unconsumed number allocated on an earlier Bratislava day no longer counts toward the limit after midnight and is dropped from the pool (`EvidenceNumberPool.reusable`, `EZZKEvidenceNumberPolicy.isUsable`); a record for it can still be sent late (see "Submission states" below).
- `AttestationData.evidenceNumberAllocatedAt` records the server time of the allocation and `EZZKEvidenceNumberPolicy.isUsable` refuses to sign with a number from another calendar day in `Europe/Bratislava`.
- `AttestationData.evidenceNumberMode` records the mode the number came from, and signing is refused if the current mode differs, so a demo or test number cannot end up in a record signed on production. Both checks run before anything is signed or written.
- The adapter drops numbers that a local record in `LocalEvidenceStore` already uses before handing one to ZaKo.
- A number without an allocation time or without a mode (typed by hand or from older data) is not blocked.
- `ReceiveConversionRecord` answering 0 means the record was accepted for processing, not that it is valid: the public lookup then reports code 1 ("evidovaný, ale nespracovaný") until EZZK finishes processing it (observed up to 18 minutes on test), after which it reports 0 (accepted) or another code (rejected, with EZZK's own text).

## Submission states

`EZZKSubmissionCoordinator` (`Sources/Chevron7Kit/EZZK/EZZKSubmissionCoordinator.swift`) owns every transition a register row can make once it has a signed record. The ZaKo flow, the Register's "Odoslať"/"Overiť v EZZK" and the periodic `EZZKStatusChecker` all go through it, so a row is never sent or looked up by two paths at once (a duplicate send earns EZZK result 106).

- **Send** (`submit`): a network error, an unreachable login, a refused certificate pin, or a WCF deserialization fault happens before the operation runs, so nothing was sent; the row stays `.queuedForSubmission` (or `.late`) with the reason. Anything else unexpected after the request left (`outcomeUnknown`, an unreadable reply, a 5xx) is not proven unsent, so the row becomes `.outcomeUnknown` and is never resent blindly. A clean result becomes `.acceptedForProcessing` with the WS-Addressing `MessageID` and the send time. A 106 result (the number is used by several records, ruling R17) proves nothing about this record, so the row becomes `.outcomeUnknown` and the lookup decides.
- **Resolve an unknown outcome** (`resolveUnknown`): waits five minutes after the send so EZZK has registered a record it may still have been receiving. A 105 (unknown number) means EZZK never got it, so the row is requeued (`.queuedForSubmission`); found means it was accepted after all, and so does a 106 (EZZK holds records under the number; the row keeps code 106 and EZZK's text); any other code means EZZK processed and refused it (`.rejected`, with EZZK's code and text).
- **Refresh an accepted row** (`refreshStatus`): lookup code 0 becomes `.processed`; code 1 leaves the row `.acceptedForProcessing` (still waiting); any other code (105 included) is never treated as proof the record vanished, except a code outside {0, 1, 105, 106}, which means EZZK processed and refused it (`.rejected`). A 106 keeps the row accepted with code 106 and EZZK's text.
- **Resend a rejected row** (`resend`, only from "Odoslať znova" in the Register after a confirmation naming EZZK's code and text, ruling R18): allowed only when EZZK refused the record at submission (`canResend`: `.rejected`, no `submittedAt`, no `lastLookupAt`) and the signed record container is stored. A record refused after EZZK received it (after a receipt, or by a lookup that resolved an unknown outcome) is never resent, since EZZK holds it. The periodic check and "Odoslať" never resend a rejected row. The confirmation also carries the lateness warning ("Záznam sa neodoslal v deň pridelenia čísla...") when the row's allocation day has already passed.
- **Late rows** (`markLateIfNeeded`): a `.signed`/`.queuedForSubmission`/`.submissionFailed` row whose allocation day (Bratislava) has passed becomes `.late`. EZZK still accepts late records for processing (live, 2026-09-23), so `.late` rows are sent with a warning: "Záznam sa neodoslal v deň pridelenia čísla. EZZK ho môže odmietnuť alebo evidovať ako oneskorený."
- **Scheduling** (`nextStatusCheck`): the first check is five minutes after the send (or after the row became unknown); after that, hourly.
- **Evidence number and row lifetime in ZaKo:** the number leaves `EvidenceNumberPool` as soon as the signed client container passes `ASiCEContainerVerifier` (the client documents carry it, whatever happens to the record). The `.signed` row is written before the record is signed, and `EZZKStatusChecker.hold` keeps every path off it until that signature succeeds or fails; after a crash during the record signature the next check marks the orphan `.recordUnsigned` like any row without a signed record. Deleting a row in the Register (`EZZKStatusChecker.delete(id:) -> Bool`) also drops its number from the pool, but refuses (returns `false`, with `EZZKStatusChecker.busyDeleteMessage`) while the row is still held or in flight, so a signature or a send in progress cannot write a deleted row back into existence.
- `EZZKStatusChecker` runs this every five minutes, but only in a regular launch of Chevron7 (`shouldRun`, never in the `--web-signing` accessory mode), one row at a time (`inFlight`), capped at three automatic sends per row per Bratislava day, and sends only rows whose stored `ezzkMode` matches the mode currently selected. Accepted and unknown rows are looked up in the EZZK of their own stored mode whatever mode is selected, by the periodic check and by "Overiť v EZZK" alike: a lookup only reads, so a record accepted in Production still turns processed while the advocate works in Demo. A row without a stored mode was written before part B2 (no signed record) and no path ever sends or looks it up.

## Error mapping

| Situation | `EZZKError` | What the user sees |
| --- | --- | --- |
| Wrong name or password (`CORE-003`) | `credentialsRejected(code:)` | Nesprávne prihlasovacie meno alebo heslo. |
| Any other LogIn error code | `credentialsRejected(code:)` | EZZK odmietlo prihlásenie (kód ...). Prihláste sa znova v Nastaveniach. Like `CORE-003` and `CORE-018`, the client does not log in with those credentials again until they are saved again in Settings. |
| Locked account (`CORE-018`) | `accountLocked` | Účet v EZZK je zablokovaný. |
| Token rejected after one fresh login | `authenticationFailed` | Prompt to sign in again. |
| Unknown result code | `serviceRejected(code:message:)` | The code and the server's own text. |
| `DeserializationFailed` or `ActionMismatch` | `invalidRequest` | An application defect. Logged with the fault subcode public and the reason private. |
| Test certificate is not the pinned one | `untrustedCertificate` | Update the pin in the app. |
| Network error or HTTP 5xx (a readable WCF fault included) on allocate, consume or submit | `outcomeUnknown` | Names a lost connection or a server fault; the outcome is unknown either way and the call is never repeated, `EZZKSubmissionCoordinator` looks it up before resending. |
| Allocation attempted on production without the policy's permission | `productionAllocationDisabled` | Refused unless `EZZKProductionPolicy` allows it (see "Production and the owner switch"). |
| Submission attempted on production without the policy's permission | `submissionUnavailable` | Row stays queued in the register until the policy allows it. |
| Demo signing provider used outside Demo mode | `demoSignatureOutsideDemo` | ZaKo refuses before allocating a number or signing. |
| Number from another day or another mode | `evidenceNumberExpired`, `evidenceNumberFromOtherMode` | Get a new number. |
| No reusable evidence number, EZZK refuses allocation (code 113) | `EvidenceNumberPool.numberLimitMessage` | Finish the pending conversion or wait until midnight. |

Errors that fail before anything was sent (no connection, host not found, DNS
failure) stay a plain `networkFailure` even on a consequential call, because in
that case the outcome is known.

## Security

- The password lives only in the Keychain, in a generic password item with service `app.slovensko.chevron7.ezzk.soap` and account `test` or `production`. It is never written to `AppSettings`, logs, probe output or the repository.
- The token lives only in memory, inside the client actor. Nothing can read it out, and the probe never prints it.
- The session uses an ephemeral configuration with no cookie storage and no cache, and refuses every redirect, so the password body and the token cookie cannot leave the EZZK host.
- The test environment trusts exactly one pinned certificate; production uses system trust. There is no global TLS bypass.
- No credentials are stored in the repository, including the sample test account from the MIRRI manual.

## Code map

| File | Responsibility |
| --- | --- |
| `Sources/Chevron7Kit/EZZK/EZZKEnvironment.swift` | Environments, SOAP URLs, the certificate pin. |
| `Sources/Chevron7Kit/EZZK/SOAP/EZZKSOAPEnvelope.swift` | Namespaces, XML escaping, the SOAP 1.2 envelope with WS-Addressing, date formatting. |
| `Sources/Chevron7Kit/EZZK/SOAP/EZZKSOAPRequest.swift` | `EZZKPerson`, request values and one builder per operation. |
| `Sources/Chevron7Kit/EZZK/SOAP/EZZKSOAPResponse.swift` | Fault and result parsing with `XMLDocument`, matched by local name. |
| `Sources/Chevron7Kit/EZZK/SOAP/URLSessionEZZKSOAPTransport.swift` | The pinned, redirect-refusing transport. |
| `Sources/Chevron7Kit/EZZK/SOAP/EZZKSOAPCredentialStore.swift` | The Keychain item. |
| `Sources/Chevron7Kit/EZZK/SOAP/EZZKSOAPClient.swift` | The actor: lazy login, token cookie, one safe re-login, no repeat of consequential calls. |
| `Sources/Chevron7Kit/EZZK/SOAP/EZZKSOAPServiceAdapter.swift` | `EZZKServicing` for the app: filters used numbers, asks `EZZKProductionPolicy` before allocation and submission on production. |
| `Sources/Chevron7Kit/EZZK/EZZKProductionPolicy.swift` | Decides whether a consequential call may reach production: the owner switch and `enabledForEveryone`. |
| `Sources/Chevron7Kit/EZZK/EZZKEvidenceNumberPolicy.swift` | The day rule, the mode rule and the clause identity check. |
| `Sources/Chevron7Kit/EZZK/EvidenceNumberPool.swift` | Evidence numbers allocated and not yet used, per mode and Bratislava day; reuse before allocating again. |
| `Sources/Chevron7Kit/EZZK/EZZKSubmissionCoordinator.swift` | The one set of rules for submission states (send, resolve unknown, refresh, late, scheduling). |
| `Sources/Chevron7Kit/Attestation/Forms/ConversionRecordRenderer.swift` | Renders the record 1.0 XML from `ConversionFormModel`. |
| `Sources/Chevron7Kit/Attestation/Forms/ZakoRecordDeliveryBuilder.swift` | Validates the record and wraps it as `<number>.record.xml.xdcf`. |
| `Sources/Chevron7App/EZZK/EZZKAccountController.swift` | Account state for Settings and ZaKo, one transport and one client per environment. |
| `Sources/Chevron7App/EZZK/EZZKStatusChecker.swift` | Sends and checks register rows: periodic pass, manual "Odoslať"/"Overiť v EZZK", per-row serialization, per-row mode. |
| `Sources/Chevron7App/Views/Settings/EZZKSettingsPane.swift` | The EZZK pane of Settings (Basic connect, Advanced environment, lookup, numbers, migration); `EZZKConnection.swift` holds the connect flow. |
| `Sources/Chevron7App/Views/EvidenceDashboardView.swift` | The Register's per-row EZZK actions and status labels. |
| `Sources/ezzk-probe/main.swift` | The command line probe. |

## Probe

```
swift run ezzk-probe <login|time|numbers|consume|lookup|record|receive> [number] [--env test|production] [--name N] [--ico I] [--at ISO] [--purpose original|xml] [--out FILE] [--file ASICE]
```

Credentials come from `EZZK_LOGIN` and `EZZK_PASSWORD`, otherwise from the Keychain
item Settings saved for that environment. `numbers`, `consume` and `receive` refuse
`--env production` before building a client. `record` reads one of the signed-in
person's own records (`GetConversionRecord`) and writes the returned object to
`--out`; it changes nothing in EZZK. The token is never printed; `login` prints
only the account name.

## Testing

- `swift test --filter EZZK` runs the unit tests. They never reach the network and never touch the real Keychain: App tests build settings with `makeSettingsStore(ezzkAccountController:)` (a `MemoryCredentialStore` and a scripted transport), so a saved test-mode credential in the developer's real Keychain never triggers an access prompt during a test run.
- Request bodies are validated with `/usr/bin/xmllint --schema` against the production WSDL and XSD snapshot, including a negative case that must fail. The record 1.0 schema does not compile in libxml2 as published (the `IdentifierValue` pattern escapes `/` as `\/`); `FormSchemaValidator` validates against a derived `docs/reference/forms/record-1.0/schema.validation.xsd` that rewrites only that one pattern, while the XDC keeps referencing and digesting the official `schema.xsd`.
- Response parsing runs against recorded replies with tokens redacted and personal data anonymized.
- `EZZK_LIVE=1 swift test --filter EZZKSOAPTransportTests` additionally performs the real pinned handshake against the test host with an unauthenticated `GetOptions`, and asserts that a wrong pin is refused.
- Live checks with the probe are manual and are not part of CI.

## Maintenance

- The test certificate is self-signed, `CN=ezzk-test.iomo.sk`, and expires on 2026-10-20. When it is renewed, read the new digest and update `EZZKEnvironment.pinnedCertificateSHA256`:

  ```bash
  echo | openssl s_client -connect ezzk-test.iomo.sk:443 -servername ezzk-test.iomo.sk 2>/dev/null | openssl x509 -outform DER | shasum -a 256
  ```

- Production uses a public RapidSSL certificate for `*.iomo.sk`. The one observed on 2026-09-17 expires on 2026-09-21; if it lapses, EZZK fails for every integrator, which is not a Chevron7 defect.
- The WSDL and XSD snapshot is dated. Refresh it when the service changes and rerun the request tests.
- Gaps deliberately left open in part A, and which of them part B2 closed, are listed at the end of `docs/P2E-EZZK-FINDINGS.md`.
