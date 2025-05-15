@echo off
setlocal enabledelayedexpansion

REM bundle web assets
call pnpm vite build

REM Compile Rust and bundle
call pnpm tauri build
