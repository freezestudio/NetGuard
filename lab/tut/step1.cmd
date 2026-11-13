@echo off
chcp 936 >nul
title C:\Windows\system32\cmd.exe - NetGuard 教程
color 0F
mode con cols=100 lines=40
cd /d C:\NetGuard
cls
echo ================================================================
echo   NetGuard 新手教程 1/3：查看程序、生成策略、安装服务
echo ================================================================
echo.
echo  第 1 步：确认程序文件都在
echo.
echo C:\NetGuard^> dir
echo.
dir
echo.
echo  说明：NetGuard.exe 是命令行工具，NetGuardUI.exe 是管理界面。
call :wait 2
call :shot 03-dir
cls
echo ================================================================
echo  第 2 步：查看命令行帮助
echo ================================================================
echo.
echo C:\NetGuard^> NetGuard.exe
echo.
NetGuard.exe
call :wait 2
call :shot 04-help
cls
echo ================================================================
echo  第 3 步：生成示例策略和部署密钥
echo ================================================================
echo.
echo C:\NetGuard^> NetGuard.exe initpolicy
echo.
NetGuard.exe initpolicy
echo.
echo C:\NetGuard^> NetGuard.exe initkey
echo.
NetGuard.exe initkey
call :wait 2
call :shot 05-initpolicy
cls
echo ================================================================
echo  第 4 步：看一眼策略文件（示例，现场按门店修改）
echo ================================================================
echo.
echo 策略文件位置：C:\ProgramData\NetGuard\policy.ini
echo 用记事本或管理界面都能看；真正修改建议用管理界面（会自动签名）。
echo.
powershell -NoProfile -Command "Get-Content C:\ProgramData\NetGuard\policy.ini -Encoding UTF8"
call :wait 3
call :shot 06-policy
cls
echo ================================================================
echo  第 5 步：校验策略签名（fail-closed，签名不对就不下发）
echo ================================================================
echo.
echo C:\NetGuard^> NetGuard.exe verify
echo.
NetGuard.exe verify
call :wait 2
call :shot 07-verify
cls
echo ================================================================
echo  第 6 步：端到端自测（会临时断网几秒，然后自动撤销）
echo ================================================================
echo.
echo C:\NetGuard^> NetGuard.exe test
echo.
NetGuard.exe test
call :wait 2
call :shot 08-test
cls
echo ================================================================
echo  第 7 步：安装为系统服务（开机自动生效、员工停不掉）
echo ================================================================
echo.
echo C:\NetGuard^> powershell -ExecutionPolicy Bypass -File install-netguard.ps1
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File install-netguard.ps1
call :wait 2
call :shot 09-install
cls
echo ================================================================
echo  第 8 步：确认服务状态与生效过滤器
echo ================================================================
echo.
echo C:\NetGuard^> sc query NetGuard
echo.
sc query NetGuard
echo.
echo C:\NetGuard^> NetGuard.exe status
echo.
NetGuard.exe status
call :wait 2
call :shot 10-status
exit /b 0

:wait
ping -n %1 127.0.0.1 >nul
exit /b

:shot
powershell -NoProfile -ExecutionPolicy Bypass -File C:\NetGuard\tut\shot.ps1 -Name %1 -TitleLike "NetGuard 教程"
exit /b
