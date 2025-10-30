# ============================================
# TacticalRMM - BitLocker Status Check
# Exitcodes:
#   0 = Keine Verschluesselung aktiv (gruen)
#   1 = Verschluesselt, aber Schutz deaktiviert (gelb)
#   2 = Vollstaendig verschluesselt & Schutz aktiv (rot)
# ============================================

$volumes = Get-BitLockerVolume -ErrorAction SilentlyContinue

if (-not $volumes) {
    Write-Output "BitLocker ist auf diesem System nicht verfuegbar oder nicht installiert."
    exit 0
}

$hasEncrypted = $false
$hasProtected = $false

foreach ($v in $volumes) {
    if ($v.VolumeStatus -eq "FullyEncrypted") {
        $hasEncrypted = $true
        if ($v.ProtectionStatus -eq "On") {
            $hasProtected = $true
        }
    }
}

if ($hasProtected) {
    Write-Output "Laufwerk(e) sind vollstaendig verschluesselt und der Schutz ist aktiv."
    exit 2
} elseif ($hasEncrypted) {
    Write-Output "Laufwerk(e) sind verschluesselt, aber der Schutz ist deaktiviert."
    exit 1
} else {
    Write-Output "Keine Laufwerksverschluesselung aktiv."
    exit 0
}
