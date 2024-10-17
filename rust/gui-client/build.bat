@echo off
setlocal enabledelayedexpansion

REM Copy frontend dependencies
copy "node_modules\flowbite\dist\flowbite.min.js" "dist\"

REM Compile TypeScript
call pnpm tsc

REM bundle JS
call pnpm vite build

REM Compile CSS
call pnpm tailwindcss -i src\input.css -o src\output.css

REM Compile Rust and bundle
call pnpm tauri build
