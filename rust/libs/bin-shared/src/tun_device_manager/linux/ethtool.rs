//! Minimal bindings for the `SIOCETHTOOL` ioctl to toggle netdev features.

use anyhow::{Context as _, Result, bail, ensure};
use std::ffi::CStr;
use std::io;
use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd};
use tun::ioctl;

const ETHTOOL_GSTRINGS: u32 = 0x0000_001b;
const ETHTOOL_GSSET_INFO: u32 = 0x0000_0037;
const ETHTOOL_SFEATURES: u32 = 0x0000_003b;

const ETH_SS_FEATURES: u32 = 4;
const ETH_GSTRING_LEN: usize = 32;

/// Upper bound on how many feature bits we can handle; kernels as of 6.x define 64.
const MAX_FEATURES: usize = 256;
const MAX_FEATURE_WORDS: usize = MAX_FEATURES / 32;

/// Enables a netdev feature, addressed by its string name (as listed by `ethtool --show-features`).
///
/// Feature bit positions are not a stable kernel ABI, only the names are,
/// so the name is resolved to its current bit at runtime.
pub(crate) fn enable_feature(ifname: &str, feature: &str) -> Result<()> {
    let socket = ethtool_socket()?;

    let num_features = num_features(&socket, ifname).context("Failed to query features")?;
    ensure!(
        num_features <= MAX_FEATURES,
        "Kernel defines {num_features} features, can handle at most {MAX_FEATURES}"
    );

    let bit = feature_bit(&socket, ifname, num_features, feature)?;

    set_feature_bit(&socket, ifname, num_features, bit)
        .with_context(|| format!("Failed to request feature `{feature}`"))?;

    Ok(())
}

/// The `SIOCETHTOOL` ioctl operates on a plain socket, addressing the device by name.
fn ethtool_socket() -> Result<OwnedFd> {
    // Safety: FFI call with valid arguments.
    let fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, 0) };

    if fd < 0 {
        return Err(io::Error::last_os_error()).context("Failed to create socket");
    }

    // Safety: We own the newly created FD.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn num_features(socket: &OwnedFd, ifname: &str) -> Result<usize> {
    #[repr(C)]
    struct GSsetInfo {
        cmd: u32,
        reserved: u32,
        sset_mask: u64,
        count: u32,
    }

    let mut info = GSsetInfo {
        cmd: ETHTOOL_GSSET_INFO,
        reserved: 0,
        sset_mask: 1 << ETH_SS_FEATURES,
        count: 0,
    };

    // Safety: The socket FD is open and `info` is a valid `ethtool` command struct.
    unsafe {
        ioctl::exec(
            socket.as_raw_fd(),
            libc::SIOCETHTOOL,
            &mut ioctl::Request::<ioctl::EthtoolPayload>::new(ifname, &mut info),
        )?;
    }

    if info.sset_mask == 0 {
        bail!("Kernel cannot enumerate features");
    }

    Ok(info.count as usize)
}

fn feature_bit(
    socket: &OwnedFd,
    ifname: &str,
    num_features: usize,
    feature: &str,
) -> Result<usize> {
    #[repr(C)]
    struct GStrings {
        cmd: u32,
        string_set: u32,
        len: u32,
        strings: [u8; MAX_FEATURES * ETH_GSTRING_LEN],
    }

    let mut gstrings = GStrings {
        cmd: ETHTOOL_GSTRINGS,
        string_set: ETH_SS_FEATURES,
        len: 0,
        strings: [0u8; MAX_FEATURES * ETH_GSTRING_LEN],
    };

    // Safety: The socket FD is open and the kernel writes at most `num_features <= MAX_FEATURES` strings.
    unsafe {
        ioctl::exec(
            socket.as_raw_fd(),
            libc::SIOCETHTOOL,
            &mut ioctl::Request::<ioctl::EthtoolPayload>::new(ifname, &mut gstrings),
        )?;
    }

    gstrings
        .strings
        .chunks_exact(ETH_GSTRING_LEN)
        .take(num_features)
        .position(|name| {
            CStr::from_bytes_until_nul(name).is_ok_and(|name| name.to_bytes() == feature.as_bytes())
        })
        .with_context(|| format!("Kernel does not support feature `{feature}`"))
}

fn set_feature_bit(socket: &OwnedFd, ifname: &str, num_features: usize, bit: usize) -> Result<()> {
    #[repr(C)]
    struct SFeatures {
        cmd: u32,
        size: u32,
        blocks: [SetFeatureBlock; MAX_FEATURE_WORDS],
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    struct SetFeatureBlock {
        valid: u32,
        requested: u32,
    }

    let mask = 1u32 << (bit % 32);

    let mut sfeatures = SFeatures {
        cmd: ETHTOOL_SFEATURES,
        // The kernel rejects any size other than the exact number of feature words it defines.
        size: num_features.div_ceil(32) as u32,
        blocks: [SetFeatureBlock::default(); MAX_FEATURE_WORDS],
    };
    sfeatures.blocks[bit / 32] = SetFeatureBlock {
        valid: mask,
        requested: mask,
    };

    // Safety: The socket FD is open and `sfeatures` is a valid `ethtool` command struct.
    unsafe {
        ioctl::exec(
            socket.as_raw_fd(),
            libc::SIOCETHTOOL,
            &mut ioctl::Request::<ioctl::EthtoolPayload>::new(ifname, &mut sfeatures),
        )?;
    }

    Ok(())
}
