# Verification of the trimmed engine (2026-10-07)

Scope decided with the owner: remove only what is strictly redundant, meaning parts that exist solely for the engine's JavaFX GUI and its HTTP API, which Chevron7 never starts (the launcher refuses anything but `--cli`). Anything with any reach from the machine protocol, `PdfaNormalize` or a plausible later use stays.

## What changed

| Removed | Why it is redundant |
|---|---|
| Runtime modules `javafx.base`, `javafx.controls`, `javafx.fxml`, `javafx.graphics`, `javafx.web` (with them `javafx.media`, `jdk.jsobject`, `jdk.xml.dom`) | GUI only. The single non-GUI use was `Logging.log`, which asked `Platform.isFxApplicationThread()` for a debug line; it now logs the thread name. |
| `java.net.http` | Only `core/Updater` (GUI update check). |
| `java.scripting` | No reference in the engine or any jar; only `javafx.fxml` required it. |
| `jdk.httpserver` | Only `server/` (the GUI's HTTP API, created only by `GUIApp`). |
| Jars `javafx-*-23.0.1` (12) | Shadowed by the runtime modules before, unused after. |
| Jars `httpclient-4.5.14`, `httpcore-4.4.16` | Only `core/LaunchParameters` (GUI `--url` launch). DSS uses HttpClient 5. |
| Launcher flag `--enable-native-access=...,javafx.graphics` | Module no longer exists. |
| Swift `JavaEngineInstallation.launchArguments` | Never called. |

Kept on purpose, although the audit called some of them removable: veraPDF stack, `dss-pdfa`, `rhino`, `stax-utils` (human CLI `--pdfa`, a possible PDF/A check in ZaKo later), `commons-codec` (xmlsec references), `jul-to-slf4j`, `xmlresolver-data`, `java.compiler` (JAXB references), `java.sql` (loaded in the runs below), `jdk.unsupported`.

## Sizes (`du -sh`, `.build/engine/Contents`)

| | Before | After |
|---|---|---|
| runtime | 215 MB | 63 MB |
| dependency jars | 84 MB | 42 MB |
| engine total | 300 MB | 106 MB |

## Before/after run

The same script ran against a copy of the engine built from `main` and against the trimmed one (synthetic PKCS#12 key, because machine SIGN refuses keystores; the human CLI goes through the same `SigningJob` and DSS code):

- machine v1: CAPABILITIES, DRIVERS, INSPECT of 8 inputs (PDF in XAdES and CAdES ASiC-E, PAdES, plain PDF, general agenda XDC, FUPS XDCF, FS form with timestamp, DOCX);
- CLI signing: PAdES B, PAdES T with BOSA's qualified TSA, PDF into XAdES ASiC-E, general agenda eForm into XDC (Saxon) with and without a timestamp, plain XML, TXT and DOCX into ASiC-E;
- machine v2 session: CAPABILITIES, INSPECT, PREVIEW of a PDF, the general agenda and the FUPS form, VALIDATE of 5 files with online trusted lists;
- INSPECT of every signed output, and `PdfaNormalize`.

Results:

- Every operation ended the same way in both engines. The one failure (an FS form the CLI does not know, `UnknownEformException`) is identical in both.
- All machine protocol payloads are identical after removing times, ids and paths, including PREVIEW HTML, validation verdicts and `QTSA` qualifications.
- Inside every signed container the data objects (PDF, XDC built by Saxon, TXT, DOCX) are byte-identical; only `META-INF/signatures*.xml` differ (signing time, ids).
- `PdfaNormalize` output differs only in the XMP create and modify dates.
- JavaFX classes loaded: 1408 before (signing), 0 after. Runtime modules loaded after: `java.base java.desktop java.logging java.naming java.security.sasl java.sql java.xml jdk.crypto.cryptoki jdk.net jdk.unsupported`, all present.
- No `NoClassDefFoundError` and no `Unknown module` warning.

## Not covered without a card (owner's check before merge)

Machine SIGN with a real card (PAdES with a visible stamp and a timestamp, ASiC-E), ZaKo end to end with the mandate card, the Finder Quick Action, browser signing, and "Overiť znova" in the app.
