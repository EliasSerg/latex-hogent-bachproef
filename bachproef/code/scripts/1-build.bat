@echo off
title PoC-omgeving opbouwen
echo.
echo De volledige testopstelling wordt nu opgebouwd.
echo Dit kan de eerste keer 10 tot 15 minuten duren, en downloadt eenmalig
echo een basisbestand van ongeveer 600 MB. Sluit dit venster niet.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-PoC.ps1"
echo.
echo ============================================================
echo  Klaar. Dit venster kan je nu sluiten.
echo ============================================================
pause