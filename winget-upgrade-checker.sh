# Name: Winget Upgrade Checker

# Beschreibung:
# Dieses Skript zeigt verfügbare Upgrades mit winget an, falls welche vorhanden sind.
# Exit 1: Wenn neue Upgrades verfügbar sind oder ein Fehler auftritt.
# Exit 0: Wenn keine Upgrades verfügbar sind.

# Winget-Upgrade-Befehl ausführen
try {
    $wingetloc = (Get-Childitem -Path "C:\Program Files\WindowsApps" -Include winget.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -Last 1 | %{$_.FullName} | Split-Path)
    cd $wingetloc

    $Output = .\winget.exe upgrade --accept-source-agreements 2>&1 | Out-String
} catch {
    Write-Host "Fehler: Winget konnte nicht ausgeführt werden."
    Exit 1
}

# Prüfung, ob keine Updates verfügbar sind
if ($Output -match "No installed package\(s\) have available updates" -or $Output -match "No installed package found matching input criteria") {
    Write-Host "WinGet hat keine neuen Aktualisierungen gefunden!"
    Exit 0
}

# Extrahieren und Anzeigen der relevanten Ausgabe
$Lines = $Output -split "`n"
$StartIndex = ($Lines | ForEach-Object { $_ } | Select-String -Pattern "^Name\s+Id\s+Version\s+Available\s+Source" | Select-Object -First 1).LineNumber
if ($StartIndex -ne $null) {
    $RelevantLines = $Lines[($StartIndex - 1)..($Lines.Length - 1)] | Where-Object { $_ -notmatch "^[\\|/\-]*$" -and $_ -ne "" }
    Write-Host "WinGet hat neue Aktualisierungen gefunden:`n"
    Write-Host ($RelevantLines -join "`n")
    Exit 1
} else {
    Write-Host "Fehler: Relevante Informationen konnten nicht extrahiert werden."
    Exit 1
}

