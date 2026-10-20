@echo off
rem trkStreamDesc release script - builds dev + prod and packs bin\prod
rem into dist\trkStreamDesc-win64.zip.

setlocal
cd /d "%~dp0"

call "%~dp0build.bat" || exit /b 1

if not exist dist mkdir dist
set "ZIP=dist\trkStreamDesc-win64.zip"
if exist "%ZIP%" del /q "%ZIP%"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Compress-Archive -Path '%~dp0bin\prod\*' -DestinationPath '%~dp0%ZIP%' -Force"
if errorlevel 1 (
  echo [ERROR] Creating %ZIP% failed.
  exit /b 1
)

echo.
echo Release package: %ZIP%
exit /b 0
