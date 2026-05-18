use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt as _;
#[cfg(not(test))]
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};

use tokio::net::UnixStream;

use super::{Allowlist, PeerRejected};

impl Allowlist {
    #[cfg(not(test))]
    pub fn load_default() -> Self {
        Allowlist::with_paths(read_file(Path::new("/etc/firezone/allowed-clients.conf")))
    }

    /// Verify that the peer connected to `stream` is running a binary on
    /// this allowlist.
    ///
    /// Steps:
    ///   1. `getsockopt(SO_PEERPIDFD)` to obtain a pidfd pinned to the peer
    ///      process; on `ENOPROTOOPT` the kernel doesn't support pidfds and
    ///      we return `Unverifiable`, leaving the accept/reject choice to
    ///      the caller.
    ///   2. Read the peer's `Pid` from `/proc/self/fdinfo/<pidfd>` — the
    ///      pidfd keeps the PID from being reused.
    ///   3. Resolve `/proc/<peer_pid>/exe` and reject if the kernel marks
    ///      it `(deleted)`.
    ///   4. Canonicalise the exe path and check it against the allowlist.
    pub fn verify_peer(&self, stream: &UnixStream) -> Result<PathBuf, PeerRejected> {
        let pidfd = match peer_pidfd(stream.as_raw_fd()) {
            Ok(fd) => fd,
            Err(error) if error.raw_os_error() == Some(libc::ENOPROTOOPT) => {
                return Err(PeerRejected::Unverifiable);
            }
            Err(error) => return Err(PeerRejected::ExeUnreadable(error)),
        };

        let peer_pid =
            read_pid_from_fdinfo(pidfd.as_raw_fd()).map_err(PeerRejected::ExeUnreadable)?;
        let exe_link = format!("/proc/{peer_pid}/exe");
        let target = std::fs::read_link(&exe_link).map_err(PeerRejected::ExeUnreadable)?;

        if target.as_os_str().as_bytes().ends_with(b" (deleted)") {
            return Err(PeerRejected::ExeDeleted(target));
        }

        let canonical = std::fs::canonicalize(&target).map_err(PeerRejected::ExeUnreadable)?;

        if !self.contains(&canonical) {
            return Err(PeerRejected::NotAllowlisted { exe: canonical });
        }

        Ok(canonical)
    }
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
        .ok_or_else(|| io::Error::other("missing or unparsable `Pid:` field in fdinfo"))
}

/// Read and parse the root-managed allowlist file.
///
/// The file's own ownership/mode are validated to prevent a
/// confused-deputy attack: without that check, an attacker with write
/// access to the file alone could allowlist a root-owned interpreter like
/// `/usr/bin/bash` (which passes `target_safe`) and connect via
/// `bash -c "..."` so `/proc/<bash-pid>/exe` matches. Requiring the
/// allowlist itself to be root-owned closes that path.
#[cfg(not(test))]
#[tracing::instrument(level = "debug", skip_all, fields(path = %path.display()))]
fn read_file(path: &Path) -> Vec<PathBuf> {
    let metadata = match std::fs::metadata(path) {
        Ok(meta) => meta,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            tracing::debug!("Allowlist file is missing; no peers will be accepted");
            return Vec::new();
        }
        Err(error) => {
            tracing::debug!("Couldn't stat allowlist: {error}");
            return Vec::new();
        }
    };

    if metadata.uid() != 0 || metadata.gid() != 0 {
        tracing::debug!(
            uid = metadata.uid(),
            gid = metadata.gid(),
            "Allowlist must be owned by root:root; ignoring"
        );
        return Vec::new();
    }

    let mode = metadata.mode() & 0o777;
    if mode != 0o644 && mode != 0o640 {
        tracing::debug!(
            mode = format_args!("{mode:#o}"),
            "Allowlist must have mode 0644 or 0640; ignoring"
        );
        return Vec::new();
    }

    let contents = match std::fs::read_to_string(path) {
        Ok(s) => s,
        Err(error) => {
            tracing::debug!("Couldn't read allowlist: {error}");
            return Vec::new();
        }
    };

    contents
        .lines()
        .filter_map(parse_line)
        .filter_map(canonicalise_entry)
        .collect()
}

#[cfg(not(test))]
fn parse_line(line: &str) -> Option<PathBuf> {
    let trimmed = line.split('#').next()?.trim();

    if trimmed.is_empty() {
        return None;
    }

    if !Path::new(trimmed).is_absolute() {
        tracing::debug!(entry = %trimmed, "Ignoring non-absolute allowlist entry");
        return None;
    }

    Some(PathBuf::from(trimmed))
}

#[cfg(not(test))]
fn canonicalise_entry(raw: PathBuf) -> Option<PathBuf> {
    let canonical = match std::fs::canonicalize(&raw) {
        Ok(p) => p,
        Err(error) => {
            tracing::debug!(entry = %raw.display(), "Ignoring allowlist entry: {error}");
            return None;
        }
    };

    if !target_safe(&canonical) {
        tracing::debug!(entry = %canonical.display(), "Ignoring allowlist entry: target or ancestor not root-owned, or is group/world-writable");
        return None;
    }

    Some(canonical)
}

/// True iff `path` and every ancestor up to the root are owned by uid 0
/// and not group- or world-writable.
///
/// Owner check (`uid == 0`) is what prevents a non-root user from
/// substituting the allowlisted binary by recreating it after the daemon
/// loads the allowlist: even if a `0755` directory along the path happens
/// to be writable only by its owner, that owner could replace the
/// allowlisted file if they're not root.
#[cfg(not(test))]
fn target_safe(path: &Path) -> bool {
    let mut current = Some(path);

    while let Some(p) = current {
        let Ok(meta) = std::fs::metadata(p) else {
            return false;
        };

        if meta.uid() != 0 {
            return false;
        }

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

    #[test]
    fn allowlist_contains_canonicalised_path() {
        let canonical = std::fs::canonicalize("/usr/bin/true").unwrap();
        let allowlist = Allowlist::with_paths(vec![canonical.clone()]);

        assert!(allowlist.contains(&canonical));
        assert!(!allowlist.contains(Path::new("/usr/bin/false")));
    }

    #[test]
    fn rejected_reason_strings_are_stable() {
        assert_eq!(PeerRejected::Unverifiable.reason(), "unverifiable");
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
        let allowlist = Allowlist::with_paths(vec![own_exe.clone()]);

        assert_eq!(allowlist.verify_peer(&b).unwrap(), own_exe);

        let empty = Allowlist::default();
        match empty.verify_peer(&b) {
            Err(PeerRejected::NotAllowlisted { exe }) => assert_eq!(exe, own_exe),
            other => panic!("expected NotAllowlisted, got {other:?}"),
        }
    }
}
