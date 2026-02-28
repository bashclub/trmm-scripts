# Requires admin privileges

# Hole die Festplatte, auf der "C:" liegt
$systemDrive = (Get-Partition -DriveLetter C).DiskNumber
$disk = Get-Disk -Number $systemDrive

# Prüfe nicht zugewiesenen Speicherplatz in GB
$unallocatedSpaceGB = [math]::Round(($disk.LargestFreeExtent / 1GB), 2)

# Ergebnis ausgeben
if ($unallocatedSpaceGB -ge 10) {
    Write-Output "WARNUNG: $unallocatedSpaceGB GB nicht zugewiesener Speicherplatz vorhanden auf Datenträger $($disk.Number)."
    exit 1  # WARNING status in Tactical RMM
} else {
    Write-Output "OK: Nur $unallocatedSpaceGB GB nicht zugewiesener Speicherplatz auf Datenträger $($disk.Number)."
    exit 0
}
