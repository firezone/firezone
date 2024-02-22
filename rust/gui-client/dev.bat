@echo off
setlocal enabledelayedexpansion

REM Copy frontend dependencies
copy "node_modules\flowbite\dist\flowbite.min.js" "src\"

REM Compile TypeScript in watch mode
start tsc --watch

REM Compile CSS in watch mode
start call npx tailwindcss -i src\input.css -o src\output.css --watch

REM Start Tauri hot-reloading
tauri dev
