@echo off
title Afstandscategorie kiezen
echo.
echo Welke afstandscategorie wil je activeren (vaste basistoestand)?
echo.
echo   1 = 0-15 km    (optimaal bereik, sterk signaal)
echo   2 = 15-30 km   (horizonlimiet, adaptieve modulatie)
echo   3 = 30+ km     (buiten betrouwbaar bereik)
echo.
echo Let op: dit zet een VASTE toestand, zonder weers-/DFS-variatie. Voor de
echo statistische batchtests (honderd trials met willekeurige variatie per
echo afstand), gebruik 4-Voer-Batchtest-Uit.bat.
echo.
choice /c 123 /n /m "Maak een keuze (1, 2 of 3): "

if errorlevel 3 set DISTANCE=30+
if errorlevel 2 if not errorlevel 3 set DISTANCE=15-30
if errorlevel 1 if not errorlevel 2 set DISTANCE=0-15

echo.
echo Afstandscategorie "%DISTANCE%" wordt geactiveerd...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Select-Scenario.ps1" "%DISTANCE%"
echo.
pause
