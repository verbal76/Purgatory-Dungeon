@echo off
:: ============================================================
::  convert_to_webm.bat
::  Drag any video file onto this batch file to convert it
::  to a Godot-compatible .webm (VP9, no audio).
::
::  OUTPUT: saved in the same folder as the SOURCE FILE
::  REQUIRES: ffmpeg.exe must be on your system PATH
::
::  ADJUSTABLE SETTINGS:
::    CRF    — quality (0=best, 63=worst, 30 is a good default)
::    SPEED  — encode speed (0=slowest/best, 4=fastest/rougher)
:: ============================================================

set CRF=30
set SPEED=2

:: ── Require a dragged file ─────────────────────────────────
if "%~1"=="" (
    echo.
    echo  ERROR: No file dragged onto this bat.
    echo  Drag a video file onto convert_to_webm.bat to use it.
    echo.
    pause
    exit /b 1
)

:: ── Build paths ────────────────────────────────────────────
set "INPUT=%~1"
set "OUTPUT=%~dp1%~n1.webm"

echo.
echo ============================================================
echo  INPUT  : %INPUT%
echo  OUTPUT : %OUTPUT%
echo  CRF    : %CRF%   (lower = better quality)
echo  SPEED  : %SPEED%  (0=best quality, 4=fastest)
echo ============================================================
echo.

:: ── Check ffmpeg is reachable ──────────────────────────────
where ffmpeg >nul 2>&1
if %errorlevel% neq 0 (
    echo  ERROR: ffmpeg not found on PATH.
    echo  Download from https://ffmpeg.org and add its bin
    echo  folder to your Windows PATH, then try again.
    echo.
    pause
    exit /b 1
)

echo  ffmpeg found. Starting conversion...
echo  (Full ffmpeg output shown below so you can see any errors)
echo.

:: ── Run conversion — all output visible in this window ─────
ffmpeg -i "%INPUT%" -c:v libvpx-vp9 -b:v 0 -crf %CRF% -cpu-used %SPEED% -an -y "%OUTPUT%"

echo.
echo ============================================================

:: ── Verify the output file actually exists ─────────────────
if exist "%OUTPUT%" (
    echo  SUCCESS: File saved to:
    echo  %OUTPUT%
) else (
    echo  FAILED: Output file was not created.
    echo  Check the ffmpeg output above for the error.
)

echo ============================================================
echo.
pause
