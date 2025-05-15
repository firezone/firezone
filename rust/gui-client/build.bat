@echo off
setlocal enabledelayedexpansion

REM Copy frontend dependencies
copy "node_modules\flowbite\dist\flowbite.min.js" "src\"

REM bundle web assets
call pnpm vite build

REM Compile Rust and bundle
call pnpm tauri build
