use ip_packet::IpPacket;
use std::io;
use std::task::{Context, Poll, Waker};
use tracing::Level;
use tun::Tun;

pub struct Device {
    tun: Option<Box<dyn Tun>>,
    waker: Option<Waker>,
}

impl Device {
    pub(crate) fn new() -> Self {
        Self {
            tun: None,
            waker: None,
        }
    }

    pub(crate) fn set_tun(&mut self, tun: Box<dyn Tun>) {
        tracing::info!(name = %tun.name(), "Initializing TUN device");

        self.tun = Some(tun);

        if let Some(waker) = self.waker.take() {
            waker.wake();
        }
    }

    pub(crate) fn poll_read_many(
        &mut self,
        cx: &mut Context<'_>,
        buf: &mut Vec<IpPacket>,
        max: usize,
    ) -> Poll<usize> {
        let Some(tun) = self.tun.as_mut() else {
            self.waker = Some(cx.waker().clone());
            return Poll::Pending;
        };

        let n = std::task::ready!(tun.poll_recv_many(cx, buf, max));

        for packet in &buf[..n] {
            tracing::trace!(target: "wire::dev::recv", ?packet);

            if tracing::event_enabled!(target: "wire::dns::qry", Level::TRACE) {
                if let Some(query) = parse_dns_query(packet) {
                    tracing::trace!(target: "wire::dns::qry", ?query);
                }
            }

            if packet.is_fz_p2p_control() {
                tracing::warn!("Packet matches heuristics of FZ-internal p2p control protocol");
            }
        }

        Poll::Ready(n)
    }

    pub fn poll_send_ready(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let Some(tun) = self.tun.as_mut() else {
            self.waker = Some(cx.waker().clone());
            return Poll::Pending;
        };

        tun.poll_send_ready(cx)
    }

    pub fn send(&mut self, packet: IpPacket) -> io::Result<()> {
        if tracing::event_enabled!(target: "wire::dns::res", Level::TRACE) {
            if let Some(response) = parse_dns_response(&packet) {
                tracing::trace!(target: "wire::dns::res", ?response);
            }
        }

        tracing::trace!(target: "wire::dev::send", ?packet);

        debug_assert!(
            !packet.is_fz_p2p_control(),
            "FZ p2p control protocol packets should never leave `connlib`"
        );

        self.tun()?.send(packet)?;

        Ok(())
    }

    fn tun(&mut self) -> io::Result<&mut dyn Tun> {
        Ok(self
            .tun
            .as_mut()
            .ok_or_else(io_error_not_initialized)?
            .as_mut())
    }
}

fn io_error_not_initialized() -> io::Error {
    io::Error::new(io::ErrorKind::NotConnected, "device is not initialized yet")
}

fn parse_dns_query(packet: &IpPacket) -> Option<dns_types::Query> {
    let udp = packet.as_udp()?;
    if udp.destination_port() != crate::dns::DNS_PORT {
        return None;
    }

    dns_types::Query::parse(udp.payload()).ok()
}

fn parse_dns_response(packet: &IpPacket) -> Option<dns_types::Response> {
    let udp = packet.as_udp()?;
    if udp.source_port() != crate::dns::DNS_PORT {
        return None;
    }

    dns_types::Response::parse(udp.payload()).ok()
}
