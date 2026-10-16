# P2E and EZZK Findings Register

Status: working technical record for Autogram P2E and CEZZK integration
Scope: official form sources, observed Podpisuj output, authenticated EZZK interface, and implementation boundaries

## Executive decisions

- Production target for the conversion clause is the official Slovensko.sk form dataset version 1.3.
- The Podpisuj artifact observed during reverse engineering is retained as a version 1.2 reference fixture only. It is not the production target.
- The current CEZZK conversion-record form remains version 1.0 until the official transition to record version 1.2 on 2027-01-01. Re-check the official source and dataset before changing this profile.
- Autogram must not claim production compatibility from the existing legacy Swift renderer. The new validator is structural and digest-based only, and is not a certificate trust-list validator or a VeraPDF conformance proof.
- EZZK authentication and submission must use the real authenticated service contract. No credentials, tokens, or guessed authorization flow are stored in the repository.
- Since 2026-09-17 EZZK access uses the Ditec WCF SOAP service with the advocate's own EZZK name and password. MIRRI will not register a native OAuth callback, so the Keycloak OAuth/REST client stays in the code but is not wired. Design: `docs/superpowers/specs/2026-09-17-ezzk-soap-design.md`.
- Initial end-to-end integration must target the EZZK test environment before any production submission path is enabled.

## Official Slovensko.sk and MIRRI findings

### Clause form target: version 1.3

The official Slovensko.sk catalogue identifies the target form as:

- Form identifier: `50349287.ConversionCertificateOfPaperToElectronicDocument.sk`
- Form version: `1.3`
- Reference identifier: `http://data.gov.sk/doc/eform/50349287.ConversionCertificateOfPaperToElectronicDocument.sk/1.3`
- Clause namespace: `http://schemas.gov.sk/form/50349287.ConversionCertificateOfPaperToElectronicDocument.sk/1.3`
- Clause root: `ConversionCertificateOfPaperToElectronicDocument`
- Title: `Osvedčovacia doložka zaručenej konverzie z listinnej podoby do novovzniknutého elektronického dokumentu`
- Catalogue validity start shown by the official page: `01.12.2019`

Official sources:

- Metadata page: `https://formulare.slovensko.sk/_layouts/eFLCM/DetailVzoruEFormulara.aspx?vid=50349287.ConversionCertificateOfPaperToElectronicDocument.sk&vh=1&vl=3`
- Official artefact archive: `https://formulare.slovensko.sk/_layouts/eFLCM/GetEFormArtefact.aspx?ac=4&vid=50349287.ConversionCertificateOfPaperToElectronicDocument.sk&sid=&vh=1&vl=3`

The version 1.3 archive contains the official XML/XSD/XSLT artefacts, including `schema.xsd` and `data.xml`. The repository centralizes the URLs in `P2EConformanceProfile` so future dataset updates are explicit.

### CEZZK record transition

The official MIRRI CEZZK documentation states that new electronic record forms version 1.2 become effective on 2027-01-01. The current version 1.0 record forms remain in force until that date.

The currently published Slovensko.sk record dataset contains version 1.0:

- Dataset directory: `https://www.slovensko.sk/static/eform/dataset/50349287.ConversionRecordOfPaperToElectronicDocument.sk/`
- Current record namespace: `https://data.gov.sk/id/egov/eform/50349287.ConversionRecordOfPaperToElectronicDocument.sk/1.0`
- Current record identifier: `http://data.gov.sk/doc/eform/50349287.ConversionRecordOfPaperToElectronicDocument.sk/1.0`
- Record root: `ConversionRecord`
- Record XDCF version: `1.0`

The version 1.2 record profile is intentionally not guessed or enabled before the official effective date and dataset publication.

Official source:

- MIRRI CEZZK documentation: `https://mirri.gov.sk/sekcie/informatizacia/dokumenty/zakon-o-e-governmente/centralna-evidencia-zaznamov-o-vykonanej-zarucenej-konverzii/`

## Observed Podpisuj reference fixture

An authenticated Podpisuj transaction was inspected as a reference implementation. It used the same conversion domain but a different clause namespace and identifier:

- Clause namespace: `http://schemas.gov.sk/form/50349287.ConversionCertificateOfPaperToElectronicDocument/1.2`
- Clause identifier: `http://data.gov.sk/doc/eform/50349287.ConversionCertificateOfPaperToElectronicDocument/1.2`
- Clause version: `1.2`
- Record profile observed alongside it: record version `1.0`

This fixture is useful for regression and interoperability comparison. It must not replace the official v1.3 target profile. The v1.2 reference profile is named `P2EConformanceProfile.referenceV1_2`.

The authenticated Podpisuj account exposed historical P2E activity, including 133 P2E transactions and 266 consumed timestamps during the observed session. A known record `1563-260824-1` was displayed as authentic and valid. These values are observations from the authenticated interface, not a repository fixture or an EZZK production guarantee.

## Authenticated EZZK findings

### Portal and tenant

The authenticated EZZK portal was available at:

- Portal: `https://ezzk.iomo.sk/portal/ezzk/dashboard`
- API base: `https://ezzk.iomo.sk/api/zzkservice/v1`
- Logged-in organization shown by the portal: `Advokátska kancelária CHZ`
- Logged-in identifier shown by the portal: `000042249180`
- Portal build shown by the portal: `0.16.2`

The account-specific dashboard did not show usable unconsumed evidence numbers at the time of inspection. An authenticated `GET /ec` returned:

```json
{
  "availableEvidenceNumbers": [],
  "description": "Neboli nájdené žiadne nespotrebované evidenčné čísla"
}
```

This does not prove that the account can never generate numbers. It only records the state returned by the read-only request at inspection time.

### Discovered portal routes

The portal exposed these user-facing routes:

- `/portal/ezzk/evidence/request`
- `/portal/ezzk/evidence/consumed`
- `/portal/ezzk/conversion/perform`
- `/portal/ezzk/conversion/history`

### REST contract discovered from the authenticated portal bundle

The service JavaScript bundle exposed the following API contract:

| Method | Endpoint | Purpose | Repository status |
| --- | --- | --- | --- |
| `GET` | `/ec` | Read available evidence numbers | Read-only request performed |
| `POST` | `/ec` | Generate evidence numbers | Not called because it is consequential |
| `GET` | `/zzk/{evidenceNumber}` | Read a conversion record | Not called during this session |
| `GET` | `/zzk/{evidenceNumber}/original` | Read the original artefact | Not called during this session |
| `POST` | `/zzk` | Submit a conversion record | Not called because it is consequential |
| `GET` | `/ec/consumed` | Read consumed evidence numbers | Not called during this session |
| `GET` | `/zzk?...` | History/DataTables query | Default history request observed |

The conversion upload input accepts `.asice`. The Angular payload shape is:

```json
{
  "files": [
    {
      "fileName": "example.asice",
      "fileType": "application/vnd.etsi.asic-e+zip",
      "value": "<base64 file content>"
    }
  ]
}
```

The exact endpoint contract is now sufficient to design a typed transport, but not sufficient to authorize or submit automatically without an explicit authenticated session and a test-environment validation step.

### Authentication contract

The portal uses OAuth2 Bearer authentication through Keycloak:

- Issuer: `https://ezzk.iomo.sk/sso/auth/realms/ezzk`
- Client ID: `login-app`
- Redirect URI: `https://ezzk.iomo.sk/portal`

The repository must not embed tokens, client secrets, passwords, or copied browser session data. The intended native implementation is an interactive `ASWebAuthenticationSession` flow with secure token storage and refresh handling, followed by an EZZK REST client.

## Implementation now present in Autogram

### Conformance profiles

`P2EConformanceProfile.swift` defines:

- `targetV1_3` for the official clause namespace and identifier
- `referenceV1_2` for the observed Podpisuj fixture
- Current record version 1.0 for both profiles
- Official metadata, archive, and MIRRI documentation URLs
- Shared MIME, PDF/A-2, SHA-256, and evidence URI constants

### Structural validator

`P2EConformanceValidator.swift` validates the following without making unsupported trust claims:

- ASiC container validity through the existing verifier
- Required XDCF and PDF entries
- Official namespace, identifier, root, and XDCF version
- PDF/A-2 and `PDFA2` declarations
- SHA-256 method and Base64 digest of the embedded PDF
- Evidence URI and ISO-8601 conversion time
- Expected PDF data, evidence number, and conversion time when supplied
- Presence of `META-INF/signatures001.xml` and `SignatureTimeStamp`
- Rejection of demo signature markers
- Record artifact shape with one XDCF entry and no PDF entry
- Equality of evidence URI, fingerprint, and conversion time between clause and record
- Deterministic, sorted, deduplicated issue strings

The validator deliberately does not prove:

- Qualified certificate trust
- Trust-list status
- OCSP or CRL status
- Long-term signature validity
- Full PDF/A conformance through VeraPDF
- Legal acceptance by CEZZK

### EZZK capability boundaries

`EZZKService.swift` now separates the service contract into:

- `EZZKServerClock`
- `EZZKEvidenceNumberProvider`
- `EZZKSubmissionTransport`
- `EZZKServicing`, which inherits all three and remains source-compatible

Existing mock numbering, HTTP behavior, and method signatures remain unchanged. The capability split is an architectural boundary only. No production endpoint, token flow, or submission side effect was added.

### Deliberate non-cutover

The existing legacy Swift form renderer and `FormPackRepository.currentLegacyUnverified` remain pilot-only. The new validator is not wired into the legacy generation path, because doing so would risk marking the existing output as official v1.3 compatible without an official renderer and end-to-end validation.

## Verification record

The implementation was completed on branch `codex/ezzk-oauth-rest-ui` and merged locally into `main`.

```text
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test
```

Result on the merged `main`: 187 tests executed, 3 skipped, 0 failures.

```text
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" ./build_app.sh
```

Result on the merged `main`: successful debug build at `Autogram/.build/arm64-apple-macosx/debug/Autogram.app`.

The app was launched from the built bundle. Screen capture produced no usable app surface in the verification session, so interactive Settings verification was not feasible. Source and build evidence confirm the sandbox default, closed production gate, callback-gated login, no EZZK password-login controls, disabled signed ASiC-E submission control, and demo rows remaining pending.

No EZZK evidence numbers were generated and no conversion was submitted. No installed Podpisuj application was modified.

## Current open work and update triggers

1. Obtain operator confirmation for a native redirect URI or callback scheme for `login-app`.
2. Obtain a non-production EZZK sandbox account.
3. Confirm the complete `POST /ec` contract and response.
4. Confirm the complete `POST /zzk` request, receipt, error, retry, and idempotency contract.
5. Produce and validate the separate signed record ASiC in the conversion workflow before enabling submission.
6. Obtain and inspect the full official v1.3 XSD/XSLT/data artefacts and implement an official-compatible clause renderer before production eligibility.
7. Re-check the MIRRI documentation and Slovensko.sk dataset when record version 1.2 is announced or on 2027-01-01.
8. Add a visible UI state distinguishing pilot output, structurally validated output, and EZZK-accepted output.

## Repository references

- Plan: `docs/superpowers/plans/2026-08-29-ezzk-oauth-rest-ui.md`
- Clause profile: `Sources/AutogramKit/Attestation/P2EConformanceProfile.swift`
- Validator: `Sources/AutogramKit/Attestation/P2EConformanceValidator.swift`
- EZZK boundaries: `Sources/AutogramKit/EZZK/EZZKService.swift`
- Conformance tests: `Tests/AutogramKitTests/P2EConformanceTests.swift`
- EZZK and packaging tests: `Tests/AutogramKitTests/EvidenceAndPackagingTests.swift`

## Task 6 integration and verification update (2026-08-30)

### Implemented and verified

- `EZZKEnvironment` remains fixed-authority: sandbox is `https://ezzk-test.iomo.sk`, production is `https://ezzk.iomo.sk`, and the app's production authority gate is closed.
- `EZZKSessionController` owns OAuth-backed session state. The default OAuth configuration has no native callback, so login remains unavailable until the operator registers and supplies a confirmed native redirect URI and callback scheme.
- `SettingsView` presents only fixed environment identities, OAuth session controls, and migration contact metadata. It does not present an EZZK password login, arbitrary EZZK endpoint input, OAuth token values, or a mock fallback after OAuth failure.
- `EZZKClient` uses the fixed sandbox API host by environment, Bearer tokens from the dedicated EZZK token store, authenticated server `Date` values, bounded retries for read-only requests only, and a non-retrying consequential POST.
- Consequential submit decoding requires a non-empty `EZZKSubmissionReceipt.receipt`. A 2xx response with an unknown body is rejected as `invalidResponse`, and transport timeout remains an uncertainty rather than a submission.
- Focused receipt tests now prove that a confirmed receipt does not mutate a local evidence row by itself, that an unknown successful response leaves a signed row non-submitted, and that a submit timeout leaves a signed row non-submitted.
- The legacy exported `HTTPSEZZKService` and `EZZKCredentials` types remain only for source compatibility. No application wiring selects them; `AppSettingsStore` does not construct a password-authenticated service. Legacy password storage is read only to prevent an old credentialed installation from entering demo mode and is not used for OAuth or REST requests.
- Demo-only `MockEZZKService` behavior is retained. Explicit demo submit calls remain local-only and leave the evidence row pending; dashboard success feedback identifies the local preparation rather than CEZZK acceptance.
- `URLSessionEZZKHTTPTransport` uses a redirect-denying delegate, so Bearer headers and refresh-token POST bodies are never forwarded across HTTP redirects. The client also validates final API and issuer response authorities.
- Conversion preflight no longer requests evidence numbers automatically. Evidence-number generation remains an explicit Settings action or explicit user action from the conversion form.
- `AppSettingsStore` distinguishes empty, present, and unavailable OAuth token storage. Keychain errors fail closed and cannot classify an installation as demo or expose the mock service.
- Demo is visible as `Demo (lokálne)` with no sandbox or production URL presented as the active service. Demo submission calls remain local and leave rows pending.
- Validated OIDC discovery now carries its token endpoint in `EZZKTokenSet`; refresh uses that endpoint and rejects missing or untrusted endpoints instead of reconstructing a path.

### Exact verification

```text
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter EZZKHTTPClientTests
```

Result: 21 tests passed, 0 failures.

```text
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test
```

Result: 187 tests executed, 3 skipped, 0 failures.

```text
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" ./build_app.sh
```

Result: successful debug build at `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/.build/arm64-apple-macosx/debug/Autogram.app`. Existing warnings remain in unrelated app and signing support code.

The verified debug bundle was installed at `/Applications/Autogram macOS.app`. The app was launched from the built bundle. Screen capture produced no usable app surface in this session, so interactive Settings verification was not feasible. Source and build evidence confirm the sandbox default, closed production gate, callback-gated login, no EZZK password-login controls, and disabled signed ASiC-E submission control.

### Blockers and uncertainty

- **Native callback blocker:** the operator has not supplied a registered native redirect URI and callback scheme. The observed web redirect is explicitly rejected, so login remains blocked closed.
- **Sandbox account blocker:** no non-production EZZK test account or credentials were available for an authenticated sandbox smoke test. No evidence-number request or conversion POST was made.
- **Unconfirmed POST receipt schema:** the portal bundle confirms the `.asice` `files` payload and `POST /api/zzkservice/v1/zzk`, but the authoritative success body and complete error mapping were not confirmed from an operator-backed sandbox transaction. The client therefore accepts only the typed non-empty `receipt` shape as a narrow defensive boundary and does not claim interoperability.
- **Local evidence integration gap:** the current app workflow does not produce and validate the separate signed record ASiC required for EZZK submission, and `EZZKClient` is not yet adapted to `EZZKServicing.submit(ConversionRecordEnvelope)`. The Settings ASiC submission control remains disabled. The app-target test boundary also prevents a direct XCTest of `EZZKSessionController.logout()` preserving rows; `LocalEvidenceStore` persists independently and existing persistence coverage remains green.
- **Demo status limitation:** the demo mock is still called for compatibility, but both the dashboard and conversion workflow now leave demo rows pending instead of assigning `.submitted`. It is not evidence of CEZZK acceptance; dashboard feedback labels the outcome as demo-local.

Production readiness is not claimed.

## SOAP integration (2026-09-17)

### Why

On 2026-09-17 the podpisuj.sk team confirmed that EZZK is not maintained, MIRRI has no administrative access to it, and user creation goes through paid change requests to Ditec. A native OAuth callback for `login-app` will not be registered. Every integrating system uses the SOAP service with the person's own EZZK login instead.

### Verified contract

- Sources: MIRRI "Integračný manuál poskytovaných služieb modulu EZZK" v1.4 (2019-11-18), the live WSDL and XSD (snapshot in `docs/reference/ezzk-soap/2026-09-17/`), and calls on 2026-09-17.
- Endpoints: `/Iam.Core3.Svc.Wcf/LogInService.svc` and `/EZZK.Svc.Wcf/EZZKService.svc` on `ezzk-test.iomo.sk` and `ezzk.iomo.sk`.
- SOAP 1.2 with mandatory WS-Addressing `Action`, `MessageID` and `To`; the manual's empty header fails with `ActionMismatch`.
- `LogIn` with `ApplicationId` `EZZK` returns `TokenDescriptor`; authenticated calls send it as `Cookie: IamTokenDescriptor=<token>`. Without the cookie: HTTP 500 "service implementation object was not initialized". With an invalid token: result code 101.
- Inherited request fields (`ZiadostVypis`, object header) live in the `Ditec.IOM.EZZK.Dol` namespace; the manual's operation namespace fails with `DeserializationFailed`.
- `GetConversionRecordEvidenceNumber` has a required `EvidenceNumberAmount` element that the manual omits.
- Result codes differ from the manual: an empty `ReceiveConversionRecord` batch returns 110 (manual: 113). Unknown public lookup: 105.
- Test and production schemas differ only in `GetConversionRecord2` and where `OdpovedVypis` document fields sit.
- The test sample account returned ten unconsumed numbers (`260917-dD9DbFE4f7` form); production numbers look like `1563-260824-1`. The test service did not bind the person's IČO to the account.
- The unauthenticated `GetConversionRecordInformationPurpose` works against production from a Mac; record `1563-260824-1` was returned with its details.

### Certificates

- Production: public RapidSSL `CN=*.iomo.sk`, observed expiry 2026-09-21. If it lapses, EZZK fails for every integrator.
- Test: self-signed `CN=ezzk-test.iomo.sk`, SHA-256 `D1:6F:5B:61:72:0A:59:53:08:56:5D:D8:4E:32:93:5E:7A:7D:E8:3A:6C:2F:A8:F0:E6:41:34:51:ED:2B:12:E2`, expiry 2026-10-20. Autogram pins it in `EZZKEnvironment.pinnedCertificateSHA256`; update the pin when it is renewed.

### Implementation boundaries (part A)

- Production is read-only: login check, server time and public lookup. Number allocation is refused (`EZZKError.productionAllocationDisabled`) until part B builds and sends the signed record. `EZZKSOAPClient` refuses `evidenceNumbers`, `consume` and `receive` on production itself, before any network use, in addition to the adapter (`EZZKSOAPServiceAdapter`), the account controller (`EZZKAccountController`), Settings and `ezzk-probe`, each of which also refuses the same calls independently.
- On those consequential calls, a network error that may have reached the server, or an HTTP 5xx response, becomes `EZZKError.outcomeUnknown` and is never repeated; the caller is told the outcome is unknown rather than risking a duplicate submission.
- ZaKo refuses an evidence number fetched in another EZZK mode (`AttestationData.evidenceNumberMode`, `EZZKError.evidenceNumberFromOtherMode`) before any EZZK call, so a demo or test number never reaches a clause signed on production.
- `ReceiveConversionRecord` exists only as a request builder and client call; the app's `submit` throws `submissionUnavailable` and rows stay queued.
- `Result` 0 on `ReceiveConversionRecord` is acceptance for processing only; validation errors arrive later in the sender's eDesk. Podpisuj reports that EZZK marks many valid advocate records as invalid for a missing timestamp, so part B must add a qualified timestamp to the record signature.

### Live checks (2026-09-17)

`ezzk-probe` ran against the live services: `time`, `login` and `numbers` on test (the MIRRI manual's sample account, ten numbers returned), and `lookup 1563-260824-1` on production (read-only). The pinned test certificate handshake also passed live. `ezzk-probe` never prints the token; `login` prints only the account name. The sample account's login and password are not recorded here or anywhere else in the repository.

### Open work (part B)

1. ~~Build the record (`50349287.ConversionRecordOfPaperToElectronicDocument.sk` v1.0) in an `XMLDataContainer`, sign it with the mandate certificate and a qualified timestamp into its own ASiC.~~ Done in part B2: `ConversionRecordRenderer`, `ZakoRecordDeliveryBuilder`, engine local XDC route, qualified TSA endpoints outside Demo. See "Part B2" below.
2. ~~Send it with `ReceiveConversionRecord`~~, then open production allocation. Sending is done in part B2; production allocation and submission stay refused until part B3.
3. Switch to record form v1.2 from 2027-01-01. Done on 2026-10-16 together with the record-first order (`ZakoRegime`, `docs/ZAKO-2027-FINDINGS-2026-10-16.md`).

### Known gaps left open in part A

Recorded from the branch reviews so they are not rediscovered later. None of them blocks part A.

1. The test pin covers the whole certificate and expires 2026-10-20; a renewal breaks test mode until the app ships a new pin. Pinning the public key would survive a renewal that keeps the key. Still open.
2. ~~A stored password that has become wrong causes one `LogIn` per authenticated call, so repeated attempts can lock the account (`CORE-018`). There is no single-flight login and no backoff.~~ Closed in part B (task 7, commits `b3a12f7f..350b75ad`): `EZZKSOAPClient` keeps one `loginTask` at a time, stops repeating `LogIn` after a rejected password, and refreshes an expired token once.
3. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is honored only by the data protection keychain; the adapter uses the file based keychain, so the attribute is not in force. Reading `storedLogin` at launch also decrypts the password item, which prompts after an ad hoc rebuild. Still open.
4. Demo numbers look like production numbers (`1563-yymmdd-N`). A `DEMO-` prefix would make screenshots and test data unmistakable. Still open.
5. `EZZKSOAPClient` treats `notConnectedToInternet` as "nothing was sent" on consequential calls; URLSession can also report it when the network drops mid-request. Still open for `ReceiveConversionRecord`, now enabled in part B2: a mid-send drop before a real reply is not distinguishable from no connection at all, and both stay a resendable `queuedForSubmission` rather than `outcomeUnknown`.
6. ~~The ZaKo Done screen reads the current EZZK mode, not the mode the record was signed in, and the attestation form warns about a wrong-mode number only when signing starts.~~ Closed in part B2 (task 11/12): `EvidenceRecord.ezzkMode` is stamped at signing time and `EZZKStatusChecker` acts only on the EZZK the row's own mode names; a row of another mode is refused with `recordFromOtherModeMessage`.
7. ~~Three older ZaKo tests build `AppSettingsStore()` with the default controller, so they read the real Keychain (read only). `AppSettingsStore(ezzkAccountController:)` exists to switch them.~~ Closed in part B2 (task 13, commits `6eb4240f..ea9f8259`): `makeSettingsStore()` now defaults to an in-memory controller.
8. Settings has not been checked visually in the running app, and no sign-in has been done from inside the app bundle. Closed in part B1: the owner signed in from the built app and saved a test EZZK credential (see the ruling R6 note above); Settings has since been used interactively for every B1/B2 live check.

## Part B1 (2026-09-23)

### What shipped

- **Clause slot defect and fix:** the clause slot held a record (`AttestationClauseGenerator` emitted the record form 1.0, never the clause), so the delivered `.xml.xdcf` was not a clause at all; B1 renders the actual clause 1.3 through `ConversionFormModel` and `ConversionCertificateRenderer`, validates it against the official schema (`FormSchemaValidator`), and wraps it as an `XMLDataContainer` (`XMLDataContainerBuilder`), all assembled by `ZakoClauseDeliveryBuilder`.
- **Fingerprint and embedding defect and fix:** Chevron7 hashed the PDF/A, then embedded the clause XML into it and normalised again, so the delivered PDF no longer matched the fingerprint carried in its own clause; B1 stops embedding, hashes the final delivered PDF/A bytes, and signs PDF/A and clause XDC as two data objects of one ASiC-E (`SigningRequest.signsExtraFilesAsDataObjects`, machine protocol v1 `attachments`) instead of nesting an unsigned `kontajner.asice` inside the engine's own container.
- **Location codelist change:** `OriginalDocumentSecurityElementsLocation` now uses the official codelist 11 item codes (the page centre is `Mid`, not `Center`); physical-original security elements pick their location from the same codelist in both the add-element sheet and the inspector, instead of free text.
- **Phone limited to Demo:** ZaKo on the phone (AVM) uploads only the PDF and produces no clause XDC, so `isMobileSigningAvailable` is true only in EZZK Demo mode; Test and Production refuse it with `ZakoSessionStore.mobileOutsideDemoMessage`.
- **Record path unchanged in B1:** the register XML (still rendered by `AttestationClauseGenerator`) and the EZZK submission (`ReceiveConversionRecord`) were not touched in B1; they were part B2 work, listed under "Open work (part B)" above. Part B2 replaced `AttestationClauseGenerator`'s record output with `ConversionRecordRenderer`/`ZakoRecordDeliveryBuilder` and wired the submission; see "Part B2" below.

Official form files (record 1.0 and clause 1.3 schema and signer XSLT) live in `Chevron7/docs/reference/forms`, embedded into `Chevron7Kit` by `scripts/embed-official-forms.sh`. Codelist fixes also cover the legal-subject URI (`https://data.gov.sk/id/legal-subject/<IČO>`) and the `Iny` paper-size fallback. Design: `Chevron7/docs/superpowers/specs/2026-09-23-ezzk-part-b-design.md`.

### Live check with a SAK card

Live check with a SAK card: done 2026-09-24 (result below). This session could not run it (no SAK card). The owner runs one ZaKo conversion of a synthetic document in Demo mode with the SAK card, naming the source with a space and a diacritic (for example "Zmluva o dielo č. 3", so the source and clause file names carry both), then:

```bash
cd <output folder>
unzip -l *.asice
```
Expected: `mimetype`, `<new document name>.pdf`, `<number>.xml.xdcf`, `META-INF/manifest.xml`, `META-INF/signatures001.xml`, and no `.asice` inside, as in the podpisuj.sk reference.

```bash
unzip -p *.asice '*.xdcf' | grep -o '<NewDocumentName>[^<]*'
```
Expected: exactly the name of the `.pdf` entry listed above.

```bash
unzip -p *.asice '*.pdf' | openssl dgst -sha256 -binary | base64
unzip -p *.asice '*.xdcf' | grep -o '<ElectronicFingerprintValue>[^<]*'
```
Expected: the two values are equal.

```bash
unzip -p *.asice META-INF/signatures001.xml | grep -o '<xades:MimeType>[^<]*'
```
Expected: two matches, `application/pdf` and `application/vnd.gov.sk.xmldatacontainer+xml`, one `DataObjectFormat` per signed data object.

```bash
unzip -p *.asice META-INF/signatures001.xml | grep -o '<xades:SignatureTimeStamp'
```
Expected: at least one match, confirming the signature carries a qualified timestamp (Baseline T).

Result (2026-09-24, owner, I.CA SAK card): passed with source "Ukazkova_listina". The client ASiC-E held `mimetype`, the PDF, `<name>-<number>.xml.xdcf` and `META-INF`, with no nested `.asice`; the clause fingerprint equalled the PDF's SHA-256; both MIME types were present and the signature carried a `SignatureTimeStamp`. The record `1563-260924-1.record.asice` held only the record 1.0 XDC with a timestamp. That run also showed a naming gap against the podpisuj.sk reference: the clause said `<NewDocumentName>Ukazkova_listina copy.pdf</NewDocumentName>` while the PDF entry was `Ukazkova_listina copy-konvertovane.pdf` and the clause entry `Ukazkova_listina copy-konvertovane-260924-BcE299bb83.xml.xdcf`. Fixed the same day: both the PDF entry and NewDocumentName (clause and record) come from one sanitized value (`ConversionOutputNaming.containerDocumentName`), and the clause entry is `<number>.xml.xdcf` (`containerClauseName`).

## Part B2 (2026-09-23)

### What shipped

- **Record 1.0 rendered and sent:** `ConversionRecordRenderer` renders the conversion record (`50349287.ConversionRecordOfPaperToElectronicDocument.sk` 1.0) from `ConversionFormModel`, exactly in the shape of the record EZZK accepted on 2026-08-24. `ZakoRecordDeliveryBuilder` validates it against the libxml2-compatible derived schema and wraps it as `<number>.record.xml.xdcf`, built by `ZakoRecordDeliveryBuilder`. `EZZKSOAPClient.receive` (`ReceiveConversionRecord`) sends it and returns the request's WS-Addressing `MessageID` as `EZZKSOAPSubmissionReceipt`.
- **Record schema derivation:** the official record 1.0 `schema.xsd` does not compile in libxml2 (`xmllint`): the `IdentifierValue` pattern escapes `/` as `\/` and the record's identifier pattern differs from the clause's (8 or 12 digits, not 8 to 12). `docs/reference/forms/record-1.0/schema.validation.xsd` is a derived copy in which only that one pattern is rewritten to `https://data\.gov\.sk/id/legal-subject/([0-9]{8}|[0-9]{12})`; the XDC itself keeps referencing and digesting the official `schema.xsd`. A test pins that the two files differ only in that pattern.
- **Engine local route for the record:** a sign request whose single source is an `.xdcf` holding an `XMLDataContainer` root, with no attachments and no eForm, is signed locally (`SigningParameters.isPlainRecordXdc()`): `autoLoadEform=false`, `fsFormId=null`, `plainXmlEnabled=true`, ASiC-E, XAdES, bare MIME `application/vnd.gov.sk.xmldatacontainer+xml`, no network call to slovensko.sk. This mirrors the record EZZK accepted on 2026-08-24.
- **Qualified timestamp by construction:** outside Demo, ZaKo passes only the built-in qualified authorities (`TimestampAuthority.qualifiedURLs`) to the engine for both the client and the record signature, so a Baseline T output with a cryptographically valid timestamp is a build property rather than something inspected after signing. The QTS toggle is shown only in Demo.
- **Storage:** the signed record container is written to `Evidence/records/<record id>.asice` (the copy submission reads, `LocalEvidenceStore.storeRecordContainer`) and nowhere else; the Register saves it as `<number>.record.asice` ("Uložiť záznam…"). Since 2026-09-24 the folder next to the source holds only the client ASiC-E after a card signature (no loose PDF/A, clause XDCF or record copy). A record-signing failure leaves the client outputs delivered but marks the row `.recordUnsigned`; nothing is sent.
- **Evidence numbers reused, not just allocated:** `EvidenceNumberPool` remembers every number this app allocated and has not used yet, per EZZK mode and Bratislava day, and a fresh conversion reuses one before asking EZZK for a new one.
- **Submission states owned by one coordinator:** `EZZKSubmissionCoordinator` (rulings R9 to R12 and R16 in the plan ledger) decides every transition; `EZZKStatusChecker` runs it for every register row every five minutes, but only in a regular launch of Chevron7 (ruling R13, never in the `--web-signing` accessory mode), one row at a time, per-row EZZK mode, capped automatic sends per day (ruling R14), and never for a row written before part B2 (ruling R15, no stored `ezzkMode`) or a production row (ruling R16 is about late rows; production stays refused independently until B3).
- **Register safety:** an unreadable register is never overwritten after a failed load (its own timestamped `.unreadable-*` copy is kept beside it), and the first B2 write makes a one-time `register.backup-before-b2.json` copy so a register written by an older build can be recovered.
- **Tests never touch the real Keychain:** `makeSettingsStore(ezzkAccountController:)` now defaults every App test to an in-memory controller (`MemoryCredentialStore`), closing gap 7 above; this also stopped the hangs the owner hit once a real test EZZK credential was saved (ruling R6).

- **Result 106 (ruling R17):** 106 means the number is used by several records; EZZK stores duplicates rather than refusing them. A `ReceiveConversionRecord` result 106 therefore does not say what became of the record just sent: the row becomes `.outcomeUnknown` and the lookup resolves it. A lookup result 106 means EZZK holds a record under the number: the row is `.acceptedForProcessing` with code 106 and EZZK's text, never `.rejected` under the "other code" rule of ruling R12. Not yet observed live.

### Live checks on test EZZK (account `sys_zaktest1`, `ezzk-probe`)

- `GetConversionRecordEvidenceNumber` refuses with code 113 ("vyčerpaný nastavený limit aktuálne nespotrebovaných evidenčných čísiel") once the account's limit of unconsumed numbers is reached; it never returns a number already given out.
- `ReceiveConversionRecord` consumes the evidence number: right after a result-0 receipt a new number could be allocated again. No separate `ConsumeConversionRecordEvidenceNumber` call is needed for a sent record.
- 2026-09-24, 00:05 to 00:33 Bratislava: after midnight EZZK allocated a new number (`260924-SfE299Bb85`) even though `260923-NSE299bA61` was still unconsumed, confirming that a previous day's number no longer counts toward the account's limit once its Bratislava day has passed.
- A record for the 2026-09-23 number sent at 00:33, after that number's allocation day had ended, was accepted with result 0 (`MessageId ae6fbf72-...`): a late record is still accepted for processing (ruling R12). Its public lookup then answered code 1 ("evidovaný, ale nespracovaný") while EZZK processed it.
- The earlier, deliberately unsigned test record now looks up as code 12 "Neznámy obsah": EZZK processed and refused it. This is the live evidence behind ruling R12 (a lookup code other than 0, 1 and 105 means EZZK processed and refused the record, mapped to `.rejected`).
- Test EZZK's processing (the window between a result-0 receipt and the public lookup settling on a final code) took more than 18 minutes for these records; `EZZKSubmissionCoordinator.refreshStatus` polls hourly after the first check, so the app does not busy-loop the account while EZZK processes a record.

### Live check with the owner (Test mode, SAK card)

Pending (owner). This session could not run it (no SAK card, no access to the owner's test EZZK credential). The owner runs one full ZaKo conversion of a synthetic document named "Zmluva o dielo č. 3" in Test mode with the SAK card, then from `Chevron7/`:

```bash
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift run ezzk-probe lookup <number> --env test
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift run ezzk-probe record <number> --env test --out /tmp/record.asice
unzip -l /tmp/record.asice
```

`record` signs in with the credential Settings saved for Test mode, so the first run may prompt for Keychain access. Expected: the register row shows "Prijatý na spracovanie" and later "Spracovaný v EZZK"; the lookup finds the record; the stored object is our `<number>.record.xml.xdcf` inside a one-file ASiC-E carrying a Baseline T signature (`unzip -l` lists `mimetype`, `<number>.record.xml.xdcf` and `META-INF/signatures001.xml`, no nested `.asice`).

Result (2026-09-24, owner, I.CA SAK card, v0.7.0 plus local fixes): passed. Number `260924-BcE299bb83` came from the app, the Done screen showed "EZZK prijalo záznam na spracovanie", `lookup` found it (code 1, not yet processed), and `record` returned a one-file ASiC-E byte-identical to the local `260924-BcE299bb83.record.asice` (same SHA-256): `mimetype`, `260924-BcE299bb83.record.xml.xdcf`, `META-INF/signatures001.xml`, `META-INF/manifest.xml`, one `SignatureTimeStamp`. The client container passed the fingerprint and timestamp checks. Found on the way: a local build bundled an engine older than the B2 engine change, so the record failed with `SIGNING_UNAVAILABLE` (`build_app.sh` now refuses a stale engine); numbers requested in Settings and a stray probe number blocked allocation with code 113 (Settings numbers now join the pool); Demo reused `1563-<day>-1` after a relaunch (Demo now skips numbers in the register).

## Part B3 (2026-09-24)

### What shipped

- **One production policy:** `EZZKProductionPolicy` decides every consequential production call (allocating or consuming an evidence number, sending a record); read-only calls (login, server time, public lookup) never need it. `enabledForEveryone` is false until a later release flips it, once the owner's own first live production conversion is processed; until then the policy is refused everywhere unless the owner switch is set on this Mac (`EZZKProductionPolicy.ownerSwitchKey`, `defaults write app.slovensko.chevron7 EZZKProductionOwnerSwitch -bool YES`). `EZZKSOAPClient` and `EZZKSOAPServiceAdapter` both default to `.refused`; `EZZKAccountController.productionPolicy` (app default `.current(defaults: .standard)`, every test passing `.refused` explicitly) hands the same policy to both SOAP clients, to `EZZKStatusChecker` (`sendsInProduction`, `refusalReason(forMode:)`), and to the Register's and ZaKo's Done screen actions (`productionAllowed:`) and Settings' Produkcia texts. "Vyžiadať čísla" stays test only regardless, and `ezzk-probe` still hard-refuses `numbers`, `consume` and `receive` on production.
- **Demo signature stays in Demo:** `EZZKError.demoSignatureOutsideDemo` refuses before anything happens: outside Demo mode ZaKo neither allocates an evidence number nor authorizes with the Demo signing provider, so a build without the bundled engine or without a card identity can never cost a real number or reach EZZK by silently falling back to `DemoSigningProvider`.
- **106 lookup retried with the conversion time (ruling R-B3-1):** a lookup that first answers 106 (the number is shared by several records) is asked again once with the record's conversion time, the only thing that tells the duplicates apart; a 105 on that timed retry does not mean the record is gone, since the first 106 already proved the number is occupied, so the row still keeps code 106 and EZZK's text instead of being requeued for a resend, which would risk storing a duplicate under an occupied number.
- **Register safety on delete and resend:** `EZZKStatusChecker.delete(id:) -> Bool` now refuses to delete a row ZaKo still signs or the checker still sends (`busyDeleteMessage`), so an in-flight write can no longer resurrect a row the advocate believed gone; a manual "Odoslať znova" on a record whose evidence number is past its Bratislava day now carries the same lateness warning a pending row gets; the outcome-unknown message now names a server fault as well as a lost connection, since both leave the same doubt about what EZZK did with the request.

Production and the owner switch are documented in `Chevron7/docs/EZZK-INTEGRATION.md`, section "Production and the owner switch".

### Live check with the owner (Production, first real conversion)

Pending (owner). This session could not run it (a production submission needs the owner's own production EZZK account and a real legal document; production is a live register, never a place for a synthetic or test conversion). The recipe:

1. The owner sets the switch, relaunches, selects Produkcia in Settings and checks "Prihlásenie uložené" for the production account.
2. One real conversion the owner needs anyway (production is a legal record: never a synthetic or test document), with the SAK card; "Získať číslo", authorize.
3. Expected: Done screen "EZZK prijalo záznam na spracovanie"; `swift run ezzk-probe lookup <number> --env production` reports the record, later "Záznam je spracovaný"; `swift run ezzk-probe record <number> --env production --name "<EZZK name>" --ico <IČO> --out /tmp/prod-record.asice` returns the record byte-identical to the Register copy (compare with "Uložiť záznam…").
4. Result: not yet run.
