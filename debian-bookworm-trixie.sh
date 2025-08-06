#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

BACKUP_DIR="/etc/apt/sources.list.d/backup-bookworm"
RESTORE_NEEDED=false

echo "[*] Backup der Paketquellen"

cp /etc/apt/sources.list /etc/apt/sources.list.bookworm.bak
mkdir -p "$BACKUP_DIR"
find /etc/apt/sources.list.d/ -name '*.list' -exec cp {} "$BACKUP_DIR/" \;

echo "[*] Ersetze 'bookworm' durch 'trixie' in /etc/apt/sources.list"
sed -i -E 's/\bbookworm(-security|-updates)?\b/trixie\1/g' /etc/apt/sources.list

echo "[*] Ersetze 'bookworm' durch 'trixie' in allen Dateien unter /etc/apt/sources.list.d/"
find /etc/apt/sources.list.d/ -name '*.list' -exec sed -i -E 's/\bbookworm(-security|-updates)?\b/trixie\1/g' {} \;

echo "[*] Update der Paketlisten"

if ! apt-get update -y; then
    echo "[✗] apt-get update fehlgeschlagen – Wiederherstellung der alten Paketquellen..."

    echo "[*] Wiederherstelle /etc/apt/sources.list"
    cp /etc/apt/sources.list.bookworm.bak /etc/apt/sources.list

    echo "[*] Wiederherstelle Dateien in /etc/apt/sources.list.d/"
    for f in "$BACKUP_DIR"/*.list; do
        basefile=$(basename "$f")
        cp "$f" "/etc/apt/sources.list.d/$basefile"
    done

    echo "[✓] Wiederherstellung abgeschlossen. Bitte überprüfe die Repos manuell."
    exit 1
fi

echo "[*] Sicherstellen, dass wichtige Pakete verfügbar sind"
apt-get install -y --no-install-recommends apt apt-utils debian-archive-keyring

echo "[*] Volles Upgrade starten (non-interaktiv, ohne Konfig-Prompts)"
apt-get -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        dist-upgrade -y

echo "[*] Veraltete Pakete entfernen"
apt-get autoremove -y
apt-get autoclean -y

echo "[✓] Upgrade abgeschlossen. Ein Reboot wird empfohlen."
