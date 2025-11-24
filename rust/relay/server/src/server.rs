mod channel_data;
mod client_message;

pub use crate::server::channel_data::ChannelData;
pub use crate::server::client_message::{
    Allocate, Binding, ChannelBind, ClientMessage, CreatePermission, Refresh,
};

use crate::auth::{self, AuthenticatedMessage, FIREZONE, MessageIntegrityExt, Nonces};
use crate::net_ext::IpAddrExt;
use crate::{ClientSocket, IpStack, PeerSocket, SOFTWARE};
use anyhow::Result;
use bytecodec::EncodeExt;
use core::fmt;
use hex_display::HexDisplayExt as _;
use logging::err_with_src;
use opentelemetry::KeyValue;
use opentelemetry::metrics::{Counter, UpDownCounter};
use rand::Rng;
use secrecy::SecretString;
use smallvec::SmallVec;
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::hash::Hash;
use std::net::{IpAddr, SocketAddr};
use std::ops::RangeInclusive;
use std::time::{Duration, Instant, SystemTime};
use stun_codec::rfc5389::attributes::{
    ErrorCode, MessageIntegrity, Nonce, Realm, Software, Username, XorMappedAddress,
};
use stun_codec::rfc5389::errors::{BadRequest, ServerError, StaleNonce, Unauthorized};
use stun_codec::rfc5389::methods::BINDING;
use stun_codec::rfc5766::attributes::{
    ChannelNumber, Lifetime, RequestedTransport, XorPeerAddress, XorRelayAddress,
};
use stun_codec::rfc5766::errors::{AllocationMismatch, InsufficientCapacity};
use stun_codec::rfc5766::methods::{ALLOCATE, CHANNEL_BIND, CREATE_PERMISSION, REFRESH};
use stun_codec::rfc8656::attributes::{
    AdditionalAddressFamily, AddressFamily, RequestedAddressFamily,
};
use stun_codec::rfc8656::errors::{AddressFamilyNotSupported, PeerAddressFamilyMismatch};
use stun_codec::{Message, MessageClass, Method, TransactionId};
use tracing::field;
use uuid::Uuid;

/// A sans-IO STUN & TURN server.
///
/// A [`Server`] is bound to an IPv4 address and assumes to only operate on UDP.
/// Thus, 3 out of the 5 components of a "5-tuple" are unique to an instance of [`Server`] and
/// we can index data simply by the sender's [`SocketAddr`].
///
/// Additionally, we assume to have complete ownership over the port range `lowest_port` - `highest_port`.
#[derive(Debug)]
pub struct Server<R> {
    public_address: IpStack,

    /// All client allocations, indexed by client's socket address.
    allocations: BTreeMap<ClientSocket, Allocation>,
    clients_by_allocation: HashMap<AllocationPort, ClientSocket>,
    /// Redundant mapping so we can look route data with a single lookup.
    channel_and_client_by_port_and_peer:
        HashMap<(AllocationPort, PeerSocket), (ClientSocket, ChannelNumber)>,

    listen_port: u16,

    ports: RangeInclusive<u16>,

    /// Channel numbers are unique by client, thus indexed by both.
    channels_by_client_and_number: BTreeMap<(ClientSocket, ChannelNumber), Channel>,
    /// Channel numbers are unique between clients and peers, thus indexed by both.
    channel_numbers_by_client_and_peer: HashMap<(ClientSocket, PeerSocket), ChannelNumber>,

    pending_commands: VecDeque<Command>,

    rng: R,

    auth_secret: SecretString,

    nonces: Nonces,

    allocations_up_down_counter: UpDownCounter<i64>,
    data_relayed_counter: Counter<u64>,
    data_relayed: u64, // Keep a separate counter because `Counter` doesn't expose the current value :(
    responses_counter: Counter<u64>,
}

/// The commands returned from a [`Server`].
///
/// The [`Server`] itself is sans-IO, meaning it is the caller responsibility to cause the side-effects described by these commands.
#[derive(Debug, PartialEq, Clone)]
pub enum Command {
    SendMessage {
        payload: Vec<u8>,
        recipient: ClientSocket,
    },
    /// Listen for traffic on the provided port [AddressFamily].
    ///
    /// Any incoming data should be handed to the [`Server`] via [`Server::handle_peer_traffic`].
    /// A single allocation can reference one of either [AddressFamily]s or both.
    /// Only the combination of [AllocationPort] and [AddressFamily] is unique.
    CreateAllocation {
        port: AllocationPort,
        family: AddressFamily,
    },
    /// Free the allocation associated with the given [AllocationPort] and [AddressFamily].
    FreeAllocation {
        port: AllocationPort,
        family: AddressFamily,
    },
    CreateChannelBinding {
        client: ClientSocket,
        channel_number: ChannelNumber,

        peer: PeerSocket,
        allocation_port: AllocationPort,
    },
    DeleteChannelBinding {
        client: ClientSocket,
        channel_number: ChannelNumber,

        peer: PeerSocket,
        allocation_port: AllocationPort,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct AllocationPort(u16);

impl AllocationPort {
    pub fn new(port: u16) -> Self {
        Self(port)
    }

    pub fn value(&self) -> u16 {
        self.0
    }
}

impl fmt::Display for AllocationPort {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

/// See <https://www.rfc-editor.org/rfc/rfc8656#name-requested-transport>.
const UDP_TRANSPORT: u8 = 17;

/// The duration of a channel binding.
///
/// See <https://www.rfc-editor.org/rfc/rfc8656#name-channels-2>.
const CHANNEL_BINDING_DURATION: Duration = Duration::from_secs(600);

/// The timeout before a channel be rebound.
///
/// See <https://www.rfc-editor.org/rfc/rfc8656#section-12-14>.
const CHANNEL_REBIND_TIMEOUT: Duration = Duration::from_secs(300);

impl<R> Server<R>
where
    R: Rng,
{
    /// Constructs a new [`Server`].
    ///
    /// # Port configuration
    ///
    /// The [TURN RFC](https://www.rfc-editor.org/rfc/rfc8656#section-7.2-6) recommends using the port range `49152 - 65535`.
    /// We make this configurable here because there are several situations in which we don't want to use the full range:
    /// - Users might already have other services deployed on the same machine that overlap with the ports the RFC recommends.
    /// - Docker Desktop struggles with forwarding large port ranges to the host with the default networking mode.
    pub fn new(
        public_address: impl Into<IpStack>,
        mut rng: R,
        listen_port: u16,
        ports: RangeInclusive<u16>,
    ) -> Self {
        // TODO: Validate that local IP isn't multicast / loopback etc.

        let meter = opentelemetry::global::meter("relay");

        let allocations_up_down_counter = meter
            .i64_up_down_counter("allocations_total")
            .with_description("The number of active allocations")
            .build();
        let responses_counter = meter
            .u64_counter("responses_total")
            .with_description("The number of responses")
            .build();
        let data_relayed_counter = meter
            .u64_counter("data_relayed_userspace_bytes")
            .with_description("The number of bytes relayed")
            .with_unit("b")
            .build();

        Self {
            public_address: public_address.into(),
            allocations: Default::default(),
            clients_by_allocation: Default::default(),
            listen_port,
            ports,
            channels_by_client_and_number: Default::default(),
            channel_numbers_by_client_and_peer: Default::default(),
            pending_commands: Default::default(),
            auth_secret: SecretString::from(hex::encode(rng.r#gen::<[u8; 32]>())),
            rng,
            nonces: Default::default(),
            allocations_up_down_counter,
            responses_counter,
            data_relayed_counter,
            data_relayed: 0,
            channel_and_client_by_port_and_peer: Default::default(),
        }
    }

    pub fn auth_secret(&self) -> &SecretString {
        &self.auth_secret
    }

    pub fn public_address(&self) -> IpStack {
        self.public_address
    }

    pub fn public_ip4(&self) -> Option<IpAddr> {
        Some(IpAddr::V4(*self.public_address.as_v4()?))
    }

    pub fn public_ip6(&self) -> Option<IpAddr> {
        Some(IpAddr::V6(*self.public_address.as_v6()?))
    }

    pub fn listen_port(&self) -> u16 {
        self.listen_port
    }

    /// Registers a new, valid nonce.
    ///
    /// Each nonce is valid for 10 requests.
    pub fn add_nonce(&mut self, nonce: Uuid) {
        self.nonces.add_new(nonce);
    }

    pub fn num_relayed_bytes(&self) -> u64 {
        self.data_relayed
    }

    pub fn num_allocations(&self) -> usize {
        self.allocations.len()
    }

    pub fn num_active_channels(&self) -> usize {
        self.channels_by_client_and_number
            .iter()
            .filter(|(_, c)| c.bound)
            .count()
    }

    /// Process the bytes received from a client.
    ///
    /// # Returns
    ///
    /// - [`Some`] if the provided bytes were a [`ChannelData`] message.
    ///   In that case, you should forward the _payload_ to the [`PeerSocket`] on the [`AllocationPort`].
    pub fn handle_client_input(
        &mut self,
        bytes: &[u8],
        sender: ClientSocket,
        now: Instant,
    ) -> Option<(AllocationPort, PeerSocket)> {
        tracing::trace!(target: "wire", num_bytes = %bytes.len());

        match client_message::decode(bytes) {
            Ok(Ok(message)) => {
                return self.handle_client_message(message, sender, now);
            }
            // Could parse the bytes but message was semantically invalid (like missing attribute).
            Ok(Err(error_response)) => {
                tracing::warn!(target: "relay", %sender, method = %error_response.method(), "Failed to decode message");

                // This is fine, the original message failed to parse to we cannot respond with an authenticated reply.
                let message = AuthenticatedMessage::new_dangerous_unauthenticated(error_response);

                self.send_message(message, sender);
            }
            // Parsing the bytes failed.
            Err(client_message::Error::BadChannelData(ref error)) => {
                tracing::debug!(target: "relay", %error, "failed to decode channel data")
            }
            Err(client_message::Error::DecodeStun(ref error)) => {
                tracing::debug!(target: "relay", %error, "failed to decode stun packet")
            }
            Err(client_message::Error::UnknownMessageType(t)) => {
                tracing::debug!(target: "relay", r#type = %t, "unknown STUN message type")
            }
            Err(client_message::Error::Eof) => {
                tracing::debug!(target: "relay", "unexpected EOF while parsing message")
            }
        };

        None
    }

    pub fn handle_client_message(
        &mut self,
        message: ClientMessage,
        sender: ClientSocket,
        now: Instant,
    ) -> Option<(AllocationPort, PeerSocket)> {
        let result = match &message {
            ClientMessage::Allocate(request) => self.handle_allocate_request(request, sender, now),
            ClientMessage::Refresh(request) => self.handle_refresh_request(request, sender, now),
            ClientMessage::ChannelBind(request) => {
                self.handle_channel_bind_request(request, sender, now)
            }
            ClientMessage::CreatePermission(request) => {
                self.handle_create_permission_request(request, sender)
            }
            ClientMessage::Binding(request) => {
                self.handle_binding_request(request, sender);
                return None;
            }
            ClientMessage::ChannelData(msg) => {
                return self.handle_channel_data_message(msg, sender);
            }
        };

        let Err(mut error_response) = result else {
            return None;
        };

        let is_auth_error = error_response
            .get_attribute::<ErrorCode>()
            .is_some_and(|error_code| {
                error_code == &ErrorCode::from(Unauthorized)
                    || error_code == &ErrorCode::from(StaleNonce)
            });

        // In case of a 401 or 438 response, attach a realm and nonce.
        if is_auth_error {
            error_response.add_attribute((*FIREZONE).clone());
            error_response.add_attribute(self.new_nonce_attribute());
        }

        let message = match message.username() {
            Some(username) => {
                match AuthenticatedMessage::new(&self.auth_secret, username, error_response) {
                    Ok(message) => message,
                    Err(e) => {
                        tracing::warn!(target: "relay", "Failed to create error response: {}", err_with_src(&e));
                        return None;
                    }
                }
            }
            None => {
                tracing::warn!(target: "relay", ?message, "Unable to authenticate error response, message did not contain a `Username` attribute");

                AuthenticatedMessage::new_dangerous_unauthenticated(error_response)
            }
        };

        self.send_message(message, sender);

        None
    }

    /// Process the bytes received from an allocation.
    ///
    /// # Returns
    ///
    /// - [`Some`] if there is an active channel on this allocation for this peer.
    ///   In that case, you should create a [`ChannelData`] message with the returned channel number and send it to the [`ClientSocket`].
    pub fn handle_peer_traffic(
        &mut self,
        msg: &[u8],
        sender: PeerSocket,
        allocation: AllocationPort,
    ) -> Option<(ClientSocket, ChannelNumber)> {
        let Some((client, channel_number)) = self
            .channel_and_client_by_port_and_peer
            .get(&(allocation, sender))
        else {
            tracing::debug!(target: "relay", %sender, %allocation, "no channel");

            return None;
        };

        self.data_relayed_counter.add(msg.len() as u64, &[]);
        self.data_relayed += msg.len() as u64;

        tracing::trace!(target: "wire", num_bytes = %msg.len());

        Some((*client, *channel_number))
    }

    /// An allocation failed.
    pub fn handle_allocation_failed(&mut self, allocation: AllocationPort) {
        self.delete_allocation(allocation)
    }

    /// Return the next command to be executed.
    pub fn next_command(&mut self) -> Option<Command> {
        self.pending_commands.pop_front()
    }

    // TODO: It might be worth to do some caching here?
    pub fn poll_timeout(&self) -> Option<Instant> {
        let channel_expiries = self.channels_by_client_and_number.values().map(|c| {
            if c.bound {
                c.expiry
            } else {
                c.expiry + CHANNEL_REBIND_TIMEOUT
            }
        });
        let allocation_expiries = self.allocations.values().map(|a| a.expires_at);

        channel_expiries
            .chain(allocation_expiries)
            .fold(None, |current, next| earliest(current, Some(next)))
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        let expired_allocations = self
            .allocations
            .values()
            .filter_map(|a| a.is_expired(now).then_some(a.port))
            .collect::<Vec<_>>();

        for id in expired_allocations {
            self.delete_allocation(id);
        }

        for ((client, number), channel) in self
            .channels_by_client_and_number
            .iter_mut()
            .filter(|(_, c)| c.is_expired(now) && c.bound)
        {
            tracing::info!(target: "relay", channel = %number.value(), %client, peer = %channel.peer_address, allocation = %channel.allocation, "Channel is now expired");

            self.pending_commands
                .push_back(Command::DeleteChannelBinding {
                    client: *client,
                    channel_number: *number,
                    peer: channel.peer_address,
                    allocation_port: channel.allocation,
                });

            channel.bound = false;
            if let Some((cs, n)) = self
                .channel_and_client_by_port_and_peer
                .remove(&(channel.allocation, channel.peer_address))
            {
                debug_assert_eq!(&cs, client, "internal state should be consistent");
                debug_assert_eq!(&n, number, "internal state should be consistent");
            };
        }

        let channels_to_delete = self
            .channels_by_client_and_number
            .iter()
            .filter_map(|(id, c)| c.can_be_deleted(now).then_some(*id))
            .collect::<Vec<_>>();

        for (client_socket, number) in channels_to_delete {
            self.delete_channel_binding(client_socket, number);
        }
    }

    #[tracing::instrument(level = "info", skip_all, fields(software = request.software().map(|s| field::display(s.description())), tid = %format_args!("{:X}", request.transaction_id().as_bytes().hex()), %sender))]
    fn handle_binding_request(&mut self, request: &Binding, sender: ClientSocket) {
        let mut message = success_response(BINDING, request.transaction_id());
        message.add_attribute(XorMappedAddress::new(sender.0));

        tracing::info!("Handled BINDING request");

        self.send_message(
            AuthenticatedMessage::new_dangerous_unauthenticated(message),
            sender,
        );
    }

    /// Handle a TURN allocate request.
    ///
    /// See <https://www.rfc-editor.org/rfc/rfc8656#name-receiving-an-allocate-reque> for details.
    fn handle_allocate_request(
        &mut self,
        request: &Allocate,
        sender: ClientSocket,
        now: Instant,
    ) -> Result<(), Message<Attribute>> {
        let username = self.verify_auth(request)?;

        if let Some(allocation) = self.allocations.get(&sender) {
            let (error_response, msg) = make_error_response(AllocationMismatch, request);

            tracing::debug!(target: "relay", allocation = %allocation.port, %sender, "{msg}: Client already has an allocation");

            return Err(error_response);
        }

        let max_available_ports = self.max_available_ports() as usize;
        if self.clients_by_allocation.len() == max_available_ports {
            let (error_response, msg) = make_error_response(InsufficientCapacity, request);

            tracing::warn!(target: "relay", %max_available_ports, %sender, "{msg}: No more ports available");

            return Err(error_response);
        }

        let requested_protocol = request.requested_transport().protocol();
        if requested_protocol != UDP_TRANSPORT {
            let (error_response, msg) = make_error_response(BadRequest, request);

            tracing::warn!(target: "relay", %requested_protocol, %sender, "{msg}: Unsupported protocol");

            return Err(error_response);
        }

        let (first_relay_address, maybe_second_relay_addr) = derive_relay_addresses(
            self.public_address,
            request.requested_address_family(),
            request.additional_address_family(),
        )
        .map_err(|e| {
            let (error_response, msg) = make_error_response(e, request);
            tracing::warn!(target: "relay", %sender, "{msg}: Failed to derive relay addresses");

            error_response
        })?;

        // TODO: Do we need to handle DONT-FRAGMENT?
        // TODO: Do we need to handle EVEN/ODD-PORT?
        let effective_lifetime = request.effective_lifetime();

        let allocation = self.create_new_allocation(
            now,
            &effective_lifetime,
            first_relay_address,
            maybe_second_relay_addr,
        );

        let mut message = success_response(ALLOCATE, request.transaction_id());

        let port = allocation.port;

        message.add_attribute(XorRelayAddress::new(SocketAddr::new(
            first_relay_address,
            port.value(),
        )));
        if let Some(second_relay_address) = maybe_second_relay_addr {
            message.add_attribute(XorRelayAddress::new(SocketAddr::new(
                second_relay_address,
                port.value(),
            )));
        }

        message.add_attribute(XorMappedAddress::new(sender.0));
        message.add_attribute(effective_lifetime.clone());

        self.pending_commands.push_back(Command::CreateAllocation {
            port: allocation.port,
            family: first_relay_address.family(),
        });
        if let Some(second_relay_addr) = maybe_second_relay_addr {
            self.pending_commands.push_back(Command::CreateAllocation {
                port: allocation.port,
                family: second_relay_addr.family(),
            });
        }
        self.authenticate_and_send(&username, request, message, sender);

        if let Some(second_relay_addr) = maybe_second_relay_addr {
            tracing::info!(
                target: "relay",
                %sender,
                first_relay_address = field::display(first_relay_address),
                second_relay_address = field::display(second_relay_addr),
                lifetime = field::debug(effective_lifetime.lifetime()),
                "Created new allocation",
            )
        } else {
            tracing::info!(
                target: "relay",
                %sender,
                first_relay_address = field::display(first_relay_address),
                lifetime = field::debug(effective_lifetime.lifetime()),
                "Created new allocation",
            )
        }

        self.clients_by_allocation.insert(allocation.port, sender);
        self.allocations.insert(sender, allocation);
        self.allocations_up_down_counter.add(1, &[]);

        Ok(())
    }

    /// Handle a TURN refresh request.
    ///
    /// See <https://www.rfc-editor.org/rfc/rfc8656#name-receiving-a-refresh-request> for details.
    fn handle_refresh_request(
        &mut self,
        request: &Refresh,
        sender: ClientSocket,
        now: Instant,
    ) -> Result<(), Message<Attribute>> {
        let username = self.verify_auth(request)?;

        // TODO: Verify that this is the correct error code.
        let Some(allocation) = self.allocations.get_mut(&sender) else {
            let (error_response, msg) = make_error_response(AllocationMismatch, request);
            tracing::info!(target: "relay", %sender, "{msg}: Sender doesn't have an allocation");

            return Err(error_response);
        };

        let effective_lifetime = request.effective_lifetime();

        if effective_lifetime.lifetime().is_zero() {
            let port = allocation.port;

            self.delete_allocation(port);
            self.authenticate_and_send(
                &username,
                request,
                refresh_success_response(effective_lifetime, request.transaction_id()),
                sender,
            );

            return Ok(());
        }

        allocation.expires_at = now + effective_lifetime.lifetime();

        tracing::info!(target: "relay", allocation = %allocation.port, %sender, "Refreshed allocation");

        self.authenticate_and_send(
            &username,
            request,
            refresh_success_response(effective_lifetime, request.transaction_id()),
            sender,
        );

        Ok(())
    }

    /// Handle a TURN channel bind request.
    ///
    /// See <https://www.rfc-editor.org/rfc/rfc8656#name-receiving-a-channelbind-req> for details.
    fn handle_channel_bind_request(
        &mut self,
        request: &ChannelBind,
        sender: ClientSocket,
        now: Instant,
    ) -> Result<(), Message<Attribute>> {
        let username = self.verify_auth(request)?;

        let Some(allocation) = self.allocations.get_mut(&sender) else {
            let (error_response, msg) = make_error_response(AllocationMismatch, request);

            tracing::info!(target: "relay", "{msg}: Sender doesn't have an allocation");

            return Err(error_response);
        };

        // Note: `channel_number` is enforced to be in the correct range.
        let requested_channel = request.channel_number();
        let peer_address = PeerSocket(request.xor_peer_address().address());

        // Check that our allocation can handle the requested peer addr.
        if !allocation.can_relay_to(peer_address) {
            let (error_response, msg) = make_error_response(PeerAddressFamilyMismatch, request);

            tracing::warn!(target: "relay", allocation = %allocation.port, peer = %peer_address, channel = %requested_channel.value(), "{msg}: Allocation cannot relay to peer");

            return Err(error_response);
        }

        // Ensure the same address isn't already bound to a different channel.
        if let Some(number) = self
            .channel_numbers_by_client_and_peer
            .get(&(sender, peer_address))
            && number != &requested_channel
        {
            let (error_response, msg) = make_error_response(BadRequest, request);

            tracing::warn!(target: "relay", existing_channel = %number.value(), allocation = %allocation.port, peer = %peer_address, channel = %requested_channel.value(), "{msg}: Peer is already bound to another channel");

            return Err(error_response);
        }

        // Ensure the channel is not already bound to a different address.
        if let Some(channel) = self
            .channels_by_client_and_number
            .get_mut(&(sender, requested_channel))
        {
            if channel.peer_address != peer_address {
                let (error_response, msg) = make_error_response(BadRequest, request);

                tracing::warn!(target: "relay", existing_peer = %channel.peer_address, allocation = %allocation.port, peer = %peer_address, channel = %requested_channel.value(), "{msg}: Channel is already bound to a different peer");

                return Err(error_response);
            }

            // Binding requests for existing channels act as a refresh for the binding.

            channel.refresh(now);

            // Update the fast-path map in case the binding expired in the cooldown period and got removed.
            self.channel_and_client_by_port_and_peer.insert(
                (channel.allocation, channel.peer_address),
                (sender, requested_channel),
            );

            self.pending_commands
                .push_back(Command::CreateChannelBinding {
                    client: sender,
                    channel_number: requested_channel,
                    peer: channel.peer_address,
                    allocation_port: channel.allocation,
                });

            tracing::info!(target: "relay", allocation = %allocation.port, peer = %peer_address, channel = %requested_channel.value(), "Refreshed channel binding");

            self.authenticate_and_send(
                &username,
                request,
                channel_bind_success_response(request.transaction_id()),
                sender,
            );

            return Ok(());
        }

        // Channel binding does not exist yet, create it.

        // TODO: Any additional validations would go here.
        // TODO: Capacity checking would go here.

        let port = allocation.port;
        self.create_channel_binding(sender, requested_channel, peer_address, port, now);
        self.authenticate_and_send(
            &username,
            request,
            channel_bind_success_response(request.transaction_id()),
            sender,
        );

        tracing::info!(target: "relay", allocation = %port, peer = %peer_address, channel = %requested_channel.value(), "Successfully bound channel");

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
        request: &CreatePermission,
        sender: ClientSocket,
    ) -> Result<(), Message<Attribute>> {
        let username = self.verify_auth(request)?;

        self.authenticate_and_send(
            &username,
            request,
            create_permission_success_response(request.transaction_id()),
            sender,
        );

        Ok(())
    }

    fn handle_channel_data_message(
        &mut self,
        message: &ChannelData,
        sender: ClientSocket,
    ) -> Option<(AllocationPort, PeerSocket)> {
        let channel_number = message.channel();
        let data = message.data();

        let Some(channel) = self
            .channels_by_client_and_number
            .get(&(sender, channel_number))
        else {
            tracing::debug!(target: "relay", channel = %channel_number.value(), "Channel does not exist, refusing to forward data");
            return None;
        };

        // TODO: Do we need to enforce that only the creator of the channel can relay data?
        // The sender of a UDP packet can be spoofed, so why would we bother?

        if !channel.bound {
            tracing::debug!(target: "relay", channel = %channel_number.value(), "Channel exists but is unbound");
            return None;
        }

        tracing::trace!(target: "wire", num_bytes = %data.len());

        self.data_relayed_counter.add(data.len() as u64, &[]);
        self.data_relayed += data.len() as u64;

        Some((channel.allocation, channel.peer_address))
    }

    fn verify_auth(
        &mut self,
        request: &(impl StunRequest + ProtectedRequest),
    ) -> Result<Username, Message<Attribute>> {
        let message_integrity = request.message_integrity().ok_or_else(|| {
            let (error_response, msg) = make_error_response(Unauthorized, request);
            tracing::warn!(target: "relay", "{msg}: Missing `MessageIntegrity` attribute");

            error_response
        })?;
        let username = request.username().ok_or_else(|| {
            let (error_response, msg) = make_error_response(Unauthorized, request);
            tracing::warn!(target: "relay", "{msg}: Missing `Username` attribute");

            error_response
        })?;
        let nonce = request
            .nonce()
            .ok_or_else(|| {
                let (error_response, msg) = make_error_response(Unauthorized, request);
                tracing::debug!(target: "relay", "{msg}: Missing `Nonce` attribute");

                error_response
            })?
            .value()
            .parse::<Uuid>()
            .map_err(|e| {
                let (error_response, msg) = make_error_response(Unauthorized, request);
                tracing::warn!(target: "relay", "{msg}: Failed to parse nonce: {e}");

                error_response
            })?;

        self.nonces.handle_nonce_used(nonce).map_err(|e| {
            let (error_response, msg) = make_error_response(StaleNonce, request);
            tracing::debug!(target: "relay", "{msg}: Nonce is invalid: {e}");

            error_response
        })?;

        message_integrity
            .verify(&self.auth_secret, username.name(), SystemTime::now()) // This is impure but we don't need to control this in our tests.
            .map_err(|e| {
                let (error_response, msg) = make_error_response(Unauthorized, request);

                match e {
                    auth::Error::UnknownNonce | auth::Error::NonceUsedUp | auth::Error::Expired | auth::Error::InvalidPassword => {
                        tracing::debug!(target: "relay", "{msg}: MessageIntegrity check failed: {e}");
                    },
                    auth::Error::CannotAuthenticate(_) | auth::Error::InvalidUsername => {
                        tracing::warn!(target: "relay", "{msg}: MessageIntegrity check failed: {e}")
                    },
                }

                error_response
            })?;

        Ok(username.clone())
    }

    fn create_new_allocation(
        &mut self,
        now: Instant,
        lifetime: &Lifetime,
        first_relay_addr: IpAddr,
        second_relay_addr: Option<IpAddr>,
    ) -> Allocation {
        assert!(
            self.clients_by_allocation.len() < self.max_available_ports() as usize,
            "No more ports available; this would loop forever"
        );

        let port = loop {
            let candidate = AllocationPort(self.rng.gen_range(self.ports.clone()));

            if !self.clients_by_allocation.contains_key(&candidate) {
                break candidate;
            }
        };

        Allocation {
            port,
            expires_at: now + lifetime.lifetime(),
            first_relay_addr,
            second_relay_addr,
        }
    }

    fn max_available_ports(&self) -> u16 {
        self.ports.clone().count() as u16
    }

    fn create_channel_binding(
        &mut self,
        client: ClientSocket,
        requested_channel: ChannelNumber,
        peer: PeerSocket,
        id: AllocationPort,
        now: Instant,
    ) {
        let expiry = now + CHANNEL_BINDING_DURATION;

        let existing = self.channels_by_client_and_number.insert(
            (client, requested_channel),
            Channel {
                expiry,
                peer_address: peer,
                allocation: id,
                bound: true,
            },
        );
        self.pending_commands
            .push_back(Command::CreateChannelBinding {
                client,
                channel_number: requested_channel,
                peer,
                allocation_port: id,
            });

        debug_assert!(existing.is_none());

        let existing = self
            .channel_numbers_by_client_and_peer
            .insert((client, peer), requested_channel);

        debug_assert!(existing.is_none());

        let existing = self
            .channel_and_client_by_port_and_peer
            .insert((id, peer), (client, requested_channel));

        debug_assert!(existing.is_none());
    }

    fn authenticate_and_send(
        &mut self,
        username: &Username,
        request: &impl StunRequest,
        message: Message<Attribute>,
        recipient: ClientSocket,
    ) {
        let authenticated_message = match AuthenticatedMessage::new(
            &self.auth_secret,
            username,
            message,
        ) {
            Ok(message) => message,
            Err(e) => {
                let (error_response, msg) = make_error_response(ServerError, request);
                tracing::warn!(target: "relay", "{msg}: Failed to authenticate message: {}", err_with_src(&e));

                AuthenticatedMessage::new_dangerous_unauthenticated(error_response)
            }
        };

        self.send_message(authenticated_message, recipient);
    }

    fn send_message(&mut self, message: AuthenticatedMessage, recipient: ClientSocket) {
        debug_assert!(message.get_attribute::<Software>().is_some());

        let method = message.method();
        let class = message.class();
        let error_code = message.get_attribute::<ErrorCode>().map(|e| e.code());
        tracing::trace!(target: "relay",  method = %message.method(), class = %message.class(), "Sending message");

        let Ok(bytes) = auth::MessageEncoder::default().encode_into_bytes(message) else {
            debug_assert!(false, "Encoding should never fail");
            return;
        };

        tracing::trace!(target: "wire", num_bytes = %bytes.len());

        self.pending_commands.push_back(Command::SendMessage {
            payload: bytes,
            recipient,
        });

        // record metrics
        let response_class = match class {
            MessageClass::SuccessResponse => "success",
            MessageClass::ErrorResponse => "error",
            MessageClass::Indication | MessageClass::Request => return,
        };
        let message_type = match method {
            BINDING => "binding",
            ALLOCATE => "allocate",
            REFRESH => "refresh",
            CHANNEL_BIND => "channelbind",
            CREATE_PERMISSION => "createpermission",
            _ => return,
        };
        let error_code = error_code.map(|c| opentelemetry::Value::from(c as i64));

        // Use a `SmallVec` to avoid heap-allocations when collecting metrics.
        let mut attributes = SmallVec::<[KeyValue; 3]>::with_capacity(3);
        attributes.push(KeyValue::new("response_class", response_class));
        attributes.push(KeyValue::new("message_type", message_type));

        if let Some(error_code) = error_code {
            attributes.push(KeyValue::new("error_code", error_code));
        }

        self.responses_counter.add(1, &attributes);
    }

    fn delete_allocation(&mut self, port: AllocationPort) {
        let Some(client) = self.clients_by_allocation.remove(&port) else {
            tracing::debug!(target: "relay", allocation = %port, "Unable to delete unknown allocation");

            return;
        };
        let allocation = self
            .allocations
            .remove(&client)
            .expect("internal state mismatch");

        let port = allocation.port;

        for ((cs, number), c) in self
            .channels_by_client_and_number
            .extract_if(.., |_, c| c.allocation == port)
        {
            debug_assert_eq!(cs, client, "internal state should be consistent");

            let peer = c.peer_address;

            if let Some(existing) = self
                .channel_numbers_by_client_and_peer
                .remove(&(client, peer))
            {
                debug_assert_eq!(existing, number, "internal state should be consistent");
            }

            if let Some((existing_cs, existing_n)) = self
                .channel_and_client_by_port_and_peer
                .remove(&(port, peer))
            {
                debug_assert_eq!(existing_cs, cs, "internal state should be consistent");
                debug_assert_eq!(existing_n, number, "internal state should be consistent");
            }

            self.pending_commands
                .push_back(Command::DeleteChannelBinding {
                    client: cs,
                    channel_number: number,
                    peer: c.peer_address,
                    allocation_port: c.allocation,
                });

            tracing::info!(%peer, %number, allocation = %port, "Deleted channel binding");
        }

        self.allocations_up_down_counter.add(-1, &[]);
        self.pending_commands.push_back(Command::FreeAllocation {
            port,
            family: allocation.first_relay_addr.family(),
        });
        if let Some(second_relay_addr) = allocation.second_relay_addr {
            self.pending_commands.push_back(Command::FreeAllocation {
                port,
                family: second_relay_addr.family(),
            })
        }

        tracing::info!(target: "relay", allocation = %port, "Deleted allocation");
    }

    fn delete_channel_binding(&mut self, client: ClientSocket, chan: ChannelNumber) {
        let Some(channel) = self.channels_by_client_and_number.get(&(client, chan)) else {
            return;
        };

        let peer = channel.peer_address;
        let allocation = channel.allocation;

        if let Some(_peer_channel) = self
            .channel_numbers_by_client_and_peer
            .remove(&(client, peer))
        {
            debug_assert_eq!(_peer_channel, chan, "internal state should be consistent");
        }

        self.channels_by_client_and_number.remove(&(client, chan));

        tracing::info!(target: "relay", channel = %chan.value(), %client, %peer, %allocation, "Channel binding is now deleted (and can be rebound)");
    }

    fn new_nonce_attribute(&mut self) -> Nonce {
        let new_nonce = Uuid::from_u128(self.rng.r#gen());

        self.add_nonce(new_nonce);

        Nonce::new(new_nonce.to_string())
            .expect("UUIDs are valid nonces because they are less than 128 characters long")
    }
}

fn make_error_response(
    error_code: impl Into<ErrorCode>,
    request: &impl StunRequest,
) -> (Message<Attribute>, String) {
    let method = request.method();

    let attribute = error_code.into();
    let reason = attribute.reason_phrase();
    let msg = format!("{method} failed with {reason}");

    (
        error_response(method, request.transaction_id(), attribute),
        msg,
    )
}

fn refresh_success_response(
    effective_lifetime: Lifetime,
    transaction_id: TransactionId,
) -> Message<Attribute> {
    let mut message = success_response(REFRESH, transaction_id);
    message.add_attribute(effective_lifetime);
    message
}

fn channel_bind_success_response(transaction_id: TransactionId) -> Message<Attribute> {
    success_response(CHANNEL_BIND, transaction_id)
}

fn create_permission_success_response(transaction_id: TransactionId) -> Message<Attribute> {
    success_response(CREATE_PERMISSION, transaction_id)
}

/// Represents an allocation of a client.
#[derive(Debug, Clone)]
struct Allocation {
    /// Data arriving on this port will be forwarded to the client iff there is an active data channel.
    port: AllocationPort,
    expires_at: Instant,

    first_relay_addr: IpAddr,
    second_relay_addr: Option<IpAddr>,
}

#[derive(Debug, Clone)]
struct Channel {
    /// When the channel expires.
    expiry: Instant,

    /// The address of the peer that the channel is bound to.
    peer_address: PeerSocket,

    /// The allocation this channel belongs to.
    allocation: AllocationPort,

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
        self.bound = true;
    }

    fn is_expired(&self, now: Instant) -> bool {
        self.expiry <= now
    }

    fn can_be_deleted(&self, now: Instant) -> bool {
        self.expiry + CHANNEL_REBIND_TIMEOUT <= now
    }
}

impl Allocation {
    /// Checks whether this [`Allocation`] can relay to the given address.
    ///
    /// This is called in the context of a channel binding with the requested peer address.
    /// We can only relay to the address if the allocation supports the same version of the IP protocol.
    fn can_relay_to(&self, addr: PeerSocket) -> bool {
        match addr.0 {
            SocketAddr::V4(_) => self.first_relay_addr.is_ipv4(), // If we have an IPv4 address, it is in `first_relay_addr`, no need to check `second_relay_addr`.
            SocketAddr::V6(_) => {
                self.first_relay_addr.is_ipv6()
                    || self.second_relay_addr.is_some_and(|a| a.is_ipv6())
            }
        }
    }
}

impl Allocation {
    fn is_expired(&self, now: Instant) -> bool {
        self.expires_at <= now
    }
}

/// Derive the relay address for the client based on the request and the supported IP stack of the relay server.
///
/// By default, a client gets an IPv4 address.
/// They can request an _additional_ IPv6 address or only an IPv6 address.
/// This is handled with two different STUN attributes: [AdditionalAddressFamily] and [RequestedAddressFamily].
///
/// The specification mandates certain checks for how these attributes can be used.
/// In a nutshell, the requirements constrain the use such that there is only one way of doing things.
/// For example, it is disallowed to use [RequestedAddressFamily] for IPv6 and requested and an IPv4 address via [AdditionalAddressFamily].
/// If this is desired, clients should simply use [AdditionalAddressFamily] for IPv6.
///
/// Note: To be fully compliant with TURN, we would need to set `ADDRESS-ERROR-CODE` in the response for partially filled requests.
/// We chose to omit this for now because our clients don't check for it.
fn derive_relay_addresses(
    public_address: IpStack,
    requested_addr_family: Option<&RequestedAddressFamily>,
    additional_addr_family: Option<&AdditionalAddressFamily>,
) -> Result<(IpAddr, Option<IpAddr>), ErrorCode> {
    match (
        public_address,
        requested_addr_family.map(|r| r.address_family()),
        additional_addr_family.map(|a| a.address_family()),
    ) {
        (
            IpStack::Ip4(addr) | IpStack::Dual { ip4: addr, .. },
            None | Some(AddressFamily::V4),
            None,
        ) => Ok((addr.into(), None)),
        (IpStack::Ip6(addr) | IpStack::Dual { ip6: addr, .. }, Some(AddressFamily::V6), None) => {
            Ok((addr.into(), None))
        }
        (IpStack::Dual { ip4, ip6 }, None, Some(AddressFamily::V6)) => {
            Ok((ip4.into(), Some(ip6.into())))
        }
        (IpStack::Ip4(ip4), None, Some(AddressFamily::V6)) => {
            // TODO: The spec says to also include an error code here.
            // For now, we will just partially satisfy the request.
            // We expect clients to gracefully handle this by only extracting the relay addresses they receive.

            tracing::debug!(target: "relay", "Partially fulfilling allocation using only an IPv4 address");

            Ok((ip4.into(), None))
        }
        (IpStack::Ip6(ip6), None, Some(AddressFamily::V6)) => {
            // TODO: The spec says to also include an error code here.
            // For now, we will just partially satisfy the request.
            // We expect clients to gracefully handle this by only extracting the relay addresses they receive.

            tracing::debug!(target: "relay", "Partially fulfilling allocation using only an IPv6 address");

            Ok((ip6.into(), None))
        }
        (_, Some(_), Some(_)) => {
            tracing::warn!(target: "relay", "Specifying `REQUESTED-ADDRESS-FAMILY` and `ADDITIONAL-ADDRESS-FAMILY` is against the spec");

            Err(BadRequest.into())
        }
        (_, _, Some(AddressFamily::V4)) => {
            tracing::warn!(target: "relay", "Specifying `IPv4` for `ADDITIONAL-ADDRESS-FAMILY` is against the spec");

            Err(BadRequest.into())
        }
        (IpStack::Ip6(_), None | Some(AddressFamily::V4), None) => {
            tracing::warn!(target: "relay", "Cannot provide an IPv4 allocation on an IPv6-only relay");

            Err(AddressFamilyNotSupported.into())
        }
        (IpStack::Ip4(_), Some(AddressFamily::V6), _) => {
            tracing::warn!(target: "relay", "Cannot provide an IPv6 allocation on an IPv4-only relay");

            Err(AddressFamilyNotSupported.into())
        }
    }
}

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

/// Private helper trait to make [`Server::verify_auth`] more ergonomic to use.
trait ProtectedRequest {
    fn message_integrity(&self) -> Option<&MessageIntegrity>;
    fn username(&self) -> Option<&Username>;
    fn nonce(&self) -> Option<&Nonce>;
}

macro_rules! impl_protected_request_for {
    ($t:ty) => {
        impl ProtectedRequest for $t {
            fn message_integrity(&self) -> Option<&MessageIntegrity> {
                self.message_integrity()
            }

            fn username(&self) -> Option<&Username> {
                self.username()
            }

            fn nonce(&self) -> Option<&Nonce> {
                self.nonce()
            }
        }
    };
}

impl_protected_request_for!(Allocate);
impl_protected_request_for!(ChannelBind);
impl_protected_request_for!(CreatePermission);
impl_protected_request_for!(Refresh);

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
        Username,
        RequestedAddressFamily,
        AdditionalAddressFamily,
        Software
    ]
);

fn success_response(method: Method, id: TransactionId) -> Message<Attribute> {
    let mut message = Message::new(MessageClass::SuccessResponse, method, id);
    message.add_attribute(SOFTWARE.clone());

    message
}

fn error_response(
    method: Method,
    transaction_id: TransactionId,
    error_code: ErrorCode,
) -> Message<Attribute> {
    let mut message = Message::new(MessageClass::ErrorResponse, method, transaction_id);
    message.add_attribute(SOFTWARE.clone());
    message.add_attribute(error_code);

    message
}

fn earliest(left: Option<Instant>, right: Option<Instant>) -> Option<Instant> {
    match (left, right) {
        (None, None) => None,
        (Some(left), Some(right)) => Some(std::cmp::min(left, right)),
        (Some(left), None) => Some(left),
        (None, Some(right)) => Some(right),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, Ipv6Addr};

    // Tests for requirements listed in https://www.rfc-editor.org/rfc/rfc8656#name-receiving-an-allocate-reque.

    // 6. The server checks if the request contains both REQUESTED-ADDRESS-FAMILY and ADDITIONAL-ADDRESS-FAMILY attributes. If yes, then the server rejects the request with a 400 (Bad Request) error.
    #[test]
    fn requested_and_additional_is_bad_request() {
        let error_code = derive_relay_addresses(
            IpStack::Ip4(Ipv4Addr::LOCALHOST),
            Some(&RequestedAddressFamily::new(AddressFamily::V4)),
            Some(&AdditionalAddressFamily::new(AddressFamily::V6)),
        )
        .unwrap_err();

        assert_eq!(error_code.code(), BadRequest::CODEPOINT)
    }

    // 7. If the server does not support the address family requested by the client in REQUESTED-ADDRESS-FAMILY, or if the allocation of the requested address family is disabled by local policy, it MUST generate an Allocate error response, and it MUST include an ERROR-CODE attribute with the 440 (Address Family not Supported) response code.
    // If the REQUESTED-ADDRESS-FAMILY attribute is absent and the server does not support the IPv4 address family, the server MUST include an ERROR-CODE attribute with the 440 (Address Family not Supported) response code.
    #[test]
    fn requested_address_family_not_available_is_not_supported() {
        let error_code = derive_relay_addresses(
            IpStack::Ip4(Ipv4Addr::LOCALHOST),
            Some(&RequestedAddressFamily::new(AddressFamily::V6)),
            None,
        )
        .unwrap_err();

        assert_eq!(error_code.code(), AddressFamilyNotSupported::CODEPOINT);

        let error_code = derive_relay_addresses(
            IpStack::Ip6(Ipv6Addr::LOCALHOST),
            Some(&RequestedAddressFamily::new(AddressFamily::V4)),
            None,
        )
        .unwrap_err();

        assert_eq!(error_code.code(), AddressFamilyNotSupported::CODEPOINT);

        let error_code =
            derive_relay_addresses(IpStack::Ip6(Ipv6Addr::LOCALHOST), None, None).unwrap_err();

        assert_eq!(error_code.code(), AddressFamilyNotSupported::CODEPOINT)
    }

    //9. The server checks if the request contains an ADDITIONAL-ADDRESS-FAMILY attribute. If yes, and the attribute value is 0x01 (IPv4 address family), then the server rejects the request with a 400 (Bad Request) error.
    #[test]
    fn additional_address_family_ip4_is_bad_request() {
        let error_code = derive_relay_addresses(
            IpStack::Ip4(Ipv4Addr::LOCALHOST),
            None,
            Some(&AdditionalAddressFamily::new(AddressFamily::V4)),
        )
        .unwrap_err();

        assert_eq!(error_code.code(), BadRequest::CODEPOINT)
    }
}
