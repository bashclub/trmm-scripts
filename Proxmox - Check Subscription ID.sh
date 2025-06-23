#!/bin/bash

# Skript zur Überprüfung des Proxmox VE Subscription-Status
# Ergebnis wird ins Custom Field "PVESubID" geschrieben (TRMM)

# Nur auf Proxmox-Systemen sinnvoll
if [[ ! -d "/etc/pve" ]]; then
  echo "Nicht Proxmox"
  exit 0
fi

# Versuche den Lizenz-Key zu holen
if ! OUTPUT=$(pvesubscription get 2>&1); then
  echo "Fehler: $OUTPUT"
  exit 1
fi

# Extrahiere den Key
KEY=$(echo "$OUTPUT" | awk -F': ' '/^key:/ {print $2}')

# Falls kein Key vorhanden, "Community" zurückgeben
if [[ -z "$KEY" ]]; then
  echo "Community"
else
  echo "$KEY"
fi

exit 0
