//! DNS and route control  for the virtual network interface in `tunnel`

#[cfg(target_os = "linux")]
pub mod linux;
use std::fmt;

#[cfg(target_os = "linux")]
pub use linux as platform;

#[cfg(target_os = "windows")]
pub mod windows;
#[cfg(target_os = "windows")]
pub use windows as platform;

#[cfg(target_os = "macos")]
pub mod macos;
#[cfg(target_os = "macos")]
pub use macos as platform;

pub use platform::TunDeviceManager;

/// A TUN device backed by one worker thread per direction.
///
/// Owns the channels connecting the workers to the main thread.
/// Dropping closes the channels and then joins both workers. Platform state
/// that the workers additionally need released in order to exit (e.g. the
/// WinTUN session) must be released before this drops.
#[cfg(any(target_os = "linux", target_os = "windows"))]
pub(crate) struct TunWorkers {
    state: Option<WorkerState>,

    send_thread: Option<std::thread::JoinHandle<()>>,
    recv_thread: Option<std::thread::JoinHandle<()>>,
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
struct WorkerState {
    outbound_tx: tun::OutboundTx,
    inbound_rx: tun::InboundRx,
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
impl TunWorkers {
    /// Spawns the send and recv worker threads for a TUN device.
    ///
    /// Panics if called without a Tokio runtime.
    pub(crate) fn spawn(
        send: impl FnOnce(tun::OutboundRx) + Send + 'static,
        recv: impl FnOnce(tun::InboundTx) + Send + 'static,
    ) -> std::io::Result<Self> {
        let (outbound_tx, outbound_rx) = tun::outbound_channel();
        let (inbound_tx, inbound_rx) = tun::inbound_channel();

        tokio::spawn(otel_instruments::periodic_queue_length(
            outbound_tx.downgrade(),
            [
                otel_attributes::queue_item_ip_packet_batch(),
                otel_attributes::network_io_direction_transmit(),
            ],
        ));
        tokio::spawn(otel_instruments::periodic_queue_length(
            inbound_tx.downgrade(),
            [
                otel_attributes::queue_item_ip_packet_batch(),
                otel_attributes::network_io_direction_receive(),
            ],
        ));

        let send_thread = std::thread::Builder::new()
            .name("TUN send".to_owned())
            .spawn(move || send(outbound_rx))?;
        let recv_thread = std::thread::Builder::new()
            .name("TUN recv".to_owned())
            .spawn(move || recv(inbound_tx))?;

        Ok(Self {
            state: Some(WorkerState {
                outbound_tx,
                inbound_rx,
            }),
            send_thread: Some(send_thread),
            recv_thread: Some(recv_thread),
        })
    }

    pub(crate) fn sender(&self) -> &tun::OutboundTx {
        &self
            .state
            .as_ref()
            .expect("`state` should always be `Some` until `TunWorkers` drops")
            .outbound_tx
    }

    pub(crate) fn receiver(&mut self) -> &mut tun::InboundRx {
        &mut self
            .state
            .as_mut()
            .expect("`state` should always be `Some` until `TunWorkers` drops")
            .inbound_rx
    }
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
impl Drop for TunWorkers {
    fn drop(&mut self) {
        use std::time::{Duration, Instant};

        const SHUTDOWN_WAIT: Duration = Duration::from_secs(10);

        let recv_thread = self
            .recv_thread
            .take()
            .expect("`recv_thread` should always be `Some` until `TunWorkers` drops");

        let send_thread = self
            .send_thread
            .take()
            .expect("`send_thread` should always be `Some` until `TunWorkers` drops");

        let _ = self.state.take(); // Drop all channel state, allowing the worker threads to exit gracefully.

        let start = Instant::now();

        loop {
            let recv_thread_finished = recv_thread.is_finished();
            let send_thread_finished = send_thread.is_finished();

            if recv_thread_finished && send_thread_finished {
                break;
            }

            if start.elapsed() > SHUTDOWN_WAIT {
                tracing::warn!(%recv_thread_finished, %send_thread_finished, "TUN worker threads did not exit gracefully in {SHUTDOWN_WAIT:?}");
                return;
            }

            std::thread::sleep(Duration::from_millis(100));
        }

        tracing::debug!(
            "Worker threads exited gracefully after {:?}",
            start.elapsed()
        );

        if let Err(error) = recv_thread.join() {
            tracing::error!("TUN recv thread panicked: {error:?}");
        }
        if let Err(error) = send_thread.join() {
            tracing::error!("TUN send thread panicked: {error:?}");
        }
    }
}

/// The supported IP stack of the TUN device
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TunIpStack {
    V4Only,
    V6Only,
    Dual,
}

impl TunIpStack {
    pub fn supports_ipv4(&self) -> bool {
        match self {
            TunIpStack::V4Only | TunIpStack::Dual => true,
            TunIpStack::V6Only => false,
        }
    }

    pub fn supports_ipv6(&self) -> bool {
        match self {
            TunIpStack::V6Only | TunIpStack::Dual => true,
            TunIpStack::V4Only => false,
        }
    }
}

impl fmt::Display for TunIpStack {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TunIpStack::V4Only => write!(f, "V4Only"),
            TunIpStack::V6Only => write!(f, "V6Only"),
            TunIpStack::Dual => write!(f, "Dual"),
        }
    }
}
