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

# A DMG downloaded in a browser carries quarantine (and provenance) flags on
# every file inside. Stripping just the quarantine was not enough: Safari kept
# logging "Computing the code signing dictionary failed" for the appex and hid
# its row until the flags were cleared everywhere and the appex was signed
# again locally. Approving the app in Gatekeeper does not clean the appex.
xattr -cr "$APP" 2>/dev/null || true

APPEX="$APP/Contents/PlugIns/Chevron7WebExtension.appex"
if [[ -d "$APPEX" ]]; then
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
    codesign --force --sign - --entitlements "$APPEX_ENTITLEMENTS" "$APPEX" >/dev/null 2>&1 \
        || echo "  (upozornenie: appex sa nepodarilo znova podpísať)" >&2
    rm -f "$APPEX_ENTITLEMENTS"
    codesign --force --sign - "$APP" >/dev/null 2>&1 \
        || echo "  (upozornenie: aplikáciu sa nepodarilo znova podpísať)" >&2
    codesign --verify --deep --strict "$APP" >/dev/null 2>&1 \
        || echo "  (upozornenie: podpis aplikácie neprešiel kontrolou)" >&2

    # LaunchServices finds the appex on first app launch, but a freshly staged
    # copy can stay discovery-only, so register it explicitly.
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
    pluginkit -a "$APPEX" >/dev/null 2>&1 || true
fi

echo "Safari: ukoncite ho (Cmd+Q), otvorte znova, zapnite Develop > Allow Unsigned Extensions a skontrolujte Settings > Extensions."
