# Task 6 report: integration, findings, and verification

## Status

Complete for the defensible scope. The branch is not production ready and no production readiness claim is made.

## Changes

- Added focused EZZK receipt and uncertainty tests in `Autogram/Tests/AutogramKitTests/EZZKHTTPClientTests.swift`:
  - A typed, non-empty receipt is returned by the explicit submit path and does not mutate a local evidence row until the caller explicitly changes the row.
  - A 2xx response with an unknown body is rejected and leaves a signed local row non-submitted.
  - A submit timeout is surfaced as network uncertainty and leaves a signed local row non-submitted.
- Added `EZZKSessionController.isDemoMode` for presentation and submission guards. Existing demo mock calls remain intact, but dashboard and conversion workflow keep demo rows pending instead of assigning CEZZK `.submitted`.
- Hardened `URLSessionEZZKHTTPTransport` with a redirect-denying delegate and carried the validated OIDC discovery token endpoint through `EZZKTokenSet` into refresh. Added regressions for redirect suppression and a non-default discovered token path.
- Removed automatic evidence-number generation from conversion preflight. Evidence-number generation remains an explicit Settings action or explicit user action from the conversion form.
- Made `AppSettingsStore` distinguish empty, present, and unavailable OAuth token storage. Keychain errors fail closed rather than selecting demo mode.
- Updated Settings to show `Demo (lokálne)` and suppress sandbox or production endpoint presentation while in demo mode.
- Kept the exported legacy `HTTPSEZZKService` and `EZZKCredentials` types for source compatibility. No application wiring selects them. `AppSettingsStore` does not construct a password-authenticated EZZK service; legacy password storage is only read to prevent an old credentialed installation from entering demo mode.
- Updated `Autogram/docs/P2E-EZZK-FINDINGS.md` with implementation status, exact verification, callback and sandbox-account blockers, the unconfirmed POST receipt schema, the separate signed ASiC integration gap, and the demo limitation.

## Verification

Focused receipt tests:

```text
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter EZZKHTTPClientTests
```

PASS: 21 tests, 0 failures.

Complete package tests:

```text
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test
```

PASS: 187 tests executed, 3 skipped, 0 failures.

Application build:

```text
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" ./build_app.sh
```

PASS: `.build/arm64-apple-macosx/debug/Autogram.app`.

The build emitted existing warnings in unrelated `ZakoFlowViews.swift`, `ZakoSessionStore.swift`, and `SigningSessionStore.swift` code. No formatter or linter was run.

## UI inspection

The built app was launched and activated. A screen capture was attempted, but this session produced no usable app surface, so interactive Settings verification was not feasible. Source and build evidence confirm:

- sandbox is the default fixed environment;
- production is disabled behind the closed authority gate;
- login is disabled until the native callback is configured;
- EZZK password fields are not presented as OAuth login controls;
- no OAuth token is displayed;
- Settings submission is disabled without a validated signed ASiC-E capability.

## Findings and blockers

- Native callback remains blocked because the operator has not supplied a registered native redirect URI and callback scheme. The observed web redirect is rejected.
- No non-production EZZK sandbox account or credentials were available. No evidence-number request or conversion POST was made.
- The portal bundle confirms the `.asice` `files` payload and `POST /api/zzkservice/v1/zzk`, but the authoritative success body and complete error mapping remain unconfirmed from an operator-backed sandbox transaction. The client therefore requires a typed non-empty `receipt` and fails closed for unknown successful bodies.
- Redirects are denied before URLSession can forward Bearer headers or refresh-token POST bodies. Missing or unavailable OAuth token storage fails closed and does not expose the mock as a real EZZK service.
- Conversion preflight does not issue the consequential `/ec` POST. The request is now explicit only.
- The current conversion workflow does not produce and validate the separate signed record ASiC required by EZZK, and `EZZKClient` is not adapted to `EZZKServicing.submit(ConversionRecordEnvelope)`. The Settings submit control remains disabled.
- The app target has no XCTest target, so direct automated coverage of `EZZKSessionController.logout()` preserving evidence rows is not available. `LocalEvidenceStore` persists independently, and existing persistence coverage passed.
- Demo mock submission remains a compatibility-only local behavior. It is called for explicit demo actions, but dashboard and conversion workflow leave rows pending rather than represent demo activity as CEZZK acceptance; dashboard feedback labels it as demo-local.

## Commit

Commits after review: `68343aa8`, `b95f7b33`, `7820b22f`, `7caf0515`, `2806c7d1`
