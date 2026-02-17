# TRMM Disk Usage Check - Alarm bei >= 85%
# Exitcode 0 = OK
# Exitcode 1 = Warning/Alarm

$threshold = 85
$exitCode = 0
$messages = @()

# Nur physische Laufwerke (DriveType 3 = Fixed Disk)
$disks = Get-CimInstance Win32_LogicalDisk | Where-Object {
    $_.DriveType -eq 3 -and $_.Size -gt 0
}

foreach ($disk in $disks) {

    $sizeGB = [math]::Round($disk.Size / 1GB, 2)
    $freeGB = [math]::Round($disk.FreeSpace / 1GB, 2)
    $usedGB = $sizeGB - $freeGB

    if ($sizeGB -eq 0) { continue }

    $usedPercent = [math]::Round(($usedGB / $sizeGB) * 100, 1)

    if ($usedPercent -ge $threshold) {
        $messages += "ALARM: Laufwerk $($disk.DeviceID) ist zu $usedPercent% voll ($usedGB GB von $sizeGB GB benutzt)"
        $exitCode = 1
    }
    else {
        $messages += "OK: Laufwerk $($disk.DeviceID) ist zu $usedPercent% voll"
    }
}

# Ausgabe für TRMM
foreach ($msg in $messages) {
    Write-Output $msg
}

exit $exitCode
