# Autogram macOS CLI automation

Autogram has a human CLI and a versioned machine CLI. Use the machine CLI for non-interactive automation. Its protocol is documented in [Machine CLI protocol v1](machine-cli-protocol-v1.md).

## Machine CLI requirements

- macOS 27 or later.
- Apple silicon.
- Native ARM Autogram 2.7.5 or later.
- For I.CA tokens, I.CA SecureStore 8.3.1 or later.
- Every PKCS#11 dynamic library used by the machine CLI must contain an `arm64` slice.

Machine mode has no Intel, Rosetta, translated-runtime, JavaFX, or interactive fallback. Do not start it if any requirement is not met. A missing driver, service, platform capability, or required token is reported with exit code `69`.

## Starting machine mode

Pass a single JSON request through standard input and select the same operation on the command line:

```bash
printf '%s\n' '{"protocolVersion":1,"requestId":"example-1","operation":"CAPABILITIES","payload":{}}' \
  | AutogramApp --cli --machine-readable --protocol-version 1 --operation CAPABILITIES
```

Read JSON Lines only from standard output. Standard error is for local diagnostics and is not part of the protocol. The process exits after it has emitted and flushed its terminal event.

## Signing policy

Machine signing accepts PDFs, existing ASiC containers (a new signature is added to the container), XMLDataContainer `.xdcf` files (signed alone), plain text and PNG files, and XML eForms when the request carries `eform` attributes.

- `PAdES_BASELINE_T` and `XAdES_BASELINE_T` are always accepted and require a timestamp (`timestamp.required` true with at least one TSA URL). The new signature's timestamp must be cryptographically valid; with a visible signature the output must also be `PAdES_BASELINE_T` with a timestamp that validates as `TimestampQualification.QTSA`.
- `XAdES_BASELINE_B` is accepted for state-portal requests (an eForm, or XAdES around a PDF, which always becomes an ASiC-E). `PAdES_BASELINE_B` is accepted only with `eform` attributes. Baseline B carries no timestamp; its output is checked for exactly one new signature of the requested level with intact cryptography.
- XAdES output is an ASiC-E container. `files[].attachments` (XAdES only, never with `eform`) adds further files as data objects of one new ASiC-E; no attachment may itself be a container.
- Every output must contain exactly one new signature with intact cryptography and keep every earlier signature.

Protocol v1 is described in `docs/machine-cli-protocol-v1.md`; eForm attributes and visible signatures need protocol v2.

A TSA URL alone does not prove qualification. Verify the timestamp in the signed output against the applicable trusted list before accepting it as qualified.

## Human CLI

The existing `--cli` mode remains available for interactive use. Its arguments and output are separate from the machine protocol and are not a fallback for machine mode.
