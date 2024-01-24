use crate::pool::Transmit;
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
    ip4_candidate: Option<Candidate>,
    /// If present, the IPv6 socket the relay allocated for us.
    last_ip6_candidate: Option<Candidate>,

    /// When we received the allocation and how long it is valid.
    allocation_lifetime: Option<(Instant, Duration)>,

    buffered_transmits: VecDeque<Transmit<'static>>,
    new_candidates: VecDeque<Candidate>,

    sent_requests: HashMap<TransactionId, (Message<Attribute>, Instant)>,

    channel_bindings: ChannelBindings,
    last_now: Option<Instant>,

    username: Username,
    password: String,
    realm: Realm,
    nonce: Option<Nonce>,
}

impl Allocation {
    pub fn new(server: SocketAddr, username: Username, password: String, realm: Realm) -> Self {
        Self {
            server,
            last_srflx_candidate: Default::default(),
            ip4_candidate: Default::default(),
            last_ip6_candidate: Default::default(),
            buffered_transmits: Default::default(),
            new_candidates: Default::default(),
            sent_requests: Default::default(),
            username,
            password,
            realm,
            nonce: Default::default(),
            allocation_lifetime: Default::default(),
            channel_bindings: Default::default(),
            last_now: Default::default(),
        }
    }

    pub fn current_candidates(&self) -> impl Iterator<Item = Candidate> {
        [
            self.last_srflx_candidate.clone(),
            self.ip4_candidate.clone(),
            self.last_ip6_candidate.clone(),
        ]
        .into_iter()
        .flatten()
    }

    pub fn handle_input(&mut self, from: SocketAddr, packet: &[u8], now: Instant) -> bool {
        if Some(now) > self.last_now {
            self.last_now = Some(now);
        }

        if from != self.server {
            return false;
        }

        let Ok(Ok(message)) = decode(packet) else {
            return false;
        };

        let Some((original_request, sent_at)) =
            self.sent_requests.remove(&message.transaction_id())
        else {
            return false;
        };

        let rtt = now.duration_since(sent_at);
        tracing::debug!(id = ?original_request.transaction_id(), method = %original_request.method(), ?rtt);

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
                    method = %original_request.method(),
                    error = error.reason_phrase(),
                    "Request failed, re-authenticating"
                );

                self.authenticate_and_queue(original_request, now);

                return true;
            }

            // TODO: Handle error codes such as:
            // - Failed allocations
            // - Failed channel bindings

            tracing::warn!(method = %original_request.method(), error = %error.reason_phrase(), "STUN request failed");
            return true;
        }

        if message.class() != MessageClass::SuccessResponse {
            tracing::warn!(
                "Cannot handle message with class {} for method {}",
                message.class(),
                message.method()
            );
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

                let maybe_srflx_candidate = message.attributes().find_map(srflx_candidate);
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
                    &mut self.ip4_candidate,
                    &mut self.new_candidates,
                );
                update_candidate(
                    maybe_ip6_relay_candidate,
                    &mut self.last_ip6_candidate,
                    &mut self.new_candidates,
                );

                tracing::info!(
                    srflx = ?self.last_srflx_candidate,
                    relay_ip4 = ?self.ip4_candidate,
                    relay_ip6 = ?self.last_ip6_candidate,
                    ?lifetime,
                    "Updated candidates of allocation"
                );
            }
            REFRESH => {
                let Some(lifetime) = message.get_attribute::<Lifetime>() else {
                    tracing::warn!("Message does not contain lifetime");
                    return true;
                };

                self.allocation_lifetime = Some((now, lifetime.lifetime()));

                tracing::info!(
                    srflx = ?self.last_srflx_candidate,
                    relay_ip4 = ?self.ip4_candidate,
                    relay_ip6 = ?self.last_ip6_candidate,
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
                };

                return true;
            }
            _ => {}
        }

        true
    }

    /// Attempts to decapsulate and incoming packet as a channel-data message.
    ///
    /// Returns the original sender, the packet and _our_ remote socket that this packet was sent to.
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

        // Our remote socket that we received this packet on!
        let remote_socket = match peer {
            SocketAddr::V4(_) => self.ip4_candidate.as_ref()?.addr(),
            SocketAddr::V6(_) => self.last_ip6_candidate.as_ref()?.addr(),
        };

        tracing::debug!(server = %self.server, %peer, %remote_socket, "Decapsulated channel-data message");

        Some((peer, payload, remote_socket))
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        if Some(now) > self.last_now {
            self.last_now = Some(now);
        }

        if !self.has_allocation() && !self.allocate_in_flight() {
            tracing::debug!(server = %self.server, "Request new allocation");

            self.authenticate_and_queue(make_allocate_request(), now);
        }

        while let Some(timed_out_request) =
            self.sent_requests.iter().find_map(|(id, (_, sent_at))| {
                (now.duration_since(*sent_at) >= REQUEST_TIMEOUT).then_some(*id)
            })
        {
            let (request, _) = self
                .sent_requests
                .remove(&timed_out_request)
                .expect("ID is from list");

            tracing::debug!(id = ?request.transaction_id(), method = %request.method(), "Request timed out, re-sending");

            self.authenticate_and_queue(request, now);
        }

        if let Some((received_at, lifetime)) = self.allocation_lifetime {
            let refresh_after = lifetime / 2;

            if now > received_at + refresh_after {
                tracing::debug!("Allocation is at 50% of its lifetime, refreshing");
                self.authenticate_and_queue(make_refresh_request(), now);
            }
        }

        let refresh_messages = self
            .channel_bindings
            .channels_to_refresh(now, |number| self.channel_binding_in_flight(number))
            .map(|(number, peer)| make_channel_bind_request(peer, number))
            .collect::<Vec<_>>(); // Need to allocate here to satisfy borrow-checker. Number of channel refresh messages should be small so this shouldn't be a big impact.

        for message in refresh_messages {
            self.authenticate_and_queue(message, now);
        }

        // TODO: Clean up unused channels
    }

    pub fn poll_candidate(&mut self) -> Option<Candidate> {
        self.new_candidates.pop_front()
    }

    pub fn poll_transmit(&mut self) -> Option<Transmit<'static>> {
        self.buffered_transmits.pop_front()
    }

    // pub fn poll_timeout(&self) -> Option<Instant> {
    //     None // TODO: Implement this.
    // }

    pub fn bind_channel(&mut self, peer: SocketAddr, now: Instant) {
        let Some(channel) = self.channel_bindings.new_channel_to_peer(peer, now) else {
            tracing::warn!(relay = %self.server, "All channels are exhausted");
            return;
        };

        self.authenticate_and_queue(make_channel_bind_request(peer, channel), now);
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
            crate::channel_data::encode_header_to_slice(channel_number, packet, header);

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

    fn has_allocation(&self) -> bool {
        self.ip4_candidate.is_some() || self.last_ip6_candidate.is_some()
    }

    fn allocate_in_flight(&self) -> bool {
        self.sent_requests
            .values()
            .any(|(r, _)| r.method() == ALLOCATE)
    }

    fn channel_binding_in_flight(&self, channel: u16) -> bool {
        self.sent_requests.values().any(|(r, _)| {
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

    fn authenticate_and_queue(&mut self, message: Message<Attribute>, now: Instant) {
        let authenticated_message = self.authenticate(message);
        let id = authenticated_message.transaction_id();

        self.sent_requests
            .insert(id, (authenticated_message.clone(), now));
        self.buffered_transmits.push_back(Transmit {
            src: None,
            dst: self.server,
            payload: encode(authenticated_message).into(),
        });
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
    // message.add_attribute(AdditionalAddressFamily::new(AddressFamily::V6)); TODO: Request IPv6 binding.

    message
}

fn make_refresh_request() -> Message<Attribute> {
    let mut message = Message::new(MessageClass::Request, REFRESH, TransactionId::new(random()));

    message.add_attribute(RequestedTransport::new(17));
    // message.add_attribute(AdditionalAddressFamily::new(AddressFamily::V6)); TODO: Request IPv6 binding.

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

fn srflx_candidate(attr: &Attribute) -> Option<Candidate> {
    let addr = match attr {
        Attribute::XorMappedAddress(a) => a.address(),
        _ => return None,
    };

    let new_candidate = match Candidate::server_reflexive(addr, Protocol::Udp) {
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

    fn set_confirmed(&mut self, c: u16, now: Instant) -> bool {
        let Some(channel) = self.inner.get_mut(&c) else {
            return false;
        };

        channel.set_confirmed(now);

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
        self.peer == peer && self.age(now) < Self::CHANNEL_LIFETIME
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{IpAddr, Ipv4Addr};

    const PEER1: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 10000);
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

    fn ch(peer: SocketAddr, now: Instant) -> Channel {
        Channel {
            peer,
            bound: true,
            bound_at: now,
            last_received: now,
        }
    }
}
