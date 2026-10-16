# Official conversion forms

Verbatim files from the slovensko.sk form packages that Chevron7 references in every
XMLDataContainer it builds: record 1.0 (`ConversionRecordOfPaperToElectronicDocument`) and
clause 1.3 (`ConversionCertificateOfPaperToElectronicDocument`), plus record 1.2
(`ConversionRecordOfPaperToElectronicDocument_2021.sk`), the record form from 1. 1. 2027, whose
official schema libxml2 compiles as is (no validation copy). Sources, hashes and the digest
rule are in `provenance.json`. The presentation file is the package manifest's
`media-destination="sign"` entry (record: TXT; clause: the HTML one).

After changing any file here, run `scripts/embed-official-forms.sh` and commit the regenerated
`Sources/Chevron7Kit/Attestation/Forms/OfficialFormFiles.swift`. `OfficialFormTests` fails when
the two drift apart. The record digests must stay equal to those of the record EZZK accepted on
2026-08-24 (spec: `docs/superpowers/specs/2026-09-23-ezzk-part-b-design.md`).

`record-1.0/schema.validation.xsd` is a derived copy of `record-1.0/schema.xsd` with only the
`IdentifierValueType` pattern's escaped slashes unescaped, because libxml2 (`xmllint`) rejects
`\/` in a schema pattern and cannot compile the official file as-is. It is used only for local
validation; every XMLDataContainer reference and digest still points at the official `schema.xsd`.
