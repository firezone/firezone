//! Packet I/O through the shared rings of a session.
//!
//! See the "I/O model" section of `include/tundra.h` for the protocol. In short: the
//! driver copies every packet the OS sends into the *transmit* ring, and copies packets
//! we put into the *receive* ring out to the OS. While there is traffic, neither side
//! makes a system call; events are only signalled at idle <-> busy transitions.

use std::ffi::c_void;
use std::future::poll_fn;
use std::io;
use std::os::windows::io::{AsRawHandle as _, FromRawHandle as _, OwnedHandle, RawHandle};
use std::ptr::{self, NonNull};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};

use windows_sys::Win32::Foundation::{HANDLE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::System::Memory::{
    MEM_COMMIT, MEM_RELEASE, MEM_RESERVE, PAGE_READWRITE, VirtualAlloc, VirtualFree,
};
use windows_sys::Win32::System::Threading::{
    CreateEventW, INFINITE, RegisterWaitForSingleObject, SetEvent, UnregisterWaitEx,
    WT_EXECUTEINWAITTHREAD,
};

use crate::abi::{self, AdapterInfo, HEADER_LEN, PacketHeader, RingHeader, Statistics};
use crate::{Device, Packet, PacketMut};

/// Ring sizes of a [`Session`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SessionConfig {
    /// Bytes of packets (OS -> user) the driver can buffer before it starts dropping.
    pub transmit_capacity: usize,
    /// Bytes of packets (user -> OS) we can queue before [`Sender::poll_send_ready`] waits.
    pub receive_capacity: usize,
}

impl Default for SessionConfig {
    fn default() -> Self {
        Self {
            transmit_capacity: 4 * 1024 * 1024,
            receive_capacity: 4 * 1024 * 1024,
        }
    }
}

/// An adapter's packet interface: the two shared rings plus their notifications.
///
/// The [`Receiver`] gets the packets the OS sends, the [`Sender`] hands packets to the
/// OS. Both can be borrowed at the same time with [`Session::split`], e.g. to forward
/// packets from one ring to the other without an intermediate copy, or moved to
/// different threads with [`Session::into_split`].
///
/// The `poll_*` methods work with any async runtime: wakeups come from the Windows
/// thread pool waiting on the driver's events, without a thread of our own. A blocking
/// user can drive them with any `block_on`.
///
/// Dropping the session (or both halves) ends it: the adapter's link goes down and
/// packets the OS sends are dropped until a new session starts.
#[derive(Debug)]
pub struct Session {
    shared: Arc<Shared>,
    receiver: Receiver,
    sender: Sender,
}

/// What both halves need to keep alive.
#[derive(Debug)]
struct Shared {
    // Field order matters: closing the handle ends the session in the driver, which
    // unlocks the ring memory, so it must happen before the rings are freed.
    device: Device,
    _transmit: RingMemory,
    _receive: RingMemory,
}

impl Session {
    /// Starts a session on `device`. An adapter has at most one session at a time.
    pub fn start(device: Device, config: SessionConfig) -> io::Result<Self> {
        let (transmit, transmit_memory) = Ring::new(config.transmit_capacity)?;
        let (receive, receive_memory) = Ring::new(config.receive_capacity)?;
        let transmit_data = event()?;
        let receive_data = event()?;
        let receive_space = event()?;

        let params = abi::SessionParameters {
            transmit_ring: transmit.header.as_ptr() as u64,
            receive_ring: receive.header.as_ptr() as u64,
            transmit_capacity: transmit.capacity,
            receive_capacity: receive.capacity,
            transmit_data_event: transmit_data.as_raw_handle() as u64,
            receive_data_event: receive_data.as_raw_handle() as u64,
            receive_space_event: receive_space.as_raw_handle() as u64,
        };
        // SAFETY: `SessionParameters` is plain old data.
        let input = unsafe {
            std::slice::from_raw_parts(
                &params as *const _ as *const u8,
                size_of::<abi::SessionParameters>(),
            )
        };
        let transmit_data = Wakeup::new(transmit_data)?;
        let receive_space = Wakeup::new(receive_space)?;
        // Last: from here on the driver uses the rings, so they must outlive the handle.
        device.ioctl(abi::IOCTL_START_SESSION, input, &mut [])?;

        let shared = Arc::new(Shared {
            device,
            _transmit: transmit_memory,
            _receive: receive_memory,
        });
        Ok(Self {
            receiver: Receiver {
                ring: transmit,
                data: transmit_data,
                head: 0,
                waiting: false,
                _shared: shared.clone(),
            },
            sender: Sender {
                ring: receive,
                data: receive_data,
                space: receive_space,
                tail: 0,
                waiting: false,
                _shared: shared.clone(),
            },
            shared,
        })
    }

    /// See [`Device::info`].
    pub fn info(&self) -> io::Result<AdapterInfo> {
        self.shared.device.info()
    }

    /// See [`Device::statistics`].
    pub fn statistics(&self) -> io::Result<Statistics> {
        self.shared.device.statistics()
    }

    /// See [`Device::set_offloads`].
    pub fn set_offloads(&self, offloads: u32) -> io::Result<AdapterInfo> {
        self.shared.device.set_offloads(offloads)
    }

    /// Separates the two directions, e.g. to drive them from different threads. The
    /// session ends when both are dropped.
    pub fn into_split(self) -> (Receiver, Sender) {
        (self.receiver, self.sender)
    }

    /// Packets from the OS.
    pub fn receiver(&mut self) -> &mut Receiver {
        &mut self.receiver
    }

    /// Packets to the OS.
    pub fn sender(&mut self) -> &mut Sender {
        &mut self.sender
    }

    /// Both directions at once.
    pub fn split(&mut self) -> (&mut Receiver, &mut Sender) {
        (&mut self.receiver, &mut self.sender)
    }
}

/// The OS -> user direction of a [`Session`] (the adapter's transmit ring).
#[derive(Debug)]
pub struct Receiver {
    ring: Ring,
    data: Wakeup,
    /// Our consumer position.
    head: u32,
    waiting: bool,
    _shared: Arc<Shared>,
}

// SAFETY: The ring memory is owned by us; all access to it requires `&mut self` and the
// shared header fields are atomics.
unsafe impl Send for Receiver {}
// SAFETY: There are no `&self` methods that touch the ring.
unsafe impl Sync for Receiver {}

impl Receiver {
    /// Returns all packets the OS has sent since the last call, without waiting.
    pub fn try_recv(&mut self) -> io::Result<Option<RecvBatch<'_>>> {
        let tail = self.ring.load_offset(&self.ring.header().tail)?;
        if tail == self.head {
            return Ok(None);
        }
        Ok(Some(RecvBatch {
            ring: &self.ring,
            head: &mut self.head,
            end: tail,
        }))
    }

    /// Polls until [`Receiver::try_recv`] has packets.
    ///
    /// Fails once the adapter is gone and every packet it sent has been received.
    pub fn poll_recv_ready(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let header = self.ring.header();
        let head = self.head;
        if self.ring.load_offset(&header.tail)? == head {
            if header.producer_closed.load(Ordering::Acquire) != 0 {
                return Poll::Ready(Err(closed()));
            }
            self.data.slot.register(cx.waker());
            // Must be visible to the driver before we re-read Tail.
            header.consumer_waiting.swap(1, Ordering::SeqCst);
            self.waiting = true;
            if self.ring.load_offset(&header.tail)? == head {
                if header.producer_closed.load(Ordering::Acquire) != 0 {
                    return Poll::Ready(Err(closed()));
                }
                return Poll::Pending;
            }
        }
        if self.waiting {
            header.consumer_waiting.store(0, Ordering::Relaxed);
            self.waiting = false;
        }
        Poll::Ready(Ok(()))
    }

    /// Like [`Receiver::try_recv`] but returns [`Poll::Pending`] instead of `None`.
    pub fn poll_recv(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<RecvBatch<'_>>> {
        match self.poll_recv_ready(cx) {
            Poll::Ready(Ok(())) => {
                Poll::Ready(self.try_recv().map(|batch| batch.expect(NON_EMPTY)))
            }
            Poll::Ready(Err(e)) => Poll::Ready(Err(e)),
            Poll::Pending => Poll::Pending,
        }
    }

    /// Waits for packets from the OS.
    pub async fn recv(&mut self) -> io::Result<RecvBatch<'_>> {
        poll_fn(|cx| self.poll_recv_ready(cx)).await?;
        Ok(self.try_recv()?.expect(NON_EMPTY))
    }
}

const NON_EMPTY: &str = "we are the only consumer, so the ring is still non-empty";

/// The user -> OS direction of a [`Session`] (the adapter's receive ring).
#[derive(Debug)]
pub struct Sender {
    ring: Ring,
    data: OwnedHandle,
    space: Wakeup,
    /// Our producer position.
    tail: u32,
    waiting: bool,
    _shared: Arc<Shared>,
}

// SAFETY: As for `Receiver`.
unsafe impl Send for Sender {}
// SAFETY: As for `Receiver`.
unsafe impl Sync for Sender {}

impl Sender {
    /// Polls until a packet of `len` bytes fits into the ring.
    ///
    /// Fails once the adapter is gone.
    pub fn poll_send_ready(&mut self, cx: &mut Context<'_>, len: usize) -> Poll<io::Result<()>> {
        let size = entry_size(len) as u32;
        let header = self.ring.header();
        if header.consumer_closed.load(Ordering::Acquire) != 0 {
            return Poll::Ready(Err(closed()));
        }
        if size > self.ring.free(self.tail)? {
            self.space.slot.register(cx.waker());
            // Must be visible to the driver before we re-read Head.
            header.producer_waiting.swap(1, Ordering::SeqCst);
            self.waiting = true;
            if size > self.ring.free(self.tail)? {
                if header.consumer_closed.load(Ordering::Acquire) != 0 {
                    return Poll::Ready(Err(closed()));
                }
                return Poll::Pending;
            }
        }
        if self.waiting {
            header.producer_waiting.store(0, Ordering::Relaxed);
            self.waiting = false;
        }
        Poll::Ready(Ok(()))
    }

    /// Waits until a packet of `len` bytes fits into the ring.
    pub async fn send_ready(&mut self, len: usize) -> io::Result<()> {
        poll_fn(|cx| self.poll_send_ready(cx, len)).await
    }

    /// Starts writing packets for the OS. They are handed to the driver when the batch
    /// is dropped. Never waits; see [`Sender::poll_send_ready`].
    pub fn send_batch(&mut self) -> SendBatch<'_> {
        let pos = self.tail;
        let free = self.ring.free(pos).unwrap_or(0);
        SendBatch {
            ring: &self.ring,
            tail: &mut self.tail,
            pos,
            free,
            event: self.data.as_raw_handle() as HANDLE,
        }
    }
}

/// Packets the OS sent, borrowed from the transmit ring. Dropping the batch hands the
/// space back to the driver.
#[derive(Debug)]
pub struct RecvBatch<'a> {
    ring: &'a Ring,
    head: &'a mut u32,
    end: u32,
}

impl RecvBatch<'_> {
    pub fn iter(&self) -> RecvIter<'_> {
        RecvIter {
            ring: self.ring,
            pos: *self.head,
            end: self.end,
            _batch: std::marker::PhantomData,
        }
    }

    /// Like [`RecvBatch::iter`] but with mutable packet data, e.g. to complete checksums.
    pub fn iter_mut(&mut self) -> RecvIterMut<'_> {
        RecvIterMut {
            ring: self.ring,
            pos: *self.head,
            end: self.end,
            _batch: std::marker::PhantomData,
        }
    }

    /// Ring bytes the batch occupies (headers and padding included).
    pub fn ring_bytes(&self) -> usize {
        ((self.end.wrapping_sub(*self.head)) & (self.ring.capacity - 1)) as usize
    }
}

impl Drop for RecvBatch<'_> {
    fn drop(&mut self) {
        *self.head = self.end;
        self.ring.header().head.store(self.end, Ordering::Release);
    }
}

/// Iterator over the packets of a [`RecvBatch`].
#[derive(Debug)]
pub struct RecvIter<'a> {
    ring: &'a Ring,
    pos: u32,
    end: u32,
    _batch: std::marker::PhantomData<&'a [u8]>,
}

impl<'a> Iterator for RecvIter<'a> {
    type Item = Packet<'a>;

    fn next(&mut self) -> Option<Packet<'a>> {
        let (header, data) = self.ring.next_entry(&mut self.pos, self.end)?;
        // SAFETY: The driver does not touch [head, end) until the batch is dropped, which
        // the borrow of the batch prevents while these slices live. The virtio header is
        // the tail of the entry header, directly in front of the packet.
        let (data, vnet_frame) = unsafe {
            let len = header.length as usize;
            (
                std::slice::from_raw_parts(data, len),
                std::slice::from_raw_parts(data.sub(abi::VNET_HDR_LEN), abi::VNET_HDR_LEN + len),
            )
        };
        Some(Packet {
            header,
            data,
            vnet_frame,
        })
    }
}

/// Iterator over the packets of a [`RecvBatch`], with mutable data.
#[derive(Debug)]
pub struct RecvIterMut<'a> {
    ring: &'a Ring,
    pos: u32,
    end: u32,
    _batch: std::marker::PhantomData<&'a mut [u8]>,
}

impl<'a> Iterator for RecvIterMut<'a> {
    type Item = PacketMut<'a>;

    fn next(&mut self) -> Option<PacketMut<'a>> {
        let (header, data) = self.ring.next_entry(&mut self.pos, self.end)?;
        // SAFETY: As for `RecvIter`; entries are disjoint and each is yielded once while
        // the batch is mutably borrowed.
        let data = unsafe { std::slice::from_raw_parts_mut(data, header.length as usize) };
        Some(PacketMut { header, data })
    }
}

/// Error returned when a packet does not fit into the receive ring right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RingFull;

impl std::fmt::Display for RingFull {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("receive ring is full")
    }
}

impl std::error::Error for RingFull {}

/// Packets being written into the receive ring; they reach the OS when this is dropped.
#[derive(Debug)]
pub struct SendBatch<'a> {
    ring: &'a Ring,
    tail: &'a mut u32,
    pos: u32,
    free: u32,
    event: HANDLE,
}

impl SendBatch<'_> {
    /// Writes a packet of `len` bytes in place: `fill` gets the packet's bytes (with
    /// unspecified contents) and returns its header. `length` and `reserved` of the
    /// returned header are set by us.
    ///
    /// # Panics
    ///
    /// If `len` is zero or larger than [`abi::MAX_PACKET_SIZE`].
    pub fn push_with(
        &mut self,
        len: usize,
        fill: impl FnOnce(&mut [u8]) -> PacketHeader,
    ) -> Result<(), RingFull> {
        assert!(
            (1..=abi::MAX_PACKET_SIZE).contains(&len),
            "invalid packet length {len}"
        );
        let size = entry_size(len) as u32;
        if size > self.free {
            // The driver may have caught up since we last looked.
            self.free = self.ring.free(self.pos).map_err(|_| RingFull)?;
            if size > self.free {
                return Err(RingFull);
            }
        }
        // SAFETY: `pos` < capacity and `size` <= RING_TRAILER, so the entry is inside the
        // allocation, and it lies in free space the driver does not read.
        unsafe {
            let entry = self.ring.data.as_ptr().add(self.pos as usize);
            let packet = std::slice::from_raw_parts_mut(entry.add(HEADER_LEN), len);
            let mut header = fill(packet);
            header.length = len as u32;
            header.reserved = 0;
            ptr::copy_nonoverlapping(header.to_bytes().as_ptr(), entry, HEADER_LEN);
        }
        self.pos = (self.pos + size) & (self.ring.capacity - 1);
        self.free -= size;
        Ok(())
    }

    /// Copies `packet` into the ring. See [`SendBatch::push_with`].
    pub fn push(&mut self, header: PacketHeader, packet: &[u8]) -> Result<(), RingFull> {
        self.push_with(packet.len(), |buf| {
            buf.copy_from_slice(packet);
            header
        })
    }

    /// Copies `packet` into the ring, described by a legacy `virtio_net_hdr`. Together they
    /// form what a Linux TUN device with `IFF_VNET_HDR` takes in `write()`.
    pub fn push_vnet(
        &mut self,
        vnet_hdr: &[u8; abi::VNET_HDR_LEN],
        packet: &[u8],
    ) -> Result<(), RingFull> {
        let mut bytes = [0u8; HEADER_LEN];
        bytes[abi::VNET_HDR_OFFSET..].copy_from_slice(vnet_hdr);
        let header = PacketHeader::parse(&bytes).expect("exactly one header");
        self.push(header, packet)
    }

    /// Whether nothing was pushed yet.
    pub fn is_empty(&self) -> bool {
        self.pos == *self.tail
    }
}

impl Drop for SendBatch<'_> {
    fn drop(&mut self) {
        if self.is_empty() {
            return;
        }
        *self.tail = self.pos;
        let header = self.ring.header();
        // Full barrier: the driver sets ConsumerWaiting before re-reading Tail.
        header.tail.swap(self.pos, Ordering::SeqCst);
        if header.consumer_waiting.load(Ordering::SeqCst) != 0 {
            // SAFETY: The event handle is owned by the `Sender`, which outlives the batch.
            unsafe { SetEvent(self.event) };
        }
    }
}

fn entry_size(len: usize) -> usize {
    abi::align(HEADER_LEN + len)
}

fn closed() -> io::Error {
    io::Error::new(io::ErrorKind::NotConnected, "the adapter is gone")
}

/// A view of a ring in our own memory, shared with the driver for the lifetime of the
/// session. The memory itself is owned by [`Shared`].
#[derive(Debug, Clone, Copy)]
struct Ring {
    header: NonNull<RingHeader>,
    data: NonNull<u8>,
    capacity: u32,
}

impl Ring {
    fn new(capacity: usize) -> io::Result<(Self, RingMemory)> {
        if !(abi::MIN_RING_CAPACITY..=abi::MAX_RING_CAPACITY).contains(&capacity)
            || !capacity.is_power_of_two()
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "ring capacity must be a power of two within the ABI limits",
            ));
        }
        // Page aligned and zeroed, as the ABI requires.
        // SAFETY: Plain FFI call.
        let base = unsafe {
            VirtualAlloc(
                ptr::null(),
                abi::ring_size(capacity),
                MEM_COMMIT | MEM_RESERVE,
                PAGE_READWRITE,
            )
        };
        let Some(header) = NonNull::new(base as *mut RingHeader) else {
            return Err(io::Error::last_os_error());
        };
        let ring = Self {
            header,
            // SAFETY: The data follows the header within the allocation.
            data: unsafe { NonNull::new_unchecked(base.cast::<u8>().add(size_of::<RingHeader>())) },
            capacity: capacity as u32,
        };
        Ok((ring, RingMemory(header.cast())))
    }

    fn header(&self) -> &RingHeader {
        // SAFETY: Valid for our lifetime; all fields the driver writes are atomics.
        unsafe { self.header.as_ref() }
    }

    /// Loads an offset published by the driver.
    fn load_offset(&self, offset: &std::sync::atomic::AtomicU32) -> io::Result<u32> {
        let value = offset.load(Ordering::Acquire);
        if value >= self.capacity || !(value as usize).is_multiple_of(abi::ALIGNMENT) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "the driver published an invalid ring offset",
            ));
        }
        Ok(value)
    }

    /// Bytes we may still produce, given our producer position.
    fn free(&self, tail: u32) -> io::Result<u32> {
        let head = self.load_offset(&self.header().head)?;
        Ok(head.wrapping_sub(tail).wrapping_sub(abi::ALIGNMENT as u32) & (self.capacity - 1))
    }

    /// Parses the entry at `*pos` (if `*pos != end`) and advances past it.
    fn next_entry(&self, pos: &mut u32, end: u32) -> Option<(PacketHeader, *mut u8)> {
        if *pos == end {
            return None;
        }
        let available = end.wrapping_sub(*pos) & (self.capacity - 1);
        // SAFETY: `pos` < capacity and the trailer covers a whole header.
        let entry = unsafe { self.data.as_ptr().add(*pos as usize) };
        let mut bytes = [0u8; HEADER_LEN];
        // SAFETY: See above; the driver does not write published entries.
        unsafe { ptr::copy_nonoverlapping(entry, bytes.as_mut_ptr(), HEADER_LEN) };
        let header = PacketHeader::parse(&bytes)?;
        let len = header.length as usize;
        let size = entry_size(len) as u32;
        if len == 0 || len > abi::MAX_PACKET_SIZE || size > available {
            // Never produced by the driver; stop rather than read garbage.
            *pos = end;
            return None;
        }
        *pos = (*pos + size) & (self.capacity - 1);
        // SAFETY: The packet follows its header within the entry.
        Some((header, unsafe { entry.add(HEADER_LEN) }))
    }
}

/// Owns a ring's allocation.
#[derive(Debug)]
struct RingMemory(NonNull<c_void>);

// SAFETY: Only freed on drop.
unsafe impl Send for RingMemory {}
// SAFETY: No access through `&self`.
unsafe impl Sync for RingMemory {}

impl Drop for RingMemory {
    fn drop(&mut self) {
        // SAFETY: We allocated it with VirtualAlloc.
        unsafe { VirtualFree(self.0.as_ptr(), 0, MEM_RELEASE) };
    }
}

/// Wakes the last registered [`Waker`] whenever an event is signalled.
#[derive(Debug)]
struct Wakeup {
    /// Kept open for the wait; the driver holds its own reference.
    _event: OwnedHandle,
    wait: HANDLE,
    slot: Arc<WakerSlot>,
}

#[derive(Debug, Default)]
struct WakerSlot(Mutex<Option<Waker>>);

impl WakerSlot {
    fn register(&self, waker: &Waker) {
        let mut slot = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if !slot.as_ref().is_some_and(|w| w.will_wake(waker)) {
            *slot = Some(waker.clone());
        }
    }

    fn wake(&self) {
        let waker = self.0.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(waker) = waker {
            waker.wake();
        }
    }
}

unsafe extern "system" fn wait_callback(context: *mut c_void, _timed_out: bool) {
    // SAFETY: `context` is the `Arc<WakerSlot>` leaked in `Wakeup::new`, which stays
    // alive until `UnregisterWaitEx` has waited for all callbacks.
    let slot = unsafe { &*(context as *const WakerSlot) };
    slot.wake();
}

impl Wakeup {
    fn new(event: OwnedHandle) -> io::Result<Self> {
        let slot = Arc::new(WakerSlot::default());
        let mut wait: HANDLE = ptr::null_mut();
        // SAFETY: The context pointer stays valid until the wait is unregistered (in Drop).
        let ok = unsafe {
            RegisterWaitForSingleObject(
                &mut wait,
                event.as_raw_handle() as HANDLE,
                Some(wait_callback),
                Arc::as_ptr(&slot) as *const c_void,
                INFINITE,
                // The callback only takes a lock and wakes a task.
                WT_EXECUTEINWAITTHREAD,
            )
        };
        if ok == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            _event: event,
            wait,
            slot,
        })
    }
}

impl Drop for Wakeup {
    fn drop(&mut self) {
        // Blocks until a running callback has finished, so `slot` can be dropped.
        // SAFETY: `wait` is our registration.
        unsafe { UnregisterWaitEx(self.wait, INVALID_HANDLE_VALUE) };
    }
}

/// An auto-reset event.
fn event() -> io::Result<OwnedHandle> {
    // SAFETY: Plain FFI call.
    let handle = unsafe { CreateEventW(ptr::null(), 0, 0, ptr::null()) };
    if handle.is_null() {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: We own the new handle.
    Ok(unsafe { OwnedHandle::from_raw_handle(handle as RawHandle) })
}
