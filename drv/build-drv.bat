@echo off
setlocal
call "C:\Program Files\Microsoft Visual Studio\18\Professional\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 ( echo [ERR] vcvars64 failed & exit /b 1 )

set WDK=C:\Program Files (x86)\Windows Kits\10
set WINC=%WDK%\Include\10.0.26100.0
set WLIB=%WDK%\Lib\10.0.26100.0\km\x64
set OUT=%~dp0out
if not exist "%OUT%" mkdir "%OUT%"

cl /nologo /c /kernel /GS- /Gs9999999 /Zl /W4 ^
  /I"%WINC%\km" /I"%WINC%\shared" ^
  /D_WIN32_WINNT=0x0A00 /DNTDDI_VERSION=0x0A000000 /DPOOL_NX_OPTIN=1 ^
  /D_KERNEL_MODE /D_AMD64_ /D_WIN64 ^
  /Fo"%OUT%\\" "%~dp0hello.c"
if errorlevel 1 ( echo [ERR] compile failed & exit /b 1 )

link /nologo /DRIVER /SUBSYSTEM:NATIVE /ENTRY:DriverEntry /MACHINE:X64 ^
  /OUT:"%OUT%\nghello.sys" "%OUT%\hello.obj" ^
  "%WLIB%\ntoskrnl.lib" "%WLIB%\hal.lib" "%WLIB%\wdm.lib" "%WLIB%\BufferOverflowK.lib"
if errorlevel 1 ( echo [ERR] link failed & exit /b 1 )

echo OK -^> %OUT%\nghello.sys
endlocal
