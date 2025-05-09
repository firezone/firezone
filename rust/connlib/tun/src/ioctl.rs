use std::{io, os::fd::RawFd};

/// Executes the `ioctl` syscall on the given file descriptor with the provided request.
///
/// # Safety
///
/// The file descriptor must be open.
pub unsafe fn exec<P>(fd: RawFd, code: libc::c_ulong, req: &mut Request<P>) -> io::Result<()> {
    let ret = unsafe { libc::ioctl(fd, code as _, req) };

    if ret < 0 {
        return Err(io::Error::last_os_error());
    }

    Ok(())
}

/// Represents a control request to an IO device, addresses by the device's name.
///
/// The payload MUST also be `#[repr(C)]` and its layout depends on the particular request you are sending.
#[repr(C)]
pub struct Request<P> {
    name: [std::ffi::c_uchar; libc::IF_NAMESIZE],
    payload: P,
}

#[cfg(target_os = "linux")]
impl Request<SetTunFlagsPayload> {
    pub fn new(name: &str) -> Self {
        let name_as_bytes = name.as_bytes();
        debug_assert!(name_as_bytes.len() < libc::IF_NAMESIZE);

        let mut name = [0u8; libc::IF_NAMESIZE];
        name[..name_as_bytes.len()].copy_from_slice(name_as_bytes);

        Self {
            name,
            payload: SetTunFlagsPayload {
                flags: (libc::IFF_TUN | libc::IFF_NO_PI | libc::IFF_MULTI_QUEUE) as _,
            },
        }
    }
}

impl Request<GetInterfaceNamePayload> {
    pub fn new() -> Self {
        Self {
            name: [0u8; libc::IF_NAMESIZE],
            payload: Default::default(),
        }
    }

    pub fn name(&self) -> std::borrow::Cow<'_, str> {
        // Safety: The memory of `self.name` is always initialized.
        let cstr = unsafe { std::ffi::CStr::from_ptr(self.name.as_ptr() as _) };

        cstr.to_string_lossy()
    }
}

impl Default for Request<GetInterfaceNamePayload> {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(target_os = "linux")]
#[repr(C)]
pub struct SetTunFlagsPayload {
    flags: std::ffi::c_short,
}

#[derive(Default)]
#[repr(C)]
pub struct GetInterfaceNamePayload {
    // Fixes a nasty alignment bug on 32-bit architectures on Android.
    // The `name` field in `ioctl::Request` is only 16 bytes long and accessing it causes a NPE without this alignment.
    // Why? Not sure. It seems to only happen in release mode which hints at an optimisation issue.
    alignment: [std::ffi::c_uchar; 16],
}
