This is a test program for features that aren't working in the GUI Windows client yet.

# Debugging

In Powershell

```
cd src-tauri
cargo build
Start-Process target/debug/windows-permissions-test.exe -verb runas
```
