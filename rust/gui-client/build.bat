@echo off
setlocal enabledelayedexpansion

REM bundle web assets
call pnpm vite build

REM The `firezone` CLI is its own workspace member, so `tauri build` never
REM compiles it. The installer renames `firezone-cli.exe` on the way in.
cargo build --release -p firezone-cli || exit /b 1

REM Compile Rust and bundle
call pnpm tauri build
