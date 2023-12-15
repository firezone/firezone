use crate::{channel_data, FIREZONE};
use anyhow::Result;
use bytecodec::{DecodeExt, EncodeExt};
use futures::future::{BoxFuture, Fuse};
use futures::stream::{BoxStream, SelectAll};
use futures::{future, stream, FutureExt, StreamExt};
use rand::random;
use std::collections::HashMap;
use std::net::{SocketAddr, SocketAddrV4, SocketAddrV6};
use std::sync::Arc;
use std::task::{ready, Context, Poll, Waker};
use std::time::{Duration, Instant};
use stun_codec::rfc5389::attributes::{
    ErrorCode, MessageIntegrity, Nonce, Realm, Username, XorMappedAddress,
};
use stun_codec::rfc5389::errors::{StaleNonce, Unauthorized};
use stun_codec::rfc5389::methods::BINDING;
use stun_codec::rfc5766::attributes::{
    ChannelNumber, Lifetime, RequestedTransport, XorPeerAddress, XorRelayAddress,
};
use stun_codec::rfc5766::methods::{ALLOCATE, CHANNEL_BIND};
use stun_codec::rfc8656::attributes::{AdditionalAddressFamily, AddressFamily};
use stun_codec::{
    DecodedMessage, Message, MessageClass, MessageDecoder, MessageEncoder, TransactionId,
};

/// How often we will refresh a channel to a peer with a relay.
///
/// Channel bindings can also be used to refresh permissions.
/// In fact, our TURN relay doesn't have a concept of permissions but only uses channels.
///
/// Channels expire after 10 minutes, so we refresh them at half-time.
// const CHANNEL_REFRESH_DURATION: Duration = Duration::from_secs(60 * 5);

/// As per TURN spec, 0x4000 is the first channel number.
const FIRST_CHANNEL: u16 = 0x4000;

/// Represents a STUN binding (request).
///
/// A STUN binding request is a stateless, request-response operation.
/// We model the binding as a continuous operation that happens every X seconds.
/// This allows us to detect "roaming" of clients.
pub struct Binding {
    last_request: Option<Message<Attribute>>,
    last_binding_response: Option<SocketAddr>,

    next_request: tokio::time::Interval,
    server: SocketAddr,
}

impl Binding {
    pub fn new(server: SocketAddr) -> Self {
        Self {
            server,
            last_request: None,
            last_binding_response: None,
            next_request: tokio::time::interval(Duration::from_secs(60)),
        }
    }

    pub fn mapped_address(&self) -> Option<SocketAddr> {
        self.last_binding_response
    }

    pub fn handle_input(&mut self, from: SocketAddr, packet: &[u8]) -> bool {
        if from != self.server {
            return false;
        }

        let Ok(Ok(message)) = decode(packet) else {
            return false;
        };

        match self.last_request.as_ref() {
            Some(last_request) if last_request.transaction_id() == message.transaction_id() => {}
            _ => return false,
        }

        if let Some(mapped) = message.get_attribute::<XorMappedAddress>() {
            let address = mapped.address();

            tracing::debug!(%address, "Updated mapped address");
            self.last_binding_response = Some(address);
        } else {
            tracing::warn!("STUN response did not contain `XOR-MAPPED-ADDRESS`");
        }

        self.last_request = None;
        true
    }

    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<Transmit> {
        ready!(self.next_request.poll_tick(cx));

        let message = make_stun_request();
        let transmit = Transmit {
            dst: self.server,
            payload: encode(message.clone()),
        };

        self.last_request = Some(message);

        Poll::Ready(transmit)
    }
}
/// Represents a TURN allocation that refreshes itself.
///
/// Allocations have a lifetime and need to be continuously refreshed to stay active.
pub struct Allocation {
    relay: SocketAddr,

    ip4: Option<SocketAddrV4>,
    ip6: Option<SocketAddrV6>,
    last_binding_response: Option<SocketAddr>,

    sent_requests: HashMap<TransactionId, Message<Attribute>>,

    // TODO: This actually needs to be a refresh and not an allocate request.
    // But we also should try to make this allocation a couple of times before we give up, perhaps an exponential backoff?
    next_allocation_request: Fuse<BoxFuture<'static, ()>>, // This is separate because we need to honor the lifetime returned by the relay.

    pending_requests: SelectAll<BoxStream<'static, Message<Attribute>>>,
    no_pending_requests_waker: Option<Waker>,

    next_channel: u16,

    username: Username,
    password: String,
    nonce: Option<Nonce>,
}

impl Allocation {
    pub fn new(relay: SocketAddr, username: Username, password: String) -> Self {
        Self {
            relay,
            ip4: None,
            ip6: None,
            last_binding_response: None,
            sent_requests: Default::default(),
            next_allocation_request: tokio::time::sleep_until(Instant::now().into())
                .boxed()
                .fuse(),
            pending_requests: Default::default(),
            no_pending_requests_waker: None,
            next_channel: FIRST_CHANNEL,
            username,
            password,
            nonce: None,
        }
    }

    pub fn mapped_address(&self) -> Option<SocketAddr> {
        self.last_binding_response
    }

    pub fn ip4_socket(&self) -> Option<SocketAddrV4> {
        self.ip4
    }

    pub fn ip6_socket(&self) -> Option<SocketAddrV6> {
        self.ip6
    }

    pub fn handle_input(&mut self, from: SocketAddr, packet: &[u8]) -> bool {
        if from != self.relay {
            return false;
        }

        let Ok(Ok(message)) = decode(packet) else {
            return false;
        };

        let Some(original_request) = self.sent_requests.remove(&message.transaction_id()) else {
            return false;
        };

        if let Some(error) = message.get_attribute::<ErrorCode>() {
            // Check if we need to re-authenticate the original request
            if error.code() == Unauthorized::CODEPOINT || error.code() == StaleNonce::CODEPOINT {
                if let Some(nonce) = message.get_attribute::<Nonce>() {
                    self.nonce = Some(nonce.clone());
                };

                tracing::debug!(
                    method = %original_request.method(),
                    error = error.reason_phrase(),
                    "Request failed, re-authenticating"
                );

                self.pending_requests
                    .push(stream::once(future::ready(original_request)).boxed());

                if let Some(waker) = self.no_pending_requests_waker.take() {
                    waker.wake();
                }

                return true;
            }

            tracing::warn!(method = %original_request.method(), error = %error.reason_phrase(), "STUN request failed");
            return true;
        }

        if let Some(mapped_address) = message.get_attribute::<XorMappedAddress>() {
            let address = mapped_address.address();

            tracing::debug!(%address, "Updated mapped address");
            self.last_binding_response = Some(address);
        }

        for relay_addr in message.attributes().filter_map(|a| match a {
            Attribute::XorRelayAddress(a) => Some(a.address()),
            _ => None,
        }) {
            match relay_addr {
                SocketAddr::V4(v4) => {
                    tracing::debug!(address = %v4, "Updated relay address");
                    self.ip4 = Some(v4)
                }

                SocketAddr::V6(v6) => {
                    tracing::debug!(address = %v6, "Updated relay address");
                    self.ip6 = Some(v6)
                }
            }
        }

        true
    }

    pub fn bind_channel(&mut self, target: SocketAddr) -> Result<ChannelBinding, NoAllocation> {
        if self.ip4.is_none() && self.ip6.is_none() {
            return Err(NoAllocation);
        }

        let channel = self.next_channel;
        self.next_channel += 1;

        let reference = Arc::new((target, channel));

        let refresh_interval = tokio::time::interval(Duration::from_secs(60 * 5));
        let weak = Arc::downgrade(&reference);

        self.pending_requests.push(
            futures::stream::unfold(
                (refresh_interval, weak),
                |(mut interval, reference)| async move {
                    interval.tick().await;

                    let strong = reference.upgrade()?; // If we upgrade fails (i.e. returns `None`), the `ChannelBinding` was dropped and we can thus close the stream and stop refreshing it.
                    let (target, channel) = strong.as_ref();

                    let message = make_channel_bind_request(*target, *channel);

                    Some((message, (interval, reference)))
                },
            )
            .boxed(),
        );

        Ok(ChannelBinding {
            reference,
            relay: self.relay,
        })
    }

    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<Transmit> {
        if self.next_allocation_request.poll_unpin(cx).is_ready() {
            let message = self.authenticate(make_allocate_request());
            self.sent_requests
                .insert(message.transaction_id(), message.clone());

            return Poll::Ready(Transmit {
                dst: self.relay,
                payload: encode(message),
            });
        }

        if let Poll::Ready(Some(message)) = self.pending_requests.poll_next_unpin(cx) {
            let message = self.authenticate(message);
            self.sent_requests
                .insert(message.transaction_id(), message.clone());

            return Poll::Ready(Transmit {
                dst: self.relay,
                payload: encode(message),
            });
        }

        self.no_pending_requests_waker = Some(cx.waker().clone());
        Poll::Pending
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
                Attribute::Realm(FIREZONE.clone()),
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
            &FIREZONE,
            &self.password,
        )
        .expect("signing never fails");

        message.add_attribute(message_integrity);

        message
    }
}

#[derive(Debug)]
pub struct NoAllocation;

/// Represents a channel binding to a particular peer.
///
/// Channel bindings need to be refreshed to remain active.
/// This struct encapsulates this refresh process via an internal timer.
///
/// By dropping a [`ChannelBinding`] struct, this refresh process stops and the channel on the TURN server expires.
pub struct ChannelBinding {
    reference: Arc<(SocketAddr, u16)>,
    relay: SocketAddr,
}

impl ChannelBinding {
    /// The address of the remote peer this channel is bound to.
    pub fn peer(&self) -> SocketAddr {
        todo!()
    }

    /// Attempt to decapsulate the given packet as a channel data message.
    ///
    /// Returns the unpacked payload on success or `None` otherwise.
    pub fn decapsulate<'b>(&self, from: SocketAddr, packet: &'b [u8]) -> Option<&'b [u8]> {
        if from != self.relay {
            return None;
        }

        let (number, payload) = channel_data::decode(packet).ok()?;

        if number != self.reference.as_ref().1 {
            return None;
        }

        Some(payload)
    }

    pub fn encapsulate(&self, _packet: &[u8]) -> Option<(SocketAddr, [u8; 4])> {
        None
    }
}

#[derive(Debug)]
pub struct Transmit {
    pub dst: SocketAddr,
    pub payload: Vec<u8>,
}

fn make_stun_request() -> Message<Attribute> {
    Message::new(MessageClass::Request, BINDING, TransactionId::new(random()))
}

// TODO: Finish this impl.
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

// TODO: Finish this impl.
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

fn decode(packet: &[u8]) -> bytecodec::Result<DecodedMessage<Attribute>> {
    MessageDecoder::<Attribute>::default().decode_from_bytes(packet)
}

fn encode(message: Message<Attribute>) -> Vec<u8> {
    MessageEncoder::default()
        .encode_into_bytes(message.clone())
        .expect("encoding always works")
}

// Define an enum of all attributes that we care about for our server.
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
pub enum Event {
    Send {
        dest: SocketAddr,
        packet: Vec<u8>,
    },
    NewCandidate {
        server: SocketAddr,
        candidate: SocketAddr,
    },
    NewAllocation {
        server: SocketAddr,
        address: SocketAddr,
    },
}
