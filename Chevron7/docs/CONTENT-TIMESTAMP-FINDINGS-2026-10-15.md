# Content timestamp for an officially certified signature (2026-10-15)

## Why

§ 23 ods. 1 písm. b) zákona č. 305/2013 Z. z. (e-Government) says that where a special law requires an officially certified handwritten signature on an electronic podanie, a person who is not a public authority authorizes it with a qualified electronic signature whose qualified certificate carries the minimum data set of a natural person (Implementing Regulation (EU) 2015/1501, annex point 1) and "ktorý zahrnul do autorizácie aj kvalifikovanú elektronickú časovú pečiatku ... ktorá určuje dátum a čas, po ktorom nastala autorizácia".

The MIRRI guidance on that provision ([Usmernenie k § 23 ods. 1 písm. b)](https://mirri.gov.sk/wp-content/uploads/2019/07/Usmernenie-k-%C2%A7-23-ods.-1-pi%CC%81sm.-b-za%CC%81kona-o-e-Governmente.pdf), read 2026-10-15) explains the technique: the qualified timestamp is not appended to the finished signature (unsigned data) but included in the signed data, so the signature itself protects the time after which authorization happened. It names the elements:

- XAdES: `AllDataObjectsTimeStamp` or `IndividualDataObjectsTimeStamp`,
- CAdES: `contentTimestamp`,
- PAdES: covering an existing PAdES signature that carries a timestamp, or covering a document timestamp.

A second timestamp on the signature itself (the ordinary Baseline T signature timestamp) is optional and fixes the time before which authorization happened; under § 23 ods. 8 a public authority adds one when the podanie lacks it. The guidance stresses that the rule concerns the podanie only (žaloba, návrh, žiadosť, sťažnosť, vyjadrenie), never its attachments, and only where a special law requires the signature on the podanie itself to be officially certified.

Upstream discussion: [slovensko-digital/autogram#356](https://github.com/slovensko-digital/autogram/issues/356) (content timestamp for the officially certified signature, open).

Chevron7 before this change only ever added a signature timestamp (Baseline T through `service.setTspSource` in `SigningJob`), so no Chevron7 signature met § 23 ods. 1 písm. b).

## What DSS 6.4 produces (spike)

`engine/src/test/java/digital/slovensko/autogram/ContentTimestampSpikeTest.java` signs `sample.pdf` with the test keystore and a real qualified authority (Sectigo Qualified, `http://timestamp.sectigo.com/qualified`). It runs only with `CHEVRON7_SPIKE_OUT=<dir>` set (and optionally `CHEVRON7_SPIKE_TSA`); the three outputs of 2026-10-15 are kept in `docs/reference/content-timestamp/2026-10-15/`.

| File | How | DSS timestamp types (diagnostic data) |
|---|---|---|
| `xades-content-ts.asice` | `ASiCWithXAdESService.getContentTimestamp(documents, parameters)`, then `parameters.setContentTimestamps(...)`, XAdES Baseline T | `ALL_DATA_OBJECTS_TIMESTAMP` (covers the PDF data object), `SIGNATURE_TIMESTAMP` (covers the signature and the content timestamp) |
| `pades-content-ts.pdf` | `PAdESService.getContentTimestamp(document, parameters)` (the content timestamp parameters need the same digest algorithm as the signature, SHA-256), PAdES Baseline T, `contentSize` 9472 * 3 | `CONTENT_TIMESTAMP` (CMS `content-time-stamp` signed attribute), `SIGNATURE_TIMESTAMP` |
| `pades-doc-ts-then-signature.pdf` | `PAdESService.timestamp(document, PAdESTimestampParameters)` (a document timestamp revision), then a PAdES Baseline T signature over that revision | `DOCUMENT_TIMESTAMP` (detached, `getDetachedTimestamps()`), the signature's own `SIGNATURE_TIMESTAMP` |

In all three the message imprint of every timestamp is intact, the signature is intact, and the engine's own VALIDATE (`MachineInspectionService.forTrustedValidation()`) reads the file. The XAdES `AllDataObjectsTimeStamp` sits inside `xades:SignedDataObjectProperties`, so it is part of the signed properties as the guidance requires. The PAdES document timestamp sits in an earlier revision covered by the signature's ByteRange.

Observations that matter for the implementation:

- DSS reports the XAdES spike signature as `XAdES-BASELINE-B` although it carries a signature timestamp. That is the test keystore's certificate, not the content timestamp: it expired, and DSS 6.4's `XAdESBaselineRequirementsChecker.hasBaselineTProfile` requirement (o) needs the signature timestamp to predate the signing certificate's expiry (the PAdES checker has no such rule, hence `PAdES-BASELINE-T`). A valid card certificate gives `XAdES-BASELINE-T`. Engine tests therefore assert timestamp types, never the format, for XAdES.
- Before this change the engine's payload listed only the signature timestamps from the structural pass, and the trusted pass listed the content timestamp without telling it apart (the first entry of `timestamps` was the content timestamp, which the done screen would have named as "the" timestamp). A document timestamp was not listed at all.
- The content timestamp's own message imprint uses SHA-512 (DSS's default for XAdES timestamp parameters); the qualified authorities accept it.

## Choice

- ASiC-E XAdES: `AllDataObjectsTimeStamp` over every data object (with attachments, all of them), the guidance's first XAdES element.
- PAdES: a document timestamp revision before the signature, the guidance's PAdES wording ("zahrnutie časovej pečiatky dokumentu"). The CMS `content-time-stamp` attribute is a valid ETSI construct too, but the guidance names it only for CAdES; its spike file stays here so the owner can compare how the tools show it.
- CAdES, an existing ASiC-E being extended, a ZaKo record and portal (web) or phone signatures: no content timestamp. The portal decides its own format, the phone service builds the signature itself, and ZaKo has its own legal frame.
- The content timestamp comes from the same qualified authority list as the signature timestamp (the authority chosen in Settings, the signing window or the batch). It is independent of the QTS switch: with the switch off the signature is Baseline B plus a content timestamp; with it on, Baseline T plus a content timestamp.
- Without a visible stamp the claimed signing time is set after the content timestamp is fetched, so the signature never claims to precede its own content timestamp. A visible PAdES stamp keeps the time drawn in the stamp, which is a few seconds earlier than the document timestamp; DSS has no check that ties the claimed signing time to a content or document timestamp (only `TimestampCoherenceOrderCheck`, content before signature timestamps).

## How the owner checks acceptance (open gate)

The spike files are signed by the expired "Jano Suchal" test key, so every validator shows the signature itself as invalid or undetermined. They can show only whether a tool lists and labels the content or document timestamp. Real acceptance needs a card signature from a build with the new switch:

1. In Chevron7, sign a test PDF twice with "Časová pečiatka údajov" on: once as PAdES, once as ASiC-E (XAdES). Keep the QTS switch on for one of them.
2. Open each in D.Viewer (Ditec, the state's viewer) and note how it lists the timestamps: whether it shows a timestamp of the data or document separately from the signature timestamp, and whether it reports the signature as valid.
3. Upload each to the informative validation on slovensko.sk ([Služba overenia ZEP](https://www.slovensko.sk/sk/e-sluzby/sluzba-overenia-zep), the link "Overiť aj na slovensko.sk" opens) and note the verdict and how it names the timestamps.
4. Optionally do the same with the three spike files here, to see the labels for the CMS content timestamp variant as well.
5. If either tool rejects the PAdES document timestamp but accepts the CMS variant, switching the engine to the CMS attribute is one method (`SigningJob.signDocumentAsPAdeS`); record the result here.

Until those checks are done, the app explains the switch but makes no claim that a portal accepts the signature as officially certified.

## Inspection

The engine now reports a `type` for every timestamp of a signature (DSS `TimestampType`: `ALL_DATA_OBJECTS_TIMESTAMP`, `INDIVIDUAL_DATA_OBJECTS_TIMESTAMP`, `CONTENT_TIMESTAMP`, `SIGNATURE_TIMESTAMP`, `ARCHIVE_TIMESTAMP`, `DOCUMENT_TIMESTAMP`, ...), from both the structural and the trusted pass. A PDF document timestamp in a revision before a signature is listed under that signature as `DOCUMENT_TIMESTAMP`, because the signature covers it. The app shows "Časová pečiatka údajov" (content, data objects or a prior document timestamp) separately from "Časová pečiatka podpisu" (signature and archive timestamps), and names the signature timestamp's authority and time on the done screen as before.
