#!/bin/bash
# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-License-Identifier: EUPL-1.2
set -euo pipefail

# Chevron7.app build script - assembly of a macOS app bundle.
#
# Usage:
#   ./build_app.sh                    # debug build (fast); no Safari extension in the product
#   ./build_app.sh --release          # release build; no Safari extension in the product
#   ./build_app.sh install            # debug build and install into /Applications
#   ./build_app.sh --release install  # release build and install into /Applications
#   ./build_app.sh --release package  # release build for the DMG; keeps the Safari extension

MODE="debug"
INSTALL=false
PACKAGE=false
for argument in "$@"; do
    case "$argument" in
        --release) MODE="release" ;;
        install) INSTALL=true ;;
        package) PACKAGE=true ;;
        *)
            echo "Usage: $0 [--release] [install|package]" >&2
            exit 2
            ;;
    esac
done
if [[ "$INSTALL" == true && "$PACKAGE" == true ]]; then
    echo "install and package are mutually exclusive" >&2
    exit 2
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export MACOSX_DEPLOYMENT_TARGET="27.0"

# The release workflow passes the version; local builds take it from the last release tag.
VERSION="${CHEVRON7_VERSION:-$(git describe --tags --abbrev=0 --match 'native-v*' 2>/dev/null | sed 's/^native-v//')}"
VERSION="${VERSION:-0.0.0}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid version: $VERSION" >&2; exit 2; }

# Sparkle updates. The feed and the Ed25519 public key are public; the private key
# signs the appcast in the release workflow (SPARKLE_PRIVATE_ED_KEY). Only release
# builds carry the key, so a debug build never offers to replace itself.
UPDATE_FEED_URL="${CHEVRON7_UPDATE_FEED_URL:-https://github.com/originalmagneto/chevron7/releases/latest/download/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-0VKcGhf6at6eeW1esfwLDtTkPTCfmV6hybTl6X2/1Bg=}"

echo "▸ swift build -c $MODE"
swift build -c "$MODE"

# Ask SwiftPM where it put the products: Xcode 27 toolchains use .build/out/Products/<Mode>,
# older ones .build/arm64-apple-macosx/<mode>.
BIN_DIR="$(swift build -c "$MODE" --show-bin-path)"
APP_DIR="$BIN_DIR/Chevron7.app"
CONTENTS="$APP_DIR/Contents"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_DIR/Chevron7" "$CONTENTS/MacOS/Chevron7"

# SwiftPM links Sparkle dynamically; this hand-built bundle embeds the framework.
# ditto keeps its symlinks and permissions.
SPARKLE_FRAMEWORK="$(find .build/artifacts -type d -path '*macos*' -name Sparkle.framework -print -quit 2>/dev/null || true)"
[[ -n "$SPARKLE_FRAMEWORK" ]] || { echo "Error: Sparkle.framework was not resolved by SwiftPM" >&2; exit 1; }
mkdir -p "$CONTENTS/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/Sparkle.framework"
if ! otool -l "$CONTENTS/MacOS/Chevron7" | grep -Fq "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/Chevron7"
fi
if [[ -x "$BIN_DIR/pkcs11-helper" ]]; then
    cp "$BIN_DIR/pkcs11-helper" "$CONTENTS/MacOS/pkcs11-helper"
fi
cp "Assets/Chevron7.icns" "$CONTENTS/Resources/Chevron7.icns"
# The official Buy Me a Coffee button image, the same as on chevron7.slovensko.app.
cp "Assets/BuyMeACoffee.png" "$CONTENTS/Resources/BuyMeACoffee.png"
ditto "Assets/Chevron7 Finder Quick Action.workflow" "$CONTENTS/Resources/Chevron7 Finder Quick Action.workflow"

# Preferred source of the signing engine: the in-repo Java fork built by
# scripts/build-engine.sh. A legacy app bundle is only a fallback.
LEGACY_CONTENTS="${CHEVRON7_LEGACY_APP_ROOT:-}"
ENGINE_BUILD=".build/engine/Contents"
if [[ -z "$LEGACY_CONTENTS" && -x "$ENGINE_BUILD/Helpers/AutogramCLI-arm64" && -f "$ENGINE_BUILD/app/autogram.jar" ]]; then
    LEGACY_CONTENTS="$ENGINE_BUILD"
    # An engine built before the latest engine/ changes signs without them (a ZaKo record
    # then fails with SIGNING_UNAVAILABLE), so refuse to bundle it silently.
    newer_engine_source="$(find ../engine/src/main ../engine/scripts/native-macos ../engine/pom.xml -type f -newer "$ENGINE_BUILD/app/autogram.jar" -print -quit 2>/dev/null || true)"
    if [[ -n "$newer_engine_source" ]]; then
        echo "Error: the signing engine in $ENGINE_BUILD is older than $newer_engine_source. Run scripts/build-engine.sh first." >&2
        exit 1
    fi
fi
if [[ -z "$LEGACY_CONTENTS" ]]; then
    for candidate in /Applications/*.app/Contents "$HOME"/Applications/*.app/Contents; do
        if [[ -x "$candidate/Helpers/AutogramCLI-arm64" \
              && -x "$candidate/Helpers/AutogramQuickActionRunner-arm64" \
              && -f "$candidate/app/autogram.jar" \
              && -d "$candidate/app/dependency-jars" \
              && -d "$candidate/runtime" ]]; then
            LEGACY_CONTENTS="$candidate"
            break
        fi
    done
fi

if [[ -n "$LEGACY_CONTENTS" \
      && -x "$LEGACY_CONTENTS/Helpers/AutogramCLI-arm64" \
      && -x "$LEGACY_CONTENTS/Helpers/AutogramQuickActionRunner-arm64" \
      && -f "$LEGACY_CONTENTS/app/autogram.jar" \
      && -d "$LEGACY_CONTENTS/app/dependency-jars" \
      && -d "$LEGACY_CONTENTS/runtime" ]]; then
    mkdir -p "$CONTENTS/Helpers" "$CONTENTS/app"
    ditto "$LEGACY_CONTENTS/Helpers" "$CONTENTS/Helpers"
    cp "$LEGACY_CONTENTS/app/autogram.jar" "$CONTENTS/app/autogram.jar"
    ditto "$LEGACY_CONTENTS/app/dependency-jars" "$CONTENTS/app/dependency-jars"
    ditto "$LEGACY_CONTENTS/runtime" "$CONTENTS/runtime"
else
    echo "Warning: signing engine not found. Run scripts/build-engine.sh first; without it KEP signing falls back to Keychain/DEMO and the Finder Quick Action cannot sign." >&2
fi
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.autogram.asice</string>
            <key>UTTypeDescription</key>
            <string>ASiC-E signed container</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.zip-archive</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>asice</string>
                </array>
                <key>public.mime-type</key>
                <string>application/vnd.etsi.asic-e+zip</string>
            </dict>
        </dict>
    </array>
    <key>CFBundleIconFile</key>
    <string>Chevron7</string>
    <key>CFBundleName</key>
    <string>Chevron7</string>
    <key>CFBundleDisplayName</key>
    <string>Chevron7</string>
    <!-- The interface is Slovak; this also makes Sparkle and the standard AppKit
         items speak Slovak instead of following an English system language. -->
    <key>CFBundleDevelopmentRegion</key>
    <string>sk</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>sk</string>
    </array>
    <key>CFBundleIdentifier</key>
    <string>app.slovensko.chevron7</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>app.slovensko.chevron7.ezzk</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>chevron7</string>
            </array>
        </dict>
    </array>
    <key>CFBundleVersion</key>
    <string>VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>Chevron7</string>
    <key>LSMinimumSystemVersion</key>
    <string>27.0</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>PDF Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.adobe.pdf</string>
                <string>org.autogram.asice</string>
            </array>
        </dict>
    </array>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
        <key>NSExceptionDomains</key>
        <dict>
            <key>tsa.disig.sk</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
                <key>NSIncludesSubdomains</key>
                <true/>
            </dict>
            <key>timestamp.sectigo.com</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
                <key>NSIncludesSubdomains</key>
                <true/>
            </dict>
            <key>tsa.belgium.be</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
                <key>NSIncludesSubdomains</key>
                <true/>
            </dict>
        </dict>
    </dict>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Marián Čuprík, EUPL-1.2. Podpisový engine: fork slovensko-digital/autogram.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

cat > "$CONTENTS/PkgInfo" <<'PKG'
APPL????
PKG
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleVersion $VERSION" \
    -c "Set :CFBundleShortVersionString $VERSION" \
    "$CONTENTS/Info.plist"
if [[ "$MODE" == "release" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Add :SUFeedURL string $UPDATE_FEED_URL" \
        -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" \
        -c "Add :SUEnableAutomaticChecks bool true" \
        "$CONTENTS/Info.plist"
fi

# ---------------------------------------------------------------------------
# Safari web extension: a hand-assembled .appex, because this project builds
# with SwiftPM and has no Xcode target to produce one.
#
# The extension is sandboxed by Safari and only relays native messages to the
# app over a Mach service, which the temporary-exception entitlement lets it
# look up. That exception needs neither a Team ID nor an app group, so it also
# holds under the adhoc signature used here. Distribution still needs a
# Developer ID and notarization; unsigned, Safari loads it only while
# "Allow Unsigned Extensions" is on in the Develop menu.
# ---------------------------------------------------------------------------
# launchd agent that owns the Mach service name. A GUI app cannot publish one:
# launchd hands the receive right only to the process it launches for the name.
# The agent is a rendezvous point, no document ever passes through it.
AGENT_BIN="$BIN_DIR/chevron7-webbridge-agent"
if [[ -x "$AGENT_BIN" ]]; then
    cp "$AGENT_BIN" "$CONTENTS/Helpers/chevron7-webbridge-agent" 2>/dev/null \
        || { mkdir -p "$CONTENTS/Helpers" && cp "$AGENT_BIN" "$CONTENTS/Helpers/chevron7-webbridge-agent"; }
    # The linker signs it as "chevron7-webbridge-agent-<hash>"; the app and the
    # extension check the agent by its plain identifier (WebBridgeCodeRequirement).
    codesign --force --sign - --identifier chevron7-webbridge-agent "$CONTENTS/Helpers/chevron7-webbridge-agent" >/dev/null 2>&1 \
        || echo "  (upozornenie: agenta sa nepodarilo podpísať)"

    # A Developer ID build registers the agent itself through SMAppService
    # (WebBridgeAgentService); launchd reads this plist from the bundle.
    mkdir -p "$CONTENTS/Library/LaunchAgents"
    cat > "$CONTENTS/Library/LaunchAgents/app.slovensko.chevron7.webbridge.plist" <<'AGENTPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>app.slovensko.chevron7.webbridge</string>
    <key>BundleProgram</key>
    <string>Contents/Helpers/chevron7-webbridge-agent</string>
    <key>MachServices</key>
    <dict>
        <key>app.slovensko.chevron7.webbridge</key>
        <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>app.slovensko.chevron7</string>
    </array>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
AGENTPLIST
fi

EXTENSION_BIN="$BIN_DIR/Chevron7WebExtensionHandler"
if [[ -x "$EXTENSION_BIN" ]]; then
    APPEX="$CONTENTS/PlugIns/Chevron7WebExtension.appex"
    rm -rf "$APPEX"
    mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
    cp "$EXTENSION_BIN" "$APPEX/Contents/MacOS/Chevron7WebExtension"

    if [[ -d "WebExtension/dist" ]]; then
        ditto "WebExtension/dist" "$APPEX/Contents/Resources"
    else
        echo "  (upozornenie: WebExtension/dist chýba, rozšírenie bude bez web častí)"
    fi

    cat > "$APPEX/Contents/Info.plist" <<'APPEXPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Chevron7</string>
    <key>CFBundleDisplayName</key>
    <string>Chevron7</string>
    <key>CFBundleIdentifier</key>
    <string>app.slovensko.chevron7.WebExtension</string>
    <key>CFBundleExecutable</key>
    <string>Chevron7WebExtension</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>sk</string>
    <!-- Safari lists an extension only when the bundle says which platform it
         is for and how far back it runs. pluginkit registers it without these,
         which is why a missing entry shows up as "registered but not listed". -->
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.Safari.web-extension</string>
        <key>NSExtensionPrincipalClass</key>
        <string>Chevron7WebExtensionHandler</string>
    </dict>
</dict>
APPEXPLIST
    echo '</plist>' >> "$APPEX/Contents/Info.plist"
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleVersion $VERSION" \
        -c "Set :CFBundleShortVersionString $VERSION" \
        "$APPEX/Contents/Info.plist"
    if [[ -f "$APPEX/Contents/Resources/manifest.json" ]]; then
        sed -i '' -E "s/(\"version\": \")[^\"]+/\1$VERSION/" "$APPEX/Contents/Resources/manifest.json"
    fi

    APPEX_ENTITLEMENTS="Config/Chevron7WebExtension.entitlements"
    codesign --force --sign - --entitlements "$APPEX_ENTITLEMENTS" "$APPEX" >/dev/null 2>&1 \
        || echo "  (upozornenie: appex sa nepodarilo podpísať)"
    echo "▸ Safari rozšírenie: $APPEX"
fi

codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "✔ Hotovo: $APP_DIR ($VERSION)"
echo "  Spustenie: open \"$APP_DIR\""

# pluginkit -r does not stick while the appex file remains: discovery adds it
# back. Dev builds drop it. `package` keeps it so the DMG can ship it.
strip_build_product_extension() {
    local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    pluginkit -r "$APP_DIR/Contents/PlugIns/Chevron7WebExtension.appex" >/dev/null 2>&1 || true
    rm -rf "$APP_DIR/Contents/PlugIns"
    codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true
    "$lsregister" -u "$APP_DIR" >/dev/null 2>&1 || true
}

if [[ "$INSTALL" == true ]]; then
    INSTALL_DIR="/Applications/Chevron7.app"
    rm -rf "$INSTALL_DIR"
    ditto --rsrc --extattr --acl "$APP_DIR" "$INSTALL_DIR"
    strip_build_product_extension

    # Drop every other registered copy, then register only the installed one.
    # pluginkit -m without -D hides duplicates, so Safari would show one row per path.
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    INSTALLED_APPEX="$INSTALL_DIR/Contents/PlugIns/Chevron7WebExtension.appex"
    while IFS= read -r pluginkit_line; do
        case "$pluginkit_line" in
            *"Path ="*)
                appex_path="${pluginkit_line#*Path = }"
                if [[ -n "$appex_path" && "$appex_path" != "$INSTALLED_APPEX" ]]; then
                    pluginkit -r "$appex_path" >/dev/null 2>&1 || true
                fi
                ;;
            *"Parent Bundle ="*)
                parent_app="${pluginkit_line#*Parent Bundle = }"
                if [[ -n "$parent_app" && "$parent_app" != "$INSTALL_DIR" ]]; then
                    "$LSREGISTER" -u "$parent_app" >/dev/null 2>&1 || true
                fi
                ;;
        esac
    done < <(pluginkit -m -D -i app.slovensko.chevron7.WebExtension -vvv 2>/dev/null || true)
    "$LSREGISTER" -f "$INSTALL_DIR" >/dev/null 2>&1 || true
    if [[ -d "$INSTALLED_APPEX" ]]; then
        # pluginkit accepts the appex right after lsregister but may not list it yet.
        # An empty match list is not success: that is how a missing registration
        # used to be reported as registered.
        registered=false
        for _ in 1 2 3 4 5; do
            pluginkit -a "$INSTALLED_APPEX" >/dev/null 2>&1 || true
            if pluginkit -m -D -i app.slovensko.chevron7.WebExtension -vvv 2>/dev/null | grep -F -q "Path = $INSTALLED_APPEX"; then
                registered=true
                break
            fi
            sleep 1
        done
        others="$(pluginkit -m -D -i app.slovensko.chevron7.WebExtension -vvv 2>/dev/null | sed -n 's/.*Path = //p' | grep -F -x -v "$INSTALLED_APPEX" || true)"
        if [[ "$registered" != true ]]; then
            echo "  (upozornenie: Safari rozšírenie sa nepodarilo zaregistrovať)" >&2
        elif [[ -n "$others" ]]; then
            echo "  (upozornenie: Safari stále vidí ďalšie kópie rozšírenia)" >&2
            printf '%s\n' "$others" >&2
        else
            echo "▸ Safari rozšírenie zaregistrované"
        fi
    fi
    echo "✔ Nainštalované: $INSTALL_DIR"
    if pgrep -x Safari >/dev/null 2>&1; then
        echo "  Safari beží: ukončite ho (⌘Q) a otvorte znova, inak rozšírenie hlási SFErrorDomain error 3."
    fi
elif [[ "$PACKAGE" == true ]]; then
    echo "▸ Safari rozšírenie ostáva v balíku: $APP_DIR"
else
    strip_build_product_extension
fi
