@echo off
title NightLock installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0NightLock.ps1" -Install
