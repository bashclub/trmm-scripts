#!/bin/bash

# Überprüfen Sie den Status aller ZFS-Pools auf dem System
all_pools=$(zpool list -H -o name)

for pool in $all_pools; do
  pool_status=$(zpool status -x $pool | grep -i "DEGRADED\|FAULTED\|OFFLINE\|UNAVAIL")

  if [ -z "$pool_status" ]; then
    # Wenn der Pool-Status erfolgreich ist (kein Fehler)
    echo "ZFS-Pool '$pool' ist in Ordnung."
  else
    # Wenn ein Fehler im Pool-Status vorliegt
    echo "FEHLER: ZFS-Pool '$pool' hat Probleme."
    exit 3  # Kritischer Fehler
  fi
done

# Alle Pools wurden erfolgreich überprüft
echo "Alle ZFS-Pools sind in Ordnung."
exit 0  # Erfolg
