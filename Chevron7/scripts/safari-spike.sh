#!/bin/bash
# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-License-Identifier: EUPL-1.2
set -euo pipefail

# Answers the three unknowns behind the Safari extension in one run:
#   1. does Safari load a hand-assembled, adhoc-signed .appex
#   2. does the mach-lookup temporary exception hold without a Team ID
#   3. what is the ceiling on a native message
#
# Everything that can be checked without Safari is checked here. Enabling an
# unsigned extension is an in-memory Safari setting with no preference key, so
# that one step stays manual.

cd "$(dirname "$0")/.."

APP="/Applications/Chevron7.app"
APPEX="$APP/Contents/PlugIns/Chevron7WebExtension.appex"
SERVICE="app.slovensko.chevron7.webbridge"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✘\033[0m %s\n' "$1"; }

step "1. Je appex v nainštalovanej aplikácii?"
if [[ -d "$APPEX" ]]; then
    ok "$APPEX"
else
    bad "appex chýba - spusti najprv: DEVELOPER_DIR=\"/Applications/Xcode.app/Contents/Developer\" ./build_app.sh --release install"
    exit 1
fi

step "2. Má appex vložený mach-lookup entitlement?"
if codesign -d --entitlements - "$APPEX" 2>/dev/null | grep -q "$SERVICE"; then
    ok "temporary-exception.mach-lookup.global-name obsahuje $SERVICE"
else
    bad "entitlement chýba - Safari appex načíta, ale spojenie s aplikáciou zlyhá"
fi

step "3. Sedí principal class a extension point?"
POINT=$(/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionPointIdentifier" "$APPEX/Contents/Info.plist" 2>/dev/null || echo "")
CLASS=$(/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionPrincipalClass" "$APPEX/Contents/Info.plist" 2>/dev/null || echo "")
[[ "$POINT" == "com.apple.Safari.web-extension" ]] && ok "extension point: $POINT" || bad "extension point: '$POINT'"
[[ "$CLASS" == "Chevron7WebExtensionHandler" ]] && ok "principal class: $CLASS" || bad "principal class: '$CLASS'"

step "4. Sú web časti rozšírenia v Resources?"
for file in manifest.json background.js content.js ditec.js inject.js; do
    [[ -f "$APPEX/Contents/Resources/$file" ]] && ok "$file" || bad "$file chýba"
done

step "5. Je launchd agent zaregistrovaný?"
if launchctl print "gui/$(id -u)/$SERVICE" >/dev/null 2>&1; then
    ok "agent $SERVICE je v launchd"
else
    bad "agent chýba - spusti: ./scripts/install-webbridge-agent.sh"
fi

step "6. Beží aplikácia a je dosiahnuteľná cez agenta?"
if ! pgrep -x "Chevron7" >/dev/null 2>&1; then
    echo "  Aplikácia nebeží, spúšťam ju..."
    open "$APP"
    sleep 4
fi
if "$(swift build --show-bin-path 2>/dev/null)/webbridge-probe" 2>&1 | sed 's/^/  /'; then
    ok "XPC transport funguje (appková polovica je overená)"
else
    bad "XPC spojenie zlyhalo - pozri log: log show --last 2m --predicate 'subsystem == \"app.slovensko.chevron7\"'"
fi

cat <<'MANUAL'

──────────────────────────────────────────────────────────────────────────
Zvyšok sa bez teba spraviť nedá. Tri kroky v Safari:

  1. Safari > Settings > Advanced > zapni "Show features for web developers"
     (IncludeDevelopMenu už máš zapnuté)

  2. Safari > Develop > Allow Unsigned Extensions
     Pozor: Safari to zabudne pri každom štarte, musíš to zapnúť znova.

  3. Safari > Settings > Extensions > zapni "Chevron7"

Potom otvor https://www.slovensko.sk/ a vo web inspectore konzoly spusti:

     await window.chevron7.status()

  Očakávaný výsledok:  { ok: true, ready: true, version: "0.4.0" }
  (presne to už vracia sonda v kroku 6 bez Safari)

  ready:true znamená, že podpisový handler je pripravený. Samotný podpis
  ešte vyžaduje potvrdenie používateľom a kartu alebo mobil.

  Ak dostaneš { ok:false, error:"Chevron7 nebeží..." }, appex sa načítal,
  ale spojenie s aplikáciou zlyhalo. Skontroluj registráciu agenta,
  mach-lookup entitlement a výsledok XPC sondy vyššie.
──────────────────────────────────────────────────────────────────────────
MANUAL
