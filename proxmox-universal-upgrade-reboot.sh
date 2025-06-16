#!/bin/bash

# ============================
# UNIVERSAL UPDATE-SKRIPT (inkl. Auto-Reboot + Auto-Cleanup)
# Erkennt automatisch: PVE / UCS / Debian / Ubuntu
# Führt das passende Update durch, erkennt Keyring-Probleme,
# erstellt Snapshots (bei PVE), und führt optional Neustart aus
# Optional: Bereinigt alte Pakete mit AUTOREMOVE=YES
# ============================
# Tactical RMM Beispiel:
# Unter Enviroment vars "REBOOT=YES" "AUTOREMOVE=YES" ohne "" /pfad/zum/universal_update.sh

# Nur als Root ausführen
if [[ $(id -u) -ne 0 ]]; then
  echo "Dieses Skript muss als Root ausgeführt werden."
  exit 1
fi

# ======================================
# SYSTEMERKENNUNG
# ======================================
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

# ======================================
# PVE-Komplettes Update (inkl. LXCs)
# ======================================
run_pve_update() {
  # Logdateien definieren
  LXC_LOGFILE="/var/log/lxc_update.log"
  LOGFILE="/var/log/proxmox_update.log"
  REBOOT=${REBOOT:-NO}
  TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
  ZFS_DATASETS=("rpool/ROOT" "rpool/pveconf")
  SNAPSHOT_TAG="pve-update-via-rmm"
  MAX_SNAPSHOTS=5

  echo "--- LXC Container Update Log - $(date) ---" > "$LXC_LOGFILE"
  container_ids=$(lxc-ls --active)

  if [[ -z "$container_ids" ]]; then
    echo "Keine aktiven LXC-Container gefunden." | tee -a "$LXC_LOGFILE"
  else
    reboot_required=0
    update_failed=0
    for id in $container_ids; do
      hostname=$(lxc-attach -n $id -- hostname)
      update_output=$(lxc-attach -n $id -- env DEBIAN_FRONTEND=noninteractive apt-get update 2>&1)
      if echo "$update_output" | grep -qE "GPG-Fehler|Fehlschlag beim Holen|Einige Indexdateien konnten nicht heruntergeladen werden"; then
        echo "🔴 Fehler beim Aktualisieren der Paketlisten in Container $id ($hostname)!" | tee -a "$LXC_LOGFILE"
        echo "$update_output" | grep -E "GPG-Fehler|Fehlschlag beim Holen|Einige Indexdateien konnten nicht heruntergeladen werden" >> "$LXC_LOGFILE"
        update_failed=1
        continue
      fi
      upgradable=$(lxc-attach -n $id -- apt list --upgradable 2>/dev/null | grep -c "upgradable")
      if [ "$upgradable" -eq 0 ]; then
        echo "🟢 Keine neuen Updates für Container $id ($hostname) verfügbar." | tee -a "$LXC_LOGFILE"
        continue
      fi
      if lxc-attach -n $id -- env DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y > /dev/null; then
        echo "Container $id ($hostname) wurde erfolgreich aktualisiert." | tee -a "$LXC_LOGFILE"
      else
        echo "🔴 Fehler beim Update von Container $id ($hostname)." | tee -a "$LXC_LOGFILE"
        update_failed=1
      fi
      if lxc-attach -n $id -- test -f /var/run/reboot-required; then
        echo "Neustart von Container $id ($hostname) erforderlich." | tee -a "$LXC_LOGFILE"
        reboot_required=1
      else
        echo "Kein Neustart von Container $id ($hostname) erforderlich." | tee -a "$LXC_LOGFILE"
      fi
    done
    if [ "$update_failed" -eq 1 ]; then
      echo "⚠️ Bei mindestens einem Container sind Fehler aufgetreten!" | tee -a "$LXC_LOGFILE"
    fi
    if [ "$reboot_required" -eq 1 ]; then
      echo "⚠️ Mindestens ein Container benötigt einen Neustart." | tee -a "$LXC_LOGFILE"
    fi
  fi

  echo "--- Proxmox Host Update Log - $(date) ---" > "$LOGFILE"
  update_output=$(apt-get update 2>&1)
  if echo "$update_output" | grep -qE "GPG-Fehler|Fehlschlag beim Holen|Einige Indexdateien konnten nicht heruntergeladen werden"; then
    echo "🟡 Fehler beim Aktualisieren der Paketlisten auf dem PVE-Host!" | tee -a "$LOGFILE"
    echo "$update_output" | grep -E "GPG-Fehler|Fehlschlag beim Holen|Einige Indexdateien konnten nicht heruntergeladen werden" >> "$LOGFILE"
    exit 2
  fi

  UPGRADE_COUNT=$(apt list --upgradable 2>/dev/null | grep -c "upgradable")
  if [[ "$UPGRADE_COUNT" -eq 0 ]]; then
    echo "🟢 Keine neuen Updates für den Proxmox-Host verfügbar." | tee -a "$LOGFILE"
  else
    declare -A SNAPSHOT_NAMES
    for dataset in "${ZFS_DATASETS[@]}"; do
      SNAPSHOT_NAMES[$dataset]="${dataset}@${SNAPSHOT_TAG}-$TIMESTAMP"
    done
    for dataset in "${ZFS_DATASETS[@]}"; do
      SNAPSHOTS_TO_DELETE=$(zfs list -t snapshot -o name | grep "${dataset}@${SNAPSHOT_TAG}-" | head -n -$MAX_SNAPSHOTS)
      if [[ -n "$SNAPSHOTS_TO_DELETE" ]]; then
        echo "$SNAPSHOTS_TO_DELETE" | xargs -n1 zfs destroy -r
      fi
    done
    echo "📸 Erstelle folgende ZFS-Snapshots:"
    for dataset in "${ZFS_DATASETS[@]}"; do
      snapshot_name="${SNAPSHOT_NAMES[$dataset]}"
      zfs snapshot "$snapshot_name"
      echo "   📌 $snapshot_name"
    done
    echo ""
    if ! apt-get dist-upgrade -y 2>&1; then
      echo "🔴 Fehler beim Installieren der Updates!" | tee -a "$LOGFILE"
      exit 2
    fi
    KERNEL_UPDATE=$(dpkg-query -W -f='${binary:Package}
' linux-image-* | grep -v "$(uname -r)" | wc -l)
    if [[ "$KERNEL_UPDATE" -gt 0 ]]; then
      echo "⚠️ Ein neuer Kernel wurde installiert! Ein Neustart wird zeitnah empfohlen." | tee -a "$LOGFILE"
      echo "📂 Logs gespeichert unter:"
      echo "   📄 LXC-Update-Log: /var/log/lxc_update.log"
      echo "   📄 Proxmox-Update-Log: /var/log/proxmox_update.log"
      if [[ "$REBOOT" == "YES" ]]; then
        echo "🔄 Neustart wird nun automatisch durchgeführt, da REBOOT=YES gesetzt ist." | tee -a "$LOGFILE"
        sleep 5
        pvesh create /nodes/$(hostname)/status --command reboot
      else
        echo "ℹ️ Automatischer Neustart deaktiviert. Setze REBOOT=YES um automatisch neu zu starten." | tee -a "$LOGFILE"
      fi
      exit 1
    fi
    echo "✅ Alle Updates wurden erfolgreich installiert. Kein Neustart erforderlich." | tee -a "$LOGFILE"
    if [[ "$AUTOREMOVE" == "YES" ]]; then
      echo "🧹 Führe apt autoremove aus..." | tee -a "$LOGFILE"
      apt-get autoremove -y | tee -a "$LOGFILE"
    fi
  fi
  echo "📂 Logs gespeichert unter:"
  echo "   📄 LXC-Update-Log: /var/log/lxc_update.log"
  echo "   📄 Proxmox-Update-Log: /var/log/proxmox_update.log"
  exit 0
}

# ======================================
# UCS Update (offiziell via univention-upgrade)
# ======================================
run_ucs_update() {
  LOGFILE="/var/log/ucs_update.log"
  echo "--- Univention Update Log - $(date) ---" > "$LOGFILE"

  # UCS-Upgrade ausführen (ohne App-Updates)
  upgrade_output=$(univention-upgrade --noninteractive --disable-app-updates 2>&1)
  echo "$upgrade_output" | tee -a "$LOGFILE"

  # Fehlerprüfung
  if echo "$upgrade_output" | grep -qE "FAILED|ERR|GPG error|Fehlschlag|nicht aufgelöst"; then
    echo "🔴 Fehler beim Univention Upgrade!" | tee -a "$LOGFILE"
    exit 2
  fi

  # Reboot-Erkennung
  if [[ -f /var/run/reboot-required ]]; then
    echo "⚠️ Neustart empfohlen." | tee -a "$LOGFILE"
    if [[ "$REBOOT" == "YES" ]]; then
      echo "🔄 Automatischer Neustart..." | tee -a "$LOGFILE"
      reboot
    fi
    exit 1
  fi

  # Optional: Autoremove
  if [[ "$AUTOREMOVE" == "YES" ]]; then
    echo "🧹 Führe apt autoremove aus..." | tee -a "$LOGFILE"
    apt-get autoremove -y | tee -a "$LOGFILE"
  fi

  echo "✅ UCS erfolgreich aktualisiert." | tee -a "$LOGFILE"
  exit 0
}

# ======================================
# Debian/Ubuntu Update
# ======================================
run_debian_like_update() {
  if [[ "$system_type" == "ubuntu" ]]; then
    LOGFILE="/var/log/ubuntu_update.log"
  else
    LOGFILE="/var/log/debian_update.log"
  fi
  echo "--- Debian/Ubuntu Update Log - $(date) ---" > "$LOGFILE"
  update_output=$(apt-get update 2>&1)
  echo "$update_output" | tee -a "$LOGFILE"
  if echo "$update_output" | grep -qE "GPG-Fehler|Fehlschlag beim Holen"; then
    echo "🔴 Fehler bei apt update!" | tee -a "$LOGFILE"
    exit 2
  fi
  upgrade_output=$(apt-get dist-upgrade -y 2>&1)
  echo "$upgrade_output" | tee -a "$LOGFILE"
  if echo "$upgrade_output" | grep -qE "GPG-Fehler|Fehlschlag beim Holen"; then
    echo "🔴 Fehler bei apt upgrade!" | tee -a "$LOGFILE"
    exit 2
  fi
  if [[ -f /var/run/reboot-required ]]; then
    echo "⚠️ Neustart empfohlen." | tee -a "$LOGFILE"
    [[ "$REBOOT" == "YES" ]] && echo "🔄 Automatischer Neustart..." | tee -a "$LOGFILE" && reboot
    exit 1
  fi
  if [[ "$AUTOREMOVE" == "YES" ]]; then
    echo "🧹 Führe apt autoremove aus..." | tee -a "$LOGFILE"
    apt-get autoremove -y | tee -a "$LOGFILE"
  fi
  echo "✅ System erfolgreich aktualisiert." | tee -a "$LOGFILE"
  exit 0
}

# ======================================
# HAUPTLOGIK
# ======================================

LOCKFILE="/var/run/universal_update.lock"
if [[ -e "$LOCKFILE" ]]; then
  echo "⚠️ Update läuft bereits (Lockfile: $LOCKFILE). Abbruch."
  exit 100
fi
trap "rm -f $LOCKFILE" EXIT
touch "$LOCKFILE"

system_type=$(detect_system_type)

summary_result() {
  local exit_code=$1
  case "$system_type" in
    pve) log_path="/var/log/proxmox_update.log" ;;
    ucs) log_path="/var/log/ucs_update.log" ;;
    debian) log_path="/var/log/debian_update.log" ;;
    ubuntu) log_path="/var/log/ubuntu_update.log" ;;
    *) log_path="/dev/null" ;;
  esac
  case "$exit_code" in
    0) status="OK" ;;
    1) status="REBOOT_REQUIRED" ;;
    2) status="ERROR" ;;
    3) status="UNSUPPORTED_SYSTEM" ;;
    100) status="LOCK_EXISTS" ;;
    *) status="UNKNOWN" ;;
  esac
  echo "📋 Zusammenfassung: Systemtyp=$system_type | Status=$status | Log=$log_path"
}

case "$system_type" in
  pve)
    run_pve_update; result=$? ;;
  ucs)
    run_ucs_update; result=$? ;;
  debian|ubuntu)
    run_debian_like_update; result=$? ;;
  *)
    echo "❌ Unbekanntes System. Kein Update möglich."; result=3 ;;
esac

find /var/log -type f -name '*_update.log' -mtime +14 -exec rm -f {} \;
summary_result $result
exit $result

