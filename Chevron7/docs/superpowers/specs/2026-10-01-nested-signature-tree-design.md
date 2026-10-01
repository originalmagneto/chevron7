# Signature tree: container signatures and signatures inside embedded documents

Date: 2026-10-01. Status: design approved in conversation by the owner on 2026-10-01; written spec awaiting review.
Builds on: PR originalmagneto/chevron7#30 (a signed PDF wrapped into a new ASiC-E keeps its PAdES signatures inside the unchanged data object).

## Goal

When a document carries signatures on more than one level, an advocate sees at a glance where each signature sits, what it covers and whether it holds, verified with the same strictness on every level.

The case that started this: `report_podpisane_podpisane.asice` is an ASiC-E whose XAdES signature covers `report_podpisane.pdf`, and that PDF carries its own PAdES signature. Today "Overenie podpisov v súbore" lists only the container's XAdES signature, so the document looks like it has one signature when it has two.

Success means:

- Every signature in the document is shown once, under the level it belongs to (the container, or a named document inside it), with its own state.
- Signatures are verified against the EU trusted lists (DSS, LOTL) on every level, not only structurally.
- A summary states the worst result across the whole tree, and an indeterminate result is never shown as valid.
- The advocate can repeat the verification.
- No document leaves the Mac for verification unless the advocate takes it to an online service themselves.

## Decisions taken with the owner

| Question | Decision |
|---|---|
| Where full (trusted list) validation runs | Wherever signatures are shown in the signing flow: on opening a document (prepare) and in "Overenie podpisov v súbore" after signing. The structural result shows at once and the full result replaces it. Batch signing and ZaKo keep today's structural input check. |
| Depth | PDF and ASiC data objects inside a container are verified, one level deep. A PDF or ASiC found one level further is listed as not verified, never silently hidden. |
| Summary | Every signature keeps its own state. A summary line on top reports the worst result across the tree. Indeterminate is its own category and never counts as valid. |
| Approach | The engine returns the tree (approach 1). Rejected: assembling the tree in Swift through PREVIEW and separate VALIDATE calls (more processes, repeated trusted list loading, legal documents in temporary files), and a flat list with paths (hierarchy lost and rebuilt). |
| Repeat | An "Overiť znova" button repeats the full validation. |
| Online services | Not integrated. A link "Overiť aj na slovensko.sk" opens the state's informative verification service in the browser; the advocate uploads the file there. Results in the app are labelled informative. |

## Facts about today's code

- The app only ever runs structural inspection. `AutogramCLIEngine.inspect` (`Chevron7/Sources/Chevron7Kit/EngineBridge/CLI/AutogramCLIEngine.swift:114-136`) sends machine protocol v1 INSPECT, which always uses `new MachineInspectionService()` (structural, `engine/.../ui/machine/MachineCliApp.java:22`). Structural mapping sets `indication` to `INDETERMINATE` for every signature (`MachineInspectionService.mapStructuralSignature`), so every engine-inspected signature shows "Neurčitý".
- Trusted validation exists end to end but has no app caller: v2 VALIDATE (`engine/.../ui/machine/v2/MachineV2CliApp.java:152-165`) initializes the trusted lists once per process (`ValidationSession`, `MachineTrustService`: 60 s limit, `TRUSTED_LIST_UNAVAILABLE`, LOTL file cache with 6 h expiry) and runs `MachineInspectionService.forTrustedValidation`. `AutogramCLIEngine.validate(files:)` (`:170-192`) is called only from a test.
- Trusted `inspect(Path)` already returns the container's `documents` and per-signature coverage (`readTrustedInspection`, `validator.getOriginalDocuments`); structural inspection returns `documents` but no coverage; trusted `inspect(byte[])` returns neither.
- Nothing inspects a document inside a container for its own signatures. `extractEmbeddedDocument` serves PREVIEW only.
- "QTS" in `SignatureInfoRow` (`Chevron7/Sources/Chevron7App/Views/SigningFlowViews.swift:861`) comes from `hasQualifiedTimestamp`, which `AutogramCLIEngine.signatures(in:)` (`:647-676`) sets when `qualifiedTimestampValid` is true or when any timestamp is merely cryptographically intact. After structural inspection it therefore means "a timestamp is intact", not "a qualified timestamp was verified".
- `EngineBridgeSigningProvider.inputSignatureInspection` (`:194-212`) maps to `DocumentSignatureInfo` (`Chevron7/Sources/Chevron7Kit/Signing/SigningProvider.swift:298-325`), dropping coverage and qualification.
- `SigningSessionStore.inspectExistingSignatures` (`Chevron7/Sources/Chevron7App/SigningSessionStore.swift:356-364`) and the post-sign inspection (`:724`, `:327`) fill flat `existingSignatures` / `resultSignatures`. A failed inspection yields an empty list, which the prepare view shows as "Dokument zatiaľ neobsahuje elektronický podpis" (`SigningFlowViews.swift:513-535`). That text is wrong for a failure.
- `InputSignatureVerificationService.completed` (`:30-50`) uses `hasQualifiedTimestamp` only together with `state == .valid`, which structural results never reach, so separating "timestamp present" from "qualified timestamp verified" changes nothing for batch and ZaKo.
- Demo and Keychain providers do not override inspection; they fall back to the Swift byte scan `InputSignatureVerificationService.structuralInspection`.
- Engine processes run under a 90 s timeout (`ProcessConfiguration.production`, `AutogramCLIEngine.swift:756`); v1 runs share `helperOperationGate`.

## Design

### 1. Engine: the tree

`MachineInspectionService` gets one internal entry point, `inspectDocument(DSSDocument document, int depth)`, used by both modes (structural and trusted) and by `inspect(Path)` and `inspect(byte[])`. It returns the payload below. The mode decides only how a signature is mapped (`mapStructuralSignature` or `mapSignature`); the tree walk is shared.

```json
{
  "signatures": [ { "id": "…", "format": "XAdES_BASELINE_T", "documents": ["report.pdf"], "…": "…" } ],
  "documents": [
    { "name": "report.pdf", "nested": { "kind": "PDF", "signatures": [ … ] } },
    { "name": "kontajner.asice", "nested": { "kind": "ASIC", "signatures": [ … ],
        "documents": [ { "name": "a.pdf", "nestedSkipped": "DEPTH_LIMIT" } ] } },
    { "name": "dolozka.xml.xdcf" },
    { "name": "velky.pdf", "nestedSkipped": "TOO_LARGE" },
    { "name": "zly.pdf", "nestedError": "NESTED_INSPECTION_FAILED" }
  ]
}
```

Rules:

- `signatures` keeps today's meaning and shape: the signatures of this level. Each signature carries `documents` (the names it covers, from `getOriginalDocuments`) in both modes; structural inspection gains coverage so the first display already shows it.
- `documents` is present only for an ASiC, as today; entries keep `name` and may add exactly one of `nested`, `nestedSkipped`, `nestedError`.
- The bytes decide the kind, never the name: `%PDF-` is `PDF`; content for which DSS creates an `ASiCContainerWithXAdESValidator` or `ASiCContainerWithCAdESValidator` is `ASIC`. Anything else is a leaf without `nested`.
- `nested` is produced at depth 0 only (the top document is depth 0, its data objects are inspected as depth 1). Inside a nested ASiC, a data object that is itself a PDF or ASiC gets `nestedSkipped: "DEPTH_LIMIT"`.
- A data object larger than 100 MB is not inspected: `nestedSkipped: "TOO_LARGE"`.
- A nested PDF without signatures still gets `nested` with an empty `signatures`, so the UI can say the PDF is unsigned.
- Any exception while inspecting one data object becomes `nestedError: "NESTED_INSPECTION_FAILED"` on that entry; the rest of the tree is returned.
- Nested documents are handled in memory (the ASiC extractors already return `DSSDocument`s); nothing is written to disk.
- In trusted mode, a nested document is validated with the same `ValidatorReportReader` and certificate verifier as the top document, so trusted lists are loaded once per VALIDATE.
- A plain PDF returns exactly today's payload (no `documents`).

The machine protocol shape is additive: v1 INSPECT and v2 VALIDATE return the same tree; existing fields and events do not change. Signature ids from DSS are unique only within one document, so consumers address a signature by (path, id), where the path is `[]` for the top level and `["report.pdf"]` for a data object.

### 2. Swift model (Chevron7Kit)

- `SignatureTree`: `signatures: [DocumentSignatureInfo]` and `documents: [SignedDataObject]`.
- `SignedDataObject`: `name` and `content`, one of `.signed(kind: .pdf | .asic, tree: SignatureTree)`, `.skipped(.depthLimit | .tooLarge)`, `.failed`, `.plain`.
- `DocumentSignatureInfo` gains `coveredDocuments: [String]`, `certificateQualification: String?` (DSS `SignatureQualification` name from trusted validation) and `hasTimestamp: Bool`. `hasQualifiedTimestamp` becomes true only from `qualifiedTimestampValid`; the structural "a timestamp is cryptographically intact" moves to `hasTimestamp`.
- `SignatureTreeSummary`: counts valid, invalid and indeterminate (indeterminate and unknown together) over the whole tree, plus nested failures and skips as indeterminate, and remembers the path of the worst result.
- `AutogramCLIEngine` decodes the tree from both `inspection.completed` and `validation.completed` with one decoder. `InspectedPDF` keeps `signatures` and `documents` for existing callers and gains `tree`.
- `QualifiedSigningProviding` gains `inspectSignatureTree(in:) async -> SignatureTreeResult` and `validateSignatureTree(in:) async -> SignatureTreeResult`, where `SignatureTreeResult` is `.tree(SignatureTree)` or `.failed(reason: String)`. Default implementations: inspection wraps the Swift structural fallback as a flat tree; validation returns `.failed` with "Plné overenie vyžaduje podpisový engine." `inspectSignatures` and `inspectInputSignatures` stay for batch and ZaKo.

### 3. Flow (SigningSessionStore)

`existingSignatures` and `resultSignatures` become `SignatureTreeState`: the tree plus a phase.

| Phase | Meaning | Shown as |
|---|---|---|
| `inspecting` | structural inspection running | "Kontrolujem podpisy…" |
| `structural` | structural tree shown, full validation running | "Overuje sa voči dôveryhodným zoznamom…" |
| `validated` | trusted tree replaced the structural one | "Informatívne overenie voči dôveryhodným zoznamom EÚ" |
| `validationUnavailable(reason)` | trusted lists or validation failed; structural tree stays | "Dôveryhodné zoznamy nedostupné: výsledok je len štrukturálny" or the reason |
| `failed(reason)` | even structural inspection failed | "Podpisy sa nepodarilo skontrolovať" (never "neobsahuje podpis") |

- Opening or selecting a source, and finishing a signature, run INSPECT, publish `structural`, then run VALIDATE and publish `validated` or `validationUnavailable`.
- Each run carries a token; a result whose token no longer matches the current document (another document selected, document reset) is dropped.
- "Overiť znova" reruns VALIDATE for the current tree and returns to `structural` meanwhile.
- When signing starts, a running validation is cancelled so the signature does not wait for trusted list loading; the output is validated after signing.
- The trusted tree replaces the structural one as a whole; signatures are matched by (path, id) only to keep the expansion state of the UI.

### 4. UI (`SignatureTreeView`)

Used in the prepare inspector ("Podpisy v dokumente") and in "Overenie podpisov v súbore". Example:

```
✔ 2 podpisy: 2 platné          Informatívne overenie voči dôveryhodným zoznamom EÚ   [Overiť znova]
Podpisy kontajnera
  ✔ Marián Čuprík OPRÁVNENIE 1042   XAdES_BASELINE_T · QTS · Platný
    Pokrýva: report_podpisane.pdf
▾ report_podpisane.pdf · 1 podpis
    ✔ <podpisovateľ>                PAdES_BASELINE_T · QTS · Platný
Ďalšie súbory v kontajneri: dolozka.xml.xdcf
Overiť aj na slovensko.sk
```

- The summary line takes the worst result: red when anything is invalid, orange when anything is indeterminate, failed or skipped, green only when every signature on every level is valid.
- Next to it: the phase text and "Overiť znova" (disabled while validating or signing).
- Container signatures under "Podpisy kontajnera", each `SignatureInfoRow` with a new "Pokrýva:" line.
- Each data object with `nested` is a `DisclosureGroup` with its name and signature count, expanded automatically when it holds anything not valid. A nested PDF without signatures and documents without own signatures are listed together under "Ďalšie súbory v kontajneri".
- Skipped and failed data objects: "Podpisy v tomto súbore sa neoverovali (ďalšie vnorenie)", "… (súbor je príliš veľký)", "Podpisy v tomto súbore sa nepodarilo overiť".
- At most two indentation levels (the inspector is narrow).
- A plain PDF looks like today plus the phase text, "Overiť znova", and a summary line when it has more than one signature.
- "QTS" only when `hasQualifiedTimestamp`; otherwise "Časová pečiatka" when `hasTimestamp`.
- "Overiť aj na slovensko.sk" opens `https://www.slovensko.sk/sk/e-sluzby/sluzba-overenia-zep` in the default browser. Nothing is uploaded by the app.
- `SignatureInfoRow` stays the row for one signature.

### 5. Errors

- `TRUSTED_LIST_UNAVAILABLE`, `VALIDATION_FAILED`, a process timeout (90 s) or a missing engine: `validationUnavailable` with a Slovak reason; the structural tree stays, its states stay indeterminate.
- Structural INSPECT fails: `failed`, with "Podpisy sa nepodarilo skontrolovať".
- One nested data object fails or is skipped: only that node says so; the summary counts it as indeterminate.

## Testing (test-first)

Engine (`MachineInspectionServiceTest`, `MachineCliAppTest`, `v2/MachineV2CliAppTest`):

- a container around a signed PDF, built in the test with the test keystore (as in `signsAndPublishesAnAlreadySignedPdfIntoANewContainerThroughTheService`), returns the PDF's PAdES signature under `documents[0].nested`, structurally and with a mocked trusted report reader;
- a nested ASiC returns its signatures and marks its own PDF/ASiC data objects `DEPTH_LIMIT`;
- `TOO_LARGE` above the limit (limit injectable for the test);
- a corrupt PDF inside a container gives `nestedError` and the container's signatures are still returned;
- the kind follows the bytes (a PDF named `.txt` is inspected, a text file named `.pdf` is a leaf);
- structural signatures carry coverage;
- a plain PDF's payload is unchanged;
- v1 INSPECT and v2 VALIDATE events carry the tree.

Swift (`Chevron7KitTests`, `Chevron7AppTests`):

- decoding a full tree payload (trusted and structural) into `SignatureTree`, the first test that decodes signature JSON end to end;
- `SignatureTreeSummary` worst-of, with failed and skipped nodes as indeterminate;
- `hasQualifiedTimestamp` only from `qualifiedTimestampValid`, `hasTimestamp` from intact timestamps;
- store phases with a fake provider: structural then validated; validation unavailable keeps the structural tree; a stale result for a previous document is dropped; "Overiť znova" reruns; signing cancels a running validation; a failed inspection never reads as "no signature";
- `LiveEngineInspectionTests` (`CHEVRON7_ENGINE_LIVE_TEST=1`): the real engine on a container around a signed PDF.

Manual: `report_podpisane_podpisane.asice` in the app, online and offline.

## Out of scope

- Qualified validation (eIDAS Art. 33) through a qualified trust service provider. It is paid, needs a contract and an API, and sends documents to a third party; a separate project if wanted.
- Automatic upload to any online validation service, including slovensko.sk and the European Commission's DSS demo (which states it is not a service and advises against sensitive documents).
- Full validation in batch signing, ZaKo, the web signing panel and the Register.
- Depth beyond one nested level.
- A downloadable validation report.
