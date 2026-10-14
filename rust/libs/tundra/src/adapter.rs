//! Adapter lifecycle: driver installation, creating and removing adapters.
//!
//! Adapters are software devices created with `SwDeviceCreate`. By default their
//! lifetime is tied to the [`Adapter`] value (and therefore to the process): when it is
//! dropped or the process exits, Windows removes the adapter.
//!
//! All functions here require administrator privileges.

use std::ffi::c_void;
use std::io;
use std::os::windows::ffi::OsStrExt as _;
use std::path::Path;
use std::ptr;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use windows_sys::Win32::Devices::DeviceAndDriverInstallation::{
    CM_Get_DevNode_Status, CM_LOCATE_DEVNODE_NORMAL, CM_LOCATE_DEVNODE_PHANTOM, CM_Locate_DevNodeW,
    CM_Open_DevNode_Key, CM_PROB_DRIVER_FAILED_LOAD, CM_PROB_FAILED_ADD, CM_PROB_FAILED_START,
    CM_PROB_UNSIGNED_DRIVER, CM_REGISTRY_SOFTWARE, CR_SUCCESS, DN_HAS_PROBLEM, DiInstallDriverW,
    RegDisposition_OpenAlways, RegDisposition_OpenExisting,
};
use windows_sys::Win32::Devices::Enumeration::Pnp::{
    HSWDEVICE, SW_DEVICE_CREATE_INFO, SW_DEVICE_LIFETIME, SWDeviceCapabilitiesDriverRequired,
    SWDeviceCapabilitiesSilentInstall, SWDeviceLifetimeHandle, SWDeviceLifetimeParentPresent,
    SwDeviceClose, SwDeviceCreate, SwDeviceSetLifetime,
};
use windows_sys::Win32::Devices::Properties::{
    DEVPKEY_Device_ClassGuid, DEVPKEY_Device_DeviceDesc, DEVPKEY_Device_FriendlyName,
    DEVPROP_STORE_SYSTEM, DEVPROP_TYPE_GUID, DEVPROP_TYPE_STRING, DEVPROPCOMPKEY, DEVPROPERTY,
};
use windows_sys::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND};
use windows_sys::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryW};
use windows_sys::Win32::System::Registry::{
    HKEY, KEY_QUERY_VALUE, KEY_SET_VALUE, REG_BINARY, REG_DWORD, RegCloseKey, RegQueryValueExW,
    RegSetValueExW,
};
use windows_sys::core::{GUID, HRESULT, PCWSTR};

use crate::Device;

/// `{4D36E972-E325-11CE-BFC1-08002BE10318}`
const GUID_DEVCLASS_NET: GUID = GUID::from_u128(0x4d36e972_e325_11ce_bfc1_08002be10318);

/// How long to wait for PnP to install the driver and NDIS to start the adapter.
const START_TIMEOUT: Duration = Duration::from_secs(30);

/// Installs the driver package into the driver store (idempotent).
///
/// `inf` is the path to `tundra.inf`, next to `tundra.sys` and `tundra.cat`.
pub fn install_driver(inf: &Path) -> io::Result<()> {
    let inf = std::path::absolute(inf)?;
    let wide = wide(inf.as_os_str());
    let mut reboot = 0;
    // SAFETY: `wide` is NUL-terminated.
    if unsafe { DiInstallDriverW(ptr::null_mut(), wide.as_ptr(), 0, &mut reboot) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// A Tundra network adapter.
#[derive(Debug)]
pub struct Adapter {
    sw_device: HSWDEVICE,
    guid: u128,
    luid: u64,
    instance_id: String,
}

// SAFETY: `HSWDEVICE` is a handle that may be used from any thread.
unsafe impl Send for Adapter {}
// SAFETY: `Adapter` has no interior mutability.
unsafe impl Sync for Adapter {}

impl Adapter {
    /// Creates an adapter.
    ///
    /// * `name`: the connection name shown in `ncpa.cpl` / `Get-NetAdapter`.
    /// * `guid`: the interface GUID (`NetCfgInstanceId`). Reusing the same GUID keeps
    ///   the interface identity (firewall profile, network category, ...) stable.
    ///
    /// The driver must have been installed with [`install_driver`] beforehand.
    pub fn create(name: &str, guid_value: u128) -> io::Result<Self> {
        let guid = GUID::from_u128(guid_value);
        let instance_id = guid_string(&guid);
        let root = wide("HTREE\\ROOT\\0");
        let enumerator = wide(crate::abi::HWID);
        let instance_w = wide(&instance_id);
        let description = wide(format!("{name} Tunnel"));

        // Step 1: create a stub device without hardware IDs so that no driver binds yet,
        // and record the GUID we want NDIS to assign as `NetCfgInstanceId`.
        {
            let no_hwids: [u16; 2] = [0, 0];
            let info = SW_DEVICE_CREATE_INFO {
                cbSize: size_of::<SW_DEVICE_CREATE_INFO>() as u32,
                pszInstanceId: instance_w.as_ptr(),
                pszzHardwareIds: no_hwids.as_ptr(),
                pszzCompatibleIds: ptr::null(),
                pContainerId: ptr::null(),
                CapabilityFlags: (SWDeviceCapabilitiesSilentInstall
                    | SWDeviceCapabilitiesDriverRequired) as u32,
                pszDeviceDescription: description.as_ptr(),
                pszDeviceLocation: ptr::null(),
                pSecurityDescriptor: ptr::null(),
            };
            let props = [guid_property(&DEVPKEY_Device_ClassGuid, &GUID_DEVCLASS_NET)];
            let (stub, device_instance) = sw_device_create(&enumerator, &root, &info, &props)
                .map_err(|e| context(e, "failed to create stub device"))?;
            let result = set_suggested_instance_id(&device_instance, &guid);
            // SAFETY: `stub` is a valid handle from `SwDeviceCreate`.
            unsafe { SwDeviceClose(stub) };
            result.map_err(|e| context(e, "failed to set SuggestedInstanceId"))?;
        }

        // Step 2: create the real device.
        let hwids: Vec<u16> = wide(crate::abi::HWID).into_iter().chain([0]).collect();
        let info = SW_DEVICE_CREATE_INFO {
            cbSize: size_of::<SW_DEVICE_CREATE_INFO>() as u32,
            pszInstanceId: instance_w.as_ptr(),
            pszzHardwareIds: hwids.as_ptr(),
            pszzCompatibleIds: ptr::null(),
            pContainerId: ptr::null(),
            CapabilityFlags: (SWDeviceCapabilitiesSilentInstall
                | SWDeviceCapabilitiesDriverRequired) as u32,
            pszDeviceDescription: description.as_ptr(),
            pszDeviceLocation: ptr::null(),
            pSecurityDescriptor: ptr::null(),
        };
        let props = [
            string_property(&DEVPKEY_Device_FriendlyName, &description),
            string_property(&DEVPKEY_Device_DeviceDesc, &description),
        ];
        let (sw_device, device_instance) = sw_device_create(&enumerator, &root, &info, &props)
            .map_err(|e| context(e, "failed to create device"))?;
        let mut adapter = Self {
            sw_device,
            guid: guid_value,
            luid: 0,
            instance_id: device_instance,
        };

        adapter.luid = adapter.wait_for_luid()?;
        adapter
            .wait_for_device()
            .map_err(|e| context(e, "failed to open adapter device"))?;
        if let Err(e) = set_connection_name(&guid, name) {
            // Not fatal; the adapter just keeps its default name.
            let _ = e;
        }
        Ok(adapter)
    }

    /// Keeps the adapter after this value is dropped / the process exits.
    pub fn persist(&self) -> io::Result<()> {
        self.set_lifetime(SWDeviceLifetimeParentPresent)
    }

    /// The `NET_LUID` of the adapter, for use with the IP Helper API.
    pub fn luid(&self) -> u64 {
        self.luid
    }

    /// The interface GUID of the adapter.
    pub fn guid(&self) -> u128 {
        self.guid
    }

    /// The PnP device instance ID, e.g. `SWD\Tundra\{...}`.
    pub fn instance_id(&self) -> &str {
        &self.instance_id
    }

    /// Opens a handle for packet I/O. May be called any number of times.
    pub fn open(&self) -> io::Result<Device> {
        Device::open(self.luid)
    }

    fn set_lifetime(&self, lifetime: SW_DEVICE_LIFETIME) -> io::Result<()> {
        // SAFETY: `sw_device` is valid for the lifetime of `self`.
        hresult(unsafe { SwDeviceSetLifetime(self.sw_device, lifetime) })
    }

    fn wait_for_luid(&self) -> io::Result<u64> {
        let deadline = Instant::now() + START_TIMEOUT;
        loop {
            match read_luid(&self.instance_id) {
                Ok(luid) => return Ok(luid),
                Err(e) if Instant::now() >= deadline => {
                    return Err(io::Error::new(
                        e.kind(),
                        format!("adapter did not start: {e}"),
                    ));
                }
                Err(_) => std::thread::sleep(Duration::from_millis(50)),
            }
        }
    }

    fn wait_for_device(&self) -> io::Result<()> {
        let deadline = Instant::now() + START_TIMEOUT;
        loop {
            match Device::open(self.luid) {
                Ok(_) => return Ok(()),
                Err(e)
                    if Instant::now() < deadline
                        && matches!(e.raw_os_error(), Some(c) if c == ERROR_FILE_NOT_FOUND as i32 || c == ERROR_PATH_NOT_FOUND as i32) =>
                {
                    std::thread::sleep(Duration::from_millis(50))
                }
                Err(e) => return Err(e),
            }
            if let Some(problem) = device_problem(&self.instance_id) {
                return Err(io::Error::other(problem));
            }
        }
    }
}

/// Returns a description of a (non-transient) PnP problem the device is in, if any.
fn device_problem(instance_id: &str) -> Option<String> {
    let id = wide(instance_id);
    let mut devinst = 0u32;
    // SAFETY: `id` is NUL-terminated.
    if unsafe { CM_Locate_DevNodeW(&mut devinst, id.as_ptr(), CM_LOCATE_DEVNODE_NORMAL) }
        != CR_SUCCESS
    {
        return None;
    }
    let (mut status, mut problem) = (0u32, 0u32);
    // SAFETY: Out-pointers are valid.
    if unsafe { CM_Get_DevNode_Status(&mut status, &mut problem, devinst, 0) } != CR_SUCCESS
        || status & DN_HAS_PROBLEM == 0
    {
        return None;
    }
    let reason = match problem {
        CM_PROB_FAILED_START => "the driver failed to start (code 10)",
        CM_PROB_FAILED_ADD => "the driver failed to load (code 31)",
        CM_PROB_DRIVER_FAILED_LOAD => "the driver could not be loaded (code 39)",
        CM_PROB_UNSIGNED_DRIVER => {
            "the driver signature was rejected (code 52); is test signing enabled and active?"
        }
        _ => return None,
    };
    Some(format!("adapter {instance_id} did not start: {reason}"))
}

impl Drop for Adapter {
    fn drop(&mut self) {
        // SAFETY: `sw_device` is valid; closing it removes the device unless persisted.
        unsafe { SwDeviceClose(self.sw_device) };
    }
}

fn sw_device_create(
    enumerator: &[u16],
    parent: &[u16],
    info: &SW_DEVICE_CREATE_INFO,
    props: &[DEVPROPERTY],
) -> io::Result<(HSWDEVICE, String)> {
    unsafe extern "system" fn callback(
        _device: HSWDEVICE,
        result: HRESULT,
        context: *const c_void,
        instance_id: PCWSTR,
    ) {
        // SAFETY: `context` is the boxed sender leaked below; the callback runs once and
        // takes ownership of it, so it stays valid however late the callback runs.
        let tx = unsafe { Box::from_raw(context as *mut mpsc::Sender<(HRESULT, String)>) };
        let id = if instance_id.is_null() {
            String::new()
        } else {
            // SAFETY: `instance_id` is a NUL-terminated wide string.
            unsafe { from_wide_ptr(instance_id) }
        };
        let _ = tx.send((result, id));
    }

    let (tx, rx) = mpsc::channel::<(HRESULT, String)>();
    let context = Box::into_raw(Box::new(tx));
    let mut handle: HSWDEVICE = ptr::null_mut();
    // SAFETY: All pointers are valid for the duration of the call. The callback owns
    // `context` (see above).
    let hr = unsafe {
        SwDeviceCreate(
            enumerator.as_ptr(),
            parent.as_ptr(),
            info,
            props.len() as u32,
            props.as_ptr(),
            Some(callback),
            context as *const c_void,
            &mut handle,
        )
    };
    if hr < 0 {
        // The callback will never run, so reclaim its context.
        // SAFETY: `context` came from `Box::into_raw` above and was not handed off.
        drop(unsafe { Box::from_raw(context) });
        return hresult(hr).map(|()| unreachable!());
    }
    let result = rx.recv_timeout(START_TIMEOUT);
    let (hr, instance_id) = match result {
        Ok(r) => r,
        Err(_) => {
            // SAFETY: Valid handle; closing cancels the pending creation.
            unsafe { SwDeviceClose(handle) };
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "timed out creating software device",
            ));
        }
    };
    if let Err(e) = hresult(hr) {
        // SAFETY: Valid handle.
        unsafe { SwDeviceClose(handle) };
        return Err(e);
    }
    Ok((handle, instance_id))
}

fn open_driver_key(instance_id: &str, access: u32, create: bool) -> io::Result<HKEY> {
    let id = wide(instance_id);
    let mut devinst = 0u32;
    // SAFETY: `id` is NUL-terminated.
    let cr = unsafe { CM_Locate_DevNodeW(&mut devinst, id.as_ptr(), CM_LOCATE_DEVNODE_PHANTOM) };
    if cr != CR_SUCCESS {
        return Err(io::Error::other(format!("CM_Locate_DevNodeW failed: {cr}")));
    }
    let mut key: HKEY = ptr::null_mut();
    let disposition = if create {
        RegDisposition_OpenAlways
    } else {
        RegDisposition_OpenExisting
    };
    // SAFETY: Out-pointer is valid.
    let cr = unsafe {
        CM_Open_DevNode_Key(
            devinst,
            access,
            0,
            disposition,
            &mut key,
            CM_REGISTRY_SOFTWARE,
        )
    };
    if cr != CR_SUCCESS {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("CM_Open_DevNode_Key failed: {cr}"),
        ));
    }
    Ok(key)
}

fn set_suggested_instance_id(instance_id: &str, guid: &GUID) -> io::Result<()> {
    let key = open_driver_key(instance_id, KEY_SET_VALUE, true)?;
    let name = wide("SuggestedInstanceId");
    // SAFETY: Valid key and buffers.
    let status = unsafe {
        RegSetValueExW(
            key,
            name.as_ptr(),
            0,
            REG_BINARY,
            guid as *const GUID as *const u8,
            size_of::<GUID>() as u32,
        )
    };
    // SAFETY: Valid key.
    unsafe { RegCloseKey(key) };
    if status != 0 {
        return Err(io::Error::from_raw_os_error(status as i32));
    }
    Ok(())
}

fn read_luid(instance_id: &str) -> io::Result<u64> {
    let key = open_driver_key(instance_id, KEY_QUERY_VALUE, false)?;
    let index = query_dword(key, "NetLuidIndex");
    let if_type = query_dword(key, "*IfType");
    // SAFETY: Valid key.
    unsafe { RegCloseKey(key) };
    let (index, if_type) = (index?, if_type?);
    Ok(((index as u64 & 0xFF_FFFF) << 24) | ((if_type as u64 & 0xFFFF) << 48))
}

fn query_dword(key: HKEY, name: &str) -> io::Result<u32> {
    let name = wide(name);
    let mut value = 0u32;
    let mut ty = 0u32;
    let mut len = size_of::<u32>() as u32;
    // SAFETY: Valid key and buffers.
    let status = unsafe {
        RegQueryValueExW(
            key,
            name.as_ptr(),
            ptr::null(),
            &mut ty,
            &mut value as *mut u32 as *mut u8,
            &mut len,
        )
    };
    if status != 0 {
        return Err(io::Error::from_raw_os_error(status as i32));
    }
    if ty != REG_DWORD {
        return Err(io::Error::other("unexpected registry value type"));
    }
    Ok(value)
}

/// Sets the connection name via the (undocumented, but long stable) `NciSetConnectionName`.
fn set_connection_name(guid: &GUID, name: &str) -> io::Result<()> {
    type NciSetConnectionName = unsafe extern "system" fn(*const GUID, PCWSTR) -> u32;
    let dll = wide("nci.dll");
    // SAFETY: Loading a system DLL by name.
    let module = unsafe { LoadLibraryW(dll.as_ptr()) };
    if module.is_null() {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: Valid module; the symbol name is NUL-terminated.
    let Some(func) =
        (unsafe { GetProcAddress(module, c"NciSetConnectionName".as_ptr() as *const u8) })
    else {
        return Err(io::Error::last_os_error());
    };
    // SAFETY: The function has this signature.
    let func: NciSetConnectionName = unsafe { std::mem::transmute(func) };
    let name = wide(name);
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        // SAFETY: Valid pointers.
        let status = unsafe { func(guid, name.as_ptr()) };
        if status == 0 {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(io::Error::from_raw_os_error(status as i32));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn guid_property(
    key: &'static windows_sys::Win32::Foundation::DEVPROPKEY,
    guid: &'static GUID,
) -> DEVPROPERTY {
    DEVPROPERTY {
        CompKey: DEVPROPCOMPKEY {
            Key: *key,
            Store: DEVPROP_STORE_SYSTEM,
            LocaleName: ptr::null(),
        },
        Type: DEVPROP_TYPE_GUID,
        BufferSize: size_of::<GUID>() as u32,
        Buffer: guid as *const GUID as *mut c_void,
    }
}

fn string_property(
    key: &'static windows_sys::Win32::Foundation::DEVPROPKEY,
    value: &[u16],
) -> DEVPROPERTY {
    DEVPROPERTY {
        CompKey: DEVPROPCOMPKEY {
            Key: *key,
            Store: DEVPROP_STORE_SYSTEM,
            LocaleName: ptr::null(),
        },
        Type: DEVPROP_TYPE_STRING,
        BufferSize: (value.len() * 2) as u32,
        Buffer: value.as_ptr() as *mut c_void,
    }
}

fn guid_string(g: &GUID) -> String {
    format!(
        "{{{:08X}-{:04X}-{:04X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}}}",
        g.data1,
        g.data2,
        g.data3,
        g.data4[0],
        g.data4[1],
        g.data4[2],
        g.data4[3],
        g.data4[4],
        g.data4[5],
        g.data4[6],
        g.data4[7]
    )
}

fn context(e: io::Error, what: &str) -> io::Error {
    io::Error::new(e.kind(), format!("{what}: {e}"))
}

fn hresult(hr: HRESULT) -> io::Result<()> {
    if hr >= 0 {
        Ok(())
    } else {
        Err(io::Error::from_raw_os_error(hr))
    }
}

fn wide(s: impl AsRef<std::ffi::OsStr>) -> Vec<u16> {
    s.as_ref().encode_wide().chain([0]).collect()
}

/// # Safety
///
/// `p` must point to a NUL-terminated wide string.
unsafe fn from_wide_ptr(p: *const u16) -> String {
    let mut len = 0;
    // SAFETY: Upheld by the caller.
    while unsafe { *p.add(len) } != 0 {
        len += 1;
    }
    // SAFETY: `len` elements are valid.
    String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(p, len) })
}

#[allow(dead_code)]
const _: SW_DEVICE_LIFETIME = SWDeviceLifetimeHandle;
