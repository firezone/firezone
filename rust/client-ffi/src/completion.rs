//! C packet I/O ABI for a serial host event loop.
//!
//! Session calls require exclusive access and valid pointers. Input leases are
//! consumed even on errors. Output storage is released independently of send
//! completion and may outlive the session. No packet bytes use UniFFI serialization.

use anyhow::Result;
use client_shared::completion::{
    CompletionPort, DrivenEvents, Operation, Payload, ReceivedDatagram,
};
use ip_packet::{Ecn, IpPacket, IpPacketBuf};
use std::{
    ffi::{CStr, CString, c_char, c_void},
    net::{SocketAddr, SocketAddrV6},
    panic::{AssertUnwindSafe, catch_unwind},
    ptr,
};

pub struct CompletionSession {
    host: Host,
    error: CString,
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

struct Host {
    events: DrivenEvents,
    port: CompletionPort,
    output: Option<tokio::sync::mpsc::UnboundedSender<client_shared::Event>>,
    closed: bool,
    runtime: tokio::runtime::Runtime,
}

impl CompletionSession {
    #[cfg(target_vendor = "apple")]
    pub(crate) fn create_driver(
        runtime: tokio::runtime::Runtime,
        events: DrivenEvents,
        port: CompletionPort,
    ) -> (
        u64,
        tokio::sync::mpsc::UnboundedReceiver<client_shared::Event>,
    ) {
        let (output, receiver) = tokio::sync::mpsc::unbounded_channel();
        let driver = Box::new(Self {
            host: Host {
                events,
                port,
                output: Some(output),
                closed: false,
                runtime,
            },
            error: CString::default(),
        });
        (Box::into_raw(driver) as usize as u64, receiver)
    }
}

impl Host {
    fn poll(&mut self) {
        if self.closed {
            return;
        }
        let events = &mut self.events;
        let output = &mut self.output;
        let closed = &mut self.closed;
        self.runtime.block_on(async {
            tokio::task::yield_now().await;
            std::future::poll_fn(|cx| {
                for _ in 0..128 {
                    match events.poll_next(cx) {
                        std::task::Poll::Ready(Some(event)) => {
                            if let Some(output) = output.as_ref() {
                                let _ = output.send(event);
                            }
                        }
                        std::task::Poll::Ready(None) => {
                            *closed = true;
                            output.take();
                            break;
                        }
                        std::task::Poll::Pending => break,
                    }
                }
                std::task::Poll::Ready(())
            })
            .await;
            tokio::task::yield_now().await;
        });
    }
}

#[unsafe(no_mangle)]
pub(crate) unsafe extern "C" fn fz_completion_free(session: *mut CompletionSession) {
    if session.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(session));
    }
}

#[unsafe(no_mangle)]
pub(crate) unsafe extern "C" fn fz_completion_poll(session: *mut CompletionSession) -> i32 {
    unsafe {
        call(session, |session| {
            session.host.poll();
            Ok(if session.host.closed { 2 } else { 0 })
        })
    }
}

#[unsafe(no_mangle)]
pub(crate) unsafe extern "C" fn fz_completion_error(
    session: *const CompletionSession,
) -> *const c_char {
    if session.is_null() {
        return ptr::null();
    }
    unsafe { &*session }.error.as_ptr()
}

#[unsafe(no_mangle)]
pub(crate) unsafe extern "C" fn fz_completion_receive_ready(
    session: *mut CompletionSession,
    network: bool,
) -> i32 {
    unsafe {
        call(session, |session| {
            let mut cx = std::task::Context::from_waker(futures::task::noop_waker_ref());
            Ok(
                if session
                    .host
                    .port
                    .poll_receive_ready(&mut cx, network)
                    .is_ready()
                {
                    0
                } else {
                    1
                },
            )
        })
    }
}

#[unsafe(no_mangle)]
pub(crate) unsafe extern "C" fn fz_completion_receive_network(
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
pub(crate) unsafe extern "C" fn fz_completion_receive_tun(
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
            for packet in std::slice::from_raw_parts(packets, count) {
                if packet.data.is_null() || packet.len == 0 {
                    continue;
                }
                let mut buffer = IpPacketBuf::new();
                if packet.len > buffer.buf().len() {
                    continue;
                }
                let bytes = std::slice::from_raw_parts(packet.data, packet.len);
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
pub(crate) unsafe extern "C" fn fz_completion_next_operation(
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
            Ok(0)
        })
    }
}

#[unsafe(no_mangle)]
pub(crate) unsafe extern "C" fn fz_completion_packet(
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
pub(crate) unsafe extern "C" fn fz_completion_buffer_free(buffer: *mut BufferLease) {
    if !buffer.is_null() {
        unsafe {
            drop(Box::from_raw(buffer));
        }
    }
}

#[unsafe(no_mangle)]
pub(crate) unsafe extern "C" fn fz_completion_complete(
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
pub(crate) unsafe extern "C" fn fz_completion_endpoint_parse(
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
    let (ip, scope) = address.split_once('%').unwrap_or((address, ""));
    let Ok(ip) = ip.parse::<std::net::IpAddr>() else {
        return -1;
    };
    let scope = if scope.is_empty() {
        0
    } else if let Ok(index) = scope.parse::<u32>() {
        index
    } else {
        #[cfg(unix)]
        {
            let Ok(name) = CString::new(scope) else {
                return -1;
            };
            let index = unsafe { libc::if_nametoindex(name.as_ptr()) };
            if index == 0 {
                return -1;
            }
            index
        }
        #[cfg(not(unix))]
        {
            return -1;
        }
    };
    let socket = match ip {
        std::net::IpAddr::V4(ip) if scope == 0 => SocketAddr::new(ip.into(), port),
        std::net::IpAddr::V4(_) => return -1,
        std::net::IpAddr::V6(ip) => SocketAddr::V6(SocketAddrV6::new(ip, port, 0, scope)),
    };
    unsafe {
        *output = Endpoint::from(socket);
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn rejected_foreign_input_releases_its_lease() {
        let released = Cell::new(0usize);
        let status = unsafe {
            fz_completion_receive_network(
                ptr::null_mut(),
                0,
                [42].as_ptr(),
                1,
                Endpoint::default(),
                Endpoint::default(),
                0,
                &released as *const Cell<usize> as *mut c_void,
                release_counter,
            )
        };
        assert_eq!(status, -1);
        assert_eq!(released.get(), 1);
    }

    #[test]
    fn output_segments_borrow_the_pool_buffer_until_release() {
        let pool = bufferpool::BufferPool::<Vec<u8>>::new(5, "test-ffi-lease");
        let mut packet = pool.pull();
        packet.clear();
        packet.extend([1, 1, 2, 2, 3]);
        let original = packet.as_ptr();
        let lease = Box::into_raw(Box::new(BufferLease(Payload::Network(
            socket_factory::DatagramOut {
                src: None,
                dst: "127.0.0.1:1234".parse().unwrap(),
                packet,
                segment_size: 2,
                ecn: Ecn::NonEct,
            },
        ))));
        let mut output = ByteSlice {
            data: ptr::null(),
            len: 0,
        };
        for (index, expected) in [&[1, 1][..], &[2, 2][..], &[3][..]].into_iter().enumerate() {
            assert_eq!(
                unsafe { fz_completion_packet(lease, index, &mut output) },
                0
            );
            assert_eq!(output.data, unsafe { original.add(index * 2) });
            assert_eq!(
                unsafe { std::slice::from_raw_parts(output.data, output.len) },
                expected
            );
        }
        assert_eq!(unsafe { fz_completion_packet(lease, 3, &mut output) }, -1);
        let address = lease as usize;
        std::thread::spawn(move || unsafe {
            fz_completion_buffer_free(address as *mut BufferLease)
        })
        .join()
        .unwrap();
        assert_eq!(pool.pull().as_ptr(), original);
    }

    #[test]
    fn scoped_ipv6_endpoint_roundtrips() {
        let address = c"fe80::1234%7";
        let mut endpoint = Endpoint::default();
        assert_eq!(
            unsafe { fz_completion_endpoint_parse(address.as_ptr(), 52625, &mut endpoint) },
            0
        );
        assert_eq!(
            endpoint.socket().unwrap(),
            "[fe80::1234%7]:52625".parse().unwrap()
        );
    }

    unsafe extern "C" fn release_counter(context: *mut c_void) {
        let counter = unsafe { &*context.cast::<Cell<usize>>() };
        counter.set(counter.get() + 1);
    }
}
