@echo off
title Statistische batchtest
echo.
echo Voor welke afstandscategorie wil je honderden trials uitvoeren?
echo.
echo   1 = 0-15 km
echo   2 = 15-30 km
echo   3 = 30+ km
echo.
choice /c 123 /n /m "Maak een keuze (1, 2 of 3): "
if errorlevel 3 set DISTANCE=30+
if errorlevel 2 if not errorlevel 3 set DISTANCE=15-30
if errorlevel 1 if not errorlevel 2 set DISTANCE=0-15

echo.
set /p AANTAL="Hoeveel trials wil je uitvoeren? (standaard 100, Enter voor standaard): "
if "%AANTAL%"=="" set AANTAL=100

echo.
echo Afstandscategorie "%DISTANCE%" wordt %AANTAL% keer getest.
echo Dit duurt ongeveer %AANTAL% x 30 seconden. Sluit dit venster niet.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-DistanceTrials.ps1" "%DISTANCE%" -Count %AANTAL%
echo.
pause
