@echo off
REM Run the Daseeki-Bags 2.0 headless self-test harness under real Lua 5.1.
REM Uses the vendored Lua 5.1 shipped with nexus-test-harness (a sibling repo).
REM Usage: run-selftests.cmd [BAGS2_DIR]
setlocal
set HERE=%~dp0
set LUA=%HERE%..\..\nexus-test-harness\lua51\lua5.1.exe
if not exist "%LUA%" set LUA=%HERE%..\..\..\nexus-test-harness\lua51\lua5.1.exe
set BAGS2=%~1
if "%BAGS2%"=="" set BAGS2=%HERE%..
"%LUA%" "%HERE%run-selftests.lua" "%BAGS2%"
exit /b %ERRORLEVEL%
