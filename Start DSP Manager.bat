@echo off
title DSP Manager

:: Start de applicatie onzichtbaar op de achtergrond
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0DSP-Manager-Core.ps1"
