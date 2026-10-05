@echo off
rem Run tb_candidate_axis once per parameter set with xsim.
rem Generate the reference files first (WSL): gen_candidate_axis_ref.py.
rem The parameter list below must match PARAM_SETS in that script.
rem Build outputs go to scripts\tb_work (not version controlled).
rem This file is ASCII only: cmd misparses UTF-8 batch files.

setlocal enabledelayedexpansion
call C:\AMDDesignTools\2025.2\Vivado\settings64.bat

set SCRIPT_DIR=%~dp0
set SRC_DIR=%SCRIPT_DIR%..\SaltConv.srcs
set REF_DIR=%SRC_DIR%\sim_1\new\ref
set WORK_DIR=%SCRIPT_DIR%tb_work

if not exist "%WORK_DIR%" mkdir "%WORK_DIR%"
cd /d "%WORK_DIR%"

call xvlog --sv "%SRC_DIR%\sources_1\new\CandidateAxis.sv" "%SRC_DIR%\sim_1\new\tb_candidate_axis.sv" > xvlog.out 2>&1
if errorlevel 1 (
	type xvlog.out
	exit /b 1
)

rem KERNEL_SIZE STRIDE PADDING OUT_SIZE IN_COORD_WIDTH
for %%P in ("3 1 1 64 9" "3 2 1 32 6" "5 2 2 20 6" "4 1 0 7 4" "7 3 3 15 5" "1 2 0 16 5" "2 3 0 10 5" "3 1 1 1 3") do (
	for /f "tokens=1-5" %%a in (%%P) do (
		set SNAP=snap_K%%a_S%%b_P%%c_O%%d_W%%e
		call xelab tb_candidate_axis -s !SNAP! -generic_top "KERNEL_SIZE=%%a" -generic_top "STRIDE=%%b" -generic_top "PADDING=%%c" -generic_top "OUT_SIZE=%%d" -generic_top "IN_COORD_WIDTH=%%e" > xelab_!SNAP!.out 2>&1
		if errorlevel 1 (
			type xelab_!SNAP!.out
			exit /b 1
		)
		call xsim !SNAP! -R -testplusarg "REF_DIR=%REF_DIR:\=/%" > xsim_!SNAP!.out 2>&1
		findstr /c:"MISMATCH" /c:"check_count=" /c:"Fatal" /c:"FATAL" xsim_!SNAP!.out
	)
)
endlocal
