mod channel_data;

use crate::rfc8656::PeerAddressFamilyMismatch;
use crate::server::channel_data::ChannelData;
use crate::stun_codec_ext::{MessageClassExt, MethodExt};
use crate::TimeEvents;
use anyhow::Result;
use bytecodec::{DecodeExt, EncodeExt};
use core::fmt;
use rand::rngs::mock::StepRng;
use rand::rngs::ThreadRng;
use rand::Rng;
use std::collections::{HashMap, VecDeque};
use std::hash::Hash;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::time::{Duration, Instant};
use stun_codec::rfc5389::attributes::{
    ErrorCode, MessageIntegrity, Nonce, Realm, Username, XorMappedAddress,
};
use stun_codec::rfc5389::errors::{BadRequest, Unauthorized};
use stun_codec::rfc5389::methods::BINDING;
use stun_codec::rfc5766::attributes::{
    ChannelNumber, Lifetime, RequestedTransport, XorPeerAddress, XorRelayAddress,
};
use stun_codec::rfc5766::errors::{AllocationMismatch, InsufficientCapacity};
use stun_codec::rfc5766::methods::{ALLOCATE, CHANNEL_BIND, CREATE_PERMISSION, REFRESH};
use stun_codec::{Message, MessageClass, MessageDecoder, MessageEncoder, Method, TransactionId};

/// A sans-IO STUN & TURN server.
///
/// A [`Server`] is bound to an IPv4 address and assumes to only operate on UDP.
/// Thus, 3 out of the 5 components of a "5-tuple" are unique to an instance of [`Server`] and
/// we can index data simply by the sender's [`SocketAddr`].
///
/// Additionally, we assume to have complete ownership over the port range `LOWEST_PORT` - `HIGHEST_PORT`.
pub struct Server<R = ThreadRng> {
    decoder: MessageDecoder<Attribute>,
    encoder: MessageEncoder<Attribute>,

    public_ip4_address: Ipv4Addr,

    /// All client allocations, indexed by client's socket address.
    allocations: HashMap<SocketAddr, Allocation>,

    clients_by_allocation: HashMap<AllocationId, SocketAddr>,
    allocations_by_port: HashMap<u16, AllocationId>,

    channels_by_number: HashMap<u16, Channel>,
    channel_numbers_by_peer: HashMap<SocketAddr, u16>,

    pending_commands: VecDeque<Command>,
    next_allocation_id: AllocationId,

    rng: R,

    time_events: TimeEvents<TimedAction>,
}

/// The commands returned from a [`Server`].
///
/// The [`Server`] itself is sans-IO, meaning it is the caller responsibility to cause the side-effects described by these commands.
#[derive(Debug)]
pub enum Command {
    SendMessage {
        payload: Vec<u8>,
        recipient: SocketAddr,
    },
    /// Listen for traffic on the provided IP addresses.
    ///
    /// Any incoming data should be handed to the [`Server`] via [`Server::handle_relay_input`].
    AllocateAddresses { id: AllocationId, port: u16 },
    /// Free the addresses associated with the given [`AllocationId`].
    FreeAddresses { id: AllocationId },

    ForwardData {
        id: AllocationId,
        data: Vec<u8>,
        receiver: SocketAddr,
    },
    /// At the latest, the [`Server`] needs to be woken at the specified deadline to execute time-based actions correctly.
    Wake { deadline: Instant },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct AllocationId(u64);

impl AllocationId {
    fn next(&mut self) -> Self {
        let id = self.0;

        self.0 += 1;

        AllocationId(id)
    }
}

impl fmt::Display for AllocationId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "AID-{}", self.0)
    }
}

/// See <https://www.rfc-editor.org/rfc/rfc8656#name-requested-transport>.
const UDP_TRANSPORT: u8 = 17;

const LOWEST_PORT: u16 = 49152;
const HIGHEST_PORT: u16 = 65535;

/// The maximum number of ports available for allocation.
const MAX_AVAILABLE_PORTS: u16 = HIGHEST_PORT - LOWEST_PORT;

/// The maximum lifetime of an allocation.
const MAX_ALLOCATION_LIFETIME: Duration = Duration::from_secs(3600);

/// The default lifetime of an allocation.
///
/// See <https://www.rfc-editor.org/rfc/rfc8656#name-allocations-2>.
const DEFAULT_ALLOCATION_LIFETIME: Duration = Duration::from_secs(600);

/// The duration of a channel binding.
///
/// See <https://www.rfc-editor.org/rfc/rfc8656#name-channels-2>.
const CHANNEL_BINDING_DURATION: Duration = Duration::from_secs(600);

impl Server {
    pub fn new(public_ip4_address: Ipv4Addr) -> Self {
        // TODO: Validate that local IP isn't multicast / loopback etc.

        Self {
            decoder: Default::default(),
            encoder: Default::default(),
            public_ip4_address,
            allocations: Default::default(),
            clients_by_allocation: Default::default(),
            allocations_by_port: Default::default(),
            channels_by_number: Default::default(),
            channel_numbers_by_peer: Default::default(),
            pending_commands: Default::default(),
            next_allocation_id: AllocationId(1),
            rng: rand::thread_rng(),
            time_events: TimeEvents::default(),
        }
    }
}

impl<R> Server<R>
where
    R: Rng,
{
    /// Process the bytes received from a client.
    ///
    /// After calling this method, you should call [`Server::next_command`] until it returns `None`.
    pub fn handle_client_input(
        &mut self,
        bytes: &[u8],
        sender: SocketAddr,
        now: Instant,
    ) -> Result<()> {
        if tracing::enabled!(target: "wire", tracing::Level::TRACE) {
            let hex_bytes = hex::encode(bytes);
            tracing::trace!(target: "wire", r#"Input::client("{sender}","{hex_bytes}")"#);
        }

        // De-multiplex as per <https://www.rfc-editor.org/rfc/rfc8656#name-channels-2>.
        match bytes.first() {
            Some(0..=3) => {
                let Ok(message) = self.decoder.decode_from_bytes(bytes)? else {
                    tracing::warn!(target: "relay", "received broken STUN message from {sender}");
                    return Ok(());
                };

                tracing::trace!(target: "relay", "Received {} {} from {sender}", message.method().as_str(), message.class().as_str());

                self.dispatch_stun_message(message, sender, now, |server, message, sender, now| {
                    use MessageClass::*;
                    match (message.method(), message.class()) {
                        (BINDING, Request) => {
                            server.handle_binding_request(message, sender);
                            Ok(())
                        }
                        (ALLOCATE, Request) => server.handle_allocate_request(message, sender, now),
                        (REFRESH, Request) => server.handle_refresh_request(message, sender, now),
                        (CHANNEL_BIND, Request) => {
                            server.handle_channel_bind_request(message, sender, now)
                        }
                        (CREATE_PERMISSION, Request) => {
                            server.handle_create_permission_request(message, sender, now)
                        }
                        (_, Indication) => {
                            tracing::trace!(target: "relay", "Indications are not yet implemented");

                            Err(ErrorCode::from(BadRequest))
                        }
                        _ => Err(ErrorCode::from(BadRequest)),
                    }
                });
            }
            Some(64..=79) => {
                let msg = match ChannelData::parse(bytes) {
                    Ok(v) => v,
                    Err(e) => {
                        tracing::debug!(
                            target: "relay",
                            "failed to parse channel data message: {e:#}"
                        );
                        return Ok(());
                    }
                };

                self.handle_channel_data_message(msg, sender, now);
            }
            _ => {
                tracing::trace!(target: "relay", "Received unknown message from {sender}");
            }
        }

        Ok(())
    }

    /// Process the bytes received from an allocation.
    pub fn handle_relay_input(
        &mut self,
        bytes: &[u8],
        sender: SocketAddr,
        allocation_id: AllocationId,
    ) {
        if tracing::enabled!(target: "wire", tracing::Level::TRACE) {
            let hex_bytes = hex::encode(bytes);
            tracing::trace!(target: "wire", r#"Input::peer("{sender}","{hex_bytes}")"#);
        }

        let Some(client) = self.clients_by_allocation.get(&allocation_id) else {
            tracing::debug!(target: "relay", "unknown allocation {allocation_id}");
            return;
        };

        let Some(channel_number) = self.channel_numbers_by_peer.get(&sender) else {
            tracing::debug!(target: "relay", "no active channel for {sender}, refusing to relay {} bytes", bytes.len());
            return;
        };

        let Some(channel) = self.channels_by_number.get(channel_number) else {
            debug_assert!(false, "unknown channel {}", channel_number);
            return
        };

        if !channel.bound {
            tracing::debug!(
                target: "relay",
                "channel {channel_number} from {sender} to {client} existed but is unbound"
            );
            return;
        }

        if channel.allocation != allocation_id {
            tracing::debug!(
                target: "relay",
                "channel {channel_number} is not associated with allocation {allocation_id}",
            );
            return;
        }

        tracing::debug!(target: "relay", "Relaying {} bytes from {sender} to {client} via channel {channel_number}",
            bytes.len()
        );

        let recipient = *client;
        let data = ChannelData::new(*channel_number, bytes).to_bytes();

        if tracing::enabled!(target: "wire", tracing::Level::TRACE) {
            let hex_bytes = hex::encode(&data);
            tracing::trace!(target: "wire", r#"Output::send_message("{recipient}","{hex_bytes}")"#);
        }

        self.pending_commands.push_back(Command::SendMessage {
            payload: data,
            recipient,
        })
    }

    pub fn handle_deadline_reached(&mut self, now: Instant) {
        for action in self.time_events.pending_actions(now) {
            match action {
                TimedAction::ExpireAllocation(id) => {
                    let Some(allocation) = self.get_allocation(&id) else {
                        tracing::debug!(target: "relay", "Cannot expire non-existing allocation {id}");

                        continue;
                    };

                    if allocation.is_expired(now) {
                        self.delete_allocation(id)
                    }
                }
                TimedAction::UnbindChannel(chan) => {
                    let Some(channel) = self.channels_by_number.get_mut(&chan) else {
                        tracing::debug!(target: "relay", "Cannot expire non-existing channel binding {chan}");

                        continue;
                    };

                    if channel.is_expired(now) {
                        tracing::info!(target: "relay", "Channel {chan} is now expired");

                        channel.bound = false;

                        self.time_events.add(
                            now + Duration::from_secs(5 * 60),
                            TimedAction::DeleteChannel(chan),
                        );
                    }
                }
                TimedAction::DeleteChannel(chan) => {
                    self.delete_channel_binding(chan);
                }
            }
        }
    }

    /// Return the next command to be executed.
    pub fn next_command(&mut self) -> Option<Command> {
        self.pending_commands.pop_front()
    }

    fn dispatch_stun_message(
        &mut self,
        message: Message<Attribute>,
        sender: SocketAddr,
        now: Instant,
        handler: impl Fn(&mut Self, Message<Attribute>, SocketAddr, Instant) -> Result<(), ErrorCode>,
    ) {
        let transaction_id = message.transaction_id();
        let method = message.method();

        if let Err(e) = handler(self, message, sender, now) {
            if e.code() == Unauthorized::CODEPOINT {
                self.send_message(unauthorized(transaction_id, method), sender);
                return;
            }

            self.send_message(error_response(transaction_id, method, e), sender);
        }
    }

    fn handle_binding_request(&mut self, message: Message<Attribute>, sender: SocketAddr) {
        let mut message = Message::new(
            MessageClass::SuccessResponse,
            BINDING,
            message.transaction_id(),
        );
        message.add_attribute(XorMappedAddress::new(sender).into());

        self.send_message(message, sender);
    }

    /// Handle a TURN allocate request.
    ///
    /// See <https://www.rfc-editor.org/rfc/rfc8656#name-receiving-an-allocate-reque> for details.
    fn handle_allocate_request(
        &mut self,
        message: Message<Attribute>,
        sender: SocketAddr,
        now: Instant,
    ) -> Result<(), ErrorCode> {
        let _ = message
            .get_attribute::<MessageIntegrity>()
            .ok_or(Unauthorized)?;

        if self.allocations.contains_key(&sender) {
            return Err(AllocationMismatch.into());
        }

        if self.allocations_by_port.len() == MAX_AVAILABLE_PORTS as usize {
            return Err(InsufficientCapacity.into());
        }

        let requested_transport = message
            .get_attribute::<RequestedTransport>()
            .ok_or(BadRequest)?;

        if requested_transport.protocol() != UDP_TRANSPORT {
            return Err(BadRequest.into());
        }

        let requested_lifetime = message.get_attribute::<Lifetime>();

        let effective_lifetime = compute_effective_lifetime(requested_lifetime);

        // TODO: Do we need to handle DONT-FRAGMENT?
        // TODO: Do we need to handle EVEN/ODD-PORT?

        let allocation = self.create_new_allocation(now, &effective_lifetime);

        let mut message = Message::new(
            MessageClass::SuccessResponse,
            ALLOCATE,
            message.transaction_id(),
        );

        let ip4_relay_address = self.public_relay_address_for_port(allocation.port);

        message.add_attribute(XorRelayAddress::new(ip4_relay_address.into()).into());
        message.add_attribute(XorMappedAddress::new(sender).into());
        message.add_attribute(effective_lifetime.clone().into());

        let wake_deadline = self.time_events.add(
            allocation.expires_at,
            TimedAction::ExpireAllocation(allocation.id),
        );
        self.pending_commands.push_back(Command::Wake {
            deadline: wake_deadline,
        });
        self.pending_commands.push_back(Command::AllocateAddresses {
            id: allocation.id,
            port: allocation.port,
        });
        self.send_message(message, sender);

        tracing::info!(
            target: "relay",
            "Created new allocation for {sender} on {ip4_relay_address} and lifetime {}s",
            effective_lifetime.lifetime().as_secs()
        );

        self.clients_by_allocation.insert(allocation.id, sender);
        self.allocations.insert(sender, allocation);

        Ok(())
    }

    /// Handle a TURN refresh request.
    ///
    /// See <https://www.rfc-editor.org/rfc/rfc8656#name-receiving-a-refresh-request> for details.
    fn handle_refresh_request(
        &mut self,
        message: Message<Attribute>,
        sender: SocketAddr,
        now: Instant,
    ) -> Result<(), ErrorCode> {
        let _ = message
            .get_attribute::<MessageIntegrity>()
            .ok_or(Unauthorized)?;

        // TODO: Verify that this is the correct error code.
        let allocation = self
            .allocations
            .get_mut(&sender)
            .ok_or(ErrorCode::from(AllocationMismatch))?;

        let requested_lifetime = message.get_attribute::<Lifetime>();
        let effective_lifetime = compute_effective_lifetime(requested_lifetime);

        if effective_lifetime.lifetime().is_zero() {
            let port = allocation.port;

            self.pending_commands
                .push_back(Command::FreeAddresses { id: allocation.id });
            self.allocations.remove(&sender);
            self.allocations_by_port.remove(&port);
            self.send_message(
                refresh_success_response(effective_lifetime, message.transaction_id()),
                sender,
            );

            tracing::info!(
                target: "relay",
                "Deleted allocation for {sender} on port {port}"
            );

            return Ok(());
        }

        allocation.expires_at = now + effective_lifetime.lifetime();

        tracing::info!(
            target: "relay",
            "Refreshed allocation for {sender} on port {} and lifetime {}s",
            allocation.port,
            effective_lifetime.lifetime().as_secs()
        );

        let wake_deadline = self.time_events.add(
            allocation.expires_at,
            TimedAction::ExpireAllocation(allocation.id),
        );
        self.pending_commands.push_back(Command::Wake {
            deadline: wake_deadline,
        });
        self.send_message(
            refresh_success_response(effective_lifetime, message.transaction_id()),
            sender,
        );

        Ok(())
    }

    /// Handle a TURN channel bind request.
    ///
    /// See <https://www.rfc-editor.org/rfc/rfc8656#name-receiving-a-channelbind-req> for details.
    fn handle_channel_bind_request(
        &mut self,
        message: Message<Attribute>,
        sender: SocketAddr,
        now: Instant,
    ) -> Result<(), ErrorCode> {
        let _ = message
            .get_attribute::<MessageIntegrity>()
            .ok_or(Unauthorized)?;

        let allocation = self
            .allocations
            .get_mut(&sender)
            .ok_or(ErrorCode::from(AllocationMismatch))?;

        let requested_channel = message
            .get_attribute::<ChannelNumber>()
            .ok_or(ErrorCode::from(BadRequest))?
            .value();

        let peer_address = message
            .get_attribute::<XorPeerAddress>()
            .ok_or(ErrorCode::from(BadRequest))?
            .address();

        // Note: `channel_number` is enforced to be in the correct range.

        // Check that our allocation can handle the requested peer addr.
        if !allocation.can_relay_to(peer_address) {
            return Err(ErrorCode::from(PeerAddressFamilyMismatch));
        }

        // Ensure the same address isn't already bound to a different channel.
        if let Some(number) = self.channel_numbers_by_peer.get(&peer_address) {
            if number != &requested_channel {
                return Err(ErrorCode::from(BadRequest));
            }
        }

        // Ensure the channel is not already bound to a different address.
        if let Some(channel) = self.channels_by_number.get_mut(&requested_channel) {
            if channel.peer_address != peer_address {
                return Err(ErrorCode::from(BadRequest));
            }

            // Binding requests for existing channels act as a refresh for the binding.

            channel.refresh(now);

            tracing::info!(target: "relay", "Refreshed channel binding {requested_channel} between {sender} and {peer_address} on allocation {}", allocation.id);

            self.time_events.add(
                channel.expiry,
                TimedAction::UnbindChannel(requested_channel),
            );
            self.send_message(
                channel_bind_success_response(message.transaction_id()),
                sender,
            );

            return Ok(());
        }

        // Channel binding does not exist yet, create it.

        // TODO: Any additional validations would go here.
        // TODO: Capacity checking would go here.

        let allocation_id = allocation.id;
        self.create_channel_binding(requested_channel, peer_address, allocation_id, now);
        self.send_message(
            channel_bind_success_response(message.transaction_id()),
            sender,
        );

        tracing::info!(target: "relay", "Bound channel {requested_channel} between {sender} and {peer_address} on allocation {}", allocation_id);

        Ok(())
    }

    /// Handle a TURN create permission request.
    ///
    /// See <https://www.rfc-editor.org/rfc/rfc8656#name-receiving-a-createpermissio> for details.
    ///
    /// This TURN server implementation does not support relaying data other than through channels.
    /// Thus, creating a permission is a no-op that always succeeds.
    fn handle_create_permission_request(
        &mut self,
        message: Message<Attribute>,
        sender: SocketAddr,
        _: Instant,
    ) -> Result<(), ErrorCode> {
        let _ = message
            .get_attribute::<MessageIntegrity>()
            .ok_or(Unauthorized)?;
        self.send_message(
            create_permission_success_response(message.transaction_id()),
            sender,
        );

        Ok(())
    }

    fn handle_channel_data_message(
        &mut self,
        message: ChannelData,
        sender: SocketAddr,
        _: Instant,
    ) {
        let channel_number = message.channel();
        let data = message.data();

        let Some(channel) = self.channels_by_number.get(&channel_number) else {
            tracing::debug!(target: "relay", "Channel {channel_number} does not exist, refusing to forward data");
            return;
        };

        // TODO: Do we need to enforce that only the creator of the channel can relay data?
        // The sender of a UDP packet can be spoofed, so why would we bother?

        if !channel.bound {
            tracing::debug!(target: "relay", "Channel {channel_number} exists but is unbound");
            return;
        }

        let recipient = channel.peer_address;

        tracing::debug!(target: "relay", "Relaying {} bytes from {sender} to {recipient} via channel {channel_number}", data.len());

        if tracing::enabled!(target: "wire", tracing::Level::TRACE) {
            let hex_bytes = hex::encode(data);
            tracing::trace!(target: "wire", r#"Output::Forward("{recipient}","{hex_bytes}")"#);
        }

        self.pending_commands.push_back(Command::ForwardData {
            id: channel.allocation,
            data: data.to_vec(),
            receiver: recipient,
        });
    }

    fn create_new_allocation(&mut self, now: Instant, lifetime: &Lifetime) -> Allocation {
        // First, find an unused port.

        assert!(
            self.allocations_by_port.len() < MAX_AVAILABLE_PORTS as usize,
            "No more ports available; this would loop forever"
        );

        let port = loop {
            let candidate = self.rng.gen_range(LOWEST_PORT..HIGHEST_PORT);

            if !self.allocations_by_port.contains_key(&candidate) {
                break candidate;
            }
        };

        // Second, grab a new allocation ID.
        let id = self.next_allocation_id.next();

        self.allocations_by_port.insert(port, id);

        Allocation {
            id,
            port,
            expires_at: now + lifetime.lifetime(),
        }
    }

    fn create_channel_binding(
        &mut self,
        requested_channel: u16,
        peer_address: SocketAddr,
        id: AllocationId,
        now: Instant,
    ) {
        self.channels_by_number.insert(
            requested_channel,
            Channel {
                expiry: now + CHANNEL_BINDING_DURATION,
                peer_address,
                allocation: id,
                bound: true,
            },
        );
        self.channel_numbers_by_peer
            .insert(peer_address, requested_channel);
    }

    fn send_message(&mut self, message: Message<Attribute>, recipient: SocketAddr) {
        tracing::trace!(target: "relay", "Sending {} {} to {recipient}", message.method().as_str(), message.class().as_str());

        let Ok(bytes) = self.encoder.encode_into_bytes(message) else {
            debug_assert!(false, "Encoding should never fail");
            return;
        };

        if tracing::enabled!(target: "wire", tracing::Level::TRACE) {
            let hex_bytes = hex::encode(&bytes);
            tracing::trace!(target: "wire", r#"Output::SendMessage("{recipient}","{hex_bytes}")"#);
        }

        self.pending_commands.push_back(Command::SendMessage {
            payload: bytes,
            recipient,
        });
    }

    fn public_relay_address_for_port(&self, port: u16) -> SocketAddrV4 {
        SocketAddrV4::new(self.public_ip4_address, port)
    }

    fn get_allocation(&self, id: &AllocationId) -> Option<&Allocation> {
        self.clients_by_allocation
            .get(id)
            .and_then(|client| self.allocations.get(client))
    }

    fn delete_allocation(&mut self, id: AllocationId) {
        let Some(client) = self.clients_by_allocation.remove(&id) else {
            return;
        };

        self.allocations.remove(&client);
        self.pending_commands
            .push_back(Command::FreeAddresses { id });
    }

    fn delete_channel_binding(&mut self, chan: u16) {
        let Some(channel) = self.channels_by_number.get(&chan) else {
            return;
        };

        let addr = channel.peer_address;

        self.channel_numbers_by_peer.remove(&addr);
        self.channels_by_number.remove(&chan);
    }
}

fn refresh_success_response(
    effective_lifetime: Lifetime,
    transaction_id: TransactionId,
) -> Message<Attribute> {
    let mut message = Message::new(MessageClass::SuccessResponse, REFRESH, transaction_id);
    message.add_attribute(effective_lifetime.into());
    message
}

fn channel_bind_success_response(transaction_id: TransactionId) -> Message<Attribute> {
    Message::new(MessageClass::SuccessResponse, CHANNEL_BIND, transaction_id)
}

fn create_permission_success_response(transaction_id: TransactionId) -> Message<Attribute> {
    Message::new(
        MessageClass::SuccessResponse,
        CREATE_PERMISSION,
        transaction_id,
    )
}

impl Server<StepRng> {
    #[allow(dead_code)]
    pub fn test() -> Self {
        Self {
            decoder: Default::default(),
            encoder: Default::default(),
            public_ip4_address: Ipv4Addr::new(35, 124, 91, 37),
            allocations: HashMap::new(),
            clients_by_allocation: Default::default(),
            allocations_by_port: Default::default(),
            channels_by_number: Default::default(),
            next_allocation_id: AllocationId::default(),
            pending_commands: VecDeque::new(),
            rng: StepRng::new(0, 0),
            time_events: TimeEvents::default(),
            channel_numbers_by_peer: Default::default(),
        }
    }
}

/// Represents an allocation of a client.
struct Allocation {
    id: AllocationId,
    /// Data arriving on this port will be forwarded to the client iff there is an active data channel.
    port: u16,
    expires_at: Instant,
}

struct Channel {
    /// When the channel expires.
    expiry: Instant,

    /// The address of the peer that the channel is bound to.
    peer_address: SocketAddr,

    /// The allocation this channel belongs to.
    allocation: AllocationId,

    /// Whether the channel is currently bound.
    ///
    /// Channels are active for 10 minutes. During this time, data can be relayed through the channel.
    /// After 10 minutes, the channel is considered unbound.
    ///
    /// To prevent race conditions, we MUST NOT use the same channel number for a different peer and vice versa for another 5 minutes after the channel becomes unbound.
    /// Once it becomes unbound, we simply flip this bool and only completely remove the channel after another 5 minutes.
    ///
    /// With the data structure still existing while the channel is unbound, our existing validations cover the above requirement.
    bound: bool,
}

impl Channel {
    fn refresh(&mut self, now: Instant) {
        self.expiry = now + CHANNEL_BINDING_DURATION;
    }

    fn is_expired(&self, now: Instant) -> bool {
        self.expiry <= now
    }
}

impl Allocation {
    fn can_relay_to(&self, addr: SocketAddr) -> bool {
        // Currently, we only support IPv4, thus any IPv6 address is invalid.
        addr.is_ipv4()
    }
}

impl Allocation {
    fn is_expired(&self, now: Instant) -> bool {
        self.expires_at <= now
    }
}

enum TimedAction {
    ExpireAllocation(AllocationId),
    UnbindChannel(u16),
    DeleteChannel(u16),
}

/// Computes the effective lifetime of an allocation.
fn compute_effective_lifetime(requested_lifetime: Option<&Lifetime>) -> Lifetime {
    let Some(requested) = requested_lifetime else {
        return Lifetime::new(DEFAULT_ALLOCATION_LIFETIME).unwrap();
    };

    let effective_lifetime = requested.lifetime().min(MAX_ALLOCATION_LIFETIME);

    Lifetime::new(effective_lifetime).unwrap()
}

fn error_response(
    transaction_id: TransactionId,
    method: Method,
    error_code: ErrorCode,
) -> Message<Attribute> {
    let mut message = Message::new(MessageClass::ErrorResponse, method, transaction_id);
    message.add_attribute(error_code.into());

    message
}

fn unauthorized(transaction_id: TransactionId, method: Method) -> Message<Attribute> {
    let mut message = Message::new(MessageClass::ErrorResponse, method, transaction_id);
    message.add_attribute(ErrorCode::from(Unauthorized).into());
    message.add_attribute(Nonce::new("foobar".to_owned()).unwrap().into());
    message.add_attribute(Realm::new("firezone".to_owned()).unwrap().into());

    message
}

// Define an enum of all attributes that we care about for our server.
stun_codec::define_attribute_enums!(
    Attribute,
    AttributeDecoder,
    AttributeEncoder,
    [
        MessageIntegrity,
        XorMappedAddress,
        ErrorCode,
        RequestedTransport,
        XorRelayAddress,
        Lifetime,
        ChannelNumber,
        XorPeerAddress,
        Nonce,
        Realm,
        Username
    ]
);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requested_lifetime_is_capped_at_max_lifetime() {
        let requested_lifetime = Lifetime::new(Duration::from_secs(10_000_000)).unwrap();

        let effective_lifetime = compute_effective_lifetime(Some(&requested_lifetime));

        assert_eq!(effective_lifetime.lifetime(), MAX_ALLOCATION_LIFETIME)
    }
}
