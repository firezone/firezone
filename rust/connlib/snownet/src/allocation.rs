use crate::{
    backoff::{self, ExponentialBackoff},
    node::Transmit,
    utils::earliest,
};
use ::backoff::backoff::Backoff;
use bytecodec::{DecodeExt as _, EncodeExt as _};
use rand::random;
use std::{
    collections::{HashMap, VecDeque},
    net::SocketAddr,
    time::{Duration, Instant},
};
use str0m::{net::Protocol, Candidate};
use stun_codec::{
    rfc5389::{
        attributes::{ErrorCode, MessageIntegrity, Nonce, Realm, Username, XorMappedAddress},
        errors::{StaleNonce, Unauthorized},
        methods::BINDING,
    },
    rfc5766::{
        attributes::{
            ChannelNumber, Lifetime, RequestedTransport, XorPeerAddress, XorRelayAddress,
        },
        methods::{ALLOCATE, CHANNEL_BIND, REFRESH},
    },
    rfc8656::attributes::AdditionalAddressFamily,
    DecodedMessage, Message, MessageClass, MessageDecoder, MessageEncoder, TransactionId,
};
use tracing::{field, Span};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

/// Represents a TURN allocation that refreshes itself.
///
/// Allocations have a lifetime and need to be continuously refreshed to stay active.
#[derive(Debug)]
pub struct Allocation {
    server: SocketAddr,

    /// If present, the last address the relay observed for us.
    last_srflx_candidate: Option<Candidate>,
    /// If present, the IPv4 socket the relay allocated for us.
    ip4_allocation: Option<Candidate>,
    /// If present, the IPv6 socket the relay allocated for us.
    ip6_allocation: Option<Candidate>,

    /// When we received the allocation and how long it is valid.
    allocation_lifetime: Option<(Instant, Duration)>,

    buffered_transmits: VecDeque<Transmit<'static>>,
    new_candidates: VecDeque<Candidate>,

    backoff: ExponentialBackoff,
    sent_requests: HashMap<TransactionId, (Message<Attribute>, Instant, Duration)>,

    channel_bindings: ChannelBindings,
    buffered_channel_bindings: BufferedChannelBindings,

    last_now: Instant,

    username: Username,
    password: String,
    realm: Realm,
    nonce: Option<Nonce>,
}

impl Allocation {
    pub fn new(
        server: SocketAddr,
        username: Username,
        password: String,
        realm: Realm,
        now: Instant,
    ) -> Self {
        let mut allocation = Self {
            server,
            last_srflx_candidate: Default::default(),
            ip4_allocation: Default::default(),
            ip6_allocation: Default::default(),
            buffered_transmits: Default::default(),
            new_candidates: Default::default(),
            sent_requests: Default::default(),
            username,
            password,
            realm,
            nonce: Default::default(),
            allocation_lifetime: Default::default(),
            channel_bindings: Default::default(),
            last_now: now,
            buffered_channel_bindings: Default::default(),
            backoff: backoff::new(now, REQUEST_TIMEOUT),
        };

        tracing::debug!(%server, "Requesting new allocation");

        allocation.authenticate_and_queue(make_allocate_request());

        allocation
    }

    pub fn current_candidates(&self) -> impl Iterator<Item = Candidate> {
        [
            self.last_srflx_candidate.clone(),
            self.ip4_allocation.clone(),
            self.ip6_allocation.clone(),
        ]
        .into_iter()
        .flatten()
    }

    #[tracing::instrument(level = "debug", skip(self, packet, now), fields(relay = %self.server, id, method, class))]
    pub fn handle_input(
        &mut self,
        from: SocketAddr,
        local: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> bool {
        self.update_now(now);

        if from != self.server {
            return false;
        }

        let Ok(Ok(message)) = decode(packet) else {
            return false;
        };

        Span::current().record("id", field::debug(message.transaction_id()));
        Span::current().record("method", field::display(message.method()));
        Span::current().record("class", field::display(message.class()));

        let Some((original_request, sent_at, _)) =
            self.sent_requests.remove(&message.transaction_id())
        else {
            return false;
        };

        self.backoff.reset();

        let rtt = now.duration_since(sent_at);
        tracing::debug!(?rtt);

        if let Some(error) = message.get_attribute::<ErrorCode>() {
            // Check if we need to re-authenticate the original request
            if error.code() == Unauthorized::CODEPOINT || error.code() == StaleNonce::CODEPOINT {
                if let Some(nonce) = message.get_attribute::<Nonce>() {
                    self.nonce = Some(nonce.clone());
                };

                if let Some(offered_realm) = message.get_attribute::<Realm>() {
                    if offered_realm != &self.realm {
                        tracing::warn!(allowed_realm = %self.realm.text(), server_realm = %offered_realm.text(), "Refusing to authenticate with server");
                        return true; // We still handled our message correctly.
                    }
                };

                tracing::debug!(
                    error = error.reason_phrase(),
                    "Request failed, re-authenticating"
                );

                self.authenticate_and_queue(original_request);

                return true;
            }

            #[allow(clippy::single_match)] // There will be more eventually.
            match message.method() {
                CHANNEL_BIND => {
                    let Some(channel) = original_request
                        .get_attribute::<ChannelNumber>()
                        .map(|c| c.value())
                    else {
                        tracing::warn!("Request did not contain a `CHANNEL-NUMBER`");
                        return true;
                    };

                    self.channel_bindings.handle_failed_binding(channel);
                }
                _ => {}
            }

            // TODO: Handle error codes such as:
            // - Failed allocations

            tracing::warn!(error = %error.reason_phrase(), "STUN request failed");

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
            ALLOCATE => {
                let Some(lifetime) = message.get_attribute::<Lifetime>().map(|l| l.lifetime())
                else {
                    tracing::warn!("Message does not contain `LIFETIME`");
                    return true;
                };

                let maybe_srflx_candidate = message
                    .attributes()
                    .find_map(|addr| srflx_candidate(local, addr));
                let maybe_ip4_relay_candidate = message
                    .attributes()
                    .find_map(relay_candidate(|s| s.is_ipv4()));
                let maybe_ip6_relay_candidate = message
                    .attributes()
                    .find_map(relay_candidate(|s| s.is_ipv6()));

                self.allocation_lifetime = Some((now, lifetime));
                update_candidate(
                    maybe_srflx_candidate,
                    &mut self.last_srflx_candidate,
                    &mut self.new_candidates,
                );
                update_candidate(
                    maybe_ip4_relay_candidate,
                    &mut self.ip4_allocation,
                    &mut self.new_candidates,
                );
                update_candidate(
                    maybe_ip6_relay_candidate,
                    &mut self.ip6_allocation,
                    &mut self.new_candidates,
                );

                tracing::info!(
                    srflx = ?self.last_srflx_candidate,
                    relay_ip4 = ?self.ip4_allocation,
                    relay_ip6 = ?self.ip6_allocation,
                    ?lifetime,
                    "Updated candidates of allocation"
                );

                while let Some(buffered) = self.buffered_channel_bindings.pop_front() {
                    self.authenticate_and_queue(buffered);
                }
            }
            REFRESH => {
                let Some(lifetime) = message.get_attribute::<Lifetime>() else {
                    tracing::warn!("Message does not contain lifetime");
                    return true;
                };

                self.allocation_lifetime = Some((now, lifetime.lifetime()));

                tracing::info!(
                    srflx = ?self.last_srflx_candidate,
                    relay_ip4 = ?self.ip4_allocation,
                    relay_ip6 = ?self.ip6_allocation,
                    ?lifetime,
                    "Updated lifetime of allocation"
                );
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
        packet: &'p [u8],
        now: Instant,
    ) -> Option<(SocketAddr, &'p [u8], SocketAddr)> {
        if from != self.server {
            return None;
        }

        let (peer, payload) = self.channel_bindings.try_decode(packet, now)?;

        // Our socket on the relay.
        // If the remote sent from an IP4 address, it must have been received on our IP4 allocation.
        // Same thing for IP6.
        let relay_socket = match peer {
            SocketAddr::V4(_) => self.ip4_allocation.as_ref()?.addr(),
            SocketAddr::V6(_) => self.ip6_allocation.as_ref()?.addr(),
        };

        tracing::debug!(server = %self.server, %peer, %relay_socket, "Decapsulated channel-data message");

        Some((peer, payload, relay_socket))
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.update_now(now);

        while let Some(timed_out_request) =
            self.sent_requests
                .iter()
                .find_map(|(id, (_, sent_at, backoff))| {
                    (now.duration_since(*sent_at) >= *backoff).then_some(*id)
                })
        {
            let (request, _, _) = self
                .sent_requests
                .remove(&timed_out_request)
                .expect("ID is from list");

            tracing::debug!(id = ?request.transaction_id(), method = %request.method(), "Request timed out, re-sending");

            self.authenticate_and_queue(request);
        }

        if let Some(refresh_at) = self.refresh_allocation_at() {
            if now > refresh_at {
                tracing::debug!("Allocation is due for a refresh");
                self.authenticate_and_queue(make_refresh_request());
            }
        }

        let refresh_messages = self
            .channel_bindings
            .channels_to_refresh(now, |number| self.channel_binding_in_flight(number))
            .map(|(number, peer)| make_channel_bind_request(peer, number))
            .collect::<Vec<_>>(); // Need to allocate here to satisfy borrow-checker. Number of channel refresh messages should be small so this shouldn't be a big impact.

        for message in refresh_messages {
            self.authenticate_and_queue(message);
        }

        // TODO: Clean up unused channels
    }

    pub fn poll_candidate(&mut self) -> Option<Candidate> {
        self.new_candidates.pop_front()
    }

    pub fn poll_transmit(&mut self) -> Option<Transmit<'static>> {
        self.buffered_transmits.pop_front()
    }

    pub fn poll_timeout(&self) -> Option<Instant> {
        let mut earliest_timeout = self.refresh_allocation_at();

        for (_, (_, sent_at, backoff)) in self.sent_requests.iter() {
            earliest_timeout = earliest(earliest_timeout, Some(*sent_at + *backoff));
        }

        earliest_timeout
    }

    pub fn bind_channel(&mut self, peer: SocketAddr, now: Instant) {
        self.update_now(now);

        if self.channel_bindings.channel_to_peer(peer, now).is_some() {
            tracing::debug!(relay = %self.server, %peer, "Already got a channel");
            return;
        }

        let Some(channel) = self.channel_bindings.new_channel_to_peer(peer, now) else {
            tracing::warn!(relay = %self.server, "All channels are exhausted");
            return;
        };

        let msg = make_channel_bind_request(peer, channel);

        if !self.has_allocation() {
            tracing::debug!(relay = %self.server, %peer, "No allocation yet, buffering channel binding");

            self.buffered_channel_bindings.push_back(msg);
            return;
        }

        self.authenticate_and_queue(msg);
    }

    pub fn encode_to_slice(
        &mut self,
        peer: SocketAddr,
        packet: &[u8],
        header: &mut [u8],
        now: Instant,
    ) -> Option<usize> {
        let channel_number = self.channel_bindings.channel_to_peer(peer, now)?;
        let total_length =
            crate::channel_data::encode_header_to_slice(header, channel_number, packet);

        Some(total_length)
    }

    pub fn encode_to_vec(
        &mut self,
        peer: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> Option<Vec<u8>> {
        let channel_number = self.channel_bindings.channel_to_peer(peer, now)?;
        let channel_data = crate::channel_data::encode(channel_number, packet);

        Some(channel_data)
    }

    fn refresh_allocation_at(&self) -> Option<Instant> {
        let (received_at, lifetime) = self.allocation_lifetime?;

        let refresh_after = lifetime / 2;

        Some(received_at + refresh_after)
    }

    fn has_allocation(&self) -> bool {
        self.ip4_allocation.is_some() || self.ip6_allocation.is_some()
    }

    fn channel_binding_in_flight(&self, channel: u16) -> bool {
        self.sent_requests.values().any(|(r, _, _)| {
            r.method() == BINDING
                && r.get_attribute::<ChannelNumber>()
                    .is_some_and(|n| n.value() == channel)
        })
    }

    fn authenticate(&self, message: Message<Attribute>) -> Message<Attribute> {
        let attributes = message
            .attributes()
            .filter(|a| !matches!(a, Attribute::Nonce(_)))
            .filter(|a| !matches!(a, Attribute::MessageIntegrity(_)))
            .filter(|a| !matches!(a, Attribute::Realm(_)))
            .filter(|a| !matches!(a, Attribute::Username(_)))
            .cloned()
            .chain([
                Attribute::Username(self.username.clone()),
                Attribute::Realm(self.realm.clone()),
            ])
            .chain(self.nonce.clone().map(Attribute::Nonce));

        let transaction_id = TransactionId::new(random());
        let mut message = Message::new(MessageClass::Request, message.method(), transaction_id);

        for attribute in attributes {
            message.add_attribute(attribute.to_owned());
        }

        let message_integrity = MessageIntegrity::new_long_term_credential(
            &message,
            &self.username,
            &self.realm,
            &self.password,
        )
        .expect("signing never fails");

        message.add_attribute(message_integrity);

        message
    }

    fn authenticate_and_queue(&mut self, message: Message<Attribute>) {
        let Some(backoff) = self.backoff.next_backoff() else {
            tracing::warn!(
                "Unable to queue {} because we've exceeded our backoffs",
                message.method()
            );
            return;
        };

        let authenticated_message = self.authenticate(message);
        let id = authenticated_message.transaction_id();

        self.sent_requests
            .insert(id, (authenticated_message.clone(), self.last_now, backoff));
        self.buffered_transmits.push_back(Transmit {
            src: None,
            dst: self.server,
            payload: encode(authenticated_message).into(),
        });
    }

    fn update_now(&mut self, now: Instant) {
        if now > self.last_now {
            self.last_now = now;
            self.backoff.clock.now = now;
        }
    }
}

fn update_candidate(
    maybe_new: Option<Candidate>,
    maybe_current: &mut Option<Candidate>,
    new_candidates: &mut VecDeque<Candidate>,
) {
    match (maybe_new, &maybe_current) {
        (Some(new), Some(current)) if &new != current => {
            *maybe_current = Some(new.clone());
            new_candidates.push_back(new);
        }
        (Some(new), None) => {
            *maybe_current = Some(new.clone());
            new_candidates.push_back(new);
        }
        _ => {}
    }
}

fn make_allocate_request() -> Message<Attribute> {
    let mut message = Message::new(
        MessageClass::Request,
        ALLOCATE,
        TransactionId::new(random()),
    );

    message.add_attribute(RequestedTransport::new(17));
    message.add_attribute(AdditionalAddressFamily::new(
        stun_codec::rfc8656::attributes::AddressFamily::V6,
    ));

    message
}

fn make_refresh_request() -> Message<Attribute> {
    let mut message = Message::new(MessageClass::Request, REFRESH, TransactionId::new(random()));

    message.add_attribute(RequestedTransport::new(17));
    message.add_attribute(AdditionalAddressFamily::new(
        stun_codec::rfc8656::attributes::AddressFamily::V6,
    ));

    message
}

fn make_channel_bind_request(target: SocketAddr, channel: u16) -> Message<Attribute> {
    let mut message = Message::new(
        MessageClass::Request,
        CHANNEL_BIND,
        TransactionId::new(random()),
    );

    message.add_attribute(XorPeerAddress::new(target));
    message.add_attribute(ChannelNumber::new(channel).unwrap());

    message
}

fn srflx_candidate(local: SocketAddr, attr: &Attribute) -> Option<Candidate> {
    let addr = match attr {
        Attribute::XorMappedAddress(a) => a.address(),
        _ => return None,
    };

    let new_candidate = match Candidate::server_reflexive(addr, local, Protocol::Udp) {
        Ok(c) => c,
        Err(e) => {
            tracing::debug!("Observed address is not a valid candidate: {e}");
            return None;
        }
    };

    Some(new_candidate)
}

fn relay_candidate(
    filter: impl Fn(SocketAddr) -> bool,
) -> impl Fn(&Attribute) -> Option<Candidate> {
    move |attr| {
        let addr = match attr {
            Attribute::XorRelayAddress(a) if filter(a.address()) => a.address(),
            _ => return None,
        };

        let new_candidate = match Candidate::relayed(addr, Protocol::Udp) {
            Ok(c) => c,
            Err(e) => {
                tracing::debug!("Acquired allocation is not a valid candidate: {e}");
                return None;
            }
        };

        Some(new_candidate)
    }
}

fn decode(packet: &[u8]) -> bytecodec::Result<DecodedMessage<Attribute>> {
    MessageDecoder::<Attribute>::default().decode_from_bytes(packet)
}

fn encode(message: Message<Attribute>) -> Vec<u8> {
    MessageEncoder::default()
        .encode_into_bytes(message.clone())
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
        Lifetime
    ]
);

#[derive(Debug)]
struct ChannelBindings {
    inner: HashMap<u16, Channel>,
    next_channel: u16,
}

impl Default for ChannelBindings {
    fn default() -> Self {
        Self {
            inner: Default::default(),
            next_channel: ChannelBindings::FIRST_CHANNEL,
        }
    }
}

impl ChannelBindings {
    /// Per TURN spec, 0x4000 is the first channel number.
    const FIRST_CHANNEL: u16 = 0x4000;
    /// Per TURN spec, 0x4000 is the last channel number.
    const LAST_CHANNEL: u16 = 0x4FFF;

    fn try_decode<'p>(&mut self, packet: &'p [u8], now: Instant) -> Option<(SocketAddr, &'p [u8])> {
        let (channel_number, payload) = crate::channel_data::decode(packet).ok()?;
        let channel = self.inner.get_mut(&channel_number)?;
        channel.record_received(now);

        debug_assert!(channel.bound); // TODO: Should we "force-set" this? We seem to be getting traffic on this channel ..

        Some((channel.peer, payload))
    }

    fn new_channel_to_peer(&mut self, peer: SocketAddr, now: Instant) -> Option<u16> {
        if self.next_channel == Self::LAST_CHANNEL {
            self.next_channel = Self::FIRST_CHANNEL;
        }

        let channel = loop {
            match self.inner.get(&self.next_channel) {
                Some(channel) if channel.can_rebind(now) => break self.next_channel,
                None => break self.next_channel,
                _ => {}
            }

            self.next_channel += 1;

            if self.next_channel >= Self::LAST_CHANNEL {
                return None;
            }
        };

        self.inner.insert(
            channel,
            Channel {
                peer,
                bound: false,
                bound_at: now,
                last_received: now,
            },
        );

        Some(channel)
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

    fn channel_to_peer(&self, peer: SocketAddr, now: Instant) -> Option<u16> {
        self.inner
            .iter()
            .find(|(_, c)| c.connected_to_peer(peer, now))
            .map(|(n, _)| *n)
    }

    fn handle_failed_binding(&mut self, c: u16) {
        let Some(channel) = self.inner.remove(&c) else {
            debug_assert!(false, "No channel binding for {c}");
            return;
        };

        debug_assert!(!channel.bound, "Channel should not yet be bound")
    }

    fn set_confirmed(&mut self, c: u16, now: Instant) -> bool {
        let Some(channel) = self.inner.get_mut(&c) else {
            return false;
        };

        channel.set_confirmed(now);

        tracing::info!(channel = %c, peer = %channel.peer, "Bound channel");

        true
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

#[derive(Debug, Default)]
struct BufferedChannelBindings {
    inner: VecDeque<Message<Attribute>>,
}

impl BufferedChannelBindings {
    /// Adds a new `CHANNEL-BIND` message to this buffer.
    ///
    /// The buffer has a fixed size of 10 to avoid unbounded memory growth.
    /// All prior messages are cleared once we outgrow the buffer.
    /// Very likely, we buffer `CHANNEL-BIND` messages only for a brief period of time.
    /// However, it might also happen that we can only re-connect to a TURN server after an extended period of downtime.
    /// Chances are that we don't need any of the old channels any more, and that the new ones are much more relevant.
    fn push_back(&mut self, msg: Message<Attribute>) {
        debug_assert_eq!(msg.method(), CHANNEL_BIND);

        if self.inner.len() == 10 {
            tracing::debug!("Clearing buffered channel-data messages");
            self.inner.clear()
        }

        self.inner.push_back(msg);
    }

    fn pop_front(&mut self) -> Option<Message<Attribute>> {
        self.inner.pop_front()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{IpAddr, Ipv4Addr};
    use stun_codec::rfc5389::errors::BadRequest;

    const PEER1: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 10000);
    const PEER2: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 20000);
    const RELAY: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 3478);
    const RELAY_ADDR: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 9999);
    const MINUTE: Duration = Duration::from_secs(60);

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

        for channel in ChannelBindings::FIRST_CHANNEL..ChannelBindings::LAST_CHANNEL {
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
    fn bound_channel_can_decode_data() {
        let mut channel_bindings = ChannelBindings::default();
        let start = Instant::now();

        let channel = channel_bindings.new_channel_to_peer(PEER1, start).unwrap();
        channel_bindings.set_confirmed(channel, start + Duration::from_secs(1));

        let packet = crate::channel_data::encode(channel, b"foobar");
        let (peer, payload) = channel_bindings
            .try_decode(&packet, start + Duration::from_secs(2))
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

        let packet = crate::channel_data::encode(channel, b"foobar");
        channel_bindings
            .try_decode(&packet, start + Duration::from_secs(2))
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
        let mut allocation = Allocation::new(
            RELAY,
            Username::new("foobar".to_owned()).unwrap(),
            "baz".to_owned(),
            Realm::new("firezone".to_owned()).unwrap(),
            Instant::now(),
        );

        let allocate = next_stun_message(&mut allocation).unwrap();
        assert_eq!(allocate.method(), ALLOCATE);

        allocation.bind_channel(PEER1, Instant::now());
        assert!(
            next_stun_message(&mut allocation).is_none(),
            "no messages to be sent if we don't have an allocation"
        );

        make_allocation(&mut allocation, allocate.transaction_id(), PEER1);

        let message = next_stun_message(&mut allocation).unwrap();
        assert_eq!(message.method(), CHANNEL_BIND);
    }

    #[test]
    fn does_not_relay_to_with_unbound_channel() {
        let mut allocation = Allocation::new(
            RELAY,
            Username::new("foobar".to_owned()).unwrap(),
            "baz".to_owned(),
            Realm::new("firezone".to_owned()).unwrap(),
            Instant::now(),
        );

        let allocate = next_stun_message(&mut allocation).unwrap();
        make_allocation(&mut allocation, allocate.transaction_id(), PEER1);
        allocation.bind_channel(PEER2, Instant::now());

        let message = allocation.encode_to_vec(PEER2, b"foobar", Instant::now());

        assert!(message.is_none())
    }

    #[test]
    fn failed_channel_binding_removes_state() {
        let mut allocation = Allocation::new(
            RELAY,
            Username::new("foobar".to_owned()).unwrap(),
            "baz".to_owned(),
            Realm::new("firezone".to_owned()).unwrap(),
            Instant::now(),
        );

        let allocate = next_stun_message(&mut allocation).unwrap();
        make_allocation(&mut allocation, allocate.transaction_id(), PEER1);
        allocation.bind_channel(PEER2, Instant::now());

        let channel_bind_msg = next_stun_message(&mut allocation).unwrap();

        allocation.handle_input(
            RELAY,
            PEER1,
            &encode(channel_bind_bad_request(channel_bind_msg.transaction_id())),
            Instant::now(),
        );

        // TODO: Not the best assertion because we are reaching into private state but better than nothing for now.
        let channel = allocation
            .channel_bindings
            .inner
            .values()
            .find(|c| c.peer == PEER2);

        assert!(channel.is_none());
    }

    #[test]
    fn rebinding_existing_channel_send_no_message() {
        let mut allocation = Allocation::new(
            RELAY,
            Username::new("foobar".to_owned()).unwrap(),
            "baz".to_owned(),
            Realm::new("firezone".to_owned()).unwrap(),
            Instant::now(),
        );

        let allocate = next_stun_message(&mut allocation).unwrap();
        make_allocation(&mut allocation, allocate.transaction_id(), PEER1);
        allocation.bind_channel(PEER2, Instant::now());

        let channel_bind_msg = next_stun_message(&mut allocation).unwrap();
        allocation.handle_input(
            RELAY,
            PEER1,
            &encode(channel_bind_success(channel_bind_msg.transaction_id())),
            Instant::now(),
        );

        allocation.bind_channel(PEER2, Instant::now());
        let next_msg = next_stun_message(&mut allocation);

        assert!(next_msg.is_none())
    }

    #[test]
    fn retries_requests_using_backoff_and_gives_up_eventually() {
        let start = Instant::now();
        let mut allocation = Allocation::new(
            RELAY,
            Username::new("foobar".to_owned()).unwrap(),
            "baz".to_owned(),
            Realm::new("firezone".to_owned()).unwrap(),
            start,
        );

        let mut expected_backoffs = VecDeque::from(backoff::steps(start));

        loop {
            let Some(timeout) = allocation.poll_timeout() else {
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
    fn discards_old_channel_bindings_once_we_outgrow_buffer() {
        let mut buffered_channel_bindings = BufferedChannelBindings::default();

        for c in 0..11 {
            buffered_channel_bindings.push_back(make_channel_bind_request(
                PEER1,
                ChannelBindings::FIRST_CHANNEL + c,
            ));
        }

        let msg = buffered_channel_bindings.pop_front().unwrap();
        assert!(
            buffered_channel_bindings.pop_front().is_none(),
            "no more messages"
        );
        assert_eq!(
            msg.get_attribute::<ChannelNumber>().unwrap().value(),
            ChannelBindings::FIRST_CHANNEL + 10
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

    fn next_stun_message(allocation: &mut Allocation) -> Option<stun_codec::Message<Attribute>> {
        let transmit = allocation.poll_transmit()?;

        Some(decode(&transmit.payload).unwrap().unwrap())
    }

    fn make_allocation(allocation: &mut Allocation, allocate_id: TransactionId, local: SocketAddr) {
        allocation.handle_input(
            RELAY,
            local,
            &encode(allocate_response(allocate_id)),
            Instant::now(),
        );
    }

    fn allocate_response(id: TransactionId) -> stun_codec::Message<Attribute> {
        let mut message = stun_codec::Message::new(MessageClass::SuccessResponse, ALLOCATE, id);
        message.add_attribute(XorMappedAddress::new(PEER1));
        message.add_attribute(XorRelayAddress::new(RELAY_ADDR));
        message.add_attribute(Lifetime::new(Duration::from_secs(600)).unwrap());

        message
    }

    fn channel_bind_bad_request(id: TransactionId) -> stun_codec::Message<Attribute> {
        let mut message = stun_codec::Message::new(MessageClass::ErrorResponse, CHANNEL_BIND, id);
        message.add_attribute(ErrorCode::from(BadRequest));

        message
    }

    fn channel_bind_success(id: TransactionId) -> stun_codec::Message<Attribute> {
        stun_codec::Message::new(MessageClass::SuccessResponse, CHANNEL_BIND, id)
    }
}
