@echo off
schtasks /run /tn "VM-Start-Win7" >nul 2>&1
if errorlevel 1 powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\VMs\launch\start-Win7.ps1'"