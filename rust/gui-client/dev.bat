@echo off
setlocal enabledelayedexpansion

REM Copy frontend dependencies
copy "node_modules\flowbite\dist\flowbite.min.js" "src\"

REM Compile TypeScript in watch mode
start tsc --watch

REM Start Tauri hot-reloading
tauri dev
