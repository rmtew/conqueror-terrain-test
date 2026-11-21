@echo off
setlocal
cd /d "%~dp0"
if not defined VASM set "VASM=%~dp0bin\vasmm68k_mot.exe"
if not exist build mkdir build
"%VASM%" -m68000 -Fhunkexe -kick1hunks -I. -o build/TankRenderLab tank_render_lab.s
if errorlevel 1 exit /b %errorlevel%
python tools/make_adf.py build/TankRenderLab build/TankRenderLab.adf
exit /b %errorlevel%
