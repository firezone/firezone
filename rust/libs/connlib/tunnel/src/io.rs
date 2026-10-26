mod crypto;
mod device;
mod udp_gso_train;

pub(crate) use crypto::MAX_DECRYPT_BACKLOG_MEMORY;
pub use crypto::{
    CryptoWorkers, DecryptBatch, DecryptedDatagram, DecryptedIpPackets, EncryptBatch,
};
pub use device::{Device, TunChannelClosed};
pub(crate) use udp_gso_train::UdpGsoTrain;

use crate::{
    TunnelError, dns,
    resolver::{self, ResolverControl, ResolverQuery},
    sockets::{ReceivedDatagrams, Sockets},
};
use anyhow::Result;
use crypto::Decrypting;
use fast_random_state::FastRandomState;
use ip_packet::IpPacket;
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::{
    collections::HashMap,
    io,
    net::SocketAddr,
    sync::Arc,
    task::{Context, Poll},
};
use tun::Tun;

/// Bundles together all side-effects that connlib needs to have access to.
pub struct Io {
    /// The UDP sockets used to send & receive packets from the network.
    sockets: Sockets,
    crypto: CryptoWorkers,
    decrypting: Decrypting,
    resolver: resolver::EventLoopEnds,

    udp_dns_server: HashMap<SocketAddr, l4_udp_dns_server::Server, FastRandomState>,
    tcp_dns_server: HashMap<SocketAddr, l4_tcp_dns_server::Server, FastRandomState>,

    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,

    tun: Device,
}

/// Represents all IO sources that may be ready during a single event-loop tick.
///
/// This structure allows us to batch-process multiple ready sources rather than
/// handling them one at a time, improving fairness and preventing starvation.
pub struct Input {
    pub device: Option<tun::PacketBatch>,
    pub network: Option<ReceivedDatagrams>,
    pub decrypted: Option<DecryptedIpPackets>,
    pub tcp_dns_queries: Vec<l4_tcp_dns_server::Query>,
    pub udp_dns_queries: Vec<l4_udp_dns_server::Query>,
    pub dns_responses: Vec<dns::RecursiveResponse>,
    pub error: TunnelError,
}

fn poll_to_option<T>(poll: Poll<T>) -> Option<T> {
    match poll {
        Poll::Ready(r) => Some(r),
        Poll::Pending => None,
    }
}

fn poll_result_to_option<T, E>(poll: Poll<Result<T, E>>, error: &mut TunnelError) -> Option<T>
where
    anyhow::Error: From<E>,
{
    match poll {
        Poll::Ready(Ok(r)) => Some(r),
        Poll::Ready(Err(e)) => {
            error.push(e);

            None
        }
        Poll::Pending => None,
    }
}

/// The state of a single [`Io::poll`] call.
struct PollState<'a, 'cx> {
    io: &'a mut Io,
    cx: &'a mut Context<'cx>,
    udp_has_room: bool,
    tun_has_room: bool,
    input: Input,
}

impl<'a, 'cx> PollState<'a, 'cx> {
    fn new(io: &'a mut Io, cx: &'a mut Context<'cx>) -> Self {
        Self {
            io,
            cx,
            udp_has_room: false,
            tun_has_room: false,
            input: Input {
                device: None,
                network: None,
                decrypted: None,
                tcp_dns_queries: Vec::new(),
                udp_dns_queries: Vec::new(),
                dns_responses: Vec::new(),
                error: TunnelError::default(),
            },
        }
    }

    fn flush_udp(&mut self) {
        let poll = self.io.sockets.poll_flush(self.cx);

        self.udp_has_room = poll_result_to_option(poll, &mut self.input.error).is_some();
    }

    fn flush_tun(&mut self) {
        let poll = self.io.tun.poll_flush(self.cx);

        self.tun_has_room = poll_result_to_option(poll, &mut self.input.error).is_some();
    }

    fn poll_decrypted(&mut self) {
        if !self.tun_has_room {
            return;
        }

        self.input.decrypted = poll_to_option(self.io.decrypting.poll_next(self.cx));
    }

    fn poll_network(&mut self) {
        if !self.io.decrypting.has_room() {
            return;
        }

        self.input.network = poll_to_option(self.io.sockets.poll_recv_from(self.cx));
    }

    fn poll_socket_errors(&mut self) {
        while let Poll::Ready(e) = self.io.sockets.poll_error(self.cx) {
            self.input.error.push(e);
        }
    }

    fn poll_device(&mut self) {
        if !self.udp_has_room {
            return;
        }

        let poll = self.io.tun.poll_read(self.cx);

        self.input.device = poll_result_to_option(poll, &mut self.input.error);
    }

    fn poll_dns_queries(&mut self) {
        for server in self.io.udp_dns_server.values_mut() {
            if let Some(query) = poll_result_to_option(server.poll(self.cx), &mut self.input.error)
            {
                self.input.udp_dns_queries.push(query);
            }
        }

        for server in self.io.tcp_dns_server.values_mut() {
            if let Some(query) = poll_result_to_option(server.poll(self.cx), &mut self.input.error)
            {
                self.input.tcp_dns_queries.push(query);
            }
        }
    }

    fn poll_dns_responses(&mut self) {
        self.io
            .resolver
            .poll_responses(self.cx, &mut self.input.dns_responses);
    }

    fn into_input(self) -> Poll<Input> {
        let input = self.input;

        if input.device.is_none()
            && input.network.is_none()
            && input.decrypted.is_none()
            && input.tcp_dns_queries.is_empty()
            && input.udp_dns_queries.is_empty()
            && input.dns_responses.is_empty()
            && input.error.is_empty()
        {
            return Poll::Pending;
        }

        Poll::Ready(input)
    }
}

impl Io {
    pub fn new(
        sockets: Sockets,
        crypto: CryptoWorkers,
        resolver: resolver::EventLoopEnds,
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    ) -> Self {
        Self {
            sockets,
            crypto,
            decrypting: Decrypting::default(),
            resolver,
            udp_dns_server: Default::default(),
            tcp_dns_server: Default::default(),
            tcp_socket_factory,
            udp_socket_factory,
            tun: Device::new(),
        }
    }

    pub fn rebind_dns(&mut self, sockets: Vec<SocketAddr>) -> Result<(), TunnelError> {
        tracing::debug!(?sockets, "Rebinding DNS servers");

        self.udp_dns_server.clear();
        self.tcp_dns_server.clear();

        let mut error = TunnelError::default();

        for socket in sockets {
            let mut udp = l4_udp_dns_server::Server::default();
            let mut tcp = l4_tcp_dns_server::Server::default();

            match udp.rebind(socket) {
                Ok(()) => {
                    self.udp_dns_server.insert(socket, udp);
                }
                Err(e) => {
                    error.push(e);
                }
            };
            match tcp.rebind(socket) {
                Ok(()) => {
                    self.tcp_dns_server.insert(socket, tcp);
                }
                Err(e) => {
                    error.push(e);
                }
            };
        }

        if !error.is_empty() {
            self.udp_dns_server.clear();
            self.tcp_dns_server.clear();

            return Err(error);
        }

        Ok(())
    }

    pub fn send_resolver_control(&self, control: ResolverControl) {
        self.resolver.send_control(control);
    }

    /// Polls all IO sources that are ready.
    ///
    /// The TUN device is only read while nothing waits for room in the UDP sockets, and decrypted
    /// packets are only accepted while the TUN device has room.
    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<Input> {
        let mut state = PollState::new(self, cx);

        state.flush_udp();
        state.flush_tun();
        state.poll_decrypted();
        state.poll_network();
        state.poll_socket_errors();
        state.poll_device();
        state.poll_dns_queries();
        state.poll_dns_responses();

        state.into_input()
    }

    pub fn flush(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        let mut any_pending = false;

        if self.sockets.poll_flush(cx)?.is_pending() {
            any_pending = true
        }

        if self.tun.poll_flush(cx)?.is_pending() {
            any_pending = true;
        }

        if any_pending {
            return Poll::Pending;
        }

        Poll::Ready(Ok(()))
    }

    pub fn set_tun(&mut self, tun: Box<dyn Tun>) {
        self.tun.set_tun(tun);
    }

    pub fn queue_tun(&mut self, packet: IpPacket) {
        self.tun.queue(packet);
    }

    /// Marks the end of the current batch of packets queued via [`Io::queue_tun`].
    pub fn flush_tun_batch(&mut self) {
        self.tun.flush_batch();
    }

    pub fn reset(&mut self) {
        self.tcp_socket_factory.reset();
        self.udp_socket_factory.reset();
        self.sockets.rebind();
        self.resolver.send_control(ResolverControl::Reset);
    }

    /// Starts a batch of encapsulated packets to encrypt off the main thread.
    ///
    /// Its datagrams go to the UDP sockets when it is dropped. Start one only for the packets
    /// [`Io::poll`] read from the TUN device, which it does only while nothing waits for room in the
    /// UDP sockets.
    pub fn start_encrypt_batch(&mut self, num_packets: usize) -> EncryptBatch<'_> {
        self.crypto
            .start_encrypt_batch(&mut self.sockets, num_packets)
    }

    /// Starts a batch of received data messages to decrypt off the main thread, yielding them via
    /// [`Input::decrypted`].
    pub fn start_decrypt_batch(&mut self, num_packets: usize) -> DecryptBatch<'_> {
        self.crypto
            .start_decrypt_batch(&mut self.decrypting, num_packets)
    }

    pub fn send_network(&mut self, transmit: snownet::Transmit) {
        self.sockets.send_ready(transmit);
    }

    pub fn send_dns_query(&self, query: ResolverQuery) {
        self.resolver.send_query(query);
    }

    pub(crate) fn send_udp_dns_response(
        &mut self,
        to: SocketAddr,
        from: SocketAddr,
        message: dns_types::Response,
    ) -> io::Result<()> {
        self.udp_dns_server
            .get_mut(&from)
            .ok_or(io::Error::other("No DNS server"))?
            .send_response(to, message)
    }

    pub(crate) fn send_tcp_dns_response(
        &mut self,
        to: SocketAddr,
        from: SocketAddr,
        message: dns_types::Response,
    ) -> io::Result<()> {
        self.tcp_dns_server
            .get_mut(&from)
            .ok_or(io::Error::other("No DNS server"))?
            .send_response(to, message)
    }
}

#[cfg(test)]
mod tests;
