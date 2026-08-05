@echo off
title Metingen uitvoeren
echo.
echo De teststeekproef (doorvoersnelheid, latency, SFTP-overdracht) wordt
echo nu uitgevoerd. Dit duurt ongeveer 30 seconden.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Tests.ps1"
echo.
pause
