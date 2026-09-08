@echo off
setlocal

set "SRC=D:\Github\Game Mod\Binding of Isaac Repentance+\GhostStep\GhostStep3"
set "DST=D:\SteamLibrary\steamapps\common\The Binding of Isaac Rebirth\mods\GhostStep3"

echo.
echo [GhostStep3 Deploy]
echo   Source: %SRC%
echo   Target: %DST%
echo.

if not exist "%SRC%\main.lua" (
    echo ERROR: source not found
    pause
    exit /b 1
)

rem /MIR mirror sync (removes stale files e.g. old tests/), exclude tests
robocopy "%SRC%" "%DST%" /MIR /XD tests recordings /XF deploy.bat /NFL /NDL /NJH /NJS /NP >nul
if %ERRORLEVEL% GEQ 8 (
    echo ERROR: robocopy failed with code %ERRORLEVEL%
    pause
    exit /b 1
)

echo Done. Restart Isaac or press Ctrl+R in-game to reload Lua.
echo.
pause
