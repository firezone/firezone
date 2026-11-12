//! Map key types shared between the application filter's eBPF program and its loader.

#![cfg_attr(not(feature = "std"), no_std)]
#![cfg_attr(test, allow(clippy::unwrap_used))]

/// Longest executable path the filter can match, including the terminating NUL.
pub const EXE_PATH_LEN: usize = 256;

/// A zero-padded, NUL-terminated absolute path of an executable.
///
/// The kernel side fills it from the `sched_process_exec` tracepoint; userspace builds it from the policy.
/// Both sides pad with zeros so the bytes compare equal as a hash-map key.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct ExePath(pub [u8; EXE_PATH_LEN]);

impl ExePath {
    pub const fn zeroed() -> Self {
        Self([0; EXE_PATH_LEN])
    }

    /// Returns `None` when the path does not leave room for the terminating NUL.
    pub fn from_bytes(path: &[u8]) -> Option<Self> {
        if path.len() >= EXE_PATH_LEN {
            return None;
        }

        let mut exe = Self::zeroed();
        exe.0[..path.len()].copy_from_slice(path);

        Some(exe)
    }
}

#[cfg(all(feature = "std", target_os = "linux"))]
// SAFETY: `ExePath` is a plain byte array.
unsafe impl aya::Pod for ExePath {}

/// Marks an eBPF program's map entry as present; the value itself carries no meaning.
pub const PRESENT: u8 = 1;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_is_zero_padded() {
        let exe = ExePath::from_bytes(b"/usr/bin/curl").unwrap();

        assert_eq!(&exe.0[..13], b"/usr/bin/curl");
        assert!(exe.0[13..].iter().all(|b| *b == 0));
    }

    #[test]
    fn path_needs_room_for_nul() {
        assert!(ExePath::from_bytes(&[b'a'; EXE_PATH_LEN]).is_none());
        assert!(ExePath::from_bytes(&[b'a'; EXE_PATH_LEN - 1]).is_some());
    }
}
