# Chevron7 public CLI and local MCP

Status: approved by the owner on 2026-11-07; implemented in codex/cli-mcp. Automated verification passed; real signing acceptance remains pending (see ../../INTEGRATION-VERIFICATION.md).
Date: 2026-11-07.
Implementation baseline: `origin/main` at `b458d0591914ac83049f9ac89f948e342026cc53`, published as Chevron7 1.18.0 on 2026-10-23.

## Intent and observed starting point

Make Chevron7 a reusable signing and signature-inspection component for other applications, including LAWOSS, with a documented contract and dependable results. A host application must be able to request a signature, let its user confirm in Chevron7, and receive the actual output or an explicit failure. An AI agent must use the same functions without ever receiving a PIN.

The currently open Chevron7 checkout is the older `chevron7-streamlined` branch at `637b8741`. Implementation must start in an isolated worktree from the baseline above, retaining the newer main's cancellation, signature inspection and post-update bridge recovery. Root `AGENTS.md` and `CLAUDE.md` currently match; changes to them must remain mirrored.

Evidence reviewed:

- Main's `Chevron7WebBridge/WebSigningBridge.swift`, `WebBridgeCodeRequirement.swift`, `WebSignJobStore.swift`, the rendezvous agent, `Chevron7App/WebBridgeListener.swift`, `WebSigningCoordinator.swift`, `SignatureTreeLoader.swift`, signing provider and packaging scripts.
- LAWOSS's checked-out desktop module `apps/desktop/electron/lawoss-chevron7.mjs` detects an installation. Its local MCP configuration already accepts a command and argument array.
- The ongoing chat **Otestuj LAWOSS Test kompletne** and its active worktree `/Users/magneto/.codex/worktrees/lawoss-ui-integrations/lawoss` contain a newer `lawoss-chevron7-signing.mjs`. It hands one selected PDF to the bundled Quick Action, with a human confirmation and no PIN capture. It explicitly returns `returned`, not `signed`: a zero exit can mean either completion or cancellation. This is useful interim integration but not a result API. Do not overwrite that independently progressing worktree.
- Main still records the owner's existing direction: local stdio MCP over the validated XPC bridge, read operations first, signatures through the app's panel, no public HTTP listener, no automated guaranteed conversion.

## Approach

One signed native helper, `Contents/Helpers/chevron7`, offers CLI commands and `chevron7 mcp`. They share a versioned integration client and data contract. The running app owns the engine and settings; its existing LaunchAgent locates and starts it when needed.

```text
LAWOSS button / another application -> chevron7 <command> --json
LAWOSS OpenCode / other MCP host    -> chevron7 mcp (stdio)
                                      |
                               shared integration client
                                      |
                           validated XPC rendezvous + app endpoint
                                      |
                            Chevron7 integration service
                              /                    \
                      inspect / validate      signing confirmation panel
                                                      |
                                                existing engine
```

Alternatives considered:

1. Directly wrap `AutogramCLI-arm64`. It exists, but exposes internal machine protocols and card-secret handling, duplicates app configuration and engine sessions, and bypasses the established native confirmation flow. Do not make this the public integration contract.
2. Add an HTTP service. This would introduce a new listener, authentication and lifecycle while LAWOSS already supports local subprocesses. It also conflicts with the recorded local-only direction. Excluded from this design.
3. Bundled native CLI and MCP sharing the app service. Recommended and consistent with that existing owner decision. It requires Chevron7 installed on the same Mac and a logged-in graphical session for signing. It does not turn Chevron7 into a remote signing server.

No new daemon, Java runtime, Node runtime or Python runtime. Use the official Swift MCP SDK for protocol handling, pin a reviewed release at implementation, and test the negotiated versions against LAWOSS's actual MCP client. Do not implement an ad hoc JSON-RPC parser or claim support solely from an SDK version.

## Public surface

Names below are proposed stable v1 names. CLI defaults to concise human-readable output; `--json` emits one JSON result to stdout. Diagnostics and progress go to stderr. MCP stdout contains protocol messages only.

| CLI | MCP tool | Behavior |
| --- | --- | --- |
| `version --json` | covered by server metadata and status | Helper build and contract version, without starting the app |
| `status --json` | `chevron7_status` | App/bridge/engine availability and advertised features; no card login |
| `inspect FILE --json` | `chevron7_inspect` | Structural signature tree, documents and timestamps; no trusted-validation claim |
| `validate FILE --json` | `chevron7_validate` | Full signature validation, including nested entries and incomplete results |
| `sign FILE --output FILE --format pades\|asice --level B\|T --json` | `chevron7_sign` | Starts a job and opens Chevron7's confirmation panel |
| `jobs get ID --json` | `chevron7_job_get` | Reads job state and terminal result without consuming it |
| `jobs cancel ID --json` | `chevron7_job_cancel` | Cancels only the job owned by this integration session |
| `jobs save ID --output FILE --json` | `chevron7_job_save` | Retries delivery of retained signed bytes without signing again |
| `register list --limit N --cursor TOKEN --json` | `chevron7_register_list` | Paginated, read-only projection of existing register rows |
| `register get ID --json` | `chevron7_register_get` | Selected existing record, excluding full clause/XML and document bytes |
| `ezzk lookup RECORD_ID --json` | `chevron7_ezzk_lookup` | Read-only lookup for an existing row, in that row's EZZK environment |
| `mcp --root DIR [--allow-register] [--allow-ezzk]` | not a tool | Starts the MCP stdio adapter |

Expose read operations first during development; complete the same v1 delivery with confirmed signing and job handling. Do not present a read-only intermediate build as full signing support.

`sign` waits by default for the terminal result; `--no-wait` returns the job handle. MCP signing returns the handle immediately so a normal tool timeout cannot silently kill a person who is still entering their PIN. Both support the same request idempotency key. A repeated key with identical input returns the same job within its retention window; a changed payload under that key is rejected. No automatic retry of a signing action after an uncertain transport outcome.

Initial signing matrix: one PDF as PAdES or as a data object in ASiC-E; one PDF plus explicitly named attachments as one ASiC-E; a finished XDCF as ASiC-E on a card where supported by the current engine. Reject unsupported combinations before showing a panel. Adding a signature to an existing ASiC-E, raw XML form construction, visible signature positioning, batch signing and automated conversion are excluded from v1 signing. Existing PDF signatures must be preserved. Inspect/validate support the existing provider's PDF and ASiC-E inputs.

## Contract and truthfulness

Every CLI JSON envelope contains `apiVersion: 1`, a `requestId`, `ok`, and either `result` or `error: {code, message, retryable}`. Unknown major versions and unknown fields that could alter signing semantics fail explicitly. Additive result fields are allowed; consumers must ignore unknown result fields. Advertised capabilities include formats, levels, methods, limits and optional register/EZZK access; installed version alone never implies readiness.

A terminal signing result carries job ID, actual output format/level, canonical output path, output byte count and SHA-256, each input's SHA-256, and available signer metadata. Successful file delivery and signature validation are separate fields. A signature can be created successfully while trusted validation is indeterminate; do not turn that into either a false trusted success or a request to sign again.

Inspection never reports `valid` merely because a signature exists. Validation reports `valid`, `invalid`, `indeterminate` or `notValidated`, with reasons and validation time; includes the nested tree, skipped nested content and timestamp types. An unsigned document has an explicit unsigned result, not an empty successful validation. Preserve the provider's qualification distinctions. No claim of a qualified validation service is introduced.

CLI exit codes: 0 completed operation, 2 invalid arguments/request, 3 unavailable/incompatible installation, 4 busy, 5 user cancelled, 6 timeout, 7 file access/delivery failure, 8 engine or service failure, 9 outcome unknown, 10 completed validation not fully valid. JSON carries the finer stable error code. `inspect` finding an unsigned document is still a successful inspection; `validate` on unsigned, invalid or indeterminate input uses 10. MCP domain failures use tool error results with structured error codes; protocol errors remain MCP protocol errors.

## XPC roles and application service

Add an explicitly identified integration peer; the bundled helper's Developer ID must match the app's team. Keep the Safari interface separate from the integration interface, selected from the validated connection role, so Safari cannot enumerate the register or call EZZK. Both the helper and app validate their peers on every XPC connection, including the app endpoint obtained from the agent. Do not copy the developer probe's lack of client-side validation.

Use the existing rendezvous and its current stale-agent recovery. Readiness distinguishes missing app, missing/disabled agent, incompatible app/helper, unavailable engine and a ready integration. `version` and help are entirely local. Status may perform a bounded activation to test readiness, but cannot allocate evidence numbers, submit records, log into a card, or start the periodic EZZK sender. Accessory integration launch retains the existing rule that suppresses the sender and main window.

The app exposes transport-neutral handlers that use existing provider functions. CLI and MCP do not instantiate another signing engine, read private app preferences themselves or write `register.json`. A shared app-owned validation broker arbitrates every use of the provider's validation session, including the main UI, Safari and integrations. Route current UI validation through it as well. It uses a bounded queue and run ownership; cancellation of a queued task removes only that task, and `stopValidation` is called only for the active owner's run. A late result cannot reach a replacement request. Preserve the independence of signature execution and validation.

## Job lifecycle and confirmation

States: `awaitingConfirmation`, `signing`, `completed`, `cancelled`, `failed`, `outcomeUnknown`. At most one interactive signing operation is active across Safari and integrations. A conflicting request returns `BUSY`, not an invisible queue. The shared gate must include main-window card use or conservatively refuse while that provider is busy.

Use unguessable job handles and a session capability. A bare job ID is not authority to read a document or cancel another caller's request. The CLI stores the minimal session capability in a private user-owned state directory, mode 0700, with files 0600; it never prints the capability. CLI accepts `--session NAME`, with a strict plain-name syntax. The default terminal session is intentionally shared by that user's terminal commands; embedding applications must use separate profiles, and LAWOSS uses a different profile for each selected client. A long-running MCP process owns its own session and does not share the CLI's ownership. `jobs get/cancel/save` in a subsequent CLI invocation uses the selected CLI profile. These profiles isolate cooperating clients, not hostile processes running as the same OS user, which can read that user's files. Never label them authentication of LAWOSS.

Job metadata remains in app memory, capped at 64 jobs with terminal results retained for 30 minutes. Snapshots and signed bytes live in private app-managed temporary files, not an unbounded in-memory dictionary. Bound their combined retained bytes to 256 MiB and individual output to 64 MiB; reserve capacity before starting and advertise the limits. Never evict an active job to admit another one. The app owns destination writing even after `sign --no-wait` exits; check and reserve the output before confirmation and publish only after successful signing. `jobs save` writes the retained signed bytes to a new permitted destination and updates delivery metadata. An expired result or an app restart ends recovery availability and returns explicit expired/unknown, never a new signing request. Remove stale orphaned temporary files on the next launch without inferring a signature outcome from them.

Cancelling before or during confirmation dismisses only that job's panel. Cancelling during engine execution uses current provider cancellation and the session gate; it cannot revoke an already-created signature. Check for completed/delivered state before reporting cancellation. Lost connections or app restarts must never be represented as proof that no signature was produced. CLI Ctrl-C cancels its owned active job best-effort; return outcome unknown if the app cannot acknowledge. MCP process termination cancels owned pending jobs best-effort and releases session resources.

Input bytes are snapshotted before confirmation. The panel displays the actual snapshot, attachments, requested format and timestamp policy. It must identify an integration request truthfully, not call it Safari. A caller-supplied label such as LAWOSS is descriptive and not proof of that application's identity. No PIN argument, environment variable, MCP parameter or logging field. Existing card and mobile method constraints apply; the person chooses the available method in Chevron7. The request cannot silently enable a cloud signing route.

External signatures get an explicit integration origin in history, independent of browser retention settings. Their requested output is the durable delivery; optional app history must not delete that caller-owned file. Failure to archive an optional history copy cannot change a successful delivered signature into a failed one.

## Files and scope

CLI accepts local paths, resolves them once and opens only regular files, with size limits checked before reading and limits enforced during reading. No URL fetching and no arbitrary engine path, TSA URL, shell command or output naming template from the caller. Basenames are sanitized before entering the existing web signing model. V1 can retain the bridge's documented 32 MiB encoded-request ceiling, with raw-content limits advertised separately and combined attachment/base64 overhead checked before submission. Do not imply support for larger inputs until a separate streaming handoff is implemented.

MCP requires one or more launch-time `--root` directories, applying to input and output. These are host configuration, not changeable tool arguments. Resolve and check containment using real filesystem paths, including existing output parent directories, and reject symlink escapes and non-regular files. Snapshot via an already-open validated descriptor to avoid a path substitution between check and read. Document that MCP roots notifications alone are not authorization. LAWOSS supplies only the selected client's permitted roots; it must restart or replace the MCP session when that client scope changes.

Create output exclusively without overwriting input or any existing file, including case/alias/hard-link collisions. Use a reserved destination and atomic publication on the destination filesystem. A failed save after signing returns `OUTPUT_DELIVERY_FAILED` with the retained job and recovery metadata; retrying delivery must not sign again. The service owns snapshot lifetime and cleanup. Hash the delivered bytes, not a subsequently reopened caller-controlled path. Do not return document bytes in ordinary MCP content.

Register and EZZK reads require explicit launch-time grants (`--allow-register`, `--allow-ezzk` for MCP; corresponding flags for CLI register/EZZK commands). These grants are account-wide: current register rows have no trusted LAWOSS client identifier, and filesystem roots cannot scope them to a matter. Keep both grants disabled in the LAWOSS example and name their account-wide reach in help. Do not invent per-matter filtering from document names. Register list defaults to minimal metadata, not all stored personal fields. EZZK only looks up an existing record in its saved mode through the app’s read-only public SOAP lookup. It neither sends a record nor mutates its local status. A missing real evidence number or environment gives an explicit unavailable result. No allocating/consuming numbers, no receive/resend/delete, and no ZaKo operation through this API.

## LAWOSS and other clients

Proposed native invocation, using argument arrays rather than a shell:

```text
/Applications/Chevron7.app/Contents/Helpers/chevron7 --session lawoss-client-123 sign /client/input.pdf --output /client/input-signed.pdf --format pades --level B --json
```

Proposed LAWOSS MCP entry, fitting its existing export format:

```json
{
  "mcp": {
    "chevron7": {
      "type": "local",
      "command": [
        "/Applications/Chevron7.app/Contents/Helpers/chevron7",
        "mcp", "--root", "/absolute/path/to/selected/client"
      ],
      "enabled": true,
      "timeout": 120000
    }
  }
}
```

LAWOSS resolves the installed bundle rather than assuming `/Applications`, probes the CLI's contract/capabilities, and uses its JSON result to attach the new file to the selected matter. Detect the capability, not a guessed minimum app version. Existing Quick Action fallback may remain for old installations but must keep its weaker `returned` wording. Its independently active implementation is outside this Chevron7 code change; deliver a small reference JavaScript client and an integration guide so that its owner can replace the adapter without relying on internal engine layout.

Other clients use the same CLI or stdio server. The host controls when to launch MCP, avoiding a new permanent engine per workspace. Helper startup must not eagerly load Java, certificates, trusted lists or register contents. Local signing still needs a GUI session and the user present; no promise of unattended service use.

## Distribution, verification and completion

Add the executable to the Swift package, app bundle, development signing, release signing and notarization inputs. Assign one stable signing identifier in every path. Document direct bundle invocation first; a PATH symlink is optional convenience and must never replace an unrelated command. Keep help/version operational when the bridge is unavailable. Publish JSON examples, error codes, supported formats, size limits and MCP configuration in `Chevron7/docs/INTEGRATIONS.md`; update both root instruction files and release notes once shipped.

Required checks before claiming completion:

1. Contract fixtures decoded independently of Swift; stable JSON schema, unknown/malformed parameters, exit codes, non-ASCII filenames, clean stdout and help/version without engine startup.
2. Peer-role tests proving Safari cannot call integration-only methods and a wrong-team helper/app/agent is refused; compatibility mismatch has an actionable error.
3. File tests covering limits before allocation, attachments, traversal, symlinks, path substitution, output collisions, no overwrite and failed delivery recovery without re-signing.
4. Job tests covering duplicate request keys, changed payload under a reused key, busy arbitration, isolated clients, repeated result reads, TTL/capacity, cancellation races, lost response, restart and late result suppression.
5. MCP client interoperability: initialize/version negotiation, tool discovery/schema, structured results, domain errors, scopes, cancellation, stdout framing and reconnect behavior against the pinned SDK and LAWOSS's actual client.
6. Service tests using fake providers and temporary stores: unsigned/invalid/indeterminate/nested validation, read-only register/EZZK projections, no background submission, no credentials in JSON/logs. Keep RealStorageGuard protections and no real Keychain/network signing in tests.
7. Packaged CLI smoke test against an isolated synthetic app test harness, then one human-confirmed card signature and cancellation from an external client. A real card/phone end-to-end check must be reported as pending until actually performed. Do not claim it based on mocks or a process exit.
8. Existing Safari contract and cancellation regressions, native app tests, bundled helper signature verification, build and rename-boundary checks. Measure idle helper/process count to show it does not spawn a Java engine for each MCP workspace.

Builder choices: exact internal type/file names, use of the Swift argument parser versus a small strict parser, exact pinned SDK release after compatibility testing, and test fixture organization. No owner decision is needed for those details. The later owner instruction of 2026-11-07 authorizes testing, deployment and merging into main. A real signature still requires the person's confirmation in Chevron7. LAWOSS changes remain a separate integration task.

## External references

- Official Swift MCP SDK: https://github.com/modelcontextprotocol/swift-sdk (reviewed 2026-11-07; its README advertises stdio server support and protocol compatibility).
- MCP stdio transport: https://modelcontextprotocol.io/specification/2025-11-25/basic/transports (newline-delimited JSON-RPC, no non-protocol stdout).

This is an engineering design, not a new interpretation of Slovak law. No legal or company-registry lookup was needed or performed.

Builder review completed 2026-11-07. Clarifications incorporated: app-owned output delivery and recovery, explicit CLI profiles and same-user limits, account-wide opt-in register access, and shared validation arbitration including the existing UI. Thread context came from `list_threads` and paginated `read_thread` outputs; only relevant messages were reviewed, not every historical chat.
