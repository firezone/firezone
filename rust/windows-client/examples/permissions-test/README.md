This is a test program for features that aren't working in the GUI Windows client yet.

# Debugging

```
cd src-tauri
cargo build
Start-Process target/debug/windows-permissions-test.exe -verb runas
```
