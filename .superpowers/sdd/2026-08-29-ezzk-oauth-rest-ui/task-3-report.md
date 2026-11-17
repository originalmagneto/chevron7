# Task 3 report: typed EZZK REST client

## Files

- `Autogram/Sources/AutogramKit/EZZK/EZZKAPIModels.swift`
  - Added Codable, Sendable, Equatable available-evidence, ASiC file, file request, and strict submission receipt models.
- `Autogram/Sources/AutogramKit/EZZK/EZZKHTTPClient.swift`
  - Added injected `EZZKHTTPTransport` and `URLSessionEZZKHTTPTransport`.
  - Added serialized `EZZKClient` actor with fixed environment URL construction, HTTPS and host checks, Bearer authentication, refresh-token exchange, one-refresh and one-401-retry behavior, HTTP Date server time, read-only bounded exponential retry, status mapping, consequential request validation, opaque record/original responses, and strict unknown-receipt rejection.
  - Added validation of final API and issuer response URLs so redirected responses cannot be accepted from an unexpected host, port, path, or insecure scheme.
- `Autogram/Tests/AutogramKitTests/EZZKAPIModelsTests.swift`
  - Added model decoding and observed ASiC payload round-trip tests.
- `Autogram/Tests/AutogramKitTests/EZZKHTTPClientTests.swift`
  - Added injected-transport behavioral coverage for URL/header construction, routes, Date handling, refresh/retry limits, missing-token behavior, read-only timeout/rate-limit retries, status mapping, consequential validation, payloads, receipt handling, and final response host validation.

`EZZKService.swift` was intentionally unchanged because the new typed client does not require a compatibility boundary change and the legacy mock/password service remains preserved.

## Commits

- `ec7bb773 feat: add typed EZZK REST client`
- `bb4692ef docs: record typed EZZK REST client task`
- `adf05fc1 fix: validate EZZK final response hosts`

## Tests

- `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter EZZKAPIModelsTests` passed: 4 tests.
- `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --filter EZZKHTTPClientTests` passed: 15 tests.
- The redirect regression test was observed failing before the fix and passing afterward.

## Concerns

- The complete sandbox contracts for `POST /ec` and `POST /zzk` remain externally unconfirmed. The client accepts the observed evidence-number response variants and only treats a response with a non-empty `receipt` field as a successful submission receipt; unknown successful bodies remain `invalidResponse`.
- A native callback registration and a non-production sandbox account are still required before live authentication or consequential smoke testing.
- Swift test output includes pre-existing warnings outside these files; no formatter, linter, or full project suite was run.

### Follow-up fix

- `adf05fc1` also needed a stricter issuer response check. `isValidIssuerResponseURL` now compares normalized ports, rejecting same-host HTTPS responses on non-default ports.
- Added `testRefreshRejectsIssuerResponseOnNonDefaultHTTPSPort`, which failed before the fix and passes afterward.
- Re-ran focused suites: `EZZKAPIModelsTests` 4 passed and `EZZKHTTPClientTests` 16 passed.
