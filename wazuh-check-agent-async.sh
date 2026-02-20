#!/usr/bin/env bash
set -euo pipefail

LOG="/var/ossec/logs/ossec.log"
PATTERN="INFO: Evaluation finished."
HOURS=4
GRACE_MINUTES=120
TAIL_LINES=25

ok(){ echo "OK: $*"; show_tail; exit 0; }
crit(){ echo "CRIT: $*"; show_tail; exit 2; }

show_tail() {
    echo "---- Last ${TAIL_LINES} lines of ${LOG} ----"
    if [[ -f "$LOG" ]]; then
        tail -n "$TAIL_LINES" "$LOG"
    else
        echo "Logfile not found"
    fi
}

# --- Uptime prüfen ---
uptime_minutes="$(awk '{print int($1/60)}' /proc/uptime)"

if (( uptime_minutes < GRACE_MINUTES )); then
    ok "System uptime ${uptime_minutes} min (< ${GRACE_MINUTES} min grace period)"
fi

# --- Log vorhanden? ---
if [[ ! -f "$LOG" ]]; then
    crit "Logfile not found: $LOG"
fi

# --- Zeitpunkt vor 4 Stunden ---
since_epoch="$(date -d "$HOURS hours ago" +%s)"

# --- Aktivität prüfen ---
found="$(
tail -n 20000 "$LOG" | awk -v since="$since_epoch" -v pat="$PATTERN" '
{
    ts = substr($0,1,19)
    gsub(/\//,"-",ts)
    cmd = "date -d \"" ts "\" +%s 2>/dev/null"
    cmd | getline epoch
    close(cmd)

    if (epoch >= since && index($0, pat)) {
        print $0
        exit
    }
}'
)"

if [[ -n "$found" ]]; then
    ok "Wazuh agent activity detected within last ${HOURS} hours (uptime ${uptime_minutes} min)"
else
    crit "No Wazuh agent activity in last ${HOURS} hours (uptime ${uptime_minutes} min)"
fi
