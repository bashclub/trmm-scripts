#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C

WARN="${WARN:-85}"
CRIT="${CRIT:-95}"

status=0
alerts=()

# Bytes -> IEC (KiB/MiB/GiB/TiB/PiB) mit 1 Nachkommastelle
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

echo "==================== ZFS POOLS (zpool list) ===================="
printf "%-18s %14s %14s %14s %7s %10s\n" "POOL" "ALLOC" "FREE" "SIZE" "CAP" "HEALTH"

while read -r pool alloc free size cap health; do
  cap_num="${cap%%%}"   # "42%" -> "42"

  printf "%-18s %14s %14s %14s %6s%% %10s\n" \
    "$pool" "$(to_iec "$alloc")" "$(to_iec "$free")" "$(to_iec "$size")" "$cap_num" "$health"

  # Health kritisch
  if [[ "$health" != "ONLINE" ]]; then
    alerts+=("CRITICAL: ZPOOL '$pool' HEALTH=$health")
    status=2
    continue
  fi

  if [[ "$cap_num" =~ ^[0-9]+$ ]]; then
    if (( cap_num >= CRIT )); then
      alerts+=("CRITICAL: ZPOOL '$pool' ${cap_num}% belegt")
      status=2
    elif (( cap_num >= WARN )) && (( status < 1 )); then
      alerts+=("WARNING: ZPOOL '$pool' ${cap_num}% belegt")
      status=1
    fi
  fi
done < <(zpool list -H -p -o name,alloc,free,size,capacity,health)

echo
echo "==================== PVE STORAGE (wie GUI) ======================"
if ! command -v pvesm >/dev/null 2>&1; then
  echo "HINWEIS: 'pvesm' nicht gefunden. Überspringe PVE Storage Teil."
else
  printf "%-18s %-10s %14s %14s %14s %8s\n" "STORAGE" "TYPE" "TOTAL" "USED" "AVAIL" "USE%"

  while read -r s_name s_type s_total s_used s_avail s_pct; do

    # Wenn Proxmox Bytes liefert (wie bei dir), rechnen wir sauber nach IEC um.
    if [[ "$s_total" =~ ^[0-9]+$ ]] && [[ "$s_used" =~ ^[0-9]+$ ]] && [[ "$s_avail" =~ ^[0-9]+$ ]]; then
      total_h="$(to_iec "$s_total")"
      used_h="$(to_iec "$s_used")"
      avail_h="$(to_iec "$s_avail")"
    else
      # Fallback: falls Proxmox human-readable liefert (z.B. "1.85T"), unverändert anzeigen
      total_h="$s_total"
      used_h="$s_used"
      avail_h="$s_avail"
    fi

    printf "%-18s %-10s %14s %14s %14s %7s%%\n" \
      "$s_name" "$s_type" "$total_h" "$used_h" "$avail_h" "$s_pct"

    # Prozent kann Dezimal sein (z.B. 2.50). Für Schwellenwertvergleich:
    pct_int="${s_pct%.*}"
    [[ -z "$pct_int" ]] && pct_int="$s_pct"

    if [[ "$pct_int" =~ ^[0-9]+$ ]]; then
      if (( pct_int >= CRIT )); then
        alerts+=("CRITICAL: PVE Storage '$s_name' (${s_type}) ${s_pct}% belegt")
        status=2
      elif (( pct_int >= WARN )) && (( status < 1 )); then
        alerts+=("WARNING: PVE Storage '$s_name' (${s_type}) ${s_pct}% belegt")
        status=1
      fi
    fi

  done < <(
    pvesm status 2>/dev/null \
    | awk '
        NR==1 { next }                 # header skip
        $3!="active" { next }          # nur aktive Storages
        ($2=="zfspool" || $2=="zfs") {
          gsub(/%/,"",$7);
          print $1, $2, $4, $5, $6, $7
        }
      '
  )
fi

echo "-----------------------------------------------------------------"

if (( status == 0 )); then
  echo "OK: Alle ZFS-Pools und PVE-ZFS-Storages sind unter ${WARN}% und ONLINE/active."
else
  printf '%s\n' "${alerts[@]}"
fi

exit "$status"
