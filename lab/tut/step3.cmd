@echo off
chcp 936 >nul
title C:\Windows\system32\cmd.exe - NetGuard 教程
color 0F
mode con cols=100 lines=40
cd /d C:\NetGuard
cls
echo ================================================================
echo   NetGuard 新手教程 3/3：验证拦截、临时放行、审计与卸载
echo ================================================================
echo.
echo  第 9 步：验证默认拒绝（下面的 ping 应该全部超时）
echo.
echo  说明：能通的只有白名单里的“程序 + 地址 + 端口”，
echo        其余流量（包括浏览器、迅雷、木马）在这里都会被拦。
echo.
echo C:\NetGuard^> ping 8.8.8.8
echo.
ping -n 3 8.8.8.8
echo.
echo C:\NetGuard^> ping 114.114.114.114
echo.
ping -n 3 114.114.114.114
call :wait 2
call :shot 17-ping-blocked
cls
echo ================================================================
echo  第 10 步：临时放行 1 分钟（给更新程序/远程维护用）
echo ================================================================
echo.
echo C:\NetGuard^> NetGuard.exe ctl temp 1
echo.
NetGuard.exe ctl temp 1
echo.
echo C:\NetGuard^> NetGuard.exe ctl status
echo.
NetGuard.exe ctl status
call :wait 2
call :shot 18-temp
cls
echo ================================================================
echo  第 11 步：临时放行到期，看门狗自动恢复管控
echo ================================================================
echo.
echo  正在等待 125 秒（服务每 30 秒检查一次，至少跨过两个周期）...
ping -n 126 127.0.0.1 >nul
echo.
echo C:\NetGuard^> NetGuard.exe ctl status
echo.
NetGuard.exe ctl status
call :wait 2
call :shot 19-restored
cls
echo ================================================================
echo  第 12 步：查看审计与日志
echo ================================================================
echo.
echo --- C:\ProgramData\NetGuard\filters.txt（生效的过滤器 ID）---
type C:\ProgramData\NetGuard\filters.txt
echo.
echo --- ng.log 最后 8 行 ---
powershell -NoProfile -Command "Get-Content C:\ProgramData\NetGuard\ng.log -Encoding UTF8 | Select-Object -Last 8"
call :wait 2
call :shot 20-audit
cls
echo ================================================================
echo  第 13 步：卸载（先 rollback，再删除服务，不会留下断网状态）
echo ================================================================
echo.
echo C:\NetGuard^> powershell -ExecutionPolicy Bypass -File uninstall-netguard.ps1
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall-netguard.ps1
echo.
echo C:\NetGuard^> sc query NetGuard
echo.
sc query NetGuard
call :wait 2
call :shot 21-uninstall
exit /b 0

:wait
ping -n %1 127.0.0.1 >nul
exit /b

:shot
powershell -NoProfile -ExecutionPolicy Bypass -File C:\NetGuard\tut\shot.ps1 -Name %1 -TitleLike "NetGuard 教程"
exit /b
