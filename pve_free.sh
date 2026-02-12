#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C

WARN="${WARN:-85}"
CRIT="${CRIT:-95}"
ONLY_ZFS="${ONLY_ZFS:-0}"   # optionaler Filter

status=0
alerts=()

to_iec() {
  local b="$1"
  awk -v b="$b" '
    function human(x,   u,i,val) {
      split("B KiB MiB GiB TiB PiB EiB", u, " ");
      i=1; val=x;
      while (val>=1024 && i<7) { val/=1024; i++; }
      if (i==1) printf "%.0f %s", val, u[i];
      else      printf "%.1f %s", val, u[i];
    }
    BEGIN { human(b); }
  '
}

if ! command -v pvesm >/dev/null 2>&1; then
  echo "CRITICAL: 'pvesm' nicht gefunden – Script muss auf einem Proxmox VE Node laufen."
  exit 2
fi

echo "==================== PVE STORAGE (pvesm status) ======================"
printf "%-18s %-10s %-8s %14s %14s %14s %8s\n" "STORAGE" "TYPE" "STATUS" "TOTAL" "USED" "AVAIL" "USE%"

while read -r s_name s_type s_status s_total s_used s_avail s_pct; do

  # Optionaler ZFS-Filter
  if [[ "$ONLY_ZFS" == "1" ]] && [[ "$s_type" != "zfspool" && "$s_type" != "zfs" ]]; then
    continue
  fi

  if [[ "$s_total" =~ ^[0-9]+$ ]] && [[ "$s_used" =~ ^[0-9]+$ ]] && [[ "$s_avail" =~ ^[0-9]+$ ]]; then
    total_h="$(to_iec "$s_total")"
    used_h="$(to_iec "$s_used")"
    avail_h="$(to_iec "$s_avail")"
  else
    total_h="$s_total"
    used_h="$s_used"
    avail_h="$s_avail"
  fi

  printf "%-18s %-10s %-8s %14s %14s %14s %7s%%\n" \
    "$s_name" "$s_type" "$s_status" "$total_h" "$used_h" "$avail_h" "$s_pct"

  [[ "$s_status" != "active" ]] && continue

  pct_int="${s_pct%.*}"
  [[ -z "$pct_int" ]] && pct_int="$s_pct"

  if [[ "$pct_int" =~ ^[0-9]+$ ]]; then
    if (( pct_int >= CRIT )); then
      alerts+=("CRITICAL: Storage '$s_name' (${s_type}) ${s_pct}% belegt")
      status=2
    elif (( pct_int >= WARN )) && (( status < 1 )); then
      alerts+=("WARNING: Storage '$s_name' (${s_type}) ${s_pct}% belegt")
      status=1
    fi
  fi

done < <(
  pvesm status 2>/dev/null | awk '
    NR==1 { next }
    { gsub(/%/,"",$7); print $1, $2, $3, $4, $5, $6, $7 }
  '
)

echo "---------------------------------------------------------------------"

if (( status == 0 )); then
  echo "OK: Alle aktiven PVE Storages sind unter ${WARN}%."
else
  printf '%s\n' "${alerts[@]}"
fi

exit "$status"
