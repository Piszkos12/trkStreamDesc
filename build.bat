@echo off
rem trkStreamDesc build script - builds both versions:
rem   bin\dev\   debug info, runtime checks, heaptrc
rem   bin\prod\  optimized, stripped
rem Override the Lazarus location with the LAZARUS_DIR environment variable.

setlocal
cd /d "%~dp0"

if "%LAZARUS_DIR%"=="" set "LAZARUS_DIR=D:\lazarus"
set "FPC=%LAZARUS_DIR%\fpc\3.2.2\bin\x86_64-win64\fpc.exe"
if not exist "%FPC%" (
  echo [ERROR] fpc not found: "%FPC%"
  echo         Set LAZARUS_DIR to your Lazarus installation folder.
  exit /b 1
)

call :build dev  "-g -gl -gh -Ci -Cr -Co -Ct -dDEBUG" || exit /b 1
call :build prod "-O2 -Xs -XX -CX"                     || exit /b 1

echo.
echo Build finished.
exit /b 0

rem ---------------------------------------------------------------
rem :build <output subfolder> "<compiler options>"
:build
echo.
echo === Building %1 ===
set "OUT=bin\%1"
set "UNITS=lib\%1"
if not exist "%OUT%" mkdir "%OUT%"
if not exist "%UNITS%" mkdir "%UNITS%"
"%FPC%" %~2 -B -FU"%UNITS%" -FE"%OUT%" trkstream.lpr
if errorlevel 1 (
  echo [ERROR] %1 build failed.
  exit /b 1
)
copy /y *.html "%OUT%\" >nul
copy /y *.js "%OUT%\" >nul
copy /y README.md "%OUT%\" >nul
echo %1 -^> %OUT%\trkstream.exe
exit /b 0
