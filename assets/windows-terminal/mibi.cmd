# Launch mibi in Windows Terminal (your default profile) instead of a bare
# console window. Requires Windows Terminal (`wt.exe`); falls back to a plain
# console when it is not installed.
@echo off
setlocal
where wt.exe >nul 2>nul
if errorlevel 1 (
    "%~dp0..\..\zig-out\bin\mibi.exe" %*
    exit /b %errorlevel%
)
wt.exe "%~dp0..\..\zig-out\bin\mibi.exe" %*
