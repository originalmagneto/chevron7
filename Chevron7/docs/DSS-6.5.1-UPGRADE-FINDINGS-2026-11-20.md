# DSS 6.4 to 6.5.1 in the signing engine (2026-11-20)

The engine (`engine/pom.xml`, `dss.version`) moves from EU DSS 6.4 to 6.5.1 (Maven Central since 2026-10-14). Upstream slovensko-digital/autogram is on 6.5 since 2026-09-24 (a pom-only bump, commit `bed712c9`). Sources: the GitHub releases 6.5.RC1, 6.5 and 6.5.1 of `esig/dss` and the cookbook's migration guide at tag 6.5.1.

## What changed in DSS that touches the engine

Most of 6.5 is new territory the engine does not use (CB-AdES, attestations in SD-JWT VC and mdoc, LoTE validation, Spring Boot 4 in the demos). What does touch it:

| DSS change | Effect here |
|---|---|
| Migration: `TLValidationJob` sync and cache classes moved from `eu.europa.esig.dss.tsl.{sync,cache}` to `eu.europa.esig.dss.validation.job.{sync,cache}` (new jar `dss-validation-job`); `ExpirationAndSignatureCheckStrategy` stays in `tsl.sync` | Imports in `SignatureValidator`, `TrustedListAvailability` and its test adjusted. `TLInfo.getParsingCacheInfo()` now returns `TLParsingInfoRecord`, so the test mocks that type. |
| DSS-3954: cryptographic end dates from ETSI TS 119 312 v2.1.1 in the default policy (`constraint.xml`, which the engine uses) | RSA 1900 to 2999 bit (RSA-2048 of Slovak eID and I.CA cards) ends 2027-01-01 instead of 2029-01-01; RSA 3000+ ends 2035-01-01 (was open); DSA 1900 the same as RSA. `UpdateDate` is 2026-02-01 with `LevelAfterUpdate="WARN"`, so these expiries are warnings: a probe with a trusted RSA-2048 chain validated at 2027-02-01 stays `TOTAL_PASSED` and gains two AdES warnings ("The algorithm RSA with SHA256 with key size 2048 is no longer considered reliable for signature creation!"). No verdict, qualification or E→E gate changes; the app shows no DSS warnings, only the E→E ETSI report carries them. A later DSS may raise the level, so watch this on every bump. |
| DSS-3789, DSS-3799: new DPI handling for visible PDF signature images | No effect: the stamp sets the field's width and height and `ImageScaling.STRETCH` (`SigningParameters.getPAdESSignatureParameters`), and the change applies only to dimensions that are not set. |
| DSS-3819 (trusted list signature no longer accepted against a CA certificate), DSS-3968 (`ExpirationAndSignatureCheckStrategy` synchronized lists with zero or several signatures), DSS-3885 (`FileCacheDataLoader` validates before caching), DSS-3969 (new TL alert for a decreasing sequence number) | Checked live with the built jlink runtime and an empty cache: all eight `DEFAULT_TRUSTED_LIST` countries (SK, CZ, AT, PL, HU, BE, NL, ES) download and synchronize (`unavailableTrustedListCountries()` empty), in 11.1 s cold and 9.7 s warm. A real 2023 Slovak QES (test fixture `wrong_schema_xdc_signed.asice`) resolves to `INDETERMINATE_QESIG` through the SK list. |
| DSS-3946: an `/AP` added to an existing signature field is now detected as a modification | Touches the E→E fact "changed after the last signature"; the engine suite passes, a real signed original should still be checked in the E→E live test. |
| `SignatureQualification` values, ETSI TS 119 102-2 schemas (v1.1.1 to v1.4.1) | Identical in 6.4 and 6.5.1, so the qualification labels, `e2eUndeterminedQualificationMessage` and the ETSI report reader are unaffected. |
| Dependencies: Bouncy Castle 1.83 to 1.86, veraPDF 1.28.2 to 1.30.3, httpclient5 5.5.2 to 5.6.5, Guava 33.5.0 to 33.7.2 | BC and veraPDF parse every signature and PDF; covered by the suites and the card test below. |

## The F12 and F15 workarounds stay

Both DSS behaviours are unchanged in 6.5.1, proven by two canary tests in `ContentTimestampTest` that fail once DSS behaves:

- F12: `PAdESService.timestamp` on a PDF already signed at Baseline T still throws `AlertException` ("Revocation data is missing ... skipped for untrusted certificate chain"), so `SigningJob.signDocumentAsPAdeS` keeps calling `PAdESTimestampService` directly (`dssStillRefusesToTimestampAPdfSignedAtBaselineT`).
- F15: after a second QTS signature, `getDetachedTimestamps()` still lists one document timestamp and the other appears only among the first signature's timestamps, so `MachineInspectionService.pdfDocumentTimestamps` stays (`dssStillFilesALaterDocumentTimestampUnderTheEarlierSignature`).

## Other adjustments

- `ConversionEvidenceService.DSS_VERSION` was a literal "6.4" that the E→E register stores as the evidence source ("Chevron7 (DSS 6.4)"). It is now "6.5.1", and `theRecordedDssVersionIsTheOneOnTheClasspath` compares it with the `pom.properties` of the dss-validation jar, so the next bump cannot leave it behind.

## Bundle

Only one jar is new (`dss-validation-job`, needs `java.base` only). jdeps reports no module the runtime lacks beyond the three the 2026-10-07 audit already explained (`java.management`, `java.security.jgss`, `java.xml.crypto`). `.build/engine/Contents`: 94.2 MB (dependency jars 41.7 MB, runtime 50.9 MB, autogram.jar 1.4 MB), against 106 MB and 42 MB of jars in the audit. `PdfaFromSigned` (veraPDF) and VALIDATE ran through the bundled launcher and runtime.

## Before release: real cards

The engine suite (734 tests) and the Swift suite run without cards or real timestamp authorities. Before merging:

1. PAdES with QTS on a card (eID and I.CA), and a second QTS signature of the same PDF (F12).
2. ASiC-E XAdES with QTS on a card (Sectigo Qualified timestamp).
3. A ZaKo conversion in Testovacia evidencia (record and client container signed, record accepted).
4. Re-validate documents signed earlier with real cards and timestamp authorities and compare verdicts and qualifications with 6.4 (Bouncy Castle 1.86 parses them now).

## Card test results (2026-11-20, Mac Studio, Developer ID-signed 1.21.6 build with DSS 6.5.1)

- I.CA mandate card (OPRÁVNENIE 1042), PAdES with QTS: TOTAL_PASSED, QESIG, document timestamp and signature timestamp from BOSA (QTSA).
- A second QTS signature of the same PDF (F12): succeeds. Both signatures are TOTAL_PASSED and QESIG, and each lists the document timestamps it covers (F15).
- ASiC-E XAdES with QTS: TOTAL_PASSED, QESIG, AllDataObjectsTimeStamp and signature timestamp from Sectigo Qualified (QTSA).
- ZaKo record-first in Testovacia evidencia, single-PDF output, E→E 261120-qd580FC023 and P→E 261120-WF580Fc022: EZZK processed both records with code 0, and both outputs validate as PAdES Baseline T, TOTAL_PASSED, QESIG.
- Re-validation of ten earlier documents (eleven signatures, eID and I.CA, PAdES, XAdES and CAdES) through the 6.4 and 6.5.1 engines: identical output.
- Live BOSA and Sectigo Qualified timestamps through the bundled runtime: QTSA, PASSED.
- eID card, same run: PAdES with QTS, a second QTS signature of the same PDF (F12) and ASiC-E with QTS all TOTAL_PASSED and QESIG, with BOSA (PAdES) and Sectigo Qualified (XAdES) QTSA timestamps, and the F15 listing as with I.CA.
