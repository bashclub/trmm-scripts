:: ============================================================ 
:: Windows-Systemprüfung und Reparatur 
:: 
:: Diese Befehlsfolge führt eine umfassende Überprüfung und 
:: Reparatur des Windows-Betriebssystems durch. 
:: 
:: Folgende Schritte werden ausgeführt: 
:: 
:: 1. Überprüfung und Reparatur geschützter Windows-Systemdateien 
:: mittels System File Checker (SFC). 
:: 
:: 2. Analyse des Windows-Komponentenspeichers (WinSxS) auf 
:: Beschädigungen und Inkonsistenzen. 
:: 
:: 3. Reparatur erkannter Fehler im Komponentenspeicher mittels 
:: Deployment Image Servicing and Management (DISM). 
:: 
:: 4. Bereinigung veralteter Komponenten und Updates zur 
:: Reduzierung des Speicherbedarfs und Optimierung des 
:: Komponentenspeichers. 
:: 
:: Hinweise: 
:: - Die Ausführung erfordert Administratorrechte. 
:: - Je nach Systemleistung kann die Durchführung einige Zeit 
:: in Anspruch nehmen. 
:: - Nach Abschluss der Reparaturmaßnahmen wird ein Neustart 
:: des Systems empfohlen. 
:: - Der Parameter /ResetBase ist nicht rückgängig zu machen. 
:: Bereits installierte Updates können danach nicht mehr 
:: deinstalliert werden. 
:: ============================================================ 
:: Überprüft alle geschützten Windows-Systemdateien und 
:: repariert erkannte Beschädigungen automatisch.
sfc /scannow

:: Analysiert den Windows-Komponentenspeicher (WinSxS) 
:: auf mögliche Beschädigungen.
DISM /Online /Cleanup-Image /ScanHealth

:: Repariert erkannte Fehler im Komponentenspeicher. 
DISM /Online /Cleanup-Image /RestoreHealth

:: Entfernt veraltete Komponenten und ersetzt diese durch 
:: die aktuell installierten Versionen, um Speicherplatz 
:: freizugeben und den Komponentenspeicher zu optimieren. 
DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase
