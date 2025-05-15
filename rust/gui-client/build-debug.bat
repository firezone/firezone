@echo off
setlocal enabledelayedexpansion

REM Copy frontend dependencies
copy "node_modules\flowbite\dist\flowbite.min.js" "src\"

REM Compile TypeScript
call pnpm tsc

REM Compile Rust and bundle
call tauri build --debug --bundles none
