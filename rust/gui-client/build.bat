@echo off
setlocal enabledelayedexpansion

REM Copy frontend dependencies
copy "node_modules\flowbite\dist\flowbite.min.js" "src\"

REM Compile CSS
call pnpm tailwindcss -i src\input.css -o src\output.css

REM bundle web assets
call pnpm vite build

REM Compile Rust and bundle
call pnpm tauri build
