@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo Repository: %CD%
echo.
git status
echo.
echo Remote:
git remote -v
echo.
powershell -NoProfile -NoExit -Command "Set-Location -LiteralPath '%CD%'; Write-Host 'NetGuard repo ready. Try: git status / git push' -ForegroundColor Cyan"
