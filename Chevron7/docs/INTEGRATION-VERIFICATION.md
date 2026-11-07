# CLI and MCP verification

Verified on 2026-11-07 in `codex/cli-mcp`, based on main `b458d059` (Chevron7 1.18.0), using Xcode 27.2. The signed and notarized 1.19.0 candidate from commit `e1adf71c` was installed and tested with a real card before release. Subsequent changes affect only the test fixture and verification documentation.

## Automated results

| Check | Result |
| --- | --- |
| Chevron7KitTests | 868 tests, 8 skips, 0 failures |
| Chevron7AppTests | 539 tests, 2 skips, 0 failures |
| Chevron7IntegrationTests | 22 tests, 0 failures |
| Chevron7CLITests | 7 tests, 0 failures |
| Total across the four completed suites | 1,436 tests, 10 skips, 0 failures |
| Observation and batch signing regression check | 74 tests, 0 failures |
| App target and complete `build_app.sh package` debug bundle | Passed |
| Actual stdio MCP negotiation, tool listing, scope/grant injection rejection and EOF | Passed for 2025-06-18 and 2025-11-25 |
| Safari `ditec-harness.mjs` and `background-harness.mjs` | All green |
| Strict rename-boundary check | Passed |
| Dependency licence copies, shell/JS syntax, diff whitespace, AGENTS/CLAUDE mirror | Passed |

The first complete test invocation finished the Kit, Integration and CLI suites but hung in an existing certificate-resolution fake: its started flag was published before its continuation, allowing a lost wake-up. After moving both writes into the same lock, the entire App suite completed. The totals above combine these completed suites; they do not claim that the interrupted invocation passed or count the focused rerun twice.

App service tests use synthetic providers, private temporary folders, memory preferences and fake credentials. They cover input isolation, output collisions, delivery recovery without another signature, repeated request keys, session ownership, late requests, finished XDCF handling, native-panel cancellation before/after signing starts, validation arbitration and read-only projections. The storage guard remained active. Automated XCTest runs finished before the live installed-app checks.

## Signed app acceptance

[Signed candidate workflow 42326359483](https://github.com/originalmagneto/chevron7/actions/runs/42326359483) built the 1.19.0 app and DMG with Developer ID and notarized both. Publishing, tag creation and appcast generation were disabled for that candidate. Local deep strict signature verification passed; Gatekeeper accepted the app as Notarized Developer ID. The helper has the expected `chevron7` identifier and the same Team ID as the app and agent.

The candidate replaced the installed app, with the previous 1.18.0 app retained as a local rollback copy. Tests reached the installed app through the signed bundled helper and registered agent. They used temporary synthetic PDFs and did not grant register or EZZK access.

| Live check | Result |
| --- | --- |
| CLI status through authenticated XPC | 1.19.0, engine ready, confirmation required |
| LAWOSS installed JavaScript MCP SDK 1.29.0 using `Client` + `StdioClientTransport` | 10 checks passed against the installed app and real engine |
| MCP unsigned PDF inspection and validation | Correct unsigned result |
| MCP native confirmation, then cancellation | Cancelled, no output, source unchanged |
| MCP repeated job reads and identical request key | Stable retained result, no duplicate signing |
| MCP separate process reading another session's job | Refused with `JOB_UNKNOWN` |
| MCP shutdown | Both helper processes exited cleanly |
| CLI real-card signature, confirmed by the owner in Chevron7 | Completed, PAdES Baseline B, 20,899-byte output |
| Repeated CLI job read | Identical completed result |
| Signed output inspection | One PAdES Baseline B signature |
| Signed output validation | Valid, `QESIG`, exit 0 after one read-only retry |
| File integrity | Source unchanged; output SHA-256 matches returned metadata |

The card test completed at 2026-11-07T02:20:30Z. Its source SHA-256 was `affb86de209e5b04d80e915a8efa8adab5d94175e51785c2cbbb253fa3886acb`; its output SHA-256 was `7f3b745d09138cd84d898072de54e868ef07169e5f3e5d4f5e0a96b2cb5d8e7c`. Signer identity and the signed PDF remain local and are not committed. The first trusted validation returned `indeterminate` and exit 10 because trusted lists were unavailable; one repeated validation against the same installed app returned `valid`, `validationPerformed: true` and qualification `QESIG`, with exit 0. No signing retry or code change was needed.

An additional isolated engine read check inspected and validated a synthetic unsigned PDF and an existing ASiC-E fixture using a temporary trust cache. The fixture had intact cryptographic integrity but an indeterminate trust result (`NO_CERTIFICATE_CHAIN_FOUND`), correctly kept separate from a valid signature claim.

## Reproduction and limits

From the Swift package directory, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

```sh
swift test
CHEVRON7_VERSION=1.19.0 ./build_app.sh package
python3 Tests/Chevron7CLITests/mcp-stdio-smoke.py .build/out/Products/Debug/Chevron7.app/Contents/Helpers/chevron7
codesign --verify --deep --strict .build/out/Products/Debug/Chevron7.app
node scripts/ditec-harness.mjs
node scripts/background-harness.mjs
bash scripts/check-rename-boundary.sh --strict
```

The stdio smoke test starts no signing request. Live acceptance requires the signed candidate, its authenticated bridge and a person confirming the synthetic document. It must not be inferred from mocks or process exit alone.

The new integration path was checked with one real I.CA card signature and cancellation. A phone signature, an eID card, the full main-window/Safari/Finder card matrix and real register/EZZK reads were not repeated in this acceptance run. LAWOSS's existing Quick Action integration remains unchanged; wiring its document action to the new API is a separate task. Its actual installed MCP SDK was exercised without editing or starting LAWOSS.

Implementation details that refine the design: the SwiftPM executable product is `chevron7-cli` to avoid colliding with `Chevron7` on case-insensitive filesystems; its bundled name remains `chevron7`. EZZK lookup uses the existing read-only public SOAP operation, with the environment stored on the register row, and needs no EZZK password. Cancelling an MCP read stops waiting; the underlying app check may continue until its bounded deadline. See [the integration contract](INTEGRATIONS.md) for limits and lifecycle rules.
