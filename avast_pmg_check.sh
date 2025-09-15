#!/bin/bash

output=$(/usr/lib/avast/vpsupdate 2>&1)

if echo "$output" | grep -q "VPS is up to date"; then
    echo "OK – VPS is up to date."
    exit 0
else
    echo "WARNUNG – VPS nicht aktuell oder Fehler!"
    echo "$output"
    exit 1
fi
