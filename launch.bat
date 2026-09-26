@echo off
rem Double-click to open the GodotLiveMCP launcher (Windows).
rem Uses %GODOT% if set, then godot on PATH, then asks once and remembers
rem the path in launcher\.godot_path.
setlocal
set "LAUNCHER=%~dp0launcher"
set "SAVED=%LAUNCHER%\.godot_path"

if not defined GODOT if exist "%SAVED%" set /p GODOT=<"%SAVED%"
if not defined GODOT for /f "delims=" %%G in ('where godot 2^>nul') do if not defined GODOT set "GODOT=%%G"
if defined GODOT if not exist "%GODOT%" set "GODOT="

if not defined GODOT (
  echo Couldn't find Godot. Drag the Godot .exe into this window and press Enter:
  set /p GODOT=
)
set "GODOT=%GODOT:"=%"
if not exist "%GODOT%" (
  echo "%GODOT%" not found.
  pause
  exit /b 1
)
> "%SAVED%" echo %GODOT%

start "" "%GODOT%" --path "%LAUNCHER%"
