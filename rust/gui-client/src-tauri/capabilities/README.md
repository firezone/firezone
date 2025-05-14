# Tauri capabilities

For increased hardening of a Tauri application, this directory can define explicit capabilities for each view.
See https://v2.tauri.app/security/capabilities/ for details.

We don't include any for now but it is important that this directory exists to ensure we don't unnecessarily invalidate the Rust build when no code has changed as our build-script checks for this directory.
