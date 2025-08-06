#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a  # vermeidet interaktive Neustart-Abfragen bei "needrestart"

SOURCES='/etc/apt/sources.list'
BACKUP='/etc/apt/sources.list.bookworm.bak'

echo "[*] Backup der aktuellen sources.list nach $BACKUP"
cp "$SOURCES" "$BACKUP"

echo "[*] Ersetze 'bookworm' durch 'trixie' in sources.list"
sed -E '
  s/^(deb(-src)?\s+[^ ]+)\s+bookworm(-security|-updates)?\b/\1 trixie\3/g
' -i "$SOURCES"

echo "[*] Aktualisiere Paketquellen"
apt-get update -y

echo "[*] Stelle sicher, dass wichtige Pakete installiert sind"
apt-get install -y --no-install-recommends apt apt-utils debian-archive-keyring

echo "[*] Volles Systemupgrade durchführen (Konfigfragen automatisch beantworten)"
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade -y

echo "[*] Automatische Entfernung veralteter Pakete"
apt-get autoremove -y
apt-get autoclean -y

echo "[✓] Upgrade abgeschlossen. Neustart empfohlen."
