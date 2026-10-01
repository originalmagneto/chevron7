# Signing and notarizing Chevron7

Chevron7 is distributed outside the Mac App Store, so a release must be signed with a Developer ID Application certificate, use the hardened runtime and carry Apple's notarization ticket. Without that, Gatekeeper blocks the download and Safari loads the web extension only with "Allow Unsigned Extensions" turned on.

## Team and certificate

- Team: the Software s.r.o., Team ID `Q7AU96CW7H`. The signature reads `Developer ID Application: the Software s.r.o. (Q7AU96CW7H)`.
- Only the team's Account Holder can create a Developer ID Application certificate; the portal disables that option for Admins. A cloud-managed certificate does not help here: it signs only through Xcode's archive and export, while this SwiftPM build signs with `codesign`.
- The private key is generated on the signing Mac and only the certificate signing request (CSR) goes to the Account Holder. Keep an encrypted `.p12` backup of certificate and key: a lost key means revoking the certificate and creating a new one (at most five per team).

## One-time setup on a signing Mac

1. Import the certificate and its private key into the login keychain, then check that `security find-identity -v -p codesigning` lists the `Developer ID Application` identity.
2. Save notarization credentials in the keychain. An Admin can notarize with their own Apple ID and an app-specific password (appleid.apple.com, Sign-In and Security, App-Specific Passwords):

   ```bash
   xcrun notarytool store-credentials chevron7 --apple-id <apple id> --team-id Q7AU96CW7H
   ```

## Release build, signature and notarization

```bash
cd Chevron7
AUTOGRAM_JAVA_HOME=<Zulu FX 25> scripts/build-engine.sh
CHEVRON7_VERSION=X.Y.Z ./build_app.sh --release package
app="$(swift build -c release --show-bin-path)/Chevron7.app"
scripts/sign-release.sh "$app"
NOTARY_KEYCHAIN_PROFILE=chevron7 scripts/notarize-release.sh "$app"
scripts/package-release.sh X.Y.Z
codesign --force --timestamp --sign "Developer ID Application: the Software s.r.o. (Q7AU96CW7H)" .build/release-dist/Chevron7-vX.Y.Z.dmg
NOTARY_KEYCHAIN_PROFILE=chevron7 scripts/notarize-release.sh .build/release-dist/Chevron7-vX.Y.Z.dmg
(cd .build/release-dist && shasum -a 256 Chevron7-vX.Y.Z.dmg > SHA256SUMS.txt)
```

`sign-release.sh` signs inside out and never uses `codesign --deep`, which would replace the entitlements below:

| Code | Entitlements | Why |
|---|---|---|
| Native libraries inside JARs (JNA, JavaFX) | none | The notary service opens JARs and rejects unsigned Mach-O inside. The script extracts each library, signs it and writes it back; it refuses a signed JAR (`META-INF/*.SF`) with native code instead of breaking it. |
| `Contents/runtime/bin/java` | `Config/Chevron7Java.entitlements`: `allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation` | The JVM compiles at run time, and SunPKCS11 loads card drivers (eID client, I.CA, Disig) signed by other teams. `AutogramCLI-arm64` only `execv`s this binary, so the launcher needs nothing. |
| `Contents/MacOS/pkcs11-helper` | `Config/Chevron7PKCS11Helper.entitlements`: `disable-library-validation` | It `dlopen`s the same card drivers. |
| `Chevron7WebExtension.appex` | `Config/Chevron7WebExtension.entitlements`: sandbox and the Mach lookup exception for `app.slovensko.chevron7.webbridge` | Safari requires a sandboxed extension; the exception lets it reach the web bridge agent. |
| Every other Mach-O, then the app bundle | none | Hardened runtime and a secure timestamp. |

Missing library validation entitlements do not fail notarization; they fail at run time as "no card found". Before publishing a newly signed build, sign once with an eID card and once with an I.CA card, through the main window, the Safari extension and the Finder Quick Action.

When Apple refuses a submission, `notarize-release.sh` prints the notary log, which names every rejected file and the reason.

## Releases from GitHub Actions

`.github/workflows/release.yml` signs and notarizes the app and the DMG when all five Actions secrets below are set, signs ad hoc with a warning when none is set, and fails when only some are set:

| Secret | Content |
|---|---|
| `DEVELOPER_ID_APPLICATION_P12` | base64 of the `.p12` with the Developer ID Application certificate and its private key (`base64 -i developer-id.p12 \| pbcopy`) |
| `DEVELOPER_ID_APPLICATION_P12_PASSWORD` | the `.p12` password |
| `APPLE_API_KEY_P8` | base64 of an App Store Connect API key (`AuthKey_XXXX.p8`) |
| `APPLE_API_KEY_ID` | that key's ID |
| `APPLE_API_ISSUER_ID` | the team's issuer ID |

An Admin can create the API key without the Account Holder: App Store Connect, Users and Access, Integrations, App Store Connect API, Team Keys, access "Developer". Apple offers the `.p8` for download only once. The workflow imports the identity into a temporary keychain and deletes it, the `.p12` and the `.p8` at the end of the job.

## Effects of the Developer ID signature

- `Install Safari Bridge.command` (`scripts/install-webbridge-agent.sh`) leaves a Developer ID signed app untouched. It clears extended attributes and signs ad hoc again only for ad hoc builds, where Safari otherwise hid the extension.
- The app's designated requirement changes from the ad hoc hash to the team. Keychain items saved by an ad hoc build (the EZZK SOAP password, the eIdentita portal key) ask once for access on the first run of the signed build; "Always Allow" settles it.
