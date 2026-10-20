@echo off
rem trkStreamDesc clean script - removes all build output (bin\, lib\, dist\)

setlocal
cd /d "%~dp0"

for %%D in (bin lib dist backup) do (
  if exist "%%D" rmdir /s /q "%%D"
)
if exist trkstream.exe del /q trkstream.exe
if exist trkstream.o del /q trkstream.o

echo Cleaned.
exit /b 0
