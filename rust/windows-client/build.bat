@echo off
setlocal enabledelayedexpansion

REM Compile TypeScript
call pnpm tsc

REM Compile CSS
call pnpm tailwindcss -i src\input.css -o src\output.css

REM Compile Rust and bundle
call tauri build
