@echo off
setlocal
call "C:\Program Files\Microsoft Visual Studio\18\Professional\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 ( echo [ERR] vcvars64 failed & exit /b 1 )

set WDK=C:\Program Files (x86)\Windows Kits\10
set WINC=%WDK%\Include\10.0.26100.0
set WLIB=%WDK%\Lib\10.0.26100.0\km\x64
set OUT=%~dp0out
if not exist "%OUT%" mkdir "%OUT%"

cl /nologo /c /kernel /GS- /Gs9999999 /Zl /W4 /utf-8 ^
  /I"%WINC%\km" /I"%WINC%\shared" ^
  /D_WIN32_WINNT=0x0601 /DNTDDI_VERSION=0x06010000 /DPOOL_NX_OPTIN=1 ^
  /D_AMD64_ /D_WIN64 /DNT /DUNICODE /D_UNICODE /DBINARY_COMPATIBLE=0 ^
  /DNDIS60 /DNDIS_SUPPORT_NDIS6 ^
  /Fo"%OUT%\\" "%~dp0ngdrv.c"
if errorlevel 1 ( echo [ERR] compile failed & exit /b 1 )

link /nologo /DRIVER /SUBSYSTEM:NATIVE,6.01 /ENTRY:DriverEntry /MACHINE:X64 ^
  /OUT:"%OUT%\ngdrv.sys" "%OUT%\ngdrv.obj" ^
  "%WLIB%\ntoskrnl.lib" "%WLIB%\hal.lib" "%WLIB%\wdm.lib" "%WLIB%\wdmsec.lib" ^
  "%WLIB%\fwpkclnt.lib" "%WLIB%\cng.lib" "%WLIB%\ksecdd.lib" ^
  "%WLIB%\ntstrsafe.lib" "%WLIB%\BufferOverflowK.lib" ^
  "%WDK%\Lib\10.0.26100.0\um\x64\uuid.lib"
if errorlevel 1 ( echo [ERR] link failed & exit /b 1 )

echo OK -^> %OUT%\ngdrv.sys
endlocal
