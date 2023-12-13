use connlib_shared::{messages::Interface as InterfaceConfig, Result};
use ip_network::IpNetwork;
use std::{
    io,
    str::FromStr,
    sync::Arc,
    task::{ready, Context, Poll},
};
use tokio::sync::mpsc;

const TUNNEL_UUID: &str = "e9245bc1-b8c1-44ca-ab1d-c6aad4f13b9c";

// TODO: Make sure all these get dropped gracefully on disconnect
pub struct Tun {
    _adapter: Arc<wintun::Adapter>,
    // TODO: Get rid of this mutex. It's a hack to deal with `poll_read` taking a `&self` instead of `&mut self`
    packet_rx: std::sync::Mutex<mpsc::Receiver<wintun::Packet>>,
    _recv_thread: std::thread::JoinHandle<()>,
    session: Arc<wintun::Session>,
}

impl Tun {
    pub fn new(config: &InterfaceConfig) -> Result<Self> {
        // The unsafe is here because we're loading a DLL from disk and it has arbitrary C code in it.
        // As a defense, we could verify the hash before loading it. This would protect against accidental corruption, but not against attacks. (Because of TOCTOU)
        let wintun = unsafe { wintun::load_from_path("./wintun.dll") }?;
        let uuid = uuid::Uuid::from_str(TUNNEL_UUID)?;
        let adapter = match wintun::Adapter::create(
            &wintun,
            "Firezone",
            "Firezone Tunnel",
            Some(uuid.as_u128()),
        ) {
            Ok(x) => x,
            Err(e) => {
                tracing::error!(
                    "wintun::Adapter::create failed, probably need admin powers: {}",
                    e
                );
                return Err(e.into());
            }
        };

        adapter.set_address(config.ipv4)?;

        let session = Arc::new(adapter.start_session(wintun::MAX_RING_CAPACITY)?);

        let (packet_tx, packet_rx) = mpsc::channel(5);

        let recv_thread = start_recv_thread(packet_tx, Arc::clone(&session));
        let packet_rx = std::sync::Mutex::new(packet_rx);

        Ok(Self {
            _adapter: adapter,
            _recv_thread: recv_thread,
            packet_rx,
            session: Arc::clone(&session),
        })
    }

    pub fn add_route(&self, route: IpNetwork) -> Result<()> {
        tracing::debug!("add_route {route}");
        Ok(())
    }

    pub fn poll_read(&self, buf: &mut [u8], cx: &mut Context<'_>) -> Poll<io::Result<usize>> {
        let mut packet_rx = self.packet_rx.try_lock().unwrap();

        let pkt = ready!(packet_rx.poll_recv(cx));

        match pkt {
            Some(pkt) => {
                let bytes = pkt.bytes();
                let len = bytes.len();
                buf[0..len].copy_from_slice(bytes);
                Poll::Ready(Ok(len))
            }
            None => {
                tracing::error!("error receiving packet from mpsc channel");
                Poll::Ready(Err(std::io::ErrorKind::Other.into()))
            }
        }
    }

    pub fn write4(&self, bytes: &[u8]) -> io::Result<usize> {
        self.write(bytes)
    }

    pub fn write6(&self, bytes: &[u8]) -> io::Result<usize> {
        self.write(bytes)
    }

    fn write(&self, bytes: &[u8]) -> io::Result<usize> {
        // TODO: If the ring buffer is full, don't panic, just return Ok(None) or an error or whatever the Unix impls do
        // Don't block.
        let mut pkt = self
            .session
            .allocate_send_packet(bytes.len().try_into().unwrap())
            .unwrap();
        pkt.bytes_mut().copy_from_slice(bytes);
        self.session.send_packet(pkt);
        Ok(bytes.len())
    }
}

fn start_recv_thread(
    packet_tx: mpsc::Sender<wintun::Packet>,
    session: Arc<wintun::Session>,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        while let Ok(pkt) = session.receive_blocking() {
            // TODO: Don't allocate here if we can help it
            packet_tx.blocking_send(pkt).unwrap();
        }
        tracing::debug!("recv_task exiting gracefully");
    })
}
