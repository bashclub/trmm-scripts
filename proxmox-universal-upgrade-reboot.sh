#!/bin/bash

if [[ $(id -u) -ne 0 ]]; then
  echo "Dieses Skript muss als Root ausgeführt werden."
  exit 1
fi

detect_system_type() {
  if [[ -x /usr/bin/pveversion ]] && uname -r | grep -qi "pve"; then
    echo "pve"
  elif [[ -f /etc/univention/base.conf ]] && grep -qi "univention" /etc/issue; then
    echo "ucs"
  elif grep -qi "ubuntu" /etc/os-release 2>/dev/null || lsb_release -i 2>/dev/null | grep -qi "ubuntu"; then
    echo "ubuntu"
  elif grep -qi "debian" /etc/os-release 2>/dev/null || lsb_release -i 2>/dev/null | grep -qi "debian"; then
    echo "debian"
  else
    echo "unknown"
  fi
}

run_pve_update() {
  LXC_LOGFILE="/var/log/lxc_update.log"
  LOGFILE="/var/log/proxmox_update.log"
  REBOOT=${REBOOT:-NO}
  AUTOREMOVE=${AUTOREMOVE:-NO}
  TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
  ZFS_DATASETS=("rpool/ROOT" "rpool/pveconf")
  SNAPSHOT_TAG="pve-update-via-rmm"
  MAX_SNAPSHOTS=5

  echo "--- LXC Container Update Log - $(date) ---" > "$LXC_LOGFILE"

  if command -v lxc-ls >/dev/null 2>&1; then
    container_ids=$(lxc-ls --active 2>/dev/null)
  else
    container_ids=""
  fi

  if [[ -z "$container_ids" ]]; then
    echo "Keine aktiven LXC-Container gefunden." | tee -a "$LXC_LOGFILE"
  else
    for id in $container_ids; do
      hostname_ct=$(lxc-attach -n "$id" -- hostname 2>/dev/null || echo "unknown")

      update_output=$(lxc-attach -n "$id" -- env DEBIAN_FRONTEND=noninteractive apt-get update 2>&1)
      if echo "$update_output" | grep -qE "GPG-Fehler|GPG error|Fehlschlag beim Holen|Failed to fetch|Einige Indexdateien konnten nicht heruntergeladen werden"; then
        echo "🔴 Fehler beim Aktualisieren der Paketlisten in Container $id ($hostname_ct)!" | tee -a "$LXC_LOGFILE"
        echo "$update_output" | tee -a "$LXC_LOGFILE"
        continue
      fi

      upgradable=$(lxc-attach -n "$id" -- apt list --upgradable 2>/dev/null | grep -c "upgradable")
      if [[ "$upgradable" -eq 0 ]]; then
        echo "🟢 Keine neuen Updates für Container $id ($hostname_ct)." | tee -a "$LXC_LOGFILE"
        continue
      fi

      if lxc-attach -n "$id" -- env DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y >> "$LXC_LOGFILE" 2>&1; then
        echo "✅ Container $id ($hostname_ct) wurde aktualisiert." | tee -a "$LXC_LOGFILE"
      else
        echo "🔴 Fehler beim Update von Container $id ($hostname_ct)." | tee -a "$LXC_LOGFILE"
      fi
    done
  fi

  echo "--- Proxmox Host Update Log - $(date) ---" > "$LOGFILE"

  update_output=$(apt-get update 2>&1)
  echo "$update_output" | tee -a "$LOGFILE"

  if echo "$update_output" | grep -qE "GPG-Fehler|GPG error|Fehlschlag beim Holen|Failed to fetch|Einige Indexdateien konnten nicht heruntergeladen werden"; then
    echo "🔴 Fehler beim Aktualisieren der Paketlisten auf dem PVE-Host!" | tee -a "$LOGFILE"
    exit 2
  fi

  UPGRADE_COUNT=$(apt list --upgradable 2>/dev/null | grep -c "upgradable")

  if [[ "$UPGRADE_COUNT" -eq 0 ]]; then
    echo "🟢 Keine neuen Updates für den Proxmox-Host verfügbar." | tee -a "$LOGFILE"
  else
    declare -A SNAPSHOT_NAMES

    for dataset in "${ZFS_DATASETS[@]}"; do
      if zfs list "$dataset" >/dev/null 2>&1; then
        SNAPSHOT_NAMES[$dataset]="${dataset}@${SNAPSHOT_TAG}-$TIMESTAMP"

        SNAPSHOTS_TO_DELETE=$(zfs list -H -t snapshot -o name 2>/dev/null \
          | grep "^${dataset}@${SNAPSHOT_TAG}-" \
          | sort \
          | head -n -$MAX_SNAPSHOTS)

        if [[ -n "$SNAPSHOTS_TO_DELETE" ]]; then
          echo "$SNAPSHOTS_TO_DELETE" | xargs -r -n1 zfs destroy -r
        fi

        zfs snapshot "${SNAPSHOT_NAMES[$dataset]}"
        echo "📸 Snapshot erstellt: ${SNAPSHOT_NAMES[$dataset]}" | tee -a "$LOGFILE"
      else
        echo "🟡 Dataset nicht vorhanden, Snapshot übersprungen: $dataset" | tee -a "$LOGFILE"
      fi
    done

    upgrade_output=$(DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y 2>&1)
    apt_rc=$?
    echo "$upgrade_output" | tee -a "$LOGFILE"

    if [[ "$apt_rc" -ne 0 ]]; then
      echo "🟡 apt-get dist-upgrade lieferte Exitcode $apt_rc. Prüfe Systemzustand." | tee -a "$LOGFILE"
    fi
  fi

  DPKG_AUDIT=$(dpkg --audit 2>&1)
  if [[ -n "$DPKG_AUDIT" ]]; then
    echo "🔴 dpkg --audit meldet Probleme - kein Reboot und kein autoremove!" | tee -a "$LOGFILE"
    echo "$DPKG_AUDIT" | tee -a "$LOGFILE"
    exit 2
  fi

  BOOT_STATUS=$(proxmox-boot-tool status 2>&1)
  echo "$BOOT_STATUS" | tee -a "$LOGFILE"

  if echo "$BOOT_STATUS" | grep -qiE '^WARN:|^E:|does not exist|skipping|failed|cannot|error'; then
    echo "🔴 proxmox-boot-tool nicht sauber - Auto-Reboot blockiert!" | tee -a "$LOGFILE"
    exit 2
  fi

  if [[ "$AUTOREMOVE" == "YES" ]]; then
    echo "🧹 Führe apt autoremove aus..." | tee -a "$LOGFILE"
    apt-get autoremove -y 2>&1 | tee -a "$LOGFILE"

    DPKG_AUDIT_AFTER_AUTOREMOVE=$(dpkg --audit 2>&1)
    if [[ -n "$DPKG_AUDIT_AFTER_AUTOREMOVE" ]]; then
      echo "🔴 dpkg --audit meldet nach autoremove Probleme - kein Reboot!" | tee -a "$LOGFILE"
      echo "$DPKG_AUDIT_AFTER_AUTOREMOVE" | tee -a "$LOGFILE"
      exit 2
    fi
  fi

  CURRENT_KERNEL=$(uname -r)
  LATEST_KERNEL=$(ls -1 /boot/vmlinuz-*-pve 2>/dev/null \
    | sed 's#/boot/vmlinuz-##' \
    | sort -V \
    | tail -n1)

  if [[ -z "$LATEST_KERNEL" ]]; then
    echo "🔴 Kein installierter PVE-Kernel in /boot gefunden - kein Reboot!" | tee -a "$LOGFILE"
    exit 2
  fi

  echo "Aktueller Kernel: $CURRENT_KERNEL" | tee -a "$LOGFILE"
  echo "Neuester Kernel:  $LATEST_KERNEL" | tee -a "$LOGFILE"

  if [[ "$CURRENT_KERNEL" == "$LATEST_KERNEL" ]]; then
    echo "✅ Aktueller Kernel ist bereits gebootet - kein Reboot erforderlich." | tee -a "$LOGFILE"
    exit 0
  fi

  if [[ "$REBOOT" == "YES" ]]; then
    echo "🔄 Auto-Reboot freigegeben: neuer Kernel vorhanden, dpkg sauber, proxmox-boot-tool sauber." | tee -a "$LOGFILE"

    if pvesh create /nodes/$(hostname)/status --command reboot; then
      exit 0
    else
      echo "🔴 Reboot konnte nicht ausgelöst werden." | tee -a "$LOGFILE"
      exit 2
    fi
  else
    echo "⚠️ Neuer Kernel vorhanden, Reboot erforderlich, aber REBOOT != YES." | tee -a "$LOGFILE"
    exit 1
  fi
}

run_ucs_update() {
  LOGFILE="/var/log/ucs_update.log"
  REBOOT=${REBOOT:-NO}
  AUTOREMOVE=${AUTOREMOVE:-NO}

  echo "--- Univention Update Log - $(date) ---" > "$LOGFILE"

  upgrade_output=$(univention-upgrade --noninteractive --disable-app-updates 2>&1)
  echo "$upgrade_output" | tee -a "$LOGFILE"

  if echo "$upgrade_output" | grep -qE "FAILED|ERR|GPG error|Fehlschlag|nicht aufgelöst"; then
    echo "🔴 Fehler beim Univention Upgrade!" | tee -a "$LOGFILE"
    exit 2
  fi

  if [[ "$AUTOREMOVE" == "YES" ]]; then
    apt-get autoremove -y 2>&1 | tee -a "$LOGFILE"
  fi

  if [[ -f /var/run/reboot-required ]]; then
    echo "⚠️ Neustart empfohlen." | tee -a "$LOGFILE"
    if [[ "$REBOOT" == "YES" ]]; then
      reboot
      exit 0
    fi
    exit 1
  fi

  echo "✅ UCS erfolgreich aktualisiert." | tee -a "$LOGFILE"
  exit 0
}

run_debian_like_update() {
  if [[ "$system_type" == "ubuntu" ]]; then
    LOGFILE="/var/log/ubuntu_update.log"
  else
    LOGFILE="/var/log/debian_update.log"
  fi

  REBOOT=${REBOOT:-NO}
  AUTOREMOVE=${AUTOREMOVE:-NO}

  echo "--- Debian/Ubuntu Update Log - $(date) ---" > "$LOGFILE"

  update_output=$(apt-get update 2>&1)
  echo "$update_output" | tee -a "$LOGFILE"

  if echo "$update_output" | grep -qE "GPG-Fehler|GPG error|Fehlschlag beim Holen|Failed to fetch"; then
    echo "🔴 Fehler bei apt update!" | tee -a "$LOGFILE"
    exit 2
  fi

  upgrade_output=$(DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y 2>&1)
  apt_rc=$?
  echo "$upgrade_output" | tee -a "$LOGFILE"

  if [[ "$apt_rc" -ne 0 ]]; then
    echo "🔴 Fehler bei apt dist-upgrade!" | tee -a "$LOGFILE"
    exit 2
  fi

  DPKG_AUDIT=$(dpkg --audit 2>&1)
  if [[ -n "$DPKG_AUDIT" ]]; then
    echo "🔴 dpkg --audit meldet Probleme!" | tee -a "$LOGFILE"
    echo "$DPKG_AUDIT" | tee -a "$LOGFILE"
    exit 2
  fi

  if [[ "$AUTOREMOVE" == "YES" ]]; then
    apt-get autoremove -y 2>&1 | tee -a "$LOGFILE"
  fi

  if [[ -f /var/run/reboot-required ]]; then
    echo "⚠️ Neustart empfohlen." | tee -a "$LOGFILE"
    if [[ "$REBOOT" == "YES" ]]; then
      reboot
      exit 0
    fi
    exit 1
  fi

  echo "✅ System erfolgreich aktualisiert." | tee -a "$LOGFILE"
  exit 0
}

LOCKFILE="/var/run/universal_update.lock"

if [[ -e "$LOCKFILE" ]]; then
  echo "⚠️ Update läuft bereits (Lockfile: $LOCKFILE). Abbruch."
  exit 100
fi

trap "rm -f $LOCKFILE" EXIT
touch "$LOCKFILE"

system_type=$(detect_system_type)

case "$system_type" in
  pve)
    run_pve_update
    ;;
  ucs)
    run_ucs_update
    ;;
  debian|ubuntu)
    run_debian_like_update
    ;;
  *)
    echo "❌ Unbekanntes System. Kein Update möglich."
    exit 3
    ;;
esac
