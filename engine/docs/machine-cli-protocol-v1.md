# Autogram machine CLI protocol v1

## Scope and compatibility

Protocol v1 is a non-interactive JSON Lines interface for the native macOS Autogram CLI. It supports `CAPABILITIES`, `DRIVERS`, `CERTIFICATES`, `INSPECT`, and `SIGN`. The protocol version is exactly integer `1`.

Call the application with `--cli --machine-readable --protocol-version 1 --operation <OPERATION>`. Send exactly one UTF-8 JSON request object through standard input. The command-line operation and the request operation must match.

Clients must reject a protocol version they do not support. Autogram rejects unsupported request versions with `PROTOCOL_UNSUPPORTED_VERSION` and exit code `64`. New protocol versions require a new compatibility agreement. v1 clients must not infer behavior from unknown fields or event types.

## Platform requirements

- macOS 27 or later.
- Apple silicon.
- Native ARM Autogram 2.7.5 or later.
- I.CA SecureStore 8.3.1 or later when using I.CA.
- Each PKCS#11 dynamic library must contain an `arm64` slice.

There is no Intel, Rosetta, translated-runtime, JavaFX, or interactive fallback in machine mode.

## Request envelope

Every request has exactly these top-level fields:

```json
{
  "protocolVersion": 1,
  "requestId": "request-1",
  "operation": "CAPABILITIES",
  "payload": {}
}
```

`requestId` is a non-empty client correlation identifier and is returned as `sessionId` in events. The request schema is in `protocol/v1/schema/request.schema.json`.

Operation payloads are:

- `CAPABILITIES`: `{}`.
- `DRIVERS`: `{}`.
- `CERTIFICATES`: `{"driver":"driver-id","pin":"PIN"}`.
- `INSPECT`: `{"files":[{"id":"file-1","source":"/absolute/source.pdf","target":"/absolute/output.pdf"}]}`.
- `SIGN`: `{"driver":"driver-id","certificateSerial":"serial","pin":"PIN","signatureLevel":"PAdES_BASELINE_T","timestamp":{"required":true,"servers":["https://tsa.example"]},"files":[...]}`. A file may add `attachments`, absolute paths signed as further data objects of one ASiC-E (XAdES only). eForm attributes (`eform`) and visible signatures are protocol v2 features (`--protocol-version 2`, one long-lived session), which share the signing policy below.

Sources and targets in `INSPECT` and `SIGN` must be absolute normalized paths. Signing never overwrites an original or an existing target.

`driver.detected` returns installed middleware entries. Each entry includes `tokenPresent`: `true` when the PKCS#11 library reports a connected token, `false` when it reports none, or `null` when presence cannot be safely probed. Clients may use only `true` entries for automatic card selection and must retain a compatibility fallback for all-unknown legacy responses.

## Event envelope

Standard output contains one JSON object per line. Every event has this envelope:

```json
{
  "protocolVersion": 1,
  "type": "session.completed",
  "sessionId": "request-1",
  "emittedAt": "2026-08-06T00:00:00Z",
  "fileId": null,
  "payload": {}
}
```

The event schema is in `protocol/v1/schema/event.schema.json`. Expected event types include `session.started`, `driver.detected`, `certificates.available`, `inspection.completed`, `file.signingStarted`, `file.completed`, `file.failed`, `session.completed`, and `session.failed`.

Each accepted request ends with one terminal `session.completed` or `session.failed` event. It is flushed before the machine process exits. A file failure is communicated with `file.failed`; it does not prevent later files from being processed and does not change the completed-request exit code.

## Errors and process exit codes

Terminal machine errors use this stable payload:

```json
{
  "code": "DRIVER_UNAVAILABLE",
  "messageKey": "machine.error.unavailable",
  "fallbackMessage": "A required local service is unavailable.",
  "retryable": true,
  "recovery": "Connect the required token or service and retry."
}
```

| Exit code | Meaning |
| --- | --- |
| `0` | Request completed, including requests with per-file failures reported as events. |
| `64` | Protocol or request error. |
| `69` | Required driver, service, token, or platform capability is unavailable. |
| `70` | Internal machine-mode failure. |

Stable error codes include `PROTOCOL_INVALID_REQUEST`, `PROTOCOL_UNSUPPORTED_VERSION`, `OPERATION_MISMATCH`, `PIN_INCORRECT`, `PIN_LOCKED`, `OPERATION_CANCELLED`, `DRIVER_NOT_FOUND`, `DRIVER_UNAVAILABLE`, `TOKEN_NOT_PRESENT` (driver installed, no card in the reader), `TOKEN_NOT_RECOGNIZED` (card does not match the driver), `MACHINE_PLATFORM_UNSUPPORTED`, `SIGNING_UNAVAILABLE`, `TRUSTED_LIST_UNAVAILABLE`, and `INTERNAL_ERROR`. An `INTERNAL_ERROR` `fallbackMessage` names the exception classes along the cause chain, never their messages.

## Privacy and signing guarantees

PINs are supplied only through standard input and are cleared after use. Machine output never contains a PIN, request payload, client path from an unknown exception, raw exception message, exception class name, or stack trace. Do not treat standard error as protocol output.

## Signing policy

Machine signing accepts PDFs, existing ASiC containers (a new signature is added to the container), XMLDataContainer `.xdcf` files (signed alone), plain text and PNG files, and XML eForms when the request carries `eform` attributes (v2).

- `PAdES_BASELINE_T` and `XAdES_BASELINE_T` are always accepted and require a timestamp (`timestamp.required` true with at least one TSA URL). The new signature's timestamp must be cryptographically valid; with a visible signature the output must also be `PAdES_BASELINE_T` with a timestamp that validates as `TimestampQualification.QTSA`.
- `XAdES_BASELINE_B` is accepted for state-portal requests (an eForm, or XAdES around a PDF, which always becomes an ASiC-E). `PAdES_BASELINE_B` is accepted only with `eform` attributes (v2). Baseline B carries no timestamp; its output is checked for exactly one new signature of the requested level with intact cryptography.
- XAdES output is an ASiC-E container. `files[].attachments` (XAdES only, never with `eform`) adds further files as data objects of one new ASiC-E; no attachment may itself be a container.
- Every output must contain exactly one new signature with intact cryptography and keep every earlier signature.

Supplying a TSA URL alone does not prove that the timestamp is qualified.
