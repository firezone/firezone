@echo off
setlocal enabledelayedexpansion

REM Copy frontend dependencies
copy "node_modules\flowbite\dist\flowbite.min.js" "src\"

REM Compile TypeScript
call pnpm tsc

REM Compile CSS
call pnpm tailwindcss -i src\input.css -o src\output.css

REM Compile Rust and bundle
call tauri build --debug --bundles none
