#!/bin/bash
# Read-only probe of Czech signing cards and tokens for Chevron7 (Czech signing plan, Task 1).
#
# It never logs in to a token, never asks for or sends a PIN, QPIN or any other code,
# and changes nothing on the Mac or the card. It writes one text report to the Desktop
# with: macOS version, installed card middleware and its architectures, the readers and
# CryptoTokenKit tokens macOS sees, and (when OpenSC's pkcs11-tool is installed) each
# PKCS#11 token's flags, mechanisms and public certificates.
#
# Usage: bash czech-card-probe.sh            (insert the card first)
# Optional: brew install opensc               (adds the PKCS#11 part of the report)
#
# Written for the macOS system bash 3.2: no associative arrays, no mapfile.

set -u

SCRIPT_VERSION="2026-10-04"
STAMP=$(date +%Y%m%d-%H%M)
REPORT_DIR="$HOME/Desktop"
[ -d "$REPORT_DIR" ] || REPORT_DIR="$HOME"
REPORT="$REPORT_DIR/chevron7-cz-karta-$STAMP.txt"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/chevron7-cz-probe.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Library paths from the plan (Task 1 step 2) plus the engine's macOS driver list.
KNOWN_LIBRARIES="
/usr/local/lib/pkcs11/libICASecureStorePkcs11.dylib
/usr/local/lib/eOPCZE/libeopproxyp11.dylib
/usr/local/lib/libeTPkcs11.dylib
/usr/local/lib/libIDPrimePKCS11.dylib
/Library/bit4id/pkcs11/libbit4xpki.dylib
/usr/local/lib/ProIDPlus/libproidqcm11.dylib
"

MIDDLEWARE_PATTERN='ica|securestore|eop|obcank|občank|monet|proid|safenet|etoken|idprime|gemalto|thales|bit4id|postsignum|eidentity|opensc'

say() { printf '%s\n' "$*"; }
log() { printf '%s\n' "$*" >> "$REPORT"; }
section() { log ""; log "== $* =="; }

# Runs a command with a time limit and stdin closed, so a middleware that hangs or
# wants input can never block the probe or receive anything.
bounded() {
    local seconds=$1
    shift
    if command -v perl > /dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$seconds" "$@" < /dev/null
    else
        "$@" < /dev/null
    fi
}

run() {
    log "\$ $*"
    bounded 60 "$@" >> "$REPORT" 2>&1
    local status=$?
    [ $status -eq 0 ] || log "(exit $status)"
}

library_label() {
    case "$1" in
        *libICASecureStorePkcs11*) echo "I.CA SecureStore" ;;
        *libeopproxyp11*) echo "eObčanka" ;;
        *libeTPkcs11*) echo "Thales SafeNet Authentication Client" ;;
        *libIDPrimePKCS11*) echo "Thales IDPrime" ;;
        *libbit4xpki*) echo "Bit4id" ;;
        *libproidqcm11*) echo "MONET+ ProID+" ;;
        *opensc*) echo "OpenSC" ;;
        *) echo "neznámá knihovna" ;;
    esac
}

# Which libraries Chevron7 may try a test signature with today. Only I.CA: every other
# Czech device has a separate signing code (QPIN) and today's engine would send the
# typed PIN as that code, spending one of its three attempts (plan Tasks 3 and 5).
signing_test_allowed() {
    case "$1" in
        *libICASecureStorePkcs11*) return 0 ;;
        *) return 1 ;;
    esac
}

# QC statement OIDs as DER (tag, length, value), searched in the certificate bytes.
qc_flags() {
    local hex
    hex=$(xxd -p "$1" | tr -d '\n')
    local found=""
    case "$hex" in *060604008e460101*) found="$found QcCompliance" ;; esac
    case "$hex" in *060604008e460104*) found="$found QcSSCD" ;; esac
    case "$hex" in *060704008e46010601*) found="$found QcType=esign" ;; esac
    case "$hex" in *060704008e46010602*) found="$found QcType=eseal" ;; esac
    [ -n "$found" ] && echo "${found# }" || echo "none"
}

describe_certificate() {
    local der=$1
    local text
    text=$(openssl x509 -inform DER -in "$der" -noout -text 2>/dev/null) || {
        log "  (certificate could not be parsed)"
        return
    }
    if printf '%s' "$text" | grep -q 'CA:TRUE'; then
        CA_CERTIFICATES=$((CA_CERTIFICATES + 1))
        return
    fi
    log ""
    log "-- end-entity certificate, PKCS#11 id $2"
    openssl x509 -inform DER -in "$der" -noout -subject -issuer -dates -serial -nameopt utf8,sep_comma_plus >> "$REPORT" 2>&1
    printf '%s\n' "$text" | grep -E 'Public Key Algorithm|Public-Key:|ASN1 OID|NIST CURVE|Signature Algorithm' | sort -u | sed 's/^ */  /' >> "$REPORT"
    printf '%s\n' "$text" | grep -A1 -E 'X509v3 Key Usage|Extended Key Usage|Certificate Policies' | grep -v '^--$' | sed 's/^ */  /' >> "$REPORT"
    log "  QC statements: $(qc_flags "$der")"
    openssl x509 -inform DER -in "$der" -outform PEM >> "$REPORT" 2>&1
}

VERDICTS=""
add_verdict() { VERDICTS="$VERDICTS$1
"; }

say "Chevron7: diagnostika české karty (jen čtení, žádný PIN se nezadává)."
say "Pokud se objeví okno s žádostí o PIN, klikněte na Zrušit a nic nezadávejte."
say "Trvá 1 až 3 minuty."
say ""

: > "$REPORT"
log "Chevron7 Czech card probe $SCRIPT_VERSION"
log "Generated: $(date '+%Y-%m-%d %H:%M:%S %z')"
log "This probe never logs in and never sends a PIN or QPIN."

section "System"
run sw_vers
run uname -m

say "1/5 Instalované ovladače..."
section "Installed middleware (pkgutil)"
for pkg in $(pkgutil --pkgs 2>/dev/null | grep -iE "$MIDDLEWARE_PATTERN"); do
    log "-- $pkg"
    pkgutil --pkg-info "$pkg" 2>/dev/null | grep -E '^(version|install-time):' >> "$REPORT"
done
section "Applications"
for app in /Applications/*.app; do
    name=$(basename "$app")
    if printf '%s' "$name" | grep -qiE "$MIDDLEWARE_PATTERN"; then
        version=$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null)
        log "$name ${version:-?}"
    fi
done

say "2/5 Knihovny PKCS#11..."
describe_library() {
    local archs team
    archs=$(lipo -archs "$1" 2>/dev/null)
    team=$(codesign -dv "$1" 2>&1 | grep -E '^TeamIdentifier=' | cut -d= -f2)
    log "$1"
    log "  middleware: $(library_label "$1"), archs: ${archs:-unknown}, team: ${team:-none}"
}
section "PKCS#11 libraries Chevron7 knows"
PRESENT_LIBRARIES=""
for lib in $KNOWN_LIBRARIES; do
    if [ -e "$lib" ]; then
        describe_library "$lib"
        PRESENT_LIBRARIES="$PRESENT_LIBRARIES$lib
"
    else
        log "$lib: not installed"
    fi
done
# Other PKCS#11 modules are only listed, never loaded: a Czech vendor library at an
# unexpected path shows up here, generic modules (OpenSC, p11-kit) are left out.
section "Other PKCS#11 libraries (listed, not loaded)"
find /usr/local/lib /Library -maxdepth 4 \( -iname '*pkcs11*.dylib' -o -iname '*p11*.dylib' -o -iname '*pkcs11*.so' \) 2>/dev/null \
    | grep -viE 'opensc|p11-kit|pkcs11-spy' | sort -u | while read -r lib; do
        case "$KNOWN_LIBRARIES" in *"$lib"*) continue ;; esac
        describe_library "$lib"
    done

say "3/5 Čtečky a tokeny macOS..."
section "Readers and CryptoTokenKit"
run system_profiler SPSmartCardsDataType
run security list-smartcards
for token in $(security list-smartcards 2>/dev/null | grep -v 'No smartcards' ); do
    log "-- export-smartcard $token (certificates only)"
    bounded 60 security export-smartcard -i "$token" -t certs >> "$REPORT" 2>&1
done

say "4/5 Tokeny přes PKCS#11..."
section "PKCS#11 tokens (pkcs11-tool, no login)"
PKCS11_TOOL=$(command -v pkcs11-tool || true)
[ -z "$PKCS11_TOOL" ] && [ -x /opt/homebrew/bin/pkcs11-tool ] && PKCS11_TOOL=/opt/homebrew/bin/pkcs11-tool
MACHINE=$(uname -m)
if [ -z "$PKCS11_TOOL" ]; then
    log "pkcs11-tool not installed (brew install opensc); token flags and mechanisms not recorded."
fi

for lib in $PRESENT_LIBRARIES; do
    label=$(library_label "$lib")
    archs=$(lipo -archs "$lib" 2>/dev/null)
    case " $archs " in
        *" $MACHINE "*) ;;
        *)
            log "-- $lib: no $MACHINE slice, Chevron7 cannot load it"
            add_verdict "$label: knihovna nemá $MACHINE, Chevron7 ji nenačte."
            continue
            ;;
    esac
    if [ -z "$PKCS11_TOOL" ]; then
        if signing_test_allowed "$lib"; then
            add_verdict "$label: zkušební podpis v Chevron7 je povolen, jeden pokus podle návodu (stav karty nezjištěn bez pkcs11-tool)."
        else
            add_verdict "$label: zatím v Chevron7 nepodepisujte (samostatný QPIN), pošlete jen tento report."
        fi
        continue
    fi

    log ""
    log "-- $label ($lib)"
    slots_file="$WORK/slots.txt"
    bounded 60 "$PKCS11_TOOL" --module "$lib" -L > "$slots_file" 2>&1
    cat "$slots_file" >> "$REPORT"
    slots=$(awk '/^Slot [0-9]+ \(0x[0-9a-fA-F]+\):/ { id=$3; gsub(/[():]/, "", id) } /token label/ { print id }' "$slots_file")
    if [ -z "$slots" ]; then
        add_verdict "$label: knihovna je nainstalovaná, ale nevidí žádnou kartu."
        continue
    fi
    for slot in $slots; do
        log ""
        log "-- slot $slot: mechanisms"
        bounded 60 "$PKCS11_TOOL" --module "$lib" --slot "$slot" -M 2>&1 | grep -iE 'ecdsa|rsa-pkcs|pss|sha(256|384|512)-' >> "$REPORT"
        log "-- slot $slot: public objects"
        objects_file="$WORK/objects-$slot.txt"
        bounded 60 "$PKCS11_TOOL" --module "$lib" --slot "$slot" -O > "$objects_file" 2>&1
        grep -E 'Object;|label:|ID:|Usage:|Access:' "$objects_file" >> "$REPORT"
        ids=$(awk '/Certificate Object/ { cert=1; next } /Object;/ { cert=0 } cert && /ID:/ { gsub(/[: ]/, "", $0); sub(/^ID/, "", $0); print }' "$objects_file" | sort -u)
        CA_CERTIFICATES=0
        for id in $ids; do
            der="$WORK/cert-$slot-$id.der"
            if bounded 60 "$PKCS11_TOOL" --module "$lib" --slot "$slot" -r --type cert --id "$id" -o "$der" > /dev/null 2>&1; then
                describe_certificate "$der" "$id"
            fi
        done
        log ""
        log "-- slot $slot: $CA_CERTIFICATES CA certificates on the token (not listed)"

        flags=$(grep -m1 'token flags' "$slots_file")
        case "$flags" in
            *"PIN locked"*|*"final try"*|*"count low"*)
                add_verdict "$label (slot $slot): karta hlásí málo zbývajících pokusů PIN nebo blokaci. Nepodepisujte, pošlete jen tento report."
                continue
                ;;
        esac
        if signing_test_allowed "$lib"; then
            add_verdict "$label (slot $slot): zkušební podpis v Chevron7 je povolen, jeden pokus podle návodu."
        else
            add_verdict "$label (slot $slot): zatím v Chevron7 nepodepisujte (samostatný QPIN), pošlete jen tento report."
        fi
    done
done

say "5/5 Shrnutí..."
section "Verdict"
if [ -z "$VERDICTS" ]; then
    if [ -z "$PKCS11_TOOL" ]; then
        VERDICTS="Bez pkcs11-tool nelze kartu přes PKCS#11 přečíst. Pošlete tento report; s 'brew install opensc' bude úplnější.
"
    else
        VERDICTS="Žádná karta nebyla nalezena. Zasuňte kartu do čtečky a spusťte skript znovu.
"
    fi
fi
printf '%s' "$VERDICTS" >> "$REPORT"

say ""
printf '%s' "$VERDICTS"
say ""
say "Report: $REPORT"
say "Obsahuje veřejné certifikáty z karty (jméno, vydavatel), žádný PIN ani soukromý klíč."
say "Pošlete prosím tento soubor zpět."
