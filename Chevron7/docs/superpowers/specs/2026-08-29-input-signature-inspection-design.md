# ZaKo Input Signature Inspection Design

**Date:** 2026-08-29
**Status:** Approved for implementation

## Problem

The ZaKo P→E flow currently has no explicit input-signature verification gate. The existing signing inspection API returns an empty list when inspection fails, which cannot distinguish a document with no electronic signatures from a verifier that was unavailable. That ambiguity is unsafe before authorization.

## Decision

Authorization may proceed only when input-signature verification has the explicit state `valid`.

The states are:

- `valid`: inspection completed and every discovered input signature is valid. A document with no electronic signatures is valid when inspection completed successfully.
- `invalid`: inspection completed and at least one discovered signature is invalid.
- `unknown`: inspection completed but at least one signature cannot be conclusively classified.
- `unavailable`: the input cannot be inspected or the verifier is unavailable.

`invalid`, `unknown`, `unavailable`, and an inspection that has not run are all blocking states. An empty signature list is never used to represent an inspection failure.

## Architecture

Add an explicit `InputSignatureInspectionResult` model in AutogramKit. The result contains the state, discovered `DocumentSignatureInfo` values, the oldest relevant valid timestamp when one exists, and a human-readable detail.

Extend `QualifiedSigningProviding` with a status-bearing input inspection method that has a default unavailable implementation. Existing providers remain source-compatible. The engine bridge maps its low-level inspection output to the explicit result. The existing list-returning method remains available for the general signing UI and is not used as the ZaKo compliance gate.

`ZakoSessionStore` owns the current result. It resets the result when a new source document or analysis session starts, runs inspection for the current source, and ignores results belonging to an obsolete `currentRecordID` or cancelled task. `AttestationPreflight` receives the result and emits a dedicated validation error unless the state is `valid`. `authorizeAndSign()` uses the same preflight result immediately before conversion and signing, so no authorization path can bypass the gate.

## Data flow

1. ZaKo loads a PDF and creates a new session record identifier.
2. The input signature inspector runs against the source URL.
3. The result is stored only if its session identifier still matches.
4. The UI can display the explicit state and detail.
5. Preflight accepts the result only when its state is `valid`.
6. Authorization stops before PDF/A conversion when the state is not `valid`.

## Aggregation rules

For a completed inspection:

1. Any invalid signature produces `invalid`.
2. Otherwise, any unknown or indeterminate signature produces `unknown`.
3. Otherwise, the result is `valid`, including zero signatures.
4. The oldest relevant valid signing timestamp is the minimum valid signature or timestamp time available from the inspection result. Missing timestamps do not make an otherwise valid signature invalid.

A transport, parser, missing-file, or unsupported-provider failure produces `unavailable` with a non-empty detail. The service does not infer validity from an empty result after a failure.

## Error handling and security boundaries

The preflight error identifies input-signature verification as incomplete and includes the blocking state. The gate is fail-closed. The status is diagnostic and does not claim independent production validation of PAdES, XAdES, CAdES, certificate chains, or qualified timestamps until the authoritative contract and verifier are available.

No automatic confirmation, override, or fallback converts `unknown` or `unavailable` into `valid`. Existing non-mandate override behavior remains separate and cannot bypass input-signature verification.

## Testing

Add focused tests for the inspection service and preflight gate:

- valid signatures produce `valid`;
- an empty result from a successful inspection produces `valid`;
- an invalid signature produces `invalid`;
- an indeterminate or unknown signature produces `unknown`;
- verifier failure or unavailable provider produces `unavailable`;
- every state except `valid` blocks ZaKo authorization preflight;
- a stale inspection result cannot replace the result for a newer source session.

Tests use deterministic injected inspectors and real model/preflight behavior. They do not claim external validator conformance.

## Non-goals

- Implementing a full independent DSS or PDFBox signature verifier.
- Declaring PDF/A-2b production-ready.
- Defining the authoritative ZaKo, EZZK, XSD, or signature contract.
- Changing the existing signing workflow outside the ZaKo input gate.
