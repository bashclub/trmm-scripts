#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# /opt/wazuh/wazuh_ollama.sh "Frage an Ollama"
#
# Ablauf:
#  0) Query-JSON mit ABSOLUTEN UTC-Zeitstempeln (letzte N Tage) erzeugen
#  1) Wazuh Indexer abfragen (curl) -> Raw JSON Datei
#  2) Lokal reduzieren + nach Host+Problem gruppieren -> Grouped JSON Datei
#     (inkl. rule.info/rationale + full_log + EventChannel + Windows-Message Hinweise)
#  3) Für jedes Host+Problem eine 1-Satz-Empfehlung via Ollama -> HTML Report (Deutsch)
#     + CVE/HTTP Links klickbar machen
#  4) Report per SMTP-Relay via msmtp als HTML-Mail senden
#  5) Im Report: Modell erwähnen + Laufzeit am Ende
#
# Nutzung:
#   export WAZUH_INDEXER_PASS='...'
#   /opt/wazuh/wazuh_ollama.sh "Was läuft schief? Bitte nach System und Problem gruppieren."
#
# Optional:
#   export WAZUH_DAYS=3                 # default 1 (letzte 3 Tage)
#   export WAZUH_LEVEL_GTE=7            # default 7
#   export WAZUH_SIZE=500               # default 500
#   export WAZUH_AGENT_GROUP=SoGo       # optionaler Filter auf agent.labels.agent.group
#   export WAZUH_OLLAMA_URL=http://192.168.50.52:11434
#   export WAZUH_OLLAMA_MODEL=Qwen2.5:latest
#   export WAZUH_OLLAMA_THREADS=16
#   export WAZUH_OLLAMA_CTX=1024
#   export WAZUH_OLLAMA_PREDICT=120
#
# Mail:
#   SMTP Relay: 192.168.51.214:26 (ohne Auth)
#   From: wazuh@sysops.de
#   To:   support@sysops.de
# ============================================================

SCRIPT_START_EPOCH="$(date +%s)"

QUESTION="${1:-Welche Systeme haben aktuell welche Probleme und einen kurzen Lösungsvorschlag?}"

# ---- Zeitraum (Tage) ----
DAYS="${WAZUH_DAYS:-1}"
NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")"
FROM_UTC="$(date -u -d "${DAYS} days ago" +"%Y-%m-%dT%H:%M:%S.%3NZ")"

# ---- Indexer-Config ----
INDEXER="https://127.0.0.1:9200"
INDEX_PATTERN="wazuh-alerts-*"
AUTH_USER="admin"
AUTH_PASS="${WAZUH_INDEXER_PASS:-}"
CA="/etc/wazuh-indexer/certs/root-ca.pem"

RULE_LEVEL_GTE="${WAZUH_LEVEL_GTE:-7}"
SIZE="${WAZUH_SIZE:-500}"
AGENT_GROUP="${WAZUH_AGENT_GROUP:-}"

if [[ -z "$AUTH_PASS" ]]; then
  echo "[!] Fehlende Umgebungsvariable: WAZUH_INDEXER_PASS" >&2
  echo "    Beispiel: export WAZUH_INDEXER_PASS='dein_passwort'" >&2
  exit 1
fi

# ---- Ollama-Config ----
OLLAMA="${WAZUH_OLLAMA_URL:-http://127.0.0.1:11434}"
MODEL="${WAZUH_OLLAMA_MODEL:-gpt-oss}"
NUM_THREAD="${WAZUH_OLLAMA_THREADS:-16}"
NUM_CTX="${WAZUH_OLLAMA_CTX:-1024}"
NUM_PREDICT="${WAZUH_OLLAMA_PREDICT:-120}"

# ---- Mail-Config (msmtp) ----
MAIL_TO="${WAZUH_MAIL_TO:-support@sysops.de}"
MAIL_FROM="${WAZUH_MAIL_FROM:-wazuh@sysops.de}"
MAIL_SMTP_HOST="${WAZUH_MAIL_SMTP_HOST:-192.168.51.214}"
MAIL_SMTP_PORT="${WAZUH_MAIL_SMTP_PORT:-26}"
MAIL_MAILDOMAIN="${WAZUH_MAIL_MAILDOMAIN:-sysops.de}"

# ---- Output-Dateien ----
OUT_DIR="/var/log/wazuh/ollama"
mkdir -p "$OUT_DIR"
TS="$(date -u +%Y%m%d_%H%M%S)"

RAW_FILE="$OUT_DIR/wazuh_search_${TS}.json"
RAW_LATEST="$OUT_DIR/wazuh_search_latest.json"
GROUPED_FILE="$OUT_DIR/wazuh_grouped_${TS}.json"
GROUPED_LATEST="$OUT_DIR/wazuh_grouped_latest.json"
REPORT_HTML="$OUT_DIR/wazuh_report_${TS}.html"
REPORT_HTML_LATEST="$OUT_DIR/wazuh_report_latest.html"
QUERY_FILE="$OUT_DIR/wazuh_query_${TS}.json"
QUERY_LATEST="$OUT_DIR/wazuh_query_latest.json"

TMP_REQ="$(mktemp)"
TMP_RESP="$(mktemp)"
trap 'rm -f "$TMP_REQ" "$TMP_RESP"' EXIT

# ---- Terminal-Header ----
echo "=================================================="
echo "Wazuh → Ollama Sicherheitsanalyse"
echo "Zeitraum (UTC): $FROM_UTC  bis  $NOW_UTC  (${DAYS} Tag(e))"
echo "Fragestellung: $QUESTION"
echo "Ollama: $OLLAMA  Modell: $MODEL"
if [[ -n "$AGENT_GROUP" ]]; then
  echo "Agent-Gruppe Filter: $AGENT_GROUP"
else
  echo "Agent-Gruppe Filter: keiner"
fi
echo "=================================================="

# -----------------------------
# Helper: HTML escapen + Links
# -----------------------------
html_escape() {
  sed -e 's/&/\&amp;/g' \
      -e 's/</\&lt;/g' \
      -e 's/>/\&gt;/g' \
      -e 's/"/\&quot;/g' \
      -e "s/'/\&#39;/g"
}

linkify_urls_and_cves() {
  # erwartet bereits HTML-escaped Text
  perl -0777 -pe '
    s{(https?://[^\s<>"'\''\)]+)}{<a href="$1" target="_blank" rel="noreferrer">$1</a>}gi;
    s{\b(CVE-\d{4}-\d{4,7})\b}{<a href="https://cve.mitre.org/cgi-bin/cvename.cgi?name=$1" target="_blank" rel="noreferrer">$1</a>}gi;
  '
}

fmt_duration() {
  local seconds="$1"
  local h=$((seconds/3600))
  local m=$(((seconds%3600)/60))
  local s=$((seconds%60))
  if (( h > 0 )); then
    printf "%dh %dm %ds" "$h" "$m" "$s"
  elif (( m > 0 )); then
    printf "%dm %ds" "$m" "$s"
  else
    printf "%ds" "$s"
  fi
}

# -----------------------------
# Schritt 0: Query JSON erzeugen (ABSOLUTE Timestamps)
# -----------------------------
if [[ -n "$AGENT_GROUP" ]]; then
  GROUP_FILTER="$(jq -nc --arg g "$AGENT_GROUP" '{"match_phrase":{"agent.labels.agent.group":{"query":$g}}}')"
else
  GROUP_FILTER=""
fi

cat > "$QUERY_FILE" <<JSON
{
  "sort":[{"timestamp":{"order":"desc","unmapped_type":"boolean"}}],
  "size": $SIZE,
  "_source": { "excludes": ["@timestamp"] },
  "query":{
    "bool":{
      "filter":[
        {"match_all":{}},
        {"match_phrase":{"manager.name":{"query":"wazuh"}}}$( [[ -n "$GROUP_FILTER" ]] && printf ',\n        %s' "$GROUP_FILTER" ),
        {"range":{"rule.level":{"gte": $RULE_LEVEL_GTE}}},
        {"range":{"timestamp":{"gte":"$FROM_UTC","lte":"$NOW_UTC","format":"strict_date_optional_time"}}}
      ]
    }
  }
}
JSON
cp -f "$QUERY_FILE" "$QUERY_LATEST"

# -----------------------------
# Schritt 1: Wazuh Indexer abfragen
# -----------------------------
echo "[1/4] Wazuh Indexer abfragen..." >&2
curl -sS -X POST "$INDEXER/$INDEX_PATTERN/_search" \
  -u "$AUTH_USER:$AUTH_PASS" \
  --cacert "$CA" \
  -H "Content-Type: application/json" \
  -d @"$QUERY_FILE" > "$RAW_FILE"

cp -f "$RAW_FILE" "$RAW_LATEST"
echo "[1/4] Raw JSON gespeichert: $RAW_FILE (latest: $RAW_LATEST)" >&2

if ! jq -e . >/dev/null 2>&1 < "$RAW_FILE"; then
  echo "[!] Antwort des Indexers ist KEIN gültiges JSON. Erste 60 Zeilen:" >&2
  sed -n '1,60p' "$RAW_FILE" >&2
  exit 2
fi

TOTAL="$(jq -r '.hits.total.value // 0' "$RAW_FILE")"
echo "[1/4] Treffer: $TOTAL" >&2

# Falls keine Treffer -> leere HTML + keine Mail
if [[ "$TOTAL" -eq 0 ]]; then
  {
    cat <<'HTML'
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Wazuh / Ollama Sicherheitsbericht</title>
</head>
<body style="font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif; line-height:1.4;">
HTML
    echo "<h2>Wazuh / Ollama Sicherheitsbericht</h2>"
    echo "<p><b>Zeitraum (UTC):</b> $(printf "%s" "$FROM_UTC" | html_escape) .. $(printf "%s" "$NOW_UTC" | html_escape)</p>"
    echo "<p><b>Fragestellung:</b> $(printf "%s" "$QUESTION" | html_escape)</p>"
    echo "<p><b>LLM-Modell:</b> $(printf "%s" "$MODEL" | html_escape)</p>"
    if [[ -n "$AGENT_GROUP" ]]; then
      echo "<p><b>Agent-Gruppe:</b> $(printf "%s" "$AGENT_GROUP" | html_escape)</p>"
    fi
    echo "<p><i>Keine Treffer im Zeitraum.</i></p>"
    echo "</body></html>"
  } > "$REPORT_HTML"

  cp -f "$REPORT_HTML" "$REPORT_HTML_LATEST"
  echo "[*] HTML Report: $REPORT_HTML (latest: $REPORT_HTML_LATEST)" >&2
  cat "$REPORT_HTML"
  exit 0
fi

# -----------------------------
# Schritt 2: Lokal reduzieren + gruppieren (Host + Problem + Rule)
#   + Kontext: rule.info/rationale + full_log + location + EventChannel + Windows-Message
# -----------------------------
echo "[2/4] Reduzieren + gruppieren..." >&2

jq -c '
  def host: (.agent.name // .agent.id // "unknown");
  def ip: (.agent.ip // "");
  def ts: (.timestamp // .["@timestamp"] // "");

  def problem_title:
    ((.rule.description // .rule.comment // "unknown")
     | tostring | gsub("[\r\n\t]"; " ") | gsub(" +"; " ") | .[0:220]);

  def info:
    ((.rule.info // .rule.rationale // "") | tostring | gsub("[\r\n\t]"; " ") | gsub(" +"; " ") | .[0:260]);

  def loc:
    ((.location // "") | tostring | gsub("[\r\n\t]"; " ") | gsub(" +"; " ") | .[0:180]);

  def full:
    ((.full_log // "") | tostring | .[0:600]);

  def eventchannel:
    ((.data.win.eventdata.channel // .win.system.channel // .event.channel // "") | tostring | gsub("[\r\n\t]"; " ") | gsub(" +"; " ") | .[0:120]);

  def win_message:
    ((.data.win.system.message // "") | tostring | gsub("[\r\n\t]"; " ") | gsub(" +"; " ") | .[0:600]);

  def tips:
    (
      (if (info != "") then ("Info: " + info) else "" end)
      + (if (loc != "") then (if (info != "") then " | " else "" end) + ("Log: " + loc) else "" end)
      + (if (eventchannel != "") then ((if (info != "" or loc != "") then " | " else "" end) + ("EventChannel: " + eventchannel)) else "" end)
      + (if (win_message != "") then "\nWindows-Message: " + win_message else "" end)
      + (if (full != "") then "\nBeispiel: " + (full | gsub("\r\n|\n|\r"; " ")) else "" end)
    );

  [ .hits.hits[]._source
    | {
        host: host,
        ip: ip,
        rule_id: (.rule.id // "unknown"),
        problem: problem_title,
        tips: tips,
        level: (.rule.level // 0),
        ts: ts
      }
  ]
  | sort_by(.host, .problem, .rule_id, .ts)
  | group_by(.host + "|" + .problem + "|" + .rule_id)
  | map({
      host: .[0].host,
      ip:   (map(.ip) | map(select(. != "")) | unique | join(", ")),
      rule_id: .[0].rule_id,
      problem: .[0].problem,
      tips:    (map(.tips) | map(select(. != "")) | unique | join("\n---\n") | .[0:2500]),
      level_max: (map(.level) | max),
      count: length,
      last_seen: (map(.ts) | map(select(. != "")) | max // "")
    })
  | sort_by(.host, -.level_max, -.count, .problem)
' "$RAW_FILE" > "$GROUPED_FILE"

cp -f "$GROUPED_FILE" "$GROUPED_LATEST"
ISSUES="$(jq -r 'length' "$GROUPED_FILE")"
echo "[2/4] Gruppierte Probleme: $ISSUES" >&2

# -----------------------------
# Schritt 3: Ollama pro Host+Problem -> Empfehlung (1 Satz, Deutsch)
# -----------------------------
echo "[3/4] Ollama abfragen..." >&2

{
  cat <<'HTML'
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Wazuh / Ollama Sicherheitsbericht</title>
</head>
<body style="font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif; line-height:1.4; color:#111;">
<div style="max-width:980px;margin:0 auto;padding:16px 12px;">
HTML
  echo "<h2 style=\"margin:0 0 8px 0;\">Wazuh / Ollama Sicherheitsbericht</h2>"
  echo "<p style=\"margin:0 0 6px 0;\"><b>Zeitraum (UTC):</b> $(printf "%s" "$FROM_UTC" | html_escape) .. $(printf "%s" "$NOW_UTC" | html_escape) <span style=\"color:#666;\">(${DAYS} Tag(e))</span></p>"
  echo "<p style=\"margin:0 0 6px 0;\"><b>Fragestellung:</b> $(printf "%s" "$QUESTION" | html_escape)</p>"
  echo "<p style=\"margin:0 0 6px 0;\"><b>LLM-Modell:</b> $(printf "%s" "$MODEL" | html_escape) <span style=\"color:#666;\">(via $(printf "%s" "$OLLAMA" | html_escape))</span></p>"
  if [[ -n "$AGENT_GROUP" ]]; then
    echo "<p style=\"margin:0 0 12px 0;\"><b>Agent-Gruppe:</b> $(printf "%s" "$AGENT_GROUP" | html_escape)</p>"
  fi
  echo "<hr style=\"border:none;border-top:1px solid #ddd;margin:14px 0;\">"
} > "$REPORT_HTML"

ollama_one_sentence() {
  local host="$1"
  local problem="$2"
  local tips="$3"

  jq -n \
    --arg model "$MODEL" \
    --arg host "$host" \
    --arg problem "$problem" \
    --arg tips "$tips" \
    --argjson nt "$NUM_THREAD" \
    --argjson nc "$NUM_CTX" \
    --argjson np "$NUM_PREDICT" \
    '{
      model: $model,
      stream: false,
      keep_alive: -1,
      options: { num_thread: $nt, num_ctx: $nc, num_predict: $np },
      messages: [
        { role: "system", content: "Du bist ein deutschsprachiger IT-Sicherheitsanalyst. Antworte ausschließlich auf Deutsch. Genau ein kurzer, klarer Satz. Keine Aufzählungen. Keine Erklärungen." },
        { role: "user", content:
          ("System: " + $host + "\n"
           + "Problem: " + $problem + "\n"
           + (if ($tips|length)>0 then ("Hinweise/Beispiel:\n" + $tips + "\n") else "" end)
           + "\nGib eine kurze, praktische 1-Satz-Handlungsempfehlung.") }
      ]
    }' > "$TMP_REQ"

  curl -sS "$OLLAMA/api/chat" \
    -H "Content-Type: application/json" \
    -d @"$TMP_REQ" > "$TMP_RESP"

  local ans
  ans="$(jq -r '.message.content // empty' "$TMP_RESP" 2>/dev/null || true)"
  if [[ -z "$ans" ]]; then
    ans="$(jq -r '.message.thinking // empty' "$TMP_RESP" 2>/dev/null || true)"
  fi

  printf "%s\n" "$ans" \
    | sed -E '
        /^[[:space:]]*$/d;
        /^We need/d; /^The user/d; /^Need /d; /^I will/d; /^We must/d;
        /^From the hits/d; /^Search in hits/d; /^Thus /d;
        /^But requirement:/,$d;
      ' \
    | sed -E 's/[[:space:]]+$//' \
    | awk 'NF{print; exit}'
}

CURRENT_HOST=""
while IFS= read -r item; do
  host="$(jq -r '.host' <<<"$item")"
  ip="$(jq -r '.ip' <<<"$item")"
  rid="$(jq -r '.rule_id' <<<"$item")"
  prob="$(jq -r '.problem' <<<"$item")"
  tips="$(jq -r '.tips' <<<"$item")"
  lvl="$(jq -r '.level_max' <<<"$item")"
  cnt="$(jq -r '.count' <<<"$item")"
  last="$(jq -r '.last_seen' <<<"$item")"

  rec="$(ollama_one_sentence "$host" "$prob" "$tips")"
  [[ -z "$rec" ]] && rec="(keine Empfehlung erhalten – bitte erneut ausführen)"

  host_h="$(printf "%s" "$host" | html_escape)"
  ip_h="$(printf "%s" "$ip" | html_escape)"
  rid_h="$(printf "%s" "$rid" | html_escape)"
  meta_h="$(printf "%s" "Level $lvl, Anzahl $cnt, Letztes Auftreten $last" | html_escape)"

  prob_h="$(printf "%s" "$prob" | html_escape | linkify_urls_and_cves)"
  rec_h="$(printf "%s" "$rec" | html_escape | linkify_urls_and_cves)"

  tips_esc="$(printf "%s" "$tips" | html_escape)"
  tips_h="$(printf "%s" "$tips_esc" | linkify_urls_and_cves)"
  tips_h="$(printf "%s" "$tips_h" | sed -e 's/\n/<br>/g')"

  if [[ "$host" != "$CURRENT_HOST" ]]; then
    echo "<h3 style=\"margin:18px 0 8px 0;\">$host_h</h3>" >> "$REPORT_HTML"
    CURRENT_HOST="$host"
  fi

  {
    echo "<div style=\"border:1px solid #e3e3e3;border-radius:10px;padding:10px 12px;margin:10px 0;background:#fff;\">"
    echo "  <div style=\"margin:0 0 6px 0;\"><b>Problem:</b> $prob_h</div>"
    echo "  <div style=\"margin:0 0 6px 0;\"><b>Empfehlung:</b> $rec_h</div>"
    echo "  <div style=\"color:#444;margin:0 0 6px 0;\"><b>Details:</b> $meta_h &nbsp;|&nbsp; <b>Regel:</b> $rid_h &nbsp;|&nbsp; <b>IP:</b> $ip_h</div>"
    if [[ -n "$tips_esc" ]]; then
      echo "  <details style=\"margin-top:6px;\">"
      echo "    <summary style=\"cursor:pointer;color:#0b57d0;\">Hinweise / Beispiel-Log (aus full_log / rationale / info / EventChannel / Windows-Message)</summary>"
      echo "    <div style=\"margin-top:6px;color:#333;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;white-space:normal;\">$tips_h</div>"
      echo "  </details>"
    fi
    echo "</div>"
  } >> "$REPORT_HTML"
done < <(jq -c '.[]' "$GROUPED_FILE")

SCRIPT_END_EPOCH="$(date +%s)"
DUR_SEC="$((SCRIPT_END_EPOCH - SCRIPT_START_EPOCH))"
DUR_FMT="$(fmt_duration "$DUR_SEC")"
{
  echo "<hr style=\"border:none;border-top:1px solid #ddd;margin:18px 0;\">"
  echo "<p style=\"color:#666;margin:0;\"><b>Laufzeit:</b> $(printf "%s" "$DUR_FMT" | html_escape)</p>"
  echo "</div></body></html>"
} >> "$REPORT_HTML"

cp -f "$REPORT_HTML" "$REPORT_HTML_LATEST"

# -----------------------------
# Schritt 4: Report per SMTP-Relay via msmtp senden (HTML)
# -----------------------------
echo "[4/4] Report per E-Mail versenden..." >&2

MAIL_SUBJECT="Wazuh Sicherheitsbericht $(date -u '+%Y-%m-%d %H:%M UTC')"

if [[ "$ISSUES" -gt 0 ]]; then
  if command -v msmtp >/dev/null 2>&1; then
    {
      echo "From: $MAIL_FROM"
      echo "To: $MAIL_TO"
      echo "Subject: $MAIL_SUBJECT"
      echo "MIME-Version: 1.0"
      echo "Content-Type: text/html; charset=UTF-8"
      echo "Content-Transfer-Encoding: 8bit"
      echo
      cat "$REPORT_HTML"
    } | msmtp --host="$MAIL_SMTP_HOST" --port="$MAIL_SMTP_PORT" --from="$MAIL_FROM" --maildomain="$MAIL_MAILDOMAIN" -t

    echo "[4/4] E-Mail gesendet an $MAIL_TO via ${MAIL_SMTP_HOST}:${MAIL_SMTP_PORT}." >&2
  else
    echo "[!] 'msmtp' nicht gefunden. Installiere: apt install -y msmtp" >&2
  fi
else
  echo "[4/4] Keine Probleme -> keine E-Mail gesendet." >&2
fi

echo "[*] Query:   $QUERY_FILE (latest: $QUERY_LATEST)" >&2
echo "[*] Raw:     $RAW_FILE (latest: $RAW_LATEST)" >&2
echo "[*] Grouped: $GROUPED_FILE (latest: $GROUPED_LATEST)" >&2
echo "[*] Report:  $REPORT_HTML (latest: $REPORT_HTML_LATEST)" >&2

cat "$REPORT_HTML"
