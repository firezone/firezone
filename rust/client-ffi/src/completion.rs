//! C packet I/O ABI for a serial host event loop.
//!
//! Session calls require exclusive access and valid pointers. Input leases are
//! consumed even on errors. Output storage is released independently of send
//! completion and may outlive the session. No packet bytes use UniFFI serialization.

use anyhow::Result;
use completion_io::{
    Operation, Payload, ReceivedDatagram,
    host::{Config, Host},
};
use ip_packet::{Ecn, IpPacket, IpPacketBuf};
use std::{
    collections::VecDeque,
    ffi::{CStr, CString, c_char, c_void},
    net::{SocketAddr, SocketAddrV6},
    panic::{AssertUnwindSafe, catch_unwind},
    ptr,
};

pub struct CompletionSession {
    host: Host,
    error: CString,
    events: VecDeque<CString>,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Endpoint {
    pub address: [u8; 16],
    pub port: u16,
    pub family: u8,
    pub scope_id: u32,
}

#[repr(C)]
pub struct ByteSlice {
    pub data: *const u8,
    pub len: usize,
}

#[repr(C)]
pub struct PacketOperation {
    pub id: u64,
    pub generation: u64,
    pub kind: u32,
    pub buffer: *mut BufferLease,
    pub packets: usize,
    pub segment_size: usize,
    pub local: Endpoint,
    pub remote: Endpoint,
    pub ecn: u8,
}

pub struct BufferLease(Payload);

struct BorrowedPacket {
    bytes: *const u8,
    len: usize,
    context: *mut c_void,
    release: unsafe extern "C" fn(*mut c_void),
}

impl AsRef<[u8]> for BorrowedPacket {
    fn as_ref(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts(self.bytes, self.len) }
    }
}
impl Drop for BorrowedPacket {
    fn drop(&mut self) {
        unsafe { (self.release)(self.context) };
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fz_completion_new(
    config: *const c_char,
    error: *mut *mut c_char,
) -> *mut CompletionSession {
    let result = catch_unwind(AssertUnwindSafe(|| {
        anyhow::ensure!(!config.is_null(), "Missing configuration");
        let config =
            serde_json::from_slice::<Config>(unsafe { CStr::from_ptr(config) }.to_bytes())?;
        let host = Host::new(config)?;
        anyhow::Ok(Box::into_raw(Box::new(CompletionSession {
            host,
            error: CString::default(),
            events: VecDeque::new(),
        })))
    }));
    match result {
        Ok(Ok(session)) => session,
        Ok(Err(failure)) => {
            if !error.is_null() {
                unsafe { *error = cstring(failure.to_string()).into_raw() };
            }
            ptr::null_mut()
        }
        Err(_) => {
            if !error.is_null() {
                unsafe { *error = cstring("Rust driver panicked".into()).into_raw() };
            }
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fz_completion_free(session: *mut CompletionSession) {
    if session.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(session));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fz_completion_poll(session: *mut CompletionSession) -> i32 {
    unsafe {
        call(session, |session| {
            session.host.poll()?;
            while let Some(event) = session.host.next_event() {
                session.events.push_back(cstring(event.to_string()));
            }
            Ok(if session.host.closed { 2 } else { 0 })
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fz_completion_next_event(session: *mut CompletionSession) -> *mut c_char {
    if session.is_null() {
        return ptr::null_mut();
    }
    unsafe { &mut *session }
        .events
        .pop_front()
        .map(CString::into_raw)
        .unwrap_or(ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fz_completion_error(session: *const CompletionSession) -> *const c_char {
    if session.is_null() {
        return ptr::null();
    }
    unsafe { &*session }.error.as_ptr()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fz_completion_string_free(string: *mut c_char) {
    if !string.is_null() {
        unsafe {
            drop(CString::from_raw(string));
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fz_completion_receive_network(
    session: *mut CompletionSession,
    generation: u64,
    bytes: *const u8,
    len: usize,
    local: Endpoint,
    remote: Endpoint,
    ecn: u8,
    context: *mut c_void,
    release: unsafe extern "C" fn(*mut c_void),
) -> i32 {
    let storage = BorrowedPacket {
        bytes,
        len,
        context,
        release,
    };
    unsafe {
        call(session, |session| {
            anyhow::ensure!(
                !bytes.is_null() && len > 0 && len <= u16::MAX as usize,
                "Invalid UDP buffer"
            );
            session.host.port.receive_network(
                generation,
                ReceivedDatagram {
                    storage: Box::new(storage),
                    local: local.socket()?,
                    from: remote.socket()?,
                    stride: len,
                    ecn: parse_ecn(ecn)?,
                },
            )?;
            Ok(0)
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fz_completion_receive_tun(
    session: *mut CompletionSession,
    generation: u64,
    packets: *const ByteSlice,
    count: usize,
) -> i32 {
    unsafe {
        call(session, |session| {
            anyhow::ensure!(count <= tun::MAX_BATCH_SIZE, "TUN batch exceeds capacity");
            anyhow::ensure!(!packets.is_null() || count == 0, "Missing TUN batch");
            if count == 0 {
                return Ok(0);
            }
            let mut batch = tun::PacketBatch::default();
            for packet in unsafe { std::slice::from_raw_parts(packets, count) } {
                if packet.data.is_null() || packet.len == 0 {
                    continue;
                }
                let mut buffer = IpPacketBuf::new();
                if packet.len > buffer.buf().len() {
                    continue;
                }
                let bytes = unsafe { std::slice::from_raw_parts(packet.data, packet.len) };
                buffer.buf()[..bytes.len()].copy_from_slice(bytes);
                let Ok(packet) = IpPacket::new(buffer, bytes.len()) else {
                    continue;
                };
                if batch.try_push(packet).is_err() {
                    unreachable!();
                }
            }
            if !batch.is_empty() {
                session.host.port.receive_tun(generation, batch)?;
            }
            Ok(0)
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fz_completion_next_operation(
    session: *mut CompletionSession,
    output: *mut PacketOperation,
) -> i32 {
    unsafe {
        call(session, |session| {
            anyhow::ensure!(!output.is_null(), "Missing operation output");
            let mut cx = std::task::Context::from_waker(futures::task::noop_waker_ref());
            let std::task::Poll::Ready(Some(Operation {
                id,
                generation,
                payload,
            })) = session.host.port.poll_operation(&mut cx)
            else {
                return Ok(1);
            };
            let (kind, packets, segment_size, local, remote, ecn) = match &payload {
                Payload::Network(datagram) => (
                    1,
                    datagram.packet.len().div_ceil(datagram.segment_size),
                    datagram.segment_size,
                    datagram.src.map(Endpoint::from).unwrap_or_default(),
                    Endpoint::from(datagram.dst),
                    datagram.ecn as u8,
                ),
                Payload::Tun(batch) => (
                    2,
                    batch.len(),
                    0,
                    Endpoint::default(),
                    Endpoint::default(),
                    0,
                ),
                Payload::Rebind => (3, 0, 0, Endpoint::default(), Endpoint::default(), 0),
            };
            let buffer = Box::into_raw(Box::new(BufferLease(payload)));
            unsafe {
                *output = PacketOperation {
                    id,
                    generation,
                    kind,
                    buffer,
                    packets,
                    segment_size,
                    local,
                    remote,
                    ecn,
                };
            }
            Ok(0)
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fz_completion_packet(
    buffer: *const BufferLease,
    index: usize,
    output: *mut ByteSlice,
) -> i32 {
    if buffer.is_null() || output.is_null() {
        return -1;
    }
    let bytes = match &unsafe { &*buffer }.0 {
        Payload::Network(datagram) => {
            let Some(offset) = index.checked_mul(datagram.segment_size) else {
                return -1;
            };
            if offset >= datagram.packet.len() {
                return -1;
            }
            &datagram.packet[offset..(offset + datagram.segment_size).min(datagram.packet.len())]
        }
        Payload::Tun(batch) => {
            let Some(packet) = batch.get(index) else {
                return -1;
            };
            packet.packet()
        }
        Payload::Rebind => return -1,
    };
    unsafe {
        *output = ByteSlice {
            data: bytes.as_ptr(),
            len: bytes.len(),
        };
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fz_completion_buffer_free(buffer: *mut BufferLease) {
    if !buffer.is_null() {
        unsafe {
            drop(Box::from_raw(buffer));
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fz_completion_complete(
    session: *mut CompletionSession,
    id: u64,
    status: i32,
) -> i32 {
    unsafe {
        call(session, |session| {
            let result = if status == 0 {
                Ok(())
            } else {
                Err(anyhow::anyhow!("Host packet I/O failed ({status})"))
            };
            session.host.port.complete(id, result)?;
            Ok(0)
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fz_completion_set_dns(
    session: *mut CompletionSession,
    json: *const c_char,
) -> i32 {
    unsafe {
        call(session, |session| {
            anyhow::ensure!(!json.is_null(), "Missing resolvers");
            session.host.session.set_dns(serde_json::from_slice(
                unsafe { CStr::from_ptr(json) }.to_bytes(),
            )?);
            Ok(0)
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fz_completion_reset(session: *mut CompletionSession) -> i32 {
    unsafe {
        call(session, |session| {
            session.host.session.reset("host network changed".into());
            Ok(0)
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fz_completion_stop(session: *mut CompletionSession) -> i32 {
    unsafe {
        call(session, |session| {
            session.host.session.stop();
            Ok(0)
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fz_completion_set_internet_resource(
    session: *mut CompletionSession,
    active: bool,
) -> i32 {
    unsafe {
        call(session, |session| {
            session.host.session.set_internet_resource_state(active);
            Ok(0)
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fz_completion_endpoint_parse(
    address: *const c_char,
    port: u16,
    output: *mut Endpoint,
) -> i32 {
    if address.is_null() || output.is_null() {
        return -1;
    }
    let Ok(address) = unsafe { CStr::from_ptr(address) }.to_str() else {
        return -1;
    };
    let Ok(ip) = address.parse() else {
        return -1;
    };
    unsafe {
        *output = Endpoint::from(SocketAddr::new(ip, port));
    }
    0
}

unsafe fn call(
    session: *mut CompletionSession,
    action: impl FnOnce(&mut CompletionSession) -> Result<i32>,
) -> i32 {
    if session.is_null() {
        return -1;
    }
    let session = unsafe { &mut *session };
    match catch_unwind(AssertUnwindSafe(|| action(session))) {
        Ok(Ok(status)) => status,
        Ok(Err(error)) => {
            session.error = cstring(error.to_string());
            -1
        }
        Err(_) => {
            session.error = cstring("Rust driver panicked; discard session".into());
            -2
        }
    }
}

fn cstring(value: String) -> CString {
    CString::new(value.replace('\0', "")).expect("NULs removed")
}

fn parse_ecn(value: u8) -> Result<Ecn> {
    let ecn = match value {
        0 => Ecn::NonEct,
        1 => Ecn::Ect1,
        2 => Ecn::Ect0,
        3 => Ecn::Ce,
        _ => anyhow::bail!("Invalid ECN codepoint"),
    };
    Ok(ecn)
}

impl Endpoint {
    fn socket(self) -> Result<SocketAddr> {
        let socket = match self.family {
            4 => SocketAddr::new(
                std::net::Ipv4Addr::new(
                    self.address[0],
                    self.address[1],
                    self.address[2],
                    self.address[3],
                )
                .into(),
                self.port,
            ),
            6 => SocketAddr::V6(SocketAddrV6::new(
                std::net::Ipv6Addr::from(self.address),
                self.port,
                0,
                self.scope_id,
            )),
            _ => anyhow::bail!("Invalid address family"),
        };
        Ok(socket)
    }
}

impl From<SocketAddr> for Endpoint {
    fn from(socket: SocketAddr) -> Self {
        let mut result = Self {
            port: socket.port(),
            ..Default::default()
        };
        match socket {
            SocketAddr::V4(socket) => {
                result.family = 4;
                result.address[..4].copy_from_slice(&socket.ip().octets());
            }
            SocketAddr::V6(socket) => {
                result.family = 6;
                result.address = socket.ip().octets();
                result.scope_id = socket.scope_id();
            }
        }
        result
    }
}
