#!/usr/bin/env bash
#
# Proxmox VE Health Check Script
#
# Exitcodes:
#   0 = OK
#   1 = WARN oder ERROR

set -u

MIN_MAJOR_VERSION=8
EXIT_CODE=0

ok()   { echo "✅ $*"; }
info() { echo "ℹ️  $*"; }
warn() { echo "⚠️  $*"; EXIT_CODE=1; }
err()  { echo "❌ $*"; EXIT_CODE=1; }

indent() { sed 's/^/   /'; }

########################################
# 0) Prüfen ob Proxmox installiert ist
########################################

if ! command -v pveversion >/dev/null 2>&1; then
    info "Proxmox VE ist nicht installiert – keine Prüfung erforderlich."
    exit 0
fi

########################################
# 1) Proxmox Version prüfen
########################################

PVE_RAW="$(pveversion 2>/dev/null | awk '{print $1}')"
PVE_VER="$(echo "$PVE_RAW" | cut -d'/' -f2)"
PVE_MAJOR="$(echo "$PVE_VER" | cut -d'.' -f1)"

PREVIOUS_EXIT_CODE=$EXIT_CODE

if [[ -z "${PVE_MAJOR:-}" ]] || ! [[ "$PVE_MAJOR" =~ ^[0-9]+$ ]]; then
    warn "Konnte Proxmox-Version nicht sauber ermitteln (pveversion: '$PVE_RAW')."
else
    if (( PVE_MAJOR < MIN_MAJOR_VERSION )); then
        warn "Proxmox-Version $PVE_VER ist veraltet (Major $PVE_MAJOR), erwartet >= $MIN_MAJOR_VERSION."
    else
        ok "Proxmox-Version $PVE_VER ist aktuell genug (Major $PVE_MAJOR)."
    fi
fi

########################################
# 2) proxmox-boot-tool vorhanden?
########################################

if ! command -v proxmox-boot-tool >/dev/null 2>&1; then
    warn "proxmox-boot-tool ist nicht installiert – Bootmodus kann nicht geprüft werden."
    exit "$EXIT_CODE"
fi

########################################
# 3) proxmox-boot-tool status prüfen
########################################

BOOT_STATUS="$(proxmox-boot-tool status 2>&1)"
BOOT_RC=$?

########################################
# Sonderfall: kein proxmox-boot-tool konfiguriert
# NUR OK wenn vorher alles OK war
########################################

if (( BOOT_RC == 2 )) && echo "$BOOT_STATUS" | grep -q "/etc/kernel/proxmox-boot-uuids does not exist"; then
    
    if (( EXIT_CODE == 0 )); then
        ok "proxmox-boot-tool ist nicht konfiguriert (Legacy/GRUB System) – kein Fehler."
        info "Status:"
        echo "$BOOT_STATUS" | indent
        exit 0
    else
        warn "proxmox-boot-tool ist nicht konfiguriert UND vorherige Tests hatten WARN/ERROR."
        info "Status:"
        echo "$BOOT_STATUS" | indent
        exit "$EXIT_CODE"
    fi

fi

########################################
# echter Fehler
########################################

if (( BOOT_RC != 0 )); then
    err "proxmox-boot-tool status fehlgeschlagen (Exitcode $BOOT_RC)."
    echo "$BOOT_STATUS" | indent
    exit "$EXIT_CODE"
fi

########################################
# WARN erkennen
########################################

WARN_LINES="$(echo "$BOOT_STATUS" | grep 'WARN:' || true)"

if [[ -n "$WARN_LINES" ]]; then
    warn "proxmox-boot-tool meldet WARNungen:"
    echo "$WARN_LINES" | indent
fi

########################################
# Legacy boot erkennen
########################################

if echo "$BOOT_STATUS" | grep -qi "not using proxmox-boot-tool"; then
    warn "System verwendet NICHT proxmox-boot-tool (vermutlich GRUB oder legacy boot)."
fi

########################################
# Status anzeigen
########################################

if [[ "$EXIT_CODE" -eq 0 ]]; then
    ok "proxmox-boot-tool ist aktiv und fehlerfrei. Status:"
else
    info "proxmox-boot-tool Status:"
fi

echo "$BOOT_STATUS" | indent

exit "$EXIT_CODE"
