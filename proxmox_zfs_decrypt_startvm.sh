#!/bin/bash

VMID=666
DATASET="rpool/crypt"
ZFS_PASSPHRASE='mein_geheimes_passwort'

# Prüfe VM-Status
status=$(qm status "$VMID" | awk '{print $2}')

if [ "$status" == "stopped" ]; then
    echo "VM $VMID ist gestoppt. Lade ZFS-Schlüssel und starte VM..."

    # Übergabe der Passphrase per stdin
    echo "$ZFS_PASSPHRASE" | zfs load-key "$DATASET"

    # Starte die VM
    qm start "$VMID"
else
    echo "VM $VMID ist bereits gestartet oder nicht gefunden. Status: $status"
fi

