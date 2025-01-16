#!/bin/bash

# Skript zur Überprüfung des Proxmox VE Subscription-Status

# Überprüfung, ob der Ordner /etc/pve existiert
if [[ -d "/etc/pve" ]]; then
    echo "Proxmox VE erkannt. Skript wird fortgesetzt."
else
    echo "Dieses System ist kein Proxmox VE" >&2
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
