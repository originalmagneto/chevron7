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

# A DMG downloaded in a browser carries quarantine flags on every file inside,
# and Safari hides a quarantined appex: pluginkit discovers it (-D lists it)
# but the enabled match (-m without -D) stays empty and Settings > Extensions
# shows no row. Approving the app in Gatekeeper does not clear the appex.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# LaunchServices finds the appex on first app launch, but a quarantined or
# freshly staged copy can stay discovery-only, so register it explicitly.
APPEX="$APP/Contents/PlugIns/Chevron7WebExtension.appex"
if [[ -d "$APPEX" ]]; then
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
    pluginkit -a "$APPEX" >/dev/null 2>&1 || true
fi

echo "Safari: ukoncite ho (Cmd+Q), otvorte znova, zapnite Develop > Allow Unsigned Extensions a skontrolujte Settings > Extensions."
