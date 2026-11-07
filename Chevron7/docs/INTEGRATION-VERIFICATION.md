# CLI and MCP verification

Verified on 2026-11-07 in `codex/cli-mcp`, based on main `b458d059` (Chevron7 1.18.0), using the installed Xcode 27.2 toolchain. This is an unreleased development build.

## Automated results

| Check | Result |
| --- | --- |
| App target and complete `build_app.sh package` debug bundle | Passed |
| Integration, CLI, web bridge/signing, signature history, batch signing, ZaKo E2E and storage guard regressions | 232 tests, 0 failures, 1 existing production E2E test skipped |
| Follow-up after final cancellation and prompt fixes | 78 tests, 0 failures |
| Actual stdio MCP handshake, tool listing, scope/grant injection rejection and EOF | Passed for 2025-06-18 and 2025-11-25 |
| LAWOSS's installed JavaScript MCP SDK 1.29.0, `Client` + `StdioClientTransport` | Connected, listed tools, received structured argument refusal and closed cleanly |
| Safari `ditec-harness.mjs` | All green |
| Strict rename-boundary check | Passed |
| Complete bundle `codesign --verify --deep --strict` | Passed, local ad hoc build |
| Dependency licence copies, shell/JS syntax, diff whitespace, AGENTS/CLAUDE mirror | Passed |

The app service tests use synthetic providers, private temporary folders, memory preferences and fake credentials. They cover input isolation, output collisions, delivery recovery without another signature, repeated request keys, session ownership, late requests, finished XDCF handling, native-panel cancellation before/after signing starts, validation arbitration and read-only projections. The storage guard remained active.

The protocol checks run the real helper process. The LAWOSS compatibility check imports its existing installed SDK without editing or starting LAWOSS. Neither check requests a real signature or contacts an EZZK service.

Reproduce from the Swift package directory, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

```sh
swift test --filter 'Integration|CLI|WebBridgeCodeRequirement|WebSign|SignatureTreeStore|SignedDocumentStore|SigningBatchTests|ZakoE2EFlowTests|RealStorageGuardTests'
CHEVRON7_VERSION=1.18.0 ./build_app.sh package
python3 Tests/Chevron7CLITests/mcp-stdio-smoke.py .build/out/Products/Debug/Chevron7.app/Contents/Helpers/chevron7
codesign --verify --deep --strict .build/out/Products/Debug/Chevron7.app
node scripts/ditec-harness.mjs
bash scripts/check-rename-boundary.sh --strict
```

## Remaining live acceptance

- Run the bundled helper through the registered agent into the new app, then confirm one real card signature, one cancellation and one mobile signature. Automated tests cover the service and stdio layers separately; they do not replace this complete XPC and signing check.
- Connect LAWOSS's document action to the new API and verify the returned file/hash before attaching it to a case. Its existing Quick Action integration was left intact.
- Developer ID signing, notarization, release packaging and deployment remain the release workflow's responsibility. The installed application was not replaced.

Implementation details that refine the design: the SwiftPM executable product is `chevron7-cli` to avoid colliding with `Chevron7` on case-insensitive filesystems; its bundled name remains `chevron7`. EZZK lookup uses the existing read-only public SOAP operation, with the environment stored on the register row, and needs no EZZK password. Cancelling an MCP read stops waiting; the underlying app check may continue until its bounded deadline. See [the integration contract](INTEGRATIONS.md) for limits and lifecycle rules.
