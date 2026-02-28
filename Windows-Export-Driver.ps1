@echo off
:: Treiber-Exportskript
:: Erstellt ein datiertes Verzeichnis und exportiert alle installierten Treiber

setlocal
set "DATUM=%date:~-4%-%date:~3,2%-%date:~0,2%"
set "ZIEL=C:\driver\%DATUM%"

echo Erstelle Zielordner: %ZIEL%
mkdir "%ZIEL%" >nul 2>&1

echo Exportiere installierte Treiber...
dism /online /export-driver /destination:%ZIEL%

echo.
echo Export abgeschlossen.
echo Alle Treiber wurden nach %ZIEL% exportiert.
endlocal
