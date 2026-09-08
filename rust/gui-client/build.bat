@echo off
setlocal enabledelayedexpansion

REM bundle web assets
call pnpm vite build

REM The `firezone` CLI is its own workspace member, so `tauri build` never
REM compiles it. It gets its own target directory because the filesystem is
REM case-insensitive: `firezone.exe` and the GUI's `Firezone.exe` are the same
REM name, so the two would overwrite each other under `target\release`.
cargo build --release -p firezone-cli --target-dir ..\target\cli || exit /b 1

REM Compile Rust and bundle
call pnpm tauri build
