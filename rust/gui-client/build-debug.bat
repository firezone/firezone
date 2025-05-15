@echo off
setlocal enabledelayedexpansion

REM Compile Rust and bundle
call tauri build --debug --bundles none
