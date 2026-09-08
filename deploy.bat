@echo off
setlocal

set "SRC=D:\Github\Game Mod\Binding of Isaac Repentance+\GhostStep"
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

rem /MIR mirror sync (removes stale files e.g. old tests/)
rem /XD recordings 递归排除运行时回放数据（/MIR 不会删除 DST 侧该目录）
rem /XD .git .claude references 排除仓库与参考资料，仅同步 mod 本体
robocopy "%SRC%" "%DST%" /MIR /XD tests recordings .git .claude references /XF deploy.bat .gitignore ANALYSIS.md /NFL /NDL /NJH /NJS /NP >nul
if %ERRORLEVEL% GEQ 8 (
    echo ERROR: robocopy failed with code %ERRORLEVEL%
    pause
    exit /b 1
)

echo Done. Restart Isaac or press Ctrl+R in-game to reload Lua.
echo.
pause
