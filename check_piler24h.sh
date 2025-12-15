#!/bin/bash
#
# Mailpiler Simple Check für Tactical RMM
# Einfache Text-Ausgabe für Script Checks
#
# Exit Codes: 0 = OK, 1 = Warning, 2 = Error
#

MAILPILER_CONFIG="/etc/piler/piler.conf"
CHECK_PERIOD_HOURS=24

# MySQL-Credentials laden
if [ -f "$MAILPILER_CONFIG" ]; then
    DB_NAME=$(grep -E "^mysqldb=" "$MAILPILER_CONFIG" | cut -d'=' -f2 | tr -d ' ')
    DB_USER=$(grep -E "^mysqluser=" "$MAILPILER_CONFIG" | cut -d'=' -f2 | tr -d ' ')
    DB_PASS=$(grep -E "^mysqlpwd=" "$MAILPILER_CONFIG" | cut -d'=' -f2 | tr -d ' ')
    DB_SOCKET=$(grep -E "^mysqlsocket=" "$MAILPILER_CONFIG" | cut -d'=' -f2 | tr -d ' ')
    DB_HOST=$(grep -E "^mysqlhost=" "$MAILPILER_CONFIG" | cut -d'=' -f2 | tr -d ' ')

    DB_HOST=${DB_HOST:-localhost}

    MYSQL_CONN="-u${DB_USER}"
    [ -n "$DB_PASS" ] && MYSQL_CONN="$MYSQL_CONN -p${DB_PASS}"
    [ -n "$DB_SOCKET" ] && MYSQL_CONN="$MYSQL_CONN -S${DB_SOCKET}" || MYSQL_CONN="$MYSQL_CONN -h${DB_HOST}"
else
    echo "ERROR: Config nicht gefunden"
    exit 2
fi

EXIT_CODE=0

# Service Check
if ! systemctl is-active --quiet piler 2>/dev/null; then
    echo "ERROR: Piler-Service läuft nicht"
    exit 2
fi

# Datenbank Check
if ! mysql $MYSQL_CONN -e "SELECT 1" "$DB_NAME" &> /dev/null; then
    echo "ERROR: Datenbank-Verbindung fehlgeschlagen"
    exit 2
fi

# Archivierungs-Check
SAMPLE_ARRIVED=$(mysql $MYSQL_CONN -N -e "SELECT arrived FROM metadata LIMIT 1" "$DB_NAME" 2>/dev/null)
if [[ "$SAMPLE_ARRIVED" =~ ^[0-9]{10}$ ]]; then
    RECENT_COUNT=$(mysql $MYSQL_CONN -N -e "SELECT COUNT(*) FROM metadata WHERE arrived > UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL $CHECK_PERIOD_HOURS HOUR))" "$DB_NAME" 2>/dev/null)
else
    RECENT_COUNT=$(mysql $MYSQL_CONN -N -e "SELECT COUNT(*) FROM metadata WHERE arrived > DATE_SUB(NOW(), INTERVAL $CHECK_PERIOD_HOURS HOUR)" "$DB_NAME" 2>/dev/null)
fi

TOTAL_EMAILS=$(mysql $MYSQL_CONN -N -e "SELECT COUNT(*) FROM metadata" "$DB_NAME" 2>/dev/null)

if [ "$RECENT_COUNT" -eq 0 ]; then
    echo "WARNING: Keine E-Mails in letzten ${CHECK_PERIOD_HOURS}h | Gesamt: ${TOTAL_EMAILS}"
    exit 1
fi

echo "OK: ${RECENT_COUNT} E-Mails in letzten ${CHECK_PERIOD_HOURS}h | Gesamt: ${TOTAL_EMAILS}"
exit 0
