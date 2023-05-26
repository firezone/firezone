mod channel_data;
mod client_message;

use crate::rfc8656::PeerAddressFamilyMismatch;
use crate::server::channel_data::ChannelData;
use crate::server::client_message::{
    Allocate, Binding, ChannelBind, ClientMessage, CreatePermission, Refresh,
};
use crate::stun_codec_ext::{MessageClassExt, MethodExt};
use crate::TimeEvents;
use anyhow::Result;
use bytecodec::EncodeExt;
use core::fmt;
use rand::rngs::mock::StepRng;
use rand::Rng;
use std::collections::{HashMap, VecDeque};
use std::hash::Hash;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::time::{Duration, SystemTime};
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
use stun_codec::{Message, MessageClass, MessageEncoder, Method, TransactionId};

/// A sans-IO STUN & TURN server.
///
/// A [`Server`] is bound to an IPv4 address and assumes to only operate on UDP.
/// Thus, 3 out of the 5 components of a "5-tuple" are unique to an instance of [`Server`] and
/// we can index data simply by the sender's [`SocketAddr`].
///
/// Additionally, we assume to have complete ownership over the port range `LOWEST_PORT` - `HIGHEST_PORT`.
pub struct Server<R> {
    decoder: client_message::Decoder,
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

    auth_secret: [u8; 32],

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
    Wake { deadline: SystemTime },
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

/// The duration of a channel binding.
///
/// See <https://www.rfc-editor.org/rfc/rfc8656#name-channels-2>.
const CHANNEL_BINDING_DURATION: Duration = Duration::from_secs(600);

impl<R> Server<R>
where
    R: Rng,
{
    pub fn new(public_ip4_address: Ipv4Addr, mut rng: R) -> Self {
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
            auth_secret: rng.gen(),
            rng,
            time_events: TimeEvents::default(),
        }
    }

    pub fn auth_secret(&mut self) -> [u8; 32] {
        self.auth_secret
    }

    /// Process the bytes received from a client.
    ///
    /// After calling this method, you should call [`Server::next_command`] until it returns `None`.
    pub fn handle_client_input(&mut self, bytes: &[u8], sender: SocketAddr, now: SystemTime) {
        if tracing::enabled!(target: "wire", tracing::Level::TRACE) {
            let hex_bytes = hex::encode(bytes);
            tracing::trace!(target: "wire", r#"Input::client("{sender}","{hex_bytes}")"#);
        }

        let result = match self.decoder.decode(bytes) {
            Ok(Ok(ClientMessage::Allocate(request))) => {
                self.handle_allocate_request(request, sender, now)
            }
            Ok(Ok(ClientMessage::Refresh(request))) => {
                self.handle_refresh_request(request, sender, now)
            }
            Ok(Ok(ClientMessage::ChannelBind(request))) => {
                self.handle_channel_bind_request(request, sender, now)
            }
            Ok(Ok(ClientMessage::CreatePermission(request))) => {
                self.handle_create_permission_request(request, sender, now)
            }
            Ok(Ok(ClientMessage::Binding(request))) => {
                self.handle_binding_request(request, sender);
                return;
            }
            Ok(Ok(ClientMessage::ChannelData(msg))) => {
                self.handle_channel_data_message(msg, sender, now);
                return;
            }

            // Could parse the bytes but message was semantically invalid (like missing attribute).
            Ok(Err(error_code)) => Err(error_code),

            // Parsing the bytes failed.
            Err(client_message::Error::BadChannelData(_)) => return,
            Err(client_message::Error::DecodeStun(_)) => return,
            Err(client_message::Error::UnknownMessageType(_)) => return,
            Err(client_message::Error::Eof) => return,
        };

        let Err(mut error_response) = result else {
            return;
        };

        // In case of a 401 response, attach a realm and nonce.
        if error_response
            .get_attribute::<ErrorCode>()
            .map_or(false, |error| error == &ErrorCode::from(Unauthorized))
        {
            error_response.add_attribute(Nonce::new("foobar".to_owned()).unwrap().into());
            error_response.add_attribute(Realm::new("firezone".to_owned()).unwrap().into());
        }

        self.send_message(error_response, sender);
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

    pub fn handle_deadline_reached(&mut self, now: SystemTime) {
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

    pub fn handle_binding_request(&mut self, message: Binding, sender: SocketAddr) {
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
    pub fn handle_allocate_request(
        &mut self,
        request: Allocate,
        sender: SocketAddr,
        now: SystemTime,
    ) -> Result<(), Message<Attribute>> {
        // TODO: Check validity of message integrity here?

        if self.allocations.contains_key(&sender) {
            return Err(error_response(AllocationMismatch, &request));
        }

        if self.allocations_by_port.len() == MAX_AVAILABLE_PORTS as usize {
            return Err(error_response(InsufficientCapacity, &request));
        }

        if request.requested_transport().protocol() != UDP_TRANSPORT {
            return Err(error_response(BadRequest, &request));
        }

        let effective_lifetime = request.effective_lifetime();

        // TODO: Do we need to handle DONT-FRAGMENT?
        // TODO: Do we need to handle EVEN/ODD-PORT?

        let allocation = self.create_new_allocation(now, &effective_lifetime);

        let mut message = Message::new(
            MessageClass::SuccessResponse,
            ALLOCATE,
            request.transaction_id(),
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
    pub fn handle_refresh_request(
        &mut self,
        request: Refresh,
        sender: SocketAddr,
        now: SystemTime,
    ) -> Result<(), Message<Attribute>> {
        // TODO: Check validity of message integrity here?

        // TODO: Verify that this is the correct error code.
        let allocation = self
            .allocations
            .get_mut(&sender)
            .ok_or(error_response(AllocationMismatch, &request))?;

        let effective_lifetime = request.effective_lifetime();

        if effective_lifetime.lifetime().is_zero() {
            let port = allocation.port;

            self.pending_commands
                .push_back(Command::FreeAddresses { id: allocation.id });
            self.allocations.remove(&sender);
            self.allocations_by_port.remove(&port);
            self.send_message(
                refresh_success_response(effective_lifetime, request.transaction_id()),
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
            refresh_success_response(effective_lifetime, request.transaction_id()),
            sender,
        );

        Ok(())
    }

    /// Handle a TURN channel bind request.
    ///
    /// See <https://www.rfc-editor.org/rfc/rfc8656#name-receiving-a-channelbind-req> for details.
    pub fn handle_channel_bind_request(
        &mut self,
        request: ChannelBind,
        sender: SocketAddr,
        now: SystemTime,
    ) -> Result<(), Message<Attribute>> {
        // TODO: Check validity of message integrity here?

        let allocation = self
            .allocations
            .get_mut(&sender)
            .ok_or(error_response(AllocationMismatch, &request))?;

        let requested_channel = request.channel_number().value();
        let peer_address = request.xor_peer_address().address();

        // Note: `channel_number` is enforced to be in the correct range.

        // Check that our allocation can handle the requested peer addr.
        if !allocation.can_relay_to(peer_address) {
            return Err(error_response(PeerAddressFamilyMismatch, &request));
        }

        // Ensure the same address isn't already bound to a different channel.
        if let Some(number) = self.channel_numbers_by_peer.get(&peer_address) {
            if number != &requested_channel {
                return Err(error_response(BadRequest, &request));
            }
        }

        // Ensure the channel is not already bound to a different address.
        if let Some(channel) = self.channels_by_number.get_mut(&requested_channel) {
            if channel.peer_address != peer_address {
                return Err(error_response(BadRequest, &request));
            }

            // Binding requests for existing channels act as a refresh for the binding.

            channel.refresh(now);

            tracing::info!(target: "relay", "Refreshed channel binding {requested_channel} between {sender} and {peer_address} on allocation {}", allocation.id);

            self.time_events.add(
                channel.expiry,
                TimedAction::UnbindChannel(requested_channel),
            );
            self.send_message(
                channel_bind_success_response(request.transaction_id()),
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
            channel_bind_success_response(request.transaction_id()),
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
    pub fn handle_create_permission_request(
        &mut self,
        message: CreatePermission,
        sender: SocketAddr,
        _: SystemTime,
    ) -> Result<(), Message<Attribute>> {
        // TODO: Check validity of message integrity here?

        self.send_message(
            create_permission_success_response(message.transaction_id()),
            sender,
        );

        Ok(())
    }

    pub fn handle_channel_data_message(
        &mut self,
        message: ChannelData,
        sender: SocketAddr,
        _: SystemTime,
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

    fn create_new_allocation(&mut self, now: SystemTime, lifetime: &Lifetime) -> Allocation {
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
        now: SystemTime,
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
        let rng = StepRng::new(0, 0);
        let public_ip4_address = Ipv4Addr::new(35, 124, 91, 37);

        Self::new(public_ip4_address, rng)
    }
}

/// Represents an allocation of a client.
struct Allocation {
    id: AllocationId,
    /// Data arriving on this port will be forwarded to the client iff there is an active data channel.
    port: u16,
    expires_at: SystemTime,
}

struct Channel {
    /// When the channel expires.
    expiry: SystemTime,

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
    fn refresh(&mut self, now: SystemTime) {
        self.expiry = now + CHANNEL_BINDING_DURATION;
    }

    fn is_expired(&self, now: SystemTime) -> bool {
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
    fn is_expired(&self, now: SystemTime) -> bool {
        self.expires_at <= now
    }
}

enum TimedAction {
    ExpireAllocation(AllocationId),
    UnbindChannel(u16),
    DeleteChannel(u16),
}

fn error_response(
    error_code: impl Into<ErrorCode>,
    request: &impl StunRequest,
) -> Message<Attribute> {
    let mut message = Message::new(
        MessageClass::ErrorResponse,
        request.method(),
        request.transaction_id(),
    );
    message.add_attribute(Attribute::from(error_code.into()));

    message
}

/// Private helper trait to make [`error_response`] more ergonomic to use.
trait StunRequest {
    fn transaction_id(&self) -> TransactionId;
    fn method(&self) -> Method;
}

macro_rules! impl_stun_request_for {
    ($t:ty, $m:expr) => {
        impl StunRequest for $t {
            fn transaction_id(&self) -> TransactionId {
                self.transaction_id()
            }

            fn method(&self) -> Method {
                $m
            }
        }
    };
}

impl_stun_request_for!(Allocate, ALLOCATE);
impl_stun_request_for!(ChannelBind, CHANNEL_BIND);
impl_stun_request_for!(CreatePermission, CREATE_PERMISSION);
impl_stun_request_for!(Refresh, REFRESH);

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
