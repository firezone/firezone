//! Measures how long connlib's IO pipeline waits for each of the threads it hands packets to.
//!
//! The pipeline reports when a [`Site`] starts and stops waiting and counts the packets it handles.
//! A sampler splits that into [`Window`]s, which it only does while packets flow.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
    sync::{
        LazyLock,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::sync::{
    Notify,
    mpsc::{
        self,
        error::{SendError, TrySendError},
    },
};

/// How many packets a [`Window`] needs for its ratios to say something about throughput.
const BUSY_PACKETS: u64 = 100;

/// Below this blocked ratio, a thread does not hold up the pipeline.
const BOTTLENECK_RATIO: f64 = 0.01;

static PACKETS: AtomicU64 = AtomicU64::new(0);
static TRAFFIC: Notify = Notify::const_new();
static SLOTS: [Slot; Site::ALL.len()] = [const { Slot::new() }; Site::ALL.len()];
static EPOCH: LazyLock<Instant> = LazyLock::new(Instant::now);

/// A thread that the IO pipeline hands packets to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Thread {
    UdpV4,
    UdpV6,
    TunTx,
    Crypto,
    EventLoop,
}

impl Thread {
    const ALL: [Thread; 5] = [
        Thread::UdpV4,
        Thread::UdpV6,
        Thread::TunTx,
        Thread::Crypto,
        Thread::EventLoop,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Thread::UdpV4 => "fz-udp-v4",
            Thread::UdpV6 => "fz-udp-v6",
            Thread::TunTx => "fz-tun-tx",
            Thread::Crypto => "fz-crypto",
            Thread::EventLoop => "fz-eventloop",
        }
    }
}

/// A place where the IO pipeline waits for a [`Thread`] to make room.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Site {
    UdpSendV4,
    UdpSendV6,
    TunWrite,
    Decrypt,
    TunRead,
    UdpRecvV4,
    UdpRecvV6,
}

impl Site {
    const ALL: [Site; 7] = [
        Site::UdpSendV4,
        Site::UdpSendV6,
        Site::TunWrite,
        Site::Decrypt,
        Site::TunRead,
        Site::UdpRecvV4,
        Site::UdpRecvV6,
    ];

    fn thread(self) -> Thread {
        match self {
            Site::UdpSendV4 => Thread::UdpV4,
            Site::UdpSendV6 => Thread::UdpV6,
            Site::TunWrite => Thread::TunTx,
            Site::Decrypt => Thread::Crypto,
            Site::TunRead => Thread::EventLoop,
            Site::UdpRecvV4 => Thread::EventLoop,
            Site::UdpRecvV6 => Thread::EventLoop,
        }
    }

    fn slot(self) -> &'static Slot {
        &SLOTS[self as usize]
    }
}

/// Counts the packets the IO loop handled.
pub fn count_packets(num_packets: usize) {
    if num_packets == 0 {
        return;
    }

    if PACKETS.fetch_add(num_packets as u64, Ordering::Relaxed) == 0 {
        TRAFFIC.notify_one();
    }
}

/// Sends `item`, counting the time until the channel has room as time that `site` waited.
pub async fn send<T>(tx: &mpsc::Sender<T>, item: T, site: Site) -> Result<(), SendError<T>> {
    let item = match tx.try_send(item) {
        Ok(()) => return Ok(()),
        Err(TrySendError::Full(item)) => item,
        Err(TrySendError::Closed(item)) => return Err(SendError(item)),
    };

    let _stall = Stall::start(site);

    tx.send(item).await
}

/// Like [`send`], but blocks the current thread.
pub fn blocking_send<T>(tx: &mpsc::Sender<T>, item: T, site: Site) -> Result<(), SendError<T>> {
    let item = match tx.try_send(item) {
        Ok(()) => return Ok(()),
        Err(TrySendError::Full(item)) => item,
        Err(TrySendError::Closed(item)) => return Err(SendError(item)),
    };

    let _stall = Stall::start(site);

    tx.blocking_send(item)
}

/// Counts the time until it is dropped as time that its [`Site`] waited.
struct Stall(Site);

impl Stall {
    fn start(site: Site) -> Self {
        site.slot().block(Instant::now());

        Self(site)
    }
}

impl Drop for Stall {
    fn drop(&mut self) {
        self.0.slot().unblock(Instant::now());
    }
}

/// Tracks the [`Stall`]s of a [`Site`] that is polled repeatedly until it has room.
pub struct Backpressure {
    site: Site,
    stall: Option<Stall>,
}

impl Backpressure {
    pub fn new(site: Site) -> Self {
        Self { site, stall: None }
    }

    pub fn record(&mut self, has_room: bool) {
        if has_room {
            self.stall = None;
            return;
        }

        if self.stall.is_none() {
            self.stall = Some(Stall::start(self.site));
        }
    }
}

/// Splits the time since packets started flowing into consecutive [`Window`]s.
pub struct Windows {
    start: Instant,
}

impl Windows {
    /// Waits until the IO loop handles packets and starts the first window.
    pub async fn wait_for_traffic() -> Self {
        while PACKETS.load(Ordering::Relaxed) == 0 {
            TRAFFIC.notified().await;
        }

        let start = Instant::now();

        for site in Site::ALL {
            site.slot().take(start);
        }

        Self { start }
    }

    /// Ends the current window and starts the next one.
    pub fn close(&mut self) -> Window {
        let end = Instant::now();
        let mut blocked = [Duration::ZERO; Thread::ALL.len()];

        for site in Site::ALL {
            let thread = &mut blocked[site.thread() as usize];

            *thread = (*thread).max(site.slot().take(end));
        }

        let window = Window {
            packets: PACKETS.swap(0, Ordering::Relaxed),
            length: end.saturating_duration_since(self.start),
            blocked,
        };
        self.start = end;

        window
    }
}

/// The packets the IO loop handled in a window and how long each [`Thread`] held it up.
///
/// A [`Thread`] that several [`Site`]s wait for holds the pipeline up for as long as the longest of them waited.
#[derive(Debug)]
pub struct Window {
    packets: u64,
    length: Duration,
    blocked: [Duration; Thread::ALL.len()],
}

impl Window {
    /// Whether no packets flowed in this window.
    pub fn is_idle(&self) -> bool {
        self.packets == 0
    }

    /// Whether enough packets flowed in this window for its ratios to be meaningful.
    pub fn is_busy(&self) -> bool {
        self.packets >= BUSY_PACKETS
    }

    /// Returns the share of the window that `time` takes up, clamped to `[0, 1]`.
    pub fn ratio(&self, time: Duration) -> f64 {
        (time.as_secs_f64() / self.length.as_secs_f64()).clamp(0.0, 1.0)
    }

    /// Returns the share of the window that each [`Thread`] held up the pipeline.
    pub fn blocked_ratios(&self) -> impl Iterator<Item = (Thread, f64)> + '_ {
        Thread::ALL
            .into_iter()
            .map(|thread| (thread, self.ratio(self.blocked[thread as usize])))
    }

    /// Returns the [`Thread`] that held up the pipeline the most, if any did noticeably.
    pub fn bottleneck(&self) -> Option<Thread> {
        self.blocked_ratios()
            .filter(|(_, ratio)| *ratio >= BOTTLENECK_RATIO)
            .max_by(|(_, a), (_, b)| a.total_cmp(b))
            .map(|(thread, _)| thread)
    }
}

/// The time a [`Site`] waited, as nanoseconds since [`EPOCH`].
struct Slot {
    blocked: AtomicU64,
    /// When the ongoing wait started, or [`Slot::NOT_BLOCKED`].
    blocked_since: AtomicU64,
}

impl Slot {
    const NOT_BLOCKED: u64 = u64::MAX;

    const fn new() -> Self {
        Self {
            blocked: AtomicU64::new(0),
            blocked_since: AtomicU64::new(Self::NOT_BLOCKED),
        }
    }

    fn block(&self, now: Instant) {
        self.blocked_since.store(nanos(now), Ordering::Relaxed);
    }

    fn unblock(&self, now: Instant) {
        let since = self
            .blocked_since
            .swap(Self::NOT_BLOCKED, Ordering::Relaxed);

        if since == Self::NOT_BLOCKED {
            return;
        }

        self.blocked
            .fetch_add(nanos(now).saturating_sub(since), Ordering::Relaxed);
    }

    /// Returns the time waited until `end` and restarts counting from there.
    ///
    /// An ongoing wait is split at `end`, so the part after it counts towards the next window.
    fn take(&self, end: Instant) -> Duration {
        let end = nanos(end);
        let since = self.blocked_since.load(Ordering::Relaxed);

        let ongoing = if since != Self::NOT_BLOCKED
            && self
                .blocked_since
                .compare_exchange(since, end.max(since), Ordering::Relaxed, Ordering::Relaxed)
                .is_ok()
        {
            end.saturating_sub(since)
        } else {
            0
        };

        Duration::from_nanos(self.blocked.swap(0, Ordering::Relaxed) + ongoing)
    }
}

fn nanos(at: Instant) -> u64 {
    at.saturating_duration_since(*EPOCH).as_nanos() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stall_across_windows_is_split_at_the_boundary() {
        let slot = Slot::new();

        slot.block(at(100));
        let first = slot.take(at(1000));
        slot.unblock(at(1300));
        let second = slot.take(at(2000));

        assert_eq!(first, Duration::from_millis(900));
        assert_eq!(second, Duration::from_millis(300));
    }

    #[test]
    fn finished_stalls_add_up() {
        let slot = Slot::new();

        slot.block(at(100));
        slot.unblock(at(200));
        slot.block(at(500));
        slot.unblock(at(550));

        assert_eq!(slot.take(at(1000)), Duration::from_millis(150));
        assert_eq!(slot.take(at(2000)), Duration::ZERO);
    }

    #[test]
    fn ratio_is_clamped_to_the_window() {
        let window = window([0, 0, 0, 0, 0]);

        assert_eq!(window.ratio(Duration::from_millis(250)), 0.25);
        assert_eq!(window.ratio(Duration::from_millis(1500)), 1.0);
    }

    #[test]
    fn bottleneck_is_the_thread_blocked_the_longest() {
        let window = window([10, 0, 300, 450, 20]);

        assert_eq!(window.bottleneck(), Some(Thread::Crypto));
    }

    #[test]
    fn no_bottleneck_if_every_thread_is_below_the_threshold() {
        let window = window([9, 0, 5, 1, 0]);

        assert_eq!(window.bottleneck(), None);
    }

    #[test]
    fn busy_window_needs_enough_packets() {
        let mut window = window([0, 0, 0, 0, 0]);

        window.packets = 99;
        assert!(!window.is_busy());

        window.packets = 100;
        assert!(window.is_busy());
    }

    fn window(blocked_millis: [u64; Thread::ALL.len()]) -> Window {
        Window {
            packets: BUSY_PACKETS,
            length: Duration::from_secs(1),
            blocked: blocked_millis.map(Duration::from_millis),
        }
    }

    fn at(millis: u64) -> Instant {
        *EPOCH + Duration::from_millis(millis)
    }
}
