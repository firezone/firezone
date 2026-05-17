//! Verify that the peer of a connected Unix Domain Socket is one of the
//! binaries on a root-managed allowlist.
//!
//! Linux 6.5+ exposes `SO_PEERPIDFD` on `AF_UNIX` sockets which yields a
//! `pidfd` pinned to a specific process incarnation. Combined with the
//! `/proc/<pid>/exe` symlink and a canonicalised path allowlist, the daemon
//! can refuse calls from any process whose binary is not a Firezone-published
//! binary, even processes running as the same UID.
//!
//! On kernels lacking `SO_PEERPIDFD` the function reports `KernelTooOld` and
//! the caller logs that enforcement is unavailable; the connection is
//! accepted without verification because no better signal exists on those
//! kernels.
//!
//! Test note: this module is built unconditionally on Linux so its inline
//! tests run; production callers gate `verify_peer` invocation on
//! `not(test)` so the IPC framework's own tests can connect from a
//! non-allowlisted test runner.

#![cfg_attr(test, allow(dead_code))]

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt as _;
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};

use tokio::net::UnixStream;

const ALLOWLIST_PATH: &str = "/etc/firezone/allowed-clients.conf";
const DEV_OVERRIDE_ENV: &str = "FIREZONE_TUNNEL_ALLOWED_CALLER_PATHS";

#[derive(Debug, Default)]
pub struct Allowlist {
    paths: Vec<PathBuf>,
}

#[derive(Debug)]
pub enum VerifiedPeer {
    Allowlisted { exe: PathBuf },
    KernelTooOld,
}

#[derive(Debug, thiserror::Error)]
pub enum PeerRejected {
    #[error("Couldn't read peer's executable: {0}")]
    ExeUnreadable(#[source] io::Error),
    #[error("Peer's executable has been deleted: {0}")]
    ExeDeleted(PathBuf),
    #[error("Peer's executable `{}` is not on the allowlist", exe.display())]
    NotAllowlisted { exe: PathBuf },
}

impl PeerRejected {
    pub fn reason(&self) -> &'static str {
        match self {
            Self::ExeUnreadable(_) => "exe_unreadable",
            Self::ExeDeleted(_) => "exe_deleted",
            Self::NotAllowlisted { .. } => "not_allowlisted",
        }
    }

    pub fn exe(&self) -> Option<&Path> {
        match self {
            Self::ExeUnreadable(_) => None,
            Self::ExeDeleted(path) | Self::NotAllowlisted { exe: path } => Some(path),
        }
    }
}

impl Allowlist {
    /// Load the allowlist from the well-known config file.
    ///
    /// Failures (file missing, bad ownership/mode, malformed entries) are
    /// logged and result in an empty or partial allowlist. The caller will
    /// reject all non-allowlisted connections regardless.
    pub fn load_default() -> Self {
        let mut paths = read_allowlist_file(Path::new(ALLOWLIST_PATH));

        if cfg!(debug_assertions)
            && let Some(extra) = std::env::var_os(DEV_OVERRIDE_ENV)
        {
            for raw in std::env::split_paths(&extra) {
                match std::fs::canonicalize(&raw) {
                    Ok(canon) => paths.push(canon),
                    Err(error) => tracing::info!(
                        path = %raw.display(),
                        "Ignoring dev override entry that cannot be canonicalised: {error}"
                    ),
                }
            }
        }

        Self { paths }
    }

    pub fn contains(&self, exe: &Path) -> bool {
        self.paths.iter().any(|allowed| allowed == exe)
    }

    #[cfg(test)]
    pub fn from_paths(paths: Vec<PathBuf>) -> Self {
        Self { paths }
    }
}

/// Verify that the peer connected to `stream` is running a binary on the
/// `allowlist`.
///
/// Steps:
///   1. `getsockopt(SO_PEERPIDFD)` to obtain a pidfd pinned to the peer
///      process; on `ENOPROTOOPT` the kernel doesn't support pidfds and we
///      return `KernelTooOld` so the caller can accept and log that fact.
///   2. Read the peer's `Pid` from `/proc/self/fdinfo/<pidfd>` — the pidfd
///      keeps the PID from being reused.
///   3. Resolve `/proc/<peer_pid>/exe` and reject if the kernel marks it
///      `(deleted)`.
///   4. Canonicalise the exe path and check it against the allowlist.
pub fn verify_peer(
    stream: &UnixStream,
    allowlist: &Allowlist,
) -> Result<VerifiedPeer, PeerRejected> {
    let pidfd = match peer_pidfd(stream.as_raw_fd()) {
        Ok(fd) => fd,
        Err(error) if error.raw_os_error() == Some(libc::ENOPROTOOPT) => {
            return Ok(VerifiedPeer::KernelTooOld);
        }
        Err(error) => return Err(PeerRejected::ExeUnreadable(error)),
    };

    let peer_pid = read_pid_from_fdinfo(pidfd.as_raw_fd()).map_err(PeerRejected::ExeUnreadable)?;
    let exe_link = format!("/proc/{peer_pid}/exe");
    let target = std::fs::read_link(&exe_link).map_err(PeerRejected::ExeUnreadable)?;

    if target.as_os_str().as_bytes().ends_with(b" (deleted)") {
        return Err(PeerRejected::ExeDeleted(target));
    }

    let canonical = std::fs::canonicalize(&target).map_err(PeerRejected::ExeUnreadable)?;

    if !allowlist.contains(&canonical) {
        return Err(PeerRejected::NotAllowlisted { exe: canonical });
    }

    Ok(VerifiedPeer::Allowlisted { exe: canonical })
}

fn peer_pidfd(socket_fd: RawFd) -> io::Result<OwnedFd> {
    let mut raw: libc::c_int = -1;
    let mut len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;

    // SAFETY: `raw` and `len` are stack-allocated; the kernel writes
    // `c_int`-sized data when the call succeeds.
    let ret = unsafe {
        libc::getsockopt(
            socket_fd,
            libc::SOL_SOCKET,
            libc::SO_PEERPIDFD,
            std::ptr::from_mut(&mut raw).cast(),
            &mut len,
        )
    };

    if ret == -1 {
        return Err(io::Error::last_os_error());
    }

    // SAFETY: the kernel returned a fresh fd; nothing else owns it.
    Ok(unsafe { OwnedFd::from_raw_fd(raw) })
}

fn read_pid_from_fdinfo(pidfd: RawFd) -> io::Result<libc::pid_t> {
    let contents = std::fs::read_to_string(format!("/proc/self/fdinfo/{pidfd}"))?;
    contents
        .lines()
        .find_map(|line| line.strip_prefix("Pid:")?.trim().parse().ok())
        .ok_or_else(|| io::Error::other("missing or unparseable `Pid:` field in fdinfo"))
}

fn read_allowlist_file(path: &Path) -> Vec<PathBuf> {
    let metadata = match std::fs::metadata(path) {
        Ok(meta) => meta,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            tracing::error!(path = %path.display(), "Allowlist file is missing; no peers will be accepted unless a dev override is set");
            return Vec::new();
        }
        Err(error) => {
            tracing::error!(path = %path.display(), "Couldn't stat allowlist: {error}");
            return Vec::new();
        }
    };

    if metadata.uid() != 0 || metadata.gid() != 0 {
        tracing::error!(
            path = %path.display(),
            uid = metadata.uid(),
            gid = metadata.gid(),
            "Allowlist must be owned by root:root; ignoring"
        );
        return Vec::new();
    }

    let mode = metadata.mode() & 0o777;
    if mode != 0o644 && mode != 0o640 {
        tracing::error!(
            path = %path.display(),
            mode = format_args!("{mode:#o}"),
            "Allowlist must have mode 0644 or 0640; ignoring"
        );
        return Vec::new();
    }

    let contents = match std::fs::read_to_string(path) {
        Ok(s) => s,
        Err(error) => {
            tracing::error!(path = %path.display(), "Couldn't read allowlist: {error}");
            return Vec::new();
        }
    };

    contents
        .lines()
        .filter_map(parse_allowlist_line)
        .filter_map(|raw| canonicalise_entry(&raw))
        .collect()
}

fn parse_allowlist_line(line: &str) -> Option<PathBuf> {
    let trimmed = line.split('#').next()?.trim();

    if trimmed.is_empty() {
        return None;
    }

    if !Path::new(trimmed).is_absolute() {
        tracing::info!(entry = %trimmed, "Ignoring non-absolute allowlist entry");
        return None;
    }

    Some(PathBuf::from(trimmed))
}

fn canonicalise_entry(raw: &Path) -> Option<PathBuf> {
    let canonical = match std::fs::canonicalize(raw) {
        Ok(p) => p,
        Err(error) => {
            tracing::info!(entry = %raw.display(), "Ignoring allowlist entry: {error}");
            return None;
        }
    };

    if !target_safe(&canonical) {
        tracing::info!(entry = %canonical.display(), "Ignoring allowlist entry: target or ancestor is group/world-writable");
        return None;
    }

    Some(canonical)
}

fn target_safe(path: &Path) -> bool {
    let mut current = Some(path);
    while let Some(p) = current {
        let Ok(meta) = std::fs::metadata(p) else {
            return false;
        };

        if meta.mode() & 0o022 != 0 {
            return false;
        }

        current = p.parent();
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;
    use std::os::unix::fs::PermissionsExt as _;
    use tempfile::NamedTempFile;

    #[test]
    fn parse_allowlist_line_strips_comments_and_blanks() {
        assert_eq!(parse_allowlist_line(""), None);
        assert_eq!(parse_allowlist_line("   "), None);
        assert_eq!(parse_allowlist_line("# comment"), None);
        assert_eq!(
            parse_allowlist_line("/usr/bin/foo  # inline"),
            Some(PathBuf::from("/usr/bin/foo"))
        );
        assert_eq!(
            parse_allowlist_line("  /usr/bin/foo"),
            Some(PathBuf::from("/usr/bin/foo"))
        );
        assert_eq!(parse_allowlist_line("relative/path"), None);
    }

    #[test]
    fn read_allowlist_file_rejects_world_writable() {
        let mut file = NamedTempFile::new().unwrap();
        writeln!(file, "/usr/bin/true").unwrap();
        let perms = std::fs::Permissions::from_mode(0o666);
        std::fs::set_permissions(file.path(), perms).unwrap();

        assert!(read_allowlist_file(file.path()).is_empty());
    }

    #[test]
    fn read_allowlist_file_missing_returns_empty() {
        assert!(
            read_allowlist_file(Path::new("/nonexistent/firezone/allowed-clients.conf")).is_empty()
        );
    }

    #[test]
    fn allowlist_contains_canonicalised_path() {
        let canonical = std::fs::canonicalize("/usr/bin/true").unwrap();
        let allowlist = Allowlist::from_paths(vec![canonical.clone()]);

        assert!(allowlist.contains(&canonical));
        assert!(!allowlist.contains(Path::new("/usr/bin/false")));
    }

    #[test]
    fn rejected_reason_strings_are_stable() {
        assert_eq!(
            PeerRejected::NotAllowlisted {
                exe: PathBuf::from("/x")
            }
            .reason(),
            "not_allowlisted",
        );
        assert_eq!(
            PeerRejected::ExeDeleted(PathBuf::from("/x")).reason(),
            "exe_deleted",
        );
        assert_eq!(
            PeerRejected::ExeUnreadable(io::Error::other("x")).reason(),
            "exe_unreadable",
        );
    }

    #[tokio::test]
    async fn verify_self_against_allowlist_round_trip() {
        let (a, b) = tokio::net::UnixStream::pair().expect("UnixStream::pair failed");

        let probe = peer_pidfd(a.as_raw_fd());
        if let Err(error) = &probe
            && error.raw_os_error() == Some(libc::ENOPROTOOPT)
        {
            tracing::info!("Kernel does not support SO_PEERPIDFD; skipping test");
            return;
        }

        let own_exe = std::fs::canonicalize(std::env::current_exe().unwrap()).unwrap();
        let allowlist = Allowlist::from_paths(vec![own_exe.clone()]);

        match verify_peer(&b, &allowlist).unwrap() {
            VerifiedPeer::Allowlisted { exe } => assert_eq!(exe, own_exe),
            VerifiedPeer::KernelTooOld => {
                panic!("kernel supports SO_PEERPIDFD but returned KernelTooOld")
            }
        }

        let empty = Allowlist::default();
        match verify_peer(&b, &empty) {
            Err(PeerRejected::NotAllowlisted { exe }) => assert_eq!(exe, own_exe),
            other => panic!("expected NotAllowlisted, got {other:?}"),
        }
    }
}
