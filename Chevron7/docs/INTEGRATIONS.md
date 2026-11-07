# Chevron7 CLI and MCP integration (API v1)

Chevron7 provides one native helper in `Chevron7.app/Contents/Helpers/chevron7`. It offers a command-line interface and a local MCP server over standard input/output. Both connect to the installed app. No network listener, separate engine or additional language runtime is required.

Signing requires a logged-in macOS graphical session and the person's confirmation in Chevron7. The helper cannot accept a PIN, choose a mobile service silently, or perform guaranteed conversion. CLI/MCP availability does not imply that a card, driver or signing engine is ready: check `status`.

## Start here

Locate the installed application by bundle identifier `app.slovensko.chevron7` (the bundle may be renamed or outside `/Applications`), then invoke its helper using an executable and argument array, never a shell string.

```sh
CLI=/Applications/Chevron7.app/Contents/Helpers/chevron7
"$CLI" version --json
"$CLI" status --json
"$CLI" inspect /absolute/path/input.pdf --json
"$CLI" validate /absolute/path/input.pdf --json
"$CLI" --session lawoss-client-123 sign /absolute/path/input.pdf \
  --output /absolute/path/input-signed.pdf --format pades --level B \
  --request-key your-persisted-request-id --json
```

`version` and `--help` do not start the app. `status` can start it through the existing background connection. If unavailable, open Chevron7 and check the connection in Settings. The helper checks the signatures of both the background service and app; the app accepts the bundled helper as a distinct integration peer. Older installations without this interface cannot be used as API v1.

`sign` waits up to 900 seconds by default. `--timeout SECONDS` accepts 1 through 3600. `--no-wait` returns the job handle immediately. Ctrl-C requests cancellation of that caller's job; a lost acknowledgement is an unknown outcome, not proof that nothing was signed.

## Supported requests

| CLI | MCP tool |
| --- | --- |
| `status` | `chevron7_status` |
| `inspect FILE` | `chevron7_inspect` |
| `validate FILE` | `chevron7_validate` |
| `sign FILE --output FILE --format pades\|asice --level B\|T` | `chevron7_sign` |
| `jobs get ID` | `chevron7_job_get` |
| `jobs cancel ID` | `chevron7_job_cancel` |
| `jobs save ID --output FILE` | `chevron7_job_save` |
| `register list [--limit N] [--cursor TOKEN] --allow-register` | `chevron7_register_list` |
| `register get RECORD_ID --allow-register` | `chevron7_register_get` |
| `ezzk lookup RECORD_ID --allow-ezzk` | `chevron7_ezzk_lookup` |

Signing supports one PDF as PAdES or ASiC-E, a PDF plus `--attach FILE` entries as one ASiC-E, and a finished XDCF as ASiC-E where the card path supports it. It does not expose batch signing, existing-ASiC extension, raw XML form construction, visual signature placement or guaranteed conversion. Phone restrictions remain those of the app. `B` requests no timestamp; `T` requests timestamping under the app's supported policy.

Inspect and validate accept PDF and ASiC-E. Inspection reports structure and does not certify validity. Validation reports `validationState`, including unsigned/invalid/indeterminate outcomes, nested signatures, qualification details and timestamps. Technical validation is separate from a signature successfully being created and saved.

## JSON and jobs

`--json` writes exactly one JSON envelope to stdout. Diagnostics belong on stderr. Every envelope has `apiVersion`, `requestId`, `ok` and either `result` or `error`:

```json
{"apiVersion":1,"requestId":"example","ok":false,"error":{"code":"BUSY","message":"Another signature is in progress.","retryable":true}}
```

The job handle is `result.jobId`; its lifecycle is `result.state` (`awaitingConfirmation`, `signing`, `completed`, `cancelled`, `failed`, `outcomeUnknown`). `ok: true` for `jobs get` means the job was successfully queried, not necessarily signed. Check the state and any `result.error`. Completed signature metadata is nested under `result.result`, including `output`, input hashes, actual format and level, signer information and delivery information. Do not treat mere process exit, window closure or the existence of an empty destination reservation as success.

`jobs get` is non-consuming. Jobs expire 30 minutes after termination and do not survive an app restart. Ending an MCP process releases its session, so MCP job recovery is available only while that process remains connected. Up to 64 job records and 256 MiB of reserved retained bytes are permitted; output is limited to 64 MiB. Capacity can be reached before 64 jobs because output capacity is reserved before signing. Individual/combined input admission is bounded to 23 MiB; the encoded request ceiling is 32 MiB. Capabilities are the authoritative machine-readable limits.

Persist a `requestKey` before sending a signature. Identical inputs with the same key and session recover the original job while retained; changed inputs conflict. The CLI uses its initial response `requestId` as the key when none is supplied. After an uncertain transport outcome, query a known job or deliberately recover the identical request with its original key. Never automatically retry with a new key.

`OUTPUT_DELIVERY_FAILED` means signed bytes may already exist. Keep the job and use `jobs save ID --output NEW_FILE` with the same session. This saves retained bytes without another signature. An expired job cannot recover those bytes.

| Exit | Meaning |
| --- | --- |
| 0 | Operation completed (inspect may find no signatures) |
| 2 | Invalid arguments/request or refused scope |
| 3 | App, bridge, engine or compatible API unavailable |
| 4 | Busy or capacity exceeded |
| 5 | User cancellation |
| 6 | Timeout with acknowledged cancellation when applicable |
| 7 | File access or delivery failure |
| 8 | Engine/service failure |
| 9 | Outcome unknown, job unknown or expired |
| 10 | Validation completed but not fully valid |

CLI profiles live in the private `~/Library/Application Support/Chevron7CLI` directory. `--session NAME` accepts 1 to 64 ASCII letters, digits, hyphens and underscores; its capability stays in a mode-0600 file inside a mode-0700 directory. Names isolate cooperating clients, not hostile processes running as the same OS user. Use a distinct LAWOSS profile per selected client and repeat the same `--root` scope on later job commands. A live session cannot change its permitted roots. Do not put client names or secrets in the profile name. MCP uses a fresh in-memory capability for each process.

## MCP host configuration

The adapter uses the official [MCP Swift SDK 0.12.1](https://github.com/modelcontextprotocol/swift-sdk/tree/0.12.1) for negotiation, JSON-RPC, tool listing, calls and stdio framing. No status text is written to MCP stdout. Calls return the same envelope as structured content and JSON text, with tool errors for domain failures. `chevron7_sign` returns immediately; poll its job instead of increasing a tool call timeout to accommodate PIN entry.

LAWOSS/OpenCode configuration:

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

Hosts with an `mcpServers` configuration use the same executable as `command` and `["mcp", "--root", "/absolute/path/to/selected/client"]` as `args`.

One or more existing `--root` directories are mandatory. File arguments must be absolute local paths and fall within these configured roots. Roots apply to both input and output, including resolved symlink targets and existing output parent directories. Tool arguments and MCP roots notifications cannot expand them. Restart the MCP process when the selected client's scope changes. The app snapshots admitted input bytes before confirmation and never overwrites an existing destination. Ordinary tool content does not contain document bytes.

Register and EZZK tools are hidden and refused unless the process is started with `--allow-register` or `--allow-ezzk`. These are **account-wide** grants, not matter filters; filesystem roots cannot scope register records. They remain disabled in the LAWOSS example. EZZK lookup uses the read-only public SOAP lookup in an existing row's recorded environment; it cannot send a record or change its local status.

## LAWOSS adapter

See [the reference Node/Electron client](chevron7-client.mjs). It uses argument arrays, captures bounded JSON, retains the caller's idempotency key and polls a non-consuming job. It deliberately does not change LAWOSS, register an MCP server, or sign anything by itself. Integrate it into the existing document action after the host has selected the permitted client root and output. Verify the returned hash before attaching the delivered file to a case.

An older Quick Action integration can only report that control returned. It must not be presented as the same API contract or infer a successful signature from exit zero.

## Build and isolated protocol checks

The Swift package product is named `chevron7-cli` so it can coexist with the `Chevron7` app executable on a case-insensitive macOS filesystem. Packaging copies it to `Contents/Helpers/chevron7` and signs that helper with the integration identity. The public bundle command remains `chevron7`.

From the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --package-path Chevron7 --product chevron7-cli
python3 Chevron7/Tests/Chevron7CLITests/mcp-stdio-smoke.py Chevron7/.build/out/Products/Debug/chevron7-cli
```

The smoke test starts no signing request and does not contact the installed app. It checks local help/version, JSON error output, rejection of PIN arguments, MCP negotiation, advertised schemas, refusal of scope injection and EOF shutdown. Unit tests use isolated session files and injected signing callbacks. Real-card and phone signing still require a separate manual acceptance check.

Cancellation of an inspection or validation tool stops that client's wait. An already admitted read in the app may continue until its normal bounded completion; cancellation does not stop another caller's validation. Signing cancellation uses the exact job owner and handle, including cancellation while the initial begin reply is in flight.
