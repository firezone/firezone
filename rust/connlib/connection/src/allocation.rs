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

/// As per TURN spec, 0x4000 is the first channel number.
const FIRST_CHANNEL: u16 = 0x4000;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

const CHANNEL_LIFETIME: Duration = Duration::from_secs(10 * 60);

/// Represents a TURN allocation that refreshes itself.
///
/// Allocations have a lifetime and need to be continuously refreshed to stay active.
#[derive(Debug)]
pub struct Allocation {
    server: SocketAddr,

    last_srflx_candidate: Option<Candidate>,
    last_ip4_candidate: Option<Candidate>,
    last_ip6_candidate: Option<Candidate>,

    /// When we received the allocation and how long it is valid.
    allocation_lifetime: Option<(Instant, Duration)>,

    buffered_transmits: VecDeque<Transmit>,
    new_candidates: VecDeque<Candidate>,

    sent_requests: HashMap<TransactionId, (Message<Attribute>, Instant)>,

    channel_bindings: HashMap<u16, Channel>, // TODO: We need to track activity on these and keep them alive accordingly.

    next_channel: u16,
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
            last_ip4_candidate: Default::default(),
            last_ip6_candidate: Default::default(),
            buffered_transmits: Default::default(),
            new_candidates: Default::default(),
            sent_requests: Default::default(),
            next_channel: FIRST_CHANNEL,
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
            self.last_ip4_candidate.clone(),
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
                    &mut self.last_ip4_candidate,
                    &mut self.new_candidates,
                );
                update_candidate(
                    maybe_ip6_relay_candidate,
                    &mut self.last_ip6_candidate,
                    &mut self.new_candidates,
                );

                tracing::info!(
                    srflx = ?self.last_srflx_candidate,
                    relay_ip4 = ?self.last_ip4_candidate,
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
                    relay_ip4 = ?self.last_ip4_candidate,
                    relay_ip6 = ?self.last_ip6_candidate,
                    ?lifetime,
                    "Updated lifetime of allocation"
                );
            }
            CHANNEL_BIND => {
                let Some(channel) = original_request
                    .get_attribute::<ChannelNumber>()
                    .map(|c| c.value())
                    .and_then(|c| self.channel_bindings.get_mut(&c))
                else {
                    tracing::warn!("No local record of channel binding");
                    return true;
                };

                channel.set_confirmed(now);
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

        let (channel_number, payload) = crate::channel_data::decode(packet).ok()?;
        let channel = self.channel_bindings.get_mut(&channel_number)?;
        channel.record_received(now);

        debug_assert!(channel.bound); // TODO: Should we "force-set" this? We seem to be getting traffic on this channel ..

        // Our remote socket that we received this packet on!
        let remote_socket = match channel.peer {
            SocketAddr::V4(_) => self.last_ip4_candidate.as_ref()?.addr(),
            SocketAddr::V6(_) => self.last_ip6_candidate.as_ref()?.addr(),
        };

        tracing::debug!(server = %self.server, peer = %channel.peer, %remote_socket, "Decapsulated channel-data message");

        Some((channel.peer, payload, remote_socket))
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
            .iter()
            .filter_map(|(number, channel)| {
                let needs_refresh = channel.needs_refresh(now);
                let refresh_in_flight = self.channel_binding_in_flight(*number);

                if needs_refresh && !refresh_in_flight {
                    tracing::debug!(%number, relay = %self.server, peer = %channel.peer, "Refreshing channel binding");
                    return Some(make_channel_bind_request(channel.peer, *number))
                }

                None
            })
            .collect::<Vec<_>>(); // Need to allocate here to satisfy borrow-checker. Number of channel refresh messages should be small so this shouldn't be a big impact.

        for message in refresh_messages {
            self.authenticate_and_queue(message, now);
        }

        // TODO: Clean up unused channels
    }

    pub fn poll_candidate(&mut self) -> Option<Candidate> {
        self.new_candidates.pop_front()
    }

    pub fn poll_transmit(&mut self) -> Option<Transmit> {
        self.buffered_transmits.pop_front()
    }

    // pub fn poll_timeout(&self) -> Option<Instant> {
    //     None // TODO: Implement this.
    // }

    pub fn bind_channel(&mut self, peer: SocketAddr, now: Instant) {
        let channel = self.next_channel;
        self.next_channel += 1;

        self.authenticate_and_queue(make_channel_bind_request(peer, channel), now);
        self.channel_bindings.insert(
            channel,
            Channel {
                peer,
                bound: false,
                bound_at: now,
                last_received: now,
            },
        );
    }

    pub fn encode_to_slice(
        &mut self,
        peer: SocketAddr,
        packet: &[u8],
        header: &mut [u8],
        now: Instant,
    ) -> Option<usize> {
        let channel_number = self.channel_to_peer(peer, now)?;
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
        let channel_number = self.channel_to_peer(peer, now)?;
        let channel_data = crate::channel_data::encode(channel_number, packet);

        Some(channel_data)
    }

    fn channel_to_peer(&self, peer: SocketAddr, now: Instant) -> Option<u16> {
        self.channel_bindings
            .iter()
            .find(|(_, c)| c.connected_to_peer(peer, now))
            .map(|(n, _)| *n)
    }

    fn has_allocation(&self) -> bool {
        self.last_ip4_candidate.is_some() || self.last_ip6_candidate.is_some()
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
            dst: self.server,
            payload: encode(authenticated_message),
        });
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
    /// Check if this channel is connected to the given peer.
    ///
    /// In case the channel is older than its lifetime (10 minutes), this returns false because the relay will have de-allocated the channel.
    fn connected_to_peer(&self, peer: SocketAddr, now: Instant) -> bool {
        self.peer == peer && self.age(now) < CHANNEL_LIFETIME
    }

    /// Check if we need to refresh this channel.
    ///
    /// We will refresh all channels that:
    /// - are older than 5 minutes
    /// - we have received data on since we created / refreshed them
    fn needs_refresh(&self, now: Instant) -> bool {
        let channel_refresh_threshold = CHANNEL_LIFETIME / 2;

        if self.age(now) < channel_refresh_threshold {
            return false;
        }

        if self.last_received == self.bound_at {
            return false;
        }

        true
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{IpAddr, Ipv4Addr};

    const PEER1: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 10000);
    const MINUTE: Duration = Duration::from_secs(60);

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

    fn ch(peer: SocketAddr, now: Instant) -> Channel {
        Channel {
            peer,
            bound: true,
            bound_at: now,
            last_received: now,
        }
    }
}
