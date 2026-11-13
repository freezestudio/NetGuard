@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\VMs\launch\connect-rdp.ps1" -Target Win10
