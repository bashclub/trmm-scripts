#!/bin/bash

# Skript zur Überprüfung des Proxmox VE Subscription-Status

# Überprüfen, ob das Kommando verfügbar ist
if ! command -v pvesubscription &>/dev/null; then
  echo "Das Kommando 'pvesubscription' ist nicht verfügbar. Bitte überprüfen Sie, ob Proxmox VE korrekt installiert ist.",exit >&2
  exit 0
fi

# Befehl ausführen und Output erfassen
OUTPUT=$(pvesubscription get 2>&1)

# Überprüfen, ob der Befehl erfolgreich war
if [[ $? -ne 0 ]]; then
  echo "Fehler beim Ausführen von 'pvesubscription get':" >&2
  echo "$OUTPUT" >&2
  exit 1
fi

# Nur den Key aus der Ausgabe extrahieren
KEY=$(echo "$OUTPUT" | grep -i '^key:' | awk '{print $2}')

if [[ -z "$KEY" ]]; then
  echo "Kein Key gefunden (Community-Version oder keine Lizenz)."
else
  echo "Key: $KEY"
fi

exit 0
