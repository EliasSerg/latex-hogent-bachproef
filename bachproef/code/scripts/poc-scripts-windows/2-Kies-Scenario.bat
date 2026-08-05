@echo off
title Kanaalscenario kiezen
echo.
echo Welk kanaalscenario wil je activeren?
echo.
echo   1 = Ideaal       (0-15 km, sterk signaal)
echo   2 = Marginaal    (15-30 km, adaptieve modulatie)
echo   3 = DFS-wissel   (simuleert radardetectie: 10s onderbreking)
echo.
choice /c 123 /n /m "Maak een keuze (1, 2 of 3): "

if errorlevel 3 set SCENARIO=dfs
if errorlevel 2 if not errorlevel 3 set SCENARIO=marginaal
if errorlevel 1 if not errorlevel 2 set SCENARIO=ideaal

echo.
echo Scenario "%SCENARIO%" wordt geactiveerd...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Select-Scenario.ps1" %SCENARIO%
echo.
pause
