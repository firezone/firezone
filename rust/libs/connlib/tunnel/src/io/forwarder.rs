//! The host-socket side of the userspace forwarder.
//!
//! [`userspace_forwarder::Forwarder`] decides what to do; this module does it: one task
//! per TCP connection, UDP flow or ICMP echo session, talking to the core through
//! channels. Sockets come from the same factories as the rest of the tunnel's, so they
//! bypass the tunnel where the platform needs that.

use std::{
    collections::HashMap,
    io,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
    time::{Duration, Instant},
};

use ip_packet::IpPacket;
use socket_factory::{SocketFactory, TcpSocket};
use tokio::{
    io::{AsyncReadExt as _, AsyncWriteExt as _},
    sync::mpsc,
    task::JoinSet,
};
use userspace_forwarder::{Command, Event, FlowId};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const READ_CHUNK: usize = 16 * 1024;
const UDP_MAX: usize = 64 * 1024;

pub struct Forwarder {
    core: userspace_forwarder::Forwarder,

    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,

    events_tx: mpsc::Sender<Event>,
    events_rx: mpsc::Receiver<Event>,

    tcp: HashMap<FlowId, mpsc::UnboundedSender<TcpCmd>>,
    udp: HashMap<FlowId, mpsc::UnboundedSender<Vec<u8>>>,
    icmp: HashMap<FlowId, mpsc::UnboundedSender<EchoRequest>>,

    tasks: JoinSet<()>,
    timeout: Option<Pin<Box<tokio::time::Sleep>>>,

    warned_icmp: bool,
}

enum TcpCmd {
    Send(Vec<u8>),
    RecvCredit(usize),
    ShutdownWrite,
    Close,
}

struct EchoRequest {
    sequence: u16,
    payload: Vec<u8>,
    ttl: u8,
}

impl Forwarder {
    pub fn new(tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>, now: Instant) -> Self {
        let (events_tx, events_rx) = mpsc::channel(1024);

        Self {
            core: userspace_forwarder::Forwarder::new(now),
            tcp_socket_factory,
            events_tx,
            events_rx,
            tcp: HashMap::new(),
            udp: HashMap::new(),
            icmp: HashMap::new(),
            tasks: JoinSet::new(),
            timeout: None,
            warned_icmp: false,
        }
    }

    /// A packet from a peer for a resource this device serves.
    pub fn forward(&mut self, packet: IpPacket, now: Instant) {
        self.core.handle_packet(packet, now);
        self.dispatch();
    }

    /// Polls the host sockets and the core's timers; packets for the peers come out.
    pub fn poll(&mut self, cx: &mut Context<'_>, now: Instant) -> Vec<IpPacket> {
        while let Poll::Ready(Some(event)) = self.events_rx.poll_recv(cx) {
            self.core.handle_event(event, now);
            self.dispatch();
        }

        while let Poll::Ready(Some(_)) = self.tasks.poll_join_next(cx) {}

        if let Some(timeout) = self.timeout.as_mut()
            && timeout.as_mut().poll(cx).is_ready()
        {
            self.timeout = None;
            self.core.handle_timeout(now);
            self.dispatch();
        }

        self.arm_timeout(cx, now);

        std::iter::from_fn(|| self.core.poll_packet()).collect()
    }

    fn arm_timeout(&mut self, cx: &mut Context<'_>, now: Instant) {
        let Some(at) = self.core.poll_timeout() else {
            self.timeout = None;
            return;
        };

        let deadline = tokio::time::Instant::now() + at.saturating_duration_since(now);

        match self.timeout.as_mut() {
            Some(sleep) if sleep.deadline() == deadline => {}
            Some(sleep) => sleep.as_mut().reset(deadline),
            None => self.timeout = Some(Box::pin(tokio::time::sleep_until(deadline))),
        }

        if let Some(sleep) = self.timeout.as_mut()
            && sleep.as_mut().poll(cx).is_ready()
        {
            cx.waker().wake_by_ref();
        }
    }

    /// Carries out what the core decided.
    fn dispatch(&mut self) {
        while let Some(command) = self.core.poll_command() {
            match command {
                Command::TcpConnect { flow, remote } => {
                    let (tx, rx) = mpsc::unbounded_channel();
                    self.tcp.insert(flow, tx);
                    self.tasks.spawn(tcp_flow(
                        flow,
                        remote,
                        self.tcp_socket_factory.clone(),
                        rx,
                        self.events_tx.clone(),
                    ));
                }
                Command::TcpSend { flow, data } => self.send_tcp(flow, TcpCmd::Send(data)),
                Command::TcpRecvCredit { flow, bytes } => {
                    self.send_tcp(flow, TcpCmd::RecvCredit(bytes))
                }
                Command::TcpShutdownWrite { flow } => self.send_tcp(flow, TcpCmd::ShutdownWrite),
                Command::TcpClose { flow } => {
                    if let Some(tx) = self.tcp.remove(&flow) {
                        let _ = tx.send(TcpCmd::Close);
                    }
                }
                Command::UdpSend { flow, remote, data } => {
                    let tx = self.udp.entry(flow).or_insert_with(|| {
                        let (tx, rx) = mpsc::unbounded_channel();
                        self.tasks
                            .spawn(udp_flow(flow, remote, rx, self.events_tx.clone()));

                        tx
                    });
                    let _ = tx.send(data);
                }
                Command::UdpClose { flow } => {
                    self.udp.remove(&flow);
                }
                Command::IcmpEcho {
                    flow,
                    remote,
                    sequence,
                    payload,
                    ttl,
                } => {
                    let tx = self.icmp.entry(flow).or_insert_with(|| {
                        let (tx, rx) = mpsc::unbounded_channel();
                        self.tasks.spawn(icmp_flow(
                            flow,
                            remote,
                            rx,
                            self.events_tx.clone(),
                            !std::mem::replace(&mut self.warned_icmp, true),
                        ));

                        tx
                    });
                    let _ = tx.send(EchoRequest {
                        sequence,
                        payload,
                        ttl,
                    });
                }
                Command::IcmpClose { flow } => {
                    self.icmp.remove(&flow);
                }
            }
        }
    }

    fn send_tcp(&mut self, flow: FlowId, cmd: TcpCmd) {
        if let Some(tx) = self.tcp.get(&flow)
            && tx.send(cmd).is_err()
        {
            self.tcp.remove(&flow);
        }
    }
}

async fn tcp_flow(
    flow: FlowId,
    remote: SocketAddr,
    factory: Arc<dyn SocketFactory<TcpSocket>>,
    mut cmds: mpsc::UnboundedReceiver<TcpCmd>,
    events: mpsc::Sender<Event>,
) {
    let connect = async { factory.bind(remote)?.connect(remote).await };
    let stream = match tokio::time::timeout(CONNECT_TIMEOUT, connect).await {
        Ok(Ok(stream)) => stream,
        Ok(Err(e)) => {
            tracing::debug!(%flow, %remote, "Host connection failed: {e}");
            let _ = events
                .send(Event::TcpConnectFailed {
                    flow,
                    refused: e.kind() == io::ErrorKind::ConnectionRefused,
                })
                .await;
            return;
        }
        Err(_) => {
            tracing::debug!(%flow, %remote, "Host connection timed out");
            let _ = events
                .send(Event::TcpConnectFailed {
                    flow,
                    refused: false,
                })
                .await;
            return;
        }
    };

    if events.send(Event::TcpConnected { flow }).await.is_err() {
        return;
    }

    let (mut reader, mut writer) = tokio::io::split(stream);
    let mut credit = 0usize;
    let mut eof = false;

    loop {
        tokio::select! {
            cmd = cmds.recv() => match cmd {
                None | Some(TcpCmd::Close) => break,
                Some(TcpCmd::Send(data)) => {
                    if let Err(e) = writer.write_all(&data).await {
                        tracing::debug!(%flow, "Failed to write to host connection: {e}");
                        let _ = events.send(Event::TcpError { flow }).await;
                        break;
                    }

                    if events.send(Event::TcpSent { flow, bytes: data.len() }).await.is_err() {
                        break;
                    }
                }
                Some(TcpCmd::ShutdownWrite) => {
                    let _ = writer.shutdown().await;
                }
                Some(TcpCmd::RecvCredit(bytes)) => credit += bytes,
            },
            (result, data) = read_chunk(&mut reader, credit.min(READ_CHUNK)), if credit > 0 && !eof => match result {
                Ok(0) => {
                    eof = true;
                    if events.send(Event::TcpEof { flow }).await.is_err() {
                        break;
                    }
                }
                Ok(n) => {
                    credit -= n;
                    if events.send(Event::TcpData { flow, data }).await.is_err() {
                        break;
                    }
                }
                Err(e) => {
                    tracing::debug!(%flow, "Failed to read from host connection: {e}");
                    let _ = events.send(Event::TcpError { flow }).await;
                    break;
                }
            }
        }
    }
}

/// Reads up to `max` bytes, returning the bytes read as a vector of exactly that length.
async fn read_chunk<R: tokio::io::AsyncRead + Unpin>(
    reader: &mut R,
    max: usize,
) -> (io::Result<usize>, Vec<u8>) {
    let mut data = vec![0u8; max];

    match reader.read(&mut data).await {
        Ok(n) => {
            data.truncate(n);
            (Ok(n), data)
        }
        Err(e) => (Err(e), Vec::new()),
    }
}

async fn udp_flow(
    flow: FlowId,
    remote: SocketAddr,
    mut datagrams: mpsc::UnboundedReceiver<Vec<u8>>,
    events: mpsc::Sender<Event>,
) {
    let socket = match tokio::net::UdpSocket::bind(unspecified(remote.ip())).await {
        Ok(socket) => socket,
        Err(e) => {
            tracing::debug!(%flow, %remote, "Failed to open UDP socket: {e}");
            let _ = events.send(Event::UdpUnreachable { flow }).await;
            return;
        }
    };
    if let Err(e) = socket.connect(remote).await {
        tracing::debug!(%flow, %remote, "Failed to connect UDP socket: {e}");
        let _ = events.send(Event::UdpUnreachable { flow }).await;
        return;
    }

    let mut buf = vec![0u8; UDP_MAX];

    loop {
        tokio::select! {
            datagram = datagrams.recv() => match datagram {
                None => break,
                Some(data) => {
                    if let Err(e) = socket.send(&data).await {
                        tracing::debug!(%flow, %remote, "Failed to send UDP datagram: {e}");
                        if is_unreachable(&e) {
                            let _ = events.send(Event::UdpUnreachable { flow }).await;
                            break;
                        }
                    }
                }
            },
            result = socket.recv(&mut buf) => match result {
                Ok(n) => {
                    if events.send(Event::UdpData { flow, data: buf[..n].to_vec() }).await.is_err() {
                        break;
                    }
                }
                Err(e) if is_unreachable(&e) => {
                    let _ = events.send(Event::UdpUnreachable { flow }).await;
                    break;
                }
                Err(e) => {
                    tracing::debug!(%flow, %remote, "Failed to receive UDP datagram: {e}");
                }
            }
        }
    }
}

fn is_unreachable(e: &io::Error) -> bool {
    matches!(
        e.kind(),
        io::ErrorKind::ConnectionRefused
            | io::ErrorKind::HostUnreachable
            | io::ErrorKind::NetworkUnreachable
    )
}

fn unspecified(ip: IpAddr) -> SocketAddr {
    match ip {
        IpAddr::V4(_) => SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0),
        IpAddr::V6(_) => SocketAddr::new(Ipv6Addr::UNSPECIFIED.into(), 0),
    }
}

async fn icmp_flow(
    flow: FlowId,
    remote: IpAddr,
    mut requests: mpsc::UnboundedReceiver<EchoRequest>,
    events: mpsc::Sender<Event>,
    warn_on_failure: bool,
) {
    let identifier = (flow_number(flow) & 0xffff) as u16;

    let socket = match icmp::open(remote, identifier).await {
        Ok(socket) => socket,
        Err(e) => {
            if warn_on_failure {
                tracing::warn!(
                    "Cannot open ICMP sockets, peers cannot ping the resources this device serves: {e:#}"
                );
            } else {
                tracing::debug!(%flow, "Failed to open ICMP socket: {e:#}");
            }

            // Keep the channel open so the requests are swallowed until the session idles out.
            while requests.recv().await.is_some() {}
            return;
        }
    };

    let mut buf = vec![0u8; UDP_MAX];

    loop {
        tokio::select! {
            request = requests.recv() => match request {
                None => break,
                Some(EchoRequest { sequence, payload, ttl }) => {
                    if let Err(e) = socket.send_echo(remote, identifier, sequence, &payload, ttl).await {
                        tracing::debug!(%flow, %remote, "Failed to send echo request: {e:#}");
                        let _ = events.send(Event::IcmpUnreachable { flow, sequence: Some(sequence) }).await;
                    }
                }
            },
            result = socket.recv(&mut buf) => match result {
                Ok((n, from)) => {
                    let Some(message) = icmp::parse(&buf[..n], remote.is_ipv4(), socket.strips_ip_header(), identifier) else {
                        continue;
                    };

                    let event = match message {
                        icmp::Message::EchoReply { sequence, payload } => Event::IcmpReply { flow, sequence, payload },
                        icmp::Message::Unreachable { sequence } => Event::IcmpUnreachable { flow, sequence: Some(sequence) },
                        icmp::Message::TimeExceeded { sequence } => Event::IcmpTimeExceeded { flow, sequence, from },
                    };

                    if events.send(event).await.is_err() {
                        break;
                    }
                }
                Err(e) => {
                    // Ping sockets report ICMP errors for the session as socket errors.
                    tracing::debug!(%flow, %remote, "ICMP socket error: {e}");
                    let _ = events.send(Event::IcmpUnreachable { flow, sequence: None }).await;
                }
            }
        }
    }
}

fn flow_number(flow: FlowId) -> u64 {
    // The display form is `flow#N`.
    flow.to_string()
        .trim_start_matches("flow#")
        .parse()
        .unwrap_or_default()
}

/// Ping sockets: datagram ICMP where the platform allows it unprivileged, raw ICMP otherwise.
mod icmp {
    use std::net::{IpAddr, SocketAddr};

    use anyhow::{Context as _, Result};
    use socket2::{Domain, Protocol, SockRef, Socket, Type};

    pub(super) struct PingSocket {
        inner: tokio::net::UdpSocket,
        /// Whether received messages start at the ICMP header; raw IPv4 sockets include the IP header.
        strips_ip_header: bool,
        ipv4: bool,
    }

    pub(super) enum Message {
        EchoReply { sequence: u16, payload: Vec<u8> },
        Unreachable { sequence: u16 },
        TimeExceeded { sequence: u16 },
    }

    pub(super) async fn open(remote: IpAddr, identifier: u16) -> Result<PingSocket> {
        let (domain, protocol) = match remote {
            IpAddr::V4(_) => (Domain::IPV4, Protocol::ICMPV4),
            IpAddr::V6(_) => (Domain::IPV6, Protocol::ICMPV6),
        };

        // Raw first where we may: it sees the ICMP errors a datagram socket only reports
        // as a failed receive. Not on Windows, where datagram ICMP does not exist.
        let attempts: &[Type] = if cfg!(windows) {
            &[Type::RAW]
        } else {
            &[Type::RAW, Type::DGRAM]
        };

        let mut last_error = None;
        for ty in attempts {
            match Socket::new(domain, *ty, Some(protocol)) {
                Ok(socket) => {
                    let strips_ip_header = *ty == Type::DGRAM || remote.is_ipv6();
                    let ping = configure(socket, remote, identifier, strips_ip_header, *ty)
                        .await
                        .with_context(|| format!("Failed to configure {ty:?} ICMP socket"))?;

                    return Ok(ping);
                }
                Err(e) => last_error = Some(e),
            }
        }

        Err(last_error.expect("at least one attempt")).context("Failed to open ICMP socket")
    }

    async fn configure(
        socket: Socket,
        remote: IpAddr,
        identifier: u16,
        strips_ip_header: bool,
        ty: Type,
    ) -> Result<PingSocket> {
        socket.set_nonblocking(true)?;

        let local = local_address_for(remote, ty).await?;

        // On Linux, the port of a datagram ICMP socket is the echo identifier the kernel
        // stamps on requests and matches replies with.
        let bind_port = if ty == Type::DGRAM { identifier } else { 0 };
        socket
            .bind(&SocketAddr::new(local, bind_port).into())
            .or_else(|_| socket.bind(&SocketAddr::new(local, 0).into()))
            .context("Failed to bind ICMP socket")?;

        let inner = tokio::net::UdpSocket::from_std(std::net::UdpSocket::from(socket))?;

        Ok(PingSocket {
            inner,
            strips_ip_header,
            ipv4: remote.is_ipv4(),
        })
    }

    /// Raw sockets on Windows receive only when bound to the interface address the
    /// traffic uses; elsewhere the unspecified address is fine.
    async fn local_address_for(remote: IpAddr, ty: Type) -> Result<IpAddr> {
        if !(cfg!(windows) && ty == Type::RAW) {
            return Ok(super::unspecified(remote).ip());
        }

        let probe = tokio::net::UdpSocket::bind(super::unspecified(remote)).await?;
        probe.connect(SocketAddr::new(remote, 9)).await?;

        Ok(probe.local_addr()?.ip())
    }

    impl PingSocket {
        pub(super) fn strips_ip_header(&self) -> bool {
            self.strips_ip_header
        }

        pub(super) async fn send_echo(
            &self,
            remote: IpAddr,
            identifier: u16,
            sequence: u16,
            payload: &[u8],
            ttl: u8,
        ) -> Result<()> {
            let sock = SockRef::from(&self.inner);
            if self.ipv4 {
                sock.set_ttl_v4(u32::from(ttl))?;
            } else {
                sock.set_unicast_hops_v6(u32::from(ttl))?;
            }

            let mut message = Vec::with_capacity(8 + payload.len());
            message.push(if self.ipv4 { 8 } else { 128 }); // Echo request.
            message.push(0);
            message.extend_from_slice(&[0, 0]); // Checksum.
            message.extend_from_slice(&identifier.to_be_bytes());
            message.extend_from_slice(&sequence.to_be_bytes());
            message.extend_from_slice(payload);

            if self.ipv4 {
                // The kernel computes the ICMPv6 checksum, not the ICMPv4 one.
                let checksum = internet_checksum(&message);
                message[2..4].copy_from_slice(&checksum.to_be_bytes());
            }

            self.inner
                .send_to(&message, SocketAddr::new(remote, 0))
                .await?;

            Ok(())
        }

        pub(super) async fn recv(&self, buf: &mut [u8]) -> std::io::Result<(usize, IpAddr)> {
            let (n, from) = self.inner.recv_from(buf).await?;

            Ok((n, from.ip()))
        }
    }

    /// Decodes a received ICMP message that concerns our `identifier`.
    pub(super) fn parse(
        mut data: &[u8],
        ipv4: bool,
        strips_ip_header: bool,
        identifier: u16,
    ) -> Option<Message> {
        if ipv4 && !strips_ip_header {
            let header_len = usize::from(*data.first()? & 0x0f) * 4;
            data = data.get(header_len..)?;
        }
        if data.len() < 8 {
            return None;
        }

        let (ty, code) = (data[0], data[1]);
        let (echo_reply, unreachable, time_exceeded) = if ipv4 { (0, 3, 11) } else { (129, 1, 3) };

        if ty == echo_reply {
            let id = u16::from_be_bytes([data[4], data[5]]);
            let sequence = u16::from_be_bytes([data[6], data[7]]);

            // Datagram sockets already demultiplexed by identifier.
            if strips_ip_header || id == identifier {
                return Some(Message::EchoReply {
                    sequence,
                    payload: data[8..].to_vec(),
                });
            }

            return None;
        }

        if ty != unreachable && ty != time_exceeded {
            return None;
        }
        let _ = code;

        // The quoted request: an IP header and the first bytes of our echo request.
        let quoted = data.get(8..)?;
        let quoted_icmp = if ipv4 {
            let header_len = usize::from(*quoted.first()? & 0x0f) * 4;
            quoted.get(header_len..)?
        } else {
            quoted.get(40..)?
        };
        if quoted_icmp.len() < 8 {
            return None;
        }

        let id = u16::from_be_bytes([quoted_icmp[4], quoted_icmp[5]]);
        let sequence = u16::from_be_bytes([quoted_icmp[6], quoted_icmp[7]]);
        if id != identifier {
            return None;
        }

        if ty == unreachable {
            Some(Message::Unreachable { sequence })
        } else {
            Some(Message::TimeExceeded { sequence })
        }
    }

    fn internet_checksum(data: &[u8]) -> u16 {
        let mut sum = 0u32;
        for chunk in data.chunks(2) {
            let word = match chunk {
                [a, b] => u16::from_be_bytes([*a, *b]),
                [a] => u16::from_be_bytes([*a, 0]),
                _ => 0,
            };
            sum += u32::from(word);
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xffff) + (sum >> 16);
        }

        !(sum as u16)
    }
}
