//! Advisory file lock used to coordinate first-instance detection.
//!
//! The first GUI instance acquires an exclusive non-blocking advisory
//! lock on `<known_dirs::session()>/launch.lock` and holds it for the
//! lifetime of the process. Subsequent launches see the lock fail and
//! know to hand off to the running instance instead of binding their
//! own pipe server.
//!
//! Same code path on Linux (`flock` via `fd-lock`) and Windows
//! (`LockFileEx` via `fd-lock`). The lock is in-memory kernel state
//! attached to the open file descriptor / handle, so a sudden power
//! loss or crash releases it automatically on the next boot — there's
//! no PID-file-style stale-owner problem.
//!
//! The file's content is irrelevant; only the *presence of the lock*
//! is observed. We never read the file from the second instance, so
//! Windows' "locked range blocks `ReadFile`" mandatory-lock semantics
//! don't matter.

use anyhow::{Context, Result};
use fd_lock::{RwLock as FdRwLock, RwLockWriteGuard as FdRwLockWriteGuard};
use std::{
    fs::{File, OpenOptions},
    path::PathBuf,
};

/// RAII guard holding the advisory file lock for the lifetime of the
/// first instance. The kernel auto-releases the lock on process exit
/// (graceful, panic, or `kill -9`), so the presence of the lock is
/// also a liveness signal.
pub struct LaunchLock {
    // The `'static` lifetime is a deliberate leak: this struct lives
    // for the whole process when held. `fd_lock::RwLock` owns the
    // `std::fs::File` and the guard borrows from it; leaking the
    // `RwLock` makes the borrow `'static`.
    _guard: FdRwLockWriteGuard<'static, File>,
}

/// Outcome of [`acquire`].
pub enum FirstInstance {
    /// We acquired the exclusive lock and are the running first
    /// instance. The `LaunchLock` must be held for the process
    /// lifetime; dropping it releases the lock and unblocks a
    /// subsequent first-instance check.
    Yes(LaunchLock),
    /// Another instance is alive and holds the lock. The caller is
    /// expected to hand off whatever request triggered the launch
    /// (deep-link URL, "open the UI") to the running instance and
    /// exit.
    No,
}

/// Tries to become the first GUI instance.
pub fn acquire() -> Result<FirstInstance> {
    let path = path()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("Failed to create `{}`", parent.display()))?;
    }

    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&path)
        .with_context(|| format!("Failed to open launch lock `{}`", path.display()))?;

    // Leak the `RwLock` so the guard's borrow is `'static`; the
    // first-instance state lives for the whole process either way.
    let lock: &'static mut FdRwLock<File> = Box::leak(Box::new(FdRwLock::new(file)));

    match lock.try_write() {
        Ok(guard) => Ok(FirstInstance::Yes(LaunchLock { _guard: guard })),
        Err(_) => Ok(FirstInstance::No),
    }
}

fn path() -> Result<PathBuf> {
    let dir = known_dirs::session().context("No session directory available")?;
    Ok(dir.join("launch.lock"))
}
