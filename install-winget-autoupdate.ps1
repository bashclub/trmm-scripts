#Set custom field at client level with LIZENSE an GROUP ID
###Download and Install Securepount AV  Client###

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$downloadURL = "https://github.com/Romanitho/Winget-AutoUpdate/releases/download/v1.20.0/WAU.zip"


#---------------------------------------------------------------#

#Look for Securepoint Folder, if not exist then create
$folderName = "Spille"
$Path="C:\"+$folderName

if (!(Test-Path $Path))
{
New-Item -itemType Directory -Path C:\ -Name $FolderName
}
else
{
write-host "Folder already exists"
}

#Download MSI for SECUREPOINT AV
Invoke-WebRequest -Uri "$downloadURL" -OutFile "C:\Spille\WAU.zip"
Expand-Archive -Path C:\Spille\WAU.zip -DestinationPath C:\Spille -Force
C:\Spille\Winget-AutoUpdate-Install.ps1 -Silent
