use domain::base::iana::Rcode;
use domain::base::{Message, ParsedName, Rtype};
use domain::rdata::AllRecordData;
use ip_packet::IpPacket;
use itertools::Itertools;
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
            if tracing::event_enabled!(target: "wire::dns::qry", Level::TRACE) {
                if let Some((qtype, qname, qid)) = parse_dns_query(packet) {
                    tracing::trace!(target: "wire::dns::qry", %qid, "{:5} {qname}", qtype.to_string());
                }
            }

            if packet.is_fz_p2p_control() {
                tracing::warn!("Packet matches heuristics of FZ-internal p2p control protocol");
            }

            tracing::trace!(target: "wire::dev::recv", dst = %packet.destination(), src = %packet.source(), bytes = %packet.packet().len());
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
            if let Some((qtype, qname, records, rcode, qid)) = parse_dns_response(&packet) {
                tracing::trace!(target: "wire::dns::res", %qid, %rcode, "{:5} {qname} => [{records}]", qtype.to_string());
            }
        }

        tracing::trace!(target: "wire::dev::send", dst = %packet.destination(), src = %packet.source(), bytes = %packet.packet().len());

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

fn parse_dns_query(packet: &IpPacket) -> Option<(Rtype, ParsedName<&[u8]>, u16)> {
    let udp = packet.as_udp()?;
    if udp.destination_port() != crate::dns::DNS_PORT {
        return None;
    }

    let message = &Message::from_slice(udp.payload()).ok()?;

    if message.header().qr() {
        return None;
    }

    let question = message.sole_question().ok()?;

    let qtype = question.qtype();
    let qname = question.into_qname();
    let id = message.header().id();

    Some((qtype, qname, id))
}

#[expect(clippy::type_complexity)]
fn parse_dns_response(packet: &IpPacket) -> Option<(Rtype, ParsedName<&[u8]>, String, Rcode, u16)> {
    let udp = packet.as_udp()?;
    if udp.source_port() != crate::dns::DNS_PORT {
        return None;
    }

    let message = &Message::from_slice(udp.payload()).ok()?;

    if !message.header().qr() {
        return None;
    }

    let question = message.sole_question().ok()?;

    let qtype = question.qtype();
    let qname = question.into_qname();
    let rcode = message.header().rcode();

    let record_section = message.answer().ok()?;

    let records = record_section
        .into_iter()
        .filter_map(|r| {
            let data = r
                .ok()?
                .into_any_record::<AllRecordData<_, _>>()
                .ok()?
                .data()
                .clone();

            Some(data)
        })
        .join(" | ");
    let id = message.header().id();

    Some((qtype, qname, records, rcode, id))
}
