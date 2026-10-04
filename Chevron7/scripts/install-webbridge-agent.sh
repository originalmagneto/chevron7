#!/bin/bash
# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-License-Identifier: EUPL-1.2
set -euo pipefail

# Registers the launchd agent that owns the web bridge Mach service.
# Needed because launchd, not the app, decides who may publish a service name.

APP="${1:-/Applications/Chevron7.app}"
LABEL="app.slovensko.chevron7.webbridge"
AGENT="$APP/Contents/Helpers/chevron7-webbridge-agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[[ -x "$AGENT" ]] || { echo "Agent chýba: $AGENT" >&2; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$AGENT</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>$LABEL</key>
        <true/>
    </dict>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "✔ Agent zaregistrovaný: $LABEL"
launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | sed -n '1,6p' || true

# A release signed with Developer ID and notarized is left exactly as shipped:
# clearing its flags or signing it again would throw the notarization away.
TEAM_ID="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
DEVELOPER_ID=false
[[ -n "$TEAM_ID" && "$TEAM_ID" != "not set" ]] && DEVELOPER_ID=true

APPEX="$APP/Contents/PlugIns/Chevron7WebExtension.appex"
if [[ -d "$APPEX" && "$DEVELOPER_ID" == false ]]; then
    # An ad hoc build from a DMG downloaded in a browser carries quarantine (and
    # provenance) flags on every file inside. Stripping just the quarantine was
    # not enough: Safari kept logging "Computing the code signing dictionary
    # failed" for the appex and hid its row until the flags were cleared
    # everywhere and the appex was signed again locally. Approving the app in
    # Gatekeeper does not clean the appex.
    xattr -cr "$APP" 2>/dev/null || true

    # The appex must keep its sandbox + Mach lookup exception: a bare
    # `codesign --sign -` would drop them and break the native bridge.
    APPEX_ENTITLEMENTS="$(mktemp -t chevron7-appex-entitlements).plist"
    cat > "$APPEX_ENTITLEMENTS" <<'ENTPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
    <array>
        <string>app.slovensko.chevron7.webbridge</string>
    </array>
</dict>
</plist>
ENTPLIST
    if ! codesign --force --sign - --entitlements "$APPEX_ENTITLEMENTS" "$APPEX"; then
        echo "CHYBA: appex sa nepodarilo znova podpísať, registrácia sa preskakuje." >&2
        rm -f "$APPEX_ENTITLEMENTS"
        exit 1
    fi
    rm -f "$APPEX_ENTITLEMENTS"
    # Keep the app's own entitlements (Config/Chevron7App.entitlements, smart card slots).
    if ! codesign --force --sign - --preserve-metadata=entitlements "$APP"; then
        echo "CHYBA: aplikáciu sa nepodarilo znova podpísať, registrácia sa preskakuje." >&2
        exit 1
    fi
fi

if [[ -d "$APPEX" ]]; then
    if ! codesign --verify --deep --strict "$APP"; then
        echo "CHYBA: podpis aplikácie neprešiel kontrolou, registrácia sa preskakuje." >&2
        exit 1
    fi

    # LaunchServices finds the appex on first app launch, but a freshly staged
    # copy can stay discovery-only, so register it explicitly.
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
    pluginkit -a "$APPEX" >/dev/null 2>&1 || true
fi

if [[ "$DEVELOPER_ID" == true ]]; then
    echo "Safari: ukoncite ho (Cmd+Q), otvorte znova a zapnite Chevron7 v Settings > Extensions."
else
    echo "Safari: ukoncite ho (Cmd+Q), otvorte znova, zapnite Develop > Allow Unsigned Extensions a skontrolujte Settings > Extensions."
fi
