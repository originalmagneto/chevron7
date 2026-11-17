# Task 2 self-review report

## Files

- `Autogram/Sources/AutogramKit/EZZK/EZZKPKCE.swift`
- `Autogram/Sources/AutogramApp/EZZK/EZZKAuthenticationSession.swift`
- `Autogram/Tests/AutogramKitTests/EZZKEnvironmentTests.swift`

## Implementation review

- PKCE uses CryptoKit SHA-256 with unpadded Base64URL encoding.
- Verifier and state use independent cryptographically random 32-byte values.
- Callback parsing is strict: it requires a non-empty code and matching state, rejects duplicate or malformed parameters, and maps OAuth cancellation and authentication failures to errors without associated callback values.
- The app broker requires `isNativeCallbackConfigured` before discovery or starting `ASWebAuthenticationSession`.
- Authorization uses the configured redirect URI and callback scheme. The observed web portal redirect is never used.
- Discovery is fetched from the configured issuer and validates the metadata issuer, HTTPS, host, port, and endpoint authority before token exchange.
- Token responses require valid access token, token type, and positive expiration values; refresh token is optional but cannot be empty.
- The broker does not persist authentication state or tokens, and failures return before any token set is available.
- No callback URLs, authorization codes, tokens, or request bodies are logged.
- No em dash characters were added.

## Commit

Implementation commit: `65042adb` (`feat: add EZZK OAuth PKCE broker`)

## Focused verification

```text
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcrun swift test --build-path /tmp/ezzk-oauth-matching-build --filter EZZKEnvironmentTests
```

Result: PASS, 11 tests, 0 failures.

```text
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcrun swift build --build-path /tmp/ezzk-oauth-app-build --product Autogram
```

Result: PASS, Autogram product built successfully. Existing project warnings were emitted; no formatter, linter, or full project suite was run.

## Concerns

- Live ASWebAuthenticationSession and network token exchange are intentionally not exercised in focused unit tests because native callback configuration and operator-confirmed discovery metadata are not available in this workspace.
- The broker intentionally keeps native login unavailable until both callback configuration values are confirmed.

## Review fixes
Review-fix commit: `803c4d5e` (`fix: harden EZZK OAuth broker`)

- Replaced callback state equality with an equal-length byte-wise constant-time comparison. The focused callback regression now includes a same-length mismatch.
- Added a URLSession redirect delegate that permits only HTTPS redirects retaining the issuer host and normalized port, so token POST data cannot follow a cross-authority redirect.
- Added an `authenticationInProgress` guard set before discovery and cleared by `defer`, preventing overlapping authentication calls from overwriting the shared session continuation.
- Authorization URL construction now preserves existing endpoint query items and appends the OAuth parameters.

Review-fix verification:

```text
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcrun swift test --build-path /tmp/ezzk-oauth-fix-tests --filter EZZKEnvironmentTests
```

Result: PASS, 11 tests, 0 failures.

```text
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcrun swift build --build-path /tmp/ezzk-oauth-fix-build --product Autogram
```

Result: PASS, Autogram product built successfully. Existing project warnings remain.
