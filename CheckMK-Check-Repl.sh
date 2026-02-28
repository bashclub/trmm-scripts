#!/bin/bash

# Verzeichnis mit den CheckMK-Dateien
directory="/var/lib/check_mk_agent/spool"

# Aktuelle Zeit
current_time=$(date +%s)

# Funktion zur Überprüfung des Status in der Datei
check_status() {
    file_path="$1"
    exit_code=0
    echo "Inhalt der Datei $file_path:"
    echo "--------------------------------"
    while IFS= read -r line; do
        if [[ "$line" == '<<<local>>>'* ]]; then
            continue
        fi
        
        status=$(echo "$line" | awk '{print $1}')
        description=$(echo "$line" | awk '{print $2}')
        message=$(echo "$line" | awk -F'- ' '{print $2}')

        case "$status" in
            0)
                echo "$description - $message"
                ;;
            1)
                echo "$description - kein Replikat gefunden"
                exit_code=1
                ;;
            2)
                echo "$description - $message"
                exit_code=2
                ;;
            *)
                echo "$description - $message"
                exit_code=3
                ;;
        esac
    done < "$file_path"
    echo "--------------------------------"
    return $exit_code
}

# Hauptfunktion zum Durchsuchen des Verzeichnisses und Überprüfen der Dateien
main() {
    overall_exit_code=0
    for filename in "$directory"/*; do
        if [ -f "$filename" ]; then
            echo "Überprüfe Datei: $(basename "$filename")"
            echo "=============================="
            max_age=$(basename "$filename" | cut -d'_' -f1)
            if [[ "$max_age" =~ ^[0-9]+$ ]]; then
                file_mtime=$(stat -c %Y "$filename")
                file_age=$((current_time - file_mtime))
                file_age_hours=$((file_age / 3600))

                echo "Alter der Datei: $file_age_hours Stunden"

                if [ "$file_age" -gt "$max_age" ]; then
                    echo "$(basename "$filename") - DATEI IST ZU ALT"
                    overall_exit_code=3
                else
                    check_status "$filename"
                    file_exit_code=$?
                    if [ "$file_exit_code" -gt "$overall_exit_code" ]; then
                        overall_exit_code=$file_exit_code
                    fi
                fi
            else
                echo "$(basename "$filename") - UNGÜLTIGER DATEINAME"
                overall_exit_code=3
            fi
            echo ""
        fi
    done
    exit $overall_exit_code
}

# Ausführung der Hauptfunktion
main
