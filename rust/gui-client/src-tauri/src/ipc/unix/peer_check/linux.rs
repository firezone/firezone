use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt as _;
use std::path::{Path, PathBuf};

use tokio::net::UnixStream;

#[cfg(not(test))]
use super::allowlist_file;
use super::{Allowlist, PeerRejected};

#[cfg(not(test))]
const ALLOWLIST_PATH: &str = "/etc/firezone/allowed-clients.conf";

#[cfg(not(test))]
pub fn load_default() -> Allowlist {
    Allowlist::with_paths(allowlist_file::read(Path::new(ALLOWLIST_PATH)))
}

/// Test variant: trust the running test binary. Controller tests connect
/// from a cargo-built test binary that lives under `target/.../deps/` and
/// is owned by the test runner, so it can never be on a real root-managed
/// allowlist.
#[cfg(test)]
pub fn load_default() -> Allowlist {
    let exe = std::env::current_exe().expect("test binary must have an exe path");
    let canonical = std::fs::canonicalize(&exe).unwrap_or(exe);
    Allowlist::with_paths(vec![canonical])
}

/// Verify that the peer connected to `stream` is running a binary on the
/// `allowlist`.
///
/// Steps:
///   1. `getsockopt(SO_PEERPIDFD)` to obtain a pidfd pinned to the peer
///      process; on `ENOPROTOOPT` the kernel doesn't support pidfds and we
///      return `Unverifiable`, leaving the accept/reject choice to the
///      caller.
///   2. Read the peer's `Pid` from `/proc/self/fdinfo/<pidfd>` — the pidfd
///      keeps the PID from being reused.
///   3. Resolve `/proc/<peer_pid>/exe` and reject if the kernel marks it
///      `(deleted)`.
///   4. Canonicalise the exe path and check it against the allowlist.
pub fn verify_peer(stream: &UnixStream, allowlist: &Allowlist) -> Result<PathBuf, PeerRejected> {
    let pidfd = match peer_pidfd(stream.as_raw_fd()) {
        Ok(fd) => fd,
        Err(error) if error.raw_os_error() == Some(libc::ENOPROTOOPT) => {
            return Err(PeerRejected::Unverifiable);
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

    Ok(canonical)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allowlist_contains_canonicalised_path() {
        let canonical = std::fs::canonicalize("/usr/bin/true").unwrap();
        let allowlist = Allowlist::from_paths(vec![canonical.clone()]);

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
        let allowlist = Allowlist::from_paths(vec![own_exe.clone()]);

        assert_eq!(verify_peer(&b, &allowlist).unwrap(), own_exe);

        let empty = Allowlist::default();
        match verify_peer(&b, &empty) {
            Err(PeerRejected::NotAllowlisted { exe }) => assert_eq!(exe, own_exe),
            other => panic!("expected NotAllowlisted, got {other:?}"),
        }
    }
}
