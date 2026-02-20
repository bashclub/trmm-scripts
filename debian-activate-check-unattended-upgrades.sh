#!/bin/bash
set -u

PKG="unattended-upgrades"
SERVICE="unattended-upgrades.service"
TIMER="unattended-upgrades.timer"

# --- Proxmox-Erkennung: PVE / PBS / PMG -> SKIP (OK) ---
is_proxmox() {
  # Pakete (robust, weil auf Proxmox-Systemen meist vorhanden)
  dpkg-query -W -f='${Status}\n' pve-manager 2>/dev/null | grep -q "install ok installed" && return 0
  dpkg-query -W -f='${Status}\n' proxmox-backup-server 2>/dev/null | grep -q "install ok installed" && return 0
  dpkg-query -W -f='${Status}\n' proxmox-mailgateway 2>/dev/null | grep -q "install ok installed" && return 0

  # Fallbacks: typische Kennzeichen
  [ -d /etc/pve ] && return 0
  grep -qiE 'proxmox|pve|pbs|pmg' /etc/issue 2>/dev/null && return 0

  return 1
}

if is_proxmox; then
  echo "OK (SKIP): Proxmox (PVE/PBS/PMG) erkannt – unattended-upgrades wird hier nicht geprüft/gesetzt."
  exit 0
fi

# --- Debian: unattended-upgrades installieren falls nötig ---
echo "Prüfe, ob $PKG installiert ist..."
if ! dpkg -s "$PKG" >/dev/null 2>&1; then
  echo "$PKG ist nicht installiert. Installiere..."

  export DEBIAN_FRONTEND=noninteractive

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "FEHLER: apt-get nicht gefunden – kann $PKG nicht installieren."
    exit 1
  fi

  apt-get update -qq || { echo "FEHLER: apt-get update fehlgeschlagen."; exit 1; }
  apt-get install -y "$PKG" || { echo "FEHLER: Installation von $PKG fehlgeschlagen."; exit 1; }

  echo "$PKG wurde installiert."
else
  echo "$PKG ist bereits installiert."
fi

# --- Danach prüfen ob Timer/Service läuft ---
echo "Prüfe, ob unattended-upgrades aktiv ist..."

if systemctl list-unit-files 2>/dev/null | grep -q "^${TIMER}"; then
  # Timer existiert
  if systemctl is-enabled "$TIMER" >/dev/null 2>&1 && systemctl is-active "$TIMER" >/dev/null 2>&1; then
    echo "OK: $TIMER ist enabled und active."
    exit 0
  else
    echo "FEHLER: $TIMER ist NICHT enabled/active!"
    systemctl status "$TIMER" --no-pager -l 2>/dev/null || true
    exit 1
  fi
else
  # Fallback auf Service
  if systemctl is-enabled "$SERVICE" >/dev/null 2>&1 && systemctl is-active "$SERVICE" >/dev/null 2>&1; then
    echo "OK: $SERVICE ist enabled und active."
    exit 0
  else
    echo "FEHLER: $SERVICE ist NICHT enabled/active!"
    systemctl status "$SERVICE" --no-pager -l 2>/dev/null || true
    exit 1
  fi
fi
