# Edition aus Registry holen
$edition = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").EditionID

# Ausgabe für Collection Task
Write-Output "WinEdition=$edition"

# Optional: Fehler erzeugen, wenn Evaluation erkannt wird
if ($edition -like "*Eval*") {
    Write-Error "❌ Evaluation Edition detected: $edition"
    exit 1
}
