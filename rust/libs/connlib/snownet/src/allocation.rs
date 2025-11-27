use crate::{
    backoff::{self, ExponentialBackoff},
    channel_data,
    node::{SessionId, Transmit},
};
use bufferpool::BufferPool;
use bytecodec::{DecodeExt as _, EncodeExt as _};
use hex_display::HexDisplayExt as _;
use ip_packet::Ecn;
use logging::err_with_src;
use rand::random;
use ringbuffer::{AllocRingBuffer, RingBuffer as _};
use std::{
    collections::{BTreeMap, VecDeque},
    iter,
    net::{SocketAddr, SocketAddrV4, SocketAddrV6},
    time::{Duration, Instant},
};
use str0m::{Candidate, net::Protocol};
use stun_codec::{
    DecodedMessage, Message, MessageClass, MessageDecoder, MessageEncoder, TransactionId,
    rfc5389::{
        attributes::{
            ErrorCode, MessageIntegrity, Nonce, Realm, Software, Username, XorMappedAddress,
        },
        errors::{StaleNonce, Unauthorized, UnknownAttribute},
        methods::BINDING,
    },
    rfc5766::{
        attributes::{
            ChannelNumber, Lifetime, RequestedTransport, XorPeerAddress, XorRelayAddress,
        },
        errors::AllocationMismatch,
        methods::{ALLOCATE, CHANNEL_BIND, REFRESH},
    },
    rfc8656::attributes::AdditionalAddressFamily,
};
use tracing::{Span, field};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(1);
const REQUEST_MAX_ELAPSED: Duration = Duration::from_secs(8);

/// How often to send a STUN binding request after the initial connection to the relay.
///
/// Most NATs keep _confirmed_ UDP bindings around for 120s.
/// Unconfirmed UDP bindings are usually kept around for 30s.
/// The binding interval here is chosen very conservatively to reflect these.
/// It ain't much traffic and with a lower interval, these checks can also help in disconnecting from an unresponsive relay.
const BINDING_INTERVAL: Duration = Duration::from_secs(25);

/// Represents a TURN allocation that refreshes itself.
///
/// Allocations have a lifetime and need to be continuously refreshed to stay active.
pub struct Allocation {
    /// The known sockets of the relay.
    server: RelaySocket,
    /// The socket we have chosen to use to communicate with the relay.
    ///
    /// A relay may be reachable on IPv4, IPv6 or both.
    /// At the same time, we may have an IPv4 or IPv6 interface or both.
    ///
    /// To figure out, how to communicate with the relay, we start by sending a BINDING request on all known sockets.
    /// Whatever comes back first, wins.
    ///
    /// Once set, we send STUN binding requests at an interval of [`BINDING_INTERVAL`].
    /// This ensures any NAT bindings stay alive even if the allocation is completely idle.
    active_socket: Option<ActiveSocket>,

    software: Software,

    /// If present, the IPv4 address we received traffic on.
    ip4_host_candidate: Option<Candidate>,
    /// If present, the IPv6 address we received traffic on.
    ip6_host_candidate: Option<Candidate>,
    /// If present, the IPv4 address the relay observed for us.
    ip4_srflx_candidate: Option<Candidate>,
    /// If present, the IPv6 address the relay observed for us.
    ip6_srflx_candidate: Option<Candidate>,
    /// If present, the IPv4 socket the relay allocated for us.
    ip4_allocation: Option<Candidate>,
    /// If present, the IPv6 socket the relay allocated for us.
    ip6_allocation: Option<Candidate>,

    /// When we received the allocation and how long it is valid.
    allocation_lifetime: Option<(Instant, Duration)>,

    buffered_transmits: VecDeque<Transmit>,
    events: VecDeque<Event>,

    sent_requests: BTreeMap<TransactionId, (SocketAddr, Message<Attribute>, ExponentialBackoff)>,

    channel_bindings: ChannelBindings,
    buffered_channel_bindings: AllocRingBuffer<SocketAddr>,

    credentials: Option<Credentials>,

    explicit_failure: Option<FreeReason>,

    buffer_pool: BufferPool<Vec<u8>>,
}

#[derive(derive_more::Debug, Clone, Copy)]
#[debug("{addr}")]
struct ActiveSocket {
    addr: SocketAddr,
    next_binding: Instant,
}

#[derive(Debug, PartialEq)]
pub(crate) enum Event {
    New(Candidate),
    Invalid(Candidate),
}

#[derive(Debug, Clone)]
struct Credentials {
    username: Username,
    password: String,
    realm: Realm,
    nonce: Option<Nonce>,
}

/// Describes the socket address(es) we know about the relay.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum RelaySocket {
    /// The relay is only reachable via IPv4.
    V4(SocketAddrV4),
    /// The relay is only reachable via IPv6.
    V6(SocketAddrV6),
    /// The relay is reachable via IPv4 and IPv6.
    Dual { v4: SocketAddrV4, v6: SocketAddrV6 },
}

impl RelaySocket {
    pub fn as_v4(&self) -> Option<&SocketAddrV4> {
        match self {
            Self::V4(v4) => Some(v4),
            Self::V6(_) => None,
            Self::Dual { v4, .. } => Some(v4),
        }
    }

    pub fn as_v6(&self) -> Option<&SocketAddrV6> {
        match self {
            Self::V4(_) => None,
            Self::V6(v6) => Some(v6),
            Self::Dual { v6, .. } => Some(v6),
        }
    }

    pub fn matches(&self, candidate: SocketAddr) -> bool {
        let matches_v4 = self
            .as_v4()
            .is_some_and(|v4| SocketAddr::V4(*v4) == candidate);
        let matches_v6 = self
            .as_v6()
            .is_some_and(|v6| SocketAddr::V6(*v6) == candidate);

        matches_v4 || matches_v6
    }
}

impl From<SocketAddr> for RelaySocket {
    fn from(value: SocketAddr) -> Self {
        match value {
            SocketAddr::V4(inner) => RelaySocket::V4(inner),
            SocketAddr::V6(inner) => RelaySocket::V6(inner),
        }
    }
}

impl From<SocketAddrV4> for RelaySocket {
    fn from(value: SocketAddrV4) -> Self {
        RelaySocket::V4(value)
    }
}

impl From<SocketAddrV6> for RelaySocket {
    fn from(value: SocketAddrV6) -> Self {
        RelaySocket::V6(value)
    }
}

impl From<(SocketAddrV4, SocketAddrV6)> for RelaySocket {
    fn from((v4, v6): (SocketAddrV4, SocketAddrV6)) -> Self {
        RelaySocket::Dual { v4, v6 }
    }
}

/// A socket that has been allocated on a TURN server.
///
/// Note that any combination of IP versions is possible here.
/// We might have allocated an IPv6 address on a TURN server that we are talking to IPv4 and vice versa.
#[derive(Debug, Clone, Copy)]
pub struct Socket {
    /// The address of the socket that was allocated.
    address: SocketAddr,
}

impl Socket {
    pub fn address(&self) -> SocketAddr {
        self.address
    }
}

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum FreeReason {
    #[error("authentication error")]
    AuthenticationError,
    #[error("no response received. Is STUN blocked?")]
    NoResponseReceived,
    #[error("TURN protocol failure")]
    ProtocolFailure,
}

impl Allocation {
    pub fn new(
        server: RelaySocket,
        username: Username,
        password: String,
        realm: Realm,
        now: Instant,
        session_id: SessionId,
        buffer_pool: BufferPool<Vec<u8>>,
    ) -> Self {
        let mut allocation = Self {
            server,
            active_socket: None,
            ip4_host_candidate: Default::default(),
            ip6_host_candidate: Default::default(),
            ip4_srflx_candidate: Default::default(),
            ip6_srflx_candidate: Default::default(),
            ip4_allocation: Default::default(),
            ip6_allocation: Default::default(),
            buffered_transmits: Default::default(),
            events: Default::default(),
            sent_requests: Default::default(),
            credentials: Some(Credentials {
                username,
                password,
                realm,
                nonce: Default::default(),
            }),
            allocation_lifetime: Default::default(),
            channel_bindings: Default::default(),
            buffered_channel_bindings: AllocRingBuffer::new(100),
            software: Software::new(format!("snownet; session={session_id}"))
                .expect("description has less then 128 chars"),
            explicit_failure: Default::default(),
            buffer_pool,
        };

        allocation.send_binding_requests(now);

        allocation
    }

    pub fn host_and_server_reflexive_candidates(&self) -> impl Iterator<Item = Candidate> + use<> {
        [
            self.ip4_host_candidate.clone(),
            self.ip6_host_candidate.clone(),
            self.ip4_srflx_candidate.clone(),
            self.ip6_srflx_candidate.clone(),
        ]
        .into_iter()
        .flatten()
    }

    pub fn current_relay_candidates(&self) -> impl Iterator<Item = Candidate> + use<> {
        [self.ip4_allocation.clone(), self.ip6_allocation.clone()]
            .into_iter()
            .flatten()
    }

    /// Refresh this allocation.
    ///
    /// In case refreshing the allocation fails, we will attempt to make a new one.
    #[tracing::instrument(level = "debug", skip_all, fields(active_socket = ?self.active_socket))]
    pub fn refresh(&mut self, now: Instant) {
        if !self.has_allocation() && self.allocate_in_flight() {
            tracing::debug!("Not refreshing allocation because we are already making one");
            return;
        }

        if self.is_suspended() {
            tracing::debug!("Attempting to make a new allocation");

            self.active_socket = None;
            self.send_binding_requests(now);
            return;
        }

        tracing::debug!("Refreshing allocation");

        // By using the `REQUEST_TIMEOUT` for timeout and max_elapsed, we effectively only perform
        // a single request.
        //
        // When pro-actively refreshing the allocation, we don't want to timeout after 8s but much earlier.
        let backoff = backoff::new(now, REQUEST_TIMEOUT, REQUEST_TIMEOUT);

        self.authenticate_and_queue(
            make_refresh_request(self.software.clone()),
            Some(backoff),
            now,
        );
    }

    #[tracing::instrument(level = "debug", skip_all, fields(%from, tid, method, class, rtt))]
    pub fn handle_input(
        &mut self,
        from: SocketAddr,
        local: SocketAddr,
        message: Message<Attribute>,
        now: Instant,
    ) -> bool {
        debug_assert_eq!(
            from.is_ipv4(),
            local.is_ipv4(),
            "`from` and `local` to have the same IP version"
        );

        if !self.server.matches(from) {
            return false;
        }

        let transaction_id = message.transaction_id();

        Span::current().record(
            "tid",
            field::display(format_args!("{:X}", transaction_id.as_bytes().hex())),
        );
        Span::current().record("method", field::display(message.method()));
        Span::current().record("class", field::display(message.class()));

        // Early return to avoid cryptographic work in case it isn't our message.
        if !self.sent_requests.contains_key(&transaction_id) {
            return false;
        }

        let passed_message_integrity_check = self.check_message_integrity(&message);

        if message.method() != BINDING && !passed_message_integrity_check {
            // We don't want to `remove` the message here otherwise an attacker could change our state with unauthenticated messages.
            let request = self
                .sent_requests
                .get(&transaction_id)
                .map(|(_, r, _)| r.attributes().map(display_attr).collect::<Vec<_>>());
            let response = message.attributes().map(display_attr).collect::<Vec<_>>();

            tracing::warn!(?request, ?response, "Message integrity check failed");
            return true; // The message still indicated that it was for this `Allocation`.
        }

        let Some((original_dst, original_request, backoff)) =
            self.sent_requests.remove(&transaction_id)
        else {
            return false;
        };

        let rtt = now.duration_since(backoff.start_time());
        Span::current().record("rtt", field::debug(rtt));

        if tracing::enabled!(target: "wire::turn", tracing::Level::DEBUG) {
            let request = original_request
                .attributes()
                .map(display_attr)
                .collect::<Vec<_>>();
            let response = message.attributes().map(display_attr).collect::<Vec<_>>();

            tracing::debug!(target: "wire::turn", ?request, ?response);
        }

        if let Some(error) = message.get_attribute::<ErrorCode>() {
            // If we sent a nonce but receive 401 instead of 438 then our credentials are invalid.
            if error.code() == Unauthorized::CODEPOINT
                && original_request.get_attribute::<Nonce>().is_some()
            {
                tracing::warn!(
                    "Invalid credentials, refusing to re-authenticate {}",
                    original_request.method()
                );
                self.credentials = None;
                self.invalidate_allocation();

                return true;
            }

            // Check if we need to re-authenticate the original request
            if error.code() == Unauthorized::CODEPOINT || error.code() == StaleNonce::CODEPOINT {
                let Some(Credentials { nonce, realm, .. }) = &mut self.credentials else {
                    return true;
                };

                if let Some(new_nonce) = message.get_attribute::<Nonce>() {
                    let _ = nonce.insert(new_nonce.clone());
                };

                if let Some(offered_realm) = message.get_attribute::<Realm>()
                    && offered_realm != realm
                {
                    tracing::warn!(allowed_realm = %realm.text(), server_realm = %offered_realm.text(), "Refusing to authenticate with server");
                    return true; // We still handled our message correctly.
                };

                tracing::debug!(
                    error = error.reason_phrase(),
                    "Request failed, re-authenticating"
                );

                self.authenticate_and_queue(original_request, None, now);

                return true;
            }

            // If we receive an allocation mismatch, we need to clear our local state.
            if error.code() == AllocationMismatch::CODEPOINT {
                self.invalidate_allocation();

                match message.method() {
                    ALLOCATE => {
                        // AllocationMismatch during allocate means we already have an allocation.
                        // Delete it.
                        self.authenticate_and_queue(
                            make_delete_allocation_request(self.software.clone()),
                            None,
                            now,
                        );

                        tracing::debug!("Deleting existing allocation to re-sync");
                    }
                    REFRESH => {
                        // AllocationMismatch for refresh means we don't have an allocation.
                        // Make one.
                        self.authenticate_and_queue(
                            make_allocate_request(self.software.clone()),
                            None,
                            now,
                        );

                        tracing::debug!("Making new allocation to re-sync");
                    }
                    CHANNEL_BIND => {
                        // AllocationMismatch for channel-bind means we don't have an allocation.
                        // Make one.
                        self.authenticate_and_queue(
                            make_allocate_request(self.software.clone()),
                            None,
                            now,
                        );

                        tracing::debug!("Making new allocation to re-sync");

                        // Re-queue the failed channel binding.
                        let peer = original_request
                            .get_attribute::<XorPeerAddress>()
                            .map(|c| c.address());
                        self.buffered_channel_bindings.extend(peer);
                    }
                    _ => {}
                }

                return true;
            }

            if error.code() == UnknownAttribute::CODEPOINT {
                let attributes = message.unknown_attributes().collect::<Vec<_>>();

                tracing::warn!(
                    ?attributes,
                    "Server did not understand one or more attributes in our request"
                );
                self.explicit_failure = Some(FreeReason::ProtocolFailure);

                return true;
            }

            // Catch-all error handling if none of the above apply.
            match message.method() {
                ALLOCATE => {
                    self.buffered_channel_bindings.clear();
                }
                CHANNEL_BIND => {
                    let Some(channel) = original_request
                        .get_attribute::<ChannelNumber>()
                        .map(|c| c.value())
                    else {
                        tracing::warn!("Request did not contain a `CHANNEL-NUMBER`");
                        return true;
                    };
                    let Some(peer) = original_request
                        .get_attribute::<XorPeerAddress>()
                        .map(|c| c.address())
                    else {
                        tracing::warn!("Request did not contain a `XOR-PEER-ADDRESS`");
                        return true;
                    };

                    self.channel_bindings.handle_failed_binding(channel);

                    // Duplicate log here because we want to attach "channel number" and "peer".
                    tracing::warn!(error = %error.reason_phrase(), %channel, %peer, "Channel bind failed");
                    return true;
                }
                _ => {}
            }

            tracing::warn!(error = %error.reason_phrase(), code = %error.code(), "TURN request failed with unhandled error code");

            return true;
        }

        if message.class() != MessageClass::SuccessResponse {
            tracing::warn!("Can only handle success messages from here");
            return true;
        }

        debug_assert_eq!(
            message.method(),
            original_request.method(),
            "Method of response should match the one from our request"
        );

        match message.method() {
            BINDING => {
                // First, see if we need to update our host candidate.
                let current_host_candidate = match local {
                    SocketAddr::V4(_) => &mut self.ip4_host_candidate,
                    SocketAddr::V6(_) => &mut self.ip6_host_candidate,
                };

                let maybe_candidate = Candidate::host(local, Protocol::Udp).ok();
                if update_candidate(maybe_candidate, current_host_candidate, &mut self.events) {
                    self.log_update(now);
                }

                // Second, process the binding request itself.
                let current_srflx_candidate = match original_dst {
                    SocketAddr::V4(_) => &mut self.ip4_srflx_candidate,
                    SocketAddr::V6(_) => &mut self.ip6_srflx_candidate,
                };

                let maybe_candidate = message.attributes().find_map(|a| srflx_candidate(local, a));
                if update_candidate(maybe_candidate, current_srflx_candidate, &mut self.events) {
                    self.log_update(now);
                }

                // Third, check if we have already determined which socket to use for this relay.
                // We send 2 BINDING requests to start with (one for each IP version) and the first one coming back wins.
                // Thus, if we already have a socket set, we are done with processing this binding request.

                if let Some(active_socket) = self.active_socket.as_ref() {
                    // We also use binding requests to keep NAT bindings alive. For those
                    // replies, these sockets will always be the same. Only log if we
                    // actually have two different sockets to choose from.
                    if active_socket.addr != original_dst {
                        tracing::debug!(active_socket = %active_socket.addr, additional_socket = %original_dst, "Relay supports dual-stack but we've already picked a socket");
                    }

                    return true;
                }

                // If the socket isn't set yet, use the `original_dst` as the primary socket.
                self.active_socket = Some(ActiveSocket::new(original_dst, now));

                tracing::debug!(active_socket = %original_dst, "Updating active socket");

                if self.has_allocation() {
                    self.authenticate_and_queue(
                        make_refresh_request(self.software.clone()),
                        None,
                        now,
                    );
                } else {
                    self.authenticate_and_queue(
                        make_allocate_request(self.software.clone()),
                        None,
                        now,
                    );
                }
            }
            ALLOCATE => {
                let Some(lifetime) = message.get_attribute::<Lifetime>().map(|l| l.lifetime())
                else {
                    tracing::warn!("Message does not contain `LIFETIME`");
                    return true;
                };

                let maybe_ip4_relay_candidate = message
                    .attributes()
                    .find_map(relay_candidate(local, |s| s.is_ipv4()));
                let maybe_ip6_relay_candidate = message
                    .attributes()
                    .find_map(relay_candidate(local, |s| s.is_ipv6()));

                if maybe_ip4_relay_candidate.is_none() && maybe_ip6_relay_candidate.is_none() {
                    tracing::warn!("Relay sent a successful allocate response without addresses");
                    return true;
                }

                self.allocation_lifetime = Some((now, lifetime));
                update_candidate(
                    maybe_ip4_relay_candidate,
                    &mut self.ip4_allocation,
                    &mut self.events,
                );
                update_candidate(
                    maybe_ip6_relay_candidate,
                    &mut self.ip6_allocation,
                    &mut self.events,
                );

                self.log_update(now);

                while let Some(peer) = self.buffered_channel_bindings.dequeue() {
                    debug_assert!(
                        self.has_allocation(),
                        "We just received a successful allocation response"
                    );
                    self.bind_channel(peer, now);
                }
            }
            REFRESH => {
                let Some(lifetime) = message.get_attribute::<Lifetime>() else {
                    tracing::warn!("Message does not contain lifetime");
                    return true;
                };

                // If we refreshed with a lifetime of 0, we deleted our previous allocation.
                // Make a new one.
                if lifetime.lifetime().is_zero() {
                    self.authenticate_and_queue(
                        make_allocate_request(self.software.clone()),
                        None,
                        now,
                    );
                    return true;
                }

                self.allocation_lifetime = Some((now, lifetime.lifetime()));

                self.log_update(now);
            }
            CHANNEL_BIND => {
                let Some(channel) = original_request
                    .get_attribute::<ChannelNumber>()
                    .map(|c| c.value())
                else {
                    tracing::warn!("Request did not contain a `CHANNEL-NUMBER`");
                    return true;
                };

                if !self.channel_bindings.set_confirmed(channel, now) {
                    tracing::warn!(%channel, "Unknown channel");
                }
            }
            _ => {}
        }

        true
    }

    /// Attempts to decapsulate and incoming packet as a channel-data message.
    ///
    /// Returns the original sender, the packet and _our_ relay socket that this packet was sent to.
    /// Our relay socket is the destination that the remote peer sees for us.
    /// TURN is designed such that the remote has no knowledge of the existence of a relay.
    /// It simply sends data to a socket.
    pub fn decapsulate<'p>(
        &mut self,
        from: SocketAddr,
        packet: channel_data::Packet<'p>,
        now: Instant,
    ) -> Option<(SocketAddr, &'p [u8], Socket)> {
        if !self.server.matches(from) {
            tracing::trace!(?self.server, "Packet is not for this allocation");

            return None;
        }

        let (peer, payload) = self.channel_bindings.try_handle_packet(packet, now)?;

        // Our socket on the relay.
        // If the remote sent from an IP4 address, it must have been received on our IP4 allocation.
        // Same thing for IP6.
        let socket = match peer {
            SocketAddr::V4(_) => self.ip4_socket()?,
            SocketAddr::V6(_) => self.ip6_socket()?,
        };

        tracing::trace!(%peer, ?socket, "Decapsulated channel-data message");

        Some((peer, payload, socket))
    }

    #[tracing::instrument(level = "debug", skip_all, fields(active_socket = ?self.active_socket))]
    pub fn handle_timeout(&mut self, now: Instant) {
        if self
            .allocation_expires_at()
            .is_some_and(|expires_at| now >= expires_at)
        {
            tracing::debug!("Allocation is expired");

            self.invalidate_allocation();
        }

        if self.has_allocation()
            && let Some(addr) = self
                .active_socket
                .as_mut()
                .and_then(|a| a.handle_timeout(now))
        {
            self.queue(addr, make_binding_request(self.software.clone()), None, now);
        }

        while let Some(timed_out_request) = self
            .sent_requests
            .iter()
            .find_map(|(id, (_, _, backoff))| (now >= backoff.next_trigger()).then_some(*id))
        {
            let (dst, request, mut backoff) = self
                .sent_requests
                .remove(&timed_out_request)
                .expect("ID is from list");

            let backoff_duration = backoff.interval();
            let method = request.method();

            backoff.handle_timeout(now); // Must update timeout here to avoid an endless loop.

            tracing::debug!(id = ?request.transaction_id(), %method, %dst, "Request timed out after {backoff_duration:?}, re-sending");

            let needs_auth = method != BINDING;

            let queued = if needs_auth {
                self.authenticate_and_queue(request, Some(backoff), now)
            } else {
                self.queue(dst, request, Some(backoff), now)
            };

            // If we have an active socket (i.e. successfully sent at least 1 BINDING request)
            // and we just timed out a message, invalidate the allocation.
            if !queued
                && self
                    .active_socket
                    .is_some_and(|s| s.same_ip_version_as(dst))
            {
                self.active_socket = None; // The socket seems to no longer be reachable.
                self.invalidate_allocation();
            }
        }

        for (_, _, backoff) in self.sent_requests.values_mut() {
            backoff.handle_timeout(now);
        }

        if let Some(refresh_at) = self.refresh_allocation_at()
            && (now >= refresh_at)
            && !self.refresh_in_flight()
        {
            tracing::debug!("Allocation is due for a refresh");
            self.authenticate_and_queue(make_refresh_request(self.software.clone()), None, now);
        }

        let channel_refresh_messages = self
            .channel_bindings
            .channels_to_refresh(now, |number| {
                self.channel_binding_in_flight_by_number(number)
            })
            .inspect(|(number, peer)| {
                tracing::debug!(%number, %peer, "Channel is due for a refresh");
            })
            .map(|(number, peer)| make_channel_bind_request(peer, number, self.software.clone()))
            .collect::<Vec<_>>(); // Need to allocate here to satisfy borrow-checker. Number of channel refresh messages should be small so this shouldn't be a big impact.

        for message in channel_refresh_messages {
            self.authenticate_and_queue(message, None, now);
        }

        // TODO: Clean up unused channels
    }

    pub fn poll_event(&mut self) -> Option<Event> {
        self.events.pop_front()
    }

    pub fn poll_transmit(&mut self) -> Option<Transmit> {
        self.buffered_transmits.pop_front()
    }

    pub fn poll_timeout(&self) -> Option<(Instant, &'static str)> {
        let next_refresh = if !self.refresh_in_flight() {
            self.refresh_allocation_at()
                .map(|refresh_at| (refresh_at, "refresh allocation"))
        } else {
            None
        };

        let next_timeout = self
            .sent_requests
            .values()
            .map(|(_, _, b)| (b.next_trigger(), "resend TURN message"));

        let next_keepalive = if self.has_allocation() {
            self.active_socket
                .map(|a| (a.next_binding, "TURN keep-alive"))
        } else {
            None
        };

        iter::empty()
            .chain(next_refresh)
            .chain(next_keepalive)
            .chain(next_timeout)
            .min_by_key(|(instant, _)| *instant)
    }

    #[tracing::instrument(level = "debug", skip(self, now), fields(active_socket = ?self.active_socket))]
    pub fn bind_channel(&mut self, peer: SocketAddr, now: Instant) {
        if self.is_suspended() {
            tracing::debug!("Allocation is suspended");
            return;
        }

        if self
            .channel_bindings
            .connected_channel_to_peer(peer, now)
            .is_some()
        {
            tracing::debug!("Already got a channel");
            return;
        }

        if self.channel_binding_in_flight_by_peer(peer) {
            tracing::debug!("Already binding a channel to peer");
            return;
        }

        if !self.has_allocation() {
            tracing::debug!("No allocation yet, buffering channel binding");

            self.buffered_channel_bindings.enqueue(peer);
            return;
        }

        if !self.can_relay_to(peer) {
            tracing::debug!("Allocation cannot relay to this IP version");
            return;
        }

        let Some(channel) = self.channel_bindings.new_channel_to_peer(peer, now) else {
            tracing::warn!("All channels are exhausted");
            return;
        };

        tracing::debug!(number = %channel, "Binding new channel");

        self.authenticate_and_queue(
            make_channel_bind_request(peer, channel, self.software.clone()),
            None,
            now,
        );
    }

    pub fn encode_channel_data_header(
        &mut self,
        peer: SocketAddr,
        buffer: &mut [u8],
        now: Instant,
    ) -> Option<EncodeOk> {
        let active_socket = self.active_socket?.addr;
        let payload_length = buffer.len() - 4;

        let connected_channel_to_peer = self.channel_bindings.connected_channel_to_peer(peer, now);
        let inflight_channel_to_peer = self.channel_bindings.inflight_channel_to_peer(peer, now);

        // We use connected and in-flight channels in order to optimistically send data.
        // Chances are, by the time the channel data message arrives, the channel will have been bound already.
        // Whether or not we drop the packet here or on the relay if happened to not be bound does not matter.
        let channel_number = match connected_channel_to_peer.or(inflight_channel_to_peer) {
            Some(cn) => cn,
            None => {
                self.bind_channel(peer, now);

                return None;
            }
        };
        crate::channel_data::encode_header_to_slice(
            &mut buffer[..4],
            channel_number,
            payload_length,
        );

        Some(EncodeOk {
            socket: active_socket,
        })
    }

    /// Whether this [`Allocation`] can be freed.
    ///
    /// This is tied to having our credentials cleared (i.e due to an authentication error) and having emitted all events or not having received a single response.
    pub fn can_be_freed(&mut self) -> Option<FreeReason> {
        if let Some(reason) = self.explicit_failure.take() {
            return Some(reason);
        }

        let pending_work = !self.events.is_empty()
            || !self.buffered_transmits.is_empty()
            || !self.sent_requests.is_empty();

        let no_responses = !self.received_any_response();
        let auth_failure = !self.has_credentials();

        if !pending_work && no_responses {
            return Some(FreeReason::NoResponseReceived);
        }

        if !pending_work && auth_failure {
            return Some(FreeReason::AuthenticationError);
        }

        None
    }

    pub fn received_any_response(&self) -> bool {
        self.active_socket.is_some()
    }

    pub fn has_credentials(&self) -> bool {
        self.credentials.is_some()
    }

    pub fn matches_credentials(&self, username: &Username, password: &str) -> bool {
        self.credentials
            .as_ref()
            .is_some_and(|c| &c.username == username && c.password == password)
    }

    pub fn matches_socket(&self, socket: &RelaySocket) -> bool {
        &self.server == socket
    }

    fn log_update(&self, now: Instant) {
        tracing::debug!(
            host_ip4 = ?self.ip4_host_candidate.as_ref().map(|c| c.addr()),
            host_ip6 = ?self.ip6_host_candidate.as_ref().map(|c| c.addr()),
            srflx_ip4 = ?self.ip4_srflx_candidate.as_ref().map(|c| c.addr()),
            srflx_ip6 = ?self.ip6_srflx_candidate.as_ref().map(|c| c.addr()),
            relay_ip4 = ?self.ip4_allocation.as_ref().map(|c| c.addr()),
            relay_ip6 = ?self.ip6_allocation.as_ref().map(|c| c.addr()),
            remaining_lifetime = ?self.allocation_lifetime.and_then(|(created_at, d)| d.checked_sub(now.checked_duration_since(created_at)?)),
            "Updated allocation"
        );
    }

    fn refresh_allocation_at(&self) -> Option<Instant> {
        let (received_at, lifetime) = self.allocation_lifetime?;

        let refresh_after = lifetime / 2;

        Some(received_at + refresh_after)
    }

    fn allocation_expires_at(&self) -> Option<Instant> {
        let (received_at, lifetime) = self.allocation_lifetime?;

        Some(received_at + lifetime)
    }

    fn invalidate_allocation(&mut self) {
        tracing::info!(active_socket = ?self.active_socket, "Invalidating allocation");

        if let Some(candidate) = self.ip4_allocation.take() {
            self.events.push_back(Event::Invalid(candidate))
        }

        if let Some(candidate) = self.ip6_allocation.take() {
            self.events.push_back(Event::Invalid(candidate))
        }

        self.channel_bindings.clear();
        self.allocation_lifetime = None;
        self.sent_requests.clear();
    }

    /// Checks whether the given socket is part of this allocation.
    pub fn has_socket(&self, socket: SocketAddr) -> bool {
        let is_ip4 = self.ip4_socket().is_some_and(|s| s.address() == socket);
        let is_ip6 = self.ip6_socket().is_some_and(|s| s.address() == socket);

        is_ip4 || is_ip6
    }

    pub fn server(&self) -> RelaySocket {
        self.server
    }

    pub fn ip4_socket(&self) -> Option<Socket> {
        let address = self.ip4_allocation.as_ref().map(|c| c.addr())?;

        debug_assert!(address.is_ipv4());

        Some(Socket { address })
    }

    pub fn ip6_socket(&self) -> Option<Socket> {
        let address = self.ip6_allocation.as_ref().map(|c| c.addr())?;

        debug_assert!(address.is_ipv6());

        Some(Socket { address })
    }

    fn has_allocation(&self) -> bool {
        self.ip4_allocation.is_some() || self.ip6_allocation.is_some()
    }

    fn can_relay_to(&self, socket: SocketAddr) -> bool {
        match socket {
            SocketAddr::V4(_) => self.ip4_allocation.is_some(),
            SocketAddr::V6(_) => self.ip6_allocation.is_some(),
        }
    }

    fn channel_binding_in_flight_by_number(&self, channel: u16) -> bool {
        self.sent_requests.values().any(|(_, r, _)| {
            r.method() == CHANNEL_BIND
                && r.get_attribute::<ChannelNumber>()
                    .is_some_and(|n| n.value() == channel)
        })
    }

    fn channel_binding_in_flight_by_peer(&self, peer: SocketAddr) -> bool {
        let sent_requests = self
            .sent_requests
            .values()
            .map(|(_, r, _)| r)
            .filter(|message| message.method() == CHANNEL_BIND)
            .filter_map(|message| message.get_attribute::<XorPeerAddress>())
            .map(|a| a.address());
        let buffered = self.buffered_channel_bindings.iter().copied();

        sent_requests
            .chain(buffered)
            .any(|buffered| buffered == peer)
    }

    fn allocate_in_flight(&self) -> bool {
        self.sent_requests
            .values()
            .any(|(_, r, _)| r.method() == ALLOCATE)
    }

    fn refresh_in_flight(&self) -> bool {
        self.sent_requests
            .values()
            .any(|(_, r, _)| r.method() == REFRESH)
    }

    /// Check whether this allocation is suspended.
    ///
    /// We call it suspended if we have given up making an allocation due to some error.
    fn is_suspended(&self) -> bool {
        let no_allocation = !self.has_allocation();
        let nothing_in_flight = self.sent_requests.is_empty();
        let nothing_buffered = self.buffered_transmits.is_empty();
        let waiting_on_nothing = self.poll_timeout().is_none();

        no_allocation && nothing_in_flight && nothing_buffered && waiting_on_nothing
    }

    fn send_binding_requests(&mut self, now: Instant) {
        tracing::debug!(relay_socket = ?self.server, "Sending BINDING requests to pick active socket");

        if let Some(v4) = self.server.as_v4() {
            self.queue(
                (*v4).into(),
                make_binding_request(self.software.clone()),
                None,
                now,
            );
        }
        if let Some(v6) = self.server.as_v6() {
            self.queue(
                (*v6).into(),
                make_binding_request(self.software.clone()),
                None,
                now,
            );
        }
    }

    /// Returns: Whether we actually queued a message.
    fn authenticate_and_queue(
        &mut self,
        message: Message<Attribute>,
        backoff: Option<ExponentialBackoff>,
        now: Instant,
    ) -> bool {
        let Some(active_socket) = self.active_socket else {
            tracing::debug!(
                "Unable to queue {} because we haven't nominated a socket yet",
                message.method()
            );
            return false;
        };

        let Some(credentials) = &self.credentials else {
            tracing::debug!(
                "Unable to queue {} because we don't have credentials",
                message.method()
            );
            return false;
        };

        let authenticated_message = authenticate(message, credentials);
        self.queue(active_socket.addr, authenticated_message, backoff, now)
    }

    fn queue(
        &mut self,
        dst: SocketAddr,
        message: Message<Attribute>,
        backoff: Option<ExponentialBackoff>,
        now: Instant,
    ) -> bool {
        let backoff = backoff.unwrap_or(backoff::new(now, REQUEST_TIMEOUT, REQUEST_MAX_ELAPSED));
        let id = message.transaction_id();

        if backoff.is_expired(now) {
            tracing::debug!(?id, method = %message.method(), %dst, "Backoff expired, giving up");

            return false;
        }

        self.sent_requests
            .insert(id, (dst, message.clone(), backoff));

        self.buffered_transmits.push_back(Transmit {
            src: None,
            dst,
            payload: self.buffer_pool.pull_initialised(&encode(message)),
            ecn: Ecn::NonEct,
        });

        true
    }

    #[cfg(test)]
    fn check_message_integrity(&self, _: &Message<Attribute>) -> bool {
        true // In order to make the tests simpler, we skip the message integrity check there.
    }

    #[cfg(not(test))]
    fn check_message_integrity(&self, message: &Message<Attribute>) -> bool {
        let Some(mi) = message.get_attribute::<MessageIntegrity>() else {
            if message.method() != BINDING {
                tracing::debug!("Message does not have a `MessageIntegrity` attribute");
            }

            return false;
        };

        let Some(credentials) = &self.credentials else {
            tracing::debug!("Cannot check message integrity without credentials");

            return false;
        };

        mi.check_long_term_credential(
            &credentials.username,
            &credentials.realm,
            &credentials.password,
        )
        .is_ok()
    }
}

pub struct EncodeOk {
    pub socket: SocketAddr,
}

impl ActiveSocket {
    fn new(addr: SocketAddr, now: Instant) -> Self {
        Self {
            addr,
            next_binding: now + BINDING_INTERVAL,
        }
    }

    fn same_ip_version_as(&self, dst: SocketAddr) -> bool {
        self.addr.is_ipv4() == dst.is_ipv4()
    }

    fn handle_timeout(&mut self, now: Instant) -> Option<SocketAddr> {
        if now < self.next_binding {
            return None;
        }

        self.next_binding = now + BINDING_INTERVAL;

        Some(self.addr)
    }
}

fn authenticate(message: Message<Attribute>, credentials: &Credentials) -> Message<Attribute> {
    let attributes = message
        .attributes()
        .filter(|a| !matches!(a, Attribute::Nonce(_)))
        .filter(|a| !matches!(a, Attribute::MessageIntegrity(_)))
        .filter(|a| !matches!(a, Attribute::Realm(_)))
        .filter(|a| !matches!(a, Attribute::Username(_)))
        .cloned()
        .chain([
            Attribute::Username(credentials.username.clone()),
            Attribute::Realm(credentials.realm.clone()),
        ])
        .chain(credentials.nonce.clone().map(Attribute::Nonce));

    let transaction_id = TransactionId::new(random());
    let mut message = Message::new(MessageClass::Request, message.method(), transaction_id);

    for attribute in attributes {
        message.add_attribute(attribute.to_owned());
    }

    let message_integrity = MessageIntegrity::new_long_term_credential(
        &message,
        &credentials.username,
        &credentials.realm,
        &credentials.password,
    )
    .expect("signing never fails");

    message.add_attribute(message_integrity);

    message
}

/// Updates the current candidate to the new one if it differs.
///
/// Returns whether the candidate got updated.
fn update_candidate(
    maybe_new: Option<Candidate>,
    maybe_current: &mut Option<Candidate>,
    events: &mut VecDeque<Event>,
) -> bool {
    match (maybe_new, &maybe_current) {
        (Some(new), Some(current)) if &new != current => {
            events.push_back(Event::New(new.clone()));
            events.push_back(Event::Invalid(current.clone()));
            *maybe_current = Some(new);

            true
        }
        (Some(new), None) => {
            *maybe_current = Some(new.clone());
            events.push_back(Event::New(new));

            true
        }
        _ => false,
    }
}

fn make_binding_request(software: Software) -> Message<Attribute> {
    let mut message = Message::new(MessageClass::Request, BINDING, TransactionId::new(random()));
    message.add_attribute(software);

    message
}

fn make_allocate_request(software: Software) -> Message<Attribute> {
    let mut message = Message::new(
        MessageClass::Request,
        ALLOCATE,
        TransactionId::new(random()),
    );

    message.add_attribute(RequestedTransport::new(17));
    message.add_attribute(AdditionalAddressFamily::new(
        stun_codec::rfc8656::attributes::AddressFamily::V6,
    ));
    message.add_attribute(software);

    message
}

/// To delete an allocation, we need to refresh it with a lifetime of 0.
fn make_delete_allocation_request(software: Software) -> Message<Attribute> {
    let mut refresh = make_refresh_request(software);
    refresh.add_attribute(Lifetime::from_u32(0));

    refresh
}

fn make_refresh_request(software: Software) -> Message<Attribute> {
    let mut message = Message::new(MessageClass::Request, REFRESH, TransactionId::new(random()));

    message.add_attribute(RequestedTransport::new(17));
    message.add_attribute(AdditionalAddressFamily::new(
        stun_codec::rfc8656::attributes::AddressFamily::V6,
    ));
    message.add_attribute(software);

    message
}

fn make_channel_bind_request(
    target: SocketAddr,
    channel: u16,
    software: Software,
) -> Message<Attribute> {
    let mut message = Message::new(
        MessageClass::Request,
        CHANNEL_BIND,
        TransactionId::new(random()),
    );

    message.add_attribute(XorPeerAddress::new(target));
    message.add_attribute(ChannelNumber::new(channel).expect("channel number out of range")); // Panic is fine here, because we control the channel number within this module.
    message.add_attribute(software);

    message
}

fn srflx_candidate(local: SocketAddr, attr: &Attribute) -> Option<Candidate> {
    let Attribute::XorMappedAddress(a) = attr else {
        return None;
    };

    let new_candidate = match Candidate::server_reflexive(a.address(), local, Protocol::Udp) {
        Ok(c) => c,
        Err(e) => {
            tracing::debug!(
                "Observed address is not a valid candidate: {}",
                err_with_src(&e)
            );
            return None;
        }
    };

    Some(new_candidate)
}

fn relay_candidate(
    local: SocketAddr,
    filter: impl Fn(SocketAddr) -> bool,
) -> impl Fn(&Attribute) -> Option<Candidate> {
    move |attr| {
        let Attribute::XorRelayAddress(a) = attr else {
            return None;
        };
        let addr = a.address();

        if !filter(addr) {
            return None;
        };

        let new_candidate = match Candidate::relayed(addr, local, Protocol::Udp) {
            Ok(c) => c,
            Err(e) => {
                tracing::debug!(
                    "Acquired allocation is not a valid candidate: {}",
                    err_with_src(&e)
                );
                return None;
            }
        };

        Some(new_candidate)
    }
}

pub(crate) fn decode(packet: &[u8]) -> bytecodec::Result<DecodedMessage<Attribute>> {
    MessageDecoder::<Attribute>::default().decode_from_bytes(packet)
}

fn encode(message: Message<Attribute>) -> Vec<u8> {
    MessageEncoder::default()
        .encode_into_bytes(message)
        .expect("encoding always works")
}

stun_codec::define_attribute_enums!(
    Attribute,
    AttributeDecoder,
    AttributeEncoder,
    [
        RequestedTransport,
        AdditionalAddressFamily,
        ErrorCode,
        Nonce,
        Realm,
        Username,
        MessageIntegrity,
        XorMappedAddress,
        XorRelayAddress,
        XorPeerAddress,
        ChannelNumber,
        Lifetime,
        Software
    ]
);

#[derive(Debug)]
struct ChannelBindings {
    inner: BTreeMap<u16, Channel>,
    next_channel: u16,
}

impl Default for ChannelBindings {
    fn default() -> Self {
        Self {
            inner: Default::default(),
            next_channel: Self::FIRST_CHANNEL,
        }
    }
}

impl ChannelBindings {
    /// Per TURN spec, 0x4000 is the first channel number.
    const FIRST_CHANNEL: u16 = 0x4000;
    /// Per TURN spec, 0x4000 is the last channel number.
    const LAST_CHANNEL: u16 = 0x4FFF;

    fn try_handle_packet<'p>(
        &mut self,
        packet: channel_data::Packet<'p>,
        now: Instant,
    ) -> Option<(SocketAddr, &'p [u8])> {
        let channel_number = packet.channel();

        let Some(channel) = self.inner.get_mut(&channel_number) else {
            tracing::debug!(%channel_number, "Unknown channel");
            return None;
        };

        if !channel.bound {
            tracing::debug!(peer = %channel.peer, number = %channel_number, "Dropping message from channel because it is not yet bound");
            return None;
        }

        channel.record_received(now);

        Some((channel.peer, packet.payload()))
    }

    fn new_channel_to_peer(&mut self, peer: SocketAddr, now: Instant) -> Option<u16> {
        if let Some(number) = self.bound_channel_to_peer(peer, now) {
            return Some(number);
        }

        let number = self.next_channel_number(now)?;

        if number == Self::LAST_CHANNEL {
            self.next_channel = Self::FIRST_CHANNEL
        } else {
            self.next_channel = number + 1;
        }

        self.inner.insert(
            number,
            Channel {
                peer,
                bound: false,
                bound_at: now,
                last_received: now,
            },
        );

        Some(number)
    }

    /// Picks the next channel number to use.
    fn next_channel_number(&self, now: Instant) -> Option<u16> {
        // Cycle through all channel numbers, starting with `self.next_channel`.
        let candidates =
            (self.next_channel..=Self::LAST_CHANNEL).chain(Self::FIRST_CHANNEL..self.next_channel);

        for number in candidates {
            match self.inner.get(&number) {
                Some(channel) if channel.can_rebind(now) => return Some(number),
                None => return Some(number),
                _ => {}
            }
        }

        None
    }

    fn channels_to_refresh<'s>(
        &'s self,
        now: Instant,
        is_inflight: impl Fn(u16) -> bool + 's,
    ) -> impl Iterator<Item = (u16, SocketAddr)> + 's {
        self.inner
            .iter()
            .filter(move |(_, channel)| channel.needs_refresh(now))
            .filter(move |(number, _)| !is_inflight(**number))
            .map(|(number, channel)| (*number, channel.peer))
    }

    fn connected_channel_to_peer(&self, peer: SocketAddr, now: Instant) -> Option<u16> {
        self.inner
            .iter()
            .find(|(_, c)| c.connected_to_peer(peer, now))
            .map(|(n, _)| *n)
    }

    fn inflight_channel_to_peer(&self, peer: SocketAddr, now: Instant) -> Option<u16> {
        self.inner
            .iter()
            .find(|(_, c)| c.inflight_to_peer(peer, now))
            .map(|(n, _)| *n)
    }

    fn bound_channel_to_peer(&self, peer: SocketAddr, now: Instant) -> Option<u16> {
        self.inner
            .iter()
            .find(|(_, c)| c.bound_to_peer(peer, now))
            .map(|(n, _)| *n)
    }

    fn handle_failed_binding(&mut self, c: u16) {
        if self.inner.remove(&c).is_none() {
            debug_assert!(false, "No channel binding for {c}");
        }
    }

    fn set_confirmed(&mut self, c: u16, now: Instant) -> bool {
        let Some(channel) = self.inner.get_mut(&c) else {
            return false;
        };

        channel.set_confirmed(now);

        tracing::debug!(channel = %c, peer = %channel.peer, "Bound channel");

        true
    }

    fn clear(&mut self) {
        self.inner.clear();
    }
}

#[derive(Debug, Clone, Copy)]
struct Channel {
    peer: SocketAddr,

    /// If `false`, the channel binding has not yet been confirmed.
    bound: bool,

    /// When the channel was created or last refreshed.
    bound_at: Instant,
    last_received: Instant,
}

impl Channel {
    const CHANNEL_LIFETIME: Duration = Duration::from_secs(10 * 60);

    /// Per TURN spec, a client MUST wait for an additional 5 minutes before rebinding a channel.
    const CHANNEL_REBIND_TIMEOUT: Duration = Duration::from_secs(5 * 60);

    /// Check if this channel is connected to the given peer.
    ///
    /// In case the channel is older than its lifetime (10 minutes), this returns false because the relay will have de-allocated the channel.
    fn connected_to_peer(&self, peer: SocketAddr, now: Instant) -> bool {
        self.peer == peer && self.age(now) < Self::CHANNEL_LIFETIME && self.bound
    }

    /// Check if this channel is to-be-bound to the given peer.
    ///
    /// In case the channel is older than its lifetime (10 minutes), this returns false because the relay will have de-allocated the channel.
    fn inflight_to_peer(&self, peer: SocketAddr, now: Instant) -> bool {
        self.peer == peer && self.age(now) < Self::CHANNEL_LIFETIME
    }

    /// Check if this channel is bound to the given peer.
    fn bound_to_peer(&self, peer: SocketAddr, now: Instant) -> bool {
        self.peer == peer
            && self.age(now) < Self::CHANNEL_LIFETIME + Self::CHANNEL_REBIND_TIMEOUT
            && self.bound
    }

    fn can_rebind(&self, now: Instant) -> bool {
        self.no_activity()
            && (self.age(now) >= Self::CHANNEL_LIFETIME + Self::CHANNEL_REBIND_TIMEOUT)
    }

    /// Check if we need to refresh this channel.
    ///
    /// We will refresh all channels that:
    /// - are older than 5 minutes
    /// - we have received data on since we created / refreshed them
    fn needs_refresh(&self, now: Instant) -> bool {
        let channel_refresh_threshold = Self::CHANNEL_LIFETIME / 2;

        if self.age(now) < channel_refresh_threshold {
            return false;
        }

        if self.no_activity() {
            return false;
        }

        true
    }

    /// Returns `true` if no data has been received since we created this channel.
    fn no_activity(&self) -> bool {
        self.last_received == self.bound_at
    }

    fn age(&self, now: Instant) -> Duration {
        now.duration_since(self.bound_at)
    }

    fn set_confirmed(&mut self, now: Instant) {
        self.bound = true;
        self.bound_at = now;
        self.last_received = now;
    }

    /// Record when we last received data on this channel.
    ///
    /// This is used for keeping channels alive.
    /// We will keep all channels alive that we have received data on since we created them.
    fn record_received(&mut self, now: Instant) {
        self.last_received = now;
    }
}

fn display_attr(attr: &Attribute) -> String {
    match attr {
        Attribute::RequestedTransport(inner) => format!("{inner:?}"),
        Attribute::AdditionalAddressFamily(inner) => format!("{inner:?}"),
        Attribute::ErrorCode(inner) => {
            format!("ErrorCode({}, {})", inner.code(), inner.reason_phrase())
        }
        Attribute::Nonce(inner) => format!("Nonce({})", inner.value()),
        Attribute::Realm(inner) => format!("Realm({})", inner.text()),
        Attribute::Username(inner) => format!("Username({})", inner.name()),
        Attribute::MessageIntegrity(inner) => {
            format!("MessageIntegrity({})", hex::encode_upper(inner.hmac_sha1()))
        }
        Attribute::XorMappedAddress(inner) => format!("{inner:?}"),
        Attribute::XorRelayAddress(inner) => format!("{inner:?}"),
        Attribute::XorPeerAddress(inner) => format!("{inner:?}"),
        Attribute::ChannelNumber(inner) => format!("{inner:?}"),
        Attribute::Lifetime(inner) => format!("{inner:?}"),
        Attribute::Software(inner) => format!("Software({})", inner.description()),
    }
}

#[cfg(test)]
mod tests {
    use crate::utils::channel_data_packet_buffer;

    use super::*;
    use std::{
        iter,
        net::{IpAddr, Ipv4Addr, Ipv6Addr},
    };
    use stun_codec::{
        rfc5389::errors::{BadRequest, ServerError},
        rfc5766::errors::AllocationMismatch,
    };

    const PEER1: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 10000);

    const PEER2_IP4: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 20000);
    const PEER2_IP6: SocketAddr = SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), 20000);

    const RELAY_V4: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::LOCALHOST, 3478);
    const RELAY_V6: SocketAddrV6 = SocketAddrV6::new(Ipv6Addr::LOCALHOST, 3478, 0, 0);
    const RELAY_ADDR_IP4: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 9999);
    const RELAY_ADDR_IP6: SocketAddr = SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), 9999);

    const MINUTE: Duration = Duration::from_secs(60);

    const ALLOCATION_LIFETIME: Duration = Duration::from_secs(600);

    #[test]
    fn returns_first_available_channel() {
        let mut channel_bindings = ChannelBindings::default();

        let channel = channel_bindings
            .new_channel_to_peer(PEER1, Instant::now())
            .unwrap();

        assert_eq!(channel, ChannelBindings::FIRST_CHANNEL);
    }

    #[test]
    fn recycles_channels_in_case_they_are_not_in_use() {
        let mut channel_bindings = ChannelBindings::default();
        let start = Instant::now();

        for channel in ChannelBindings::FIRST_CHANNEL..=ChannelBindings::LAST_CHANNEL {
            let allocated_channel = channel_bindings.new_channel_to_peer(PEER1, start).unwrap();

            assert_eq!(channel, allocated_channel)
        }

        let maybe_channel = channel_bindings.new_channel_to_peer(PEER1, start);
        assert!(maybe_channel.is_none());

        let channel = channel_bindings
            .new_channel_to_peer(
                PEER1,
                start + Channel::CHANNEL_LIFETIME + Channel::CHANNEL_REBIND_TIMEOUT,
            )
            .unwrap();
        assert_eq!(channel, ChannelBindings::FIRST_CHANNEL);
    }

    #[test]
    fn uses_unused_channels_first_before_reusing_expired_one() {
        let mut channel_bindings = ChannelBindings::default();
        let mut now = Instant::now();

        for n in 0..100 {
            let allocated_channel = channel_bindings
                .new_channel_to_peer(SocketAddr::new(PEER1.ip(), PEER1.port() + n), now)
                .unwrap();
            channel_bindings.set_confirmed(allocated_channel, now);
        }

        now += Duration::from_secs(60 * 20); // All channels are expired and could be re-bound.

        let channel = channel_bindings.new_channel_to_peer(PEER1, now).unwrap();

        assert_eq!(channel, ChannelBindings::FIRST_CHANNEL + 100)
    }

    #[test]
    fn uses_next_channel_as_long_as_its_available_before_reusing() {
        let mut channel_bindings = ChannelBindings::default();
        let mut now = Instant::now();

        for n in 0..=4095 {
            let allocated_channel = channel_bindings
                .new_channel_to_peer(SocketAddr::new(PEER1.ip(), PEER1.port() + n), now)
                .unwrap();
            channel_bindings.set_confirmed(allocated_channel, now);
        }

        now += Duration::from_secs(15 * 60); // All channels are expired and could be re-bound.
        channel_bindings.set_confirmed(ChannelBindings::LAST_CHANNEL, now); // Last channel is in use

        let channel = channel_bindings.new_channel_to_peer(PEER1, now).unwrap();
        channel_bindings.set_confirmed(channel, now);

        assert_eq!(channel, ChannelBindings::FIRST_CHANNEL);

        now += Duration::from_secs(15 * 60); // All channels are expired and could be re-bound.
        channel_bindings.set_confirmed(ChannelBindings::LAST_CHANNEL, now); // Last channel is in use
        let channel = channel_bindings.new_channel_to_peer(PEER1, now).unwrap();

        // We don't reuse the first channel, instead we should prefer the second channel
        assert_ne!(channel, ChannelBindings::FIRST_CHANNEL)
    }

    #[test]
    fn bound_channel_can_decode_data() {
        let mut channel_bindings = ChannelBindings::default();
        let start = Instant::now();

        let channel = channel_bindings.new_channel_to_peer(PEER1, start).unwrap();
        channel_bindings.set_confirmed(channel, start + Duration::from_secs(1));

        let mut packet = channel_data_packet_buffer(b"foobar");
        crate::channel_data::encode_header_to_slice(&mut packet[..4], channel, 6);
        let packet = channel_data::decode(&packet).unwrap();
        let (peer, payload) = channel_bindings
            .try_handle_packet(packet, start + Duration::from_secs(2))
            .unwrap();

        assert_eq!(peer, PEER1);
        assert_eq!(payload, b"foobar");
    }

    #[test]
    fn channel_with_activity_is_refreshed() {
        let mut channel_bindings = ChannelBindings::default();
        let start = Instant::now();

        let channel = channel_bindings.new_channel_to_peer(PEER1, start).unwrap();
        channel_bindings.set_confirmed(channel, start + Duration::from_secs(1));

        let mut packet = channel_data_packet_buffer(b"foobar");
        crate::channel_data::encode_header_to_slice(&mut packet[..4], channel, 6);
        let packet = channel_data::decode(&packet).unwrap();
        channel_bindings
            .try_handle_packet(packet, start + Duration::from_secs(2))
            .unwrap();

        let not_inflight = |_| false;
        let (channel_to_refresh, _) = channel_bindings
            .channels_to_refresh(start + 6 * MINUTE, not_inflight)
            .next()
            .unwrap();

        assert_eq!(channel_to_refresh, channel);

        let inflight = |_| true;
        let maybe_refresh = channel_bindings
            .channels_to_refresh(start + 6 * MINUTE, inflight)
            .next();

        assert!(maybe_refresh.is_none())
    }

    #[test]
    fn channel_without_activity_is_not_refreshed() {
        let mut channel_bindings = ChannelBindings::default();
        let start = Instant::now();

        let channel = channel_bindings.new_channel_to_peer(PEER1, start).unwrap();
        channel_bindings.set_confirmed(channel, start + Duration::from_secs(1));

        let maybe_refresh = channel_bindings
            .channels_to_refresh(start + 6 * MINUTE, |_| false)
            .next();

        assert!(maybe_refresh.is_none())
    }

    #[test]
    fn when_in_cooldown_reuses_same_channel_for_peer() {
        let twelve = 10 * MINUTE + 2 * MINUTE;

        let mut channel_bindings = ChannelBindings::default();
        let start = Instant::now();

        let channel = channel_bindings.new_channel_to_peer(PEER1, start).unwrap();
        channel_bindings.set_confirmed(channel, start + Duration::from_secs(1));

        let second_channel = channel_bindings
            .new_channel_to_peer(PEER1, start + twelve)
            .unwrap();

        assert_eq!(second_channel, channel);
    }

    #[test]
    fn channel_that_is_less_than_5_min_old_should_not_be_refreshed() {
        let now = Instant::now();
        let channel = ch(PEER1, now);

        let four_minutes_later = now + 4 * MINUTE;
        let needs_refresh = channel.needs_refresh(four_minutes_later);

        assert!(!needs_refresh)
    }

    #[test]
    fn channel_with_received_data_but_less_than_5_min_old_should_not_be_refreshed() {
        let now = Instant::now();
        let mut channel = ch(PEER1, now);

        let three_minutes_later = now + 3 * MINUTE;
        channel.record_received(three_minutes_later);

        let four_minutes_later = now + 4 * MINUTE;
        let needs_refresh = channel.needs_refresh(four_minutes_later);

        assert!(!needs_refresh)
    }

    #[test]
    fn channel_with_no_activity_and_older_than_5_minutes_should_not_be_refreshed() {
        let now = Instant::now();
        let channel = ch(PEER1, now);

        let six_minutes_later = now + 6 * MINUTE;
        let needs_refresh = channel.needs_refresh(six_minutes_later);

        assert!(!needs_refresh)
    }

    #[test]
    fn channel_with_received_data_and_older_than_5_min_should_be_refreshed() {
        let now = Instant::now();
        let mut channel = ch(PEER1, now);

        channel.record_received(now + Duration::from_secs(1));

        let six_minutes_later = now + 6 * MINUTE;
        let needs_refresh = channel.needs_refresh(six_minutes_later);

        assert!(needs_refresh)
    }

    #[test]
    fn when_just_expires_channel_cannot_be_rebound() {
        let now = Instant::now();
        let channel = ch(PEER1, now);

        let ten_minutes_one_second = now + 10 * MINUTE + Duration::from_secs(1);
        let can_rebind = channel.can_rebind(ten_minutes_one_second);

        assert!(!can_rebind)
    }

    #[test]
    fn when_just_expires_plus_5_minutes_channel_can_be_rebound() {
        let now = Instant::now();
        let channel = ch(PEER1, now);

        let fiveteen_minutes = now + 10 * MINUTE + 5 * MINUTE;
        let can_rebind = channel.can_rebind(fiveteen_minutes);

        assert!(can_rebind)
    }

    #[test]
    fn buffer_channel_bind_requests_until_we_have_allocation() {
        let mut allocation =
            Allocation::for_test_ip4(Instant::now()).with_binding_response(PEER1, Instant::now());

        let allocate = allocation.next_message().unwrap();
        assert_eq!(allocate.method(), ALLOCATE);

        allocation.bind_channel(PEER1, Instant::now());
        assert!(
            allocation.next_message().is_none(),
            "no messages to be sent if we don't have an allocation"
        );

        allocation.handle_test_input_ip4(
            allocate_response(&allocate, &[RELAY_ADDR_IP4]),
            Instant::now(),
        );

        let message = allocation.next_message().unwrap();
        assert_eq!(message.method(), CHANNEL_BIND);
    }

    #[test]
    fn does_relay_to_with_bound_channel() {
        let mut allocation = Allocation::for_test_ip4(Instant::now())
            .with_binding_response(PEER1, Instant::now())
            .with_allocate_response(&[RELAY_ADDR_IP4], Instant::now());
        allocation.bind_channel(PEER2_IP4, Instant::now());

        let channel_bind_msg = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(channel_bind_success(&channel_bind_msg), Instant::now());

        let mut buffer = channel_data_packet_buffer(b"foobar");
        let encode_ok = allocation
            .encode_channel_data_header(PEER2_IP4, &mut buffer, Instant::now())
            .unwrap();

        assert_eq!(encode_ok.socket, RELAY_V4.into());
    }

    #[test]
    fn relays_to_inflight_channel() {
        let mut allocation = Allocation::for_test_ip4(Instant::now())
            .with_binding_response(PEER1, Instant::now())
            .with_allocate_response(&[RELAY_ADDR_IP4], Instant::now());
        allocation.bind_channel(PEER2_IP4, Instant::now());

        let mut buffer = channel_data_packet_buffer(b"foobar");
        let encode_ok =
            allocation.encode_channel_data_header(PEER2_IP4, &mut buffer, Instant::now());

        assert!(encode_ok.is_some())
    }

    #[test]
    fn does_not_relay_to_with_unbound_channel() {
        let mut allocation = Allocation::for_test_ip4(Instant::now())
            .with_binding_response(PEER1, Instant::now())
            .with_allocate_response(&[RELAY_ADDR_IP4], Instant::now());

        let mut buffer = channel_data_packet_buffer(b"foobar");
        let encode_ok =
            allocation.encode_channel_data_header(PEER2_IP4, &mut buffer, Instant::now());

        assert!(encode_ok.is_none())
    }

    #[test]
    fn failed_channel_binding_removes_state() {
        let mut allocation = Allocation::for_test_ip4(Instant::now())
            .with_binding_response(PEER1, Instant::now())
            .with_allocate_response(&[RELAY_ADDR_IP4], Instant::now());
        allocation.bind_channel(PEER2_IP4, Instant::now());

        let channel_bind_msg = allocation.next_message().unwrap();

        allocation
            .handle_test_input_ip4(channel_bind_bad_request(&channel_bind_msg), Instant::now());

        // TODO: Not the best assertion because we are reaching into private state but better than nothing for now.
        let channel = allocation
            .channel_bindings
            .inner
            .values()
            .find(|c| c.peer == PEER2_IP4);

        assert!(channel.is_none());
    }

    #[test]
    fn rebinding_existing_channel_send_no_message() {
        let mut allocation = Allocation::for_test_ip4(Instant::now())
            .with_binding_response(PEER1, Instant::now())
            .with_allocate_response(&[RELAY_ADDR_IP4], Instant::now());
        allocation.bind_channel(PEER2_IP4, Instant::now());

        let channel_bind_msg = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(channel_bind_success(&channel_bind_msg), Instant::now());

        allocation.bind_channel(PEER2_IP4, Instant::now());
        let next_msg = allocation.next_message();

        assert!(next_msg.is_none())
    }

    #[test]
    fn retries_requests_using_backoff_and_gives_up_eventually() {
        let start = Instant::now();
        let mut allocation = Allocation::for_test_ip4(start);

        let mut expected_backoffs = VecDeque::from(backoff::steps(start));

        loop {
            let Some((timeout, _)) = allocation.poll_timeout() else {
                break;
            };

            assert_eq!(expected_backoffs.pop_front().unwrap(), timeout);

            assert!(allocation.poll_transmit().is_some());
            assert!(allocation.poll_transmit().is_none());

            allocation.handle_timeout(timeout);
        }

        assert!(expected_backoffs.is_empty())
    }

    #[test]
    fn given_no_ip6_allocation_does_not_attempt_to_bind_channel_to_ip6_address() {
        let mut allocation = Allocation::for_test_ip4(Instant::now())
            .with_binding_response(PEER1, Instant::now())
            .with_allocate_response(&[RELAY_ADDR_IP4], Instant::now());

        allocation.bind_channel(PEER2_IP6, Instant::now());
        let next_msg = allocation.next_message();

        assert!(next_msg.is_none());
    }

    #[test]
    fn given_no_ip4_allocation_does_not_attempt_to_bind_channel_to_ip4_address() {
        let mut allocation = Allocation::for_test_ip4(Instant::now())
            .with_binding_response(PEER1, Instant::now())
            .with_allocate_response(&[RELAY_ADDR_IP6], Instant::now());
        allocation.bind_channel(PEER2_IP4, Instant::now());

        let next_msg = allocation.next_message();
        assert!(next_msg.is_none());
    }

    #[test]
    fn given_only_ip4_allocation_when_binding_channel_to_ip6_does_not_emit_buffered_binding() {
        let mut allocation =
            Allocation::for_test_ip4(Instant::now()).with_binding_response(PEER1, Instant::now());

        // Attempt to allocate
        let allocate = allocation.next_message().unwrap();
        assert_eq!(allocate.method(), ALLOCATE);

        // No response yet, try to bind channel to an IPv6 peer.
        allocation.bind_channel(PEER2_IP6, Instant::now());
        assert!(
            allocation.next_message().is_none(),
            "no messages to be sent if we don't have an allocation"
        );

        // Allocation succeeds but only for IPv4
        allocation.handle_test_input_ip4(
            allocate_response(&allocate, &[RELAY_ADDR_IP4]),
            Instant::now(),
        );

        let next_msg = allocation.next_message();
        assert!(next_msg.is_none(), "to not emit buffered channel binding");
    }

    #[test]
    fn initial_allocate_has_username_realm_and_message_integrity_set() {
        let mut allocation =
            Allocation::for_test_ip4(Instant::now()).with_binding_response(PEER1, Instant::now());

        let allocate = allocation.next_message().unwrap();

        assert_eq!(
            allocate.get_attribute::<Username>().map(|u| u.name()),
            Some("foobar")
        );
        assert_eq!(
            allocate.get_attribute::<Realm>().map(|u| u.text()),
            Some("firezone")
        );
        assert!(allocate.get_attribute::<MessageIntegrity>().is_some());
    }

    #[test]
    fn initial_allocate_is_missing_nonce() {
        let mut allocation =
            Allocation::for_test_ip4(Instant::now()).with_binding_response(PEER1, Instant::now());

        let allocate = allocation.next_message().unwrap();

        assert!(allocate.get_attribute::<Nonce>().is_none());
    }

    #[test]
    fn upon_stale_nonce_reauthorizes_using_new_nonce() {
        let mut allocation =
            Allocation::for_test_ip4(Instant::now()).with_binding_response(PEER1, Instant::now());

        let allocate = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(
            stale_nonce_response(&allocate, Nonce::new("nonce2".to_owned()).unwrap()),
            Instant::now(),
        );

        assert_eq!(
            allocation
                .next_message()
                .unwrap()
                .get_attribute::<Nonce>()
                .map(|n| n.value()),
            Some("nonce2")
        );
    }

    #[test]
    fn given_a_request_with_nonce_and_we_are_unauthorized_dont_retry() {
        let mut allocation =
            Allocation::for_test_ip4(Instant::now()).with_binding_response(PEER1, Instant::now());

        // Attempt to authenticate without a nonce
        let allocate = allocation.next_message().unwrap();
        allocation
            .handle_test_input_ip4(unauthorized_response(&allocate, "nonce1"), Instant::now());

        let allocate = allocation.next_message().unwrap();
        assert_eq!(
            allocate.get_attribute::<Nonce>().map(|n| n.value()),
            Some("nonce1"),
            "expect next message to include nonce from error response"
        );

        allocation
            .handle_test_input_ip4(unauthorized_response(&allocate, "nonce2"), Instant::now());

        assert!(
            allocation.next_message().is_none(),
            "expect repeated unauthorized despite received nonce to stop retry"
        );
    }

    #[test]
    fn returns_new_candidates_on_successful_allocation() {
        let mut allocation =
            Allocation::for_test_ip4(Instant::now()).with_binding_response(PEER1, Instant::now());

        let allocate = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(
            allocate_response(&allocate, &[RELAY_ADDR_IP4]),
            Instant::now(),
        );

        let next_event = allocation.poll_event();
        assert_eq!(
            next_event,
            Some(Event::New(Candidate::host(PEER1, Protocol::Udp).unwrap()))
        );
        let next_event = allocation.poll_event();
        assert_eq!(
            next_event,
            Some(Event::New(
                Candidate::server_reflexive(PEER1, PEER1, Protocol::Udp).unwrap()
            ))
        );
        let next_event = allocation.poll_event();
        assert_eq!(
            next_event,
            Some(Event::New(
                Candidate::relayed(RELAY_ADDR_IP4, PEER1, Protocol::Udp).unwrap()
            ))
        );
        let next_event = allocation.poll_event();
        assert_eq!(next_event, None);
    }

    #[test]
    fn calling_refresh_with_same_credentials_will_trigger_refresh() {
        let mut allocation =
            Allocation::for_test_ip4(Instant::now()).with_binding_response(PEER1, Instant::now());

        let allocate = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(
            allocate_response(&allocate, &[RELAY_ADDR_IP4]),
            Instant::now(),
        );

        allocation.refresh_with_same_credentials();

        let refresh = allocation.next_message().unwrap();
        assert_eq!(refresh.method(), REFRESH);

        let lifetime = refresh.get_attribute::<Lifetime>();
        assert!(lifetime.is_none() || lifetime.is_some_and(|l| l.lifetime() != Duration::ZERO));
    }

    #[test]
    fn failed_refresh_will_invalidate_relay_candiates() {
        let mut allocation =
            Allocation::for_test_ip4(Instant::now()).with_binding_response(PEER1, Instant::now());

        let allocate = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(
            allocate_response(&allocate, &[RELAY_ADDR_IP4, RELAY_ADDR_IP6]),
            Instant::now(),
        );
        let _ = iter::from_fn(|| allocation.poll_event()).collect::<Vec<_>>(); // Drain events.

        allocation.refresh_with_same_credentials();

        let refresh = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(allocation_mismatch(&refresh), Instant::now());

        assert_eq!(
            allocation.poll_event(),
            Some(Event::Invalid(
                Candidate::relayed(RELAY_ADDR_IP4, PEER1, Protocol::Udp).unwrap()
            ))
        );
        assert_eq!(
            allocation.poll_event(),
            Some(Event::Invalid(
                Candidate::relayed(RELAY_ADDR_IP6, PEER1, Protocol::Udp).unwrap()
            ))
        );
        assert!(allocation.poll_event().is_none());
        assert_eq!(
            allocation.current_relay_candidates().collect::<Vec<_>>(),
            vec![],
        )
    }

    #[test]
    fn failed_refresh_clears_all_channel_bindings() {
        let mut allocation =
            Allocation::for_test_ip4(Instant::now()).with_binding_response(PEER1, Instant::now());

        let allocate = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(
            allocate_response(&allocate, &[RELAY_ADDR_IP4, RELAY_ADDR_IP6]),
            Instant::now(),
        );

        allocation.bind_channel(PEER2_IP4, Instant::now());
        let channel_bind_msg = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(channel_bind_success(&channel_bind_msg), Instant::now());

        let mut packet = channel_data_packet_buffer(b"foobar");
        let msg = allocation.encode_channel_data_header(PEER2_IP4, &mut packet, Instant::now());
        assert!(msg.is_some(), "expect to have a channel to peer");

        allocation.refresh_with_same_credentials();

        let refresh = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(allocation_mismatch(&refresh), Instant::now());

        let mut packet = channel_data_packet_buffer(b"foobar");
        let msg = allocation.encode_channel_data_header(PEER2_IP4, &mut packet, Instant::now());
        assert!(msg.is_none(), "expect to no longer have a channel to peer");
    }

    #[test]
    fn refresh_does_nothing_if_we_dont_have_an_allocation_yet() {
        let mut allocation =
            Allocation::for_test_ip4(Instant::now()).with_binding_response(PEER1, Instant::now());

        let _allocate = allocation.next_message().unwrap();

        allocation.refresh_with_same_credentials();

        let next_msg = allocation.next_message();
        assert!(next_msg.is_none())
    }

    #[test]
    fn failed_refresh_attempts_to_make_new_allocation() {
        let mut allocation =
            Allocation::for_test_ip4(Instant::now()).with_binding_response(PEER1, Instant::now());

        let allocate = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(
            allocate_response(&allocate, &[RELAY_ADDR_IP4, RELAY_ADDR_IP6]),
            Instant::now(),
        );

        allocation.refresh_with_same_credentials();

        let refresh = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(allocation_mismatch(&refresh), Instant::now());

        let allocate = allocation.next_message().unwrap();
        assert_eq!(allocate.method(), ALLOCATE);
    }

    #[test]
    fn allocation_is_refreshed_after_half_its_lifetime() {
        let mut now = Instant::now();
        let mut allocation = Allocation::for_test_ip4(now).with_binding_response(PEER1, now);

        let allocate = allocation.next_message().unwrap();

        allocation.handle_test_input_ip4(
            allocate_response(&allocate, &[RELAY_ADDR_IP4, RELAY_ADDR_IP6]),
            now,
        );

        now += ALLOCATION_LIFETIME / 2;
        allocation.handle_timeout(now);

        let refresh = iter::from_fn(|| allocation.next_message()).find(|m| m.method() == REFRESH);
        assert!(refresh.is_some());
    }

    #[test]
    fn allocation_is_refreshed_only_once() {
        let mut allocation =
            Allocation::for_test_ip4(Instant::now()).with_binding_response(PEER1, Instant::now());

        let allocate = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(
            allocate_response(&allocate, &[RELAY_ADDR_IP4, RELAY_ADDR_IP6]),
            Instant::now(),
        );

        let (refresh_at, _) = allocation.poll_timeout().unwrap();

        allocation.handle_timeout(refresh_at);

        assert!(allocation.poll_timeout().unwrap().0 > refresh_at);
    }

    #[test]
    fn when_refreshed_with_no_allocation_after_failed_response_tries_to_allocate() {
        let mut allocation =
            Allocation::for_test_ip4(Instant::now()).with_binding_response(PEER1, Instant::now());

        let allocate = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(server_error(&allocate), Instant::now());

        allocation.refresh_with_same_credentials();

        let binding = allocation.next_message().unwrap();
        assert_eq!(binding.method(), BINDING);
        allocation.handle_test_input_ip4(binding_response(&binding, PEER1), Instant::now());

        let next_msg = allocation.next_message().unwrap();
        assert_eq!(next_msg.method(), ALLOCATE)
    }

    #[test]
    fn failed_allocation_clears_buffered_channel_bindings() {
        let mut allocation =
            Allocation::for_test_ip4(Instant::now()).with_binding_response(PEER1, Instant::now());

        allocation.bind_channel(PEER1, Instant::now());

        let allocate = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(server_error(&allocate), Instant::now()); // This should clear the buffered channel bindings.

        allocation.refresh_with_same_credentials();

        let binding = allocation.next_message().unwrap();
        assert_eq!(binding.method(), BINDING);
        allocation.handle_test_input_ip4(binding_response(&binding, PEER1), Instant::now());

        let allocate = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(
            allocate_response(&allocate, &[RELAY_ADDR_IP4, RELAY_ADDR_IP6]),
            Instant::now(),
        );

        let next_msg = allocation.next_message();
        assert!(next_msg.is_none())
    }

    #[test]
    fn allocation_mismatch_in_channel_binding_clears_and_reallocates() {
        let _guard = logging::test("debug");

        let mut allocation = Allocation::for_test_ip4(Instant::now())
            .with_binding_response(PEER1, Instant::now())
            .with_allocate_response(&[RELAY_ADDR_IP4, RELAY_ADDR_IP6], Instant::now());

        allocation.bind_channel(PEER1, Instant::now());

        let channel_bind = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(allocation_mismatch(&channel_bind), Instant::now());

        let allocate = allocation.next_message().unwrap();
        assert_eq!(
            allocate.method(),
            ALLOCATE,
            "should allocate after failed channel binding"
        );
        allocation.handle_test_input_ip4(
            allocate_response(&allocate, &[RELAY_ADDR_IP4, RELAY_ADDR_IP6]),
            Instant::now(),
        );

        let channel_bind = allocation.next_message().unwrap();
        assert_eq!(
            channel_bind.method(),
            CHANNEL_BIND,
            "channel bind to be automatically retried"
        );
    }

    #[test]
    fn dont_buffer_channel_bindings_twice() {
        let mut allocation =
            Allocation::for_test_ip4(Instant::now()).with_binding_response(PEER1, Instant::now());

        allocation.bind_channel(PEER1, Instant::now());
        allocation.bind_channel(PEER1, Instant::now());

        let allocate = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(
            allocate_response(&allocate, &[RELAY_ADDR_IP4]),
            Instant::now(),
        );

        let channel_bind = allocation.next_message().unwrap();
        let next_msg = allocation.next_message();

        assert_eq!(channel_bind.method(), CHANNEL_BIND);
        assert!(next_msg.is_none());
    }

    #[test]
    fn buffered_channel_bindings_to_different_peers_work() {
        let mut allocation =
            Allocation::for_test_ip4(Instant::now()).with_binding_response(PEER1, Instant::now());

        allocation.bind_channel(PEER1, Instant::now());
        allocation.bind_channel(PEER2_IP4, Instant::now());

        let allocate = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(
            allocate_response(&allocate, &[RELAY_ADDR_IP4]),
            Instant::now(),
        );

        let channel_bind_peer_1 = allocation.next_message().unwrap();
        let channel_bind_peer_2 = allocation.next_message().unwrap();

        assert_eq!(channel_bind_peer_1.method(), CHANNEL_BIND);
        assert_eq!(peer_address(&channel_bind_peer_1), PEER1);

        assert_eq!(channel_bind_peer_2.method(), CHANNEL_BIND);
        assert_eq!(peer_address(&channel_bind_peer_2), PEER2_IP4);
    }

    #[test]
    fn dont_send_channel_binding_if_inflight() {
        let mut allocation = Allocation::for_test_ip4(Instant::now())
            .with_binding_response(PEER1, Instant::now())
            .with_allocate_response(&[RELAY_ADDR_IP4], Instant::now());

        allocation.bind_channel(PEER1, Instant::now());

        let channel_bind = allocation.next_message().unwrap();
        assert_eq!(channel_bind.method(), CHANNEL_BIND);

        allocation.bind_channel(PEER1, Instant::now());

        assert!(allocation.next_message().is_none());
    }

    #[test]
    fn send_channel_binding_to_second_peer_if_inflight_for_other() {
        let mut allocation = Allocation::for_test_ip4(Instant::now())
            .with_binding_response(PEER1, Instant::now())
            .with_allocate_response(&[RELAY_ADDR_IP4], Instant::now());

        allocation.bind_channel(PEER1, Instant::now());

        let channel_bind = allocation.next_message().unwrap();
        assert_eq!(channel_bind.method(), CHANNEL_BIND);

        allocation.bind_channel(PEER2_IP4, Instant::now());
        let channel_bind_peer_2 = allocation.next_message().unwrap();

        assert_eq!(channel_bind_peer_2.method(), CHANNEL_BIND);
        assert_eq!(peer_address(&channel_bind_peer_2), PEER2_IP4);
    }

    #[test]
    fn failed_allocation_is_suspended() {
        let mut allocation = Allocation::for_test_ip4(Instant::now());

        let allocate = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(server_error(&allocate), Instant::now()); // This should clear the buffered channel bindings.

        assert!(allocation.is_suspended())
    }

    #[test]
    fn timed_out_binding_requests_invalid_candidates() {
        let _guard = logging::test("trace");

        let mut now = Instant::now();
        let mut allocation = Allocation::for_test_ip4(now).with_binding_response(PEER1, now);

        // Make an allocation
        {
            let allocate = allocation.next_message().unwrap();
            allocation.handle_test_input_ip4(
                allocate_response(&allocate, &[RELAY_ADDR_IP4, RELAY_ADDR_IP6]),
                now,
            );
            let _drained_events = iter::from_fn(|| allocation.poll_event()).collect::<Vec<_>>();
        }

        // Test that we send binding requests it.
        {
            now = allocation.poll_timeout().unwrap().0;
            allocation.handle_timeout(now);

            let binding = allocation.next_message().unwrap();
            assert_eq!(binding.method(), BINDING);
        }

        // Simulate bindings timing out
        for _ in backoff::steps(now) {
            allocation.handle_timeout(allocation.poll_timeout().unwrap().0);
        }

        assert_eq!(
            iter::from_fn(|| allocation.poll_event()).collect::<Vec<_>>(),
            vec![
                Event::Invalid(Candidate::relayed(RELAY_ADDR_IP4, PEER1, Protocol::Udp).unwrap()),
                Event::Invalid(Candidate::relayed(RELAY_ADDR_IP6, PEER1, Protocol::Udp).unwrap()),
            ]
        )
    }

    #[test]
    fn expires_allocation_invalidates_candidates() {
        let start = Instant::now();
        let mut allocation = Allocation::for_test_ip4(start)
            .with_binding_response(PEER1, start)
            .with_allocate_response(&[RELAY_ADDR_IP4, RELAY_ADDR_IP6], start);

        let _drained_events = iter::from_fn(|| allocation.poll_event()).collect::<Vec<_>>();

        allocation.handle_timeout(start + ALLOCATION_LIFETIME);

        assert_eq!(
            iter::from_fn(|| allocation.poll_event()).collect::<Vec<_>>(),
            vec![
                Event::Invalid(Candidate::relayed(RELAY_ADDR_IP4, PEER1, Protocol::Udp).unwrap()),
                Event::Invalid(Candidate::relayed(RELAY_ADDR_IP6, PEER1, Protocol::Udp).unwrap()),
            ]
        )
    }

    #[test]
    fn invalid_credentials_invalidates_existing_allocation() {
        let now = Instant::now();
        let mut allocation = Allocation::for_test_ip4(now)
            .with_binding_response(PEER1, now)
            .with_allocate_response(&[RELAY_ADDR_IP4, RELAY_ADDR_IP6], now);
        let _drained_events = iter::from_fn(|| allocation.poll_event()).collect::<Vec<_>>();
        allocation.credentials.as_mut().unwrap().nonce =
            Some(Nonce::new("nonce1".to_owned()).unwrap()); // Assume we had a nonce.

        let now = now + Duration::from_secs(1);
        allocation.refresh(now);

        // If the relay is restarted, our current credentials will be invalid. Simulate with an "unauthorized" response".
        let now = now + Duration::from_secs(1);
        let refresh = allocation.next_message().unwrap();
        allocation.handle_test_input_ip4(unauthorized_response(&refresh, "nonce2"), now);

        assert!(
            allocation.next_message().is_none(),
            "no more messages to be generated"
        );
        assert!(allocation.poll_timeout().is_none(), "nothing to wait for");
        assert_eq!(
            iter::from_fn(|| allocation.poll_event()).collect::<Vec<_>>(),
            vec![
                Event::Invalid(Candidate::relayed(RELAY_ADDR_IP4, PEER1, Protocol::Udp).unwrap()),
                Event::Invalid(Candidate::relayed(RELAY_ADDR_IP6, PEER1, Protocol::Udp).unwrap()),
            ]
        );
        assert_eq!(
            allocation.can_be_freed(),
            Some(FreeReason::AuthenticationError)
        );
    }

    #[test]
    fn allocation_is_not_freed_on_startup() {
        let mut allocation = Allocation::for_test_ip4(Instant::now());

        assert_eq!(allocation.can_be_freed(), None);
    }

    #[test]
    fn relay_socket_matches_v4_socket() {
        let socket = RelaySocket::V4(RELAY_V4);

        assert!(socket.matches(SocketAddr::V4(RELAY_V4)));
        assert!(!socket.matches(SocketAddr::V6(RELAY_V6)));
    }

    #[test]
    fn relay_socket_matches_v6_socket() {
        let socket = RelaySocket::V6(RELAY_V6);

        assert!(socket.matches(SocketAddr::V6(RELAY_V6)));
        assert!(!socket.matches(SocketAddr::V4(RELAY_V4)));
    }

    #[test]
    fn relay_socket_matches_dual_socket() {
        let socket = RelaySocket::Dual {
            v4: RELAY_V4,
            v6: RELAY_V6,
        };

        assert!(socket.matches(SocketAddr::V4(RELAY_V4)));
        assert!(socket.matches(SocketAddr::V6(RELAY_V6)));
    }

    #[test]
    fn first_binding_response_sets_socket_to_use() {
        let now = Instant::now();
        let mut allocation = Allocation::for_test_dual(now);

        let _ = allocation.next_message().unwrap(); // Discard the first one.

        let binding = allocation.next_message().unwrap();
        allocation.handle_input(
            RELAY_V6.into(),
            PEER2_IP6,
            binding_response(&binding, PEER2_IP6),
            now,
        );

        assert_eq!(allocation.poll_transmit().unwrap().dst, RELAY_V6.into());
    }

    #[test]
    fn both_stun_responses_are_returned_as_candidates() {
        let now = Instant::now();
        let mut allocation = Allocation::for_test_dual(now);

        let binding = allocation.next_message().unwrap();
        let handled = allocation.handle_input(
            RELAY_V4.into(),
            PEER2_IP4,
            binding_response(&binding, PEER2_IP4),
            now,
        );
        assert!(handled);

        let binding = allocation.next_message().unwrap();
        let handled = allocation.handle_input(
            RELAY_V6.into(),
            PEER2_IP6,
            binding_response(&binding, PEER2_IP6),
            now,
        );
        assert!(handled);

        let events = iter::from_fn(|| allocation.poll_event()).collect::<Vec<_>>();
        assert_eq!(
            events,
            vec![
                Event::New(Candidate::host(PEER2_IP4, Protocol::Udp).unwrap()),
                Event::New(
                    Candidate::server_reflexive(PEER2_IP4, PEER2_IP4, Protocol::Udp).unwrap()
                ),
                Event::New(Candidate::host(PEER2_IP6, Protocol::Udp).unwrap()),
                Event::New(
                    Candidate::server_reflexive(PEER2_IP6, PEER2_IP6, Protocol::Udp).unwrap()
                )
            ]
        )
    }

    #[test]
    fn second_stun_request_gives_up_eventually() {
        let _guard = logging::test("trace");

        let start = Instant::now();
        let mut allocation = Allocation::for_test_dual(start);

        // We respond to the BINDING request on IPv4.
        let binding = allocation.next_message().unwrap();
        allocation.handle_input(
            RELAY_V4.into(),
            PEER2_IP4,
            binding_response(&binding, PEER2_IP4),
            start,
        );

        loop {
            let Some((timeout, _)) = allocation.poll_timeout() else {
                break;
            };

            allocation.handle_timeout(timeout);

            // We expect two transmits.
            // The order is not deterministic because internally it is a `HashMap`.
            let _ = allocation.poll_transmit().unwrap();
            let _ = allocation.poll_transmit().unwrap();
        }

        assert_eq!(allocation.poll_transmit(), None);
    }

    #[test]
    fn allocation_can_be_freed_after_all_requests_time_out() {
        let mut allocation = Allocation::for_test_dual(Instant::now());

        loop {
            let Some((timeout, _)) = allocation.poll_timeout() else {
                break;
            };
            allocation.handle_timeout(timeout);

            // We expect two transmits.
            // The order is not deterministic because internally it is a `HashMap`.
            let _ = allocation.poll_transmit().unwrap();
            let _ = allocation.poll_transmit().unwrap();
        }

        assert_eq!(
            allocation.can_be_freed(),
            Some(FreeReason::NoResponseReceived)
        );
    }

    #[test]
    fn sends_binding_request_on_nominated_socket() {
        let mut now = Instant::now();

        let mut allocation = Allocation::for_test_ip4(now)
            .with_binding_response(PEER1, now)
            .with_allocate_response(&[RELAY_ADDR_IP4], now);

        now += BINDING_INTERVAL;
        allocation.handle_timeout(now);

        let transmit = allocation.poll_transmit().unwrap();
        assert_eq!(transmit.dst, RELAY_V4.into());
        assert_eq!(
            decode(&transmit.payload).unwrap().unwrap().method(),
            BINDING
        );
    }

    fn ch(peer: SocketAddr, now: Instant) -> Channel {
        Channel {
            peer,
            bound: true,
            bound_at: now,
            last_received: now,
        }
    }

    fn allocate_response(
        request: &Message<Attribute>,
        relay_addrs: &[SocketAddr],
    ) -> Message<Attribute> {
        let mut message = Message::new(
            MessageClass::SuccessResponse,
            ALLOCATE,
            request.transaction_id(),
        );
        message.add_attribute(XorMappedAddress::new(PEER1));

        assert!(!relay_addrs.is_empty());
        for addr in relay_addrs {
            message.add_attribute(XorRelayAddress::new(*addr));
        }

        message.add_attribute(Lifetime::new(ALLOCATION_LIFETIME).unwrap());

        message
    }

    fn binding_response(
        request: &Message<Attribute>,
        srflx_addr: SocketAddr,
    ) -> Message<Attribute> {
        let mut message = Message::new(
            MessageClass::SuccessResponse,
            BINDING,
            request.transaction_id(),
        );
        message.add_attribute(XorMappedAddress::new(srflx_addr));

        message
    }

    fn unauthorized_response(request: &Message<Attribute>, nonce: &str) -> Message<Attribute> {
        let mut message = Message::new(
            MessageClass::ErrorResponse,
            request.method(),
            request.transaction_id(),
        );
        message.add_attribute(ErrorCode::from(Unauthorized));
        message.add_attribute(Realm::new("firezone".to_owned()).unwrap());
        message.add_attribute(Nonce::new(nonce.to_owned()).unwrap());

        message
    }

    fn server_error(request: &Message<Attribute>) -> Message<Attribute> {
        let mut message = Message::new(
            MessageClass::ErrorResponse,
            request.method(),
            request.transaction_id(),
        );
        message.add_attribute(ErrorCode::from(ServerError));

        message
    }

    fn stale_nonce_response(request: &Message<Attribute>, nonce: Nonce) -> Message<Attribute> {
        let mut message = Message::new(
            MessageClass::ErrorResponse,
            request.method(),
            request.transaction_id(),
        );
        message.add_attribute(ErrorCode::from(StaleNonce));
        message.add_attribute(Realm::new("firezone".to_owned()).unwrap());
        message.add_attribute(nonce);

        message
    }

    fn allocation_mismatch(request: &Message<Attribute>) -> Message<Attribute> {
        let mut message = Message::new(
            MessageClass::ErrorResponse,
            request.method(),
            request.transaction_id(),
        );
        message.add_attribute(ErrorCode::from(AllocationMismatch));

        message
    }

    fn channel_bind_bad_request(request: &Message<Attribute>) -> Message<Attribute> {
        let mut message = Message::new(
            MessageClass::ErrorResponse,
            CHANNEL_BIND,
            request.transaction_id(),
        );
        message.add_attribute(ErrorCode::from(BadRequest));

        message
    }

    fn channel_bind_success(request: &Message<Attribute>) -> Message<Attribute> {
        Message::new(
            MessageClass::SuccessResponse,
            CHANNEL_BIND,
            request.transaction_id(),
        )
    }

    fn peer_address(message: &Message<Attribute>) -> SocketAddr {
        message.get_attribute::<XorPeerAddress>().unwrap().address()
    }

    impl Allocation {
        fn for_test_ip4(start: Instant) -> Self {
            Allocation::new(
                RelaySocket::V4(RELAY_V4),
                Username::new("foobar".to_owned()).unwrap(),
                "baz".to_owned(),
                Realm::new("firezone".to_owned()).unwrap(),
                start,
                SessionId::default(),
                BufferPool::new(500, "test"),
            )
        }

        fn for_test_dual(start: Instant) -> Self {
            Allocation::new(
                RelaySocket::Dual {
                    v4: RELAY_V4,
                    v6: RELAY_V6,
                },
                Username::new("foobar".to_owned()).unwrap(),
                "baz".to_owned(),
                Realm::new("firezone".to_owned()).unwrap(),
                start,
                SessionId::default(),
                BufferPool::new(500, "test"),
            )
        }

        fn with_binding_response(mut self, srflx_addr: SocketAddr, now: Instant) -> Self {
            let binding = self.next_message().unwrap();
            self.handle_test_input_ip4(binding_response(&binding, srflx_addr), now);

            self
        }

        fn with_allocate_response(mut self, relay_addrs: &[SocketAddr], now: Instant) -> Self {
            let allocate = self.next_message().unwrap();
            self.handle_test_input_ip4(allocate_response(&allocate, relay_addrs), now);

            self
        }

        fn next_message(&mut self) -> Option<Message<Attribute>> {
            let transmit = self.poll_transmit()?;

            Some(decode(&transmit.payload).unwrap().unwrap())
        }

        /// Wrapper around `handle_input` that always sets `RELAY` and `PEER1`.
        fn handle_test_input_ip4(&mut self, packet: Message<Attribute>, now: Instant) -> bool {
            self.handle_input(RELAY_V4.into(), PEER1, packet, now)
        }

        fn refresh_with_same_credentials(&mut self) {
            self.refresh(Instant::now());
        }
    }
}
