@echo off
rem NetGuard build - MSVC, static CRT, Windows 7 target (no .NET)
setlocal

set VSDIR=C:\Program Files\Microsoft Visual Studio\18\Professional
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 ( echo [ERR] vcvars64 failed & exit /b 1 )

if not exist "%~dp0build" mkdir "%~dp0build"

set CFLAGS=/nologo /W3 /O2 /MT /std:c++17 /EHsc /utf-8 /D_WIN32_WINNT=0x0601 /DWINVER=0x0601 /DUNICODE /D_UNICODE /DNOMINMAX /D_CRT_SECURE_NO_WARNINGS
set LIBS=fwpuclnt.lib ws2_32.lib bcrypt.lib advapi32.lib user32.lib gdi32.lib comctl32.lib comdlg32.lib shell32.lib ole32.lib

echo [1/4] compile core
cl %CFLAGS% /c /Fo"%~dp0build\\" "%~dp0src\ng_common.cpp" "%~dp0src\ng_policy.cpp" "%~dp0src\ng_wfp.cpp" "%~dp0src\ng_ipc.cpp" "%~dp0src\ng_trial.cpp" "%~dp0src\ng_drv.cpp" "%~dp0src\ng_service.cpp" "%~dp0src\NetGuard.cpp"
if errorlevel 1 ( echo [ERR] compile failed & exit /b 1 )

echo [2/4] link NetGuard.exe
link /nologo /SUBSYSTEM:CONSOLE,6.01 /DYNAMICBASE /NXCOMPAT /OUT:"%~dp0build\NetGuard.exe" ^
  "%~dp0build\ng_common.obj" "%~dp0build\ng_policy.obj" "%~dp0build\ng_wfp.obj" "%~dp0build\ng_ipc.obj" "%~dp0build\ng_trial.obj" "%~dp0build\ng_drv.obj" "%~dp0build\ng_service.obj" "%~dp0build\NetGuard.obj" %LIBS%
if errorlevel 1 ( echo [ERR] link failed & exit /b 1 )

echo [3/4] compile UI
cl %CFLAGS% /c /Fo"%~dp0build\\" "%~dp0src\ui_main.cpp"
if errorlevel 1 ( echo [ERR] UI compile failed & exit /b 1 )

echo [4/4] link NetGuardUI.exe
rem UI manifest: requireAdministrator (UAC) + comctl32 v6
link /nologo /SUBSYSTEM:WINDOWS,6.01 /DYNAMICBASE /NXCOMPAT /MANIFEST:EMBED ^
  /MANIFESTUAC:"level='requireAdministrator' uiAccess='false'" ^
  /MANIFESTDEPENDENCY:"type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'" ^
  /OUT:"%~dp0build\NetGuardUI.exe" ^
  "%~dp0build\ui_main.obj" "%~dp0build\ng_common.obj" "%~dp0build\ng_policy.obj" "%~dp0build\ng_ipc.obj" "%~dp0build\ng_trial.obj" %LIBS%
if errorlevel 1 ( echo [ERR] UI link failed & exit /b 1 )

echo.
echo ALL OK  -^>  build\NetGuard.exe   build\NetGuardUI.exe
endlocal
