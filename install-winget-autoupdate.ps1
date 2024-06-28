
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$downloadURL = "https://github.com/Romanitho/Winget-AutoUpdate/releases/download/v1.20.1/WAU.zip"


$folderName = "IMSTALL"
$Path="C:\"+$folderName

if (!(Test-Path $Path))
{
New-Item -itemType Directory -Path C:\ -Name $FolderName
}
else
{
write-host "Folder already exists"
}

Invoke-WebRequest -Uri "$downloadURL" -OutFile "C:\IMSTALL\WAU.zip"
Expand-Archive -Path C:\IMSTALL\WAU.zip -DestinationPath C:\IMSTALL -Force
C:\IMSTALL\Winget-AutoUpdate-Install.ps1 -Silent
