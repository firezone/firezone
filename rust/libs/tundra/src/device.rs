//! The per-adapter device handle used for packet I/O.

use std::ffi::c_void;
use std::io;
use std::os::windows::ffi::OsStrExt as _;
use std::os::windows::io::{
    AsHandle, AsRawHandle, BorrowedHandle, FromRawHandle as _, OwnedHandle, RawHandle,
};
use std::ptr;

use windows_sys::Win32::Foundation::{
    ERROR_IO_PENDING, GENERIC_READ, GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAG_OVERLAPPED, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
};
use windows_sys::Win32::System::IO::{DeviceIoControl, GetOverlappedResult, OVERLAPPED};
use windows_sys::Win32::System::Threading::CreateEventW;

use crate::abi::{self, AdapterInfo, Statistics};

/// An open handle to an adapter's control device.
///
/// Packet I/O happens through a [`crate::Session`] started on it; the device itself
/// only answers queries and offload configuration.
#[derive(Debug)]
pub struct Device {
    handle: OwnedHandle,
}

impl Device {
    /// Opens the device for the adapter with the given `NET_LUID`.
    pub fn open(luid: u64) -> io::Result<Self> {
        let path = device_path(luid);
        let wide: Vec<u16> = std::ffi::OsStr::new(&path)
            .encode_wide()
            .chain([0])
            .collect();
        // SAFETY: `wide` is a valid NUL-terminated wide string.
        let handle = unsafe {
            CreateFileW(
                wide.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                ptr::null(),
                OPEN_EXISTING,
                FILE_FLAG_OVERLAPPED,
                ptr::null_mut(),
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: We just created the handle and own it.
        let handle = unsafe { OwnedHandle::from_raw_handle(handle as RawHandle) };
        let device = Self { handle };
        let info = device.info()?;
        if info.abi_version != abi::ABI_VERSION {
            return Err(io::Error::other(format!(
                "driver ABI version {} does not match expected version {}",
                info.abi_version,
                abi::ABI_VERSION
            )));
        }
        Ok(device)
    }

    /// Queries static and negotiated adapter information.
    pub fn info(&self) -> io::Result<AdapterInfo> {
        let mut info = AdapterInfo::default();
        self.ioctl(abi::IOCTL_GET_INFO, &[], as_bytes_mut(&mut info))?;
        Ok(info)
    }

    /// Queries the driver's packet counters.
    pub fn statistics(&self) -> io::Result<Statistics> {
        let mut stats = Statistics::default();
        self.ioctl(abi::IOCTL_GET_STATISTICS, &[], as_bytes_mut(&mut stats))?;
        Ok(stats)
    }

    /// Tells the driver which offloads (`abi::OFFLOAD_*`) this consumer can handle.
    ///
    /// The driver renegotiates with the TCP/IP stack and returns the resulting
    /// configuration. Pass `0` to receive only plain, fully checksummed packets.
    /// The setting is per adapter and lasts until the adapter restarts.
    pub fn set_offloads(&self, offloads: u32) -> io::Result<AdapterInfo> {
        let mut info = AdapterInfo::default();
        self.ioctl(
            abi::IOCTL_SET_OFFLOADS,
            &offloads.to_le_bytes(),
            as_bytes_mut(&mut info),
        )?;
        Ok(info)
    }

    fn wait(&self, overlapped: &mut OVERLAPPED) -> io::Result<usize> {
        let mut transferred = 0u32;
        // SAFETY: `overlapped` belongs to an operation on this handle.
        if unsafe { GetOverlappedResult(self.raw(), overlapped, &mut transferred, 1) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(transferred as usize)
    }

    pub(crate) fn ioctl(&self, code: u32, input: &[u8], output: &mut [u8]) -> io::Result<usize> {
        let event = Event::new()?;
        let mut overlapped = event.overlapped();
        // SAFETY: All buffers outlive the call since we wait for completion.
        let ok = unsafe {
            DeviceIoControl(
                self.raw(),
                code,
                input.as_ptr() as *const c_void,
                input.len() as u32,
                output.as_mut_ptr() as *mut c_void,
                output.len() as u32,
                ptr::null_mut(),
                &mut overlapped,
            )
        };
        check_overlapped(ok)?;
        self.wait(&mut overlapped)
    }

    fn raw(&self) -> HANDLE {
        self.handle.as_raw_handle() as HANDLE
    }
}

impl AsRawHandle for Device {
    fn as_raw_handle(&self) -> RawHandle {
        self.handle.as_raw_handle()
    }
}

impl AsHandle for Device {
    fn as_handle(&self) -> BorrowedHandle<'_> {
        self.handle.as_handle()
    }
}

/// The Win32 path of the device for the adapter with the given `NET_LUID`.
pub fn device_path(luid: u64) -> String {
    format!("{}{luid:016X}", abi::USER_PATH_PREFIX)
}

fn check_overlapped(ok: i32) -> io::Result<()> {
    if ok != 0 {
        return Ok(());
    }
    let err = io::Error::last_os_error();
    if err.raw_os_error() == Some(ERROR_IO_PENDING as i32) {
        return Ok(());
    }
    Err(err)
}

fn as_bytes_mut<T: Copy>(value: &mut T) -> &mut [u8] {
    // SAFETY: Only used with plain-old-data `#[repr(C)]` types.
    unsafe { std::slice::from_raw_parts_mut(value as *mut T as *mut u8, size_of::<T>()) }
}

/// A manual-reset event for synchronous waits on overlapped operations.
struct Event(OwnedHandle);

impl Event {
    fn new() -> io::Result<Self> {
        // SAFETY: Plain FFI call.
        let handle = unsafe { CreateEventW(ptr::null(), 1, 0, ptr::null()) };
        if handle.is_null() {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: We own the new handle.
        Ok(Self(unsafe {
            OwnedHandle::from_raw_handle(handle as RawHandle)
        }))
    }

    fn overlapped(&self) -> OVERLAPPED {
        // SAFETY: OVERLAPPED is plain old data.
        let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
        // Setting the low-order bit keeps the completion from being queued to a
        // completion port the handle might be associated with.
        overlapped.hEvent = (self.0.as_raw_handle() as usize | 1) as HANDLE;
        overlapped
    }
}
